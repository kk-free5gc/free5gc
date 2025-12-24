# Free5GC Phase 0 - IPv6 Configuration Schema Implementation Notes

**Date:** 2025-10-14
**Status:** ✅ Complete
**Based on:** `codex_free5gc_ipv6_implementation_plan_251014_v2_phase_0_ipv6_config_schema_decision.md`

---

## Overview

This document captures the complete implementation of IPv6 configuration schema changes for Free5GC SMF and UPF as outlined in Phase 0 of the IPv6 implementation plan. All changes follow the design specifications in sections 1-4 of the schema decision document.

---

## 1. SMF Schema Updates

### File Modified
`free5gc/NFs/smf/pkg/factory/config.go`

### New Structures Added

#### 1.1 UEIPv6Pool (Lines 685-718)
Defines IPv6 address pool configuration for UEs with comprehensive validation.

```go
type UEIPv6Pool struct {
	Prefix          string   `yaml:"prefix" valid:"ipv6cidr,required"`
	UePrefixLength  int      `yaml:"uePrefixLength" valid:"range(1|128),required"`
	IidAllocation   string   `yaml:"iidAllocation" valid:"in(random|eui64|manual),optional"`
	Exclude         []string `yaml:"exclude,omitempty" valid:"optional"`
	RaProfile       string   `yaml:"raProfile,omitempty" valid:"optional"`
}
```

**Validation Features:**
- IPv6 CIDR validation with proper slash parsing
- UE prefix length range: 1-128
- IID allocation modes: `random`, `eui64`, `manual`
- Exclude list validates IPv6 addresses or CIDRs
- Optional RA profile reference for Router Advertisements

#### 1.2 StaticUEIPv6Assignment (Lines 720-746)
Static IPv6 address assignments for specific UEs.

```go
type StaticUEIPv6Assignment struct {
	Supi         string `yaml:"supi" valid:"required"`
	Address      string `yaml:"address" valid:"ipv6,required"`
	PrefixLength int    `yaml:"prefixLength" valid:"range(1|128),required"`
	Comment      string `yaml:"comment,omitempty" valid:"optional"`
}
```

**Validation Features:**
- SUPI format: `imsi-[0-9]{5,15}`
- IPv6 address validation
- Prefix length range: 1-128
- Optional comment field for documentation

#### 1.3 SessionTypePolicy (Lines 748-785)
Defines supported PDU session types for a DNN.

```go
type SessionTypePolicy struct {
	Default string   `yaml:"default" valid:"in(ipv4|ipv6|ipv4v6),required"`
	Allowed []string `yaml:"allowed" valid:"required"`
}
```

**Validation Features:**
- Default session type: `ipv4`, `ipv6`, or `ipv4v6`
- Allowed list must contain at least one type
- Default must be present in allowed list
- Cross-validation ensures consistency

### DnnUpfInfoItem Extensions

#### Extended Fields (Lines 578-588)
```go
type DnnUpfInfoItem struct {
	Dnn                   string                        `json:"dnn" yaml:"dnn" valid:"required"`
	DnaiList              []string                      `json:"dnaiList" yaml:"dnaiList" valid:"optional"`
	PduSessionTypes       []models.PduSessionType       `json:"pduSessionTypes" yaml:"pduSessionTypes" valid:"optional"`
	Pools                 []*UEIPPool                   `json:"pools" yaml:"pools" valid:"optional"`
	StaticPools           []*UEIPPool                   `json:"staticPools" yaml:"staticPools" valid:"optional"`
	UeIPv6Pools             []*UEIPv6Pool                 `json:"ipv6Pools" yaml:"ipv6Pools" valid:"optional"`            // NEW
	StaticIPv6Pools       []*UEIPv6Pool                 `json:"ipv6StaticPools" yaml:"ipv6StaticPools" valid:"optional"`  // NEW
	IPv6StaticAssignments []*StaticUEIPv6Assignment     `json:"ipv6StaticAssignments" yaml:"ipv6StaticAssignments" valid:"optional"` // NEW
	SessionTypePolicy     *SessionTypePolicy            `json:"sessionTypePolicy" yaml:"sessionTypePolicy" valid:"optional"` // NEW
}
```

