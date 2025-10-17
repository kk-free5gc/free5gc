# IPv6 Address Allocation Enhancement Plan (free5gc + gtp5g)

## Overview
- **Goal** Enable free5gc SMF/UPF with gtp5g to allocate IPv6 UE addresses per S-NSSAI while preserving existing IPv4
semantics.
- **Approach** Mirror open5gs dual-stack flow (see `open5gs/docs/codex_IPv6_UE_Addressing_Findings.md`) and keep
architecture aligned with current IPv4 code paths.
- **Scope** SMF config/session handling, UPF data plane integration, gtp5g kernel updates, config/tooling adjustments,
validation, and documentation.

## Phase Summary
| Phase | Focus | Primary Owners | Key Deliverables |
|-------|-------|----------------|------------------|
| 0 | Design Baseline | SMF lead, UPF lead, architect | Gap analysis doc, open questions list |
| 1 | Config & Data Model Prep | SMF config maintainer, DevOps rep | Updated schemas/configs + validation |
| 2 | Control Plane Enhancements | SMF core team | Dual-stack session logic, WNC logs |
| 3 | User Plane & Kernel Updates | UPF Go team, gtp5g C team | IPv6-aware UPF & kernel handling |
| 4 | Integration & Config Validation | Integration engineer | End-to-end wiring & deployment readiness |

---

## Phase 0 – Design Baseline
- **Objectives**
  - Confirm IPv6 feature scope (per S-NSSAI pools, dual-stack expectations).
  - Align free5gc design with open5gs reference flow and identify reuse points.
- **Tasks**
  - Trace IPv4 allocation in `free5gc/NFs/smf` and map to required IPv6 hooks.
  - Review UPF/gtp5g IPv4 handling for IPv6 assumptions in `free5gc/NFs/upf` and `gtp5g/src`.
  - Compare PFCP pool management between free5gc and open5gs; catalogue missing abstractions.
  - Assess config impacts across `free5gc/config/*.yaml`, scripts, and tooling.
- **Deliverables**
  - Design baseline document with file/function pointers, risk notes, and open questions signed off by SMF, UPF, and ops stakeholders.

## Phase 1 – Config & Data Model Prep
- **Objectives**
  - Extend SMF/UPF configuration schemas for IPv6 pools per S-NSSAI without regressing IPv4 behavior.
- **Tasks**
  - Update `free5gc/NFs/smf/config/config.json` (and generated Go structs) with IPv6 fields mirroring IPv4 naming.
  - Modify `free5gc/config/smfcfg.yaml` and `free5gc/config/upfcfg.yaml` templates to include IPv6 pool definitions
and documentation.
  - Adjust context initialization (`free5gc/NFs/smf/app/context_init.go`, `free5gc/NFs/upf/app/context.go`) to persist
IPv6 metadata; add WNC-prefixed debug logs when pools are detected.
  - Implement validation routines ensuring proper IPv6 CIDR, gateway, and coexistence rules with descriptive WNC logs.
  - Verify helper scripts (`free5gc/scripts`, `free5gc/run.sh`) tolerate or propagate new fields.
- **Deliverables**
  - Schema/config diffs with unit tests for load/validate paths, updated config docs, checklist confirming IPv4-only behavior unchanged.

## Phase 2 – Control Plane Enhancements
- **Objectives**
  - Enable SMF to negotiate IPv6/IPv4v6 sessions, allocate IPv6 addresses per S-NSSAI, and manage PFCP signaling with
robust logging.
- **Tasks**
  - Extend session setup logic (`free5gc/NFs/smf/service/smf_service.go`, `context` package) to select IPv6 pools using
IPv4-parallel structures.
  - Update PFCP UE IP allocation calls to request IPv6 addresses per S-NSSAI, caching results in session context.
  - Add Router Solicitation detection and Router Advertisement responses similar to open5gs (`free5gc/NFs/smf/consumer/
`, `gtp` handlers) with WNC-prefixed logs.
  - Ensure AMF, UDM, PCF interactions propagate IPv6 PAA info (`lib/openapi`, `consumer` paths).
  - Guard dual-stack downgrade logic (e.g., fallback to IPv4-only) with unit tests and logging.
- **Deliverables**
  - Updated SMF control-plane code with tests covering IPv6 allocation paths, verified logging, and design notes for any remaining edge cases.

## Phase 3 – User Plane & Kernel Updates
- **Objectives**
  - Equip free5gc UPF and gtp5g module to handle IPv6 UE traffic aligned with PFCP policies.
