# UE Configuration Update for Transparent UE Policy Delivery  
*(ts_123502v180600p.pdf 3GPP TS 23.502 §4.2.4.3)*

---

## 1. Objective
- Implement the 3GPP-defined procedure that lets the PCF update UE policy information and deliver it transparently via the AMF to the UE.

## 2. Actors / Network Functions
- **PCF (Policy Control Function)** – Initiates and manages policy updates.
- **AMF (Access and Mobility Management Function)** – Transparent proxy, relays policy info to the UE.
- **UE (User Equipment)** – Receives and applies the policy update.
- **UDR (Unified Data Repository)** – Stores the latest delivered Policy Set Information (PSI).

## 3. High-Level Workflow Overview
1. PCF decides to update policy (trigger conditions met).
2. PCF → AMF: Send UE Policy Container via `Namf_Communication_N1N2MessageTransfer`.
3. AMF → UE: Forward UE Policy Container (page if idle).
4. UE → AMF: UE returns update result/ack.
5. AMF → PCF: Forward UE response via `Namf_Communication_N1MessageNotify`.
6. PCF → UDR: Update UDR with PSI list (`Nudr_DM_Update`).
7. Error path: AMF notifies PCF of failures via `Namf_Communication_N1N2TransferFailureNotification`.

## 4. Detailed Implementation Prompts & Sub-Tasks

### 4.1 PCF Policy Update Trigger Logic (Step 0)

- **Goal**: Decide when to start a UE policy update.
- **Tasks**
    - Handle trigger events (initial registration, mobility from EPS→5GS, location/S-NSSAI changes, operator policies, NWDAF analytics). 
        - But for now, I only want the trigger point to be at initial registration (in HandlePostUEPolicies() after PostUEPoliciesProcedure())
        - Example, add TriggerAsyncUEPolicyEvaluation() to decide wether call UpdateUEPolicy()

    - Retrieve PSI list (e.g., via Npcf_UEPolicyControl_Create) and compare with stored PSI to determine if an update is needed.

    - Enforce message size limits; fragment the policy container if needed. Each fragment must be self-contained.

    - (Optional) Subscribe for UE response notifications from AMF if not already subscribed.

### 4.2 PCF → AMF Policy Delivery (Step 1)
- **Goal**: Invoke AMF’s N1N2 transfer service.
- **Tasks**:
    - Implement Namf_Communication_N1N2MessageTransfer client logic in PCF.
        - Please refer to similar function: N1N2MessageTransfer which SMF used to send to AMF in NFs/smf/internal/sbi/consumer/amf_service.go

    - Include SUPI and UE Policy Container payload(s).
        - Currently, I use TriggerUEPolicyDelivery(), LoadUEPolicyConfigFromYAML(), BuildManageUEPolicyCommand() to help me construct "UE policy container", but since I find these file list under /home/loren/go/pkg/mod/github.com/free5gc, maybe the current method should be updated
            - ./nas@v1.1.5/uePolicyContainer
            - ./nas@v1.1.5/uePolicyContainer/UePolicyContainer_UEPolicySectionManagementSubList.go
            - ./nas@v1.1.5/uePolicyContainer/UePolicyContainer.go
            - ./nas@v1.1.5/uePolicyContainer/UePolicyContainer_UEPolicyParts.go
            - ./nas@v1.1.5/uePolicyContainer/UePolicyContainer_ManageUEPolicyComplete.go
            - ./nas@v1.1.5/uePolicyContainer/UePolicyContainer_UEPolicySectionManagementSubResult.go
            - ./nas@v1.1.5/uePolicyContainer/UePolicyContainer_UEPolicyNetworkClassmark.go
            - ./nas@v1.1.5/uePolicyContainer/UePolicyContainer_Instruction.go
            - ./nas@v1.1.5/uePolicyContainer/NAS_UePolicyDeliveryServiceMsgType.go
            - ./nas@v1.1.5/uePolicyContainer/UePolicyContainer_ManageUEPolicyCommand.go
            - ./nas@v1.1.5/uePolicyContainer/UePolicyContainer_Result.go
            - ./nas@v1.1.5/uePolicyContainer/UePolicyContainer_ManageUEPolicyReject.go
            - ./nas@v1.1.5/uePolicyContainer/UePolicyContainer_UEPolicyPartType.go
            - ./nas@v1.1.5/uePolicyContainer/UePolicyContainer_UEPolicySectionManagementResult.go
            - ./nas@v1.1.5/uePolicyContainer/UePolicyContainer_UEPolicySectionManagementList.go

    - Handle response codes from AMF (accepted, rejected, partial success).

