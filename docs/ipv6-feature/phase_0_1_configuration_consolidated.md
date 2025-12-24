# Free5GC IPv6 Configuration - Phase 0 & 1 Consolidated

**Implementation Period:** October 14-17, 2025
**Status:** ✅ COMPLETE
**Scope:** Configuration schema design and YAML configuration updates

---

## Table of Contents

1. [Overview](#overview)
2. [Phase 0: Configuration Schema Design](#phase-0-configuration-schema-design)
3. [Phase 1: Configuration File Updates](#phase-1-configuration-file-updates)
4. [Troubleshooting Notes](#troubleshooting-notes)
5. [Cross-References](#cross-references)

---

## Overview

Phases 0 and 1 established the complete configuration foundation for IPv6 support in Free5GC. These preparatory phases focused on:

- **Phase 0 (Oct 14-15)**: Go configuration structures, validation logic, and context loaders
- **Phase 1 (Oct 17)**: YAML configuration files and test fixtures

Both phases are configuration-focused and are consolidated here since they work together to enable IPv6 addressing.

### What Was Accomplished

**Phase 0 Deliverables:**
- IPv6 pool structures in SMF and UPF factory configs
- Comprehensive validation logic with WNC-prefixed errors
- Context loaders for runtime pool management
- Router Advertisement profile structures
- PDU session type schema unification

**Phase 1 Deliverables:**
- Extended SMF and UPF YAML configurations with IPv6 pools
- Router Advertisement profile configuration
- Updated test fixtures to match new validation rules
- Dual-stack configuration examples

---

## Phase 0: Configuration Schema Design

### 1. SMF Configuration Structures

#### 1.1 New IPv6 Pool Structure

**File:** `NFs/smf/pkg/factory/config.go:753-759`

```go
type UEIPv6Pool struct {
    Prefix          string   `yaml:"prefix" valid:"ipv6cidr,required"`
    UePrefixLength  int      `yaml:"uePrefixLength" valid:"range(1|128),required"`
    IidAllocation   string   `yaml:"iidAllocation" valid:"in(random|eui64|manual),optional"`
    Exclude         []string `yaml:"exclude,omitempty" valid:"optional"`
    RaProfile       string   `yaml:"raProfile,omitempty" valid:"optional"`
}
```

**Fields:**
- `Prefix`: IPv6 CIDR for the pool (e.g., `2001:db8::/32`)
- `UePrefixLength`: Prefix length delegated to each UE (typically 64)
- `IidAllocation`: Interface identifier allocation method
  - `random`: Cryptographically random IID
  - `eui64`: EUI-64 based on MAC address
  - `manual`: Manual assignment via static config
- `Exclude`: List of IPv6 addresses/CIDRs to exclude from allocation
- `RaProfile`: Reference to Router Advertisement profile

#### 1.2 Static IPv6 Assignment Structure

**File:** `NFs/smf/pkg/factory/config.go:793-798`

```go
type StaticUEIPv6Assignment struct {
    Supi         string `yaml:"supi" valid:"required"`
    Address      string `yaml:"address" valid:"ipv6,required"`
    PrefixLength int    `yaml:"prefixLength" valid:"range(1|128),required"`
    Comment      string `yaml:"comment,omitempty" valid:"optional"`
}
```

**Validation:**
- SUPI format: `imsi-[0-9]{5,15}`
- IPv6 address validation
- Containment validation: All static assignments must fall within configured pools

#### 1.3 Extended DnnUpfInfoItem

**File:** `NFs/smf/pkg/factory/config.go:581-590`

```go
type DnnUpfInfoItem struct {
    Dnn                   string                    `json:"dnn" yaml:"dnn" valid:"required"`
    DnaiList              []string                  `json:"dnaiList" yaml:"dnaiList" valid:"optional"`
    PduSessionTypes       *models.PduSessionTypes   `json:"pduSessionTypes" yaml:"pduSessionTypes" valid:"optional"`
    Pools                 []*UEIPPool               `json:"pools" yaml:"pools" valid:"optional"`
    StaticPools           []*UEIPPool               `json:"staticPools" yaml:"staticPools" valid:"optional"`
    UeIPv6Pools           []*UEIPv6Pool             `json:"ipv6Pools" yaml:"ipv6Pools" valid:"optional"`
    StaticIPv6Pools       []*UEIPv6Pool             `json:"ipv6StaticPools" yaml:"ipv6StaticPools" valid:"optional"`
    IPv6StaticAssignments []*StaticUEIPv6Assignment `json:"ipv6StaticAssignments" yaml:"ipv6StaticAssignments" valid:"optional"`
}
```

### 2. UPF Configuration Structures

#### 2.1 IPv6 Pool Structure

**File:** `NFs/upf/pkg/factory/config.go:59-66`

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

#### 2.2 Router Advertisement Profile

**File:** `NFs/upf/pkg/factory/config.go:69-79`

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

**RA Flags:**
- `0xC0`: Managed address configuration (M) + Other configuration (O)
- `0x80`: Managed address configuration only
- `0x40`: Other configuration only

#### 2.3 Extended DnnList

**File:** `NFs/upf/pkg/factory/config.go:51-56`

```go
type DnnList struct {
    Dnn       string      `yaml:"dnn"       valid:"required"`
    Cidr      string      `yaml:"cidr"      valid:"optional,cidr"`  // IPv4 pool
    NatIfName string      `yaml:"natifname" valid:"optional"`
    IPv6      *IPv6Pool   `yaml:"ipv6"      valid:"optional"`       // IPv6 pool
}
```

**Design Decision:** Kept `Cidr` field name for backward compatibility instead of renaming to `ipv4`.

### 3. Validation Logic

#### 3.1 Pool Requirement Validation

**File:** `NFs/smf/pkg/factory/config.go:651-653`

```go
// At least one pool (IPv4 or IPv6) must be configured
if len(d.Pools) == 0 && len(d.StaticPools) == 0 &&
   len(d.UeIPv6Pools) == 0 && len(d.StaticIPv6Pools) == 0 {
    return false, errors.New("DnnUpfInfoItem must have at least one pool configured (IPv4 or IPv6)")
}
```

#### 3.2 Static Assignment Containment Validation

**File:** `NFs/smf/pkg/factory/config.go:653-688`

Ensures all IPv6 static assignments fall within configured IPv6 pools:

```go
func (d *DnnUpfInfoItem) validateIPv6StaticAssignmentContainment() error {
    if len(d.IPv6StaticAssignments) == 0 {
        return nil
    }

    // Collect all pool prefixes (union of UeIPv6Pools and StaticIPv6Pools)
    var allPools []*UEIPv6Pool
    allPools = append(allPools, d.UeIPv6Pools...)
    allPools = append(allPools, d.StaticIPv6Pools...)

    if len(allPools) == 0 {
        return errors.New("WNC: DnnUpfInfoItem has IPv6 static assignments but no IPv6 pools configured")
    }

    // Validate each static assignment falls within at least one pool
    for _, assignment := range d.IPv6StaticAssignments {
        contained := false
        for _, pool := range allPools {
            if isIPv6AddressInPool(assignment.Address, pool.Prefix) {
                contained = true
                break
            }
        }
        if !contained {
            return fmt.Errorf("WNC: IPv6 static assignment for SUPI '%s' with address '%s' does not fall within any configured IPv6 pool",
                assignment.Supi, assignment.Address)
        }
    }
    return nil
}
```

#### 3.3 PDU Session Types Validation

**File:** `NFs/smf/pkg/factory/config.go:817-866`

```go
func validatePduSessionTypes(pst *models.PduSessionTypes, dnn string) (bool, error) {
    // Validate default session type is valid
    if !isValidPduSessionType(pst.DefaultSessionType) {
        return false, fmt.Errorf("WNC: DNN '%s': Invalid defaultSessionType '%s'", dnn, pst.DefaultSessionType)
    }

    // Validate allowed session types list is not empty
    if len(pst.AllowedSessionTypes) == 0 {
        return false, fmt.Errorf("WNC: DNN '%s': allowedSessionTypes list cannot be empty", dnn)
    }

    // Validate default is in allowed list
    defaultFound := false
    for _, sessionType := range pst.AllowedSessionTypes {
        if sessionType == pst.DefaultSessionType {
            defaultFound = true
            break
        }
    }
    if !defaultFound {
        return false, fmt.Errorf("WNC: DNN '%s': defaultSessionType must be in allowedSessionTypes list", dnn)
    }

    return true, nil
}
```

**Supported Session Types:**
- `IPV4` (0x01)
- `IPV6` (0x02)
- `IPV4V6` (0x03)
- `ETHERNET` (0x03)
- `UNSTRUCTURED` (0x05)

### 4. Context Loader Implementation

#### 4.1 SMF Context Structures

**File:** `NFs/smf/internal/context/snssai.go:31-41`

```go
type DnnUPFInfoItem struct {
    Dnn                   string
    DnaiList              []string
    PduSessionTypes       *models.PduSessionTypes
    UeIPPools             []*UeIPPool                   // IPv4 dynamic pools
    StaticIPPools         []*UeIPPool                   // IPv4 static pools
    UeIPv6Pools           []*UeIPPool                   // IPv6 dynamic pools
    StaticIPv6Pools       []*UeIPPool                   // IPv6 static pools
    IPv6StaticAssignments []*factory.StaticUEIPv6Assignment
}
```

**Design Decision:** Unified pool allocator (`UeIPPool`) handles both IPv4 and IPv6 using Go's `net.IPNet`.

#### 4.2 IPv6 Pool Creation

**File:** `NFs/smf/internal/context/ue_ip_pool.go:51-83`

```go
func NewUEIPv6Pool(factoryPool *factory.UEIPv6Pool) (*UeIPPool, error) {
    logger.CtxLog.Infof("WNC: Creating IPv6 pool from prefix %s with UE prefix length %d",
        factoryPool.Prefix, factoryPool.UePrefixLength)

    // Calculate the IPv6 address range for this pool
    start, end, err := calcIPv6AddrRange(factoryPool.Prefix, factoryPool.UePrefixLength)
    if err != nil {
        return nil, err
    }

    ueIPv6Pool := &UeIPPool{
        ueSubNet:        start,
        pool:            newLazyReuseIPPool(start, end),
        isIPv6:          true,
        factoryIPv6Pool: factoryPool, // Preserve original config for export
    }

    logger.CtxLog.Infof("WNC: IPv6 pool created with range %s - %s", start, end)
    return ueIPv6Pool, nil
}
```

#### 4.3 UPF Route Configuration

**File:** `NFs/upf/internal/forwarder/driver.go:68-100`

```go
link := driver.Link()
for _, dnn := range cfg.DnnList {
    // Process IPv4 pool (if configured)
    if dnn.Cidr != "" {
        _, dst, err := net.ParseCIDR(dnn.Cidr)
        if err != nil {
            logger.MainLog.Errorf("WNC: Failed to parse IPv4 CIDR for DNN %s: %v", dnn.Dnn, err)
            continue
        }
        err = link.RouteAdd(dst)
        if err != nil {
            driver.Close()
            return nil, errors.Wrapf(err, "WNC: Failed to add IPv4 route for DNN %s", dnn.Dnn)
        }
        logger.MainLog.Infof("WNC: Added IPv4 route for DNN %s: %s", dnn.Dnn, dnn.Cidr)
    }

    // Process IPv6 pool (if configured)
    if dnn.IPv6 != nil && dnn.IPv6.Prefix != "" {
        _, dst6, err := net.ParseCIDR(dnn.IPv6.Prefix)
        if err != nil {
            logger.MainLog.Errorf("WNC: Failed to parse IPv6 prefix for DNN %s: %v", dnn.Dnn, err)
            continue
        }
        err = link.RouteAdd(dst6)
        if err != nil {
            driver.Close()
            return nil, errors.Wrapf(err, "WNC: Failed to add IPv6 route for DNN %s", dnn.Dnn)
        }
        logger.MainLog.Infof("WNC: Added IPv6 route for DNN %s: %s (UE prefix length: /%d)",
            dnn.Dnn, dnn.IPv6.Prefix, dnn.IPv6.UePrefixLength)
    }
}
```

---

## Phase 1: Configuration File Updates

### 1. SMF Configuration Extension

**File:** `config/smfcfg.yaml`

Extended the first `fast.t-mobile.com` DNN with IPv6 support:

```yaml
- dnn: fast.t-mobile.com
  pduSessionTypes:
    defaultSessionType: IPV4V6
    allowedSessionTypes:
      - IPV4
      - IPV6
      - IPV4V6
  pools:
    - cidr: 10.111.0.0/16
  staticPools:
    - cidr: 10.111.100.0/24
  ipv6Pools:
    - prefix: 2001:db8:0111::/48
      uePrefixLength: 64
      iidAllocation: random
      raProfile: default
  ipv6StaticPools:
    - prefix: 2001:db8:0111:100::/56
      uePrefixLength: 64
      iidAllocation: manual
```

### 2. UPF Configuration Extension

**File:** `config/upfcfg.yaml`

Added matching IPv6 configuration:

```yaml
routerAdvertisements:
  default:
    enable: true
    routerAddress: fe80::1
    prefixLength: 64
    linkMtu: 1500
    flags: 0xC0  # Managed address configuration (M) and Other configuration (O)
    lifetime: 1800
    reachableTimer: 0
    retransTimer: 0
    dns:
      - 2001:4860:4860::8888
      - 2001:4860:4860::8844

dnnList:
  - dnn: fast.t-mobile.com
    cidr: 10.111.0.0/16
    ipv6:
      prefix: 2001:db8:0111::/48
      uePrefixLength: 64
      allocation: random
      raProfile: default
```

### 3. IPv6 Prefix Allocation Strategy

Used documentation prefix `2001:db8::/32` with unique third hextet per DNN:

| DNN | IPv6 Prefix | IPv4 CIDR | Status |
|-----|-------------|-----------|--------|
| fast.t-mobile.com | 2001:db8:0111::/48 | 10.111.0.0/16 | ✅ Implemented |
| internet | 2001:db8:0112::/48 | 10.112.0.0/16 | Pending |
| ims | 2001:db8:0113::/48 | 10.113.0.0/16 | Pending |
| sos | 2001:db8:0114::/48 | 10.114.0.0/16 | Pending |

**Pattern:** Third hextet mirrors last octet of IPv4 allocation (e.g., 10.111.x.x → 2001:db8:0111::/48)

### 4. Test Fixture Updates

**File:** `NFs/smf/pkg/factory/config_test.go`

Fixed test fixtures to comply with new validation rules:

```go
// Test case 1: IPv4-only configuration
{
    Name: "Default",
    Snssai: &models.Snssai{
        Sst: int32(1),
        Sd:  "010203",
    },
    DnnInfos: []*factory.DnnUpfInfoItem{
        {
            Dnn: "internet",
            PduSessionTypes: &models.PduSessionTypes{
                DefaultSessionType:  models.PduSessionType_IPV4,
                AllowedSessionTypes: []models.PduSessionType{models.PduSessionType_IPV4},
            },
            Pools: []*factory.UEIPPool{
                {Cidr: "10.60.0.0/16"},
            },
        },
    },
},

// Test case 2: Dual-stack configuration
{
    Name: "Empty SD",
    Snssai: &models.Snssai{
        Sst: int32(1),
    },
    DnnInfos: []*factory.DnnUpfInfoItem{
        {
            Dnn: "internet2",
            PduSessionTypes: &models.PduSessionTypes{
                DefaultSessionType:  models.PduSessionType_IPV4_V6,
                AllowedSessionTypes: []models.PduSessionType{
                    models.PduSessionType_IPV4,
                    models.PduSessionType_IPV6,
                    models.PduSessionType_IPV4_V6,
                },
            },
            Pools: []*factory.UEIPPool{
                {Cidr: "10.61.0.0/16"},
            },
            UeIPv6Pools: []*factory.UEIPv6Pool{
                {
                    Prefix:         "2001:db8:61::/48",
                    UePrefixLength: 64,
                    IidAllocation:  "random",
                },
            },
        },
    },
},
```

---

## Troubleshooting Notes

### Common Validation Errors

#### Error: "must have at least one pool configured"
```
WNC: DnnList[0] (dnn: internet) must have at least one pool configured (cidr for IPv4 or ipv6 for IPv6)
```
**Cause:** Neither `cidr` nor `ipv6` field is set in DNN configuration.
**Solution:** Add either IPv4 pool (`cidr: 10.60.0.0/16`) or IPv6 pool configuration.

#### Error: "references RA profile which does not exist"
```
WNC: DnnList[0] (dnn: internet) IPv6 pool references RA profile 'default-ra' which does not exist in routerAdvertisements
```
**Cause:** IPv6 pool references an RA profile that isn't defined.
**Solution:** Add the RA profile to `routerAdvertisements` map or remove the reference.

#### Error: "Invalid uePrefixLength"
```
Invalid uePrefixLength: 0, should be in range 1~128
```
**Cause:** UE prefix length is outside valid range.
**Solution:** Set `uePrefixLength` between 1 and 128 (typically 64 for IPv6).

#### Error: "Default session type must be in allowed list"
```
Default session type 'ipv6' must be in allowedSessionTypes list
```
**Cause:** SessionTypePolicy default is not present in allowed list.
**Solution:** Add default to allowed list or change default to match allowed types.

#### Error: "IPv6 static assignment does not fall within any configured IPv6 pool"
```
WNC: IPv6 static assignment for SUPI 'imsi-208930000000003' with address '2001:db8:dead::1' does not fall within any configured IPv6 pool for DNN 'ims'
```
**Cause:** Static assignment address is outside all configured pool prefixes.
**Solution:** Ensure static assignment addresses fall within at least one configured IPv6 pool.

### Build Issues

#### Import Error: "undefined: strings"
**Cause:** Missing import in older file version.
**Solution:** Verify `import "strings"` is present in SMF config.go.

#### Struct Field Error: "unknown field UeIPv6Pools"
**Cause:** Old version of DnnUpfInfoItem struct.
**Solution:** Rebuild SMF after pulling latest changes.

### Test Failures

#### Unit Test Failure: Empty Pool Configuration
**Problem:** Test fixtures had empty pool configurations, violating validation rule.
**Solution:** Updated test fixtures to include proper pool configurations (see Phase 1, Section 4).

---

## Cross-References

### Related Implementation Phases

**Phase 2 (Static IPv6 Assignment):**
- Uses `IPv6StaticAssignments` structure defined in Phase 0
- Implements allocation logic for static IPv6 addresses
- File: `docs/ipv6-feature/phase_2_static_ipv6_implementation.md`

**Phase 3 (Router Advertisement):**
- Uses `RouterAdvertisementProfile` structure defined in Phase 0
- Implements RA packet generation and transmission
- File: `docs/ipv6-feature/phase_3_router_advertisement_implementation.md`

### Configuration Consistency Requirements

**Critical:** SMF and UPF configurations must match for each DNN:

| Field | SMF Location | UPF Location | Must Match |
|-------|--------------|--------------|------------|
| IPv6 Prefix | `ipv6Pools[].prefix` | `ipv6.prefix` | ✅ Yes |
| UE Prefix Length | `ipv6Pools[].uePrefixLength` | `ipv6.uePrefixLength` | ✅ Yes |
| RA Profile Name | `ipv6Pools[].raProfile` | `ipv6.raProfile` | ✅ Yes |

**Mismatch Consequences:**
- Address allocation failures
- Session establishment errors
- UE connectivity issues

### Files Modified Summary

**Phase 0 (Code):**
1. `NFs/smf/pkg/factory/config.go` - Factory schema + validation (211 lines)
2. `NFs/upf/pkg/factory/config.go` - Factory schema (38 lines)
3. `NFs/upf/pkg/factory/factory.go` - Validation logic (24 lines)
4. `NFs/smf/internal/context/snssai.go` - Runtime context structs
5. `NFs/smf/internal/context/ue_ip_pool.go` - IPv6 pool allocators
6. `NFs/smf/internal/context/user_plane_information.go` - Context loaders
7. `NFs/upf/internal/forwarder/driver.go` - Route setup

**Phase 1 (Configuration):**
1. `config/smfcfg.yaml` - IPv6 pools and PDU session types
2. `config/upfcfg.yaml` - IPv6 pools and RA profile
3. `NFs/smf/pkg/factory/config_test.go` - Test fixtures

### Build Verification

```bash
# Unit tests
cd NFs/smf && go test ./pkg/factory -v
cd NFs/amf && go test ./pkg/factory -v
cd NFs/upf && go test ./pkg/factory

# Build validation
make clean
make nfs

# Verify binaries
ls -lh bin/
# Expected: amf, ausf, chf, n3iwf, nef, nrf, nssf, pcf, smf, tngf, udm, udr, upf
```

**All tests pass ✅**
**All NFs build successfully ✅**

---

## Conclusion

Phases 0 and 1 successfully established the complete configuration foundation for IPv6 support in Free5GC:

**Phase 0 Achievements:**
- ✅ IPv6 pool structures in SMF and UPF
- ✅ Comprehensive validation with WNC-prefixed errors
- ✅ Context loaders for runtime pool management
- ✅ Router Advertisement profile framework
- ✅ PDU session type schema unification
- ✅ ~273 lines of production code

**Phase 1 Achievements:**
- ✅ Extended SMF/UPF YAML configurations
- ✅ Router Advertisement profile configuration
- ✅ Updated test fixtures
- ✅ Dual-stack configuration examples
- ✅ IPv6 prefix allocation strategy

**Ready for Phase 2:**
The configuration framework is complete and validated. Phase 2 can now implement:
- IPv6 address allocation logic
- Static IPv6 assignment lookup
- PDU session establishment with IPv6
- Router Advertisement packet generation

---

**Document Version:** 1.0
**Last Updated:** December 24, 2025
**Implementation Period:** October 14-17, 2025
**Status:** ✅ COMPLETE
