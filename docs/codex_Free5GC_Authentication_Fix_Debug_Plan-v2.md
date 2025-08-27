# Authentication Flow Comparison: free5GC vs Open5GS

## Summary
- Symptom: free5GC rejects authentication with “HRES* Validation Failure”, while the same UE/SIM authenticates successfully on Open5GS.
- Root cause: free5GC AMF constructs the Serving Network Name (SNN) from the first configured PLMN (`servedGuamiList[0]`) instead of the UE’s PLMN (from TAI). Open5GS derives SNN from the UE’s PLMN. Mismatched SNN causes different XRES*/HXRES* and KSEAF derivation, resulting in HRES* mismatch and Authentication Reject.

## Key Differences
- **SNN Source**
  - free5GC: Uses `amfSelf.ServedGuamiList[0].PlmnId` to build `5G:mnc%03d.mcc%s.3gppnetwork.org`.
  - Open5GS: Uses the UE’s TAI PLMN: `ogs_serving_network_name_from_plmn_id(&amf_ue->nr_tai.plmn_id)`.
- **Multi‑PLMN Behavior**
  - free5GC: Static; ignores which PLMN the UE actually registered with.
  - Open5GS: Dynamic; uses the PLMN observed from the UE.
- **MNC Formatting**
  - Both zero‑pad MNC to 3 digits in the SNN. Padding is not the issue; the PLMN source is.

## Root Cause (free5GC)
- When multiple PLMNs are configured (e.g., 466/11, 001/01, 311/480), free5GC always builds SNN from the first item (e.g., `mnc011.mcc466`). If the UE registers on another PLMN (e.g., `311/480`), the UE computes RES* with `5G:mnc480.mcc311.3gppnetwork.org` while AUSF/AMF use `5G:mnc011.mcc466.3gppnetwork.org`. This guarantees HRES* mismatch at AMF and triggers Authentication Reject.

## Evidence (files/lines)
- free5GC SNN construction from static config:
  - File: `NFs/amf/internal/sbi/consumer/ausf_service.go`
    - Uses `amfSelf.ServedGuamiList[0]` and `fmt.Sprintf("5G:mnc%03d.mcc%s.3gppnetwork.org", ...)`.
- free5GC HRES* failure and reject path:
  - File: `NFs/amf/internal/gmm/handler.go` (TS 33.501 Annex A.5 calc and compare)
    - Logs `HRES* Validation Failure (received: ..., expected: ...)` and then `Send Authentication Reject`.
- Open5GS SNN derivation from UE’s PLMN:
  - File: `src.bak/amf/nausf-build.c`
    - `AuthenticationInfo.serving_network_name = ogs_serving_network_name_from_plmn_id(&amf_ue->nr_tai.plmn_id);`
- Logs showing behavior:
  - free5GC: `free5gc.log` contains HRES* mismatch and Authentication Reject lines.
  - Open5GS: `open5gs_log/udm.log` shows SNN e.g., `5G:mnc480.mcc311.3gppnetwork.org` and successful flow.

## Fix Plan (free5GC)
- **Goal**: Align free5GC’s AMF SNN derivation with Open5GS to eliminate HRES* mismatches.
- **Target file**: `NFs/amf/internal/sbi/consumer/ausf_service.go`
- **Change**:
  - Prefer `ue.Tai.PlmnId` (the PLMN seen on the air) to build SNN.
  - Fallback to `ue.PlmnId` if TAI’s PLMN is not set.
  - If still not available, try to match `amfSelf.ServedGuamiList` against UE’s PLMN; otherwise last‑resort to index 0.
  - Build SNN as `5G:mnc<MNC(3d)>.mcc<MCC>.3gppnetwork.org` with MNC left‑padded to 3 chars.
- **Add logging**: Emit the SNN and the source PLMN used (MCC/MNC and “source: TAI/UE/Config”).
- **Rebuild & test**:
  - `make amf ausf`, run UE registration.
  - Expected: No “HRES* Validation Failure”; Authentication succeeds.
- **Validation across MNC lengths**:
  - Test with 2‑digit and 3‑digit MNCs to confirm consistent success.

## Quick Debug Steps
- Confirm the UE’s PLMN (MCC/MNC) from gNB or AMF logs (TAI).
- Ensure AUSF sees the same SNN as the UE implies. If needed, temporarily log `AuthenticationInfo.ServingNetworkName` in AUSF `UeAuthPostRequestProcedure`.
- Compare with Open5GS logs for the same UE; verify SNN strings match.

## Relevant Log Excerpts
- free5GC failure (from `free5gc.log`):
  - `Serving network authorized` (AUSF)
  - `HRES* Validation Failure (...)` (AMF)
  - `Send Authentication Reject` (AMF)
- Open5GS success (from `open5gs_log/udm.log`):
  - `"servingNetworkName": "5G:mnc480.mcc311.3gppnetwork.org"`

## References
- free5GC code/logs:
  - `NFs/amf/internal/sbi/consumer/ausf_service.go`
  - `NFs/amf/internal/gmm/handler.go`
  - `config/amfcfg.yaml` (contains multiple PLMNs)
  - `docs/codex_analyze_authentication_flow_1.md`, `docs/codex_analyze_authentication_flow_2.md`
  - `free5gc.log`
- Open5GS code/logs:
  - `src.bak/amf/nausf-build.c` (SNN from UE PLMN)
  - `docs/codex_analyze_auth_process.md`
  - `open5gs_log/amf.log`, `open5gs_log/udm.log`

