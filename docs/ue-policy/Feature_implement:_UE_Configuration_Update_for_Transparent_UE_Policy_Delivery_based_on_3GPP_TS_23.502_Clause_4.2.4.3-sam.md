## Prompt Title:
Implementation Guidance for "4.2.4.3 UE Configuration Update procedure for transparent UE Policy delivery"

## Prompt:

**YOU ARE** a **3GPP protocol implementation expert and 5G Core Network architect**, specializing in NAS signaling, UE context management, and transparent policy handling between UE and network components.

**YOUR TASK IS** to help me **IMPLEMENT** the procedure described in **ts_123502v180600p.pdf 3GPP TS 23.502, Clause 4.2.4.3**, specifically for **UE Configuration Update handling for Transparent UE Policy Delivery**.

--- 

### 🔍 OBJECTIVE

I want you to:
1. **EXTRACT and CLARIFY** each step in the procedure defined in Clause 4.2.4.3.
2. **DECOMPOSE** the UE Configuration Update flow into implementation-relevant building blocks.
3. **TRANSLATE** the abstract procedure into a developer-friendly step-by-step guide.
4. **MAP** each action in the procedure to the corresponding network entity (UE, AMF, PCF, SMF, etc.).
5. **IDENTIFY** all necessary NAS messages, IE fields, and expected behavior for each node.
6. **SUGGEST** implementation practices or reference flows for integrating this feature into an existing 5GC architecture.
7. **PROVIDE** assumptions, constraints, and dependencies that implementers must consider (e.g., when the UE initiates this flow, fallback behavior, support for IPv4/v6, policy container types, etc.).

---

### 🧩 INPUTS

Use the specification: `ts_123502v180600p.pdf 3GPP TS 23.502 V18.6.0, Clause 4.2.4.3`, and any referenced procedures or entities within that clause, including:
- UE Configuration Update Request/Response
- Transparent UE Policy Container
- N1/N2/N15 interfaces
- PCF policy control triggers

---

### 📤 OUTPUT FORMAT

Please present the output in this format:

1. 🔸 **Procedure Summary** – 1-paragraph summary of the 4.2.4.3 purpose and scope.
2. 🔹 **Flow Breakdown** – Detailed, stepwise list with each network entity and its actions.
3. 🔹 **Signaling Details** – Table showing message names, involved IE fields, triggering conditions.
4. 🔹 **Integration Notes** – Developer advice for real-world integration, including timers, fallbacks, error cases.
5. 🔸 **Final Checklist** – A validation checklist implementers can use to ensure completeness.

---

### 🛠 ADDITIONAL GUIDANCE

- FOCUS on **transparent policy delivery**, and clarify how the UE knows when to trigger the Configuration Update.
	- I suspect trigger point should be in HandlePostUEPolicies() after PostUEPoliciesProcedure()
- EXPLAIN the role of the **UE policy container** and how it is encoded, if applicable.
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
- INCLUDE edge-case behavior (e.g., what happens if the PCF doesn't respond?).
- ENSURE output is technical, complete, and implementable.

---

## 🧪 EXAMPLES PLACEHOLDER
(Insert 2–3 implementation example scenarios for UE types – e.g., smartphone, IoT device, CPE)
