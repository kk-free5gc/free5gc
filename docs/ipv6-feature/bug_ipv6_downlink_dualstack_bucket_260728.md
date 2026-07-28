# IPv6 Downlink Fails for Dual-Stack UEs — Investigation Report

**Date:** 2026-07-28
**System:** free5gc core + custom gtp5g kernel module (branch `my-changes-v0.9.14`), live CN
**Status:** RESOLVED and validated on live hardware (2026-07-28). UE-initiated IPv6 ping
0% packet loss. Two gtp5g fixes (downlink bucket + uplink protocol re-tag) plus one UPF host
config change (IPv6 forwarding). See §7 (uplink fix) and §8 (verification results).

---

## 1. The one-paragraph summary

A phone (UE) that gets **both** an IPv4 and an IPv6 address (a "dual-stack" session) could send IPv6
traffic out fine, but **nothing could come back** over IPv6 — every reply was silently dropped inside
the UPF. IPv4 worked perfectly. The cause was a filing mistake deep in the packet-forwarding kernel
module: the rule that tells the UPF "packets for this phone's IPv6 address go down this tunnel" was
**filed in the wrong drawer**, so when a reply arrived, the UPF looked in the IPv6 drawer, found
nothing, and threw the packet away.

---

## 2. Plain-language explanation (no networking background needed)

### The setup
- A **UE** is the phone/device.
- The **UPF** (User Plane Function) is the part of the mobile core that actually moves user data
  packets. Think of it as the **post office** for the phone's internet traffic.
- The UPF runs a small piece of software inside the Linux kernel called **gtp5g** that does the
  fast packet forwarding.
- A modern phone often gets **two addresses at once**: an old-style **IPv4** address (e.g.
  `10.122.0.2`) and a newer **IPv6** address (e.g. `2001:db8:122:1:5c15:...`). Having both at the
  same time is called **dual-stack**.

### What worked and what didn't
- The phone could **send** IPv6 packets to the internet. ✅
- The phone could send **and receive** IPv4 packets. ✅
- But the phone could **never receive** IPv6 packets — pings and replies just vanished. ❌

### The analogy: a post office with two sorting walls
Imagine the UPF post office has a big wall of numbered **mailboxes** to sort deliveries quickly.
When a new phone connects, the post office writes a **delivery slip** that says *"anything addressed
to this phone goes into tunnel #X toward the phone."* It files that slip in a mailbox chosen by the
phone's address.

The problem: a **dual-stack** phone has *two* addresses (IPv4 and IPv6), but the post office wrote
**one** delivery slip and could only file it in **one** mailbox. The filing rule said *"if there's an
IPv4 address, file it in the IPv4 section"* — so the slip always went into the **IPv4 mailbox**.

Now a reply for the phone's **IPv6** address arrives. The clerk computes which mailbox it should be
in (the **IPv6** section), opens that box... and it's **empty**. The delivery slip is sitting over in
the IPv4 section, where the IPv6 clerk never looks. With no slip, the clerk doesn't know which tunnel
to use, so the packet is **discarded**. That is exactly why IPv6 replies disappeared while IPv4 (whose
slip *was* in the right box) worked fine.

### The fix in plain terms
Give the delivery slip a **second copy** and add a **second wall of mailboxes just for IPv6**. Now the
dual-stack phone's slip is filed in **both** the IPv4 section *and* the IPv6 section at the same time,
so whichever kind of reply arrives, the clerk finds the slip and delivers it.

---

## 3. Technical explanation (for engineers)

### 3.1 Components and data flow
- Downlink packets destined to a UE are transmitted on the `upfgtp` netdev. Its `.ndo_start_xmit`
  is `gtp5g_dev_xmit()` → `gtp5g_handle_skb_ipv6()` → `pdr_find_by_ipv6()`.
- PDRs are indexed in several hash tables inside `struct gtp5g_dev`:
  - `i_teid_hash` — keyed by GTP-U TEID (uplink), via `struct pdr.hlist_i_teid`.
  - `addr_hash` — keyed by UE address (downlink), via `struct pdr.hlist_addr`.
- `hash_size = 131072` buckets. Each bucket is an `hlist_head`; PDRs are chained via their embedded
  `hlist_node` hooks. A single `struct pdr` is threaded into multiple tables simultaneously, one
  `hlist_node` per table — **but it has only one `hlist_addr` hook, so it can occupy only one
  address bucket.**

