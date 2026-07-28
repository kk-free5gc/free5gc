# IPv6 SLAAC /64 Prefix-Match Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make IPv6 downlink work for SLAAC UEs by allocating a unique /64 per PDU session in the SMF and matching the UE's /64 prefix (not the exact /128) in gtp5g, without disturbing the working RS/RA/NS/NA/DAD path.

**Architecture:** Two coupled changes. (1) SMF allocator writes the allocation index into the **subnet bits** of the pool prefix (unique /64 per UE) with a fixed IID `::2` on the dynamic path only; static assignments keep full-IID round-trip. (2) gtp5g plumbs a per-PDR IPv6 prefix length (from the PFCP `Ipv6PrefixDelegationBits`, fallback 64) and uses it to mask both the **hash key** and the **compare** in the downlink/uplink resolvers to /64, leaving link-local / solicited-node-multicast / unspecified-source cases untouched.

**Tech Stack:** Go (free5gc SMF, go-upf, go-gtp5gnl netlink lib), C Linux kernel module (gtp5g), netlink (genl) attributes, PFCP (`github.com/wmnsk/go-pfcp`).

**Design source:** `docs/ipv6-feature/issue_ipv6_slaac_downlink_prefix_match_260724.md` (root cause, approach decision, component design, §11 resolved sign-offs).

## Global Constants (agreed values — every task must use these verbatim)

- **New netlink attribute number = `8`** on BOTH sides (kernel enum and go-gtp5gnl const). Value 7 is reserved for `ETHERNET_PACKET_FILTER` (go-gtp5gnl already uses 7; kernel must add a reserved 7 slot so the new attr lands on 8). Never renumber existing attrs.
- **Attribute names:** kernel `GTP5G_PDI_UE_ADDR_IPV6_PREFIX_LEN`; go-gtp5gnl `PDI_UE_ADDR_IPV6_PREFIX_LEN`; go-upf reuses the go-gtp5gnl const.
- **Prefix-length fallback = `64`** everywhere a prefix length is 0/absent.
- **Dynamic UE IID = `::2`** (last 64 bits = `0x0000000000000002`) on the dynamic allocation path only.
- **Reserve subnet index 0** on the dynamic path (dynamic UEs start at subnet index 1 → `…:1::/64`).
- **Static path is guarded:** in `UeIPPool.Allocate`, the new subnet-index scheme applies ONLY when `request == nil`. When `request != nil` (always true for `ipv6StaticPools`/`ipv6StaticAssignments`), keep the current full-IID round-trip so operator-chosen IIDs (`::10`, `::11`) survive byte-for-byte.
- **Hash invariant:** IPv6 PDR hashing uses a FIXED /64 prefix (first 64 bits) at both lookup and insert. This is valid because `Ipv6PrefixDelegationBits` is always 64 here. The per-PDR prefix length still drives the *compare*.
- **HARD CONSTRAINT — do NOT touch** the RS/RA/NS/NA/DAD matching: in `pdr_find_by_gtp1u`, only `global_match` changes; `ll_match`, `unspec_match`, `sn_multicast_match` stay exactly as-is. Do not reorder cases.
- **Git identity:** `lori041987` / `lori041987@yahoo.com.tw`. `NFs/upf` go.mod/go.sum churn is intentionally uncommitted — do not commit or flag it.

---

## Task 1: SMF allocator — unique /64 per UE (dynamic path) + static guard

**Files:**
- Modify: `NFs/smf/internal/context/ue_ip_pool.go` (`calcIPv6AddrRange`, `poolIndexToIP`, `ipToPoolIndex`, `Allocate`)
- Test: `NFs/smf/internal/context/ue_ip_pool_test.go` (add cases) and reuse `sm_context_ipv6_test.go`

**Interfaces:**
- Consumes: `factory.UEIPv6Pool{Prefix string, UePrefixLength int, ...}`; `net.IPNet`.
- Produces (unchanged signatures, new behavior):
  - `func (ueIPPool *UeIPPool) Allocate(request net.IP) net.IP` — dynamic (request==nil) returns unique-/64 address ending in `::2`; static (request!=nil) returns the requested address unchanged.
  - `func (ueIPPool *UeIPPool) poolIndexToIP(index uint64) net.IP`
  - `func (ueIPPool *UeIPPool) ipToPoolIndex(addr net.IP) uint64`
  - `func calcIPv6AddrRange(ipNet *net.IPNet, uePrefixLength int) (minAddr, maxAddr uint64, err error)`

### Background for the implementer (CORRECTED 2026-07-27 during execution review)
Today (buggy): for `uePrefixLength <= 64`, `poolIndexToIP` writes `index` into bytes 8–15 (the IID), so every UE shares one /64 and differs only by IID.

**Discriminator = `subnetBits = uePrefixLength − poolPrefixLength`, NOT `request == nil`.** `poolPrefixLength` = the mask ones-count of `ueSubNet`.
- **`subnetBits > 0` and `uePrefixLength <= 64`** (e.g. the real `/48` dynamic pool + `/64` UE ⇒ 16 subnet bits): use the NEW subnet-index model — `index` goes into the **subnet bits** `[poolPrefixLength, uePrefixLength)`, IID fixed to `::2`. 65,535 usable /64 blocks (index 0 reserved).
- **`subnetBits == 0`** (every `/64` pool: all `ipv6StaticPools`, plus a degenerate `/64` dynamic pool) OR **`uePrefixLength > 64`** (sub-/64 host allocation): keep the OLD full-IID mapping **entirely unchanged** (range and bit layout).

This is applied **inside the mapping helpers** (`poolIndexToIP`/`ipToPoolIndex`) and `calcIPv6AddrRange`, so `Allocate`, `reserveExcludes`, `Release`, and `dump` automatically do the right thing per pool type. **`Allocate` itself does NOT change** (no request-branch). Static assignments (`Allocate(request)` on a `/64` static pool, `subnetBits==0`) keep faithful full-IID round-trip because that pool uses the OLD mapping. Excludes on a `/48` pool map the gateway `::1` to subnet 0 (already reserved by `minAddr=1`), not to a valid UE subnet.

