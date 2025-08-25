# UE Policy Delivery Implementation Discussion

**Date:** 2025-01-11  
**Topic:** Implementing UE Policy Delivery "DL NAS Transport/Manage UE Policy Command" in free5GC  
**Status:** Design Complete, Ready for Implementation

## Overview

This document outlines the complete implementation plan for UE Policy delivery in free5GC, specifically implementing the "DL NAS Transport - Manage UE Policy Command" functionality based on real-world examples and following the existing free5GC patterns.

## Background

### Original Plan
- Implementation based on `ue_policy_delivery_plan.md`
- 4 phases: AMF Registration & Association, PCF Policy Generation, AMF Policy Relay, Verification
- Initial implementation used hardcoded URSP generation

### Key Updates from Discussion
1. **Real-world Examples**: Incorporated two real-world DL NAS Transport examples:
   - **QXDM Example**: Simple configuration (MCC=001, MNC=01, single URSP rule)
   - **Wireshark Example**: Complex configuration (MCC=208, MNC=32, dual URSP rules)

2. **Flexible Architecture**: Learned from `BuildRegistrationAccept` in `amf/internal/gmm/message/build.go` to create a flexible, configurable approach instead of rigid binary serialization.

3. **Extensible Design**: Built system to easily support future UE Policy configurations.

## Implementation Architecture

### Core Design Principles
1. **Follow free5GC Patterns**: Use same approach as `BuildRegistrationAccept`
2. **Configuration-Based**: Use structured configurations instead of hardcoded serialization
3. **Real-world Compatibility**: Support actual network examples
4. **Extensible**: Easy to add new policy profiles
5. **WNC Logging**: Comprehensive logging with "WNC:" prefix for debugging

### Key Components

#### 1. UE Policy Configuration Structure
```go
type UEPolicyConfig struct {
    PTI                 uint8           // Procedure Transaction Identity
    PLMN               PlmnConfig      // PLMN configuration
    UPSC               uint8           // UE Policy Section Contents
    URSPRules          []URSPRuleConfig // URSP rules list
}

type URSPRuleConfig struct {
    Precedence         uint8
    TrafficDescriptor  TrafficDescriptorConfig
    RouteSelection     []RouteSelectionConfig
}
```

#### 2. Flexible Builder Function
```go
func BuildManageUEPolicyCommand(ue *context.AmfUe, accessType models.AccessType, 
    policyConfig *UEPolicyConfig) ([]byte, error)
```

#### 3. Pre-defined Configurations
- **QXDM Profile**: `GetQXDMUEPolicyConfig()` - Simple single rule
- **Wireshark Profile**: `GetWiresharkUEPolicyConfig()` - Complex dual rules
- **Profile Selector**: `GetUEPolicyConfigByProfile(profile string)`

## Detailed Implementation Plan

### Phase 1: AMF - Initial Registration & Association Request

**File:** `NFs/amf/internal/gmm/handler.go`  
**Location:** After line 772 (`SendRegistrationAccept` call)

```go
// SendRegistrationAccept is at line 772
gmm_message.SendRegistrationAccept(ue, anType, nil, nil, nil, nil, nil)

// NEW: Request UE Policy Association immediately after registration accept
logger.GmmLog.Infof("WNC: AMF Initiating UE Policy Association for SUPI: %s", ue.Supi)
if err := requestUEPolicyAssociation(ue); err != nil {
    ue.GmmLog.Errorf("WNC: AMF Failed to create UE Policy Association: %v", err)
    // Continue without failing registration - policy delivery is optional
} else {
    ue.GmmLog.Infof("WNC: AMF UE Policy Association request sent successfully for SUPI: %s", ue.Supi)
}

return nil
```

**New Components:**
1. **UE Policy Control Client** in `NFs/amf/internal/sbi/consumer/pcf_service.go`
2. **UE Context Extension** in `NFs/amf/internal/context/amf_ue.go`
3. **Association Helper Function** `requestUEPolicyAssociation(ue)`

### Phase 2: PCF - Association, Internal Trigger, and Policy Notification

**File:** `NFs/pcf/internal/sbi/api_uepolicy.go`  
**Replace:** `HTTPCreateIndividualUEPolicyAssociation` with full implementation

