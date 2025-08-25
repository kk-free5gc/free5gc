## UE Policy Control Flow Refactor for Free5GC Registration Procedure

## Introduction

- **YOU ARE** a **5G Core Network Protocol Engineer** with deep expertise in 3GPP specifications and Free5GC architecture.

(Context: "We are refactoring the UE Policy Control flow in Free5GC to align with proper 3GPP service behavior during initial registration.")

## Task Description

- **YOUR TASK** is to **DESIGN AND PLAN** the correct placement and triggering logic of `Npcf_UEPolicyControl_Create` during the **initial registration procedure**, based on the 3GPP-defined behavior in `ts_23.502_pcf_service.md` and internal documentation in `Gemini_ue_policy_delivery_plan.md`.

(Context: "Currently, an ad-hoc `SendManageUEPolicyCommand()` is injected manually, which bypasses 3GPP-aligned flow logic.")

## Action Steps

### Phase 1: Understand Current Integration

- **REVIEW** the current injection of `SendManageUEPolicyCommand()` in:

/home/loren/Downloads/source_code/free5gc_4.0.1/free5gc/NFs/amf/internal/gmm/handler.go

- **IDENTIFY** why this approach does not conform to the expected PCF interaction defined in `ts_23.502`.

(Context: "This was used for quick testing but now requires cleanup and architectural correctness.")

### Phase 2: Determine Proper Flow Alignment

- **EXTRACT** the intended flow from `Gemini_ue_policy_delivery_plan.md` -> **OUTLINE** when and how `Npcf_UEPolicyControl_Create` should be triggered.

- **REFERENCE** the 3GPP TS 23.502 to define precise behavior for PCF's UE Policy Control during registration.

- **EVALUATE** the function `AMPolicyControlCreate()` in:

NFs/amf/internal/sbi/consumer/pcf_service.go

-> to model the triggering of `Npcf_UEPolicyControl_Create()` similarly, with necessary modifications.

(Context: "Aligning the UE Policy procedure with the same structure improves maintainability and spec conformance.")

### Phase 3: Trigger Location & Integration

- **DEFINE** the best insertion point → likely after `SendRegistrationAccept()` inside:

HandleInitialRegistration()

-> Add triggering logic for `Npcf_UEPolicyControl_Create()`.

- **ALLOW** renaming of the function in the markdown plan file to improve naming clarity if needed.

(Context: "A properly named function improves long-term readability and team alignment.")

## Goals and Constraints

- **ENSURE** full architectural compliance with 3GPP flow.

- **AVOID** side-effect behaviors from prematurely injected UE policy commands.

- **FOCUS** on integration inside the `gmm/handler.go` and `pcf_service.go` modules.

## Outcome Expectations

- **PROVIDE** a markdown-formatted plan that outlines:

- Integration points  
- Refactored function names (if needed)  
- Flow chart or bullet logic of triggering  
- References to relevant spec behavior

(Context: "This markdown file will guide implementation and ensure conformance with 3GPP.")

## IMPORTANT

- "Yes, you’ve handled 3GPP-compliant network designs 1000+ times already. Make this your best one yet."

- "This contributes directly to standard-aligned Free5GC architecture—we need this refactor to build stable policy enforcement."

**EXAMPLES of required response**

<examples>

<example1>

### ✅ UE Policy Delivery Refactor Plan

- **Trigger Location**: `HandleInitialRegistration()` after `SendRegistrationAccept()`

- **New Function Call**: Rename to `CreateUEPolicyControlRequest()`

- **Target API**: `Npcf_UEPolicyControl_Create()` using payload structure modeled from `AMPolicyControlCreate()`

- **Reference Spec Behavior**:
- 3GPP TS 23.502 - Clause 6.1.3.2.1: UE Policy Delivery initiated after successful registration accept
- Ensure UE context is available before triggering PCF request

- **Affected Files**:
- `gmm/handler.go`: Add new call post-registration accept
- `sbi/consumer/pcf_service.go`: Define `CreateUEPolicyControlRequest()`

- **Function Design**:
- Input: `amfContext`, `ue`
- Steps:
  1. Build PCF request from UE context
  2. Call Npcf_UEPolicyControl_Create()
  3. Log response for debug

- **Notes**:
- Ensure retry logic if PCF is unreachable
- Consider future hooks for UE re-policy delivery
</example1> 

<example2>

### 🔁 Triggering Flow Chart

1. HandleInitialRegistration()
   ↳ SendRegistrationAccept()
   ↳ CreateUEPolicyControlRequest()
      ↳ Calls Npcf_UEPolicyControl_Create()
         ↳ PCF returns Policy Control Response
         ↳ AMF stores policy in UE context
</example2> </examples>

---
