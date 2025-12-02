# UPF & gtp5g Crash Discussion (Nov 18, 2025)

## Context
- Issue: UPF/gtp5g URR NULL pointer crash after IPv6 implementation.
- Logs: `free5gc/dmesg-1.log` shows crash inside `gtp5g_genl_get_multi_usage_reports`.
- Recent changes: IPv6 feature (`free5gc` commit `50a7baf3a164` vs `cfe81d56c93a`).

## Key Points from Conversation
1. Crash RIP: `gtp5g_genl_get_multi_usage_reports+0x21b/0x410`.
2. Root cause: `seid_urrs[i]` remains NULL when fewer `GTP5G_URR_MULTI_SEID_URRID` TLVs arrive than advertised by `GTP5G_URR_NUM`.
3. Why mismatch happens: netlink messages can be truncated when exceeding ~16 KB body; IPv6 usage polls send larger batches, so the kernel sees a smaller number of TLVs even though `URR_NUM` retains the original count.
4. Fail path itself frees memory correctly, but there is no guard detecting the truncated request, so the NULL dereference happens before `goto fail`.
5. Recommended mitigations:
   - Validate that parsed TLV count matches `URR_NUM` and bail with `-EINVAL` if not.
   - Guard `if (!seid_urrs[i]) goto fail;` inside the loop.
   - Temporarily reduce `queryNumOnce` (batch size) in `free5gc/NFs/upf/internal/forwarder/gtp5g.go` to avoid hitting the netlink limit until kernel patch is applied.
6. Evidence snippet (disassembly) showing crash point:
   ```
   $ objdump -d gtp5g/gtp5g.ko
    000000000000a7b0 <gtp5g_genl_get_multi_usage_reports>:

    a9ba: 0f 84 b1 00 00 00     je     aa71 <gtp5g_genl_get_multi_usage_reports+0x2c1>
    a9c0: 4b 8b 04 f4           mov    (%r12,%r14,8),%rax
    a9c4: 48 8b 7d c0           mov    -0x40(%rbp),%rdi
    a9c8: 44 89 f3              mov    %r14d,%ebx
    a9cb: 8b 50 08              mov    0x8(%rax),%edx
    a9ce: 48 8b 30              mov    (%rax),%rsi
   ```
7. Suggested instrumentation: log parsed vs. declared `URR_NUM` to confirm truncation.

## Next Steps
- Apply kernel fix in `gtp5g/src/genl/genl_report.c` (validation + guard).
- Adjust UPF batching or monitor netlink size warnings.
- Re-test after patch; ensure no further NULL dereference occurs.


## Details

### Where Execution Fails

- Lines 248–262 of `gtp5g/src/genl/genl_report.c` iterate from `i = 0` to `i < urr_num` and immediately dereference `seid_urrs[i]->seid` / `seid_urrs[i]->urrid`.
- The crash log in `free5gc/dmesg-1.log:12-20` shows RIP at `gtp5g_genl_get_multi_usage_reports+0x21b` and the following bytes:

  ```
  4b 8b 04 f4  mov    (%r12,%r14,8),%rax   ; load seid_urrs[i]
  44 89 f3     mov    %r14d,%ebx
  <8b 50 08>   mov    0x8(%rax),%edx       ; load urrid → fault when %rax==0
  48 8b 30     mov    (%rax),%rsi          ; load seid
  ```

- `%rax` was zero at the time of the fault, so the `mov 0x8(%rax),%edx` instruction attempted to read from `NULL+0x8` (i.e., `seid_urrs[i]->urrid`).

### Why `seid_urrs[i]` Turns NULL

The parser earlier in the function is supposed to fill one entry per TLV:

