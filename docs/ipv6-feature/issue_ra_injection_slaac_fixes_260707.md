# IPv6 SLAAC / Router Advertisement Injection — Debugging & Fixes

**Date**: 2026-07-07
**Components**: gtp5g (kernel), go-gtp5gnl (netlink lib), UPF, SMF
**Symptom**: UE registers and gets an IPv4 address and an IPv6 **interface identifier**
(last 8 digits, delivered in the NAS *PDU Session Establishment Accept*), but never obtains a
usable **global IPv6 address** — i.e. SLAAC never completes.
**Status at end of day**: RA is now built correctly (88 bytes) and injected into the kernel
successfully; UE **still** does not configure IPv6. Next suspect = RA not reaching/accepted by
the UE (see companion `TODO_260707.md`).

---

## Background: the SLAAC delivery chain in free5gc

For a 5G UE to get an IPv6 address via SLAAC, this whole chain must complete:

```
UE sends Router Solicitation (RS, ICMPv6 type 133)
  → UPF/gtp5g matches RS via a high-precedence RS-monitor PDR + URR (EVETH event trigger)
  → UPF sends a PFCP Session Report (event only, NOT the packet) to SMF
  → SMF HandleEventReport(eventID=26) builds a Router Advertisement (RA, ICMPv6 type 134)
  → SMF POSTs the RA to the UPF HTTP endpoint  http://<upf>:8080/upf/v1/inject-ra
  → UPF calls go-gtp5gnl InjectRA → netlink → gtp5g kernel gtp5g_genl_inject_ra()
  → kernel dev_queue_xmit() → GTP-U encap toward gNB → UE
  → UE runs SLAAC using the advertised /64 prefix + its interface identifier
```