```go
func (s *Server) HTTPCreateIndividualUEPolicyAssociation(c *gin.Context) {
    logger.UePolicyLog.Infoln("WNC: PCF Handle UE Policy Association Create")
    
    // Process request, create association
    response, problemDetails := processor.HandleCreateUEPolicyAssociation(request)
    
    // Start async policy delivery
    go func() {
        logger.UePolicyLog.Infoln("WNC: PCF Starting async UE Policy delivery")
        if err := processor.InitiateInitialUEPolicyDelivery(response.PolAssoId); err != nil {
            logger.UePolicyLog.Errorf("WNC: PCF Failed to deliver initial UE Policy: %v", err)
        }
    }()
    
    c.JSON(http.StatusCreated, response)
}
```

**New Components:**
1. **UE Policy Context** in `NFs/pcf/internal/context/ue.go`
2. **UE Policy Processor** in `NFs/pcf/internal/sbi/processor/uepolicy.go`
3. **AMF Notification Consumer** in `NFs/pcf/internal/sbi/consumer/amf_service.go`

### Phase 3: AMF - Receiving and Relaying Policy via DL NAS Transport

**File:** `NFs/amf/internal/sbi/api_communication.go`  
**Add:** UE Policy notification handler

```go
{
    Name:    "UEPolicyUpdateNotify",
    Method:  http.MethodPost,
    Pattern: "/ue-policies/:polAssoId/update-notify",
    APIFunc: s.HTTPUEPolicyUpdateNotify,
}
```

**File:** `NFs/amf/internal/gmm/message/build.go`  
**Add:** Flexible UE Policy builder (main implementation)

### Phase 4: Flexible Message Building System

**Core Builder Function:**
```go
func BuildManageUEPolicyCommand(ue *context.AmfUe, accessType models.AccessType, 
    policyConfig *UEPolicyConfig) ([]byte, error) {
    
    // Build UE Policy payload using flexible configuration
    policyPayload, err := buildUEPolicyPayload(policyConfig)
    
    // Use existing DL NAS Transport builder
    return BuildDLNASTransport(ue, accessType, nasMessage.PayloadContainerTypeUEPolicy, 
        policyPayload, 0, nil, nil, 0)
}
```

## Real-World Examples Analysis

### QXDM Example Configuration
```yaml
Profile: QXDM
PTI: 128
PLMN: MCC=001, MNC=01
UPSC: 0
URSP Rules:
  - Precedence: 255
    Traffic Descriptor:
      Type: IPv4RemoteAddress
      Address: 192.168.3.2/255.255.255.255
      Match-All: true
      DNN: internet
    Route Selection:
      - Precedence: 255
        Components:
          - S-NSSAI: SST=0x01, SD=0x000001
          - DNN: internet
          - Access Type: 3GPP (1)
```

### Wireshark Example Configuration
```yaml
Profile: Wireshark
PTI: 1
PLMN: MCC=208, MNC=32
UPSC: 3
URSP Rules:
  - Precedence: 1
    Traffic Descriptor:
      Type: DNN
      DNN: business
    Route Selection:
      - Precedence: 255
        Components:
          - S-NSSAI: SST=1, SD=14868753
          - PDU Session Type: IPv4 (1)
          - Access Type: 3GPP (1)
  - Precedence: 2
    Traffic Descriptor:
      Type: Match-All
    Route Selection:
      - Precedence: 255
        Components:
          - S-NSSAI: SST=1, SD=14610978
          - DNN: internet
          - PDU Session Type: IPv4 (1)
          - Access Type: 3GPP (1)
```

## Files to Modify/Create

### AMF Files
1. **`NFs/amf/internal/sbi/consumer/pcf_service.go`**
   - Add UE Policy Control client
   - Add `UEPolicyControlCreate()` method

2. **`NFs/amf/internal/context/amf_ue.go`**
   - Add UE Policy fields: `UePolicyAssociationId`, `PolicyProfile`
   - Add search method: `AmfUeFindByUePolicyAssociationId()`

3. **`NFs/amf/internal/gmm/handler.go`**
   - Add UE Policy Association request after registration (line 772)
   - Add helper function `requestUEPolicyAssociation()`

