# UE Policy Control Flow Refactor Implementation Plan

## ✅ UE Policy Control Flow Refactor for Free5GC Registration Procedure

### **Current State Analysis**

**Current Implementation Issues:**
- `TriggerUEPolicyDelivery()` at line 776 in `gmm/handler.go` bypasses proper 3GPP flow
- `SendManageUEPolicyCommand()` is directly called without PCF interaction
- No proper `Npcf_UEPolicyControl_Create` association establishment

### **Proposed 3GPP-Compliant Architecture**

**Integration Point:** 
Replace the current `TriggerUEPolicyDelivery()` call (line 776) with proper `Npcf_UEPolicyControl_Create()` call

**New Function Structure:**
```
HandleInitialRegistration() (line 624)
  ↳ SendRegistrationAccept() (line 773)
  ↳ UEPolicyControlCreate() (NEW - replaces TriggerUEPolicyDelivery)
     ↳ Creates association with PCF
     ↳ PCF responds with Success + Association ID
     ↳ PCF triggers internal async function
     ↳ PCF sends Npcf_UEPolicyControl_UpdateNotify to AMF
     ↳ AMF processes notification and sends ManageUEPolicyCommand to UE
```

### **Implementation Design**

**Phase 1: PCF Service Integration (pcf_service.go)**

Add new function modeled after `AMPolicyControlCreate()`:

```go
func (s *npcfService) UEPolicyControlCreate(
    ue *amf_context.AmfUe, anType models.AccessType,
) (*models.ProblemDetails, error) {
    // Similar structure to AMPolicyControlCreate
    // - Build UE Policy Association Request
    // - Include SUPI and Notification URI
    // - Call Npcf_UEPolicyControl_Create API
    // - Store UE Policy Association ID in UE context
}
```

**Phase 2: Handler Integration (gmm/handler.go)**

Replace line 776:
```go
// OLD: TriggerUEPolicyDelivery(ue, anType)
// NEW:
problemDetails, err := consumer.GetConsumer().UEPolicyControlCreate(ue, anType)
if problemDetails != nil {
    ue.GmmLog.Errorf("UE Policy Control Create Failed Problem[%+v]", problemDetails)
} else if err != nil {
    ue.GmmLog.Errorf("UE Policy Control Create Error[%+v]", err)
}
```

**Phase 3: PCF Response Handler**

Add notification endpoint handler to process `Npcf_UEPolicyControl_UpdateNotify`:
- Parse incoming policy from PCF
- Convert to `ManageUEPolicyCommand` NAS message
- Send via `DLNASTransport` to UE

### **3GPP Specification Compliance**

**Reference:** TS 23.502 Section 5.2.5.6.2 `Npcf_UEPolicyControl_Create`

**Inputs Required:**
- `SUPI` (already available in UE context)
- `Notification endpoint` (AMF callback URI)

**Expected Outputs:**
- `Success/Failure` response
- `UE Policy Association ID` (stored in UE context)
- Optional: Initial UE policy information

**Process Flow:**
1. **Step 1:** AMF calls `Npcf_UEPolicyControl_Create` after Registration Accept
2. **Step 2:** PCF creates UE Policy Association and returns Success + Association ID
3. **Step 3:** PCF asynchronously triggers `Npcf_UEPolicyControl_UpdateNotify` 
4. **Step 4:** AMF receives notification and sends policy to UE via NAS Transport

### **Files to Modify**

**Primary Files:**
- `NFs/amf/internal/sbi/consumer/pcf_service.go`: Add `UEPolicyControlCreate()`
- `NFs/amf/internal/gmm/handler.go`: Replace `TriggerUEPolicyDelivery()` call
- `NFs/amf/internal/sbi/producer/`: Add notification endpoint handler

**Supporting Files:**
- `NFs/amf/internal/context/amf_ue.go`: Add UE Policy Association ID field
- `NFs/amf/internal/sbi/consumer/consumer.go`: Expose new function

### **Function Naming Convention**

**New Functions:**
- `UEPolicyControlCreate()` - Main association creation
- `UEPolicyControlUpdateNotify()` - Handler for PCF notifications  
- `SendUEPolicyToUE()` - Wrapper for NAS transport delivery

### **Benefits of This Approach**

1. **3GPP Compliance:** Follows proper service-based architecture
2. **Separation of Concerns:** Decouples association creation from policy delivery
3. **Asynchronous Design:** Prevents blocking registration procedure
4. **Maintainability:** Consistent with existing `AMPolicyControlCreate()` pattern
5. **Extensibility:** Supports future UE policy updates from PCF

### **Migration Strategy**

1. **Phase 1:** Implement `UEPolicyControlCreate()` alongside existing code
2. **Phase 2:** Add PCF notification handlers
3. **Phase 3:** Replace `TriggerUEPolicyDelivery()` with new flow
4. **Phase 4:** Remove legacy policy loading code

### **🔁 Detailed Triggering Flow Chart**

```
1. HandleInitialRegistration()
   ↳ Complete standard registration steps
   ↳ AMPolicyControlCreate() (existing)
   ↳ SendRegistrationAccept()
   ↳ UEPolicyControlCreate() (NEW)
      ↳ Build UE Policy Association Request
      ↳ Include SUPI and Notification URI
      ↳ Call Npcf_UEPolicyControl_Create()
      ↳ Store UE Policy Association ID in UE context
      ↳ Return Success to continue registration flow

2. PCF Internal Processing (Asynchronous)
   ↳ Receive UE Policy Association Request
   ↳ Create UE Policy Association context
   ↳ Respond with Success + Association ID
   ↳ Trigger internal async function
   ↳ Generate/retrieve UE policies (URSP)
   ↳ Send Npcf_UEPolicyControl_UpdateNotify to AMF

3. AMF Notification Handler
   ↳ Receive Npcf_UEPolicyControl_UpdateNotify
   ↳ Parse UE Policy Association ID
   ↳ Extract policy information from notification
   ↳ Convert to ManageUEPolicyCommand NAS message
   ↳ Send via DLNASTransport to UE
```

### **Implementation Notes**

- **Retry Logic:** Implement retry mechanism if PCF is unreachable
- **Error Handling:** Graceful degradation if UE policy delivery fails
- **Logging:** Comprehensive logging for debugging and monitoring, be sure to start logging with "WNC:" for wasy trace
- **Configuration:** Support both PCF-based and local policy configuration
- **Testing:** Ensure compatibility with existing test suites

This refactor ensures proper 3GPP alignment while maintaining backward compatibility during the transition period.

### **Pre-implementation Dependency Verification**
- **openapi file Location:** in go.mod, github.com/free5gc/openapi v1.1.0 refer to /home/loren/go/pkg/mod/github.com/free5gc/openapi@v1.1.0