- **Tasks**
  - Update UPF session handling (`free5gc/NFs/upf/service`, `context`) to accept IPv6 PDRs/FARs and configure tunnel
interfaces appropriately.
  - Extend TUN/TAP setup to assign IPv6 gateways per pool; ensure ND/RA relay requirements covered.
  - Modify PFCP encoders/decoders to include IPv6 fields where currently IPv4-only.
  - Enhance gtp5g kernel module (`gtp5g/src/*`) for IPv6 TEIDs, address matching, and encapsulation; mirror IPv4 logic
patterns with clear documentation.
  - Insert WNC-prefixed logs in UPF for key IPv6 events (allocation, packet path issues).
- **Deliverables**
  - IPv6-capable UPF and kernel module patches with integration smoke tests (e.g., mock PFCP session), and performance considerations noted.

## Phase 4 – Integration & Config Validation
- **Objectives**
  - Ensure end-to-end wiring of configs, scripts, and deployment artifacts supports IPv6 pools; validate compatibility with existing IPv4 setups.
- **Tasks**
  - Reconcile SMF/UPF config changes with deployment scripts (`free5gc/run.sh`, CI scripts) and README guidance.
  - Validate combined SMF-UPF configuration flows (start-up, reload) under IPv4-only, IPv6-only, and dual-stack
scenarios.
  - Confirm PFCP/N4 exchanges function with updated message content using integration harnesses.
  - Document operational procedures for configuring IPv6 gateways/tunnels.
- **Deliverables**
  - Integration report capturing configuration permutations, known limitations, and required operator steps; updated
documentation (`free5gc/docs`, run scripts).



## Cross-Phase Considerations
- **Logging** All new logs prefixed with `WNC` and aligned with existing verbosity controls.
- **Naming Consistency** Follow IPv4 naming patterns (e.g., `UeIpv6`, `Pool6`) to minimize refactor risk.
- **Backward Compatibility** IPv4-only deployments must operate unchanged when IPv6 fields are absent.
- **Documentation** Keep operator-facing docs synchronized with code changes; highlight IPv6 prerequisites (sysctl, kernel version).
- **Risk & Mitigation**
  - Kernel/gtp5g incompatibilities → maintain feature flags and fallback paths.
  - Config migration errors → add validation tooling and sample configs.
  - Performance regressions → schedule benchmarks during Phases 3–4.

## Milestones & Checkpoints
1. **Phase 0 sign-off** – Requirements clarified, risks documented.
2. **Phase 1 completion** – Config schemas merged, IPv4 regression tests passing.
3. **Phase 2/3 integration demo** – Basic IPv6 UE session established in lab.
4. **Phase 4 validation** – Dual-stack deployment rehearsal successful.

## Optional Follow-up
- After all Phase 2 features are validated, consider updating `NFs/smf/internal/sbi/processor/oam.go` so the OAM `PDUSessionInfo` response surfaces both IPv4 and IPv6 UE addresses for dual-stack sessions.
- Add a regression unit test that covers static IPv6 assignments sourced from UDM but residing in dynamic pools to ensure allocation/release bookkeeping stays intact.

- Implement static IPv6 Inventory Snapshot 
  - UDM / WebConsole can configure dynamically, in real world, we cannot restart CN just because we want to edit one subscriber

| Source | Scope | Entry | Prefix Length | Notes |
| --- | --- | --- | --- | --- |
| `config/smfcfg.yaml` | `UPF.fast.t-mobile.com` | `ipv6StaticPools`: `2001:db8:0111:100::/64` | `/64` | `iidAllocation=manual`, `raProfile=default` |
| `config/smfcfg.yaml` | `UPF.fast.t-mobile.com` | `ipv6StaticAssignments`: `imsi-001010123456789 -> 2001:db8:0111:100::10` | `/64` | `comment="UE-1 static IPv6"` |
| `config/smfcfg.yaml` | `UPF.fast.t-mobile.com` | `ipv6StaticAssignments`: `imsi-001010123456790 -> 2001:db8:0111:100::11` | `/64` | `comment="UE-2 static IPv6"` |
| UDM / WebConsole | Subscriber profiles | `staticIpAddress` entries using `ipv6Addr`/`ipv6Prefix` | per entry | Persisted via Nudm SDM; mirror SMF static pool coverage |

- Pending Action: add automated static IPv6 coverage tests once Phase 2 implementation is complete.
