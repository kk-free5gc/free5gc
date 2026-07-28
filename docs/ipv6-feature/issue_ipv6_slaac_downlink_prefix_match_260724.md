# IPv6 SLAAC Downlink Fails — Exact /128 UE Match vs. Privacy Address (Investigation & Design Options)

**Date:** 2026-07-24
**Status:** Investigation complete, root cause proven. **Approach 2 CHOSEN.** Concrete design drafted (§10). Awaiting user sign-off on two small specifics (§11), then spec finalization + implementation plan. **No code written yet.**
**Components in scope:** SMF (IPv6 pool allocator, PDR build), go-upf, go-gtp5gnl, gtp5g kernel module.
**Related prior work:** `issue_ra_injection_slaac_fixes_260707.md`, `issue_link_local_ipv6_neighbor_discovery_support_251209.md`, `issue_router_solicitation_monitoring_fix_251209.md`, `phase_3_implementation_consolidated.md`.

---

## 1. Symptom

UE (an OpenWrt device) attaches and receives IPv4 + IPv6 addresses on three PDU sessions. Test results:

- **IPv4 works:** `ping 8.8.8.8 -I rmnet_data0` → replies received (captured on CU as GTP/ICMP request + reply).
- **IPv6 fails:** neither `ping -6 2001:db8:122::1` (thought to be the CN gateway) nor `ping -6 2001:4860:4860::8888` (Google DNS) gets a reply.

The user's refined observation (decisive): **the ICMPv6 echo request reaches the CN, but the CN produces no reply.** The user correctly noted the internet ping can't work (no global IPv6 uplink) but expected the gateway ping to succeed. Decision taken during triage: **keep IPv6 internal to the core for now** (no routable prefix / NAT66 work).

---

## 2. Two red-herring test targets (ruled out first)

### 2a. `ping -6 2001:db8:122::1` — address collision
The UE's OpenWrt reuses the WAN /64 on its LAN bridge:

```
br-lan       inet6 2001:db8:122::1/64          # LAN bridge
rmnet_data0  inet6 2001:db8:122:0:...:9022/64  # modem/WAN (SLAAC)
upfgtp (CN)  inet6 2001:db8:122::1  prefixlen 48   # UPF gateway
```

Both the **UE's br-lan** and the **UPF gateway** hold `2001:db8:122::1`. When the UE pings it, RFC 6724 source selection picks `br-lan`'s `::1`, so the packet is `src==dst==2001:db8:122::1`. The UPF receives a packet to its own address and any "reply" loops back to itself → the UE never sees a reply. **Not a data-path bug — an address duplication on the UE side.** (Root cause: OpenWrt reusing the delegated /64 on br-lan with `::1`; proper fix is DHCPv6-PD or a distinct LAN prefix on the UE.)

### 2b. `ping -6 2001:4860:4860::8888` — unroutable source + no uplink
`2001:db8::/32` is the RFC 3849 **documentation prefix**, not globally routable, and the CN has no IPv6 uplink / NAT66. Expected to fail; tells us nothing about the core. Acknowledged and deferred.

### 2c. The clean test
`ping -6 2001:db8:126::1 -I rmnet_data0` isolates the data path:
- `2001:db8:126::1` is the **vzwadmin** DNN gateway — it lives on the UPF's `upfgtp` but on **no** UE interface (no collision).
- Source becomes `rmnet_data0`'s unique global `2001:db8:122:0:e1cb:db04:ef07:ab8f` (RFC 6724 Rule 5).
- Destination is a **local** address on the UPF, so a reply needs **no** forwarding/NAT/routable prefix — purely "can a UE packet reach a CN address and get a reply back down the tunnel?"

**Result: request reaches CN, no reply.** This is the real bug.

---

## 3. Root cause (proven at every layer)

**The UPF matches downlink IPv6 on the UE's exact /128 address, but the UE uses a SLAAC privacy address the network never assigned.**

