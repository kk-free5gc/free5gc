# GTP5G "No PDR match" Investigation – TEID Race & Inner-IP Pull Guard

**Date:** December 4, 2025  
**Issue:** Recurrent `No PDR match this skb : teid[2]` despite valid PDRs  
**Component:** `gtp5g` kernel module – instrumentation across `src/pfcp/pdr.c`, `src/gtpu/encap.c`, `src/proc.c`, `include/pdr.h`  
**Status:** ✅ FIXED and VERIFIED

---

## Issue Summary

During uplink ping tests the UPF kernel module logged bursts of:

```
upfgtp:[gtp5g] gtp1u_udp_encap_recv: No PDR match this skb : teid[2]
```

Even while PDR counters kept increasing and `/proc/gtp5g/pdr_dump` showed TEID 0x2 present. Subsequent testing after enabling verbose debugging uncovered sporadic `pskb_may_pull failed for inner IP` warnings followed by the same `No PDR match` line for TEID 0x4.

### Symptoms
- Appeared during steady ICMP traffic (ping via gNB)  
- Occurred in short bursts (1–2 seconds)  
- No PFCP Session Modification/Delete around the drop window  
- PDR hash dumps always reported the expected entries

---

## Investigation Timeline

1. **Hash instrumentation** – Added `/proc/gtp5g/pdr_dump` and per-lookup logging (bucket index, traversal count) to confirm whether the TEID bucket was empty. Result: bucket never empty; entries were still present when the lookup failed.
2. **Rehash tracing** – Logged every `hlist_del_rcu` / `hlist_add_*` in `pdr_update_hlist_table()` to look for races while rehashing. No unlink bursts coincided with the drop window.
3. **Failure point uncovered** – With extended logs, `pdr_find_by_gtp1u()` started printing:
   ```
   [gtp5g] pdr_find_by_gtp1u: WNC: … returning NULL - reason: pskb_may_pull failed for inner IP (hdrlen=24)
   ```
   Immediately followed by `No PDR match` for that TEID. So the lookup was aborting before even entering the TEID hash loop.
4. **Root cause** – In Issue #5 (October), we changed the guard to always pull `hdrlen + sizeof(struct ipv6hdr)` bytes so IPv6 TPDUs couldn’t crash the module. For IPv4 packets with short linear headroom (e.g., GTP-U header + small payload), that request exceeded the linearized portion even though the remaining data existed in frags. `pskb_may_pull` therefore failed and the lookup returned NULL.

---

## Root Cause

A **conservative inner-header guard** introduced earlier prevented crashes on fragmented IPv6 packets but inadvertently dropped valid IPv4 TPDUs:

```c
if (!pskb_may_pull(skb, hdrlen + sizeof(struct ipv6hdr))) {
    return NULL;  // causes No PDR match
}
```

- For IPv4 payloads we only need 20 bytes; forcing 40 bytes (sizeof(struct ipv6hdr)) made `pskb_may_pull` fail on packets whose linear headroom < 40 even though the rest of the payload was in frags.
- Once `pdr_find_by_gtp1u()` returned NULL, `gtp1u_udp_encap_recv()` simply logged `No PDR match` with the TEID even though the PDR was present.

---

## Fix

### Conditional Inner-Header Pull

We now pull minimally to determine the IP version and then pull the exact header size required.

```diff
@@
-    if (type == GTPV1_MSG_TYPE_TPDU) {
-        if (!pskb_may_pull(skb, hdrlen + sizeof(struct ipv6hdr))) {
-            return NULL;
-        }
-        ip_version = (*(u8 *)(skb->data + hdrlen)) >> 4;
-        if (ip_version == 4) {
-            iph = (struct iphdr *)(skb->data + hdrlen);
-        } else if (ip_version == 6) {
-            ip6h = (struct ipv6hdr *)(skb->data + hdrlen);
-        }
-    }
+    if (type == GTPV1_MSG_TYPE_TPDU) {
+        /* Step 1 – pull one byte to read the version nibble */
+        if (!pskb_may_pull(skb, hdrlen + 1)) {
+            GTP5G_WAR(NULL, "WNC: … version nibble … hdrlen=%u\n", hdrlen);
+            return NULL;
+        }
+
+        ip_version = (*(u8 *)(skb->data + hdrlen)) >> 4;
+
+        if (ip_version == 4) {
+            if (!pskb_may_pull(skb, hdrlen + sizeof(struct iphdr))) {
+                GTP5G_WAR(NULL, "WNC: … IPv4 header … hdrlen=%u need=%lu\n",
+                          hdrlen, hdrlen + sizeof(struct iphdr));
+                return NULL;
+            }
+            iph = (struct iphdr *)(skb->data + hdrlen);
+            inner_ipv4_src = iph->saddr;
+            inner_ipv4_dst = iph->daddr;
+        } else if (ip_version == 6) {
+            if (!pskb_may_pull(skb, hdrlen + sizeof(struct ipv6hdr))) {
+                GTP5G_WAR(NULL, "WNC: … IPv6 header … hdrlen=%u need=%lu\n",
+                          hdrlen, hdrlen + sizeof(struct ipv6hdr));
+                return NULL;
+            }
+            ip6h = (struct ipv6hdr *)(skb->data + hdrlen);
+            inner_ipv6_src = ip6h->saddr;
+            inner_ipv6_dst = ip6h->daddr;
+        } else {
+            GTP5G_WAR(NULL, "WNC: … unknown IP version[%u] …\n", ip_version);
+            return NULL;
+        }
+    }
```

