# Authentication Debug: PLMN Mismatch Analysis and Enhanced Logging

**Date:** August 28, 2025  
**Issue:** Authentication failures due to PLMN mismatches between CU/DU configuration and SIM card  
**Solution:** Enhanced logging for easier debugging of PLMN-related authentication issues

## Problem Statement

When the PLMN configured in the CU/DU differs from the SIM's PLMN, the 5G core network rejects authentication with an "HRES* Validation Failure". The original logging provided insufficient information to quickly identify PLMN misconfigurations.

### Original Issue Symptoms
- **Success Case**: CU/DU PLMN matches SIM PLMN → Authentication succeeds
- **Failure Case**: CU/DU PLMN differs from SIM PLMN → Authentication fails with "HRES* Validation Failure"

### Root Cause Analysis
The authentication failure occurs because:
1. **UDM** generates authentication vectors using the `ServingNetworkName` from the CU/DU configuration
2. **UE (SIM)** calculates its response using its home network PLMN
3. **Mismatch** in PLMN → Different cryptographic derivations → Authentication failure

## Example PLMN Mismatch Scenario

```
ServingPLMN: MCC=466, MNC=011  ← CU/DU Configuration
UE_PLMN:     MCC=466, MNC=110  ← SIM Card Configuration
```

**Technical Flow:**
- UDM uses `ServingNetworkName: 5G:mnc011.mcc466.3gppnetwork.org` for XRES* derivation
- UE calculates RES* using its home PLMN (466-110)
- AMF computes HRES* = SHA256(RAND || RES*) but values don't match
- Result: "HRES* Validation Failure"

## Enhanced Logging Implementation

### Files Modified

#### 1. UDM Authentication Challenge Generation
**File:** `NFs/udm/internal/sbi/processor/generate_auth_data.go`

**Added Logging Points:**
```go
// Challenge generation request context
logger.UeauLog.Infof("WNC: AUTH CHALLENGE GENERATION - SUPI/SUCI: %s, ServingNetworkName: %s", supiOrSuci, authInfoRequest.ServingNetworkName)

// Subscription data from UDR
logger.UeauLog.Infof("WNC: AUTH SUBSCRIPTION DATA - SUPI: %s, AuthMethod: %s", supi, authSubs.AuthenticationSubscription.AuthenticationMethod)
logger.UeauLog.Infof("WNC: AUTH SUBSCRIPTION DATA - EncPermanentKey: %s, EncOpcKey: %s", authSubs.AuthenticationSubscription.EncPermanentKey, authSubs.AuthenticationSubscription.EncOpcKey)

// Generated authentication vectors
logger.UeauLog.Infof("WNC: AUTH VECTORS GENERATED (5G_AKA) - SUPI: %s", supi)
logger.UeauLog.Infof("WNC: AUTH VECTORS - RAND: %s, AUTN: %s", av.Rand, av.Autn)
logger.UeauLog.Infof("WNC: AUTH VECTORS - XRES*: %s, ServingNetworkName: %s", av.XresStar, authInfoRequest.ServingNetworkName)
```

#### 2. AMF Authentication Response Validation
**File:** `NFs/amf/internal/gmm/handler.go`

**Added Logging Points:**
```go
// Authentication response context
ue.GmmLog.Infof("WNC: AUTH RESPONSE - SUPI: %s, GUTI: %s, AccessType: %s", ue.Supi, ue.Guti, accessType)
if ue.Tai.PlmnId != nil && ue.Tai.PlmnId.Mcc != "" && ue.Tai.PlmnId.Mnc != "" {
    ue.GmmLog.Infof("WNC: AUTH RESPONSE - ServingPLMN: MCC=%s, MNC=%s", ue.Tai.PlmnId.Mcc, ue.Tai.PlmnId.Mnc)
}
if ue.PlmnId.Mcc != "" && ue.PlmnId.Mnc != "" {
    ue.GmmLog.Infof("WNC: AUTH RESPONSE - UE_PLMN: MCC=%s, MNC=%s", ue.PlmnId.Mcc, ue.PlmnId.Mnc)
}

// HRES* validation failure details
ue.GmmLog.Errorf("WNC: HRES* VALIDATION FAILED - SUPI: %s", ue.Supi)
ue.GmmLog.Errorf("WNC: HRES* DEBUG - RAND: %s", av5gAka.Rand)
ue.GmmLog.Errorf("WNC: HRES* DEBUG - RES*: %s", hex.EncodeToString(resStar[:]))
ue.GmmLog.Errorf("WNC: HRES* DEBUG - Calculated_HRES*: %s", hResStar)
ue.GmmLog.Errorf("WNC: HRES* DEBUG - Expected_HXRES*: %s", av5gAka.HxresStar)

// HRES* validation success details
ue.GmmLog.Infof("WNC: HRES* VALIDATION SUCCESS - SUPI: %s", ue.Supi)
ue.GmmLog.Infof("WNC: HRES* SUCCESS - RAND: %s, RES*: %s", av5gAka.Rand, hex.EncodeToString(resStar[:]))
```

### Key Implementation Decisions

