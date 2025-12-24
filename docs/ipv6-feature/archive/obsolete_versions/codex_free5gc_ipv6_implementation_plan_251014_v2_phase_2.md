# Phase 2 – Control Plane Enhancements (Detailed Plan)

## 1. Objectives & Guardrails
- Deliver dual-stack session handling in SMF while ensuring IPv4-only flows remain untouched.
- Maintain backward compatibility: when IPv6 pools are absent, fall back to existing IPv4 logic automatically.
- Instrument with `WNC`-prefixed logs for every new IPv6 control-plane branch to aid troubleshooting.
- Converge on deterministic, unit-testable logic prior to user-plane (Phase 3) work.

## 2. Workstreams & Tasks

### 2.1 SM Context & Session Lifecycle
1. **Session Type Propagation**  
   - Ensure `SelectedPDUSessionType` is set for every SM context (NAS request fallback, default selection).  
   - Update `UPFSelectionParams` and `DataPath` builders to always carry the session type.  
   - Files: `internal/context/sm_context.go`, `internal/context/user_plane_information.go`, `internal/sbi/processor/gsm_handler.go`.
2. **Dual-Stack PDU Address Fields**  
   - Extend SM context to hold both IPv4 and IPv6 PDUs (reuse `net.IP`, add helper getters).  
   - Maintain compatibility with NAS encoding (IPv4, IPv6, IPv4v6).  
   - Files: `internal/context/sm_context.go`, `internal/context/gsm_build.go`.
3. **Static Assignment Support**  
   - Respect `staticIpAddress` entries (IPv4/IPv6) from UDM when allocating addresses.  
   - Add precedence rules: static bind > static pool > dynamic pool per family.  
   - Files: `internal/context/sm_context.go`, `internal/context/user_plane_information.go`.

### 2.2 UE IP Allocation Pipeline
1. **Pool Selection Logic**  
   - Enhance `SelectUPFAndAllocUEIP` to handle IPv4-only, IPv6-only, and IPv4v6 requests.  
   - Evaluate pool availability per family; implement graceful downgrade when dual-stack not possible.  
   - Files: `internal/context/user_plane_information.go`, `internal/context/ue_ip_pool.go`.
2. **Pool Bookkeeping Updates**  
   - Track IPv6 allocations within `UeIPPool` (release, overlap checks).  
   - Add unit tests covering IPv6 dynamic and static pools.  
   - Files: `internal/context/ue_ip_pool.go`, `internal/context/user_plane_information_test.go`.
3. **Selection Parameter Builder**  
   - Populate `UPFSelectionParams.PDUAddress` for IPv6 statics when present.  
   - Ensure non-IP sessions bypass allocation appropriately.  
   - Files: `internal/context/sm_context.go`.

### 2.3 PFCP Session Construction
1. **UE IP IE Enhancements**  
   - Populate `pfcpType.UEIPAddress` with IPv6 values (set `V6`, `Sd`, `Ipv6d` flags, prefix bits).  
   - Handle dual-stack by adding both IPv4 and IPv6 IEs when required.  
   - Files: `internal/context/datapath.go`, `internal/pfcp/message/build.go`.
2. **PDN Type Negotiation**  
   - Set PFCP `PDNType` to IPv4/IPv6/IPv4v6/Non-IP based on session type.  
   - Validate UPF support; introduce fallback errors with `WNC` logs if unsupported.  
   - Files: `internal/pfcp/message/build.go`, `internal/pfcp/handler/handler.go` (error handling).
3. **Session Context Cache**  
   - Extend `PFCPSessionContext` to store IPv6 UE address for later PFCP modifications.  
   - Files: `internal/context/pfcp_session_context.go`.

### 2.4 NAS/NGAP Signaling
1. **NAS PDU Address Encoding**  
   - Update `BuildGSMPDUSessionEstablishmentAccept` to include IPv6 / dual-stack addresses.  
   - Add downgrade cause values when only one family is allocated.  
   - Files: `internal/context/gsm_build.go`.
2. **NGAP Transfer Data**  
   - Teach `BuildPDUSessionResourceSetupRequestTransfer` to emit IPv6 UL NG-U addresses and TEIDs.  
   - Ensure GTP tunnel params align with UPF interface selection for IPv6 endpoints.  
   - Files: `internal/context/ngap_build.go`, `internal/context/upf.go`.
3. **Protocol Configuration Options**  
   - Support IPv6 DNS/PCSCF responses when UE requests them.  
   - Files: `internal/context/gsm_build.go`, `internal/context/pco.go`.

