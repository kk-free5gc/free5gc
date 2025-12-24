# UE Policy Delivery "DL NAS Transport/Manage UE Policy Command" Implementation Plan

This document outlines the plan to implement the delivery of UE Policy (specifically URSP) to the User Equipment (UE) during the initial registration procedure.

The core principle of this plan is to decouple the establishment of the UE Policy Association from the delivery of the policy itself. The AMF will initiate the association, and the PCF will be responsible for asynchronously sending the policy information immediately after the association is confirmed.

---

### Phase 1: AMF - Initial Registration & Association Request

This phase occurs within the AMF during the UE's initial registration.

1.  **Complete Standard Registration:**
    *   **File:** `NFs/amf/internal/gmm/handler.go`
    *   **Function:** `HandleInitialRegistration()`
    *   **Action:** The AMF will complete all standard registration steps, including authentication, security mode setup, AM Policy Association (`Npcf_AMPolicyControl_Create`), and finally, sending the **`Registration Accept`** message to the UE.

2.  **Request UE Policy Association:**
    *   **Location:** Immediately following the `SendRegistrationAccept(...)` call in `HandleInitialRegistration`.
    *   **Service:** `Npcf_UEPolicyControl_Create`
    *   **Action:** The AMF sends a request to the PCF to create the UE Policy Association.
    *   **Inputs:** The request must include the `SUPI` and a `Notification URI`. This URI is a crucial endpoint on the AMF that the PCF will use to send policy updates.
    *   **Expected PCF Response:** The AMF expects a standard `Success` response (e.g., `201 Created`). It will store the returned `UE Policy Association ID` in the UE's context for future reference.

---

### Phase 2: PCF - Association, Internal Trigger, and Policy Notification

This phase describes the logic implemented within the PCF.

1.  **Handle Association Request:**
    *   **Service Handler:** The PCF's handler for the `Npcf_UEPolicyControl_Create` service operation.
    *   **Action:**
        *   The PCF receives the request from the AMF.
        *   It creates and stores a new UE Policy Association context, linking the `SUPI` with the `Association ID` and the AMF's `Notification URI`.

2.  **Internal Trigger Function (New Logic):**
    *   **Location:** Still within the `Npcf_UEPolicyControl_Create` handler.
    *   **Action:**
        *   After successfully creating the association context, but *before* sending the `Success` response back to the AMF, the PCF will call a new, separate internal function (e.g., `initiateInitialUEPolicyDelivery(associationID)`).
        *   **Crucially, this function must be invoked asynchronously (e.g., as a new goroutine) to prevent blocking the HTTP response to the AMF.**

3.  **Send `Success` Response to AMF:**
    *   **Action:** The PCF's `Npcf_UEPolicyControl_Create` handler sends the `Success` response back to the AMF, completing the synchronous part of the transaction.

4.  **Prepare and Send Policy Notification (Asynchronous Task):**
    *   **Location:** The new internal function (`initiateInitialUEPolicyDelivery`).
    *   **Service:** `Npcf_UEPolicyControl_UpdateNotify`
    *   **Action:**
        *   This function gathers or generates the default URSP for the UE.
        *   It then immediately uses the stored `Notification URI` and `Association ID` to send an `Npcf_UEPolicyControl_UpdateNotify` request to the AMF, with the UE policy (URSP) in the payload.

---

### Phase 3: AMF - Receiving and Relaying the Policy

This phase describes how the AMF handles the PCF-initiated policy update.

1.  **Handle PCF Notification:**
    *   **Location:** The AMF's HTTP handler corresponding to the `Notification URI` provided in Phase 1.
    *   **Action:** The AMF receives the `Npcf_UEPolicyControl_UpdateNotify` request from the PCF. It uses the `UE Policy Association ID` from the request to identify the correct UE context.

2.  **Construct and Send "Manage UE Policy Command":**
    *   **Action:**
        *   The AMF extracts the UE policy information (URSP) from the notification payload.
        *   It constructs the `ManageUEPolicyCommand` NAS message using the `nas/message` package.
        *   It wraps this NAS PDU in a `DLNASTransport` message.
        *   Finally, it sends the `DLNASTransport` message to the UE using its standard N1 transport functions.

---

### Phase 4: Pre-implementation Dependency Verification

This is a preparatory step to ensure compatibility.

*   **Objective:** Ensure API definitions are consistent between the AMF and PCF.
*   **Action:** Before starting implementation, inspect the `go.mod` file in both `NFs/amf/` and `NFs/pcf/` to verify that they are using the same version of the `github.com/free5gc/openapi` module.

eg. in go.mod, github.com/free5gc/openapi v1.1.0 refer to /home/loren/go/pkg/mod/github.com/free5gc/openapi@v1.1.0