#### Enhanced Validation (Lines 590-643)
```go
func (d *DnnUpfInfoItem) validate() (bool, error) {
	// Validate IPv4 pools
	for _, pool := range d.Pools { ... }
	for _, pool := range d.StaticPools { ... }

	// Validate IPv6 pools
	for _, pool := range d.UeIPv6Pools { ... }
	for _, pool := range d.StaticIPv6Pools { ... }

	// Validate IPv6 static assignments
	for _, assignment := range d.IPv6StaticAssignments { ... }

	// Validate session type policy
	if d.SessionTypePolicy != nil { ... }

	// WNC: Ensure at least one pool type is configured (IPv4 or IPv6)
	if len(d.Pools) == 0 && len(d.StaticPools) == 0 &&
	   len(d.UeIPv6Pools) == 0 && len(d.StaticIPv6Pools) == 0 {
		return false, errors.New("DnnUpfInfoItem '" + d.Dnn +
			"' must have at least one pool configured (IPv4 or IPv6)")
	}

	result, err := govalidator.ValidateStruct(d)
	return result, appendInvalid(err)
}
```

### InterfaceUpfInfoItem Updates

#### IPv6 Endpoint Support (Lines 537-543)
```go
func (i *InterfaceUpfInfoItem) validate() (bool, error) {
	interfaceType := i.InterfaceType
	if result := (interfaceType == "N3" || interfaceType == "N9"); !result {
		err := errors.New("Invalid interfaceType: " + string(interfaceType) + ", should be N3 or N9.")
		return false, err
	}

	// WNC: Validate endpoints support both IPv4 and IPv6 addresses/FQDNs
	for _, endpoint := range i.Endpoints {
		if result := govalidator.IsHost(endpoint); !result {
			err := errors.New("WNC: Invalid endpoint:" + endpoint + ", should be IPv4, IPv6, or FQDN.")
			return false, err
		}
	}

	result, err := govalidator.ValidateStruct(i)
	return result, appendInvalid(err)
}
```

**Key Change:** Updated error message to accept IPv4, IPv6, or FQDN instead of IPv4-only.

### Import Changes (Line 11)
Added `strings` package for IPv6 CIDR validation:
```go
import (
	"errors"
	"fmt"
	"strconv"
	"strings"  // NEW - for IPv6 prefix parsing
	"sync"
	"time"
	// ...
)
```

---

## 2. UPF Schema Updates

### File Modified
`free5gc/NFs/upf/pkg/factory/config.go`

### Config Struct Extensions (Lines 18-26)

```go
type Config struct {
	Version                  string                               `yaml:"version"     valid:"required,in(1.0.3)"`
	Description              string                               `yaml:"description" valid:"optional"`
	Pfcp                     *Pfcp                                `yaml:"pfcp"        valid:"required"`
	Gtpu                     *Gtpu                                `yaml:"gtpu"        valid:"required"`
	DnnList                  []DnnList                            `yaml:"dnnList"     valid:"required"`
	Logger                   *Logger                              `yaml:"logger"      valid:"required"`
	RouterAdvertisements     map[string]*RouterAdvertisementProfile `yaml:"routerAdvertisements" valid:"optional"` // NEW
}
```

### IfInfo Extensions (Lines 40-49)

```go
type IfInfo struct {
	Addr       string `yaml:"addr"       valid:"required,host"`
	Type       string `yaml:"type"       valid:"required,in(N3|N9)"`
	Name       string `yaml:"name"       valid:"optional"`
	IfName     string `yaml:"ifname"     valid:"optional"`
	MTU        uint32 `yaml:"mtu"        valid:"optional"`
	Addr6      string `yaml:"addr6"      valid:"optional,ipv6"`      // NEW - IPv6 address
	LinkLocal  string `yaml:"linkLocal"  valid:"optional,ipv6"`      // NEW - Link-local IPv6
	RaProfile  string `yaml:"raProfile"  valid:"optional"`           // NEW - RA profile reference
}
```

### DnnList Refactoring (Lines 51-56)

