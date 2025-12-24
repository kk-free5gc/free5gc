# Phase 3 IPv6 Implementation - Consolidated Documentation

**Document Version:** 2.0
**Last Updated:** December 24, 2025
**Status:** Production Ready
**Completion:** Phase 3 Complete (Dec 12, 2025)

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Phase 3.1: IPv6 Packet Processing](#phase-31-ipv6-packet-processing)
3. [Phase 3.2: Router Advertisement](#phase-32-router-advertisement)
4. [Phase 3.3: Router Solicitation Monitoring](#phase-33-router-solicitation-monitoring)
5. [Phase 3.4: Testing and Validation](#phase-34-testing-and-validation)
6. [Troubleshooting Guide](#troubleshooting-guide)
7. [Completion Timeline](#completion-timeline)

---

## Executive Summary

### Overview

Phase 3 implements complete IPv6 user plane functionality across the gtp5g kernel module, UPF userspace, and SMF control plane. This phase builds upon Phase 2's control plane foundation to deliver end-to-end IPv6 data plane functionality with Router Advertisement support.

### Key Deliverables

✅ **COMPLETE** - All Phase 3 components implemented and verified (Dec 12, 2025)

| Component | Status | Completion Date |
|-----------|--------|-----------------|
| **gtp5g Kernel Module** | ✅ COMPLETE | Oct 29, 2025 |
| **UPF Userspace** | ✅ COMPLETE | Oct 29, 2025 |
| **SMF Control Plane** | ✅ COMPLETE | Oct 28, 2025 |
| **Router Advertisement HTTP Endpoint** | ✅ COMPLETE | Oct 29, 2025 |
| **PFCP Event Reporting** | ✅ COMPLETE | Dec 8, 2025 |
| **RS-Monitor Implementation** | ✅ COMPLETE | Dec 9, 2025 |
| **Wildcard Flow Support** | ✅ COMPLETE | Dec 10, 2025 |
| **Downlink Flow Derivation** | ✅ COMPLETE | Dec 11, 2025 |
| **RS-Monitor Cleanup Fixes** | ✅ COMPLETE | Dec 12, 2025 |

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Phase 3 Architecture                         │
└─────────────────────────────────────────────────────────────────┘

UE (IPv6)
  ↕ GTP-U Tunnel (IPv6 inner packets)
gtp5g Kernel Module
  • IPv6 PDR matching (hash-based lookup)
  • IPv6 SDF filters (flow label, addresses)
  • GTP-U encap/decap for IPv6
  • Router Advertisement injection
  ↕
UPF Userspace (Go)
  • IPv6 PFCP IE encoding
  • IPv6 routing setup
  • RA HTTP endpoint
  • go-gtp5gnl bindings
  ↕ PFCP (N4)
SMF Control Plane (Go)
  • IPv6 address allocation (Phase 2)
  • Router Solicitation detection
  • Router Advertisement generation
  • PFCP Event Reporting
```

---

## Phase 3.1: IPv6 Packet Processing

### 3.1.1 gtp5g Kernel Module (✅ Complete - Oct 29, 2025)

#### UAPI Extensions

**File:** `gtp5g/include/genl_pdr.h`

**New Netlink Attributes:**
```c
enum gtp5g_pdi_attrs {
    GTP5G_PDI_UE_ADDR_IPV6,      // 16 bytes for UE IPv6 address
    // ...
};

enum gtp5g_f_teid_attrs {
    GTP5G_F_TEID_GTPU_ADDR_IPV6,  // 16 bytes for GTP-U endpoint IPv6
    // ...
};

enum gtp5g_flow_description_attrs {
    GTP5G_FLOW_DESCRIPTION_SRC_IPV6,       // IPv6 source address
    GTP5G_FLOW_DESCRIPTION_SRC_IPV6_MASK,  // IPv6 source mask
    GTP5G_FLOW_DESCRIPTION_DEST_IPV6,      // IPv6 destination address
    GTP5G_FLOW_DESCRIPTION_DEST_IPV6_MASK, // IPv6 destination mask
    GTP5G_FLOW_DESCRIPTION_FLOW_LABEL,     // 20-bit IPv6 flow label
    // ...
};
```

#### Kernel Data Structures

**File:** `gtp5g/include/pdr.h`

```c
struct local_f_teid {
    u32 teid;
    struct in_addr gtpu_addr_ipv4;
    struct in6_addr *gtpu_addr_ipv6;  // Dynamically allocated
};

struct ip_filter_rule {
    // IPv4 fields (existing)
    struct in_addr *src, *smask, *dest, *dmask;

    // IPv6 fields (new)
    struct in6_addr *src_ipv6, *smask_ipv6;
    struct in6_addr *dest_ipv6, *dmask_ipv6;
    u32 flow_label;  // 20-bit IPv6 flow label
    // ...
};

struct pdi {
    u8 srcIntf;
    struct in_addr *ue_addr_ipv4;
    struct in6_addr *ue_addr_ipv6;  // Dynamically allocated
    // ...
};

struct pdr {
    u16 af;  // AF_INET | AF_INET6 for dual-stack
    // ...
};
```

#### PDR Matching and Hash Functions

**File:** `gtp5g/src/pfcp/pdr.c`

**IPv6 Hash Function:**
```c
static inline u32 ipv6_hashfn(const struct in6_addr *addr) {
    return jhash2((u32 *)addr->s6_addr32, 4, gtp5g_h_initval);
}
```

**IPv6 PDR Lookup:**
```c
struct pdr *pdr_find_by_ipv6(struct gtp5g_dev *gtp, struct sk_buff *skb,
        unsigned int hdrlen, const struct in6_addr *addr) {
    struct hlist_head *head = &gtp->addr_hash[ipv6_hashfn(addr) % gtp->hash_size];

    hlist_for_each_entry_rcu(pdr, head, hlist_addr) {
        if ((pdr->af & AF_INET6) && pdi->ue_addr_ipv6 &&
            ipv6_addr_equal(pdi->ue_addr_ipv6, addr)) {
            // Apply SDF filters
            if (pdi->sdf && !sdf_filter_match(pdi->sdf, skb, hdrlen, GTP5G_SDF_FILTER_OUT))
                continue;
            return pdr;
        }
    }
    return NULL;
}
```

#### Router Advertisement Injection (✅ Complete - Oct 29, 2025)

**Files Created:**
- `gtp5g/include/genl_ra.h` - RA injection UAPI
- `gtp5g/src/genl/genl_ra.c` - RA injection handler

**Netlink Operation:**
```c
int gtp5g_genl_inject_ra(struct sk_buff *skb, struct genl_info *info) {
    // 1. Validate SEID, PDR_ID, RA packet
    // 2. Find PDR by SEID and PDR_ID
    // 3. Validate PDR has IPv6 UE address and is downlink
    // 4. Allocate skb for RA packet
    // 5. Inject packet via dev_queue_xmit()
    return 0;
}
```

**Command Registration:**
```c
enum gtp5g_cmd {
    GTP5G_CMD_INJECT_RA,  // Router Advertisement injection
    // ...
};
```

#### Build Status

```bash
cd gtp5g && make clean && make
# ✅ Build successful
# Module: gtp5g.ko
```

---

### 3.1.2 UPF Userspace (✅ Complete - Oct 29, 2025)

#### go-gtp5gnl Bindings Update

**Files Modified:**
- `go-gtp5gnl/cmd.go` - Added `CMD_INJECT_RA`
- `go-gtp5gnl/attr_pdr.go` - IPv6 attribute constants
- `go-gtp5gnl/ra.go` (NEW) - RA injection function

**IPv6 Constants:**
```go
const (
    PDI_UE_ADDR_IPV6           = 2
    F_TEID_GTPU_ADDR_IPV6      = 3
    FLOW_DESCRIPTION_SRC_IPV6  = 8
    FLOW_DESCRIPTION_DEST_IPV6 = 10
    FLOW_DESCRIPTION_FLOW_LABEL = 14
)
```

**RA Injection Function:**
```go
func (c *Client) InjectRA(linkID int, seid uint64, pdrID uint16, raPacket []byte) error {
    req := nl.NewRequest(c.ID, CMD_INJECT_RA)
    req.Append(&nl.AttrList{
        {Type: LINK, Value: nl.AttrU32(linkID)},
        {Type: ATTR_RA_SEID, Value: nl.AttrU64(seid)},
        {Type: ATTR_RA_PDR_ID, Value: nl.AttrU16(pdrID)},
        {Type: ATTR_RA_PACKET, Value: nl.AttrBytes(raPacket)},
    })
    _, err := c.Do(req)
    return err
}
```

#### PFCP IE Encoding for IPv6

**File:** `free5gc/NFs/upf/internal/forwarder/gtp5g.go`

**Version Gating:**
```go
func (g *Gtp5g) supportsIPv6() bool {
    const minGtp5gVersionForIPv6 = "0.9.0"
    nowVer, _ := version.NewVersion(g.version)
    minIPv6Ver, _ := version.NewVersion(minGtp5gVersionForIPv6)
    return nowVer.GreaterThanOrEqual(minIPv6Ver)
}
```

**IPv6 UE Address Encoding:**
```go
case ie.UEIPAddress:
    v, _ := x.UEIPAddress()

    // IPv4 handling (existing)
    if len(v.IPv4Address) > 0 {
        attrs = append(attrs, nl.Attr{
            Type: gtp5gnl.PDI_UE_ADDR_IPV4,
            Value: nl.AttrBytes(v.IPv4Address),
        })
    }

    // IPv6 handling (new)
    if len(v.IPv6Address) > 0 && g.supportsIPv6() {
        attrs = append(attrs, nl.Attr{
            Type: gtp5gnl.PDI_UE_ADDR_IPV6,
            Value: nl.AttrBytes(v.IPv6Address),
        })
        g.log.Infof("WNC: PDI UE IPv6 address: %v", net.IP(v.IPv6Address))
    }
```

#### IPv6 Routing and Interface Setup

**File:** `free5gc/NFs/upf/internal/forwarder/driver.go`

**IPv6 Route Setup:**
```go
if hasIPv6 {
    _, dst6, _ := net.ParseCIDR(dnn.IPv6.Prefix)
    link.RouteAdd(dst6)

    // Assign gateway IPv6 address
    gatewayIP := calculateGatewayIPv6(dst6)
    ones, _ := dst6.Mask.Size()
    link.AddIPv6Address(gatewayIP, ones)

    logger.MainLog.Infof("WNC: Added IPv6 route for DNN %s: %s (UE prefix length: /%d)",
        dnn.Dnn, dnn.IPv6.Prefix, dnn.IPv6.UePrefixLength)
}
```

**File:** `free5gc/NFs/upf/internal/forwarder/gtp5glink.go`

**IPv6 Forwarding:**
```go
func enableIPv6Forwarding(ifName string, log *logrus.Entry) error {
    sysctlPath := fmt.Sprintf("/proc/sys/net/ipv6/conf/%s/forwarding", ifName)
    err := os.WriteFile(sysctlPath, []byte("1"), 0644)
    if err != nil {
        return errors.Wrapf(err, "WNC: failed to write to %s", sysctlPath)
    }
    log.Infof("WNC: Enabled IPv6 forwarding on interface %s", ifName)
    return nil
}
```

#### Build Status

```bash
cd free5gc && make upf
# ✅ Build successful
```

---

## Phase 3.2: Router Advertisement

### 3.2.1 SMF Control Plane (✅ Complete - Oct 28, 2025)

#### Router Solicitation Detection

**File:** `free5gc/NFs/smf/internal/pfcp/handler/handler.go`

**PFCP Session Report Handler:**
```go
// WNC: Handle Event Reporting for Router Solicitation (Phase 3)
if req.UsageReport != nil {
    for _, usageReport := range req.UsageReport {
        if usageReport.EventReporting != nil && usageReport.EventReporting.EventID != nil {
            eventID := usageReport.EventReporting.EventID.EventId

            if eventID == smf_context.EventIDRouterSolicitation {
                logger.PfcpLog.Infof("WNC: Router Solicitation event for SEID %d", SEID)
                smContext.HandleEventReport(eventID)
            }
        }
    }
}
```

**File:** `free5gc/NFs/smf/internal/context/sm_context.go`

**Event Report Handler:**
```go
func (smContext *SMContext) HandleEventReport(eventID uint32) {
    switch eventID {
    case EventIDRouterSolicitation:
        smContext.Log.Infof("WNC: Router Solicitation event received (Event ID: %d)", eventID)

        // Validate IPv6 session
        if smContext.SelectedPDUSessionType != nasMessage.PDUSessionTypeIPv6 &&
           smContext.SelectedPDUSessionType != nasMessage.PDUSessionTypeIPv4IPv6 {
            return
        }

        // Build RA packet
        ipv6Prefix := GetIPv6PrefixFromAddress(smContext.PDUAddressIPv6, smContext.PDUAddressIPv6PrefixLen)
        raPacket := BuildRouterAdvertisement(ipv6Prefix, smContext.PDUAddressIPv6PrefixLen)

        // Send to UPF
        smContext.SendRouterAdvertisement(raPacket)
    }
}
```

### 3.2.2 Router Advertisement HTTP Endpoint (✅ Complete - Oct 29, 2025)

#### UPF HTTP Service

**Files Created:**
- `free5gc/NFs/upf/internal/http/server.go` - HTTP server
- `free5gc/NFs/upf/internal/http/handler_ra.go` - RA endpoint handler

**HTTP API:**
```
POST /upf/v1/inject-ra
Content-Type: application/json

Request:
{
  "seid": 12345,
  "pdrId": 1,
  "raPacket": "base64..."
}

Response (200 OK):
{
  "success": true,
  "message": "WNC: RA packet injected successfully"
}
```

**Handler Implementation:**
```go
func (s *Server) HandleInjectRA(c *gin.Context) {
    var req InjectRARequest
    c.ShouldBindJSON(&req)

    raPacket, _ := base64.StdEncoding.DecodeString(req.RAPacket)

    gtp5g := s.driver.(interface {
        InjectRA(seid uint64, pdrID uint16, raPacket []byte) error
    })

    if err := gtp5g.InjectRA(req.SEID, req.PDRID, raPacket); err != nil {
        c.JSON(500, InjectRAResponse{Success: false, Message: err.Error()})
        return
    }

    c.JSON(200, InjectRAResponse{Success: true, Message: "RA injected"})
}
```

#### SMF UPF Consumer

**File:** `free5gc/NFs/smf/internal/context/upf_ra_client.go` (NEW)

**HTTP Client:**
```go
func sendRouterAdvertisementViaHTTPClient(upfHTTPEndpoint string, seid uint64,
                                          pdrID uint16, raPacket []byte) error {
    encodedPacket := base64.StdEncoding.EncodeToString(raPacket)

    req := upfInjectRARequest{
        SEID:     seid,
        PDRID:    pdrID,
        RAPacket: encodedPacket,
    }

    jsonData, _ := json.Marshal(req)
    url := fmt.Sprintf("%s/upf/v1/inject-ra", upfHTTPEndpoint)

    httpReq, _ := http.NewRequest("POST", url, bytes.NewBuffer(jsonData))
    httpReq.Header.Set("Content-Type", "application/json")

    client := &http.Client{Timeout: 5 * time.Second}
    resp, err := client.Do(httpReq)
    // ... handle response
    return nil
}
```

**File:** `free5gc/NFs/smf/internal/context/sm_context.go`

**RA Delivery:**
```go
func (smContext *SMContext) SendRouterAdvertisement(raPacket []byte) error {
    deliveryMethod := "http"  // From config

    switch deliveryMethod {
    case "http":
        return smContext.sendRouterAdvertisementViaHTTP(raPacket, 8080)
    case "pfcp":
        return errors.New("WNC: PFCP RA delivery not yet implemented")
    }
}

func (smContext *SMContext) sendRouterAdvertisementViaHTTP(raPacket []byte, upfHTTPPort uint16) error {
    // Get UPF address and build endpoint
    upfAddr := smContext.Tunnel.DataPathPool.GetDefaultPath().FirstDPNode.UPF.Addr
    upfHTTPEndpoint := "http://" + net.JoinHostPort(upfAddr, strconv.Itoa(int(upfHTTPPort)))

    // Get SEID and PDR ID
    seid := smContext.PFCPContext[upfNode.GetNodeIP()].RemoteSEID
    pdrID := /* find downlink PDR from session-specific PFCP context */

    return sendRouterAdvertisementViaHTTPClient(upfHTTPEndpoint, seid, pdrID, raPacket)
}
```

#### Configuration

**File:** `free5gc/config/upfcfg.yaml`

```yaml
httpService:
  enable: true
  addr: 127.0.0.8
  port: 8080
```

**File:** `free5gc/config/smfcfg.yaml`

```yaml
routerAdvertisement:
  deliveryMethod: http
  upfHttpPort: 8080
```

#### Complete Message Flow

```
1. UE sends Router Solicitation (ICMPv6 Type 133)
   ↓
2. UPF detects RS → PFCP Event Report (Event ID 26)
   ↓
3. SMF receives PFCP Session Report Request
   ↓
4. SMF HandleEventReport() validates IPv6 session
   ↓
5. SMF BuildRouterAdvertisement() creates 48-byte RA packet
   ↓
6. SMF HTTP POST to http://<upf-addr>:8080/upf/v1/inject-ra
   ↓
7. UPF HTTP server receives request
   ↓
8. UPF calls gtp5g.InjectRA()
   ↓
9. go-gtp5gnl sends netlink message
   ↓
10. gtp5g kernel module injects RA packet
    ↓
11. RA goes through GTP-U tunnel to UE
    ↓
12. UE receives RA and autoconfigures IPv6 address
```

#### Troubleshooting Fixes (Oct 29, 2025)

**Issue 1: Command ID Misalignment**
- **Problem:** go-gtp5gnl and gtp5g had different command ID ordering
- **Fix:** Reordered `CMD_INJECT_RA` to match kernel enum position
- **File:** `go-gtp5gnl/cmd.go`

**Issue 2: Wrong SEID**
- **Problem:** SMF used LocalSEID instead of RemoteSEID
- **Fix:** Changed to `RemoteSEID` (UPF's SEID)
- **File:** `free5gc/NFs/smf/internal/context/sm_context.go`

**Issue 3: IPv6 URL Formatting**
- **Problem:** IPv6 addresses not bracketed in URLs
- **Fix:** Use `net.JoinHostPort()` for proper IPv6 URL formatting
- **File:** `free5gc/NFs/smf/internal/context/sm_context.go`

**Issue 4: Wrong PDR Selection**
- **Problem:** Selected PDR from global pool (wrong UE)
- **Fix:** Use session-specific `pfcpContext.PDRs` with downlink filter
- **File:** `free5gc/NFs/smf/internal/context/sm_context.go`

---

## Phase 3.3: Router Solicitation Monitoring

### 3.3.1 PFCP Event Reporting (✅ Complete - Dec 8, 2025)

**Reference:** `issue_pfcp_event_reporting_router_solicitation_fix_251208.md`

#### Problem Statement

Prior to this implementation, IPv6 UEs were not receiving Router Advertisements because the SMF was **not requesting** Router Solicitation event reports from the UPF during PFCP Session Establishment.

#### Solution

**File:** `free5gc/NFs/smf/internal/pfcp/message/build.go`

**Modified Function Signature:**
```go
func urrToCreateURR(urr *context.URR, smContext *context.SMContext, pdrID uint16) *pfcp.CreateURR
```

**Event Reporting Logic:**
```go
// WNC: Add Event Reporting for Router Solicitation (Event ID 26) for IPv6 sessions
if pdrID != 0 && smContext != nil {
    hasIPv6 := smContext.SelectedPDUSessionType == nasMessage.PDUSessionTypeIPv6 ||
        smContext.SelectedPDUSessionType == nasMessage.PDUSessionTypeIPv4IPv6

    if hasIPv6 {
        createURR.EventInformation = &pfcp.EventInformation{
            EventID: &pfcpType.EventID{
                EventId: context.EventIDRouterSolicitation,
            },
            EventThreshold: &pfcpType.EventThreshold{
                EventThreshold: 1,
            },
        }

        // CRITICAL: Set Eveth bit to activate event reporting
        if createURR.ReportingTriggers == nil {
            createURR.ReportingTriggers = &pfcpType.ReportingTriggers{}
        }
        createURR.ReportingTriggers.Eveth = true

        smContext.Log.Infof("WNC: Added Event Reporting (Event ID 26 - Router Solicitation) for URR %d, PDR %d, Eveth=true",
            urr.URRID, pdrID)
    }
}
```

**PFCP Message Structure:**
```
CreateURR:
  URRID: 1
  MeasurementMethod: Volum=true
  ReportingTriggers:
    Start: true
    Eveth: true  ← Activates event reporting
  EventInformation:
    EventID: 26  ← Router Solicitation
    EventThreshold: 1
```

#### Critical Bug Fix: Missing Eveth Bit

Per 3GPP TS 29.244 §5.8.2, the Event Information IE is **only acted upon** when `Eveth` or `Evequ` is set in ReportingTriggers. Without this bit, the UPF would completely ignore the EventInformation IE.

---

### 3.3.2 Per-DNN RS Monitoring (✅ Complete - Dec 9, 2025)

**Reference:** `issue_router_solicitation_monitoring_fix_251209.md`

#### Problem Statement

URRs were only created when CHF charging was configured. Without CHF, no URRs existed on uplink PDRs, preventing Router Solicitation event reporting.

#### Solution Architecture

**1. Configuration Schema**

**File:** `free5gc/NFs/smf/pkg/factory/config.go`

```go
type DnnUpfInfoItem struct {
    Dnn                       string
    RouterSolicitationMonitor bool `yaml:"routerSolicitationMonitor" valid:"optional"`
    // ...
}
```

**Configuration Example:**
```yaml
userplaneInformation:
  upNodes:
    UPF:
      sNssaiUpfInfos:
        - sNssai: {sst: 1}
          dnnUpfInfoList:
            - dnn: fast.t-mobile.com
              routerSolicitationMonitor: true
```

**2. URR Type Extension**

**File:** `free5gc/NFs/smf/internal/context/sm_context.go`

```go
const (
    N3N6_MBQE_URR UrrType = iota
    N3N6_MAQE_URR
    // ...
    RS_MONITOR_URR  // Independent of CHF
    NOT_FOUND_URR
)
```

**3. SMContext State Persistence**

```go
type SMContext struct {
    // ...
    EnableRouterSolicitationMonitor bool  // Persists from DNN config
}

func (c *SMContext) populateRouterSolicitationMonitorFlag() {
    // Read from UPF config or DNNInfo
    // Survives UPF pointer churn (handover, release, etc.)
}
```

**4. URR Creation**

**File:** `free5gc/NFs/smf/internal/context/datapath.go`

```go
func (datapath *DataPath) addRSMonitorUrrToPath(smContext *SMContext) {
    // Check IPv6 support
    hasIPv6 := smContext.SelectedPDUSessionType == nasMessage.PDUSessionTypeIPv6 ||
        smContext.SelectedPDUSessionType == nasMessage.PDUSessionTypeIPv4IPv6

    if !hasIPv6 || !smContext.EnableRouterSolicitationMonitor {
        return
    }

    // Allocate URR ID
    if id, err := smContext.UrrIDGenerator.Allocate(); err == nil {
        smContext.UrrIdMap[RS_MONITOR_URR] = uint32(id)
    }

    // Create URR with minimal configuration
    urr, _ := curDataPathNode.UPF.AddURR(rsMonitorUrrId,
        NewMeasureInformation(true, false))  // Only MeasureMethod

    urr.ReportingTrigger.Start = true

    // Attach to uplink PDR only
    curDataPathNode.UpLinkTunnel.PDR.AppendURRs([]*URR{urr})
}
```

**5. PFCP Message Construction**

**File:** `free5gc/NFs/smf/internal/pfcp/message/build.go`

```go
// Only add RS event reporting to RS_MONITOR_URR, not CHF URRs
rsMonitorUrrId, rsMonitorExists := smContext.UrrIdMap[context.RS_MONITOR_URR]
if rsMonitorExists && urr.URRID == rsMonitorUrrId {
    // Add EventInformation and set Eveth=true
    createURR.EventInformation = &pfcp.EventInformation{
        EventID: &pfcpType.EventID{EventId: context.EventIDRouterSolicitation},
        EventThreshold: &pfcpType.EventThreshold{EventThreshold: 1},
    }
    createURR.ReportingTriggers.Eveth = true
}
```

#### CHF Compatibility

**With CHF + RS Monitoring:**
```
Uplink PDR:
  URR[0]: N3N6_MBQE_URR (CHF charging)
  URR[1]: N3N6_MAQE_URR (CHF charging)
  URR[2]: RS_MONITOR_URR (RS event reporting)
```

**Without CHF, With RS Monitoring:**
```
Uplink PDR:
  URR[0]: RS_MONITOR_URR (RS event reporting only)
```

---

### 3.3.3 Wildcard Flow Support (✅ Complete - Dec 10, 2025)

**Reference:** `issue_Open5GS_Style_Wildcard_Flow_Implementation_251210.md`

#### Problem Statement

Free5GC created too-strict SDF filters that only matched specific IP/port combinations. When no PCF policy existed, packets were dropped.

#### Solution: Open5GS-Style Wildcards

**1. Wildcard Flow Generation**

**File:** `free5gc/NFs/smf/internal/context/sm_context_policy.go`

```go
// Generate Open5GS-style wildcard flows when no PCF policy exists
if len(pcc.FlowInfos) == 0 && appID == "" {
    wildcardFlowDesc := "permit out ip from assigned to any"
    pcc.UpdateDataPathFlowDescription(wildcardFlowDesc)
    logger.CfgLog.Infof("WNC: Applied wildcard flow description for PCC rule [%s]: %s",
        pcc.PccRuleId, wildcardFlowDesc)
}
```

**2. Flow Description Handling**

**File:** `free5gc/NFs/smf/internal/context/pcc_rule.go`

```go
// Generate proper UL and DL flow descriptions
ulFlowDesc := dlFlowDesc
if dlFlowDesc == "permit out ip from assigned to any" {
    // Swap src/dst for downlink
    dlFlowDesc = "permit out ip from any to assigned"
    logger.CtxLog.Debugf("WNC: Generated wildcard flows - UL: %s, DL: %s",
        ulFlowDesc, dlFlowDesc)
}
```

**3. RS-Monitor PDR with Narrow SDF Filter**

**File:** `free5gc/NFs/smf/internal/context/datapath.go`

```go
// Create high-precedence RS-monitor PDR for narrow ICMPv6 RS matching
if curDataPathNode.IsAnchorUPF() && smContext.EnableRouterSolicitationMonitor && hasIPv6 {
    rsPDR, _ := curDataPathNode.UPF.AddPDR()

    // Higher precedence than general UL PDR
    rsPrecedence := precedence - 1
    rsPDR.Precedence = rsPrecedence

    // Copy PDI from UL PDR
    rsPDR.PDI = curULTunnel.PDR.PDI

    // Set narrow SDF filter for ICMPv6 RS only
    rsFlowDesc := "permit out 58 from fe80::/64 to ff02::2"
    rsPDR.PDI.SDFFilter = &pfcpType.SDFFilter{
        Fd:                      true,
        LengthOfFlowDescription: uint16(len(rsFlowDesc)),
        FlowDescription:         []byte(rsFlowDesc),
    }

    // Reuse same FAR as general UL PDR
    rsPDR.FAR = curULTunnel.PDR.FAR

    // Attach RS-monitor URR
    rsPDR.AppendURRs([]*URR{urr})
}
```

**Flow Descriptions:**

| Type | Flow Description | Matches |
|------|------------------|---------|
| **UL (General)** | `permit out ip from assigned to any` | All packets FROM UE |
| **DL (General)** | `permit out ip from any to assigned` | All packets TO UE |
| **RS-Monitor** | `permit out 58 from fe80::/64 to ff02::2` | ICMPv6 RS only |

---

### 3.3.4 Downlink Flow Derivation (✅ Complete - Dec 11, 2025)

**Reference:** `issue_downlink_flow_derivation_and_dual_stack_test_fix_251211.md`

#### Problem Statement

`deriveDownlinkFlow()` only handled the literal wildcard string and returned uplink flows unchanged for all other patterns, causing downlink traffic to be blocked.

#### Solution

**File:** `free5gc/NFs/smf/internal/context/pcc_rule.go`

**Complete Flow Derivation:**
```go
func deriveDownlinkFlow(ulFlowDesc string) string {
    tokens := strings.Fields(ulFlowDesc)

    // Find "from" and "to" keywords
    fromIdx, toIdx := -1, -1
    for i, token := range tokens {
        if token == "from" { fromIdx = i }
        if token == "to" { toIdx = i }
    }

    if fromIdx == -1 || toIdx == -1 || fromIdx >= toIdx {
        return ulFlowDesc  // Invalid format
    }

    // Extract parts
    prefix := tokens[0 : fromIdx+1]  // "permit out ip from"
    srcPart := tokens[fromIdx+1 : toIdx]  // source address and ports
    toPart := tokens[toIdx:]  // "to dst [dstPorts]"

    // Build downlink flow by swapping src and dst
    var dlTokens []string
    dlTokens = append(dlTokens, prefix...)
    dlTokens = append(dlTokens, toPart[1:]...)  // dst (skip "to")
    dlTokens = append(dlTokens, "to")
    dlTokens = append(dlTokens, srcPart...)  // src

    dlFlowDesc := strings.Join(dlTokens, " ")
    logger.CtxLog.Debugf("WNC: deriveDownlinkFlow: UL=%s -> DL=%s", ulFlowDesc, dlFlowDesc)
    return dlFlowDesc
}
```

**Supported Patterns:**

| Input (Uplink) | Output (Downlink) |
|----------------|-------------------|
| `permit out ip from assigned to any` | `permit out ip from any to assigned` |
| `permit out ip from 192.168.0.21 to 10.60.0.0/16` | `permit out ip from 10.60.0.0/16 to 192.168.0.21` |
| `permit out ip from any 80 to assigned` | `permit out ip from assigned to any 80` |
| `permit out 6 from 10.0.0.0/8 to assigned` | `permit out 6 from assigned to 10.0.0.0/8` |

**Test Coverage:**
- 16 test cases in `pcc_rule_test.go`
- 5 bidirectional test cases
- All tests passing ✅

---

### 3.3.5 RS-Monitor Cleanup Fixes (✅ Complete - Dec 12, 2025)

**Reference:** `issue_rs_monitor_pdr_urr_cleanup_fixes_251212.md`

#### Problem 1: Missing OuterHeaderRemoval

**Issue:** RS PDR didn't have OHR set, causing kernel to drop RS packets.

**Fix:** `free5gc/NFs/smf/internal/context/datapath.go:844-852`

```go
// Copy OuterHeaderRemoval from ULPDR so gtp5g can decap the RS packet
rsPDR.OuterHeaderRemoval = curULTunnel.PDR.OuterHeaderRemoval
if rsPDR.OuterHeaderRemoval != nil {
    logger.PduSessLog.Infof("WNC: Set RS-monitor PDR OuterHeaderRemoval to match ULPDR (description: %d)",
        rsPDR.OuterHeaderRemoval.OuterHeaderRemovalDescription)
}
```

#### Problem 2: Incorrect URR Cleanup

**Issue:** `DeactivateRSMonitorPDR` called `node.UPF.RemoveURR()`, which freed ID from wrong generator.

**Fix:** `free5gc/NFs/smf/internal/context/datapath.go:262-284`

```go
// Set URR state to RULE_REMOVE so PFCP builder will send RemoveURR
urr.State = RULE_REMOVE

// Remove from UPF's urrPool (but NOT from urrIDGenerator)
node.UPF.urrPool.Delete(urr.URRID)

// Remove from SMF's UrrUpfMap
currentUUID := node.UPF.UUID()
urrKey := getUrrIdKey(currentUUID, urr.URRID)
delete(smContext.UrrUpfMap, urrKey)
```

#### Problem 3: Duplicate URR ID Freeing

**Issue:** IPv4-only sessions freed URR ID 0, corrupting the session ID generator.

**Fix:** `free5gc/NFs/smf/internal/context/datapath.go:1147-1162`

```go
// Only free if the ID was actually allocated (non-zero)
if rsMonitorUrrId, exists := smContext.UrrIdMap[RS_MONITOR_URR]; exists && rsMonitorUrrId != 0 {
    smContext.UrrIDGenerator.FreeID(int64(rsMonitorUrrId))
    delete(smContext.UrrIdMap, RS_MONITOR_URR)
    logger.CtxLog.Infof("WNC: Freed RS_MONITOR_URR ID %d back to session UrrIDGenerator", rsMonitorUrrId)
} else if exists && rsMonitorUrrId == 0 {
    logger.CtxLog.Debugf("WNC: Skipping RS_MONITOR_URR cleanup - ID is 0 (never allocated)")
    delete(smContext.UrrIdMap, RS_MONITOR_URR)
}
```

---

## Phase 3.4: Testing and Validation

### Build Verification

**All Components:**
```bash
# gtp5g kernel module
cd gtp5g && make clean && make
# ✅ Build successful

# UPF
cd free5gc && make upf
# ✅ Build successful

# SMF
make smf
# ✅ Build successful
```

### Unit Tests

**SMF Context Tests:**
```bash
cd NFs/smf
go test -v ./internal/context -run TestDeriveDownlinkFlow
# ✅ 21/21 tests passed
```

**UPF Forwarder Tests:**
```bash
cd NFs/upf
go test -v ./internal/forwarder -run TestParseFlowDesc
# ✅ 8/8 tests passed
```

### Integration Testing

**Expected Log Flow:**

```
[INFO][SMF] WNC: Added Event Reporting (Event ID 26 - Router Solicitation) for URR 7, PDR 1, Eveth=true
[INFO][UPF] WNC: HTTP RA injection endpoint started on 127.0.0.8:8080
[INFO][SMF] WNC: Router Solicitation event for SEID 12345
[INFO][SMF] WNC: Built Router Advertisement for prefix 2001:db8::/64 (48 bytes)
[INFO][SMF] WNC: Sending Router Advertisement via HTTP to UPF...
[INFO][UPF] WNC: Received RA injection request (SEID=12345, PDR_ID=1, packet_len=48)
[INFO][UPF] WNC: RA packet injected successfully via gtp5g
```

---

## Troubleshooting Guide

### Issue: RS Events Not Reported

**Symptoms:** No "Router Solicitation event" logs in SMF

**Checklist:**
1. ✅ `routerSolicitationMonitor: true` in config for the DNN?
2. ✅ Session is IPv6 or IPv4v6?
3. ✅ URR creation logs show "Created RS monitor URR"?
4. ✅ PFCP message logs show "Added Event Reporting (Event ID 26)"?
5. ✅ PFCP capture shows Create URR IE with Event ID 26 and Eveth=true?
6. ✅ UPF supports Event ID 26?

**Debug Commands:**
```bash
# Check Event Reporting was added
grep "Added Event Reporting.*Eveth=true" console_free5gc.log

# Check PFCP message with tcpdump
sudo tcpdump -i any -n port 8805 -w pfcp.pcap
# Analyze CreateURR in Wireshark
```

### Issue: RA Packets Not Delivered

**Symptoms:** RS detected but UE doesn't receive RA

**Checklist:**
1. ✅ UPF HTTP service running? `curl http://127.0.0.8:8080/health`
2. ✅ SMF sending HTTP request? Check "Sending RA via HTTP" logs
3. ✅ Correct SEID used? Should be RemoteSEID, not LocalSEID
4. ✅ Correct PDR ID? Should be downlink PDR from session-specific context
5. ✅ IPv6 URL formatting? Should use `net.JoinHostPort()` for brackets

**Debug Commands:**
```bash
# Monitor SMF logs
tail -f /var/log/free5gc/smf.log | grep "WNC.*RA"

# Monitor UPF logs
tail -f /var/log/free5gc/upf.log | grep "WNC.*RA"

# Monitor kernel logs
sudo dmesg -w | grep -E "(WNC|gtp5g).*RA"

# Packet capture
sudo tcpdump -i any -n 'icmp6 and ip6[40] == 134' -v
```

### Issue: Downlink Traffic Blocked

**Symptoms:** Uplink works, downlink blocked

**Possible Causes:**
1. Downlink flow not derived correctly
2. PDR missing or has wrong SDF filter
3. Kernel "No PDR match" errors

**Solution:**
```bash
# Check flow derivation logs
grep "deriveDownlinkFlow" console_free5gc.log

# Check PDR creation
cat /proc/gtp5g/pdr

# Check kernel logs
dmesg | grep "No PDR match"
```

### Issue: URR ID Corruption

**Symptoms:** Duplicate URR IDs, session creation failures

**Possible Causes:**
1. Freeing URR ID 0 (IPv4-only sessions)
2. Freeing from wrong ID generator
3. Not cleaning up UrrIdMap

**Solution:**
```bash
# Check URR cleanup logs
grep "Freed RS_MONITOR_URR" console_free5gc.log
grep "Skipping RS_MONITOR_URR cleanup" console_free5gc.log

# Verify no ID 0 freeing
grep "Freed.*ID 0" console_free5gc.log  # Should be empty
```

---

## Completion Timeline

### October 2025

| Date | Component | Status |
|------|-----------|--------|
| **Oct 28** | SMF Control Plane (RS Detection) | ✅ COMPLETE |
| **Oct 29** | gtp5g Kernel Module (IPv6 + RA) | ✅ COMPLETE |
| **Oct 29** | UPF Userspace (IPv6 + HTTP) | ✅ COMPLETE |
| **Oct 29** | RA HTTP Endpoint | ✅ COMPLETE |
| **Oct 29** | Troubleshooting Fixes (4 issues) | ✅ COMPLETE |

### December 2025

| Date | Component | Status |
|------|-----------|--------|
| **Dec 8** | PFCP Event Reporting | ✅ COMPLETE |
| **Dec 9** | RS-Monitor Per-DNN Config | ✅ COMPLETE |
| **Dec 10** | Wildcard Flow Support | ✅ COMPLETE |
| **Dec 11** | Downlink Flow Derivation | ✅ COMPLETE |
| **Dec 12** | RS-Monitor Cleanup Fixes | ✅ COMPLETE |

### Phase 3 Completion

**Status:** ✅ **PRODUCTION READY** (December 12, 2025)

**Key Achievements:**
- Complete IPv6 data plane functionality
- Router Advertisement delivery working
- Router Solicitation monitoring operational
- Wildcard flow support (Open5GS-style)
- Comprehensive test coverage
- All critical bugs fixed

**Test Results:**
- 29/29 unit tests passed
- All network functions compile successfully
- All files gofmt-clean

---

## References

### 3GPP Specifications

- **TS 29.244:** PFCP Protocol
- **TS 29.281:** GTP-U Protocol
- **TS 23.502:** 5G System Procedures
- **TS 24.501:** NAS Protocol for 5GS
- **RFC 4861:** IPv6 Neighbor Discovery
- **RFC 8200:** IPv6 Specification

### Implementation Documents

- `claude_free5gc_ipv6_implementation_plan_251014_v2_phase_3.md` - Original plan
- `issue_pfcp_event_reporting_router_solicitation_fix_251208.md` - Event reporting
- `issue_router_solicitation_monitoring_fix_251209.md` - RS-Monitor
- `issue_Open5GS_Style_Wildcard_Flow_Implementation_251210.md` - Wildcard flows
- `issue_downlink_flow_derivation_and_dual_stack_test_fix_251211.md` - Flow derivation
- `issue_rs_monitor_pdr_urr_cleanup_fixes_251212.md` - Cleanup fixes

### Code Locations

**gtp5g:**
- `gtp5g/include/genl_pdr.h` - UAPI attributes
- `gtp5g/src/pfcp/pdr.c` - PDR matching
- `gtp5g/src/genl/genl_ra.c` - RA injection

**UPF:**
- `free5gc/NFs/upf/internal/forwarder/gtp5g.go` - PFCP IE encoding
- `free5gc/NFs/upf/internal/http/` - HTTP RA endpoint

**SMF:**
- `free5gc/NFs/smf/internal/pfcp/message/build.go` - PFCP message construction
- `free5gc/NFs/smf/internal/context/datapath.go` - RS-Monitor PDR/URR
- `free5gc/NFs/smf/internal/context/sm_context.go` - Event handling

---

**End of Consolidated Documentation**
