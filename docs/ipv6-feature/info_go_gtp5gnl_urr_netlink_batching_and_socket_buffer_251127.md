# URR Netlink Batching Mismatch & Socket Buffer Considerations

## Background

- Kernel repeatedly logs `gtp5g_genl_get_multi_usage_reports: WNC:multi_usage_reports truncated: URR_NUM=4 parsed=3 remaining=0` (see `dmesg-10.log:485`). The guard at `gtp5g/src/genl/genl_report.c:213` returns `-EINVAL` when the number of parsed `GTP5G_URR_MULTI_SEID_URRID` attributes is less than the advertised `URR_NUM`.
- User space (go-gtp5gnl) fetches Usage Reporting Rule (URR) chunks via `getMultiReportsOIDChunk()` (`go-gtp5gnl/report.go:342-383`). The batching logic currently assumes `MaxNetlinkUsageReportNum()` URRs will fit into a single netlink message.
- Documentation for the intended fix lives in `docs/ipv6-feature/issue_urr_netlink_message_overflow_fix_251119.md`, which explains the serialization limits and suggests either clamping `MaxNetlinkUsageReportNum()` or teaching the chunking logic to stay within `nlmsgGoodSize`.

## Root Cause Recap

1. `URR_NUM` is set to `len(oids)` before attributes are serialized.
2. As the fourth URR TLV is appended, the message exceeds the kernel's `nlmsgGoodSize` and the final attribute gets truncated.
3. The kernel still sees `URR_NUM=4` but only three TLVs; it rejects the request, causing the UPF to retry and emit the warning endlessly.

In short, the mismatch is not a kernel parsing bug—the user-space writer promises more URRs than the kernel receives because the message silently overruns the safe payload size.

### More detailed explaination

 URR_NUM comes straight from len(oids) in getMultiReportsOIDChunk() (go-gtp5gnl/report.go:342‑383). The reason the kernel only sees three TLVs is that the netlink message overruns the size limit while user space is appending the fourth URR_MULTI_SEID_URRID attribute. Netlink silently truncates the tail of the message, so:

  1. URR_NUM is still 4 (it was written before serialization started).
  2. Only three TLVs actually make it onto the wire because the last nla.Attr is cut off.
  3. The guard in gtp5g/src/genl/genl_report.c:213 notices the mismatch (URR_NUM=4 parsed=3) and rejects the request.



## Key Questions & Answers

**Q1: Why does user space claim to send 4 URRs when the kernel only sees 3? Shouldn't we fix the sender instead of clamping the number to 3?**  
**A1:** The sender already *intends* to send four URRs, and `URR_NUM` is accurate at the time it is written. However, netlink truncates the tail once the serialized message size exceeds the `NLMSG_GOODSIZE` threshold. The fourth TLV never reaches the kernel even though `URR_NUM` still says 4. Clamping `MaxNetlinkUsageReportNum()` to 3 is a temporary workaround because smaller batches fit into the default good size, but the real fix is to base batching on bytes rather than a fixed TLV count. See the formula in `issue_urr_netlink_message_overflow_fix_251119.md` or implement the byte-budget logic directly in `getMultiReportsOIDChunk()`.

**Q2: What is `nlmsgGoodSize`? I could not find it in the gtp5g source tree.**  
**A2:** `nlmsgGoodSize()` (or the `NLMSG_GOODSIZE` macro defined in `<linux/netlink.h>`) returns a conservative upper bound for the payload a single netlink message should carry on a default socket. It is derived from the default netlink socket buffer size (~32 KB) and subtracts header padding/alignment, resulting in ~8 KB of safe payload. Staying below this size avoids fragmentation and truncation.

**Q3: If we teach `getMultiReportsOIDChunk()` to stop once the serialized message would exceed `nlmsgGoodSize`, will increases to `SO_SNDBUF/RCVBUF` or global `rmem/wmem`/TCP autotune sysctls stop helping throughput?**  

Sometimes we will configure below for throughout test ( it should be related to RCVBUF)

## Setting memory parameters for kernel socket buffers
sysctl -w net.core.rmem_max=268435456
sysctl -w net.core.rmem_default=134217728
sysctl -w net.core.wmem_max=268435456
sysctl -w net.core.wmem_default=16777216

## Increase Linux autotuning TCP buffer limit to 64MB
sysctl -w net.ipv4.tcp_rmem='4096 84380 134217728'
sysctl -w net.ipv4.tcp_wmem='4096 65536 134217728'


**A3:** No. Restricting each *control-plane* netlink message to `nlmsgGoodSize` only affects how many URR TLVs fit into one request. Data-plane throughput gains from larger socket buffers remain intact because they apply to the high-volume TCP/UDP sockets carrying user traffic. Netlink's good-size limit is independent of the buffers you tune for other sockets, so chunking URRs by byte size does not negate your throughput improvements.

## Recommendations

