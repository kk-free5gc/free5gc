
# Free5GC / PFCP: SDF, PDI, PDR, FAR, QFI – Full Detail Note

This document consolidates **all details** previously provided about:

- SDF / PDI / PDR / FAR abbreviations and meanings  
- Their relationships in PFCP / Free5GC UPF  
- Mapping: **SDF → QFI → PDR → FAR**  
- A realistic **PFCP Session Establishment** example (UL/DL PDR & FAR)  
- The **UPF decision flow**  
- Pointers to relevant **go-upf** internal structures

---

## 1. Abbreviations & Concepts (3GPP / PFCP / Free5GC)

These are used in **PFCP (TS 29.244)** and implemented by **Free5GC UPF**.

| Abbreviation | Full Name                     | Layer / Meaning                                                                 |
|--------------|------------------------------|----------------------------------------------------------------------------------|
| **SDF**      | Service Data Flow            | Logical application-level flow (defined by PCF/SMF via policies, PCC, URSP).    |
| **PDI**      | Packet Detection Information | Matching information used by UPF to detect packets belonging to a given PDR.    |
| **PDR**      | Packet Detection Rule        | Rule that says *“if a packet matches this PDI, then apply this forwarding rule”*|
| **FAR**      | Forwarding Action Rule       | Defines what the UPF does with packets (forward, drop, buffer, duplicate, etc.) |
| **QFI**      | QoS Flow Identifier          | Identifies a QoS flow inside a PDU Session (mapped from SDF/QoS rules).         |

High-level responsibilities:

- **SDF** – Logical flow seen from policy / QoS point of view (PCF/SMF).  
- **PDI** – Concrete matching filters on the UPF (IP addresses, ports, TEID, etc.).  
- **PDR** – UPF rule that ties PDI to an action via FAR.  
- **FAR** – What to do: forward/drop/buffer, where to send, how to tunnel.  
- **QFI** – Which QoS flow this traffic belongs to.

---

## 2. Relationship: SDF / PDI / PDR / FAR

Conceptually, the chain looks like this:

```text
SDF → PDI → PDR ─→ FAR → (Forward / Drop / Buffer / Duplicate)
```

Or more step-by-step:

1. **SDF** is defined at the SMF/PCF level based on policy (DNN, app type, 5‑tuple).  
2. **SMF** translates SDF into **PDI** fields and embeds those inside **PDRs** in PFCP.  
3. **PDR** holds:
   - PDI (matching info)  
   - Precedence  
   - QoS-related info (e.g., QFI, QER references)  
   - A reference to a **FAR** (FAR-ID).  
4. **FAR** is the actual action that UPF executes when the PDR matches a packet.

### 2.1 SDF (Service Data Flow)

On SMF/PCF side, SDF is a **logical flow** defined by rules like:

- Destination IP / prefix  
- L4 protocol and port (e.g., TCP 443, UDP 53)  
- Direction (uplink/downlink)  
- Possibly application identifiers

Example SDF filter in abstract form:

```text
permit out ip from any to 8.8.8.8/32 53
```

The SDF itself **does not exist as an IE in the UPF**; instead, **SMF converts SDF rules into PDI filters**.

---

### 2.2 PDI (Packet Detection Information)

PDI is the **matching key** for packets on the UPF side. It is contained within a PDR.

Possible PDI fields:

- **Source Interface**: Access / Core / SGi-LAN / CP-function  
- **UE IP Address** (IPv4 and/or IPv6)  
- **SDF Filter**: IP 5-tuple (src/dst IP, ports, protocol)  
- **QFI** (for downlink PDRs) as part of QoS-related info  
- **F-TEID**: TEID and IP for GTP-U tunnels (commonly for uplink)  
- **Ethernet Packet Filter** (for Ethernet PDU type)  

PDI is essentially a **“match condition”**: if a packet meets this PDI, it hits the parent PDR.

---

### 2.3 PDR (Packet Detection Rule)

A **PDR** is the core rule in the UPF that binds:

- Matching conditions (**PDI**)  
- Priority (**Precedence**)  
- QoS identification (**QFI**)  
- Action rule (**FAR**)

A PDR roughly contains:

- **PDR ID**  
- **Precedence** (lower value = higher priority, or vice versa depending on implementation; check vendor/spec)  
- **PDI** (the match)  
- **Outer Header Removal** (e.g., remove GTP-U for UL)  
- **QFI** for QoS flow mapping  
- **FAR-ID** (a reference to one FAR)  

**Important:** Each PDR is associated with **exactly one FAR** (by FAR-ID).

---

### 2.4 FAR (Forwarding Action Rule)

FAR defines **what to do** with packets that matched a PDR.

Typical fields:

- **Apply Action**: FORW, DROP, BUFF, NOCP, DUPL, etc.  
- **Destination Interface**: Access / Core / SGi-LAN / CP-function  
- **Forwarding Parameters**:
  - **Outer Header Creation**: GTP-U/UDP/IP, TEID, peer IP address  
  - Possibly redundancy / duplication info  
- **Buffering** behavior (if BUFF is set)  
- **Duplicating** behavior (if DUPL is set, along with second FAR/QER references)

FAR does **not match** packets; it is **invoked by PDR** after a match is found.

---

### 2.5 Visual Diagram: PDR ⇨ FAR Relationship

```text
          +--------------+        +--------------+
          |     PDR      | ---->  |     FAR      |
          |--------------|        |--------------|
Packet -> |   PDI (match)|        | Action:      |
          | Precedence   |        |  - Forward   |
          | QFI          |        |  - Drop      |
          | FAR-ID ----- |------> |  - Buffer    |
          +--------------+        |  - Duplicate |
                                  +--------------+
```

- Packet arrives on the UPF.  
- UPF finds matching **PDR** via **PDI**.  
- PDR points to one **FAR**.  
- FAR tells UPF how/where to forward the packet.

---

## 3. Mapping: SDF → QFI → PDR → FAR (Free5GC Path)

This is the key end‑to‑end mapping chain from policies to UPF behavior:

```text
[SDF Flow] 
   ↓ (PCF→SMF applies URSP, PCC rules)
[QFI Assignment]
   ↓ (SMF creates QoS Flow)
[PDR Generation]
   ↓
[FAR Assignment]
   ↓
[UPF Traffic Handling]
```

### 3.1 Step 1 – SDF (Service Data Flow)

The SMF/PCF uses policies (URSP, PCC rules, slices, DNN, etc.) to define which traffic belongs to which SDF.  

Example SDF filters:

```text
SDF 1 (DNS):
  permit out udp from any to 8.8.8.8 53

SDF 2 (HTTPS):
  permit out tcp from any to any 443
```

The SDF is **logical** and exists mainly in policy databases (PCF/SMF).

---

### 3.2 Step 2 – QFI (QoS Flow Identifier)

Each SDF (or group of SDFs) gets mapped to a **QoS Flow** with a **QFI**.

Example mapping:

```text
SDF 1 (DNS)   → QFI = 9
SDF 2 (HTTPS) → QFI = 5
```

- QFI is included in NAS messages / QoS flow descriptions.  
- QFI is used in **PDRs** to tell the UPF which QoS flow the packets belong to, especially for **DL traffic**.

---

### 3.3 Step 3 – PDI (Packet Detection Information) from SDF

The SMF translates SDF filters into PDI fields and places them inside PDRs.

Example PDI for UL DNS traffic (SDF → PDI):

```text
Source Interface: Access
UE IP Address: 10.1.0.2/32
SDF Filter: destination 8.8.8.8/32, UDP port 53
F-TEID (uplink): TEID assigned for UL GTP-U tunnel (N3)
```

This PDI is then embedded in a PDR with a QFI reference.

---

### 3.4 Step 4 – PDR (Packet Detection Rule)

Each QoS Flow (QFI) with a set of SDFs is represented in the UPF by one or more **PDRs**.