**Architectural note (important):** Unlike open5gs — which detects the RS **and** builds/sends the
RA entirely in the UPF data plane (so it holds the RS packet and can *unicast* the RA back to the
UE's link-local) — free5gc routes only a PFCP **event** up to the SMF. The SMF therefore never sees
the RS packet (no UE link-local source address), builds the RA in the control plane, and ships it
back down over HTTP. This round-trip is why the feature has so many independent failure points.

> `★ Insight ─────────────────────────────────────`
> Each layer of this chain fails **silently and independently**. When the chain is broken at layer N,
> everything up to N looks perfectly healthy in the logs, and nothing errors — the UE just keeps
> soliciting. The debugging strategy that worked was to walk the chain hop-by-hop and find the *first
> silent hop*, rather than trusting the "✅ production ready" status in the older docs (which reflected
> passing **unit tests**, not a working end-to-end UE).
> `─────────────────────────────────────────────────`

---

## Fixes applied today (in the order discovered)

### Fix 1 — gtp5g loaded with IPv6 data path DISABLED
**File / knob**: `gtp5g/src/gtp5g.c` module param `ipv6_data_path` (default `false`).

The entire IPv6 data path is gated behind this parameter. When off:
`GET_FEATURES` reports `IPv6DataPath=false` → UPF (`NFs/upf/internal/forwarder/gtp5g.go:176`)
sets `ipv6Supported=false` → UPF PFCP association advertises `features: 0x0`
(`NFs/upf/internal/pfcp/association.go:48`) → SMF logs `UPF IPv6 support: false` → whole IPv6
path + RA injection disabled. gtp5g also actively rejects IPv6 PDR/FTEID/SDF/RA attributes when
the flag is 0.

**Fix**: load the module with the flag on:
```bash
sudo rmmod gtp5g
sudo insmod gtp5g.ko ipv6_data_path=1
cat /sys/module/gtp5g/parameters/ipv6_data_path   # -> Y
dmesg | grep gtp5g                                # -> "IPv6 data path: enabled"
```

> `★ Insight ─────────────────────────────────────`
> gtp5g follows a "features default-off" convention (same as its QoS support). After a long gap the
> testbed was restarted with a plain `insmod`/`modprobe`, so IPv6 came up disabled and every layer
> above it correctly, silently declined. A plain module reload also **resets `/proc/gtp5g/dbg` to the
> default (1)** — remember to re-apply `echo 4 > /proc/gtp5g/dbg` after every reload.
> `─────────────────────────────────────────────────`

### Fix 2 — UPF HTTP RA-injection endpoint was disabled (already fixed before today)
**File**: `config/upfcfg.yaml` — the `httpService` section.

The SMF delivers the RA to the UPF via `http://<upf>:8080/upf/v1/inject-ra`. The UPF only starts
that server if `httpService.enable: true` (`NFs/upf/internal/http/server.go:74`). Earlier the section
was absent/disabled → `connection refused`. The running config now has:
```yaml
httpService:
  enable: true
  port: 8080
  addr: 5.5.5.2
```

### Fix 3 — RA netlink attribute type numbers collided with the device attrs
**Files**: `gtp5g/include/genl_ra.h`, `go-gtp5gnl/attr_ra.go`

gtp5g uses a **single shared attribute namespace** (family `maxattr = GTP5G_ATTR_MAX = 32`): type
`1 = GTP5G_LINK`, `2 = GTP5G_NET_NS_FD`, and every command starts its own attrs at 3+
(e.g. `GTP5G_PDR_ID = 3`, go `PDR_ID = iota + 3`). The RA enums wrongly **restarted at 1**, so
`GTP5G_RA_SEID(1)` collided with `GTP5G_LINK(1)` — and the inject-ra message sends **both** `LINK`
and `RA_SEID`, i.e. two attributes with type 1.

**Fix**: renumber RA attrs to start at 3 on BOTH sides (must stay in sync):
```
GTP5G_RA_SEID:  1 -> 3      GTP5G_RA_PDR_ID: 2 -> 4      GTP5G_RA_PACKET: 3 -> 5
```

### Fix 4 — go-gtp5gnl InjectRA never set the genl command header (the real routing bug)
**File**: `go-gtp5gnl/ra.go`

This was the primary reason the kernel returned `EINVAL` with **no handler log at all**. The request
was built wrong:
```go
// BROKEN:
req := nl.NewRequest(c.ID, CMD_INJECT_RA)   // 2nd arg is FLAGS, not the command!
// ...and no genl.Header{Cmd: ...} was ever appended
```
So the kernel saw genl command `0` (UNSPEC), never routed to `gtp5g_genl_inject_ra`, and rejected
the message before the handler ran. Fixed to follow the `features.go` / `pdr.go` pattern:
```go
flags := syscall.NLM_F_ACK
req := nl.NewRequest(c.ID, flags)
err := req.Append(genl.Header{Cmd: CMD_INJECT_RA})   // command goes in the genl HEADER
// ... then append the attribute list ...
```
New imports required: `"syscall"`, `"github.com/khirono/go-genl"`.

> `★ Insight ─────────────────────────────────────`
> The tell was **"EINVAL with zero kernel handler logs, even at dbg=1."** gtp5g log levels are
> `LOG=0, ERR=1(default), WAR=2, INF=3, TRC=4` and print when `level <= dbg`. Every `-EINVAL` path
> inside the handler logs via `GTP5G_ERR` (level 1), so at dbg=1 they *would* appear. Their absence
> proved the handler was never reached → the rejection was upstream in generic-netlink → the message
> itself was malformed (wrong command). Reasoning about *which* logs should appear at a given level is
> what separated "handler not reached" from "handler failed silently."
> `─────────────────────────────────────────────────`

> `★ Insight ─────────────────────────────────────`
> Two independent bugs (Fix 3 and Fix 4) produced the **identical** symptom. Fixing only the attribute
> numbering did nothing because the command header was still wrong; fixing only the header would have
> immediately surfaced the attribute collision. This is why systematic debugging insists on verifying
> *the handler is even reached* before theorizing about what it does — and on changing one variable at
> a time.
> `─────────────────────────────────────────────────`

### Fix 5 — the RA packet itself was malformed
**File**: `NFs/smf/internal/context/router_advertisement.go` — `BuildRouterAdvertisement()`

The builder produced only a **48-byte ICMPv6 body** (RA header 16 + Prefix Option 32) with:
1. **No IPv6 header at all.** The kernel injector transmits the bytes verbatim as an IPv6 packet
   (`genl_ra.c` sets `protocol=ETH_P_IPV6`, `skb_reset_network_header`, `dev_queue_xmit`), so the
   first byte `0x86` (type 134) made the IP **version nibble read as 8, not 6** → not a valid IPv6
   packet. (The kernel's own `if (ra_len < 40 + 8)` check *expects* a 40-byte IPv6 header; 48 bytes
   of pure ICMPv6 squeaked past by coincidence.)
2. **ICMPv6 checksum hardcoded to 0** (a code comment even admitted the pseudo-header calc was
   missing) → UE drops it.
3. **M (managed) flag set** (`RAFlagManaged`, 0x80) → tells the UE to use **DHCPv6**, not SLAAC.

**Reference (known-good)**: the working open5gs RA captured on the CU — `my_logs/open5gs_cu_RA.txt`:
full IPv6 header, hop limit **255**, src `fe80::1`, dst `fe80::8` (UE link-local, unicast), computed
checksum, flags **M=0**, prefix option A=1, plus an MTU option. Total inner IPv6 packet = 96 bytes.

**Fix**: rebuild the packet as a complete IPv6 datagram (40-byte IPv6 header + 16 RA + 32 prefix =
**88 bytes**): version 6, next header 58, hop limit 255, src `fe80::1`, dst `ff02::1`, M=0, A=1, and a
correctly computed ICMPv6 checksum (new `icmpv6Checksum()` helper over the IPv6 pseudo-header).

**Why `ff02::1` (all-nodes multicast) instead of the UE's link-local like open5gs?** Because free5gc's
SMF only gets a PFCP *event*, not the RS packet, so it does not know the UE's self-chosen link-local
to unicast back to. `ff02::1` reaches the UE without needing it. (See the architecture discussion in
the TODO — this may need to change.)

> `★ Insight ─────────────────────────────────────`
> A malformed packet that *passes* a boundary check is more dangerous than one that fails it: the
> 48-byte body slipped through `ra_len < 48`, so nothing errored and it sailed all the way to the UE
> before dying. The kernel's length check (`40 + 8`) was itself a documentation of intent — it told us
> the injector expected the IPv6 header to be included by the caller, which the SMF was not doing.
> `─────────────────────────────────────────────────`

---

### Fix 6 (✅ VERIFIED FIXED 2026-07-08) — gtp5g dropped the injected RA because it re-derived the tunnel from `ff02::1`
**Files**: `gtp5g/src/genl/genl_ra.c`, `gtp5g/src/gtpu/encap.c`, `gtp5g/include/encap.h`

> **STATUS — VERIFIED.** After deploying this fix to `cn` (rebuild `gtp5g.ko`, reload with
> `ipv6_data_path=1`) and re-testing with the live OpenWRT/T-Mobile UE, **the UE now obtains a global
> IPv6 address via SLAAC** — the root-cause drop is resolved end-to-end, not just in theory.
> Evidence: `/home/loren/Downloads/log/260708-tmobile/test1-free5gc-t3-ipv6-ping-fail/` —
> `free5gc/log/console_free5gc.log` and CN pcap `free5gc/log/20260708_064137/free5gc.pcap`.
> A **separate** problem remains: IPv6 **ping does not work yet** (SLAAC address is assigned but no
> traffic passes). That is tracked as its own open issue below and in `TODO_260707.md`, and is NOT a
> regression of this fix.

Found by static code analysis — the planned packet capture was unnecessary to localize the drop.

**Trace of the drop:**
```
genl_ra.c: gtp5g_genl_inject_ra() resolves the correct PDR from SEID+PDR_ID ...
  ... then throws it away:  dev_queue_xmit(ra_skb)          (genl_ra.c:158)
  → gtp5g_dev_xmit()                                        (gtpu/dev.c:100, ndo_start_xmit)
  → gtp5g_handle_skb_ipv6()                                 (gtpu/encap.c:1221)
  → pdr = pdr_find_by_ipv6(gtp, skb, 0, &ip6h->daddr)       (encap.c:1244)  ← re-derives by DEST addr
  → pdr_find_by_ipv6(): ipv6_addr_equal(&pdi->ue_addr_ipv6, addr)  (pfcp/pdr.c:929) ← UE GLOBAL only
```
The RA's destination is `ff02::1` (all-nodes multicast). `pdr_find_by_ipv6` matches **only** a UE's
exact **global** address, so `ff02::1` matches nothing → `encap.c:1249 "no PDR found for IPv6
ff02::1, skip"` → `-ENOENT` → `dev.c:145 tx_err` → `dev_kfree_skb`. The RA is dropped **inside the
kernel**, immediately after `"RA packet injected successfully"` is logged (that log only means
`dev_queue_xmit` accepted the skb onto the TX path, not that it was delivered).

**Why the asymmetry (RS works, RA doesn't):** the **uplink** IPv6 matcher (`pfcp/pdr.c:786-878`) is
rich — it handles UE link-local sources and solicited-node multicast, which is why the RS is received
fine. The **downlink** resolver `pdr_find_by_ipv6` (`pfcp/pdr.c:916`) is a bare exact-global-address
match. Only one direction was taught about NDP's non-unicast addresses.

**Why not just change the RA destination?** Two dead ends: (1) the UE's *global* address doesn't
exist yet during SLAAC — the UE only has its link-local; (2) the UE *link-local* also fails, because
`pdr_find_by_ipv6` doesn't match link-local either. The real fix is not the address — it's that the
handler must **use the PDR it already resolved** instead of re-deriving it from the destination.

**Fix (kernel-only, ~40 lines; no SMF/UPF/go-gtp5gnl change):**
- `gtpu/encap.c`: new exported `gtp5g_fwd_ipv6_skb_by_pdr(skb, dev, pdr)` — does `skb_cow_head` for
  outer-header room, then forwards through the *given* PDR's FORW FAR via the existing
  `gtp5g_fwd_skb_ipv6()` + `gtp5g_xmit_skb_ipv6()` (both callable here; the former is `static` in
  encap.c). Takes ownership of the skb (transmits or frees). Works for any destination.
- `include/encap.h`: declaration + a `struct pdr;` forward declaration.
- `genl/genl_ra.c`: `#include "encap.h"`; replace the `dev_queue_xmit(ra_skb)` block with
  `gtp5g_fwd_ipv6_skb_by_pdr(ra_skb, dev, pdr)` (the PDR already resolved earlier in the handler).

Keeps the SMF round-trip and the `ff02::1` RA — both correct. A real router multicasts RAs to
`ff02::1`; the SMF is the right builder because it owns the prefix (IPv6 pools are per NSSAI/DNN in
`config/smfcfg.yaml` + UPF config). This makes the open5gs-style UPF-local re-architecture (TODO
Task B) unnecessary.

**Status:** ✅ **VERIFIED FIXED on `cn` 2026-07-08.** Deployed (mirrored 3 files, `make clean && make`,
reloaded `gtp5g.ko` with `ipv6_data_path=1`) and re-tested with the live OpenWRT/T-Mobile UE — the UE
obtained a global IPv6 address via SLAAC. The kernel-log signature `no PDR found for IPv6 ff02::1,
skip` is gone; the RA now takes the FORW path. Remaining: IPv6 ping still fails (separate open issue).

> `★ Insight ─────────────────────────────────────`
> "Injected successfully" was a false summit. `dev_queue_xmit()` returning 0 only means the packet
> was queued onto the netdev — the drop happened one layer deeper, in gtp5g's own TX path, where a
> second (destination-based) PDR lookup silently failed. When a success log sits *upstream* of the
> actual work, it will happily report success over a failure downstream of it. The fix is to not let
> the handler re-discover what it already knew.
> `─────────────────────────────────────────────────`

## Build / deploy notes learned today

- **Makefile staleness with the `replace` directive.** `NFs/upf/go.mod` has
  `replace github.com/free5gc/go-gtp5gnl => ../../../go-gtp5gnl`. The Makefile target `bin/upf` only
  depends on `.go` files under `NFs/upf`, so editing `go-gtp5gnl` (or gtp5g's Go side) does **not**
  trigger a rebuild → `make upf` prints "Nothing to be done". **Always `rm -f bin/<nf>` first**, then
  `make <nf>`. Go's own build cache then recompiles the changed replaced module.
- Which artifact to rebuild for each fix:
  - Fix 3 (genl_ra.h): rebuild **gtp5g.ko** (+ reload module).
  - Fix 3/4 (attr_ra.go, ra.go in go-gtp5gnl): rebuild **upf** (`rm -f bin/upf && make upf`).
  - Fix 5 (router_advertisement.go in smf): rebuild **smf** (`rm -f bin/smf && make smf`).
- The kernel `.ko` and the `go-gtp5gnl` compiled into `upf` must agree on command/attribute numbers —
  rebuild both together when the wire format changes.

---

## Current end-of-day state (2026-07-07 ~10:28)

- `Built Router Advertisement packet: 88 bytes, prefix=2001:db8:156::/64, src=fe80::1 dst=ff02::1` ✅
- `gtp5g_genl_inject_ra: Injecting RA packet (SEID=2, PDR_ID=11, UE=2001:db8:156::1, len=88)` ✅
- `RA packet injected successfully` (dev_queue_xmit returned 0) ✅
- **UE still has no global IPv6**, and the RS/RA exchange still repeats every ~2-4s ❌
  (that cadence = the UE re-soliciting because it never accepts a usable RA).

The clearest success signal will be the *silence*: once the UE accepts a valid RA and completes
SLAAC, the periodic RS/RA storm stops. It hasn't, so the RA is still not reaching or satisfying the
UE. Prime suspect: gtp5g not encapsulating the `ff02::1`-destined packet to this UE (multicast vs.
unicast) — to be confirmed by packet capture tomorrow (see `TODO_260707.md`).

---

## Reference file map

| Concern | File |
|---|---|
| gtp5g IPv6 gate | `gtp5g/src/gtp5g.c` (ipv6_data_path) |
| kernel RA handler | `gtp5g/src/genl/genl_ra.c` |
| RA netlink attrs (kernel) | `gtp5g/include/genl_ra.h` |
| gtp5g log levels | `gtp5g/include/log.h` |
| RA netlink attrs (go) | `go-gtp5gnl/attr_ra.go` |
| RA netlink request (go) | `go-gtp5gnl/ra.go` |
| UPF capability detect | `NFs/upf/internal/forwarder/gtp5g.go` |
| UPF RA HTTP server | `NFs/upf/internal/http/server.go`, `handler_ra.go` |
| SMF RA builder | `NFs/smf/internal/context/router_advertisement.go` |
| SMF RS-event handler | `NFs/smf/internal/context/sm_context.go` (HandleEventReport) |
| Known-good RA/RS captures | `my_logs/open5gs_cu_RA.txt`, `my_logs/open5gs_cu_RS.txt` |