1. **Implement the batching fix:** Either adopt the byte-accurate formula laid out in `docs/ipv6-feature/issue_urr_netlink_message_overflow_fix_251119.md` or modify `getMultiReportsOIDChunk()` to accumulate `NLMSG_ALIGN(attrLen)` while appending TLVs and stop before exceeding `nlmsgGoodSize`. This ensures the number of serialized URRs matches `URR_NUM`.
2. **Keep the socket buffer tuning:** The existing sysctl changes (`net.core.{r,w}mem_*`, `net.ipv4.tcp_{r,w}mem`) and any per-socket `SO_SNDBUF/RCVBUF` adjustments continue to benefit user-plane throughput and do not interfere with the control-plane fix.
3. **Optional guardrail:** Until the chunking change is merged, temporarily clamp `MaxNetlinkUsageReportNum()` to 3 so every batch fits under the current `NLMSG_GOODSIZE` threshold. Remove the clamp after the byte-aware batching lands.

Recording this context ensures the rationale behind the URR mismatch and the interaction with socket buffer tuning is preserved for future debugging sessions.



## Implementation Plan for Q3: Byte-Aware Chunking in `getMultiReportsOIDChunk()`

1. **Define the byte budget**  
   - Add a helper (e.g., `maxURRPayload()` (please refer to `### Optional: Pulling NLMSG_GOODSIZE via cgo` to retrive NLMSG_GOODSIZE ...etc ) in `attr_report.go`) that returns `NLMSG_GOODSIZE - headerSlack`, where `headerSlack` covers the netlink/genl headers plus the fixed attributes (`LINK`, `URR_NUM`). Start with the current kernel constant (8192) and document that it must track `linux/netlink.h`. Optional: detect larger buffers via `getsockopt(SO_SNDBUF)` and choose the minimum of that value and `NLMSG_GOODSIZE`.

2. **Estimate per-TLV size**  
   - Implement a Go-side calculator for the serialized size of `URR_MULTI_SEID_URRID`. Include:  
     `nl.SizeofAttr` for the outer TLV, aligned sizes for `URR_ID` and `URR_SEID`, and their nested headers. Use the same alignment helper `nl.NextAlignOf()` so the estimate mirrors real encoding.

3. **Track bytes during chunk assembly**  
   - Seed a `usedBytes` counter with the cost of the fixed attrs (`LINK` + `URR_NUM`).  
   - Iterate OIDs and, before appending, compute `tlvBytes`. If `usedBytes + tlvBytes` exceeds the payload budget, stop and send what you already have; otherwise append the attr and add `tlvBytes` to `usedBytes`.

4. **Adjust the chunking loop in `getMultiReportsOID()`**  
   - Instead of slicing by a static `maxBatchSize`, ask the chunk builder how many OIDs it consumed (e.g., return `(reports []USAReport, consumed int, err error)` or provide a helper that returns the "max count given leftover bytes"). Advance the outer loop by `consumed` to ensure you never skip URRs when the byte budget reduces the per-message count.

5. **Validation and logging**  
   - When `DebugLogging` is enabled, log the payload budget, bytes consumed, and TLV count for each chunk to correlate with kernel traces.  
   - If one TLV already exceeds the budget (should not happen), log a warning and send it alone to avoid deadlocks.

6. **Testing**  
   - Extend the `testChunkHook` harness to simulate budget boundaries (exact fit, overflow by one TLV, single large TLV).  
   - Use `strace -e sendmsg` or `netlink` capture to confirm the emitted `nlmsghdr.nlmsg_len` never exceeds the configured budget and that `URR_NUM` equals the TLV count.

Following these steps ensures each request stays within the kernel's safe netlink payload size while still batching as many URRs as the byte budget allows, eliminating the URR_NUM mismatch without impacting data-plane throughput tuning.

### Optional: Pulling `NLMSG_GOODSIZE` via cgo

If we want `go-gtp5gnl` to auto-track kernel header values instead of hardcoding a constant, add a small cgo helper:

```go
//go:build cgo

package gtp5gnl

/*
#include <linux/netlink.h>

const unsigned int go_nlmsg_goodsize = NLMSG_GOODSIZE;
const unsigned int go_nlmsg_default_size = NLMSG_DEFAULT_SIZE;
*/
import "C"

var (
	nlmsgGoodSize    = uint32(C.go_nlmsg_goodsize)
	nlmsgDefaultSize = uint32(C.go_nlmsg_default_size)
)
```

- The preamble includes `<linux/netlink.h>` from the system headers.  
- We expose the macros as `const unsigned int` because cgo cannot read macros directly.  
- `nlmsgGoodSize` / `nlmsgDefaultSize` can then be used in the byte-budget logic.  
- Add a `//go:build !cgo` sibling file with hardcoded defaults (e.g., 8192) so pure-Go builds remain possible.  
- Building now requires the host to have kernel headers installed (e.g., `linux-headers-$(uname -r)`).

This keeps the batching limit aligned with whatever `NLMSG_GOODSIZE` the kernel headers define at build time, while the rest of the logic remains the same.