Example **uplink PDR**:

```text
PDR-ID = 3
Precedence = 255
PDI:
  - Source Interface = Access
  - UE IPv4 = 10.1.0.2/32
  - SDF Filter = udp dest 8.8.8.8/32 port 53
  - F-TEID for UL from gNB
QFI = 9
FAR-ID = 3
```

Key points:

- The **SDF filter** is now inside **PDI**.  
- The **QoS Flow** is identified by **QFI = 9**.  
- **FAR-ID** links this PDR to a specific forwarding action.

---

### 3.5 Step 5 – FAR (Forwarding Action Rule)

Example **FAR #3** for this PDR:

```text
FAR-ID = 3
Apply Action: FORW
Forwarding Parameters:
  Destination Interface: Core
  Outer Header Creation:
    GTP-U/UDP/IPv4
    TEID: 0x1ab201
    IP Address: 10.200.200.2  (toward DN or next UPF)
```

Thus, the full mapping is:

```text
SDF (DNS → 8.8.8.8:53)
  → QFI 9
      → PDR #3 (matching DNS packets from UE 10.1.0.2)
          → FAR #3 (forward to Core with TEID 0x1ab201)
```

---

## 4. Realistic PFCP Session Establishment Example (Free5GC-Style)

Below is a **realistic PFCP Session Establishment Request** (SMF → UPF) with both UL and DL PDR/FAR pairs, formatted for readability.

### 4.1 Session Establishment Request – Example

```text
PFCP Session Establishment Request
---------------------------------------------------------

+ PDR (Packet Detection Rule) - ID: 1  [Uplink]
    Precedence: 255
    PDI:
        Source Interface: Access
        Local F-TEID:
            TEID: 0x0a0b0c01
            IP Address: 10.200.200.1
        UE IP Address: 10.1.0.2 (IPv4)
        SDF Filter:
            permit out udp from any to 8.8.8.8 53
    QFI: 9
    FAR-ID: 1

+ FAR (Forwarding Action Rule) - ID: 1
    Apply Action: FORW
    Forwarding Parameters:
        Destination Interface: Core
        Outer Header Creation:
            GTP-U/UDP/IPv4
            TEID: 0x1ab201
            IP Address: 10.200.200.2

---------------------------------------------------------

+ PDR (Packet Detection Rule) - ID: 2  [Downlink]
    Precedence: 255
    PDI:
        Source Interface: Core
        UE IP Address: 10.1.0.2
        SDF Filter:
            permit in udp from 8.8.8.8 53 to 10.1.0.2
    QFI: 9
    FAR-ID: 2

+ FAR (Forwarding Action Rule) - ID: 2
    Apply Action: FORW
    Forwarding Parameters:
        Destination Interface: Access
        Outer Header Creation:
            GTP-U/UDP/IPv4
            TEID: 0x0a0b0c01
            IP Address: 10.200.200.1
```

**Interpretation:**

- **PDR #1 (UL)** matches UL GTP-U packets from gNB (`Source Interface: Access` + `Local F‑TEID`).  
  - It further filters by UE IP and SDF filter (DNS traffic).  
  - QFI = 9 indicates which QoS Flow this is.  
  - FAR #1 forwards packets to the **Core** side with a specific **TEID and IP** (often toward another UPF or toward the DN).

- **PDR #2 (DL)** matches packets coming from **Core** (DN side):
  - Source Interface: Core  
  - UE IP: 10.1.0.2  
  - SDF Filter for DNS from 8.8.8.8:53 to UE  
  - QFI = 9 for the DL QoS flow  
  - FAR #2 sends packets back toward the gNB/AN by GTP-U tunnel using UL TEID/IP as the **Outer Header Creation**.

So together, the UL/DL pair handles **DNS SDF** with **QFI=9**, mapping to **two PDRs** (one per direction) and **two FARs**.

---

## 5. UPF Packet Processing / Decision Flow

From the UPF’s perspective, the processing path for each packet is:

```text
Incoming Packet
   ↓
Find Matching PDR (via PDI)
   ↓
Extract QoS info (e.g., QFI, QER) from PDR
   ↓
Use FAR-ID from PDR to locate FAR
   ↓
Execute FAR:
  - Forward / Drop / Buffer / Duplicate
  - Choose Destination Interface
  - Perform Outer Header (GTP-U) Creation / Removal
   ↓
Send packet to next hop (gNB / DN / CP)
```

In more detail:

1. **Packet arrives** on N3 (gNB–UPF) or N6/N9 interface.  
2. UPF’s PDR lookup engine:
   - For UL, matches on **F-TEID**, **Source Interface = Access**, and optionally SDF filters (if present).  
   - For DL, matches on **UE IP**, **Source Interface = Core**, and SDF filters.  
3. Once a PDR is found:
   - UPF sees the **QFI** (for DL, mainly) and **Precedence**.  
   - PDR tells UPF which **FAR** to use (FAR-ID).  
4. **FAR** is applied:
   - If `FORW`: build GTP-U tunnel or route to DN.  
   - If `DROP`: silently drop packets.  
   - If `BUFF` or `NOCP`: buffer until CP interaction, etc.  
5. Packet is forwarded accordingly.

---

## 6. Free5GC go-upf Internal Structures (High-Level)

Within **Free5GC’s go-upf** implementation, PDR/FAR concepts roughly map to Go structs and logic, for example:

| Component             | Purpose                                                    |
|-----------------------|------------------------------------------------------------|
| `PDR` struct          | Stores fields for a PDR: ID, precedence, PDI, QFI, FAR-ID |
| `FAR` struct          | Stores action, destination interface, outer header info   |
| `PDI` / Filter logic  | Stores and checks match conditions on incoming packets    |
| Packet path functions | Implement UL/DL handling with PDR lookup and FAR execution|

Typical files (names may vary by version, but conceptually):

- `pdr.go` – definition and management of PDR structures  
- `far.go` – definition and management of FAR structures  
- `packet.go` or similar – packet parsing and PDR matching logic  
- PFCP handler files – parse PFCP IEs and construct PDR/FAR/QER/Gate structs in memory

These structures are populated when the UPF receives:

- **PFCP Session Establishment Request**  
- **PFCP Session Modification Request**  

from the SMF.

---

## 7. Compact Text Diagram Summary (For Quick Reference)

### 7.1 Abbreviations

```text
SDF = Service Data Flow
PDI = Packet Detection Information
PDR = Packet Detection Rule
FAR = Forwarding Action Rule
QFI = QoS Flow Identifier
```

### 7.2 Data Plane Mapping

```text
SDF (policy-level flow)
  ↓  (PCF/SMF)
QFI (QoS flow id)
  ↓  (SMF → PFCP)
PDR (PDI + precedence + QFI + FAR-ID)
  ↓
FAR (action + tunnel params)
  ↓
UPF forwards/drops/buffers packets
```

### 7.3 UL/DL Example

```text
UL:
  PDR #1 (Access, F-TEID, SDF: UE → 8.8.8.8:53, QFI=9)
    → FAR #1 (FORW to Core, TEID 0x1ab201, 10.200.200.2)

DL:
  PDR #2 (Core, UE IP 10.1.0.2, SDF: 8.8.8.8:53 → UE, QFI=9)
    → FAR #2 (FORW to Access, TEID 0x0a0b0c01, 10.200.200.1)
```

---

## 8. Notes / Potential Extensions

If you want to extend this note later, you can add sections such as:

- **QFI → 5QI → ARP → GBR/MBR** mapping from SMF PCC rules.  
- How **slice (SST/SD)** and **DNN** selection interact with SDF/QFI → PDR/FAR.  
- Example PCAP annotations: NAS + PFCP + GTP-U for a real Free5GC call flow.  
- How to **dump active PDR/FAR/QER** from go-upf logs or internal CLI (if enabled).

This file currently contains **all the previously provided explanation content in detailed form**, not just a summary.
