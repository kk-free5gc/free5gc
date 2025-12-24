# IPv6 Implementation Plan for free5gc + gtp5g (Updated)

## Overview
- Goal: Add IPv6 UE addressing and transport to free5gc (SMF) + gtp5g (UPF), referencing Open5GS behavior.
- Strategy: Deliver in small phases with clear SMF vs. UPF/gtp5g responsibilities and acceptance checks.

## Phase 1: IPv6 UE Addressing (GTP-U over IPv4)

### Phase 1-1: SMF
*   **Config**: Add `poolsV6` per DNN/S-NSSAI (IPv6 CIDRs) in `smfcfg.yaml` and update `NFs/smf/internal/config/config.go`.
*   **Allocation**: Implement `UeIPv6Pool`; store `PDUAddressV6` (and keep `PDUAddressV4` for dual-stack later).
*   **PFCP**: Set `PDI.UEIPAddress{ V6: true, Ipv6Address: <UE> }`; keep outer header IPv4.
*   **NAS/PCO**: Encode IPv6 PDU Address; return IPv6 DNS when requested.

### Phase 1-2: UPF
*   **UPF PFCP Handler**: Update `NFs/upf/internal/pfcp/session.go` to process `UEIPAddress` with a v6 address.

### Phase 1-3: gtp5g
*   **gtp5g Netlink**: Add `GTP5G_PDI_UE_ADDR_IPV6` and plumb into PDR store via UPF application logic.
*   **gtp5g Matching**: Support UE IPv6 address match for DL PDRs.
*   **gtp5g Encapsulation**: Unchanged (outer header remains IPv4).

### Acceptance Criteria for Phase 1
*   SMF logs "Allocated UE IPv6"; UPF programs PDR with UEIPAddress.V6; IPv6 payload flows inside GTP-U over IPv4.
*   **Tests**:
    *   **Regression**: Verify that an IPv4-only PDU session can still be established without any issues.
    *   **IPv6 Session**: Verify that when a UE requests an IPv6 PDU session, the SMF correctly allocates an IPv6 address from the configured pool.
    *   **PFCP Verification**: Verify that the UPF receives a PFCP Session Establishment Request containing a PDR with the `UEIPAddress` field correctly populated for IPv6.
    *   **Data Path**: Verify that IPv6 data packets are correctly encapsulated within a GTP-U tunnel that uses an IPv4 outer header.

### How Open5GS achieves it
- Config: Allows IPv6 subnets in both SMF and UPF YAML using a single `subnet` list (e.g., `- subnet: 2001:db8:cafe::/48`) in `configs/open5gs/smf.yaml.in` and `upf.yaml.in`.
- Allocation: UPF can allocate UE IPs per PDI hints. In `src/upf/context.c`, the UPF allocates an IPv6 UE address when `ue_ip->ipv6` is set, via `ogs_pfcp_ue_ip_alloc(&cause_value, AF_INET6, ...)`, and tracks it in IPv6 hash/trie structures for framed routes.
- PFCP handling: SMF/UPF fill `PDI.UEIPAddress` with the IPv6 flag and address; outer header may remain IPv4 in this phase.
- NAS/PCO: SMF encodes IPv6 PDU Address and can supply IPv6 DNS via PCO when requested.

### What free5gc + gtp5g are missing now
- SMF address allocation: `free5gc` currently stores a single `PDUAddress` and sets UE IP in PDRs as IPv4 only in `NFs/smf/internal/context/datapath.go` (e.g., `UEIPAddress{ V4: true, Ipv4Address: ... }`). No allocation path for IPv6 exists yet, and `PDUAddressToNAS()` lacks IPv6 length/encoding.
- Config shape: This fork’s `UEIPPool` type accepts any CIDR, but examples and plumbing assume IPv4. No dedicated IPv6 pool selection per session type.
- UPF path: The UPF side in this repo is kernel-offloaded via `gtp5g`. Netlink attrs in `gtp5g/include/genl_pdr.h` only define `GTP5G_PDI_UE_ADDR_IPV4`. There’s no `...UE_ADDR_IPV6` to match IPv6 UE addresses.
- Kernel match: `gtp5g` lacks IPv6 UE address match in the PDR and won’t classify DL traffic by UE IPv6.

