# free5GC Authentication Flow (Challenge Generation and Verification)

This document traces how free5GC generates the 5G AKA/EAP-AKA' challenge (RAND/AUTN) and how it validates the UE's Authentication Response, mapping key logs and code paths.

## Overview

- Challenge generation request log: "Handle GenerateAuthDataRequest" (UDM)
- UE auth response handling log: "Handle Authentication Response" (AMF)
- Core actors: UDM (derives AVs via Milenage/KDF), AUSF (prepares Hxres*/Kseaf and confirms results, informs UDM), AMF (pre-checks HRES*, drives NAS procedure)

## Challenge Generation (RAND/AUTN)

1) Entry point (UDM SBI)
- File: `NFs/udm/internal/sbi/api_ueauthentication.go`
- Func: `HandleGenerateAuthData(...)`
- Action: Logs "Handle GenerateAuthDataRequest" and calls `Processor.GenerateAuthDataProcedure(...)`.

2) Core derivation (UDM Processor)
- File: `NFs/udm/internal/sbi/processor/generate_auth_data.go`
- Func: `GenerateAuthDataProcedure(c, authInfoRequest, supiOrSuci)`
- Steps:
  - Fetch subscriber auth data from UDR via `QueryAuthSubsData(...)` (gets `K`, `OPc`, `SQN`, `AMF`, method).
  - Validate key lengths (`EncPermanentKey`, `EncOpcKey`).
  - Load and normalize `SQN` (hex string to bytes). If resynchronization info (`AUTS`, `RAND`) is present:
    - Recover `SQNms` and verify `MAC-S` using Milenage:
      - `F2345(opc, k, rand) → AK`, compute `SQNms = AUTS[0..5] ⊕ AK`
      - `F1(opc, k, rand, SQNms, AMF=0x0000) → MAC-S`
      - If `MAC-S` matches `AUTS[6:]`, accept re-sync and advance `SQN`.
    - Else reject with problem details.
  - Persist `SQN` increment back to UDR using `ModifyAuthenticationSubscription`.
  - Generate `RAND` (16 bytes) via `crypto/rand.Read`.
  - Run Milenage:
    - `F1(opc, k, RAND, SQN, AMF) → MAC-A, MAC-S`
    - `F2345(opc, k, RAND) → RES, CK, IK, AK, AK*`
  - Build `AUTN = (SQN ⊕ AK) || AMF || MAC-A`.
  - For 5G AKA (AuthMethod=5G_AKA):
    - Derive `XRES*` with KDF: `K = CK||IK; FC=RES*; params = SNname, RAND, RES`; take last half of KDF output.
    - Derive `Kausf` with KDF: `FC=KAUSF; params = SNname, SQN⊕AK`.
    - Return `UdmUeauAuthenticationInfoResult` with `Rand`, `Autn`, `XresStar`, `Kausf`, `AvType=5G_HE_AKA`.
  - For EAP-AKA':
    - Derive `CK'|IK'` with KDF (`FC=CK'_IK'`, params = SNname, SQN⊕AK).
    - Return `Rand`, `Autn`, `Xres`, `CkPrime`, `IkPrime`, `AvType=EAP_AKA_PRIME`.

Key locations in file:
- RAND generation: around lines ~253–255
- Resynchronization flow: ~274–317
- Milenage `F1`/`F2345`: ~412 and ~421
- AUTN construction: ~427–436
- XRES*/Kausf KDF: ~442–472
- EAP-AKA' path: ~473–501

3) AUSF preparation of data for AMF
- File: `NFs/ausf/internal/sbi/processor/ue_authentication.go`
- Func: `UeAuthPostRequestProcedure(c, authenticationInfo)`
- For 5G AKA:
  - Compute `Hxres* = SHA256( RAND || XRES* )[last 16 bytes]`.
  - Derive `Kseaf` from `Kausf`: `KDF(FC_KSEAF, SNname)`.
  - Store `XresStar`, `RAND`, `Kausf`, `Kseaf` in AUSF UE context.
  - Return `Var5gAuthData` to AMF with `RAND`, `AUTN`, and `Hxres*` plus links for 5G-AKA confirmation.
- For EAP-AKA':
  - Build EAP-AKA' Challenge (AT_RAND, AT_AUTN, AT_KDF, AT_KDF_INPUT, AT_MAC) using `IkPrime`, `CkPrime`, and identity; store `XRES`, `K_aut`, `Kausf`, `Kseaf`.

Key locations in file:
- Hxres* derivation and Kseaf: ~284–341

## UE Authentication Response Verification

