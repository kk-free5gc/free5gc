# free5GC Authentication Flow (RAND/AUTN and Response Verification)

## High-Level Flow
- AMF requests auth from AUSF; AUSF queries UDM for an Authentication Vector (AV).
- UDM generates `RAND` and `AUTN` (plus `XRES*`, `KAUSF` or `CK'/IK'`) and returns to AUSF.
- AUSF prepares the challenge for UE (5G AKA or EAP-AKA').
- UE responds. AMF/AUSF verify (`RES*`/EAP-RES and MAC), then derive `Kseaf` and proceed.

## Where RAND/AUTN Are Generated (UDM)
- Entrypoint and log: `NFs/udm/internal/sbi/api_ueauthentication.go` → `HandleGenerateAuthData` (logs "Handle GenerateAuthDataRequest").
- Core logic: `NFs/udm/internal/sbi/processor/generate_auth_data.go` → `GenerateAuthDataProcedure`.

Key steps (Milenage-based):
- Fetch auth subscription from UDR: `QueryAuthSubsData` (K, OPC, SQN, AMF).
- Generate `RAND` (16 bytes): `crypto/rand.Read(RAND)`.
- Re-synchronization (optional): `auts` handled via `aucSQN` (F2345 to get AK; F1 to get MAC-S) and SQN recalculation.
- Increment SQN in UDR: `ModifyAuthenticationSubscription` (replace `/sequenceNumber`).
- Compute Milenage primitives:
  - F1 → `MAC-A` (for `AUTN`) and `MAC-S` (for resync)
  - F2345 → `RES`, `CK`, `IK`, `AK`, `AK*`
- Build `AUTN`: `AUTN = (SQN ⊕ AK) || AMF || MAC-A`.

Derivations and AV building:
- 5G AKA (AuthType `__5_G_AKA`):
  - `XRES* = KDF(CK||IK, SNname, RAND, RES)` → use `ueauth.FC_FOR_RES_STAR_XRES_STAR_DERIVATION`.
  - `KAUSF = KDF(CK||IK, SNname, SQN⊕AK)` → `FC_FOR_KAUSF_DERIVATION`.
  - Return AV with `Rand`, `Autn`, `XresStar`, `Kausf`, `AvType: 5_G_HE_AKA`.
- EAP-AKA' (AuthType `EAP_AKA_PRIME`):
  - `CK' || IK' = KDF(CK||IK, SNname, SQN⊕AK)` → `FC_FOR_CK_PRIME_IK_PRIME_DERIVATION`.
  - Return AV with `Rand`, `Autn`, `Xres`, `CkPrime`, `IkPrime`, `AvType: EAP_AKA_PRIME`.

References:
- `GenerateAuthDataProcedure`: lines ~240–506.
- Milenage invocations: F1/F2345 at lines ~414 and ~421.
- AUTN construction: lines ~430–436.

## How AUSF Issues the Challenge
- AUSF→UDM call: `NFs/ausf/internal/sbi/consumer/udm_service.go` → `GenerateAuthDataApi` builds request and parses `UdmUeauAuthenticationInfoResult`.
- Processor: `NFs/ausf/internal/sbi/processor/ue_authentication.go` → `UeAuthPostRequestProcedure`.

5G AKA path:
- Compute `Hxres* = SHA-256(RAND||XRES*)[last 128 bits]` and store; derive `Kseaf = KDF(Kausf, SNname)`; respond with `Var5gAuthData` (`rand`, `autn`, `hxres*`) and a confirmation link `/5g-aka-confirmation`.

EAP-AKA' path:
- From `CkPrime/IkPrime`, compute EAP-AKA' keys via PRF: `K_encr, K_aut, K_re, MSK, EMSK` where `K_aut` used for MAC and `Kausf = EMSK[0:32]`.
- Derive `Kseaf = KDF(Kausf, SNname)`.
- Build EAP packet (RFC 5448): attributes `AT_RAND`, `AT_AUTN`, `AT_KDF` (value 1), `AT_KDF_INPUT` (SNname), and `AT_MAC` over the payload using `K_aut`. Base64-encoded as `Var5gAuthData`, with link `/eap-session`.

References:
- 5G AKA handling: lines ~268–346 and `Kseaf` at ~320–334.
- EAP-AKA' handling and EAP encoding: lines ~346–436, `EapEncodeAttribute` and `CalculateAtMAC`.

## How The Response Is Verified
- AMF log and entry: `NFs/amf/internal/gmm/handler.go` → `HandleAuthenticationResponse` (logs "Handle Authentication Response").

5G AKA verification (in AMF then AUSF):
- AMF computes `HRES* = SHA-256(RAND||RES*)[last 128 bits]` and compares with AUSF-provided `Hxres*`.
- If match, AMF calls AUSF confirm: `consumer.SendAuth5gAkaConfirmRequest`, which triggers AUSF `Auth5gAkaComfirmRequestProcedure` to compare `Res*` with stored `XresStar`. On success, AUSF returns `Kseaf` and `Supi`.

EAP-AKA' verification (in AUSF):
- AMF passes the EAP-Response to AUSF via `SendEapAuthConfirmRequest`.
- AUSF `HandleEapAuthComfirmRequest` decodes EAP-AKA':
  - Verifies `AT_MAC` using `K_aut`.
  - Compares `AT_RES` with stored `XRES`.
  - On success, sets `Kseaf`, `Supi`, returns EAP-Success to AMF; informs UDM via `ConfirmAuth`.

References:
- AMF 5G AKA: handler lines ~1998–2060; HRES* vs HXRES* at ~2022–2035; confirm at ~2046–2060.
- AUSF 5G AKA confirm: lines ~490–517.
- AUSF EAP-AKA' confirm: lines ~64–147 and ~162–201.

## Notifications to UDM/UDR
- AUSF → UDM `ConfirmAuth`: `NFs/ausf/internal/sbi/consumer/udm_service.go` → `SendAuthResultToUDM` with `authType`, `success`, `ServingNetworkName`.
- UDM → UDR record: `ConfirmAuthDataProcedure` creates `AuthenticationStatus` in UDR.

## Notable Data and Config
- Subscription fields (from UDR): `EncPermanentKey` (K), `EncOpcKey` (OPC), `SequenceNumber.Sqn` (SQN), `AuthenticationManagementField` (AMF).
- Serving network name format (AMF): `5G:mnc<MNC>.mcc<MCC>.3gppnetwork.org`.
- Resync handling expects `AUTS` and optional `RAND` from UE; recalculates SQN and updates UDR.

## File Map (quick jump)
- UDM API/logs: `NFs/udm/internal/sbi/api_ueauthentication.go`.
- UDM generation: `NFs/udm/internal/sbi/processor/generate_auth_data.go`.
- AUSF consume/confirm: `NFs/ausf/internal/sbi/consumer/udm_service.go` and `NFs/ausf/internal/sbi/processor/ue_authentication.go`.
- AMF handling: `NFs/amf/internal/gmm/handler.go` and `NFs/amf/internal/sbi/consumer/ausf_service.go`.

## Sequence Diagram
```mermaid
sequenceDiagram
    autonumber
    participant UE
    participant AMF
    participant AUSF
    participant UDM
    participant UDR

    AMF->>AUSF: UeAuthenticationsPost (supiOrSuci, SN-name)
    AUSF->>UDM: GenerateAuthData (supiOrSuci, SN-name, AUTS?)
    UDM->>UDR: QueryAuthSubsData (K, OPC, SQN, AMF)
    UDM->>UDM: Milenage F1/F2345; RAND; AUTN=(SQN⊕AK)||AMF||MAC-A
    UDM-->>AUSF: AV {RAND, AUTN, XRES*/XRES, KAUSF or CK'/IK'}
    AUSF->>AUSF: Derive Kseaf; HXRES* or build EAP packet
    AUSF-->>AMF: UeAuthenticationCtx {challenge + links}
    AMF->>UE: NAS Authentication Request or EAP-Request/AKA'

    alt 5G AKA
        UE->>AMF: Authentication Response (RES*)
        AMF->>AMF: HRES*=SHA256(RAND||RES*)[128 LSB]
        AMF->>AMF: Compare HRES* vs HXRES*
        AMF->>AUSF: 5G-AKA Confirmation (RES*)
        AUSF->>AUSF: Compare RES* vs stored XRES*
        AUSF-->>AMF: ConfirmationDataResponse {SUCCESS, Kseaf, SUPI}
        AUSF->>UDM: ConfirmAuth(success)
        UDM->>UDR: Create AuthenticationStatus
    else EAP-AKA'
        UE->>AMF: EAP-Response/AKA' (AT_RES, AT_MAC)
        AMF->>AUSF: EapAuthMethod (EAP payload)
        AUSF->>AUSF: Verify AT_MAC with K_aut; compare AT_RES vs XRES
        AUSF-->>AMF: EAP-Success {Kseaf, SUPI} or EAP-Failure
        AUSF->>UDM: ConfirmAuth(success/failure)
        UDM->>UDR: Create AuthenticationStatus
    end
```