```go
type DnnList struct {
	Dnn       string      `yaml:"dnn"       valid:"required"`
	Cidr      string      `yaml:"cidr"      valid:"optional,cidr"`  // IPv4 pool (changed from required to optional)
	NatIfName string      `yaml:"natifname" valid:"optional"`
	IPv6      *IPv6Pool   `yaml:"ipv6"      valid:"optional"`       // NEW - IPv6 pool
}
```

**Design Decision:** `Cidr` field retained for backward compatibility instead of renaming to `ipv4`.

### New Structures Added

#### 2.1 IPv6Pool (Lines 58-66)

```go
type IPv6Pool struct {
	Prefix                 string   `yaml:"prefix"                 valid:"required,cidr"`
	UePrefixLength         int      `yaml:"uePrefixLength"         valid:"optional"`
	Allocation             string   `yaml:"allocation"             valid:"optional,in(random|delegated|manual)"`
	RaProfile              string   `yaml:"raProfile"              valid:"optional"`
	DelegatedPrefixLength  int      `yaml:"delegatedPrefixLength"  valid:"optional"`
	StaticPrefixes         []string `yaml:"staticPrefixes"         valid:"optional"`
}
```

**Fields:**
- `Prefix`: IPv6 CIDR for the pool
- `UePrefixLength`: Prefix length delegated to each UE (default: 64)
- `Allocation`: How prefixes are allocated (random/delegated/manual)
- `RaProfile`: Router Advertisement profile reference
- `DelegatedPrefixLength`: For delegated mode
- `StaticPrefixes`: Pre-configured prefix list

#### 2.2 RouterAdvertisementProfile (Lines 68-79)

```go
type RouterAdvertisementProfile struct {
	Enable          bool     `yaml:"enable"          valid:"optional"`
	RouterAddress   string   `yaml:"routerAddress"   valid:"optional,ipv6"`
	PrefixLength    int      `yaml:"prefixLength"    valid:"optional"`
	LinkMtu         uint32   `yaml:"linkMtu"         valid:"optional"`
	Flags           uint8    `yaml:"flags"           valid:"optional"`
	Lifetime        uint32   `yaml:"lifetime"        valid:"optional"`
	ReachableTimer  uint32   `yaml:"reachableTimer"  valid:"optional"`
	RetransTimer    uint32   `yaml:"retransTimer"    valid:"optional"`
	DNS             []string `yaml:"dns"             valid:"optional"`
}
```

**Fields:**
- `Enable`: Toggle RA functionality
- `RouterAddress`: Router's IPv6 address
- `PrefixLength`: Advertised prefix length
- `LinkMtu`: Interface MTU value
- `Flags`: RA flags (Managed/Other config)
- `Lifetime`: Router lifetime in seconds
- `ReachableTimer`: Neighbor reachability timer
- `RetransTimer`: Retransmission timer
- `DNS`: DNS server list for RDNSS option

---

## 3. UPF Validation Logic

### File Modified
`free5gc/NFs/upf/pkg/factory/factory.go`

### Enhanced Validation (Lines 49-72)

```go
// WNC: Validate each DNN has at least one pool (IPv4 or IPv6)
for i, dnn := range cfg.DnnList {
	if dnn.Cidr == "" && dnn.IPv6 == nil {
		return nil, errors.Errorf("WNC: DnnList[%d] (dnn: %s) must have at least one pool configured (cidr for IPv4 or ipv6 for IPv6)", i, dnn.Dnn)
	}
}

// WNC: Validate Router Advertisement profiles referenced by interfaces exist
for i, gtpuIf := range cfg.Gtpu.IfList {
	if gtpuIf.RaProfile != "" {
		if cfg.RouterAdvertisements == nil || cfg.RouterAdvertisements[gtpuIf.RaProfile] == nil {
			return nil, errors.Errorf("WNC: Gtpu.IfList[%d] references RA profile '%s' which does not exist in routerAdvertisements", i, gtpuIf.RaProfile)
		}
	}
}

// WNC: Validate Router Advertisement profiles referenced by IPv6 pools exist
for i, dnn := range cfg.DnnList {
	if dnn.IPv6 != nil && dnn.IPv6.RaProfile != "" {
		if cfg.RouterAdvertisements == nil || cfg.RouterAdvertisements[dnn.IPv6.RaProfile] == nil {
			return nil, errors.Errorf("WNC: DnnList[%d] (dnn: %s) IPv6 pool references RA profile '%s' which does not exist in routerAdvertisements", i, dnn.Dnn, dnn.IPv6.RaProfile)
		}
	}
}
```

