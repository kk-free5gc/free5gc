# Router Advertisement Endpoint Implementation Plan (Section 3.2.4)

## Overview
Implement the Router Advertisement (RA) delivery mechanism from SMF → UPF → UE, completing the IPv6 autoconfiguration flow.

## Current State & Architecture Decision

### Current PFCP Flow (Partial - RS Detection Only)
1. **UE sends RS** → UPF detects via packet inspection
2. **UPF → SMF**: PFCP Event Report (Event ID 26 = Router Solicitation) ✅ Working
3. **SMF receives event** in `handler.go:217` → `HandleEventReport()` ✅ Working
4. **SMF builds RA packet** in `router_advertisement.go` ✅ Working
5. **SMF → UPF**: RA delivery ❌ **MISSING - This is what we implement**

### Implementation Approach: Hybrid (Phase 3.1)
**Decision: HTTP REST Endpoint for RA Delivery**
- **Upstream (UPF → SMF)**: PFCP Event Report for RS detection (existing)
- **Downstream (SMF → UPF)**: HTTP REST for RA delivery (new)
- **Rationale**: Faster implementation, gets end-to-end RA working quickly

### Future Migration Path (Phase 3.2+)
**Option: Pure PFCP Approach**
- Use PFCP Session Modification with Downlink Data Notification
- Embed RA packet in PFCP IE (Information Element)
- Full 3GPP compliance
- **Configuration toggle** to switch between HTTP and PFCP methods

## Components to Implement

### 1. go-gtp5gnl Library (RA Injection Bindings)
**Location:** `go-gtp5gnl/` (local copy at `/home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/go-gtp5gnl`)

**Files:**
- `cmd.go` - Add `CMD_INJECT_RA` constant
- `ra.go` (NEW) - RA injection functions
- `attr_ra.go` (NEW) - RA attribute handling

**Key Functions:**
```go
// InjectRA sends RA packet to UE via gtp5g kernel module
func (c *Client) InjectRA(linkID int, seid uint64, pdrID uint16, raPacket []byte) error
```

**Integration with gtp5g:**
- Calls existing `gtp5g_genl_inject_ra()` in `gtp5g/src/genl/genl_ra.c` ✅ Already implemented
- Uses netlink attributes: `GTP5G_RA_SEID`, `GTP5G_RA_PDR_ID`, `GTP5G_RA_PACKET`

### 2. UPF HTTP Service
**Files:**
- `free5gc/NFs/upf/internal/http/` (NEW directory)
  - `server.go` - HTTP server initialization and routing
  - `handler_ra.go` - RA injection endpoint handler
- `free5gc/NFs/upf/pkg/app/app.go` - Start HTTP server in `Run()`
- `free5gc/NFs/upf/pkg/factory/config.go` - Add HTTP config structure

**HTTP Endpoint:**
```
POST /upf/v1/inject-ra
Content-Type: application/json

Request Body:
{
  "seid": 12345,           // uint64 - PFCP Session ID
  "pdrId": 1,              // uint16 - PDR ID identifying the UE
  "raPacket": "base64..."  // base64-encoded ICMPv6 RA packet
}

Response (200 OK):
{
  "success": true,
  "message": "WNC: RA packet injected successfully"
}

Response (400/500 Error):
{
  "success": false,
  "message": "WNC: Error description"
}
```

**Handler Logic:**
1. Decode base64 RA packet
2. Validate SEID/PDR ID
3. Call `go-gtp5gnl.InjectRA()`
4. Return success/error response

### 3. SMF UPF Consumer (HTTP Client)
**Files:**
- `free5gc/NFs/smf/internal/sbi/consumer/upf_service.go` (NEW)
  - HTTP client for UPF RA injection
- `free5gc/NFs/smf/internal/context/sm_context.go`
  - Update `SendRouterAdvertisement()` to call UPF HTTP endpoint
- `free5gc/NFs/smf/internal/context/upf.go`
  - Add `HttpUri string` field to UPF context

**Flow:**
1. SMF receives PFCP Event Report (RS) → `HandleEventReport()`
2. SMF builds RA packet → `BuildRouterAdvertisement()`
3. SMF looks up UPF HTTP endpoint from UPF context (derived from PFCP node address)
4. SMF sends HTTP POST to `http://<upf-addr>:8080/upf/v1/inject-ra`
5. UPF calls go-gtp5gnl → gtp5g injects RA to UE

**UPF Endpoint Discovery:**
- Use UPF's PFCP node address (already known to SMF)
- Assume HTTP service on same host with configured port (default: 8080)
- Format: `http://<upf-pfcp-addr>:<http-port>/upf/v1/inject-ra`

### 4. Configuration (HTTP vs PFCP Toggle)

#### UPF Configuration
**File:** `free5gc/NFs/upf/pkg/factory/config.go`
```go
type Config struct {
    // ... existing fields ...
    HttpService *HttpService `yaml:"httpService" valid:"optional"`
}

type HttpService struct {
    Enable bool   `yaml:"enable" valid:"optional"`  // Enable HTTP RA injection endpoint
    Addr   string `yaml:"addr"   valid:"optional,host"`
    Port   uint16 `yaml:"port"   valid:"optional"`
}
```

**File:** `free5gc/config/upfcfg.yaml`
```yaml
httpService:
  enable: true          # Enable HTTP endpoint for RA injection
  addr: 127.0.0.8       # Listen address (same as PFCP by default)
  port: 8080            # HTTP service port
```