1) AMF pre-check (HRES*) and AUSF confirmation
- File: `NFs/amf/internal/gmm/handler.go`
- Func: `HandleAuthenticationResponse(ue, accessType, authenticationResponse)`
- For 5G AKA:
  - Decode `RAND` from `Var5gAuthData` and read `RES*` from the NAS Authentication Response.
  - Compute `HRES* = SHA256( RAND || RES* )[last 16 bytes]`.
  - Compare with `Hxres*` from AUSF-provided `Var5gAuthData`.
    - If mismatch: either request SUCI (if GUTI used) or send Authentication Reject and trigger `AuthFailEvent`.
    - If match: call AUSF `SendAuth5gAkaConfirmRequest(RES*)` to finalize.
  - On AUSF success: set `ue.Kseaf`, `ue.Supi`, derive `Kamf` (`ue.DerivateKamf()`), and send `AuthSuccessEvent`.
- For EAP-AKA':
  - Forward EAP-Response to AUSF via `SendEapAuthConfirmRequest` and handle success/failure/ongoing per AUSF response.

Key locations in file:
- HRES* compute and compare: ~2016–2056
- Success handling: ~2063–2074
- EAP-AKA' path: ~2085 onward

2) AUSF final confirmation of UE response
- File: `NFs/ausf/internal/sbi/processor/ue_authentication.go`
- Funcs:
  - 5G-AKA: `Auth5gAkaComfirmRequestProcedure(c, confirmationData, confirmationDataResponseId)`
    - Compare received `ResStar` with stored `XresStar`.
    - On match: `AuthResult=SUCCESS`, return `Supi`, `Kseaf`; notify UDM via `SendAuthResultToUDM`.
    - On mismatch: `AuthResult=FAILURE`; notify UDM.
    - Key lines: ~491–506.
  - EAP-AKA': `EapAuthComfirmRequestProcedure(c, eapSession, eapSessionID)`
    - Verify `AT_MAC` using stored `K_aut` (HMAC-SHA256 over cleaned packet).
    - Compare `AT_RES` with stored `XRES`.
    - On success: return `Kseaf`, `Supi`, `AuthResult=SUCCESS`; notify UDM.
    - On failure: set `AuthResult=FAILURE`; notify UDM.
    - Key lines: ~96–139 (MAC/RES checks), and surrounding status handling.

3) AUSF → UDM auth result reporting
- File: `NFs/ausf/internal/sbi/consumer/udm_service.go`
- Func: `SendAuthResultToUDM(id, authType, success, servingNetworkName, udmUrl)`
- Sends `AuthEvent` to UDM `ConfirmAuth` API, recording auth success/failure.

## Key Points

- `RAND` is generated using a cryptographically secure RNG (`crypto/rand`).
- `AUTN` is constructed from Milenage outputs: `(SQN ⊕ AK) || AMF || MAC-A`.
- 5G-AKA checks are two-tiered:
  - AMF pre-check with `HRES*` vs `Hxres*` (efficient, avoids exposing keys).
  - AUSF authoritative compare `RES*` vs `XRES*` and returns `Kseaf`/`Supi`.
- Resynchronization: UDM validates `AUTS` (`F1`/`F2345`), adjusts `SQN`, and regenerates vectors.
- EAP-AKA' path uses integrity (`AT_MAC` with `K_aut`) and `AT_RES` vs `XRES` with KDF-derived `Kseaf` from EMSK.

## Code Pointers Summary

- UDM entry: `NFs/udm/internal/sbi/api_ueauthentication.go` → `HandleGenerateAuthData`
- UDM derivation: `NFs/udm/internal/sbi/processor/generate_auth_data.go` → `GenerateAuthDataProcedure`
- AUSF build/derive: `NFs/ausf/internal/sbi/processor/ue_authentication.go` → `UeAuthPostRequestProcedure`
- AMF verify: `NFs/amf/internal/gmm/handler.go` → `HandleAuthenticationResponse`
- AUSF confirm (5G-AKA): `NFs/ausf/internal/sbi/processor/ue_authentication.go` → `Auth5gAkaComfirmRequestProcedure`
- AUSF confirm (EAP-AKA'): `NFs/ausf/internal/sbi/processor/ue_authentication.go` → `EapAuthComfirmRequestProcedure`
- AUSF→UDM report: `NFs/ausf/internal/sbi/consumer/udm_service.go` → `SendAuthResultToUDM`

## Related Logs

- UDM: "Handle GenerateAuthDataRequest" → `HandleGenerateAuthData`
- AMF: "Handle Authentication Response" → `HandleAuthenticationResponse`