### 3.2 The trigger: dual-stack (IPv4v6) session
`config/smfcfg.yaml` — the `internet` DNN (which owns the UE's `2001:db8:0122::/48` pool):
```yaml
pduSessionTypes:
  defaultSessionType: IPV4V6
pools:      - cidr: 10.122.0.0/16          # IPv4
ipv6Pools:  - prefix: 2001:db8:0122::/48   # IPv6
```
Live UE confirmation:
```
inet  10.122.0.2/30
inet6 2001:db8:122:1:5c15:526:8ddd:afde/64
```
So the **downlink PDR carries both** `ue_addr_ipv4` and `ue_addr_ipv6`.

### 3.3 The bug: single-bucket insert with IPv4 priority
`src/pfcp/pdr.c`, `pdr_update_hlist_table()` (the only path that files a PDR into `addr_hash`):
```c
if (f_teid) {
    // uplink → i_teid_hash via hlist_i_teid
} else if (pdi->ue_addr_ipv4) {
    // → addr_hash[ u32_hashfn(v4) ]  via hlist_addr     // dual-stack lands HERE
} else if (pdi->has_ue_ipv6) {
    // → addr_hash[ ipv6_prefix64_hashfn(v6) ]  via hlist_addr   // NEVER reached for dual-stack
}
```
Because it's an `else if` chain and the dual-stack PDR has a v4 address, it is filed **only** in the
IPv4 bucket. The IPv6 branch never runs.

The downlink IPv6 resolver hashes by the IPv6 /64 and looks in a **different** bucket:
```c
// pdr_find_by_ipv6()
head = &gtp->addr_hash[ ipv6_prefix64_hashfn(addr) % gtp->hash_size ];
hlist_for_each_entry_rcu(pdr, head, hlist_addr) { ... }   // bucket is empty → returns NULL
```

### 3.4 Observed symptom chain
```
gtp5g_dev_xmit()  (packet reaches upfgtp)
  └─ gtp5g_handle_skb_ipv6()
       └─ pdr_find_by_ipv6()  → NULL
     "WNC: no PDR found for IPv6 2001:0db8:0122:0001:5c15:0526:8ddd:afde, skip"
       └─ return -ENOENT
  └─ ret < 0  → goto tx_err:  (dev->stats.tx_errors++, dev_kfree_skb)   // SILENT drop
```
Evidence gathered live:
- `ip -s link show upfgtp` → `TX: ... errors 8` (silent drops, no log unless `dbg >= 3`).
- `dmesg` at `dbg=4` → repeated `gtp5g_handle_skb_ipv6: WNC: no PDR found for IPv6 ...`.
- `gogtp5g-tunnel list pdr` → every PDR has `UEAddrIPv6PrefixLen: 64` (our prefix plumbing is correct).
- Uplink works: `pdr_find_by_gtp1u` matched the UE's SLAAC privacy IID via the /64 mask and forwarded
  (`UL_PKT_CNT` incrementing) — so the earlier SLAAC/64 work is validated; this is a *separate* bug.

### 3.5 Why it hid until now
IPv6 downlink was broken in **two independent** ways:
1. gtp5g matched the exact `/128` (the SMF-assigned `::2`) while the UE used a SLAAC privacy IID —
   fixed by the earlier "unique /64 + /64 masked match" work.
2. **This bug** — dual-stack PDR filed in the IPv4 bucket, invisible to the IPv6 lookup.

Fixing #1 was necessary but not sufficient; it moved the failure downstream and exposed #2. Note #2
would have dropped IPv6 downlink even for the exact `::2` address, because the bucketing is wrong
regardless of the match width.

---

## 4. The fix (approach A — dedicated IPv6 address hash)

Give IPv6 its own hook **and** its own hash table so a dual-stack PDR is indexed by both families at
once. A separate table (not a second hook in the same `addr_hash`) is required: mixing two
`hlist_node` types in one bucket would make `hlist_for_each_entry_rcu()` compute the wrong
`container_of()` offset and corrupt memory.

| # | Site | Change |
|---|------|--------|
| 1 | `include/pdr.h` `struct pdr` | add `struct hlist_node hlist_addr_ipv6;` |
| 2 | `include/dev.h` `struct gtp5g_dev` | add `struct hlist_head *addr6_hash;` |
| 3 | `src/gtpu/dev.c` | alloc + `INIT_HLIST_HEAD` loop + free (×2) for `addr6_hash`, mirroring `addr_hash` |
| 4 | `src/pfcp/pdr.c` insert | `if(f_teid){} else { if(v4) →addr_hash/hlist_addr; if(v6) →addr6_hash/hlist_addr_ipv6; }` so dual-stack is filed in **both** |
| 5 | `src/pfcp/pdr.c` `pdr_find_by_ipv6` | iterate `gtp->addr6_hash[...]` via `hlist_addr_ipv6` |
| 6 | `src/pfcp/pdr.c` delete + rehash | also unlink `hlist_addr_ipv6` (same `hlist_unhashed` guard) |

**Preserved / fixed:**
- ✅ Fixes IPv6 downlink for dual-stack **and** IPv6-only sessions.
- ✅ IPv4 downlink unchanged (`addr_hash` / `hlist_addr`).
- ✅ Uplink unchanged (`i_teid_hash`).
- ✅ RS/RA/NS/NA/DAD path unchanged.
- ✅ No SMF / control-plane change.

**Rejected alternative (approach E — SMF split-PDR):** have the SMF emit separate single-family
downlink PDRs. Larger blast radius (changes PDU-session establishment for every session, duplicates
FAR/QER wiring) and leaves the kernel bucketing bug latent. Not chosen.

---

## 5. How to reproduce / verify on the CN (operator runbook)

Exact commands used for the 2026-07-28 validation. `<gtp5g>` =
`/home/wnc/Downloads/free5gc_use_open5gs_ipv6/gtp5g`, `rmnet_dataX` = the UE's modem interface.

**Step 1 — build the module on the CN** (kernel 5.15, so it MUST be compiled there — do not copy a
`.ko` built on another kernel):
```bash
cd <gtp5g> && make clean && make
```

**Step 2 — reload the module and re-attach the UE** (reload wipes gtp5g state, so the PDU session
must be re-established afterwards):
```bash
sudo rmmod gtp5g && sudo insmod gtp5g.ko ipv6_data_path=1     # or: sudo make install && sudo modprobe gtp5g
echo 4 | sudo tee /proc/gtp5g/dbg                             # match/miss logs (GTP5G_INF = level 3)
```

**Step 3 — UPF host config (REQUIRED for IPv6 data path)** — enable IPv6 forwarding (IPv4 already had
`ip_forward=1`); make it persistent:
```bash
sudo sysctl -w net.ipv6.conf.all.forwarding=1
echo 'net.ipv6.conf.all.forwarding=1' | sudo tee /etc/sysctl.d/99-upf-ipv6-forward.conf
```

**Step 4 — add a data-network test target on the CN loopback** (NOT on `upfgtp` — an address on the
tunnel device causes local-delivery loops; `lo` gives a clean DN endpoint the UE can reach):
```bash
sudo ip -6 addr add 2001:db8:babe::1/128 dev lo
```

**Step 5 — capture on the CN** (packets are GTP-U-encapsulated on the physical/any interface, so filter
on UDP/2152 and dissect the inner ICMPv6):
```bash
sudo dmesg -C
sudo tshark -i any -f "udp port 2152" -Y "icmpv6"
```

**Step 6 — UE-initiated ping** (the acceptance test):
```bash
# on the UE:
ping -6 2001:db8:babe::1 -I rmnet_dataX -c 4
```

**Expected:** UE reports 0% loss; tshark shows matched Echo request (up) + reply (down) pairs;
`dmesg | grep -iE 'Match PDR ID|within UE'` shows `pdr_find_by_ipv6: … within UE /64` on downlink;
`nstat -az | grep IpInHdrErrors` stops climbing.

**Step 7 — cleanup** (optional, after testing):
```bash
echo 1 | sudo tee /proc/gtp5g/dbg          # back to Error level
sudo ip -6 addr del 2001:db8:babe::1/128 dev lo
```

**Regression to confirm:** IPv4 ping still works (UE has a `10.122.x.x` address); SLAAC/RA still brings
the UE up (RS→RA visible in the same tshark capture); a second UE would get a distinct `/64`.

---

## 6. Debugging notes worth keeping

- `GTP5G_INF` = `DBG(3, ...)`. Match/miss logs are invisible unless `/proc/gtp5g/dbg >= 3`. A fresh
  `insmod` defaults low — set `echo 4 > /proc/gtp5g/dbg` **before** testing.
- Read PDRs via `/proc/gtp5g/pdr_dump` (readable). `/proc/gtp5g/pdr` returns EPERM (it is a
  write-trigger, not a dump).
- `2001:db8::/32` is RFC 3849 **documentation** space — not globally routable. Pinging public targets
  (e.g. `2001:4860:4860::8888`) can never get a reply from a `2001:db8:` source; use a DN-local target
  or a CN↔UE ping to exercise downlink.
- `2001:db8:126::1` is the UPF's **own** `upfgtp` gateway address — a poor downlink test target.
- The `tx_err:` path in `gtp5g_dev_xmit()` drops **silently** (bumps `tx_errors`, no log). Watch
  `ip -s link show upfgtp` when a datapath drop is suspected.

---

## 7. Second bug found during validation — IPv6 uplink mis-tagged as IPv4

After the downlink bucket fix, IPv6 **downlink** reached the UE (proven: CN→UE ping showed
`pdr_find_by_ipv6: Match PDR ID:2 … within UE /64` and the UE replied). But a **UE-initiated**
IPv6 ping still got no reply — the request reached the UPF, yet the host never answered.

### Plain language
When the UPF unwraps a packet coming *up* from the phone, it hands the inner packet to the Linux
network stack with a little label saying "this is IPv4" — because the outer tunnel wrapper is IPv4.
For an IPv4 inner packet that label is correct (which is why IPv4 always worked). For an **IPv6**
inner packet the label is a lie: Linux gives it to the IPv4 handler, which looks at it, sees it isn't
a valid IPv4 packet, and throws it away. So the phone's IPv6 traffic never reached the data network,
and no reply was ever created.

### Technical
- `gtp5g_fwd_skb_encap()` (uplink) strips the GTP-U/UDP headers and re-injects the inner packet with
  `netif_rx()`. The N3 GTP-U transport is IPv4, so `skb->protocol` stays `ETH_P_IP` and is never
  updated to the inner family. `ip_rcv()` then rejects the inner IPv6 packet (version ≠ 4).
- Confirmed live via `nstat`: `IpInHdrErrors` climbing (1317) while `Ip6InHdrErrors` stayed 0 — the
  inner IPv6 packets were being fed to the IPv4 stack and dropped.

### Fix (gtp5g commit `795de92`)
- In `gtp5g_fwd_skb_encap()`, after `skb_reset_network_header()`, read the inner IP version nibble
  (`skb->data[0] >> 4`) and set `skb->protocol` to `ETH_P_IPV6`/`ETH_P_IP` before `netif_rx()`.

### Host config (not code) — required on the UPF
- `net.ipv6.conf.all.forwarding` was `0` while `net.ipv4.ip_forward` was `1`. That asymmetry meant the
  UPF routed IPv4 user traffic but not IPv6. Enable IPv6 forwarding and persist it:
  ```
  sudo sysctl -w net.ipv6.conf.all.forwarding=1
  echo 'net.ipv6.conf.all.forwarding=1' | sudo tee /etc/sysctl.d/99-upf-ipv6-forward.conf
  ```

---

## 8. Verification results (2026-07-28, live CN)

Full end-to-end fix chain (all four had to line up):

| Layer | Fix |
|-------|-----|
| SMF | unique /64 per UE, fixed `::2` IID (`smf b29ab37`) |
| gtp5g uplink match | UE /64 masked compare (`gtp5g 0fab710`) |
| gtp5g downlink bucket | dedicated IPv6 /64 hash, `addr6_hash` + `hlist_addr_ipv6` (`gtp5g 444d995`) |
| gtp5g uplink delivery | re-tag `skb->protocol` from inner IP version (`gtp5g 795de92`) |
| UPF host | `net.ipv6.conf.all.forwarding=1` |

**UE-initiated ping (the acceptance test)** — UE → `2001:db8:babe::1` (test addr on CN `lo`):
```
4 packets transmitted, 4 packets received, 0% packet loss
round-trip min/avg/max = 11.620/12.625/14.473 ms
```
`tshark -i any -f "udp port 2152" -Y "icmpv6"` on the CN showed matched request/reply pairs inside
the GTP-U tunnel:
```
2001:db8:122:1:e09d:1b6:507b:e947 → 2001:db8:babe::1              Echo request  seq 0-3
2001:db8:babe::1                  → 2001:db8:122:1:e09d:1b6:507b:e947  Echo reply    seq 0-3
```

**Regression (same capture):** the RS → RA exchange (`fe80::2 → ff02::2` Router Solicitation,
`fe80::1 → fe80::2` Router Advertisement) confirms SLAAC/RA and the RS/RA/NS/NA/DAD path are intact.
IPv4 (UE `10.122.0.2`) worked throughout.

**Downlink resolver, before vs after (dmesg):**
- Before: `gtp5g_handle_skb_ipv6: WNC: no PDR found for IPv6 2001:db8:122:1:… , skip`
- After:  `pdr_find_by_ipv6: WNC: Match PDR ID:2 (IPv6 dst 2001:db8:122:1:… within UE /64)`

**Not covered:** two-UE distinct-/64 disambiguation (no second UE available at test time); the
unique-/64 allocator is unit-tested in the SMF and a second UE would receive subnet index 2.