- [ ] **Step 1: Write failing tests for the new dynamic /64 mapping and the static round-trip guard**

Add to `NFs/smf/internal/context/ue_ip_pool_test.go`:

```go
func TestIPv6DynamicUniquePrefixAllocation(t *testing.T) {
	// /48 pool, /64 UE prefix → index encodes the subnet, IID fixed to ::2
	fp := &factory.UEIPv6Pool{Prefix: "2001:db8:122::/48", UePrefixLength: 64}
	p := NewUEIPv6Pool(fp)
	require.NotNil(t, p)

	// First dynamic allocation → subnet index 1 (index 0 reserved) → 2001:db8:122:1::2
	a1 := p.Allocate(nil)
	require.NotNil(t, a1)
	require.Equal(t, "2001:db8:122:1::2", a1.String())

	// Second dynamic allocation → subnet index 2 → 2001:db8:122:2::2
	a2 := p.Allocate(nil)
	require.NotNil(t, a2)
	require.Equal(t, "2001:db8:122:2::2", a2.String())

	// The two UEs are in DIFFERENT /64s
	require.NotEqual(t, a1.Mask(net.CIDRMask(64, 128)).String(),
		a2.Mask(net.CIDRMask(64, 128)).String())
}

func TestIPv6StaticAssignmentRoundTripPreserved(t *testing.T) {
	// Static /64 pool: operator picks the exact IID; it MUST survive untouched.
	fp := &factory.UEIPv6Pool{Prefix: "2001:db8:0111:100::/64", UePrefixLength: 64}
	p := NewUEIPv6Pool(fp)
	require.NotNil(t, p)

	want := net.ParseIP("2001:db8:111:100::10")
	got := p.Allocate(want)
	require.NotNil(t, got)
	require.Equal(t, want.String(), got.String()) // full IID preserved, NOT rewritten to ::2

	// A second distinct static IID in the same /64 also survives and does not collide.
	want2 := net.ParseIP("2001:db8:111:100::11")
	got2 := p.Allocate(want2)
	require.NotNil(t, got2)
	require.Equal(t, want2.String(), got2.String())
}
```

