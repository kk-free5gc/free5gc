# IPv6 User Plane Interface Specification

**Version:** 1.0-draft
**Date:** 2025-10-28
**Status:** Review Draft

---

## 1. Scope & Goals

### 1.1 Purpose
This document specifies the interface contract between free5GC user plane components to enable IPv6 UE traffic support while preserving existing IPv4 functionality and dual-stack capabilities.

### 1.2 In-Scope Components
- **SMF (Session Management Function):** PFCP session control and Router Advertisement orchestration
- **UPF (User Plane Function):** Packet forwarding, IPv6 routing, and RA injection
- **go-gtp5gnl:** Userspace netlink library for GTP-U kernel programming
- **gtp5g kernel module:** Linux kernel GTP-U encapsulation and packet processing

### 1.3 Alignment with Phase 3 Objectives
- Enable IPv6 UE traffic support in free5GC UPF + gtp5g
- Preserve existing IPv4 behavior and dual-stack negotiation from Phase 2
- Version-gate IPv6 datapath logic on gtp5g netlink API
- Provide incremental deployment path: land control-plane plumbing first, activate kernel datapath when ready
- Maintain configuration and operator workflow stability

---

## 2. Versioning & Capability Discovery

### 2.1 Genetlink Family Version Bump

The `gtp5g` genetlink family version will be incremented to signal IPv6 capability:

- **Current Version:** 1
- **IPv6-capable Version:** 2

### 2.2 Capability Probing Sequence

```
UPF Startup:
  1. Query gtp5g netlink family version via CTRL_CMD_GETFAMILY
  2. If version >= 2:
       - Enable IPv6 attribute programming
       - Report IPv6 capability to SMF via PFCP Node Report
  3. If version < 2:
       - Operate in IPv4-only mode
       - Log: "WNC: gtp5g version %d lacks IPv6 support, operating in IPv4-only mode"
```

### 2.3 WNC Downgrade Logging Policy

All capability mismatches and feature downgrades MUST be logged with `WNC` prefix:

- `WNC: gtp5g version mismatch (expected >= 2, got %d), IPv6 disabled`
- `WNC: Router Solicitation received but RA injection unavailable (kernel stub)`
- `WNC: Dual-stack session downgraded to IPv4-only due to kernel limitation`

---

## 3. Netlink Attribute Schema

### 3.1 New IPv6 Attributes

| Attribute Name | Enum ID | Type | Length | Context | Validation |
|----------------|---------|------|--------|---------|------------|
| `GTP5G_PDI_UE_ADDR_IPV6` | 15 | Binary | 16 bytes | PDI | Reject :: and multicast (ff00::/8) |
| `GTP5G_F_TEID_GTPU_ADDR_IPV6` | 8 | Binary | 16 bytes | F-TEID | Non-zero, routable address |
| `GTP5G_SDF_FILTER_SRC_IPV6` | 20 | Binary | 16 bytes | SDF Filter | IPv6 address or prefix |
| `GTP5G_SDF_FILTER_DST_IPV6` | 21 | Binary | 16 bytes | SDF Filter | IPv6 address or prefix |
| `GTP5G_SDF_FILTER_SRC_IPV6_PREFIX_LEN` | 22 | U8 | 1 byte | SDF Filter | 0-128 |
| `GTP5G_SDF_FILTER_DST_IPV6_PREFIX_LEN` | 23 | U8 | 1 byte | SDF Filter | 0-128 |
| `GTP5G_IPV6_FLOW_LABEL` | 24 | U32 | 4 bytes | PDI | 20-bit value (0x00000-0xFFFFF) |

### 3.2 Dual-Stack Semantics

- **IPv4-only session:** Provide only IPv4 attributes (existing behavior)
- **IPv6-only session:** Provide only IPv6 attributes (new)
- **Dual-stack session:** Provide BOTH IPv4 AND IPv6 attributes in the same netlink message
  - Kernel MUST create TWO PDR entries (one for AF_INET, one for AF_INET6)
  - Both share the same SEID and PDR ID context
  - Different hash table keys for packet lookup

### 3.3 IPv6 Flow Label Rules

- Flow label attribute is OPTIONAL for IPv6 sessions
- When present, kernel MUST match on the 20-bit IPv6 flow label field
- When absent, kernel ignores flow label in packet matching
- Encapsulated packets preserve original flow label value