### Implementation details (code logic)
- SMF
  - Config parsing: Either reuse existing `pools` (CIDR accepts IPv6) or add `poolsV6`. Wire DNN/S-NSSAI to choose pool by `SelectedPDUSessionType`.
  - Allocation: Extend `SMContext.AllocUeIP()` and `findPSAandAllocUeIP()` to allocate IPv6 from the appropriate pool when `SelectedPDUSessionType == IPv6` or `IPv4v6`. Store into `PDUAddress` as a 16-byte IP for v6.
  - PDR build: In `internal/context/datapath.go`, where `UEIPAddress` is set, add branches:
    - IPv6: `UEIPAddress{ V6: true, Ipv6Address: smContext.PDUAddress }` and keep `OuterHeaderRemovalGtpUUdpIpv4` for this phase.
    - Retain IPv4 path unchanged.
  - NAS/PCO: Fill PDU Address IE for IPv6 in `gsm_build.go` by setting proper length and copying the 8-byte interface identifier per TS 24.501 formatting for IPv6; add PCO IPv6 DNS when `DNSIPv6Request` is true.
- UPF / gtp5g
  - Netlink: Add `GTP5G_PDI_UE_ADDR_IPV6` in `include/genl_pdr.h` and plumb through userspace UPF to kernel.
  - Kernel PDR: Extend PDR key to include optional IPv6 UE address; implement IPv6 address match for DL on decap path.
  - Encapsulation: No change to outer header in this phase (still IPv4). Ensure no regressions in existing IPv4 path.

## Phase 2: GTP-U Over IPv6 Transport

### Phase 2-1: SMF
*   **Interface**: Select UPF N3 IPv6 endpoint when present.
*   **PFCP**: Use `F-TEID{ V6: true, Ipv6Address }`, `OuterHeaderCreationGtpUUdpIpv6`; support NodeID/F-SEID IPv6.

### Phase 2-2: UPF
*   **UPF Config**: Update `upfcfg.yaml` and `NFs/upf/internal/config/config.go` to support an IPv6 address for the N3 interface.
*   **UPF PFCP Handler**: Process PFCP F-TEID and NodeID with IPv6 addresses.

### Phase 2-3: gtp5g
*   **gtp5g Netlink**: Add `GTP5G_F_TEID_GTPU_ADDR_IPV6` and FAR IPv6 outer-header fields.
*   **gtp5g Encapsulation**: Implement UDP/2152 over IPv6 (checksum/flowlabel correct).

### Acceptance Criteria for Phase 2
*   Capture `udp.port == 2152 && ipv6` on N3; sessions stable under load.
*   **Tests**:
    *   **Configuration**: Verify that the UPF's N3 interface can be configured with an IPv6 address in `upfcfg.yaml`.
    *   **Interface Selection**: Verify that the SMF correctly selects the UPF's IPv6 N3 interface when establishing an IPv6 PDU session.
    *   **PFCP Verification**: Verify that the `F-TEID` and `OuterHeaderCreation` fields in PFCP messages correctly use IPv6 addresses.
    *   **Data Path**: Verify that IPv6 PDU sessions are established with a GTP-U tunnel that uses an IPv6 outer header. Capture traffic on the N3 interface to confirm.

### How Open5GS achieves it
- Config: Both `smf.yaml` and `upf.yaml` accept IPv6 addresses for PFCP and GTP-U endpoints. Example templates show IPv6 alongside IPv4.
- PFCP: SMF sets `F-TEID` with IPv6 address/flag and chooses `OuterHeaderCreationGtpUUdpIpv6` when targeting an IPv6 UPF N3 address; UPF advertises/accepts NodeID/F-SEID with IPv6.
- GTP-U: The UPF’s userspace path binds GTP-U sockets for IPv6 and transmits GPDU over UDP/IPv6 when the FAR’s outer header is v6.