### 4.3 AMF Transparent Forwarding (Steps 2 & 3)
- **Goal**: AMF receives the request and forwards the policy to UE, considering UE state.
- **Tasks**:
    - Implement handler for Namf_Communication_N1N2MessageTransfer in AMF.
    - If UE is CM-CONNECTED: send N1 message directly.
    - If UE is CM-IDLE: initiate paging / network-triggered service request.
    - If delivery fails, call Namf_Communication_N1N2TransferFailureNotification to PCF with error cause.

### 4.4 UE-Side Handling & Response (Step 4)
- **Goal**: UE parses, applies the policy, and reports result.
- **Tasks**:
    - Receive and parse UE Policy Container (NAS layer).
    - Update local policy configuration / cache.
    - Return success/failure to AMF via N1 message (UE Policy Update Result).

### 4.5 AMF → PCF Response & Finalization (Step 5)
- **Goal**: Ensure PCF receives UE’s outcome and finalizes data.
- **Tasks**:
    - AMF forwards UE’s response using Namf_Communication_N1MessageNotify.
    - PCF updates UDR (Nudr_DM_Update) with new PSI list upon success.
    - On failure: Modify PCF-AMF association to subscribe to UE connectivity changes and retry when UE reconnects.

## 5. API / Service Interaction Summary
PCF → AMF: Namf_Communication_N1N2MessageTransfer (deliver policy).

AMF → PCF: Namf_Communication_N1N2TransferFailureNotification (delivery failed).

AMF → PCF: Namf_Communication_N1MessageNotify (UE’s response).

PCF → UDR: Nudr_DM_Update (store updated PSI list. PSI stands for "Policy Section Identifier").

PCF ↔ AMF: Optional subscription to receive UE response notifications.

## 6. Implementation Checklist
 Define policy payload size limits & fragmentation rules.

 Implement trigger handlers in PCF (registration, mobility, NWDAF analytics, policy changes).

 Implement PSI diff logic (new vs. stored).

 Build PCF client for Namf_Communication_N1N2MessageTransfer.

 Implement AMF handler & UE reachability logic (paging if idle).

 Implement failure notification at AMF (N1N2TransferFailureNotification).

 Implement UE policy parsing & application logic.

 Implement UE response formation & AMF forwarding (N1MessageNotify).

 Implement PCF finalization (UDR update, re-subscription on failure).

 Add logging & KPIs (success rate, payload size, paging attempts).

 Write unit, integration, and E2E tests.

## 7. Testing & Validation Strategy (Skip for this feature)
### 7.1 Unit Tests
 PCF trigger logic & PSI diff.
 
 Policy fragmentation and reassembly.
 
### 7.2 Integration Tests
 PCF ↔ AMF service calls (mock UE or simulator).
 
 AMF paging path validations.
 
### 7.3 End-to-End Tests
 Successful policy delivery & UE acknowledgment.
 
 Failure path (UE unreachable) → ensure PCF re-triggers after UE reconnects.
 
### 7.4 Performance / Robustness
 Large policy payload tests.
 
 Rapid consecutive updates.
 
 Validate UDR data integrity across multiple updates.

## 8. Logging & Observability

Be sure to add sufficient logs prefixed with `"WNC:"` for easy tracing

PCF: Trigger events, PSI diff results, fragmentation logs.

AMF: Delivery attempts, paging, success/failure notifications.

UE: Policy version applied, update result.

UDR: PSI timestamps/versions after each update.

## 9. Failure & Retry Logic
AMF cannot reach UE → notify PCF via failure notification.

PCF subscribes to UE connectivity changes; retry when UE is CM-CONNECTED.

UE parsing failure → AMF notifies PCF; PCF may re-send or escalate.

## 10. References
3GPP TS 23.502 §4.2.4.3 — UE Configuration Update procedure for transparent UE Policy delivery.

3GPP TS 29.518 (AMF services), TS 29.507 (UDR), TS 29.508 (PCF).

Internal requirement/attachment converted into Markdown here.


```mermaid
sequenceDiagram
    participant UE
    participant AMF
    participant PCF
    participant UDR

    PCF->>PCF: Evaluate triggers & PSI diff
    PCF->>AMF: Namf_Communication_N1N2MessageTransfer(UE Policy Container)
    alt UE reachable
        AMF->>UE: Deliver UE Policy Container (N1 msg)
    else UE idle/unreachable
        AMF->>UE: Paging / Service Request
        UE->>AMF: Service Request
        AMF->>UE: Deliver UE Policy Container
    end
    UE->>AMF: UE Policy Update Result (N1 response)
    AMF->>PCF: Namf_Communication_N1MessageNotify
    PCF->>UDR: Nudr_DM_Update (store PSI list)
    Note over PCF: On failure, subscribe/modify association<br/>to re-trigger when UE connects