### 3.4 Error Codes

| Error Code | Meaning | UPF Action |
|------------|---------|------------|
| `-EINVAL` | Malformed IPv6 address or invalid prefix length | Reject PFCP session, report failure to SMF |
| `-EOPNOTSUPP` | IPv6 attributes sent to v1 kernel | Downgrade to IPv4, log WNC warning |
| `-ENOMEM` | Kernel memory allocation failed | Retry once, then fail session |
| `-EEXIST` | Duplicate PDR entry | Log error, check for PFCP session conflict |

---

## 4. Userspace Programming Model

### 4.1 PFCP Session Create Flow (IPv6)

```
SMF → PFCP Session Establishment Request (PDN Type: IPv6 or IPv4v6)
  ↓
UPF:
  1. Parse PFCP IEs (Create PDR, Create FAR, PDN Type, UE IP Address)
  2. Check gtp5g version >= 2
  3. Build netlink message:
       - Add GTP5G_PDI_UE_ADDR_IPV6 (UE IPv6 address)
       - Add GTP5G_F_TEID_GTPU_ADDR_IPV6 (UPF N3 endpoint)
       - Add GTP5G_SDF_FILTER_* (if SDF filters present)
       - Add IPv4 attrs alongside for dual-stack
  4. Send NL_CMD_ADD_PDR to gtp5g
  5. Check return code:
       - Success: Continue with FAR programming
       - -EOPNOTSUPP: Downgrade session to IPv4, log WNC
       - Other error: Fail PFCP session
  ↓
SMF ← PFCP Session Establishment Response (with allocated IPv6 address)
```

### 4.2 Attribute Ordering

Netlink attributes SHOULD be ordered as follows for consistency:
1. Session identifiers (SEID, PDR ID)
2. IPv4 attributes (if present)
3. IPv6 attributes (if present)
4. Common attributes (QFI, Gate Status, etc.)

### 4.3 Dual-Stack Handling

For IPv4v6 PDN sessions:
```c
// Userspace (go-gtp5gnl)
pdr.UEAddress = ue_ipv4        // e.g., 10.60.0.5
pdr.UEAddressV6 = ue_ipv6      // e.g., 2001:db8:cafe::5
pdr.FTEID.Address = upf_n3_ipv4
pdr.FTEID.AddressV6 = upf_n3_ipv6

// Kernel creates TWO PDR entries:
// PDR_1: AF_INET key={10.60.0.5, TEID}
// PDR_2: AF_INET6 key={2001:db8:cafe::5, TEID}
```

### 4.4 Router Advertisement Hook Expectations

Upon receiving Router Solicitation from UE:
1. SMF detects RS via PFCP Session Report (Future: N4 extension)
2. SMF calls UPF RA injection API:
   ```
   POST /upf/v1/sessions/{seid}/inject-ra
   {
     "pdr_id": 1,
     "ra_payload": "<base64-encoded ICMPv6 RA packet>",
     "lifetime": 1800
   }
   ```
3. UPF forwards to gtp5g via new netlink operation (see Section 5)

---

## 5. Router Advertisement Interface

### 5.1 Operation Code

New genetlink command: `GTP5G_CMD_INJECT_RA`

### 5.2 Netlink Payload Fields

| Attribute | Type | Description |
|-----------|------|-------------|
| `GTP5G_RA_SEID` | U64 | PFCP Session ID |
| `GTP5G_RA_PDR_ID` | U32 | Target PDR ID for RA injection |
| `GTP5G_RA_PAYLOAD` | Binary | Complete ICMPv6 RA packet (variable length, max 1280 bytes) |
| `GTP5G_RA_LIFETIME` | U32 | Router lifetime in seconds (0 = immediate expiry) |

### 5.3 Kernel Processing (When Implemented)

1. Validate SEID and PDR_ID exist
2. Verify PDR is IPv6-capable (has UE IPv6 address)
3. Encapsulate RA payload in GTP-U packet:
   - Outer IP: UPF N3 address → gNodeB address (from PDR context)
   - GTP-U header: TEID from PDR
   - Inner IP: Link-local fe80:: → UE IPv6 address
   - ICMPv6 RA: As provided in payload