### What free5gc + gtp5g are missing now
- SMF interface selection: `UPFInterfaceInfo.IP(...)` is present, but datapath currently hardcodes IPv4-only `OuterHeaderCreationGtpUUdpIpv4` and sets `FTEID.V4`/`Ipv4Address` in multiple places.
- PFCP types are available, but code paths do not populate `FTEID.V6` and `Ipv6Address` nor `OuterHeaderCreationGtpUUdpIpv6`.
- gtp5g netlink attrs in `include/genl_pdr.h` and `include/genl_far.h` only include IPv4 peer addresses; there’s no `...PEER_ADDR_IPV6` and no encoder/decoder for IPv6 outer-header creation.
- Kernel datapath has no AF_INET6 sockets or IPv6 transmit path for GTP-U encapsulation.

### Implementation details (code logic)
- SMF
  - Interface picking: In `internal/context/datapath.go`, when querying `iface.IP(smContext.SelectedPDUSessionType)`, support returning IPv6 address for IPv6/IPv4v6 sessions and use it when building `FTEID` and `OuterHeaderCreation`.
  - PFCP build: Where `FTEID` and `OuterHeaderCreation` are set, add IPv6 branches:
    - `FTEID{ V6: true, Ipv6Address: upIP, Teid: ... }`
    - `OuterHeaderCreation{ OuterHeaderCreationDescription: GtpUUdpIpv6, Ipv6Address: upIP, Teid: ... }`
- UPF / gtp5g
  - Netlink: Add `GTP5G_OUTER_HEADER_CREATION_PEER_ADDR_IPV6` to `include/genl_far.h` and `GTP5G_F_TEID_GTPU_ADDR_IPV6` to `include/genl_pdr.h`; handle them in userspace encoder/decoder.
  - Kernel: Create/bind IPv6 UDP socket for GTP-U; on FAR with IPv6 peer, encapsulate GPDU with IPv6 and compute UDP checksum correctly; support path MTU/segmentation unchanged.
  - PFCP signaling: Ensure NodeID/F-SEID IPv6 is accepted end-to-end in UPF control plane and mapped to correct transport sockets.

## Phase 3: Dual-Stack (IPv4v6) PDU Sessions

### Phase 3-1: SMF
*   Allocate both v4 and v6; encode NAS for IPv4v6.
*   PFCP: install PDRs for both families; downshift when only one pool exists.
*   PCO: provide both DNS families when requested.

### Phase 3-2: UPF & gtp5g
*   Coexist IPv4 and IPv6 UE-address matches; QER/URR unchanged.

### Acceptance Criteria for Phase 3
*   UE reaches both IPv4 and IPv6 hosts; handovers unaffected.
*   **Tests**:
    *   **Session Establishment**: Verify that a UE can request and be granted an `IPv4v6` PDU session type.
    *   **Address Allocation**: Verify that the SMF allocates both an IPv4 and an IPv6 address for the session.
    *   **PFCP Verification**: Verify that the UPF receives two PDRs for the session, one for the IPv4 address and one for the IPv6 address.
    *   **Data Path**: Verify that the UE can simultaneously communicate with both IPv4 and IPv6 hosts on the data network.

### How Open5GS achieves it
- SMF: Advertises IPv4v6, allocates both addresses, encodes combined NAS PDU Address, and pushes PDRs that match UE IPv4 and IPv6 for DL. DNS options can include both families.
- UPF: Maintains separate DL matches for v4 and v6 UE addresses; FARs direct to the same AN tunnel; accounting/QoS is shared.

### What free5gc + gtp5g are missing now
- SMF storage: Only one `PDUAddress` field; needs separate `PDUAddressV4` and `PDUAddressV6` or a struct with both. `PDUAddressToNAS()` has no IPv6/IPv4v6 encoding filled.
- PDR build: `datapath.go` currently sets only one `UEIPAddress` (IPv4). No second PDR for the other family and no logic to conditionally downshift.
- Kernel: `gtp5g` lacks IPv6 UE match and thus can’t simultaneously match both families.