```c
seid_urrs = kzalloc(sizeof(struct seid_urr *) * urr_num, GFP_KERNEL);
hdr = nla_next(hdr, &remaining);
while (nla_ok(hdr, remaining)) {
    switch (nla_type(hdr)) {
    case GTP5G_URR_MULTI_SEID_URRID:
        seid_urrs[i] = kzalloc(sizeof(struct seid_urr), GFP_KERNEL);
        err = parse_seid_urr(seid_urrs[i++], hdr);
        if (err) goto fail;
        break;
    }
    hdr = nla_next(hdr, &remaining);
}
```

This logic assumes the message contains at least `urr_num` nested TLVs. When only `M < urr_num` TLVs arrive, the loop finishes with `i = M`, leaving the tail of `seid_urrs[]` untouched (but still zeroed by `kzalloc`). Because the code never checks whether `i == urr_num`, the outer loop happily walks the entire array—including the NULL entries—and dies.

Illustration:

```
userspace says: URR_NUM=5
netlink delivers: only 3 TLVs
kernel array: [struct][struct][struct][NULL][NULL]
outer loop: i==3 → deref seid_urrs[3] → NULL crash
```

The cleanup section (`gtp5g/src/genl/genl_report.c:276-295`) is correct; it simply never runs because the dereference happens before we can `goto fail`.

### Temporary Guard / Proof

Add validation immediately after the parsing loop:

```c
parsed = i;
if (parsed != urr_num) {
    GTP5G_ERR(gtp ? gtp->dev : NULL,
              "multi_usage_reports truncated: URR_NUM=%u parsed=%u remaining=%d",
              urr_num, parsed, remaining);
    err = -EINVAL;
    goto fail;
}
```

This keeps the kernel alive and prints clear evidence whenever truncation occurs (`free5gc/dmesg-2.log:43` shows `URR_NUM=4 parsed=3 remaining=0`). Instrumentation also revealed the downstream PFCP failures that leave TEID 4 without a PDR, hence the `No PDR match` warnings in dmesg.

### Why TLV Counts Mismatch

Netlink is a flat byte stream. The “metadata” (`GTP5G_URR_NUM`) and the nested TLVs live side by side inside the same message. Userspace builds the request like this (see `free5gc/NFs/upf/internal/forwarder/gtp5g.go` and `github.com/kk-free5gc/go-gtp5gnl/report.go`):

1. Append fixed attributes (`GTP5G_LINK`, `GTP5G_NET_NS_FD`, `GTP5G_URR_NUM`, …).
2. Loop over every URR OID and append `GTP5G_URR_MULTI_SEID_URRID` TLVs under a nested attribute.

The kernel enforces an ~16 KB body limit per netlink message. When the payload exceeds that limit—e.g., after IPv6 batching increased the per-request size—the tail of the message is truncated. The fixed attributes survive because they appear at the start; some of the nested TLVs disappear because they sit at the end.

From the kernel’s point of view:

- `URR_NUM = 5` (still visible in the header).
- Attribute iteration finds only `parsed = 3` TLVs before `remaining` hits zero because the rest were cut off.
- Without additional checks, the code blindly trusts the header and dereferences five entries, even though only three were populated.

Reducing `queryNumOnce` (the userspace batch size) or chunking the TLVs across multiple messages keeps each request under the limit so `URR_NUM` always matches the actual payload.

## Nov 19 Status Update – Guarding + Observations

- We added the defensive instrumentation discussed above (validation + logging + NULL guard) to `gtp5g_genl_get_multi_usage_reports`.
- The kernel now emits a warning instead of crashing when netlink truncation occurs, and the handler returns `-EINVAL`. Evidence:

  ```
  [Wed Nov 19 08:08:55 2025] [gtp5g] gtp5g_genl_get_multi_usage_reports: WNC:multi_usage_reports truncated: URR_NUM=4 parsed=3 remaining=0
  ```
  (`free5gc/dmesg-2.log:43`)