4. Send via GTP-U tunnel
5. Return 0 on success

### 5.4 Stub Response (Current Implementation)

Until kernel RA injection is implemented:
```c
case GTP5G_CMD_INJECT_RA:
    return -EOPNOTSUPP;  // Not yet implemented
```

### 5.5 UPF Retry/Log Guidance

```go
// UPF internal/forwarder/gtp5g.go
err := g.InjectRA(seid, pdrID, raPayload, lifetime)
if err == syscall.EOPNOTSUPP {
    log.Warnf("WNC: RA injection not supported by kernel (SEID %d), RS ignored", seid)
    return nil  // Non-fatal
}
if err != nil {
    log.Errorf("WNC: RA injection failed (SEID %d): %v", seid, err)
    return err
}
```

---

## 6. Error Handling & Logging

### 6.1 Kernel Return Code Mapping

| Kernel Error | UPF Interpretation | SMF Action |
|--------------|-------------------|------------|
| `0` | Success | Continue session |
| `-EINVAL` | Invalid IPv6 address or attr | Fail PFCP session, send error response |
| `-EOPNOTSUPP` | Feature not available | Downgrade to IPv4, log WNC, continue session |
| `-ENOMEM` | Out of memory | Retry once, then fail session |
| `-ENOENT` | PDR/FAR not found | Log error, check PFCP state machine |

### 6.2 Mandatory WNC Logs

All IPv6-related errors and downgrades MUST include `WNC` prefix:

**Capability Mismatch:**
```
WNC: gtp5g version 1 does not support IPv6 (need >= 2), session %d downgraded to IPv4
```

**Malformed Payload:**
```
WNC: Invalid IPv6 address in PFCP PDR (UE address: %s), session rejected
WNC: IPv6 prefix length out of range (%d), must be 0-128
```

**RA Stub:**
```
WNC: Router Solicitation received (SEID %d) but RA injection unavailable (kernel returns -EOPNOTSUPP)
```

### 6.3 SMF Error Response

When UPF reports PFCP session failure due to IPv6 issues:
```
PFCP Session Establishment Response:
  Cause: System failure (19)
  Offending IE: Create PDR
  (Optional) User Plane IP Resource Information: IPv4-only fallback address
```

---

## 7. Safety & Operational Guardrails

### 7.1 Development Best Practices

**Manual Module Management:**
- Do NOT use `make install` during development
- Load module manually: `sudo insmod gtp5g/gtp5g.ko`
- Unload safely: `sudo rmmod gtp5g` (requires no active sessions)
- Check for memory leaks: `sudo cat /sys/kernel/debug/kmemleak` after unload

**Kernel Debug Symbols:**
```bash
# Build with debug info for better crash analysis
cd gtp5g
make CFLAGS="-g -O0"
```

**Boot Safety:**
- Do NOT add gtp5g to `/etc/modules-load.d/` until thoroughly tested
- Keep module out of initramfs
- Have recovery plan: boot with `init=/bin/bash` if kernel panics on load

### 7.2 IPv6 Sanity Checks

Kernel MUST reject:
- Unspecified address (`::`) as UE address (exception: during negotiation)
- Multicast addresses (`ff00::/8`) as UE unicast address
- UE addresses with non-zero prefix length > 128
- Flow label values exceeding 20 bits (> 0xFFFFF)

Kernel SHOULD warn (but not reject):
- Link-local UE addresses (`fe80::/10`) - may be valid in some deployments
- IPv4-mapped IPv6 addresses (`::ffff:0:0/96`) - suggest using native IPv4 attrs

### 7.3 Rollback Strategy

If IPv6 deployment causes issues:
1. SMF/UPF: Disable `enableIPv6: false` in config (Phase 2 addition)
2. Restart SMF/UPF services (preserves existing sessions per PFCP spec)
3. Reload older gtp5g module version (v1 without IPv6 attrs)
4. Verify IPv4-only sessions work correctly
5. Investigate root cause before re-enabling

---

## 8. Testing Expectations

### 8.1 go-gtp5gnl Coverage

**Unit Tests:**
- Encode/decode all new IPv6 attributes
- Validate attribute length and type checks
- Test dual-stack message construction
- Verify error handling for malformed input