### Implementation details (code logic)
- SMF
  - Context model: Introduce dual fields or a struct (e.g., `type PDUAddresses struct { V4, V6 net.IP }`) and adapt alloc/release paths to manage both.
  - NAS encoding: Fill PDU Address IE with IPv4v6 format per TS 24.501 (12+1 length) and include both DNS options when requested.
  - PFCP rules: Install two DL PDRs on anchor UPF: one with `UEIPAddress.V4+Sd`, one with `UEIPAddress.V6+Sd`. UL PDRs likewise reflect the UE source family.
- UPF / gtp5g
  - Userspace: Accept both v4 and v6 UE matches when programming PDRs.
  - Kernel: Support parallel UE match entries for v4 and v6 keyed to the same FAR/QER.

## Phase 4: SLAAC via Router Advertisement (Optional)

### Phase 4-1: SMF
*   CP PDR to punt ICMPv6 RS to SMF; detect RS and send RA (prefix len 64, A|L flags).

### Phase 4-2: UPF & gtp5g
*   Ensure punt path for ICMPv6 is programmed correctly based on SMF PDR.

### Acceptance Criteria for Phase 4
*   UE auto-configures via RA; RS/RA visible in captures.
*   **Tests**:
    *   **ICMPv6 Punt**: Verify that ICMPv6 Router Solicitation messages from the UE are correctly punted to the SMF.
    *   **RA Generation**: Verify that the SMF generates and sends a valid ICMPv6 Router Advertisement message in response.
    *   **Address Configuration**: Verify that the UE can successfully auto-configure an IPv6 address using the information from the RA.

### How Open5GS achieves it
- RS/RA handling: Open5GS primarily allocates IPs centrally, but it supports IPv6 framed routes and can be paired with router advertisements in certain deployments. UPF context maintains IPv6 route lists and can steer traffic accordingly.

### What free5gc + gtp5g are missing now
- Control punt: No explicit CP punt for ICMPv6 RS frames is present. PFCP `HeaderEnrichment`/`Redirect` and PDR `ForwardingParameters` would need a control-plane punt path.
- RA source: No SMF-side RA generator exists. Needs a small RA engine or integration with a userspace RA daemon connected to a tap representing the UE subnet.

### Implementation details (code logic)
- SMF
  - PDR punt: Install a CP PDR matching `next-header == 58 (ICMPv6)` and RS types, forwarding to CP (N4) instead of UPF datapath.
  - RA generation: For a configured IPv6 prefix per DNN, craft RAs (A/L flags set) with router lifetime and DNS (RDNSS) options if desired; send back via UPF to UE.
- UPF / gtp5g
  - Ensure PDR action for ICMPv6 RS forwards to CP queue; no kernel changes beyond recognizing the punt.

## Responsibilities
- SMF: config/schema (`poolsV6`), IPv6/IPv4v6 allocation, NAS/PCO updates, PFCP v6 fields, RA handling, UPF v6 interface selection.
- UPF: PFCP handling for v6, `upfcfg.yaml` schema, programming `gtp5g` via netlink.
- gtp5g: netlink attrs (UE v6, F‑TEID v6, FAR v6), PDR store/match for IPv6, GTP‑U IPv6 encap/decap, diagnostics.

Notes:
- In this fork, `UEIPPool` already accepts IPv6 CIDRs. You can either introduce a separate `poolsV6` for clarity or reuse `pools` and branch on `SelectedPDUSessionType` when allocating. The datapath currently hardcodes IPv4 in multiple places and must be generalized.

## Key Touchpoints
- SMF: `NFs/smf/internal/config/config.go`, `internal/context/ue_ip_pool_v6.go` (new), `user_plane_information.go`, `sm_context.go` (PDUAddress*, NAS), PFCP rule build sites.
- UPF: `NFs/upf/internal/config/config.go`, `NFs/upf/internal/pfcp/session.go`.
- gtp5g: `include/genl_pdr.h`, `include/genl_far.h`, `src/genl/genl.c`, `src/pfcp/pdr.c`, `src/gtpu/encap.c`.