Ensure the test file imports `"net"`, `"github.com/stretchr/testify/require"`, and `"github.com/free5gc/smf/pkg/factory"` (add any missing).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd NFs/smf && go test ./internal/context/ -run 'TestIPv6DynamicUniquePrefixAllocation|TestIPv6StaticAssignmentRoundTripPreserved' -v`
Expected: FAIL — dynamic case returns `2001:db8:122::1`-style (index in IID) instead of `2001:db8:122:1::2`.

- [ ] **Step 3: Add the fixed-IID constant + a `useSubnetIndexModel` predicate**

Near the top of `ue_ip_pool.go` (after imports) add the constant, and add a method that decides which model a pool uses:

```go
// WNC: Fixed interface-ID for dynamically-allocated UE IPv6 addresses (…::2).
// The UE ignores this for its global address (SLAAC picks its own IID); it only
// sets the assigned/link-local form. ::1 is left free for the RA router.
const dynamicUEIID uint64 = 0x0000000000000002
```

```go
// useSubnetIndexModel reports whether this IPv6 pool allocates a unique
// /uePrefixLength block per UE (index -> subnet bits, fixed ::2 IID). True only
// when the pool prefix is strictly shorter than the UE prefix AND the UE prefix
// is /64 or shorter (real config: /48 pool + /64 UE). Otherwise callers use the
// legacy full-IID mapping (static /64 pools, degenerate /64 dynamic, sub-/64).
// Returns subnetBits and the right-shift of the subnet field within the high word.
func (ueIPPool *UeIPPool) useSubnetIndexModel() (subnetBits, shift int, ok bool) {
	if !ueIPPool.isIPv6 || ueIPPool.factoryIPv6Pool == nil {
		return 0, 0, false
	}
	poolPrefixLength, _ := ueIPPool.ueSubNet.Mask.Size()
	uePrefixLength := ueIPPool.factoryIPv6Pool.UePrefixLength
	subnetBits = uePrefixLength - poolPrefixLength
	if subnetBits > 0 && uePrefixLength <= 64 {
		return subnetBits, 64 - uePrefixLength, true
	}
	return 0, 0, false
}
```

- [ ] **Step 4: Switch the IPv6 branches of `poolIndexToIP` / `ipToPoolIndex` on the model (legacy path unchanged)**

In `poolIndexToIP`, at the TOP of the `if ueIPPool.isIPv6 {` block, add the subnet-index branch and leave the existing full-IID body as the `else`/fallthrough:

```go
func (ueIPPool *UeIPPool) poolIndexToIP(index uint64) net.IP {
	if ueIPPool.isIPv6 {
		if subnetBits, shift, ok := ueIPPool.useSubnetIndexModel(); ok {
			// WNC: unique /uePrefixLength per UE — index into subnet bits, fixed ::2 IID.
			ip := make(net.IP, 16)
			copy(ip, ueIPPool.ueSubNet.IP.To16())
			hi := binary.BigEndian.Uint64(ip[0:8])
			mask := ((uint64(1) << uint(subnetBits)) - 1) << uint(shift)
			hi = (hi &^ mask) | ((index << uint(shift)) & mask)
			binary.BigEndian.PutUint64(ip[0:8], hi)
			binary.BigEndian.PutUint64(ip[8:16], dynamicUEIID)
			return ip
		}
		// --- legacy full-IID mapping (UNCHANGED from current code) ---
		ip := make(net.IP, 16)
		copy(ip, ueIPPool.ueSubNet.IP.To16())
		uePrefixLength := ueIPPool.factoryIPv6Pool.UePrefixLength
		if uePrefixLength > 64 {
			hostBits := 128 - uePrefixLength
			hostMask := uint64(0xFFFFFFFFFFFFFFFF) >> (64 - hostBits)
			networkPortion := binary.BigEndian.Uint64(ip[8:16])
			networkPortion = (networkPortion & ^hostMask) | (index & hostMask)
			binary.BigEndian.PutUint64(ip[8:16], networkPortion)
		} else {
			binary.BigEndian.PutUint64(ip[8:16], index)
		}
		return ip
	}
	buf := make([]byte, 4)
	binary.BigEndian.PutUint32(buf, uint32(index))
	return buf
}
```

In `ipToPoolIndex`, likewise add the subnet-index branch at the top of the IPv6 block and keep the existing full-IID extraction as the fallthrough:

```go
func (ueIPPool *UeIPPool) ipToPoolIndex(addr net.IP) uint64 {
	if ueIPPool.isIPv6 {
		ip16 := addr.To16()
		if ip16 == nil {
			logger.CtxLog.Warnf("WNC: Invalid IPv6 address: %s", addr)
			return 0
		}
		if subnetBits, shift, ok := ueIPPool.useSubnetIndexModel(); ok {
			hi := binary.BigEndian.Uint64(ip16[0:8])
			mask := (uint64(1) << uint(subnetBits)) - 1
			return (hi >> uint(shift)) & mask
		}
		// --- legacy full-IID extraction (UNCHANGED from current code) ---
		iidValue := binary.BigEndian.Uint64(ip16[8:16])
		uePrefixLength := ueIPPool.factoryIPv6Pool.UePrefixLength
		if uePrefixLength > 64 {
			hostBits := 128 - uePrefixLength
			hostMask := uint64(0xFFFFFFFFFFFFFFFF) >> (64 - hostBits)
			return iidValue & hostMask
		}
		return iidValue
	}
	ip4 := addr.To4()
	if ip4 == nil {
		logger.CtxLog.Warnf("Invalid IPv4 address: %s", addr)
		return 0
	}
	return uint64(binary.BigEndian.Uint32(ip4))
}
```

- [ ] **Step 5: Adjust `calcIPv6AddrRange` for the subnet-index model only (legacy branch unchanged)**

Add a subnet-index sizing branch at the top of `calcIPv6AddrRange`; keep the existing host-bits body as the `else`:

```go
func calcIPv6AddrRange(ipNet *net.IPNet, uePrefixLength int) (minAddr, maxAddr uint64, err error) {
	if uePrefixLength > 128 || uePrefixLength < 1 {
		return 0, 0, fmt.Errorf("invalid UE prefix length: %d (must be 1-128)", uePrefixLength)
	}
	poolPrefixLength, _ := ipNet.Mask.Size()
	subnetBits := uePrefixLength - poolPrefixLength

	if subnetBits > 0 && uePrefixLength <= 64 {
		// WNC: unique /uePrefixLength per UE. Reserve subnet index 0 (gateway subnet).
		minAddr = 1
		if subnetBits >= 63 {
			maxAddr = 0x7FFFFFFFFFFFFFFF
		} else {
			maxAddr = (uint64(1) << uint(subnetBits)) - 1
		}
		logger.InitLog.Infof("WNC: IPv6 pool range (subnet-indexed): %d to %d (pool /%d, UE /%d, subnet bits: %d)",
			minAddr, maxAddr, poolPrefixLength, uePrefixLength, subnetBits)
		return minAddr, maxAddr, nil
	}

	// --- legacy host-bits sizing (UNCHANGED from current code) ---
	hostBits := 128 - uePrefixLength
	if hostBits >= 64 {
		minAddr = 1
		maxAddr = 0xFFFFFFFFFFFFFFFE
	} else if hostBits == 1 {
		minAddr = 0
		maxAddr = 1
	} else if hostBits > 1 {
		minAddr = 1
		maxAddr = (uint64(1) << hostBits) - 2
	} else {
		minAddr = 0
		maxAddr = 0
	}
	ones, _ := ipNet.Mask.Size()
	logger.InitLog.Infof("WNC: IPv6 pool range: %d to %d (prefix: /%d, UE prefix: /%d, host bits: %d)",
		minAddr, maxAddr, ones, uePrefixLength, hostBits)
	return minAddr, maxAddr, nil
}
```

**`Allocate` is NOT modified** — it already calls `ipToPoolIndex`/`poolIndexToIP`, which now branch on the model. (Optionally enhance its IPv6 log line to include the prefix length; not required.)

- [ ] **Step 6: Run the new tests to verify they pass**

Run: `cd NFs/smf && go test ./internal/context/ -run 'TestIPv6DynamicUniquePrefixAllocation|TestIPv6StaticAssignmentRoundTripPreserved' -v`
Expected: PASS.

- [ ] **Step 7: Run the full SMF context test suite to catch regressions (excludes/release/dump/round-trip)**

Run: `cd NFs/smf && go test ./internal/context/... -v`
Expected: PASS. Pay special attention to any existing IPv6 pool, static-assignment, and `reserveExcludes` tests. If an existing test encoded the OLD "index-in-IID" dynamic behavior, update it to the new unique-/64 expectation (the old behavior was the bug) and note the change in the commit message.

- [ ] **Step 8: Build the SMF binary**

Run: `cd /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc && make smf`
Expected: builds with no errors; `bin/smf` updated.

- [ ] **Step 9: Commit**

```bash
cd /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc
git add NFs/smf/internal/context/ue_ip_pool.go NFs/smf/internal/context/ue_ip_pool_test.go
git commit -m "feat(smf): allocate unique /64 per UE (dynamic path), fixed ::2 IID; preserve static IPv6 full-IID round-trip

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: SMF — verify DL PDR + RA still correct after unique-/64 change (no code change expected)

**Files:**
- Inspect: `NFs/smf/internal/context/datapath.go:1005-1030` (DL PDR `Ipv6d`/`Ipv6PrefixDelegationBits`)
- Inspect: `NFs/smf/internal/context/sm_context.go` (RA prefix derivation `GetIPv6PrefixFromAddress(..., 64)`)
- Test: `NFs/smf/internal/context/sm_context_ipv6_test.go`

**Interfaces:**
- Consumes: `smContext.PDUAddressIPv6` (now a unique-/64 address ending in `::2`), `smContext.PDUAddressIPv6PrefixLen` (64).
- Produces: no new symbols. Confirms DL PDR sets `Ipv6d=true, Ipv6PrefixDelegationBits=64` and the RA advertises the UE's now-unique /64.

- [ ] **Step 1: Add an assertion test that the RA prefix equals the allocated address's /64**

Append to `sm_context_ipv6_test.go` a test that allocates a dynamic IPv6 address and checks the derived RA prefix matches its /64 and that the prefix is unique across two allocations. Use the existing helpers in that file as a template (match their construction of `smContext`/pool). Concretely assert:

```go
// pseudocode shape — adapt to the file's existing test scaffolding:
// addr := pool.Allocate(nil)                    // e.g. 2001:db8:122:1::2
// pfx  := GetIPv6PrefixFromAddress(addr, 64)     // must be 2001:db8:122:1::/64
// require.Equal(t, "2001:db8:122:1::/64", pfx.String())
```

If `GetIPv6PrefixFromAddress` is unexported or lives elsewhere, assert on the RA builder's output instead; the goal is: RA prefix == allocated address masked to /64.

- [ ] **Step 2: Run the IPv6 sm_context tests**

Run: `cd NFs/smf && go test ./internal/context/ -run 'IPv6' -v`
Expected: PASS. If FAIL because RA derivation hardcodes an assumption about the shared /64, capture the exact failure and STOP — that indicates a real coupling to fix here rather than a no-op.

- [ ] **Step 3: Commit (test-only)**

```bash
cd /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc
git add NFs/smf/internal/context/sm_context_ipv6_test.go
git commit -m "test(smf): assert RA /64 tracks the unique per-UE IPv6 allocation

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: gtp5g kernel — add prefix-length to struct + netlink enum + genl parse

**Files:**
- Modify: `gtp5g/include/pdr.h:62-71` (`struct pdi`)
- Modify: `gtp5g/include/genl_pdr.h:36-46` (PDI attr enum)
- Modify: `gtp5g/src/genl/genl_pdr.c:647-667` (parse) and `:1180-1206` (dump, optional echo)

**Interfaces:**
- Produces: `struct pdi` gains `u8 ue_addr_ipv6_prefixlen;` (0 means "unset" → callers treat as 64). Kernel enum gains `GTP5G_PDI_UE_ADDR_IPV6_PREFIX_LEN` == 8.
- Consumes: netlink attr 8 (u8) from go-upf (Task 7).

- [ ] **Step 1: Add the prefix-length field to `struct pdi`**

In `gtp5g/include/pdr.h`, inside `struct pdi` (after the two `has_ue_ipv6*` bitfields, line ~68):

```c
struct pdi {
    u8 srcIntf;
    struct in_addr *ue_addr_ipv4;
    struct in6_addr ue_addr_ipv6;         // WNC: IPv6 UE global address (embedded)
    struct in6_addr ue_addr_ipv6_ll;      // WNC: IPv6 UE link-local address for RS/RA/NS/NA/DAD
    u8 has_ue_ipv6:1;                      // WNC: IPv6 global address present
    u8 has_ue_ipv6_ll:1;                   // WNC: IPv6 link-local address present
    u8 ue_addr_ipv6_prefixlen;             // WNC: UE IPv6 prefix length for /64 match (0 => default 64)
    struct local_f_teid *f_teid;
    struct sdf_filter *sdf;
};
```

- [ ] **Step 2: Append the new attr to the kernel PDI enum at value 8 (reserve 7 for parity)**

In `gtp5g/include/genl_pdr.h`, extend the enum (currently ending `GTP5G_PDI_APP_ID,` then `__GTP5G_PDI_ATTR_MAX`):

```c
enum {
    GTP5G_PDI_UNSPEC,                       // 0
    GTP5G_PDI_UE_ADDR_IPV4,                 // 1
    GTP5G_PDI_UE_ADDR_IPV6,                 // 2
    GTP5G_PDI_F_TEID,                       // 3
    GTP5G_PDI_SDF_FILTER,                   // 4
    GTP5G_PDI_SRC_INTF,                     // 5
    GTP5G_PDI_APP_ID,                       // 6
    GTP5G_PDI_ETHERNET_PACKET_FILTER,       // 7 (reserved: parity with go-gtp5gnl)
    GTP5G_PDI_UE_ADDR_IPV6_PREFIX_LEN,      // 8 (WNC: u8 UE IPv6 prefix length)

    __GTP5G_PDI_ATTR_MAX,
};
```

Leave `#define GTP5G_PDI_ATTR_MAX 16` unchanged (still ≥ enum count).

- [ ] **Step 3: Parse the new attr in `genl_pdr.c` and default it to 64**

In `gtp5g/src/genl/genl_pdr.c`, inside the `if (attrs[GTP5G_PDI_UE_ADDR_IPV6]) { ... }` block (after `pdi->has_ue_ipv6 = 1;` and the link-local computation, ~line 666), set a default, then add a parse block right after:

```c
        pdi->has_ue_ipv6 = 1;
        // WNC: default prefix length; overridden by the explicit attr below if present
        pdi->ue_addr_ipv6_prefixlen = 64;
        GTP5G_INF(NULL, "WNC: PDI UE IPv6 global: %pI6\n", &pdi->ue_addr_ipv6);
        compute_ipv6_link_local(&pdi->ue_addr_ipv6, &pdi->ue_addr_ipv6_ll);
        pdi->has_ue_ipv6_ll = 1;
        GTP5G_INF(NULL, "WNC: PDI UE IPv6 link-local: %pI6\n", &pdi->ue_addr_ipv6_ll);
    }

    if (attrs[GTP5G_PDI_UE_ADDR_IPV6_PREFIX_LEN]) {
        u8 plen = nla_get_u8(attrs[GTP5G_PDI_UE_ADDR_IPV6_PREFIX_LEN]);
        if (plen == 0 || plen > 128)
            plen = 64; // WNC: fallback
        pdi->ue_addr_ipv6_prefixlen = plen;
        GTP5G_INF(NULL, "WNC: PDI UE IPv6 prefix length: /%u\n", pdi->ue_addr_ipv6_prefixlen);
    }
```

(Adjust indentation/brace placement to the actual code; the parse block must be OUTSIDE the IPv6-address `if` so it also applies on update paths, but the default assignment stays inside the address block.)

- [ ] **Step 4: (Optional) echo the prefix length in the PDR dump**

In `genl_pdr.c` near the `nla_put(skb, GTP5G_PDI_UE_ADDR_IPV6, ...)` block (~line 1186), after the address is put:

```c
    if (pdi->has_ue_ipv6) {
        if (nla_put(skb, GTP5G_PDI_UE_ADDR_IPV6,
                    sizeof(struct in6_addr), &pdi->ue_addr_ipv6))
            return -EMSGSIZE;
        if (nla_put_u8(skb, GTP5G_PDI_UE_ADDR_IPV6_PREFIX_LEN,
                       pdi->ue_addr_ipv6_prefixlen))
            return -EMSGSIZE;
    }
```

- [ ] **Step 5: Build the kernel module (compile-only gate)**

Run: `cd /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/gtp5g && make clean && make`
Expected: `gtp5g.ko` builds with no errors/warnings related to the new field/attr. (Do NOT `make install`/reload yet — that happens in the integration task after the resolvers are done, to avoid a half-changed module.)

- [ ] **Step 6: Commit**

```bash
cd /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/gtp5g
git add include/pdr.h include/genl_pdr.h src/genl/genl_pdr.c
git commit -m "feat(gtp5g): plumb UE IPv6 prefix length (PDI attr 8, struct pdi, genl parse)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: gtp5g kernel — downlink resolver `pdr_find_by_ipv6` /64 hash + masked compare

**Files:**
- Modify: `gtp5g/src/pfcp/pdr.c` — add a prefix-mask helper; change `pdr_find_by_ipv6` lookup hash (`:923`) + compare (`:929-931`); change insert hash in `pdr_append`/`pdr_append_addr` (`:1029`).

**Interfaces:**
- Consumes: `pdi->ue_addr_ipv6_prefixlen` (Task 3), existing `ipv6_match(target, match, mask)` (`pdr.c:217`), existing `ipv6_hashfn` (`hash.h:26`).
- Produces: downlink lookup that matches any destination inside the UE's /64.

### Background
`pdr_find_by_ipv6` hashes the incoming destination over all 128 bits, then compares with `ipv6_addr_equal`. A SLAAC UE's real address differs from the stored `::2` in the IID, so it lands in a different bucket AND fails the exact compare. Fix: hash over the **/64 prefix** at both lookup and insert (so both land in the same bucket), and compare with a /prefixlen mask.

- [ ] **Step 1: Add a /prefixlen mask builder and a prefix-hash helper**

In `gtp5g/src/pfcp/pdr.c`, near `ipv6_match` (after line 227), add:

```c
// WNC: Build an in6_addr netmask for a prefix length (0..128).
static void ipv6_build_prefix_mask(struct in6_addr *mask, u8 plen)
{
    int i;
    if (plen > 128)
        plen = 128;
    for (i = 0; i < 16; i++) {
        if (plen >= 8) {
            mask->s6_addr[i] = 0xff;
            plen -= 8;
        } else if (plen > 0) {
            mask->s6_addr[i] = (u8)(0xff << (8 - plen));
            plen = 0;
        } else {
            mask->s6_addr[i] = 0x00;
        }
    }
}

// WNC: Hash an IPv6 address over its leading /64 prefix only. Lookup and insert
// MUST use the same width so a UE's SLAAC IID does not change the bucket.
static u32 ipv6_prefix64_hashfn(const struct in6_addr *addr)
{
    // First 64 bits = s6_addr32[0..1]. Zero the rest for a stable prefix hash.
    return jhash2((const u32 *)addr->s6_addr32, 2, gtp5g_h_initval);
}
```

Confirm `jhash2` and `gtp5g_h_initval` are visible (they are used via `hash.h`, already included by `pdr.c`). If `pdr.c` does not include `hash.h`, add `#include "hash.h"` with the other includes.

- [ ] **Step 2: Use the /64 prefix hash + masked compare in `pdr_find_by_ipv6`**

Replace the lookup hash and compare (`pdr.c:923` and `:928-931`):

```c
struct pdr *pdr_find_by_ipv6(struct gtp5g_dev *gtp, struct sk_buff *skb,
        unsigned int hdrlen, const struct in6_addr *addr)
{
    struct hlist_head *head;
    struct pdr *pdr;
    struct pdi *pdi;
    struct in6_addr mask;

    head = &gtp->addr_hash[ipv6_prefix64_hashfn(addr) % gtp->hash_size]; // WNC: /64 bucket

    hlist_for_each_entry_rcu(pdr, head, hlist_addr) {
        pdi = pdr->pdi;

        if (!(pdr->af & AF_INET6) || !pdi->has_ue_ipv6)
            continue;

        // WNC: match the UE's /prefixlen (default 64), not the exact /128,
        // so SLAAC privacy IIDs still resolve to this session.
        ipv6_build_prefix_mask(&mask,
            pdi->ue_addr_ipv6_prefixlen ? pdi->ue_addr_ipv6_prefixlen : 64);
        if (!ipv6_match(addr, &pdi->ue_addr_ipv6, &mask))
            continue;

        if (pdi->sdf)
            if (!sdf_filter_match(pdi->sdf, skb, hdrlen, GTP5G_SDF_FILTER_OUT))
                continue;

        GTP5G_INF(NULL, "WNC: Match PDR ID:%d (IPv6 /%u prefix)\n",
                  pdr->id, pdi->ue_addr_ipv6_prefixlen ? pdi->ue_addr_ipv6_prefixlen : 64);
        return pdr;
    }
    return NULL;
}
```

- [ ] **Step 3: Use the /64 prefix hash at INSERT time**

In the IPv6 insert branch (`pdr.c:1029`), change the bucket computation to the same prefix hash:

```c
    } else if (pdi->has_ue_ipv6) {
        last_ppdr = NULL;
        head = &gtp->addr_hash[ipv6_prefix64_hashfn(&pdi->ue_addr_ipv6) % gtp->hash_size]; // WNC: /64 bucket
        hlist_for_each_entry_rcu(ppdr, head, hlist_addr) {
            if (pdr->precedence > ppdr->precedence)
                last_ppdr = ppdr;
            else
                break;
        }
        if (!last_ppdr)
            hlist_add_head_rcu(&pdr->hlist_addr, head);
        else
            hlist_add_behind_rcu(&pdr->hlist_addr, &last_ppdr->hlist_addr);
        GTP5G_INF(NULL, "WNC: Added PDR %d to IPv6 /64 hash bucket (%pI6)\n",
                  pdr->id, &pdi->ue_addr_ipv6);
    }
```

- [ ] **Step 4: Build the module (compile gate)**

Run: `cd /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/gtp5g && make`
Expected: builds clean.

- [ ] **Step 5: Commit**

```bash
cd /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/gtp5g
git add src/pfcp/pdr.c
git commit -m "feat(gtp5g): downlink IPv6 resolver matches UE /64 (prefix hash + masked compare)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: gtp5g kernel — uplink resolver `pdr_find_by_gtp1u` masked `global_match` (RS/RA untouched)

**Files:**
- Modify: `gtp5g/src/pfcp/pdr.c:796-852` — `global_match` only, in both `is_uplink` (saddr, `:798`) and `is_downlink` (daddr, `:820`) branches.

**Interfaces:**
- Consumes: `pdi->ue_addr_ipv6_prefixlen`, `ipv6_match`, `ipv6_build_prefix_mask` (Task 4).
- Produces: uplink/GTP1U inner-packet match on the UE's /64. **`ll_match`, `unspec_match`, `sn_multicast_match` are unchanged.**

- [ ] **Step 1: Mask `global_match` in the uplink (saddr) branch**

Change ONLY line 798. Leave 799 (`ll_match`) and 800 (`unspec_match`) and the `if (!global_match && !ll_match && !unspec_match)` logic intact:

```c
            if (is_uplink(pdr)) {
                struct in6_addr ue_mask;
                ipv6_build_prefix_mask(&ue_mask,
                    pdi->ue_addr_ipv6_prefixlen ? pdi->ue_addr_ipv6_prefixlen : 64);
                bool global_match = ipv6_match(&ip6h->saddr, &pdi->ue_addr_ipv6, &ue_mask); // WNC: /64
                bool ll_match = pdi->has_ue_ipv6_ll && ipv6_addr_equal(&ip6h->saddr, &pdi->ue_addr_ipv6_ll);
                bool unspec_match = ipv6_addr_any(&ip6h->saddr); // DAD uses :: as source

                if (!global_match && !ll_match && !unspec_match) {
                    /* ... existing mismatch log + continue, UNCHANGED ... */
                }
                /* ... existing ll_match / unspec_match info logs, UNCHANGED ... */
            }
```

- [ ] **Step 2: Mask `global_match` in the downlink (daddr) branch**

Change ONLY line 820. Leave `ll_match` (821) and the entire `sn_multicast_match` block (824-836) and the `if (!global_match && !ll_match && !sn_multicast_match)` logic intact:

```c
            else if (is_downlink(pdr)) {
                struct in6_addr ue_mask;
                ipv6_build_prefix_mask(&ue_mask,
                    pdi->ue_addr_ipv6_prefixlen ? pdi->ue_addr_ipv6_prefixlen : 64);
                bool global_match = ipv6_match(&ip6h->daddr, &pdi->ue_addr_ipv6, &ue_mask); // WNC: /64
                bool ll_match = pdi->has_ue_ipv6_ll && ipv6_addr_equal(&ip6h->daddr, &pdi->ue_addr_ipv6_ll);

                bool sn_multicast_match = false;
                /* ... existing solicited-node multicast block, UNCHANGED ... */

                if (!global_match && !ll_match && !sn_multicast_match) {
                    /* ... existing mismatch log + continue, UNCHANGED ... */
                }
                /* ... existing ll_match / sn_multicast_match info logs, UNCHANGED ... */
            }
```

- [ ] **Step 3: Build the module (compile gate)**

Run: `cd /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/gtp5g && make`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
cd /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/gtp5g
git add src/pfcp/pdr.c
git commit -m "feat(gtp5g): uplink global_match uses UE /64 mask; RS/RA/NS/NA/DAD cases untouched

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: go-gtp5gnl — add `PDI_UE_ADDR_IPV6_PREFIX_LEN` const (== 8) + decode

**Files:**
- Modify: `go-gtp5gnl/attr_pdr.go:82-99` (const block + `PDI` struct + `DecodePDI`)

**Interfaces:**
- Produces: `PDI_UE_ADDR_IPV6_PREFIX_LEN = 8`; `PDI.UEAddrIPv6PrefixLen uint8` (decoded, optional).
- Consumes: nothing new.

- [ ] **Step 1: Append the const so its iota value is 8**

The existing block is `PDI_UE_ADDR_IPV4 = iota + 1` (1) … `PDI_ETHERNET_PACKET_FILTER` (7). Append one line so the new const is 8:

```go
const (
	PDI_UE_ADDR_IPV4 = iota + 1 // 1
	PDI_UE_ADDR_IPV6            // 2  WNC: IPv6 UE address support
	PDI_F_TEID                 // 3
	PDI_SDF_FILTER             // 4
	PDI_SRC_INTF               // 5
	PDI_APP_ID                 // 6  WNC: ApplicationID for RS monitoring
	PDI_ETHERNET_PACKET_FILTER // 7
	PDI_UE_ADDR_IPV6_PREFIX_LEN // 8  WNC: UE IPv6 prefix length (u8)
)
```

- [ ] **Step 2: Add the decoded field to `PDI` and handle it in `DecodePDI`**

Add `UEAddrIPv6PrefixLen uint8` to the `PDI` struct, and a decode case in `DecodePDI`:

```go
type PDI struct {
	SrcIntf             *uint8
	UEAddr              net.IP
	UEAddrIPv6PrefixLen uint8 // WNC: UE IPv6 prefix length (0 => default 64)
	FTEID               *FTEID
	SDF                 *SDFFilter
	EPFs                []EthPktFilter
	ApplicationID       string
}
```

In the `DecodePDI` switch, add:

```go
		case PDI_UE_ADDR_IPV6_PREFIX_LEN:
			pdi.UEAddrIPv6PrefixLen = b[n]
```

- [ ] **Step 3: Build go-gtp5gnl**

Run: `cd /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/go-gtp5gnl && go build ./...`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
cd /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/go-gtp5gnl
git add attr_pdr.go
git commit -m "feat: add PDI_UE_ADDR_IPV6_PREFIX_LEN (attr 8) const + decode

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: go-upf — emit the IPv6 prefix-length attr from PFCP `Ipv6PrefixDelegationBits`

**Files:**
- Modify: `NFs/upf/internal/forwarder/gtp5g.go:601-614` (the `ie.UEIPAddress` case, IPv6 branch). If a separate UpdatePDR builder exists, mirror the change there too.

**Interfaces:**
- Consumes: parsed `v.IPv6PrefixDelegationBits uint8` (go-pfcp `UEIPAddressFields`), `gtp5gnl.PDI_UE_ADDR_IPV6_PREFIX_LEN` (Task 6).
- Produces: netlink attr 8 (u8) appended alongside `PDI_UE_ADDR_IPV6`.

- [ ] **Step 1: Append the prefix-length attr right after the IPv6 address attr**

Modify the IPv6 branch so that whenever an IPv6 UE address is emitted, a prefix-length attr (fallback 64) is emitted too:

```go
				// WNC: Handle IPv6 UE address (NEW)
				if len(v.IPv6Address) > 0 {
					if g.SupportsIPv6() {
						attrs = append(attrs, nl.Attr{
							Type:  gtp5gnl.PDI_UE_ADDR_IPV6,
							Value: nl.AttrBytes(v.IPv6Address),
						})
						// WNC: emit the UE IPv6 prefix length so gtp5g matches the /64,
						// not the exact /128 (SLAAC privacy IID differs). Fallback 64.
						plen := v.IPv6PrefixDelegationBits
						if plen == 0 {
							plen = 64
						}
						attrs = append(attrs, nl.Attr{
							Type:  gtp5gnl.PDI_UE_ADDR_IPV6_PREFIX_LEN,
							Value: nl.AttrU8(plen),
						})
						g.log.Infof("WNC: PDI UE IPv6 address: %v /%d", net.IP(v.IPv6Address), plen)
						ueIPv6 = net.IP(v.IPv6Address)
					} else {
						g.log.Warnf("WNC: IPv6 UE address present but gtp5g version %s does not support IPv6", g.version)
					}
				}
```

Verify the netlink helper name for a u8 attr. If `nl.AttrU8` does not exist in this codebase's `nl` package, use the existing pattern for single-byte attrs (grep the file/package for how `u8` attrs are built, e.g. `nl.AttrBytes([]byte{plen})`). Do not invent a helper.

- [ ] **Step 2: Confirm the PFCP field name against the vendored go-pfcp**

Run: `cd NFs/upf && GOFLAGS=-mod=mod go doc github.com/wmnsk/go-pfcp/ie.UEIPAddressFields`
Expected: shows `IPv6PrefixDelegationBits uint8`. (Verified 2026-07-27; re-confirm in case the module version changed.)

- [ ] **Step 3: Build the UPF binary**

Run: `cd /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc && make upf`
Expected: builds clean. (Reminder: the resulting `NFs/upf` go.mod/go.sum churn stays uncommitted per repo convention.)

- [ ] **Step 4: Commit (source only, NOT go.mod/go.sum)**

```bash
cd /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc/NFs/upf
git add internal/forwarder/gtp5g.go
git commit -m "feat(upf): emit PDI UE IPv6 prefix length (attr 8) from Ipv6PrefixDelegationBits

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Integration — deploy on CN, verify SLAAC downlink works, RS/RA/DAD unbroken

> **STATUS 2026-07-27: DEFERRED — code Tasks 1-7 complete and committed. User will deploy
> MANUALLY tomorrow with guidance. Do NOT bump the parent free5gc submodule pointers until
> this live verification passes.**

**Committed code to deploy (all on existing working branches):**
- gtp5g @ `0fab710` (branch my-changes-v0.9.14) — rebuild `gtp5g.ko`
- NFs/smf @ `b29ab37` (my-smf-changes-v1.3.2) — rebuild `bin/smf`
- NFs/upf @ `ddb2bb3` (my-upf-changes-v1.2.6) — rebuild `bin/upf` (go-gtp5gnl `630225a` via local replace)

**Files:** none (build + deploy + live test). Remote CN access via tmux/my-ssh per repo `CLAUDE.md`.

**Interfaces:** consumes all prior tasks. Produces the acceptance evidence.

- [ ] **Step 1: Rebuild everything locally**

Run:
```bash
cd /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/gtp5g && make clean && make
cd /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc && make smf upf
```
Expected: all build clean.

- [ ] **Step 2: Deploy the new gtp5g.ko + smf + upf to the CN and reload the module**

Use the repo's deploy path. On the CN, stop the core, unload/reload the module, restart:
```bash
tmux new-session -d -s cn 'my-ssh --target cn'
# (sync built artifacts per your existing deploy method, then:)
tmux send-keys -t cn "sudo rmmod gtp5g; sudo insmod /path/to/gtp5g.ko && lsmod | grep gtp5g" Enter
sleep 2; tmux capture-pane -t cn -p
```
Expected: `gtp5g` listed; no insmod error in `dmesg`.

- [ ] **Step 3: Bring up the core and attach the UE; confirm SLAAC still completes**

Confirm the UE still obtains its global IPv6 via RA/SLAAC (proves Task 5 did not break RS/RA/NS/NA/DAD). On the UE:
```bash
tmux send-keys -t ue "ip -6 addr show dev rmnet_data0" Enter
sleep 1; tmux capture-pane -t ue -p
```
Expected: UE has a global `2001:db8:...:<privacy-IID>/64` on its now-**unique** /64 (subnet index ≥ 1), plus `fe80::` link-local.

- [ ] **Step 4: Run the decisive downlink test (the original failing case)**

On the UE:
```bash
tmux send-keys -t ue "ping -6 2001:db8:126::1 -I rmnet_data0 -c 4" Enter
sleep 6; tmux capture-pane -t ue -p
```
Expected: **replies received** (previously 100% loss). On the CN, confirm request AND reply on the tunnel:
```bash
tmux send-keys -t cn "sudo timeout 8 tcpdump -ni upfgtp icmp6" Enter
# (re-run the UE ping while this captures)
```
Expected: both echo-request and echo-reply visible on `upfgtp`.

- [ ] **Step 5: Verify the PDR carries the /64 prefix length**

On the CN:
```bash
tmux send-keys -t cn "cat /proc/gtp5g/pdr | grep -iA3 'IPv6'" Enter
sleep 1; tmux capture-pane -t cn -p
```
Expected: the UE PDR shows the IPv6 UE address and prefix `/64`. Also `dmesg | grep 'WNC: Match PDR.*IPv6 /64'` should show the masked match firing on downlink.

- [ ] **Step 6: Two-UE disambiguation check (Approach 2 payoff)**

Attach a second UE on the same DNN. Confirm each gets a DIFFERENT /64 (subnet indices 1 and 2) and both ping `2001:db8:126::1` successfully with no cross-delivery. Capture `ip -6 addr` on both UEs and the two ping results.
Expected: distinct /64s, both succeed.

- [ ] **Step 7: Regression sweep — IPv4 and static IPv6 untouched**

- IPv4: `ping 8.8.8.8 -I rmnet_data0 -c 3` on the UE → still works.
- If any static IPv6 assignment is configured for a test SUPI, confirm that UE still receives its exact configured address (e.g. `…::10`) — the guard preserved it.
Expected: no IPv4 regression; static IPv6 addresses unchanged.

- [ ] **Step 8: Record results in the design doc**

Append a "Verification results (2026-07-27)" section to `docs/ipv6-feature/issue_ipv6_slaac_downlink_prefix_match_260724.md` with the captured ping/tcpdump/`/proc/gtp5g/pdr` evidence. Commit the doc update.

```bash
cd /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc
git add docs/ipv6-feature/issue_ipv6_slaac_downlink_prefix_match_260724.md docs/ipv6-feature/plan_ipv6_slaac_64_prefix_match_260727.md
git commit -m "docs(ipv6): record SLAAC /64 prefix-match verification results

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review Notes (author checklist — completed)

**Spec coverage vs design doc §10 components:**
- Component 1 (unique /64 allocator) → Task 1. ✅
- Component 1a (static guard) → Task 1 (Steps 4–5, `request==nil` gate). ✅
- Component 2 (SMF PDR/RA no-op verify) → Task 2. ✅
- Component 3 (go-upf emit) → Task 7. ✅
- Component 4 (go-gtp5gnl attr) → Task 6. ✅
- Component 5 (kernel struct/enum/parse + downlink + uplink) → Tasks 3, 4, 5. ✅
- Verification (§10) → Task 8. ✅

**Hard constraints honored:** RS/RA/NS/NA/DAD path (`ll_match`/`unspec_match`/`sn_multicast_match`) explicitly unchanged (Task 5); prefix length sourced from `Ipv6PrefixDelegationBits` with /64 fallback (Tasks 3,7); netlink attr appended at value 8 (Global Constants, Tasks 3,6); `NFs/upf` go.mod/go.sum left uncommitted (Task 7 Step 4).

**Type consistency:** `ue_addr_ipv6_prefixlen` (kernel `u8`), `PDI_UE_ADDR_IPV6_PREFIX_LEN` == 8 (both sides), `IPv6PrefixDelegationBits` (PFCP), `PDUAddressIPv6PrefixLen` (SMF) — used consistently across tasks.

**Known implementation-time confirmations (flagged in-plan, not placeholders):** exact `nl` u8-attr helper name in go-upf (Task 7 Step 1); whether an UpdatePDR builder needs the mirror edit (Task 7 Files); whether an existing SMF test encoded the old shared-/64 behavior (Task 1 Step 7).