**Test Cases:**
```go
func TestPDRWithIPv6UEAddress(t *testing.T) {
    pdr := &PDR{
        SEID: 123,
        PDRID: 1,
        UEAddressV6: net.ParseIP("2001:db8::1"),
    }
    msg := EncodePDR(pdr)
    decoded := DecodePDR(msg)
    assert.Equal(t, pdr.UEAddressV6, decoded.UEAddressV6)
}

func TestDualStackPDR(t *testing.T) {
    // Verify both IPv4 and IPv6 attrs coexist
}
```

### 8.2 UPF Mock Tests

**Control Plane Tests:**
- Parse PFCP Session Establishment with IPv6 PDN Type
- Generate correct netlink messages for IPv6-only and dual-stack
- Handle version detection and downgrade gracefully
- RA injection API (stub response validation)

**Mock gtp5g Responses:**
```go
type MockGTP5G struct {
    version int
}

func (m *MockGTP5G) AddPDR(pdr *PDR) error {
    if m.version < 2 && pdr.UEAddressV6 != nil {
        return syscall.EOPNOTSUPP
    }
    return nil
}
```

### 8.3 SMF Unit Tests

**Session Negotiation:**
- IPv4-only UE → IPv4 session (regression test)
- IPv6-only UE → IPv6 session (new)
- Dual-stack UE → IPv4v6 session (new)
- IPv6 UE + IPv4-only UPF → downgrade to IPv4 (new)

**Router Solicitation Handling:**
```go
func TestRouterSolicitationWithRAStub(t *testing.T) {
    // Simulate RS from UE
    // Verify SMF calls UPF RA API
    // Verify WNC log when -EOPNOTSUPP returned
}
```

### 8.4 Kernel Selftests

**Netlink Round-Trip:**
```bash
# tools/testing/selftests/net/gtp5g_ipv6_attrs.sh
# Send GTP5G_CMD_ADD_PDR with IPv6 attrs, verify kernel response
```

**Packet Matching:**
- IPv6 uplink: UE sends IPv6 packet → matched by PDR → forwarded via FAR
- IPv6 downlink: DN sends to UE IPv6 → GTP-U decap → delivered to UE
- Dual-stack: Both IPv4 and IPv6 packets coexist in same session

### 8.5 Regression Matrix

| Scenario | IPv4 Attrs | IPv6 Attrs | Expected Result |
|----------|-----------|-----------|-----------------|
| Legacy IPv4 | ✓ | ✗ | Pass (no regression) |
| IPv6-only | ✗ | ✓ | Pass (new) |
| Dual-stack | ✓ | ✓ | Pass (new) |
| IPv6 on v1 kernel | ✗ | ✓ | Downgrade to IPv4, WNC log |
| Malformed IPv6 | ✗ | Invalid | -EINVAL returned |

---

## 9. Open Issues & Decisions

### 9.1 RA Transport Finalization

**Issue:** Current plan uses HTTP/gRPC for SMF→UPF RA injection. Should this be embedded in PFCP or remain out-of-band?

**Options:**
1. **PFCP Extension:** Define new PFCP Session Modification with RA IE (requires PFCP spec change)
2. **Out-of-band API:** Use existing HTTP service in UPF (faster to implement, non-standard)
3. **Netlink Direct:** SMF talks to gtp5g directly (bypasses UPF, complex privilege model)

**Decision:** TBD
**Owner:** SMF/UPF architects
**Due Date:** M0 (Week 0)

---

### 9.2 Version Numbering Strategy

**Issue:** Should gtp5g version bump be major (v1→v2) or minor (v1.0→v1.1)?

**Implications:**
- **Major bump:** Signals breaking change, aligns with semver
- **Minor bump:** Signals backward-compatible addition

**Recommendation:** Major bump (v2) because userspace must explicitly check for IPv6 capability
**Owner:** gtp5g maintainer
**Due Date:** M0 (Week 0)

---

### 9.3 Dual-Stack Success Criteria

**Issue:** How do we define "working" dual-stack?

**Proposed Criteria:**
1. UE receives both IPv4 and IPv6 addresses via PFCP
2. IPv4 and IPv6 traffic flow simultaneously without interference
3. Metrics show no packet loss increase compared to single-stack
4. RA injection works for IPv6 neighbor discovery

