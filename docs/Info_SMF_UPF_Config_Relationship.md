# SMF vs UPF Configuration Relationship

## Why SMF and UPF Have Similar (But Different) Configurations

### Common Confusion
In a single-UPF deployment, the SMF's `userplaneInformation` and UPF's `dnnList` configurations appear almost identical, leading to questions about why both are needed.

## Configuration Purposes

### SMF Configuration (`smfcfg.yaml` - userplaneInformation)
**Purpose**: Network topology and UE IP pool management

**Responsibilities**:
- **UPF Selection**: Decides which UPF to use for which DNN/S-NSSAI combination
- **IP Address Assignment**: Selects and assigns IP addresses to UEs from configured pools
- **Routing Decisions**: Determines packet forwarding paths through UPF topology
- **Slice Awareness**: Makes S-NSSAI-based decisions for network slicing
- **Multi-UPF Management**: Manages multiple UPFs and their interconnections

**S-NSSAI Role**: **Mandatory and functional** - used for UPF selection and slice-aware routing

**Example**:
```yaml
userplaneInformation:
  upNodes:
    UPF:  # UPF node name
      type: UPF
      sNssaiUpfInfos:
        - sNssai:
            sst: 1
            sd: "000001"
          dnnUpfInfoList:
            - dnn: internet
              pools:
                - cidr: 10.112.0.0/16  # SMF assigns IPs from here to UEs
```

### UPF Configuration (`upfcfg.yaml` - dnnList)
**Purpose**: Local routing table setup

