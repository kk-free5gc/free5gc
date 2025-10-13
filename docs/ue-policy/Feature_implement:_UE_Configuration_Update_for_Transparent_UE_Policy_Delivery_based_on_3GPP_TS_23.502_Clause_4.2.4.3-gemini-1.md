# UE Configuration Update Procedure for Transparent UE Policy Delivery

ts_123502v180600p.pdf outlines the procedure for updating UE policy information, as detailed in section 4.2.4.3 of ts_123502v180600p.pdf.

## Actors

-   **UE (User Equipment):** The end-user device.
-   **AMF (Access and Mobility Management Function):** The network function that handles connection and mobility.
-   **PCF (Policy Control Function):** The network function that manages policies.

## Procedure Steps

1.  **PCF Initiates Update:** The PCF decides to update the UE policy. This can be triggered by:
    -   Initial UE registration.
    	- I suspect trigger point should be in HandlePostUEPolicies() after PostUEPoliciesProcedure()
    -   Movement from 4G (EPS) to 5G (5GS).
    	- Please skip it for now
    -   Network events requiring a policy change.
    	- Please skip it for now

2.  **PCF to AMF Communication:** The PCF sends the updated policy to the AMF in a `UE Policy Container` using the `Namf_Communication_N1N2MessageTransfer` service.
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

3.  **AMF to UE Forwarding:** The AMF transparently forwards this container to the UE.
    -   If the UE is active (`CM-CONNECTED`), the message is sent directly.
    -   If the UE is idle (`CM-IDLE`), the AMF pages the UE first.

4.  **UE Policy Update:** The UE receives the container and updates its local configuration.

5.  **UE to AMF Response:** The UE confirms the outcome of the update back to the AMF.

6.  **AMF to PCF Notification:** The AMF forwards the UE's response to the PCF using the `Namf_Communication_N1MessageNotify` service.

---

For a visual guide, please see **ts_123502v180600p.pdf Figure 4.2.4.3-1: UE Configuration Update procedure for transparent UE Policy delivery** in the original document.