**Measurement Plan:**
- Packet capture: Verify both stacks active in same PDU session
- Performance test: Compare throughput IPv4-only vs dual-stack
- Scale test: 1000 dual-stack sessions, monitor kernel memory

**Owner:** QA/Integration team
**Due Date:** M4 (Week 4-5)

---

### 9.4 Flow Label Usage

**Issue:** Should we mandate flow label support or make it optional?

**Current Spec:** Optional attribute (`GTP5G_IPV6_FLOW_LABEL`)
**Concern:** If UE doesn't set flow label, match efficiency may degrade

**Options:**
1. **Optional:** Kernel ignores if not present (current plan)
2. **Mandatory:** Reject PDRs without flow label for IPv6
3. **Heuristic:** Use flow label if present, fall back to 5-tuple

**Decision:** Keep optional (Option 1)
**Rationale:** Not all UEs populate flow label; strict requirement breaks compatibility
**Owner:** Kernel/UPF leads
**Status:** Closed

---

### 9.5 IPv4-Mapped IPv6 Address Handling

**Issue:** What to do with `::ffff:192.0.2.1` (IPv4-mapped IPv6)?

**Current Behavior:** Undefined
**Proposed Rule:** Accept but log WNC warning suggesting native IPv4 attrs

**Kernel Check:**
```c
if (IN6_IS_ADDR_V4MAPPED(&ue_addr_v6)) {
    pr_warn("WNC: IPv4-mapped IPv6 address detected, consider using IPv4 attrs instead\n");
    // Continue processing as IPv6
}
```

**Owner:** Kernel maintainer
**Due Date:** M2 (Week 2-3)

---

### 9.6 RA Caching and Lifetime Management

**Issue:** Should kernel cache RA payloads or regenerate on every RS?

**Options:**
1. **Stateless:** SMF generates RA on-demand, kernel just forwards (current plan)
2. **Cached:** Kernel stores RA, responds to RS autonomously (reduces SMF load)

**Pros/Cons:**
- Stateless: Simpler kernel, flexible RA content, higher latency
- Cached: Faster response, kernel complexity, stale configuration risk

**Decision:** Start with stateless (Option 1), revisit caching in future phase
**Owner:** UPF/kernel leads
**Due Date:** M3 (Week 3-4)

---

### 9.7 Performance Benchmarking Plan

**Issue:** Need baseline and targets for IPv6 vs IPv4 performance

**Metrics:**
- Throughput: Gbps per core (target: ≥ 95% of IPv4 performance)
- Latency: RTT increase (target: < 1ms additional)
- CPU usage: % increase (target: < 10%)
- Memory: Kernel slab usage (PDR/FAR hash tables)

**Test Setup:**
- Tool: iperf3 with IPv4 and IPv6 modes
- Traffic: 1000 concurrent flows, 60s duration
- Environment: Dedicated lab, isolated network

**Owner:** Performance engineering
**Due Date:** M5 (Week 5+)

---

### 9.8 Upstream Kernel Submission

**Issue:** Should gtp5g IPv6 patches be submitted to mainline Linux?

**Considerations:**
- gtp5g is out-of-tree module (higher review burden)
- IPv6 support aligns with kernel networking roadmap
- Maintenance burden shifts to netdev community

**Recommendation:** Submit for review after free5GC deployment stabilizes
**Owner:** Kernel maintainer + upstream liaison
**Due Date:** Post-M5 (future phase)

---

## 10. Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0-draft | 2025-10-28 | Claude Code | Initial interface specification |

---

## 11. References

- [3GPP TS 29.244](https://www.3gpp.org/DynaReport/29244.htm) - PFCP Protocol Specification
- [3GPP TS 29.281](https://www.3gpp.org/DynaReport/29281.htm) - GTP-U Protocol Specification
- [RFC 8200](https://datatracker.ietf.org/doc/html/rfc8200) - IPv6 Specification
- [RFC 4861](https://datatracker.ietf.org/doc/html/rfc4861) - IPv6 Neighbor Discovery
- free5GC Phase 3 Implementation Plan (codex_free5gc_ipv6_implementation_plan_251014_v2_phase_3.md)
- free5GC Phase 2 Dual-Stack Config (implemented)