**Validation Checks:**
1. At least one pool (IPv4 or IPv6) per DNN
2. Interface RA profile references are valid
3. IPv6 pool RA profile references are valid
4. All errors prefixed with "WNC:" for easy identification

---

## 4. Configuration Examples

### 4.1 SMF Configuration

#### IPv4-Only (Legacy - Unchanged)
```yaml
userplaneInformation:
  upNodes:
    UPF:
      type: UPF
      sNssaiUpfInfos:
        - sNssai:
            sst: 1
            sd: "010203"
          dnnUpfInfoList:
            - dnn: internet
              pools:
                - cidr: 10.60.0.0/16
```

#### IPv6-Only (New)
```yaml
userplaneInformation:
  upNodes:
    UPF:
      type: UPF
      sNssaiUpfInfos:
        - sNssai:
            sst: 1
            sd: "010203"
          dnnUpfInfoList:
            - dnn: internet
              ipv6Pools:
                - prefix: 2001:db8::/32
                  uePrefixLength: 64
                  iidAllocation: random
                  raProfile: default-ra
              sessionTypePolicy:
                default: ipv6
                allowed: [ipv6]
```

#### Dual-Stack (New)
```yaml
userplaneInformation:
  upNodes:
    UPF:
      type: UPF
      sNssaiUpfInfos:
        - sNssai:
            sst: 1
            sd: "010203"
          dnnUpfInfoList:
            - dnn: internet
              pools:
                - cidr: 10.60.0.0/16
              ipv6Pools:
                - prefix: 2001:db8::/32
                  uePrefixLength: 64
                  iidAllocation: random
                  raProfile: default-ra
              sessionTypePolicy:
                default: ipv4v6
                allowed: [ipv4, ipv6, ipv4v6]
```

#### Static IPv6 Assignments (New)
```yaml
dnnUpfInfoList:
  - dnn: internet
    ipv6Pools:
      - prefix: 2001:db8::/32
        uePrefixLength: 64
        iidAllocation: manual
    ipv6StaticAssignments:
      - supi: imsi-208930000000001
        address: 2001:db8::1
        prefixLength: 64
        comment: "VIP user static IP"
      - supi: imsi-208930000000002
        address: 2001:db8::2
        prefixLength: 64
        comment: "IoT device"
```

#### IPv6 with Endpoints (New)
```yaml
interfaces:
  - interfaceType: N3
    endpoints:
      - 127.0.0.8              # IPv4
      - 2001:db8::8            # IPv6
      - upf.example.com        # FQDN
    networkInstances: [internet]
```

### 4.2 UPF Configuration

#### IPv4-Only (Legacy - Unchanged)
```yaml
dnnList:
  - dnn: internet
    cidr: 10.60.0.0/16
    natifname: eth0
```

#### IPv6-Only (New)
```yaml
routerAdvertisements:
  default-ra:
    enable: true
    routerAddress: 2001:db8::1
    prefixLength: 64
    linkMtu: 1500
    lifetime: 1800
    dns:
      - 2001:4860:4860::8888
      - 2001:4860:4860::8844

dnnList:
  - dnn: internet
    ipv6:
      prefix: 2001:db8::/32
      uePrefixLength: 64
      allocation: delegated
      raProfile: default-ra
```

#### Dual-Stack (New)
```yaml
routerAdvertisements:
  default-ra:
    enable: true
    routerAddress: 2001:db8::1
    prefixLength: 64
    linkMtu: 1500
    lifetime: 1800
    dns:
      - 2001:4860:4860::8888

dnnList:
  - dnn: internet
    cidr: 10.60.0.0/16          # IPv4
    ipv6:                        # IPv6
      prefix: 2001:db8::/32
      uePrefixLength: 64
      allocation: delegated
      raProfile: default-ra
    natifname: eth0
```