#### PLMN Field Access Pattern
**Challenge:** Determining correct field access for PLMN data
**Solution:** 
- `ue.PlmnId` is a struct value type → Use `if ue.PlmnId.Mcc != "" && ue.PlmnId.Mnc != ""`
- `ue.Tai.PlmnId` is a pointer type → Use `if ue.Tai.PlmnId != nil && ue.Tai.PlmnId.Mcc != "" && ue.Tai.PlmnId.Mnc != ""`

**Rationale:** Check both field existence and meaningful data (non-empty strings)

## Sample Enhanced Log Output

### Failure Case (PLMN Mismatch)
```
[INFO][UeauLog] WNC: AUTH CHALLENGE GENERATION - SUPI/SUCI: imsi-466110000000548, ServingNetworkName: 5G:mnc011.mcc466.3gppnetwork.org
[INFO][UeauLog] WNC: AUTH SUBSCRIPTION DATA - SUPI: imsi-466110000000548, AuthMethod: 5G_AKA
[INFO][UeauLog] WNC: AUTH VECTORS GENERATED (5G_AKA) - SUPI: imsi-466110000000548
[INFO][UeauLog] WNC: AUTH VECTORS - RAND: abc123..., AUTN: def456...
[INFO][UeauLog] WNC: AUTH VECTORS - XRES*: ghi789..., ServingNetworkName: 5G:mnc011.mcc466.3gppnetwork.org

[INFO][GmmLog] WNC: AUTH RESPONSE - SUPI: imsi-466110000000548, GUTI: ..., AccessType: AN_3GPP
[INFO][GmmLog] WNC: AUTH RESPONSE - ServingPLMN: MCC=466, MNC=011  ← CU/DU Config
[INFO][GmmLog] WNC: AUTH RESPONSE - UE_PLMN: MCC=466, MNC=110      ← SIM Card
[ERROR][GmmLog] HRES* Validation Failure (received: 7e74c9bb4e41b590aeba7746c2f2f6ae, expected: e4b1ccba3e04d11b6913a591e92f1cd3)
[ERROR][GmmLog] WNC: HRES* VALIDATION FAILED - SUPI: imsi-466110000000548
[ERROR][GmmLog] WNC: HRES* DEBUG - RAND: abc123...
[ERROR][GmmLog] WNC: HRES* DEBUG - ServingPLMN: MCC=466, MNC=011
[ERROR][GmmLog] WNC: HRES* DEBUG - UE_PLMN: MCC=466, MNC=110
```

### Success Case (PLMN Match)
```
[INFO][UeauLog] WNC: AUTH CHALLENGE GENERATION - SUPI/SUCI: imsi-466110000013068, ServingNetworkName: 5G:mnc110.mcc466.3gppnetwork.org
[INFO][GmmLog] WNC: AUTH RESPONSE - ServingPLMN: MCC=466, MNC=110  ← CU/DU Config
[INFO][GmmLog] WNC: AUTH RESPONSE - UE_PLMN: MCC=466, MNC=110      ← SIM Card (MATCH!)
[INFO][GmmLog] WNC: HRES* VALIDATION SUCCESS - SUPI: imsi-466110000013068
[DEBUG][GmmLog] Authentication Success
```

## Debugging Benefits

### Before Enhancement
- Generic "HRES* Validation Failure" message
- No visibility into PLMN configurations
- Required deep code analysis to understand mismatch

### After Enhancement  
- **Immediate PLMN visibility**: ServingPLMN vs UE_PLMN comparison
- **Complete authentication context**: SUPI, RAND, RES*, HRES* values
- **ServingNetworkName traceability**: Links network name to authentication vectors
- **WNC prefix filtering**: Easy log filtering with `grep "WNC:"`

## Resolution Strategies

### Option 1: Fix CU/DU Configuration
```bash
# Change CU/DU PLMN from 466-011 to 466-110 to match SIM
# Update CU/DU configuration files to use correct PLMN
```

### Option 2: Update SIM Configuration
```bash
# Change SIM's home PLMN from 466-110 to 466-011 to match network
# Reprogram SIM card or update subscriber data in UDR
```

### Option 3: Network Sharing Setup
```bash
# Configure proper roaming/sharing agreements if PLMN difference is intentional
# Update AMF configuration to support multiple PLMNs
```

## Build Verification

Both network functions compile successfully with enhanced logging:
```bash
make udm  # ✓ Success
make amf  # ✓ Success
```

## Future Enhancements

1. **Automatic PLMN Mismatch Detection**: Add warning when ServingPLMN ≠ UE_PLMN
2. **Configuration Validation**: Pre-deployment PLMN consistency checks
3. **Metrics Integration**: Track PLMN mismatch authentication failures
4. **Alert System**: Automated notifications for repeated PLMN mismatches

## Conclusion

The enhanced authentication logging provides comprehensive visibility into PLMN-related authentication failures, making it significantly easier to diagnose and resolve configuration mismatches between CU/DU and SIM card PLMNs. The "WNC:" prefixed logs enable quick identification of authentication context and troubleshooting information.

**Key Takeaway**: PLMN consistency between network configuration and SIM cards is critical for successful 5G authentication. This enhanced logging makes such misconfigurations immediately apparent rather than requiring deep technical analysis.