Evidence chain:

| Layer | Behavior | Location |
|---|---|---|
| SMF | Allocates UE IID `::2`; sets DL PDR `UEIPAddress = 2001:db8:122::2` with `Ipv6d=true`, `Ipv6PrefixDelegationBits=64` | `NFs/smf/internal/context/datapath.go:1009-1014`; log `WNC: Allocated IPv6: 2001:db8:122::2` |
| go-upf | Installs `PDI_UE_ADDR_IPV6 = 2001:db8:122::2` as a **bare 16-byte address**; the prefix-length hint is **discarded** (no mask attr) | `NFs/upf/internal/forwarder/gtp5g.go:602-607` |
| go-gtp5gnl | `PDI_UE_ADDR_IPV6` is a 16-byte address with **no mask/prefix companion attribute** | `go-gtp5gnl/attr_pdr.go:84,113` |
| gtp5g kernel (downlink) | `pdr_find_by_ipv6()` hashes the **full** dst addr and compares with `ipv6_addr_equal` (exact /128) | `gtp5g/src/pfcp/pdr.c:916-940`; called from `src/gtpu/encap.c:1244` |
| gtp5g kernel (uplink) | `pdr_find_by_gtp1u()` matches TEID first, then `global_match = ipv6_addr_equal(saddr/daddr, ue_addr_ipv6)` (exact /128), plus link-local / solicited-node-multicast / unspecified cases for RS/RA/NS/NA/DAD | `gtp5g/src/pfcp/pdr.c:638,796-838` |

The UE's actual global address is `2001:db8:122:0:e1cb:db04:ef07:ab8f` — a **SLAAC privacy IID** (RFC 4941/7217). The network-assigned `::2` is used only for the link-local; the modem invents its own IID for the global address (as virtually all modems do).

- **Downlink:** reply's dst = `...e1cb...` ≠ stored `::2` → `pdr_find_by_ipv6` doesn't match (wrong hash bucket *and* exact compare fails) → dropped before GTP encapsulation. This is why the N3 capture (GTP/ICMPv6, i.e. still-encapsulated) shows the request but no reply.
- **Uplink:** same `::2` vs `...e1cb...` mismatch in `pdr_find_by_gtp1u`'s `global_match`. Uplink still traverses to the CN NIC because the capture is on N3 **before** gtp5g processing; whether gtp5g actually accepts it depends on the same exact-match. Either way the bug is symmetric.

### Why IPv4 works but IPv6 doesn't
For IPv4 the network **assigns** `10.122.0.2` and the UE uses exactly that — the exact `/32` PDR match succeeds. For IPv6 SLAAC the network legitimately owns only the **/64 prefix**; the interface-ID is the UE's to choose (and privacy extensions rotate it). Exact `/128` matching is architecturally wrong for SLAAC.

### Connection to the earlier RA fix (confirmed via git)
Commit `5300212` ("complete IPv6 SLAAC data path") is where exact matching was cemented. Its own message says *"the downlink resolver `pdr_find_by_ipv6()` only matches a UE's exact global address."* That commit extended matching to also accept UE **link-local**, **solicited-node multicast**, and **unspecified source** so RA/RS/NS/NA/DAD would work — necessary to get RA delivered so SLAAC could start. It did **not** handle the consequence of SLAAC: once the UE runs SLAAC it invents its own IID, so the assigned `::2` is no longer what the UE uses. The RA fix got the address *to* the UE; it didn't make the return path match what the UE then chose. Notably, that commit **already added a masked helper** `ipv6_match(target, match, mask)` — but wired it only to **SDF filters** (`pdr.c:576-580`), not to the UE-address match. The tool to fix this is already in the tree.

---

## 4. The deeper, coupled defect: shared /64 across UEs

The SMF IPv6 allocator writes the allocation index into the **interface-ID bits**, not the prefix bits:

```go
// NFs/smf/internal/context/ue_ip_pool.go : poolIndexToIP(), uePrefixLength <= 64
binary.BigEndian.PutUint64(ip[8:16], index)   // index -> IID; prefix (bytes 0-7) stays fixed
```

Config intent confirms this — `smfcfg.yaml` uses `iidAllocation: random`:

```yaml
ipv6Pools:
  - prefix: 2001:db8:0111::/48
    uePrefixLength: 64
    iidAllocation: random      # hands out a random IID inside ONE /64
    exclude: ["2001:db8:0111::1"]
```

**Consequence:** every UE on a DNN shares the *same* /64 (`2001:db8:PREFIX:0::/64`) and differs only by IID; the other 65,535 /64s of the /48 go unused. The RA advertises that shared /64 (`GetIPv6PrefixFromAddress(PDUAddressIPv6, /64)`, `sm_context.go:1651,1668`) to every UE.

So there are **two coupled defects**:
1. gtp5g matches the exact /128 instead of the UE's prefix.
2. the SMF allocator gives every UE the *same* /64 instead of a unique one.

Fixing only (1) makes the single-UE case work but leaves a **multi-UE ambiguity**: two UEs in one shared /64 cannot be disambiguated by prefix — the core has no deterministic `/64 → tunnel` mapping.

---

## 5. The correct model (3GPP / real-world)

Per 3GPP TS 23.501 §5.8.2.2 (inherited from TS 29.061): **each PDU session is assigned its own unique /64 prefix.** The UE forms its IID within *that dedicated /64* (assigned IID, or SLAAC/privacy random). Because the UE owns the whole /64, the core routes the **entire /64** to that UE's tunnel and never inspects the IID.

### The postman analogy (corrected)
- **/64 = a house; IID = a name on the mailbox.**
- **One /64 = one PDU session = one UE (one tunnel).** A UE's several addresses (stable + rotating privacy) are **one resident with several nicknames** — all delivered to the same UE, which sorts them in its own stack. No sender-side ambiguity.
- On the wire: a packet to any address in the UE's /64 is routed onto that UE's **point-to-point** GTP tunnel (one peer) — no neighbor-discovery choice to make. The UE accepts it if it matches any of its configured addresses.
- **Genuinely different devices** (LAN clients behind the OpenWrt router) = the UE acting as a **router**: the core routes the whole prefix to the UE, and the *UE-router* runs Neighbor Discovery on its own LAN to reach each device — exactly like a home router. The clean 3GPP mechanism for this is **DHCPv6 Prefix Delegation** (core delegates a shorter prefix, e.g. /60; router carves /64s per LAN). The IPv6 twin of IPv4 NAT: the ISP delivers to your router; your router delivers to devices.
- **Why shared-/64-across-UEs breaks:** two independent tunnels both claim addresses in one /64, and the core has no deterministic `/64 → tunnel` mapping — it would have to guess which tunnel owns a given IID, which is exactly the information it doesn't have. That is the current code's flaw and the whole reason exact-/128 matching (and the temptation of "address learning") ever arose.

### Key insights
- "Assign a /64 and let the UE choose its IID" is correct — the subtlety is **one /64 per UE**, which is what makes IID choice safe and routing trivial.
- Core-side, the only mapping needed is `/64 → tunnel` (deterministic, 1:1 with unique /64s). It never needs `IID → device`.
- UE-side, `IID → socket` (single UE) or `address → LAN device` (UE-as-router via ND) resolution is the UE's job. The core is deliberately not involved.

---

## 6. Candidate approaches