4. **`NFs/amf/internal/sbi/api_communication.go`**
   - Add UE Policy notification route and handler

5. **`NFs/amf/internal/sbi/processor/uepolicy.go`** (NEW)
   - `HandleUEPolicyUpdateNotification()`
   - Profile determination logic

6. **`NFs/amf/internal/gmm/message/build.go`**
   - **MAIN IMPLEMENTATION**: Add complete flexible UE Policy building system
   - `BuildManageUEPolicyCommand()`
   - All configuration structures and builders
   - `GetQXDMUEPolicyConfig()`, `GetWiresharkUEPolicyConfig()`

### PCF Files
1. **`NFs/pcf/internal/context/ue.go`**
   - Add UE Policy context: `UEPolicyData map[string]*UeUEPolicyData`
   - Add `UeUEPolicyData` structure

2. **`NFs/pcf/internal/sbi/api_uepolicy.go`**
   - Replace stub implementations with full handlers
   - `HTTPCreateIndividualUEPolicyAssociation()` with async policy delivery

3. **`NFs/pcf/internal/sbi/processor/uepolicy.go`** (NEW)
   - `HandleCreateUEPolicyAssociation()`
   - `InitiateInitialUEPolicyDelivery()`
   - Profile-based policy generation

4. **`NFs/pcf/internal/sbi/consumer/amf_service.go`**
   - Add `SendUEPolicyUpdateNotification()` method

## Usage Examples

### For Testing with QXDM Configuration
```go
// In AMF notification handler
policyConfig := gmm_message.GetUEPolicyConfigByProfile("qxdm")
nasPayload, err := gmm_message.BuildManageUEPolicyCommand(ue, accessType, policyConfig)
```

### For Testing with Wireshark Configuration
```go
// In AMF notification handler
policyConfig := gmm_message.GetUEPolicyConfigByProfile("wireshark")
nasPayload, err := gmm_message.BuildManageUEPolicyCommand(ue, accessType, policyConfig)
```

### Adding New Configurations
```go
func GetCustomUEPolicyConfig() *UEPolicyConfig {
    return &UEPolicyConfig{
        PTI:  200,
        PLMN: PlmnConfig{MCC: "310", MNC: "410"},
        UPSC: 5,
        URSPRules: []URSPRuleConfig{
            // Custom rules here
        },
    }
}
```

## Key Benefits of This Approach

1. **Real-world Compatibility**: Handles actual network configurations
2. **Flexible Architecture**: Easy to extend for new scenarios
3. **Follows free5GC Patterns**: Uses same approach as existing builders
4. **Comprehensive Logging**: Full WNC logging for debugging
5. **Configuration-Based**: No hardcoded binary serialization
6. **Profile Selection**: Intelligent selection based on UE characteristics
7. **Future-Proof**: Easy to add new policy types and configurations

## Testing Strategy

1. **Phase 1 Testing**: Verify UE Policy Association creation
2. **Phase 2 Testing**: Verify PCF policy generation and notification
3. **Phase 3 Testing**: Verify AMF policy reception and DL NAS Transport
4. **Integration Testing**: End-to-end UE Policy delivery
5. **Real-world Testing**: Validate against QXDM and Wireshark examples

## Next Steps

1. **Implementation**: Follow the detailed file modifications outlined above
2. **Testing**: Start with QXDM profile for simple case
3. **Validation**: Verify binary output matches real-world examples
4. **Extension**: Add Wireshark profile support
5. **Production**: Configure profile selection logic for production use

## Important Notes

- **Error Handling**: UE Policy delivery failure should not break registration
- **Backward Compatibility**: Existing functionality remains unchanged
- **Security**: Follow existing AMF/PCF security patterns
- **Performance**: Async policy delivery prevents registration delays
- **Logging**: All operations logged with "WNC:" prefix for easy debugging

---

**Implementation Status**: Design Complete ✅  
**Ready for Coding**: Yes ✅  
**Real-world Validation**: QXDM + Wireshark examples integrated ✅  
**Flexible Architecture**: BuildRegistrationAccept pattern adopted ✅