#### Interface with IPv6 (New)
```yaml
gtpu:
  forwarder: gtp5g
  ifList:
    - addr: 127.0.0.8
      addr6: 2001:db8::8         # IPv6 address
      linkLocal: fe80::1         # Link-local
      raProfile: default-ra      # RA profile
      type: N3
      name: upf-n3
      ifname: eth0
      mtu: 1500
```

---

## 5. Design Decisions

### 5.1 Why `Cidr` Instead of `IPv4` in UPF DnnList?

**Decision:** Keep existing `Cidr` field for IPv4 instead of renaming to `ipv4`.

**Rationale:**
- **Backward Compatibility**: All existing UPF configs use `cidr` for IPv4 pools
- **Zero Breaking Changes**: Existing deployments continue working without modification
- **Clear Migration Path**: New configs can use `ipv6` field alongside `cidr`
- **Semantic Clarity**: `cidr` historically meant IPv4-only; `ipv6` is explicitly new

**Trade-off Considered:**
- **Option A (Chosen)**: Keep `cidr` (IPv4), add `ipv6` (IPv6)
  - ✅ No breaking changes
  - ✅ Existing configs work immediately
  - ⚠️ Slightly less symmetric naming

- **Option B (Rejected)**: Rename to `ipv4`, add `ipv6`
  - ❌ Breaks all existing configs
  - ❌ Requires migration tool
  - ✅ Perfectly symmetric naming

**Validation Added:** Ensures at least one pool (either `cidr` or `ipv6`) is configured.

### 5.2 Why Pointer for IPv6Pool in DnnList?

```go
IPv6      *IPv6Pool   `yaml:"ipv6"      valid:"optional"`
```

**Rationale:**
- Allows `nil` to represent "IPv6 not configured"
- Cleaner YAML when omitted (no empty struct)
- Consistent with Go patterns for optional complex types
- Easy null-check: `if dnn.IPv6 != nil`

### 5.3 WNC Prefix for Error Messages

All new validation errors use `"WNC:"` prefix for easy identification in logs.

**Example:**
```
WNC: DnnList[0] (dnn: internet) must have at least one pool configured (cidr for IPv4 or ipv6 for IPv6)
WNC: Invalid endpoint:2001:db8::8:invalid, should be IPv4, IPv6, or FQDN.
```

**Benefits:**
- Quickly identify custom code vs. upstream code
- Filter logs for WNC-specific issues
- Easier debugging during development

---

## 6. Build Verification

### SMF Build
```bash
$ cd free5gc && make smf
Start building smf....
cd NFs/smf/cmd && \
CGO_ENABLED=0 go build -gcflags "" -ldflags "-X github.com/free5gc/util/version.VERSION=v4.0.1..." \
-o /home/loren/.../free5gc/bin/smf main.go
```
**Status:** ✅ Success

### UPF Build
```bash
$ cd free5gc && make upf
Start building upf....
cd NFs/upf/cmd && \
CGO_ENABLED=0 go build -gcflags "" -ldflags "-X github.com/free5gc/util/version.VERSION=v4.0.1..." \
-o /home/loren/.../free5gc/bin/upf main.go
```
**Status:** ✅ Success

### Full Build Test
```bash
$ cd free5gc && make clean && make all
```
**Expected:** ✅ All network functions compile successfully

---

## 7. Implementation Status

| Section | Component | Status | Lines Modified |
|---------|-----------|--------|----------------|
| 1 | SMF Schema Updates | ✅ Complete | config.go:578-788 |
| 2 | SMF Factory Struct Changes | ✅ Complete | config.go:7-19 |
| 3 | UPF Schema Updates | ✅ Complete | config.go:18-79 |
| 4 | UPF Factory Struct Changes | ✅ Complete | factory.go:49-72 |
| 5 | SMF Validation Logic | ✅ Complete | config.go:590-785 |
| 6 | UPF Validation Logic | ✅ Complete | factory.go:49-72 |