### Approach 1 — gtp5g /64 prefix-match only (minimal)
Change the two downlink resolvers in gtp5g to mask the UE address to its /64 before hashing **and** comparing; plumb the prefix length (SMF already sends `Ipv6PrefixDelegationBits=64`) through go-upf → a new netlink attr → kernel. Leave `pdr_find_by_gtp1u`'s link-local / multicast / unspecified cases untouched (RS/RA safe).
- **Touches:** gtp5g kernel (`pdr.c`, `pdr.h`, `genl_pdr.c`, `include/genl_pdr.h`), go-gtp5gnl (`attr_pdr.go`), go-upf (`gtp5g.go`).
- **Pros:** fixes the current single-UE test fastest; small, isolated; RS/RA path untouched.
- **Cons:** with the shared-/64 allocator still in place, **two UEs on the same DNN would collide** in one /64 → downlink can match the wrong session. Correct only for effectively one-UE-per-DNN.

### Approach 2 — unique /64 per UE + gtp5g prefix-match (3GPP-correct) — *recommended*
Approach 1 **plus** fix the SMF allocator so each PDU session gets a distinct /64 from the /48 (write the index into the subnet bits, not the IID). Each UE owns its /64; SLAAC picks any IID; the UPF routes the unique /64 unambiguously.
- **Touches:** SMF allocator (`ue_ip_pool.go` index↔IP mapping, pool sizing), RA prefix derivation (already uses the address's /64, so mostly follows), plus all of Approach 1.
- **Pros:** matches real commercial-core behavior; robust for many UEs; no per-address learning/churn; uses the /48 the standard way (up to 65,536 UEs, each with its own /64).
- **Cons:** larger change; must review pool sizing, the PDU Address IE / assigned-IID behavior, and `ipv6StaticPools`.
- **Same-/48, finer granularity:** the `exclude`/gateway logic and `fe80::1` router stay; only allocation granularity changes from IID to /64.

### Approach 3 — dynamic address learning (rejected)
Keep exact /128 matching but learn the UE's real SLAAC address (from uplink source / NS) and rewrite the downlink PDR to it.
- **Why rejected (plainly):**
  1. **The UE never announces its global address.** SLAAC just starts using an IID; the UPF would have to **snoop uplink source addresses** — a hack, not a protocol.
  2. **First-packet race:** until the UE sends uplink, downlink is dropped; network-initiated traffic fails.
  3. **Privacy addresses rotate and multiply:** RFC 4941 temporaries change on a timer and a UE holds several valid addresses at once → a PDR per address, added/expired constantly. Prefix routing handles all of them for free.
- It *feels* real because "the UE picks its own IID" is real — but the real mechanism that supports that is **per-/64 routing (Approach 2)**, not learning. Real cores do not learn UE IIDs.

### Approach 1-then-2 (staged)
Ship the minimal prefix-match now to unblock single-UE testing; open a follow-up spec for the unique-/64 allocator.

---

## 7. Hard constraints for any fix
- **Must NOT disturb the working RS/RA/NS/NA/DAD path.** That logic lives in `pdr_find_by_gtp1u` (uplink resolver) and the SEID+PDR_ID RA-injection path (`genl_ra.c`) — it accepts UE link-local, solicited-node multicast, and unspecified source. The fix should **only add** a "destination within the UE's /64" acceptance case; do not remove or reorder the existing cases. (`ipv6_match()` mask helper already exists for reuse.)
- Kernel rebuild + reload of `gtp5g.ko` on the CN is acceptable (confirmed).
- Match width should come from the value the SMF already sends (`Ipv6PrefixDelegationBits`, currently 64), with a /64 fallback — not a hardcoded constant.
- `NFs/upf` go.mod / go.sum edits are intentionally left uncommitted (per repo convention) — don't flag them.

## 8. The two gtp5g code sites to change (for reference)
- **Downlink:** `pdr_find_by_ipv6()` (`pdr.c:916`) — hash by /64 prefix at **both** lookup (`:923`) and insert (`:1029`), and replace `ipv6_addr_equal` (`:930`) with a masked compare.
- **Uplink:** `pdr_find_by_gtp1u()` (`pdr.c:638`) — change `global_match` (both `is_uplink` saddr branch `:798` and `is_downlink` daddr branch `:820`) to a masked /64 compare; keep `ll_match` / `unspec_match` / `sn_multicast_match` intact.
- **Plumbing:** add a UE-IPv6 prefix-length netlink attr (append at end of the `GTP5G_PDI_*` enum to avoid renumbering — renumbering caused pain before), mirror it in `go-gtp5gnl`, and emit it from `go-upf` using the PFCP `Ipv6PrefixDelegationBits` (fallback 64).

---

## 9. Decision (RESOLVED)
- [x] **Approach 2** — unique /64 per UE + gtp5g /64 prefix-match (3GPP-correct). **CHOSEN by user on 2026-07-24.**
- [ ] ~~Approach 1 (prefix-match only)~~
- [ ] ~~Approach 1 then 2 (staged)~~

---

## 10. Concrete design for Approach 2 (drafted, pending final sign-off)

Five components change. Components 3–5 are the prefix-match plumbing (shared with Approach 1); Component 1 is the "unique /64 per UE" allocator.

### Component 1 — SMF allocator: unique /64 per UE — `NFs/smf/internal/context/ue_ip_pool.go`
The allocatable unit becomes a **/uePrefixLength block** carved from the pool's **/poolPrefixLength** prefix, instead of an IID inside one shared /64.
- **`calcIPv6AddrRange`**: count = `2^(uePrefixLength − poolPrefixLength)`. For a `/48` pool + `/64` UE prefix → 65,536 blocks. Reserve index 0 → range `[1, 2^k − 1]`.
- **`poolIndexToIP(N)`**: write `N` into the **subnet bits** `[poolPrefixLength, uePrefixLength)`; write a **fixed IID** into `[uePrefixLength, 128)`. First UE → `2001:db8:122:1::2`, second → `2001:db8:122:2::2`, …
- **`ipToPoolIndex(addr)`**: extract the subnet bits (inverse of above).
- **IID = `::2`** (proposed): UE forms link-local `fe80::2`; RA router is `fe80::1` → no collision. All UEs sharing `fe80::2` is fine — each UE is on its own point-to-point GTP tunnel (link-local scope is per-link).
- **Degenerate case** (`poolPrefixLength == uePrefixLength`, e.g. a static `/64` pool): one block → one dedicated UE for that /64. Preserved.
- `exclude`/reserve logic stays; reserving index 0 keeps the gateway subnet (`2001:db8:122:0::/64`, holding `…::1`) free from any UE.

#### Component 1a — CRITICAL: must NOT break `ipv6StaticPools` / `ipv6StaticAssignments` (decided 2026-07-27: KEEP the feature + guard)
**Decision:** user chose to **keep** `ipv6StaticPools`/`ipv6StaticAssignments` and guard the allocator, rather than remove the feature — the guard is the smaller/lower-risk change and preserves deterministic per-subscriber /64 pinning. (The static /128 *IID* is admittedly moot for SLAAC UEs — the UE forms its own IID from the advertised /64 — but the /64-prefix pinning remains valid and the guard costs almost nothing.)

**Proven impact if left unguarded:** static IPv6 is not a separate code path — a static assignment funnels the operator-chosen address in as `Allocate(request)` with `request != nil` (`ue_defaultPath.go:375-382,430-442`: `staticIPv6 := selection.PDUAddressIPv6; pool.Allocate(staticIPv6)`). `Allocate` then does `ipToPoolIndex(request)` → `pool.Use` → `poolIndexToIP` (`ue_ip_pool.go:102-132`). **Correctness depends on `poolIndexToIP(ipToPoolIndex(addr)) == addr`** — the exact two functions Component 1 rewrites. Static assignments encode UE identity in the **IID within one shared /64** (config `ipv6StaticPools: 2001:db8:0111:100::/64` + `ipv6StaticAssignments: …::10 / …::11`). A naive uniform rewrite computes `k = uePrefixLength − poolPrefixLength = 0` → single index 0, forces IID `::2` → `::10` and `::11` collapse to `2001:db8:0111:100::2` → collision, static IIDs destroyed. The earlier "degenerate case … Preserved" note preserved block count but NOT IID semantics.

**Required guard (keeps Approach 2 intact):** apply the subnet-index + fixed-IID rewrite **only on the dynamic path (`request == nil`)**. Whenever an explicit address is requested (`request != nil` — always true for static assignments), preserve **faithful full-IID round-trip** of that exact /128 (the current full-IID `ipToPoolIndex`/`poolIndexToIP` behavior). Net: dynamic `ipv6Pools` → unique /64 + `::2`; `ipv6StaticPools`/`ipv6StaticAssignments` → operator IIDs byte-for-byte unchanged. **Also audit the other `ipToPoolIndex`/`poolIndexToIP` callers** — `reserveExcludes` (gateway `exclude:` reservation) and `Release` — so both pool types still round-trip and IP release does not silently shift. IPv4 `staticPools` (used in ~40 config blocks) is a different address family and untouched.

### Component 2 — SMF PDR build & RA (no functional change)
`datapath.go:1009-1014` already sets `Ipv6d=true, Ipv6PrefixDelegationBits=64` — relied upon, unchanged. RA builder (`sm_context.go:1651,1668`) already derives the UE's /64 from its address (now unique). Unchanged. (Verify both still behave after Component 1.)

### Component 3 — go-upf — `NFs/upf/internal/forwarder/gtp5g.go`
When emitting `PDI_UE_ADDR_IPV6` (lines ~602-607, and the UpdatePDR path), also emit a new attr `PDI_UE_ADDR_IPV6_PREFIX_LEN` sourced from PFCP `UEIPAddress.Ipv6PrefixDelegationBits` (fallback 64).

### Component 4 — go-gtp5gnl — `go-gtp5gnl/attr_pdr.go`
Add `PDI_UE_ADDR_IPV6_PREFIX_LEN` **appended at the END** of the PDI attr enum (mirror kernel; appending avoids renumbering pain the RA commit hit), plus decode.

### Component 5 — gtp5g kernel — `gtp5g/src/pfcp/pdr.c`, `include/pdr.h`, `src/genl/genl_pdr.c`, `include/genl_pdr.h`
- `include/pdr.h`: add `u8 ue_addr_ipv6_prefixlen;` to `struct pdi` (default 64).
- `include/genl_pdr.h` + `src/genl/genl_pdr.c`: add `GTP5G_PDI_UE_ADDR_IPV6_PREFIX_LEN` **at the END** of the enum; parse it; optionally echo in the PDR dump.
- `src/pfcp/pdr.c`:
  - **`pdr_find_by_ipv6`** (downlink, line 916; called from `src/gtpu/encap.c:1244`): mask both the **hash key** — lookup (`:923`) *and* insert (`:1029`) — and the **compare** (`:930`) to the UE's /64 using the existing `ipv6_match(daddr, ue_addr_ipv6, mask)`. Unique /64 ⇒ deterministic bucket, unambiguous match.
  - **`pdr_find_by_gtp1u`** (uplink + RS/RA, line 638): change **only** `global_match` in both the `is_uplink` saddr branch (`:798`) and `is_downlink` daddr branch (`:820`) to the masked compare. **Leave `ll_match` / `unspec_match` / `sn_multicast_match` exactly as-is** — that is the RS/RA/NS/NA/DAD path and must not change.
- Build the /64 mask from `ue_addr_ipv6_prefixlen` (fallback 64). `ipv6_match()` mask helper already exists (added in commit `5300212`, currently used only by SDF filters).

### Verification
1. Rebuild + reload `gtp5g.ko`; rebuild `smf` + `upf`.
2. Single UE: `ping -6 2001:db8:126::1 -I rmnet_data0` → **expect replies**; on CN watch `tcpdump -ni upfgtp icmp6` for request **and** reply.
3. Confirm RS/RA/SLAAC bring-up unchanged (UE still obtains its global address).
4. Two UEs on the same DNN → confirm they get **different** /64s and both ping.

### Risk / compat
IPv4 untouched; static IPv6 `/64` pools still work (one UE per /64); no netlink renumbering (attr appended at end); `NFs/upf` go.mod/go.sum churn stays uncommitted per repo convention; bonus — the §2a `::1` br-lan collision dissolves (UEs now in subnet ≥ 1, distinct from gateway subnet 0).

---

## 11. RESUME HERE (next session)

**All design specifics RESOLVED (2026-07-27):**
1. [x] **Fixed UE IID = `::2`** on the dynamic path within each unique /64 (keeps `fe80::1` free for the router). The global IID is the UE's own SLAAC choice; the assigned `::2` only sets the assigned/link-local form. **CHOSEN.**
2. [x] **Reserve subnet index 0** (gateway subnet) so dynamic UEs start at `…:1::/64`; also dissolves the §2a `::1` collision. **CHOSEN.**
3. [x] **Static IPv6 (`ipv6StaticPools`/`ipv6StaticAssignments`): KEEP + guard** (see Component 1a). Rewrite applies to dynamic path only; static keeps full-IID round-trip. **CHOSEN.**

**Then:** invoke the `writing-plans` workflow for a step-by-step implementation plan → implement component-by-component → build/verify per §Verification (do **not** break RS/RA).

**Build commands:** `cd gtp5g && make clean && make && sudo make install` (reload module); `cd free5gc && make smf upf`.
**Remote CN access:** `tmux new-session -d -s cn 'my-ssh --target cn'` then `tmux send-keys` / `tmux capture-pane` (see repo CLAUDE.md).

**Key evidence recap for quick recall:** SMF allocates UE IID `::2`; DL PDR keyed on exact `2001:db8:122::2`; UE actually uses SLAAC privacy `2001:db8:122:0:e1cb:db04:ef07:ab8f`; gtp5g `ipv6_addr_equal` exact match fails → downlink dropped. Fix = route the UE's whole /64 (unique per UE).

---

## Verification results (2026-07-28, live CN)

**Outcome: RESOLVED.** UE-initiated IPv6 ping over the full data path: **4/4 replies, 0% loss**
(RTT ~12 ms). Implementing Approach 2 exposed two further, independent bugs beyond the SMF
allocator + /64 match; all are now fixed. Full write-up: `bug_ipv6_downlink_dualstack_bucket_260728.md`.

Fix chain (all layers required):
1. SMF unique /64 per UE, fixed `::2` IID — `NFs/smf b29ab37`.
2. gtp5g uplink `/64` masked match (SLAAC IID) — `gtp5g 0fab710`.
3. gtp5g downlink **dual-stack bucket** fix: dedicated `addr6_hash` + `hlist_addr_ipv6` so a
   dual-stack (IPV4V6) PDR is indexed by both IPv4 and IPv6 `/64` — `gtp5g 444d995`.
4. gtp5g uplink **protocol re-tag**: set `skb->protocol` from the inner IP version before
   `netif_rx()`, so decapped inner IPv6 reaches the IPv6 stack instead of being dropped by
   `ip_rcv()` — `gtp5g 795de92`.
5. UPF host: `net.ipv6.conf.all.forwarding=1` (was 0 while IPv4 `ip_forward` was 1).

Evidence: `tshark -i any -f "udp port 2152" -Y "icmpv6"` on the CN showed matched Echo
request/reply pairs; the same capture showed RS→RA (SLAAC intact); downlink dmesg went from
`no PDR found for IPv6 …` to `pdr_find_by_ipv6: Match PDR ID:2 (… within UE /64)`.