**Responsibilities**:
- **Route Installation**: Adds routes to kernel routing table for packet forwarding
- **Packet Forwarding**: Forwards packets based on destination IP addresses
- **Interface Management**: Manages GTP-U tunneling interface (upfgtp)
- **Slice-Agnostic**: Routes packets regardless of S-NSSAI (doesn't care about slices)
- **Local Configuration**: Only knows about its own routing configuration

**S-NSSAI Role**: **Optional and informational** - only for logging/debugging, not used in routing logic

**Example**:
```yaml
dnnList:
  - dnn: internet
    cidr: 10.112.0.0/16  # Add route: packets to 10.112.0.0/16 go via upfgtp interface
    snssai:              # OPTIONAL - only for logging, not routing logic
      sst: 1
      sd: "000001"
```

## Why Both Are Needed

### Control Plane (SMF) vs User Plane (UPF) Separation
This follows 3GPP's **CUPS** (Control and User Plane Separation) architecture:

1. **SMF (Control)**: Makes **intelligent decisions** about which UPF and which IP
2. **UPF (User)**: Performs **fast packet forwarding** based on routes

### Complete Flow Example
```
UE Registration → SMF receives PDU Session request for DNN "internet"
                ↓
SMF: "Which UPF serves 'internet'?" → Checks userplaneInformation → "UPF1"
                ↓
SMF: "Assign IP to UE" → Selects 10.112.0.100 from pool 10.112.0.0/16
                ↓
SMF: "Tell UPF1 to create GTP tunnel for 10.112.0.100" → PFCP message to UPF
                ↓
UPF1: "Route packets for 10.112.0.100" → Uses existing route for 10.112.0.0/16
```

## Single UPF Deployment (Current Setup)

### SMF Config
```yaml
userplaneInformation:
  upNodes:
    UPF1:
      sNssaiUpfInfos:
        - sNssai: {sst: 1, sd: "000001"}
          dnnUpfInfoList:
            - dnn: internet
              pools: [10.112.0.0/16]
            - dnn: ims
              pools: [10.113.0.0/16]
            - dnn: fast.t-mobile.com
              pools: [10.111.0.0/16]
```

### UPF1 Config
```yaml
dnnList:
  - dnn: internet
    cidr: 10.112.0.0/16
  - dnn: ims
    cidr: 10.113.0.0/16
  - dnn: fast.t-mobile.com
    cidr: 10.111.0.0/16
```

**Result**: Configurations appear almost identical because **all DNNs → single UPF**

**Why they're still different**:
- SMF has S-NSSAI information (required for slice selection)
- SMF has pool details (for IP assignment)
- UPF has route information (for packet forwarding)
- SMF knows about topology, UPF only knows local routes

## Multiple UPF Deployment (Different Configs)

### SMF Config (Knows About All UPFs)
```yaml
userplaneInformation:
  upNodes:
    UPF-Edge:  # Near user, for low latency
      sNssaiUpfInfos:
        - sNssai: {sst: 1}
          dnnUpfInfoList:
            - dnn: internet
              pools: [10.112.0.0/16]

    UPF-IMS:  # Dedicated for voice
      sNssaiUpfInfos:
        - sNssai: {sst: 1}
          dnnUpfInfoList:
            - dnn: ims
              pools: [10.113.0.0/16]

    UPF-MEC:  # Multi-access Edge Computing
      sNssaiUpfInfos:
        - sNssai: {sst: 1, sd: "000001"}
          dnnUpfInfoList:
            - dnn: fast.t-mobile.com
              pools: [10.111.0.0/16]
```

### UPF-Edge Config (Only Its DNNs)
```yaml
dnnList:
  - dnn: internet
    cidr: 10.112.0.0/16
```

### UPF-IMS Config (Only Its DNNs)
```yaml
dnnList:
  - dnn: ims
    cidr: 10.113.0.0/16
```

### UPF-MEC Config (Only Its DNNs)
```yaml
dnnList:
  - dnn: fast.t-mobile.com
    cidr: 10.111.0.0/16
```

**Result**: Each UPF only has routes for **its specific DNNs** - configs are **completely different**!

## Real-World Multi-UPF Use Cases

### 1. Geographic Distribution
- **UPF-Tokyo**: Serves users in Asia
- **UPF-NewYork**: Serves users in North America
- **UPF-London**: Serves users in Europe
- SMF routes UE to nearest UPF based on location

### 2. Service Separation
- **UPF-Internet**: General internet traffic (DNN: internet)
- **UPF-IMS**: Voice/video calls (DNN: ims)
- **UPF-Enterprise**: Corporate VPN (DNN: enterprise)
- SMF routes based on requested service type

### 3. Edge Computing
- **Central-UPF**: Standard traffic, centralized datacenter
- **Edge-UPF**: Low-latency apps (gaming, AR/VR), local edge sites
- SMF selects based on latency requirements

### 4. Load Balancing
- **UPF-1**: internet (pool: 10.112.0.0/17)
- **UPF-2**: internet (pool: 10.112.128.0/17)
- **UPF-3**: internet (pool: 10.113.0.0/17)
- SMF distributes load across multiple UPFs for same DNN

### 5. Network Slicing
- **UPF-eMBB**: Enhanced Mobile Broadband (SST:1)
- **UPF-URLLC**: Ultra-Reliable Low Latency (SST:2)
- **UPF-mMTC**: Massive Machine Type Communications (SST:3)
- SMF routes based on S-NSSAI slice type

## Key Takeaways

1. **Single UPF**: SMF and UPF configs look similar but serve different purposes
2. **Multiple UPFs**: Configs become clearly different - SMF has global view, each UPF has local view
3. **SMF**: Network intelligence, UPF selection, IP management, slice awareness
4. **UPF**: Fast packet forwarding, route installation, slice-agnostic operation
5. **SNSSAI in UPF**: Optional field added for logging clarity, not routing functionality

## Summary Table

| Aspect | SMF userplaneInformation | UPF dnnList |
|--------|--------------------------|-------------|
| **Purpose** | Network topology & IP management | Local route installation |
| **Scope** | All UPFs in network | Single UPF only |
| **S-NSSAI** | Mandatory (for slice routing) | Optional (for logging) |
| **Functionality** | Selects UPF, assigns IPs | Forwards packets |
| **Single UPF** | Lists all DNNs | Lists all DNNs (appears duplicate) |
| **Multiple UPFs** | Lists all UPFs/DNNs | Lists only own DNNs (clearly different) |
| **Updates** | When topology changes | When local routes change |

## Configuration Synchronization

**Important**: When using multiple UPFs, you must ensure:
- Every pool in SMF's `dnnUpfInfoList` has a corresponding route in the UPF's `dnnList`
- The CIDR ranges match exactly between SMF and UPF
- If SMF assigns IPs from 10.112.0.0/16, UPF must have a route for 10.112.0.0/16

**Mismatch consequences**:
- SMF assigns IP that UPF can't route → UE has IP but no connectivity
- UPF has route that SMF doesn't know about → Unused configuration