- Because the above request is rejected, PFCP Create/Update PDR calls that rely on the missing usage reports fail with `invalid argument` / `no such file` (see `free5gc/free5gc-2.log:2463-2927`). Without those PDRs programmed, every subsequent GTP-U packet that reuses the same TEID hits the fallback log:

  ```
  upfgtp:[gtp5g] gtp1u_udp_encap_recv: No PDR match this skb : teid[4]
  ```
  (`free5gc/dmesg-2.log:4-37`)

- So the repeated `No PDR match...` lines are a *downstream effect* of the new guard: the kernel intentionally refused to build usage reports because the message was truncated, and the PFCP session never completes.

### Next Mitigation Step

To actually prevent the mismatch (as opposed to just catching it), user space must stop generating oversized netlink requests:

1. Reduce the batch size in `free5gc/NFs/upf/internal/forwarder/gtp5g.go` (and the helper in `github.com/kk-free5gc/go-gtp5gnl/report.go`) so that every netlink message fits comfortably below ~16 KB. Dropping `queryNumOnce` from the current IPv6-tuned value down to something like 32 or 64 URRs per message eliminates truncation immediately.
2. Longer term, add chunking so `URR_NUM` always equals the actual TLVs sent in each message, even if it takes multiple messages to cover all URRs.
3. Once batching is adjusted, rerun the IPv6 usage poll to confirm that:
   - No new `multi_usage_reports truncated` logs appear.
   - PFCP Create/Update PDR stop failing.
   - `gtp1u_udp_encap_recv` warnings disappear because the PDR for TEID 4 finally installs.

## How We Mapped the Crash Bytes

Several people asked how we produced the mnemonic `mov    (%r12,%r13,8),%rax` from the crash log. The process is:

1. Dmesg provides the crashing RIP offset and a raw byte window. Example (`free5gc/dmesg-1.log:12-20`):

   ```
   RIP: 0010:gtp5g_genl_get_multi_usage_reports+0x21b/0x410 [gtp5g]
   Code: ... 4c 39 75 c8 0f 84 b1 00 00 00 4b 8b 04 f4 48 8b 7d c0 44 89 f3 <8b> 50 08 48 8b 30 ...
   RAX: 0000000000000000 ...
   ```

   The byte inside `<>` is the one executing at the fault (`8b` → `mov r/m32,%edx`).

2. Look up the same function in the saved objdump (`free5gc/objdump-1.log:11175-11183`). Objdump already decoded each byte sequence:

   ```
   a9c0: 4b 8b 04 f4    mov    (%r12,%r14,8),%rax
   a9c4: 48 8b 7d c0    mov    -0x40(%rbp),%rdi
   a9c8: 44 89 f3       mov    %r14d,%ebx
   a9cb: 8b 50 08       mov    0x8(%rax),%edx   <− RAX was NULL → fault
   a9ce: 48 8b 30       mov    (%rax),%rsi
   ```

   Address `0xa7b0` is the start of the function, so `0xa9cb - 0xa7b0 = 0x21b`, matching the RIP offset in dmesg.

3. The lines just above the fault show how `%rax` was populated. At `a997` (`free5gc/objdump-1.log:11165-11170`), the code stores each parsed `struct seid_urr *` into `(%rax,%r14,8)`, so later loads from `(%r12,%r14,8)` are exactly `seid_urrs[i]`. With `%rax == 0` at the time of `8b 50 08`, the dereference of `seid_urrs[i]->urrid` faulted at offset `0x8`.

This cross-reference between the hex bytes in dmesg and the mnemonics in objdump is how we can explain each instruction in natural language.

## Summary of Current Fix Status

- Kernel side is guarded and now reports truncation instead of crashing.
- User-space batching still needs adjustment; otherwise PFCP cannot finish programming TEID 4, causing sustained `No PDR match` logs.
- SMF/PCF logs in `free5gc/free5gc-2.log` about IPv6 not being allowed on the `ims` DNN are unrelated to the gtp5g crash but should be addressed separately if IMS IPv6 is required.