#### SMF Configuration
**File:** `free5gc/NFs/smf/pkg/factory/config.go`
```go
type Configuration struct {
    // ... existing fields ...
    RouterAdvertisement *RouterAdvertisementConfig `yaml:"routerAdvertisement" valid:"optional"`
}

type RouterAdvertisementConfig struct {
    DeliveryMethod string `yaml:"deliveryMethod" valid:"optional,in(http|pfcp)"` // "http" or "pfcp"
    UpfHttpPort    uint16 `yaml:"upfHttpPort"    valid:"optional"`               // UPF HTTP port (default: 8080)
}
```

**File:** `free5gc/config/smfcfg.yaml`
```yaml
routerAdvertisement:
  deliveryMethod: http  # Phase 3.1: Use HTTP; Phase 3.2+: Use "pfcp"
  upfHttpPort: 8080     # UPF HTTP service port
```

**Configuration Behavior:**
- **`deliveryMethod: http`** (Phase 3.1 - Default)
  - SMF uses HTTP POST to UPF endpoint
  - UPF HTTP server must be enabled
- **`deliveryMethod: pfcp`** (Phase 3.2+ - Future)
  - SMF uses PFCP Session Modification
  - UPF HTTP server optional (can disable to save resources)

### 5. Error Handling & Logging

**All logs use "WNC:" prefix for traceability**

**SMF Logs:**
```
[INFO][SMF] WNC: Router Solicitation event received (SEID=12345, Event ID=26)
[INFO][SMF] WNC: Sending RA via HTTP to UPF http://127.0.0.8:8080 (delivery method: http)
[ERROR][SMF] WNC: Failed to send RA to UPF: connection refused
```

**UPF Logs:**
```
[INFO][UPF] WNC: HTTP RA injection endpoint started on 127.0.0.8:8080
[INFO][UPF] WNC: Received RA injection request (SEID=12345, PDR_ID=1, packet_len=48)
[INFO][UPF] WNC: RA packet injected successfully via gtp5g
```

**gtp5g Kernel Logs:**
```
[INFO] WNC: Injecting RA packet (SEID=12345, PDR_ID=1, UE=2001:db8::1, len=48)
[INFO] WNC: RA packet injected successfully
```

## Implementation Steps

1. ✅ **Analysis Complete** - Understand existing PFCP flow and gtp5g RA injection
2. **go-gtp5gnl bindings** - Add RA injection netlink wrapper
3. **UPF HTTP server** - Create HTTP service with RA endpoint
4. **SMF consumer** - Implement HTTP client to call UPF
5. **Configuration** - Add HTTP config with delivery method toggle
6. **Integration** - Wire up SMF → UPF HTTP flow
7. **Testing** - End-to-end RA delivery validation

## Testing Strategy

### Unit Tests
- go-gtp5gnl RA injection with mock netlink
- UPF HTTP handler with mock gtp5g client
- SMF UPF consumer with mock HTTP server

### Integration Tests
1. **RS Detection:** UE sends RS → UPF PFCP Event Report → SMF receives
2. **RA Building:** SMF builds valid ICMPv6 RA packet
3. **HTTP Delivery:** SMF HTTP POST → UPF receives and validates
4. **Kernel Injection:** UPF calls gtp5g → kernel logs show injection
5. **End-to-End:** UE receives RA and autoconfigures IPv6 address

### Validation Commands
```bash
# Check UPF HTTP server running
curl http://127.0.0.8:8080/upf/v1/inject-ra -X POST -d '{"seid":1,"pdrId":1,"raPacket":"..."}'

# Monitor logs
tail -f /var/log/free5gc/upf.log | grep "WNC.*RA"
dmesg | grep -E "(WNC|gtp5g).*RA"

# Verify UE receives RA (on UE namespace)
tcpdump -i any -n 'icmp6 and ip6[40] == 134'  # ICMPv6 type 134 = RA
```

## Phase Comparison

### Phase 3.1 (Current - HTTP Approach)
| Direction | Method | Status |
|-----------|--------|--------|
| UE → UPF → SMF (RS) | PFCP Event Report | ✅ Working |
| SMF → UPF → UE (RA) | HTTP REST | ⚙️ **Implementing** |

**Pros:**
- Fast implementation (1-2 days)
- Simple architecture
- Easy debugging (standard HTTP tools)

**Cons:**
- Hybrid approach (not pure 3GPP)
- Extra HTTP port to manage

### Phase 3.2+ (Future - Pure PFCP Approach)
| Direction | Method | Status |
|-----------|--------|--------|
| UE → UPF → SMF (RS) | PFCP Event Report | ✅ Working |
| SMF → UPF → UE (RA) | PFCP Session Modification | 📋 Planned |

**Pros:**
- Full 3GPP compliance
- Single protocol (PFCP only)
- No extra HTTP service

**Cons:**
- More complex implementation
- Requires PFCP IE extensions
- Longer development time

## Migration Path

**Deployment Strategy:**
1. **Phase 3.1:** Deploy with `deliveryMethod: http`
2. **Phase 3.2:** Implement PFCP approach in parallel
3. **Testing:** Validate PFCP approach with `deliveryMethod: pfcp`
4. **Production:** Choose method based on operator preference
5. **Long-term:** Deprecate HTTP method once PFCP proven stable

## Notes
- gtp5g RA injection already complete (3.1.5) ✅
- SMF RA building already complete (Phase 2.5) ✅
- HTTP approach is **pragmatic path forward** for Phase 3.1
- Configuration toggle allows **seamless migration** to PFCP later
- Both methods use same gtp5g kernel injection (common path)

---

**Document Version:** 1.0
**Date:** 2025-10-29
**Status:** Ready for Implementation - Phase 3.1 (HTTP Approach)
**Next Phase:** Phase 3.2 (PFCP Approach - Future)