### Files Modified
1. `free5gc/NFs/smf/pkg/factory/config.go` (211 lines added)
2. `free5gc/NFs/upf/pkg/factory/config.go` (38 lines added)
3. `free5gc/NFs/upf/pkg/factory/factory.go` (24 lines added)

### Total Lines Added
- **SMF:** ~211 lines
- **UPF:** ~62 lines
- **Total:** ~273 lines of production code

---

## 8. Next Steps

### 8.1 Immediate Actions (Phase 0 Continuation)
1. ✅ **Task 3:** Update SMF user plane information context loader
   - Location: `free5gc/NFs/smf/internal/context/user_plane_information.go`
   - Action: Extend pool construction logic to branch on IPv4 vs IPv6 fields
   - Note: Actual allocation deferred to Phase 1

2. 📝 **Schema Approval**
   - Share updated schema with SMF/UPF owners
   - Confirm pool semantics and RA handling
   - Validate IID allocation modes (random/eui64/manual)
   - Confirm UE IPv6 delegation default of /64

3. 📝 **Migration Documentation**
   - Draft migration guide for IPv4-only configs
   - Provide YAML examples for each scenario
   - Document validation error messages
   - Create troubleshooting section

### 8.2 Phase 1 Preparation
1. **IPv6 Address Allocation**
   - Implement prefix delegation logic
   - IID generation (random/EUI-64)
   - Static assignment lookup
   - Address conflict detection

2. **Router Advertisement Generation**
   - Implement RA packet construction
   - Profile-based RA customization
   - RDNSS option support
   - Prefix information option

3. **PDU Session Establishment**
   - Session type negotiation
   - IPv6 CP (Configuration Protocol)
   - DNS configuration delivery
   - MTU discovery

### 8.3 Testing Requirements
1. **Unit Tests**
   - IPv6 pool validation
   - Session type policy validation
   - RA profile reference validation
   - Static assignment uniqueness

2. **Integration Tests**
   - IPv4-only session establishment
   - IPv6-only session establishment
   - Dual-stack session establishment
   - Session type rejection scenarios

3. **Configuration Tests**
   - Legacy config compatibility
   - New IPv6-only configs
   - Dual-stack configs
   - Invalid config detection

---

## 9. Assumptions & Constraints

### 9.1 Confirmed Assumptions
1. Default UE IPv6 delegation is /64 (unless `uePrefixLength` overrides)
2. RA generation responsibility sits in UPF
3. IID allocation modes limited to: `random`, `eui64`, `manual`
4. Session types supported: `ipv4`, `ipv6`, `ipv4v6`

### 9.2 Constraints
1. Backward compatibility mandatory for existing IPv4 deployments
2. Configuration changes must validate at load time
3. Validation errors must clearly indicate WNC custom code
4. No runtime behavior changes in Phase 0 (schema-only)

### 9.3 Open Questions
1. **UE Prefix Length:** Confirm stakeholder preference for default /64
2. **RA Ownership:** Revisit if RA responsibility shifts from UPF
3. **Additional IID Modes:** Future support for sequential, cryptographic?
4. **IPv6 Fragmentation:** How to handle large policy payloads?

---

## 10. References

### 10.1 Source Documents
- `codex_free5gc_ipv6_implementation_plan_251014_v2_phase_0_ipv6_config_schema_decision.md`
- Free5GC Architecture Documentation
- 3GPP TS 23.502 (Session Management)
- RFC 8415 (DHCPv6)
- RFC 4861 (IPv6 Neighbor Discovery)

### 10.2 Related Code
- SMF Pool Management: `free5gc/NFs/smf/internal/context/user_plane_information.go`
- UPF Pool Management: `free5gc/NFs/upf/internal/pfcp/handler.go`
- PFCP Session Establishment: `free5gc/NFs/smf/internal/pfcp/udp/udp.go`

### 10.3 Validation Libraries
- `github.com/asaskevich/govalidator` - Struct validation
- `gopkg.in/yaml.v2` - YAML parsing
- Go standard library - `net`, `strings`, `strconv`

---
