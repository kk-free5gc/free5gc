# Free5GC Authentication Fix/Debug Plan

## Objectives

- Align free5GC’s 5G-AKA SNN handling with Open5GS to eliminate “HRES* Validation Failure”.
- Build SNN from the UE’s actual PLMN (like Open5GS) and keep 3‑digit MNC formatting.

## Scope

- Touch AMF SNN construction and add targeted logs in AMF/AUSF.
- No changes to cryptographic primitives or subscription data.

## Preconditions

- Same UE/SIM used for both cores.
- free5GC logs at: /home/wnc/Downloads/source_code/free5gc_4.0.1/free5gc/free5gc.log
- Open5GS logs at: /home/wnc/Downloads/source_code/open5gs-2.6.4/open5gs_log/amf.log

## Step-by-Step Plan

### 1) Reproduce and Baseline

- Trigger registration on free5GC until you see:
    - “HRES* Validation Failure”
    - “Send Authentication Reject”
- Note the UE’s PLMN (MCC/MNC) used during the attempt.

What to extract:

- From logs or traces, record:
    - UE PLMN that AMF parsed (from SUCI or TAI).
    - RAND (hex).
    - Hxres* in AUSF (if logged).
    - HRES* computed in AMF (if logged).

Commands (optional):
rg -n "HRES\\*|Authentication Reject|Serving network|Hxres|Kseaf|Suci|PLMN" free5gc.log
### 2) Add Targeted Logging (AMF)

File: NFs/amf/internal/sbi/consumer/ausf_service.go

- Before building authInfo.ServingNetworkName, add debug logs:
    - UE’s observed PLMN (ue.PlmnId.Mcc, ue.PlmnId.Mnc)
    - The servedGuami selected (index and values)
    - The final ServingNetworkName string

Example snippet:
logger.CommLog.Infof("UE PLMN from context: mcc=%s, mnc=%s", ue.PlmnId.Mcc, ue.PlmnId.Mnc)
logger.CommLog.Infof("ServedGuami[0]: mcc=%s, mnc=%s", servedGuami.PlmnId.Mcc, servedGuami.PlmnId.Mnc)
logger.CommLog.Infof("Computed SNN: %s", authInfo.ServingNetworkName)
### 3) Change AMF SNN Source To UE’s PLMN

File: NFs/amf/internal/sbi/consumer/ausf_service.go

- Current: Uses amfSelf.ServedGuamiList[0] to build SNN.
- Target: Prefer ue.PlmnId (from SUCI/TAI). Fallback to matched servedGuami for UE’s TAI if known; else [0].

Minimal change (safe fallback, keeps 3‑digit MNC):
amfSelf := amf_context.GetSelf()
servedGuami := amfSelf.ServedGuamiList[0]

// Prefer UE PLMN if set
mcc := servedGuami.PlmnId.Mcc
mncStr := servedGuami.PlmnId.Mnc
if ue.PlmnId.Mcc != "" && ue.PlmnId.Mnc != "" {
    mcc = ue.PlmnId.Mcc
    mncStr = ue.PlmnId.Mnc
}

mnc, err := strconv.Atoi(mncStr)
if err != nil {
    return nil, nil, err
}
authInfo.ServingNetworkName = fmt.Sprintf("5G:mnc%03d.mcc%s.3gppnetwork.org", mnc, mcc)
logger.CommLog.Infof("Using SNN from UE PLMN: %s (mcc=%s mnc=%s)", authInfo.ServingNetworkName, mcc, mncStr)
Notes:

- This mirrors Open5GS which derives SNN from amf_ue->nr_tai.plmn_id.
- Keeps mnc%03d formatting to satisfy AUSF regex 5G:mnc[0-9]{3}.mcc[0-9]{3}.3gppnetwork.org.

### 4) Optional: Extra AUSF Logs For Parity

File: NFs/ausf/internal/sbi/processor/ue_authentication.go

- Log accepted SNN and derived hxres* once (development only):
logger.UeAuthLog.Infof("Authorized SNN: %s", snName)
// After hxresStar is derived
logger.Auth5gAkaLog.Infof("Derived HXRES*: %s", hxresStar)
### 5) Build and Retest

- Rebuild only AMF (and AUSF if you added logs):
make amf
# and optionally
make ausf
- Rerun registration. Expected:
    - No “HRES* Validation Failure”
    - AMF derives KAMF and proceeds

### 6) Cross‑Check With Open5GS

- Verify Open5GS SNN for the same UE PLMN:
    - Open5GS uses ogs_serving_network_name_from_plmn_id(&amf_ue->nr_tai.plmn_id) → 5G:mnc%03d.mcc%03d.3gppnetwork.org
- Ensure free5GC’s SNN string exactly matches Open5GS for the given PLMN.

### 7) Edge Cases and Validation

- Multi‑PLMN setups:
    - Ensure ue.PlmnId is populated during Registration Request parsing (SuciToStringWithError) before auth starts.
- 2‑digit MNC:
    - Storage in config/UI may be “2 or 3 digits” → SNN builder pads to 3 digits. Confirm the final string matches AUSF regex.
- If mismatch persists:
    - Log RAND and compare between cores (should be different per run unless fixed).
    - Compare AMF’s computed HRES* vs AUSF HXRES* in logs.
    - Confirm AuthType is __5_G_AKA (not EAP-AKA’ path).

## Rollback

- Revert the AMF change to use ServedGuamiList[0] if needed.
- Remove added logs or reduce to debug level for production.

## Additional Checks

- amfcfg.yaml
    - Ensure servedGuamiList and plmnSupportList includes the UE’s PLMN.
- WebConsole
    - Keep allowing 2/3‑digit MNC input, but ensure the backend always pads to 3 digits for SNN.

## Success Criteria

- free5GC no longer logs “HRES* Validation Failure”.
- AUSF confirm returns SUCCESS with Kseaf and Supi.
- Open5GS and free5GC produce identical SNN for the same UE PLMN.