**Files touched:** `src/pfcp/pdr.c` (lookup guard and diagnostics). Supporting instrumentation remains to aid future debugging.

### Supporting Instrumentation (already in tree)
- `/proc/gtp5g/pdr_dump` – dumps TEID hash contents with timestamps  
- Bucket-level warning: `WNC: NO PDR MATCH - TEID[…] bucket_was_empty[…] nodes_walked[…]`  
- Rehash logging: `WNC: PDR[…] hlist_del_rcu/hlist_add_* …`  
- `wnc_log_pdr_remove()` – logs every PFCP-driven delete (none seen during the issue)
- `pdr_find_by_gtp1u` lookup breadcrumbs:
  ```
  [gtp5g] pdr_find_by_gtp1u: WNC: pdr_find_by_gtp1u returning NULL - reason: pskb_may_pull failed for IPv4 header (hdrlen=24, need=64)
  [gtp5g] pdr_find_by_gtp1u: WNC: NO PDR MATCH - TEID[0x2] bucket_idx[23153] bucket_was_empty[0] nodes_walked[1]
  ```
  These identify *why* the lookup failed (missing PDI, TEID mismatch, SDF mismatch, or early guard failure) and whether the failure happened before entering the bucket traversal.
- UL/DL counter breadcrumbs from `gtp5g_fwd_skb_encap`, `gtp5g_fwd_skb_ipv4`, and `gtp5g_drop_skb_*`:
  ```
  [gtp5g] gtp5g_fwd_skb_encap: PDR (1) UL_PKT_CNT (183) UL_BYTE_CNT (14054)
  [gtp5g] gtp5g_fwd_skb_ipv4: PDR (2) DL_PKT_CNT (173) DL_BYTE_CNT (18019)
  [gtp5g] gtp5g_drop_skb_ipv4: PDR (2) DL_DROP_CNT (5)
  ```
  These let us correlate data-plane progress with lookup failures in real time (if the counters keep increasing while a “No PDR match” burst occurs, we know TEIDs are still present and the issue lies earlier in the pipeline).

#### How to capture `/proc/gtp5g/pdr_dump`

1. Ensure the module is loaded and `/proc/gtp5g/pdr_dump` exists:
   ```bash
   ls /proc/gtp5g/pdr_dump
   ```
2. Periodically dump the TEID hash into a log (example every 100 ms for 2 seconds):
   ```bash
   for i in {1..20}; do
       echo "=== $(date +%T.%N) ===" | tee -a pdr_hash.log
       cat /proc/gtp5g/pdr_dump | tee -a pdr_hash.log
       usleep 100000
   done
   ```
3. Correlate timestamps in `pdr_hash.log` with dmesg to prove whether the TEID entries were present during drop windows.

---

## Verification

- **Test case:** Continuous ping (ICMP) via gNB → UPF with `/proc/gtp5g/dbg` level 3, `printk_ratelimit` disabled.  
- **Before fix:** Bursts of `pskb_may_pull failed for inner IP` followed by `No PDR match` for TEID 0x2/0x4 despite valid PDRs.  
- **After fix:** No more `pskb_may_pull` warnings. TEID hash stays populated; uplink counters increase without drops.

Additional validation: triggered IPv6 TPDU (synthetic) to confirm the new guard still pulls 40 bytes and prevents the Issue‑5 crash. No regressions observed.

---

## Lessons Learned / Next Steps

1. **Instrumentation matters** – The extra `/proc` dump and bucket diagnostics allowed us to rule out hash races quickly and zero in on the early-exit path.
2. **Guard conservatively but conditionally** – Safety fixes (like unconditional IPv6 pulls) should be scoped to the specific condition; otherwise they introduce new failure modes.
3. **Keep logging hooks** – Leave the detailed diagnostics in place; they’re invaluable for future troubleshooting across TEID/PDR lifecycles.
4. **Most important** – The fastest way to track this issue is to add logs around the error. Do not assume that any code which previously ran successfully will still run successfully now; anything can happen. 

✅ **Status:** Fix deployed, no drops observed in repeated runs. Please keep `/proc/gtp5g/pdr_dump` handy for future field debugging.