Additional concrete references
- free5gc SMF datapath IPv4 assumptions: `NFs/smf/internal/context/datapath.go` sets `UEIPAddress` and `OuterHeaderCreation` with IPv4-only flags/addresses in several locations; mirror these branches for IPv6 and IPv4v6.
- free5gc SMF NAS building: `NFs/smf/internal/context/gsm_build.go` uses `PDUAddressToNAS()`; extend it to set correct lengths for IPv6 and IPv4v6 and to include DNSv6 when requested.
- free5gc SMF pool model: `NFs/smf/pkg/factory/config.go` `UEIPPool` accepts CIDR generically; add validation examples with IPv6 in `smfcfg.yaml`.
- open5gs configs showing IPv6 subnets: `open5gs-2.7.6/configs/open5gs/smf.yaml.in` and `upf.yaml.in` include `- subnet: 2001:db8:cafe::/48` alongside IPv4.
- open5gs UPF IPv6 allocation path: `open5gs-2.7.6/src/upf/context.c` shows `ogs_pfcp_ue_ip_alloc(... AF_INET6 ...)` and IPv6 route handling.

## Config Examples
- `free5gc/config/smfcfg.yaml` (per DNN):
  - IPv4: `pools: [{ cidr: "10.45.0.0/16" }]`
  - IPv6: `poolsV6: [{ cidr: "2001:db8:cafe::/64" }]`
- `free5gc/config/upfcfg.yaml`:
  - `gtpu: { ipv4: "5.5.5.2", ipv6: "2001:db8:1::2" }`
- Phase 2 UPF N3 IPv6: add IPv6 address to UPF N3 interfaces; SMF selects via `UPFInterfaceInfo.IP(..., PDUSessionTypeIPv6)`.

Tip: If you do not add `poolsV6`, you can keep using `pools` and place IPv6 CIDRs there. The allocator must branch by session type to pick an IPv4 or IPv6 CIDR accordingly.

## Build & Verify
- Build gtp5g: `cd gtp5g && make && sudo make install`
- Build NFs: `cd free5gc && make nfs`
- Tests
  - SMF unit: `cd free5gc/NFs/smf && go test ./...`
  - E2E: start core; establish IPv6 session; `tcpdump -i any 'udp port 2152'` (Phase 1 IPv4 outer, Phase 2 add `ip6`).

## General Quality, Stability, and Security Guidelines

### Logging and Debugging
For traceability and easier debugging, all new log messages related to this implementation must be prefixed with `WNC`.

*   **Key areas to log**:
    *   Allocation and deallocation of IPv6 addresses, including the PDU Session ID and the allocated IP.
    *   The selected PDU session type (IPv4, IPv6, or IPv4v6) for each session.
    *   The content of key PFCP fields related to IPv6 (`UEIPAddress`, `F-TEID`, `OuterHeaderCreation`).
    *   In `gtp5g`, add logs for any errors encountered when handling IPv6-related netlink attributes or programming the datapath.

### Error Handling
*   **Pool Exhaustion**: If the IPv6 address pool is exhausted, the SMF should reject the PDU session request with an appropriate cause code (e.g., `INSUFFICIENT_RESOURCES`).
*   **UPF Capability**: If a UE requests an IPv6 session but the selected UPF does not support IPv6, the SMF should select a different UPF if possible, or reject the request.
*   **Kernel Module Errors**: If the `gtp5g` kernel module fails to program a PDR or FAR with an IPv6 address, the error must be propagated up to the UPF and SMF, and the session establishment should fail gracefully.

### Kernel Module Stability
The `gtp5g` module is a kernel component, so implementation requires extra caution. All pointers must be validated to prevent NULL pointer dereferences, and all inputs from userspace (via netlink) must be strictly validated to prevent kernel panics or crashes. Rigorous code review and static analysis are mandatory for all changes to the kernel module.

### Security
*   **Phase 4 (SLAAC)**: When handling ICMPv6 messages punted to the control plane, the SMF must validate the incoming Router Solicitation messages to prevent potential denial-of-service (DoS) attacks or other vectors. Rate limiting should be considered for these messages.