### 2.5 Router Solicitation / Advertisement Handling
1. **PFCP Triggers**  
   - Inspect PFCP Session Report Requests for Router Solicitation events (PFCP Event Reporting).  
   - Define event-to-action mapping in SMF to trigger RA workflow.  
   - Files: `internal/pfcp/handler/handler.go`, `internal/context/sm_context.go` (helper stub).
2. **RA Payload Construction**  
   - Implement IPv6 RA builder in SMF (modelled after open5gs) with pool prefix and lifetimes.  
   - Coordinate with UPF/gtp5g (Phase 3) via PFCP or SBI triggers (placeholder log).  
   - Files: `internal/context/router_advertisement.go` (new), `internal/logger` (log scope).
3. **Observability**  
   - Add `WNC` logs on RS receipt, RA dispatch attempts, and error conditions.  
   - Files: `internal/logger/logger.go` (additional loggers), referenced code paths.

### 2.6 Inter-NF Interfaces & API Models
1. **OpenAPI Model Refresh**  
   - Regenerate `lib/openapi` if newer swagger revisions include IPv6 fields (e.g., `Ipv6AddressPrefix`).  
   - Confirm go.mod/go.sum updates limited to intentional versions.  
   - Files: `go.mod`, `go.sum`, generated model directories.
2. **PCF Interaction**  
   - Populate `SmPolicyContextData.Ipv6AddressPrefix` and `Ipv4Address`/`Ipv6Address` where available.  
   - Handle absence gracefully (retain IPv4-only behaviour).  
   - Files: `internal/sbi/consumer/pcf_service.go`.
3. **UDM Subscription Parsing**  
   - Read IPv6 static entries from `SessionManagementSubscriptionData`.  
   - Add validation + logs when assignments lie outside configured pools.  
   - Files: `internal/sbi/consumer/udm_service.go`.

### 2.7 Logging & Metrics
- Ensure every new log carries `WNC` prefix and reflects actionable info.  
- Optionally extend Prometheus counters (Phase 3 candidate) – log placeholders only in Phase 2.  
- Files: `internal/logger/*.go`, targeted call sites.

## 3. Testing Strategy
1. **Unit Tests**  
   - Expand `ue_ip_pool_test.go` for IPv6 allocation, release, overlap.  
   - Add `user_plane_information_test.go` cases for dual-stack selection and fallback.  
   - Add PFCP builder tests covering IPv4, IPv6, dual-stack PDN types.  
   - New router solicitation handler tests using mocked PFCP messages.
2. **Integration Tests**  
   - Update `test/pdu_session_*` to request IPv6/IPv4v6 and assert NAS/NGAP payloads.  
   - Add mocked PCF test (`internal/sbi/consumer/pcf_service_test.go`) verifying IPv6 field propagation.
3. **Manual / Smoke**  
   - Bring up minimal SMF+UDR environment using IPv6 pool config to validate RA log path (no actual RA, expect stub log).  
   - Verify legacy IPv4 config unchanged (`make test` baseline).

## 4. Dependencies & Sequencing
1. Complete Phase 1 config/schema changes merged.  
2. Align with Phase 3 owners on RA signalling boundary (document interim stub).  
3. Confirm UDM test data includes IPv6 static entries for coverage.  
4. Keep gtp5g untouched in Phase 2; only log scaffolding for RA.

## 5. Deliverables & Exit Criteria
- Code merged with unit tests passing and `go test ./...` clean.  
- Documentation snippet (Phase 4) capturing new logs and downgrade behaviour.  
- Verified control-plane flows for:  
  1. IPv4-only UE (no regression).  
  2. IPv6-only UE (new).  
  3. Dual-stack UE with IPv6 pool shortage (fallback to IPv4 w/ cause code).  
- Open issues for RA handoff to Phase 3 clearly tracked.

## 6. Open Risks & Mitigations
| Risk | Impact | Mitigation |
|------|--------|------------|
| Missing IPv6 fields in current OpenAPI dependency | PCF/UDM contexts lack prefix info | Regenerate models or add local shim structs in Phase 2 if upstream update unavailable |
| Router Advertisement scope creep | Timeline slip into Phase 3 | Limit Phase 2 to detection + logging; document Phase 3 contract |
| Dual-stack downgrade mis-signalled | UE receives wrong NAS cause | Unit-test downgrade branches; add integration test for IPv4-only fallback |
| Legacy configs missing IPv6 blocks | Unexpected nil pointer paths | Guard checks + default IPv4 path (existing behaviour) |

## 7. Timeline (Indicative)
- **Week 1:** Session lifecycle + pool selection + unit tests.  
- **Week 2:** PFCP/NAS/NGAP updates, PCF/UDM propagation, regression tests.  
- **Week 3:** Router solicitation scaffolding, integration tests, polish & documentation hooks.



