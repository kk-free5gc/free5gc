# Free5GC IPv6 Implementation - Phase 2 Implementation Notes Part 4

## Date: October 22, 2025

This document contains implementation notes for bug fixes and enhancements to the Free5GC IPv6 dual-stack implementation.

---

## Bug Fix 1: PFCP IPv6 Delegation Flag Issue

### Date: October 22, 2025
### Files Modified: `NFs/smf/internal/context/datapath.go`

### Problem Identified

The PFCP builder was advertising an IPv6 delegation (`Ipv6d=true`) even when no prefix length was learned, because `datapath.go:543-569` unconditionally set `UEIPAddress.Ipv6d = true` whenever an IPv6 address existed—even when `smContext.PDUAddressIPv6PrefixLen` was still zero.

**Impact**: When the SMF couldn't resolve the UE's delegated prefix (common with older configs that omit `uePrefixLength` or static binds without a `prefixLength`), the UPF received `Ipv6d=1` together with `Ipv6PrefixDelegationBits=0`. This combination is invalid per 3GPP TS 29.244, causing some UPFs to reject PFCP session establishment outright.

### Root Cause

Three locations in `datapath.go` unconditionally set the IPv6 delegation flag:
- Line 557 (ULPDR - Uplink PDR)
- Line 656 (DLPDR anchor - Downlink PDR)
- Line 709 (DLPDR N9 - Downlink PDR)

```go
// WRONG - unconditional delegation flag
if hasIPv6 {
    ULPDR.PDI.UEIPAddress.Ipv6Address = ipv6
    ULPDR.PDI.UEIPAddress.Ipv6d = true // Always set!
    ULPDR.PDI.UEIPAddress.Ipv6PrefixDelegationBits = smContext.PDUAddressIPv6PrefixLen
}
```

### Solution Implemented

Wrapped the IPv6 branch so `Ipv6d` is set (and `Ipv6PrefixDelegationBits` is populated) **only if** `smContext.PDUAddressIPv6PrefixLen > 0`:

```go
// CORRECT - conditional delegation flag
if hasIPv6 {
    ULPDR.PDI.UEIPAddress.Ipv6Address = ipv6
    // Only signal IPv6 prefix delegation when we actually have a prefix length
    if smContext.PDUAddressIPv6PrefixLen > 0 {
        ULPDR.PDI.UEIPAddress.Ipv6d = true // IPv6 Prefix Delegation flag
        ULPDR.PDI.UEIPAddress.Ipv6PrefixDelegationBits = smContext.PDUAddressIPv6PrefixLen
    }
}
```

### Changes Made

**File: `NFs/smf/internal/context/datapath.go`**

1. **Line 557-561 (ULPDR - Uplink PDR)**:
   - Added conditional check for prefix length > 0
   - Only set `Ipv6d` flag when valid prefix exists

2. **Line 660-663 (DLPDR anchor - Downlink PDR)**:
   - Added conditional check for prefix length > 0
   - Only set `Ipv6d` flag when valid prefix exists

3. **Line 716-719 (DLPDR N9 - Downlink PDR)**:
   - Added conditional check for prefix length > 0
   - Only set `Ipv6d` flag when valid prefix exists

### 3GPP Compliance

This fix ensures compliance with **3GPP TS 29.244** which requires:
- `Ipv6d=0` when no prefix delegation is configured
- `Ipv6d=1` only when `Ipv6PrefixDelegationBits` contains a valid non-zero value

### Build Verification

```bash
make smf
# Build successful
```

### Testing Recommendations

1. **Static IPv6 without prefix length**: Verify session establishment succeeds
2. **Static IPv6 with prefix length**: Verify delegation flag is properly set
3. **Dynamic IPv6**: Verify behavior matches configuration
4. **Dual-stack scenarios**: Verify IPv4 is unaffected

---

## Bug Fix 2: ULCL IPv6 Static Address Allocation Issue

### Date: October 22, 2025
### Files Modified:
- `NFs/smf/internal/context/user_plane_information.go`
- `NFs/smf/internal/context/ue_defaultPath.go`

### Problem Identified

The ULCL pool selection code in `internal/context/user_plane_information.go:1434` keyed exclusively off `selection.PDUAddress`. When a subscriber had only a static IPv6 binding (`selection.PDUAddress` stayed nil while `selection.PDUAddressIPv6` was populated), the ULCL code never detected the configured address and fell through to the dynamic-path branch.

**Impact**: As a result, static IPv6 couldn't be used and the session got a random IID instead of the operator-defined one. This applied to any caller using the legacy ULCL path (`SelectUPFAndAllocUEIPForULCL`), so every ULCL deployment lost the static IPv6 feature.

### Root Cause Analysis

**Flow:**

1. **Only `selection.PDUAddress` was examined**: In `getUEIPPool()` (`user_plane_information.go:1429-1471`), the code only checked:
   ```go
   if selection.PDUAddress != nil {
       // look for that address in the configured pools
   }
   ```
   There was no parallel check for `selection.PDUAddressIPv6`.

2. **How static IPv6 is passed**: When you configure a static IPv6 binding, `SMContext.AllocUeIP()` copies it into `SelectionParam.PDUAddressIPv6` (and leaves `SelectionParam.PDUAddress` nil, because that field is reserved for IPv4).

3. **What happened at runtime**: Because `selection.PDUAddress` was nil, the code never entered the "static IP" branch. It dropped into the fallback that just appended every dynamic pool, effectively calling `pool.Allocate(nil)`, so the pool handed back the next free IID instead of the configured static one.

4. **pool.Allocate() call issue**: Even after detecting pools, `SelectUPFAndAllocUEIPForULCL` called `pool.Allocate(selection.PDUAddress)` without checking `selection.PDUAddressIPv6`.

### Solution Implemented

#### Part 1: Fix getUEIPPool() to Check Both Fields

Updated `getUEIPPool()` to check both `selection.PDUAddress` and `selection.PDUAddressIPv6`:

```go
// WNC: Check both PDUAddress (IPv4) and PDUAddressIPv6 (IPv6 static bindings)
// This ensures ULCL path honors static IPv6 assignments
staticIPv4 := selection.PDUAddress
staticIPv6 := selection.PDUAddressIPv6

// Legacy compatibility: if PDUAddress is IPv6, use it as staticIPv6
if staticIPv4 != nil && staticIPv4.To4() == nil {
    staticIPv6 = staticIPv4
    staticIPv4 = nil
}

if staticIPv4 != nil || staticIPv6 != nil {
    // Static IP allocation case
    if needIPv4 && staticIPv4 != nil {
        // Check IPv4 static pools...
    }
    if needIPv6 && staticIPv6 != nil {
        // Check IPv6 static pools...
    }
}
```

#### Part 2: Fix pool.Allocate() Call in SelectUPFAndAllocUEIPForULCL

Updated the allocation call to pass the correct static address:

```go
// WNC: Pass the correct static address (IPv4 or IPv6) to pool allocator
var requestedAddr net.IP
if selection.PDUAddress != nil && selection.PDUAddress.To4() != nil {
    requestedAddr = selection.PDUAddress // IPv4 static address
} else if selection.PDUAddressIPv6 != nil {
    requestedAddr = selection.PDUAddressIPv6 // IPv6 static address
} else if selection.PDUAddress != nil {
    requestedAddr = selection.PDUAddress // Legacy: PDUAddress as IPv6
}
addr := pool.Allocate(requestedAddr)
```

### Changes Made

**File: `NFs/smf/internal/context/user_plane_information.go`**

**Lines 1434-1484 (getUEIPPool function)**:
- Added logic to separate IPv4 and IPv6 static addresses
- Check both `PDUAddress` and `PDUAddressIPv6` fields
- Legacy compatibility for old code using `PDUAddress` for IPv6
- Added WNC-prefixed logging for ULCL static IP operations

**File: `NFs/smf/internal/context/ue_defaultPath.go`**

**Lines 203-216 (SelectUPFAndAllocUEIPForULCL)**:
- Determine correct static address to pass to `pool.Allocate()`
- Check `PDUAddress` for IPv4, `PDUAddressIPv6` for IPv6
- Enhanced logging with selected UPF and allocated address

### Key Features

1. **Dual-field check**: Examines both `PDUAddress` and `PDUAddressIPv6`
2. **Legacy compatibility**: Handles old code that used `PDUAddress` for IPv6
3. **Proper family separation**: IPv4 and IPv6 handled independently
4. **Consistent with main path**: Mirrors logic in `getUEIPPoolByFamily()`

### Build Verification

```bash
make smf
# Build successful
```

### Testing Recommendations

1. **Static IPv6-only ULCL**: Verify static address is allocated
2. **Static IPv4-only ULCL**: Verify existing behavior unchanged
3. **Dual-stack ULCL**: Verify both addresses honored (see Bug Fix 3)
4. **Dynamic allocation**: Verify fallback still works

---

## Bug Fix 3: ULCL Dual-Stack Allocation Issue

### Date: October 22, 2025
### Files Modified:
- `NFs/smf/internal/context/ue_defaultPath.go` (major rewrite)
- `NFs/smf/internal/context/sm_context.go`

### Problem Identified

`internal/context/ue_defaultPath.go:187-215` allocated only one address family per ULCL session. For `PDUSessionTypeIPv4IPv6`, the function returned as soon as it got the first address, so callers continued to downgrade to a single-stack setup.

**Impact**: A true dual-stack ULCL flow needed to request and return **both** IPv4 and IPv6 addresses, but the legacy implementation prevented this, forcing all ULCL deployments to single-stack operation even when dual-stack was requested.

### Root Cause Analysis

1. **Single return value**: `SelectUPFAndAllocUEIPForULCL` returned `(string, net.IP, bool)` - only one IP address
2. **Immediate return**: Code returned as soon as first address was allocated
3. **No dual-stack logic**: No attempt to allocate both families on the same UPF
4. **Inconsistent with main path**: Standard allocator had full dual-stack support via `SelectUPFAndAllocUEIPDualStack`

### Solution Implemented

Complete rewrite of ULCL allocation to match the dual-stack allocator pattern:

#### Part 1: Change Return Type

Changed `SelectUPFAndAllocUEIPForULCL` signature:

```go
// OLD
func (dfp *UEDefaultPaths) SelectUPFAndAllocUEIPForULCL(upi *UserPlaneInformation,
    selection *UPFSelectionParams,
) (string, net.IP, bool)

// NEW - matches UEIPAllocationResult from main path
func (dfp *UEDefaultPaths) SelectUPFAndAllocUEIPForULCL(upi *UserPlaneInformation,
    selection *UPFSelectionParams,
) *UEIPAllocationResult
```

Where `UEIPAllocationResult` is:
```go
type UEIPAllocationResult struct {
    UPF             *UPNode
    IPv4Address     net.IP
    IPv6Address     net.IP
    UseStaticIPv4   bool
    UseStaticIPv6   bool
    AllocatedFamily uint8 // nasMessage.PDUSessionTypeIPv4/IPv6/IPv4IPv6
}
```

#### Part 2: Implement Dual-Stack Allocation Logic

Completely rewrote `SelectUPFAndAllocUEIPForULCL` to mirror `SelectUPFAndAllocUEIPDualStack`:

```go
func (dfp *UEDefaultPaths) SelectUPFAndAllocUEIPForULCL(...) *UEIPAllocationResult {
    // Determine required address families based on session type
    sessionType := selection.SelectedPDUSessionType
    needIPv4 := sessionType == nasMessage.PDUSessionTypeIPv4 ||
                sessionType == nasMessage.PDUSessionTypeIPv4IPv6
    needIPv6 := sessionType == nasMessage.PDUSessionTypeIPv6 ||
                sessionType == nasMessage.PDUSessionTypeIPv4IPv6

    // Track best fallback candidates for dual-stack downgrade
    var bestIPv4Fallback *UEIPAllocationResult
    var bestIPv6Fallback *UEIPAllocationResult

    for _, upfName := range sortedUPFList {
        upf := upi.UPFs[upfName]

        // Attempt dual-stack allocation if both families are needed
        if needIPv4 && needIPv6 {
            result := tryULCLDualStackAllocation(upi, upf, selection)
            if result != nil {
                releaseFallbacks()
                return result  // Success: both IPv4 and IPv6
            }
            // Track fallbacks for graceful downgrade
            if bestIPv4Fallback == nil {
                bestIPv4Fallback = tryULCLSingleFamilyAllocation(upi, upf, selection, true)
            }
            if bestIPv6Fallback == nil {
                bestIPv6Fallback = tryULCLSingleFamilyAllocation(upi, upf, selection, false)
            }
        } else if needIPv4 {
            // IPv4-only allocation
            result := tryULCLSingleFamilyAllocation(upi, upf, selection, true)
            if result != nil {
                return result
            }
        } else if needIPv6 {
            // IPv6-only allocation
            result := tryULCLSingleFamilyAllocation(upi, upf, selection, false)
            if result != nil {
                return result
            }
        }
    }

    // Graceful downgrade if dual-stack not available
    if needIPv4 && needIPv6 {
        if bestIPv4Fallback != nil {
            // Release unused IPv6 fallback, return IPv4-only
            return bestIPv4Fallback
        }
        if bestIPv6Fallback != nil {
            // Release unused IPv4 fallback, return IPv6-only
            return bestIPv6Fallback
        }
    }

    return nil
}
```

#### Part 3: Add Helper Functions

Added three ULCL-specific helper functions mirroring the main allocator:

**1. tryULCLDualStackAllocation()**
```go
func tryULCLDualStackAllocation(upi *UserPlaneInformation, upf *UPNode,
    selection *UPFSelectionParams) *UEIPAllocationResult {

    // Get pools for both families
    ipv4Pools, ipv6Pools, useStaticIPv4, useStaticIPv6 := getUEIPPoolDualStack(upf, selection)

    if len(ipv4Pools) == 0 || len(ipv6Pools) == 0 {
        return nil
    }

    // Allocate IPv4
    var ipv4Addr net.IP
    staticIPv4 := selection.PDUAddress
    if staticIPv4 != nil && staticIPv4.To4() == nil {
        staticIPv4 = nil
    }
    for _, pool := range sortedIPv4Pools {
        addr := pool.Allocate(staticIPv4)
        if addr != nil {
            ipv4Addr = addr
            break
        }
    }
    if ipv4Addr == nil {
        return nil
    }

    // Allocate IPv6
    staticIPv6 := selection.PDUAddressIPv6
    if staticIPv6 == nil && selection.PDUAddress != nil && selection.PDUAddress.To4() == nil {
        staticIPv6 = selection.PDUAddress
    }
    for _, pool := range sortedIPv6Pools {
        addr := pool.Allocate(staticIPv6)
        if addr != nil {
            ipv6Addr = addr
            break
        }
    }

    if ipv6Addr == nil {
        // Release IPv4 and fail dual-stack attempt
        upi.ReleaseUEIP(upf, ipv4Addr, useStaticIPv4)
        return nil
    }

    // Success: both addresses allocated
    return &UEIPAllocationResult{
        UPF:             upf,
        IPv4Address:     ipv4Addr,
        IPv6Address:     ipv6Addr,
        UseStaticIPv4:   useStaticIPv4,
        UseStaticIPv6:   useStaticIPv6,
        AllocatedFamily: nasMessage.PDUSessionTypeIPv4IPv6,
    }
}
```

**2. tryULCLSingleFamilyAllocation()**
```go
func tryULCLSingleFamilyAllocation(upi *UserPlaneInformation, upf *UPNode,
    selection *UPFSelectionParams, isIPv4 bool) *UEIPAllocationResult {

    var pools []*UeIPPool
    var useStatic bool
    var requestedAddr net.IP

    if isIPv4 {
        ipv4Pools, _, useStaticIPv4, _ := getUEIPPoolDualStack(upf, selection)
        pools = ipv4Pools
        useStatic = useStaticIPv4
        requestedAddr = selection.PDUAddress
        if requestedAddr != nil && requestedAddr.To4() == nil {
            requestedAddr = nil
        }
    } else {
        _, ipv6Pools, _, useStaticIPv6 := getUEIPPoolDualStack(upf, selection)
        pools = ipv6Pools
        useStatic = useStaticIPv6
        requestedAddr = selection.PDUAddressIPv6
        if requestedAddr == nil && selection.PDUAddress != nil && selection.PDUAddress.To4() == nil {
            requestedAddr = selection.PDUAddress
        }
    }

    if len(pools) == 0 {
        return nil
    }

    for _, pool := range sortedPools {
        addr := pool.Allocate(requestedAddr)
        if addr != nil {
            result := &UEIPAllocationResult{UPF: upf}
            if isIPv4 {
                result.IPv4Address = addr
                result.UseStaticIPv4 = useStatic
                result.AllocatedFamily = nasMessage.PDUSessionTypeIPv4
            } else {
                result.IPv6Address = addr
                result.UseStaticIPv6 = useStatic
                result.AllocatedFamily = nasMessage.PDUSessionTypeIPv6
            }
            return result
        }
    }
    return nil
}
```

**3. getUEIPPoolDualStack()**
```go
func getUEIPPoolDualStack(upNode *UPNode, selection *UPFSelectionParams) (
    ipv4Pools, ipv6Pools []*UeIPPool, useStaticIPv4, useStaticIPv6 bool) {

    origSessionType := selection.SelectedPDUSessionType

    // Get IPv4 pools
    selection.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv4
    ipv4Pools, useStaticIPv4 = getUEIPPool(upNode, selection)

    // Get IPv6 pools
    selection.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv6
    ipv6Pools, useStaticIPv6 = getUEIPPool(upNode, selection)

    // Restore original session type
    selection.SelectedPDUSessionType = origSessionType

    return ipv4Pools, ipv6Pools, useStaticIPv4, useStaticIPv6
}
```

#### Part 4: Update Call Site in sm_context.go

Simplified the ULCL branch to match the standard path:

```go
// OLD - complex conversion logic
if GetSelf().ULCLSupport && CheckUEHasPreConfig(c.Supi) {
    selectedUPFName, allocatedIP, useStatic := preConfigPathPool.SelectUPFAndAllocUEIPForULCL(upi, param)
    if selectedUPFName != "" && allocatedIP != nil {
        c.SelectedUPF = upi.UPFs[selectedUPFName]
        result = &UEIPAllocationResult{UPF: c.SelectedUPF}
        if allocatedIP.To4() != nil {
            result.IPv4Address = allocatedIP
            result.UseStaticIPv4 = useStatic
            result.AllocatedFamily = nasMessage.PDUSessionTypeIPv4
        } else {
            result.IPv6Address = allocatedIP
            result.UseStaticIPv6 = useStatic
            result.AllocatedFamily = nasMessage.PDUSessionTypeIPv6
        }
    }
}

// NEW - unified handling
if GetSelf().ULCLSupport && CheckUEHasPreConfig(c.Supi) {
    // ULCL path - now supports dual-stack allocation
    result = preConfigPathPool.SelectUPFAndAllocUEIPForULCL(upi, param)
    if result != nil {
        c.SelectedUPF = result.UPF
    }
} else {
    // Use new dual-stack allocation
    result = upi.SelectUPFAndAllocUEIPDualStack(param)
    if result != nil {
        c.SelectedUPF = result.UPF
    }
}
```

### Changes Made

**File: `NFs/smf/internal/context/ue_defaultPath.go`**

1. **Added import**: `"github.com/free5gc/nas/nasMessage"` for session type constants

2. **Lines 187-301 (SelectUPFAndAllocUEIPForULCL - complete rewrite)**:
   - Changed return type to `*UEIPAllocationResult`
   - Implemented dual-stack allocation logic
   - Added fallback tracking for graceful downgrade
   - Proper resource cleanup (release unused allocations)
   - Comprehensive WNC-prefixed logging

3. **Lines 338-405 (tryULCLDualStackAllocation - new function)**:
   - Attempts to allocate both IPv4 and IPv6 on same UPF
   - Handles static addresses for both families
   - Releases IPv4 if IPv6 allocation fails
   - Returns dual-stack result or nil

4. **Lines 407-460 (tryULCLSingleFamilyAllocation - new function)**:
   - Allocates single family (IPv4 or IPv6)
   - Supports both static and dynamic allocation
   - Returns appropriate result structure

5. **Lines 462-480 (getUEIPPoolDualStack - new function)**:
   - Helper to extract both IPv4 and IPv6 pools
   - Temporarily modifies session type for pool selection
   - Restores original state after extraction

**File: `NFs/smf/internal/context/sm_context.go`**

**Lines 796-812 (findPSAandAllocUeIP ULCL branch)**:
   - Removed legacy single-IP conversion logic
   - ULCL path now directly returns `UEIPAllocationResult`
   - Unified handling for both ULCL and non-ULCL flows

### Key Features

1. **True dual-stack support**: Allocates both IPv4 and IPv6 when `PDUSessionTypeIPv4IPv6` requested
2. **Graceful downgrade**: Falls back to single-stack if dual-stack unavailable
3. **Static IP support**: Honors both `PDUAddress` (IPv4) and `PDUAddressIPv6` (IPv6)
4. **Resource cleanup**: Properly releases unused allocations during fallback
5. **Consistent behavior**: ULCL path now matches standard dual-stack allocator logic
6. **Comprehensive logging**: WNC-prefixed logs for all ULCL operations

### Allocation Flow

```
PDUSessionTypeIPv4IPv6 requested:
  For each ULCL UPF:
    1. Try dual-stack allocation (both IPv4 and IPv6)
       → Success: return both addresses
       → Failure: continue to fallback tracking

    2. Track first available IPv4-only as fallback
    3. Track first available IPv6-only as fallback

  If no dual-stack UPF found:
    → Use IPv4-only fallback (preferred)
    → Or use IPv6-only fallback
    → Release unused fallback allocation

PDUSessionTypeIPv4 requested:
  For each ULCL UPF:
    → Try IPv4-only allocation
    → Return first success

PDUSessionTypeIPv6 requested:
  For each ULCL UPF:
    → Try IPv6-only allocation
    → Return first success
```

### Build Verification

```bash
make smf
# Build successful
```

### Testing Recommendations

1. **Dual-stack ULCL**: Verify both IPv4 and IPv6 are allocated on same UPF
2. **Dual-stack with static IPs**: Verify both static addresses honored
3. **Dual-stack fallback**: Verify graceful downgrade when dual-stack unavailable
4. **IPv4-only ULCL**: Verify single-stack behavior unchanged
5. **IPv6-only ULCL**: Verify single-stack behavior unchanged
6. **Resource cleanup**: Verify no IP leaks during fallback scenarios
7. **Session establishment**: Verify PFCP messages contain both addresses for dual-stack

### Integration with Previous Fixes

This fix builds upon Bug Fix 2 (ULCL IPv6 Static Address) by:
- Using the corrected `getUEIPPool()` that checks both `PDUAddress` and `PDUAddressIPv6`
- Properly passing static addresses through `getUEIPPoolDualStack()` helper
- Ensuring static IPv6 bindings work in dual-stack ULCL scenarios

### 3GPP Compliance

This implementation aligns with 3GPP specifications for dual-stack PDU sessions:
- **TS 23.501**: PDU Session Types including IPv4v6 dual-stack
- **TS 23.502**: PDU Session Establishment with dual-stack support
- **TS 29.244**: PFCP requirements for dual-stack UE IP addressing

---

## Bug Fix 4: Dual-Stack Downgrade State Cleanup Issue

### Date: October 22, 2025
### Files Modified: `NFs/smf/internal/context/sm_context.go`

### Problem Identified

When a dual-stack (IPv4v6) PDU session request downgrades to IPv4-only or IPv6-only due to address allocation constraints, the code in `sm_context.go:880-936` failed to clear stale state from the unused address family. This caused the SMContext to retain old IPv4 or IPv6 address fields even though the session negotiated single-stack operation.

**Impact**:
- The `HasPDUIPv6()` helper returns `true` when `PDUAddressIPv6 != nil`, even after downgrading to IPv4-only
- `datapath.go:544-545` calls `PDUIPv4()` and `PDUIPv6()` to determine which addresses to include in PFCP messages
- The PFCP `UEIPAddress` IE (lines 548-562, 649-673, 705-729) would include **both** the negotiated IPv4 address and the stale IPv6 address (or vice versa)
- This creates a **session type mismatch**: the session negotiated IPv4-only but PFCP messages advertise dual-stack to the UPF
- UPF may reject the session due to invalid/mismatched address information
- Even if accepted, downstream packet processing uses incorrect addressing metadata

### Root Cause

Three downgrade scenarios in the dual-stack allocation logic failed to clear opposite-family state:

**1. Dual-stack → IPv4-only downgrade** (line 880-895):
```go
} else if result.IPv4Address != nil {
    // Downgrade to IPv4-only
    c.PDUAddress = result.IPv4Address
    c.PDUAddressIPv4 = result.IPv4Address
    c.UseStaticIP = result.UseStaticIPv4
    c.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv4
    c.EstAcceptCause5gSMValue = nasMessage.Cause5GSMPDUSessionTypeIPv4OnlyAllowed
    // Missing: clear PDUAddressIPv6, UseStaticIPv6, PDUAddressIPv6PrefixLen
}
```

**2. Dual-stack → IPv6-only downgrade** (line 896-916):
```go
} else if result.IPv6Address != nil {
    // Downgrade to IPv6-only
    c.PDUAddressIPv6 = result.IPv6Address
    c.UseStaticIPv6 = result.UseStaticIPv6
    c.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv6
    c.EstAcceptCause5gSMValue = nasMessage.Cause5GSMPDUSessionTypeIPv6OnlyAllowed
    // Missing: clear PDUAddress, PDUAddressIPv4, UseStaticIP
}
```

**3. Dual-stack → static IPv6 fallback** (line 917-935):
```go
} else if c.PDUAddressIPv6 != nil {
    // WNC: Dual-stack requested but allocator couldn't serve it - keep preconfigured static IPv6
    c.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv6
    c.EstAcceptCause5gSMValue = nasMessage.Cause5GSMPDUSessionTypeIPv6OnlyAllowed
    // Missing: clear PDUAddress, PDUAddressIPv4, UseStaticIP
}
```

### How the Bug Manifests

**Scenario**: UE with pre-configured static IPv6 address requests dual-stack (IPv4v6)

```
1. SM context creation → PDUAddressIPv6 set to static value (e.g., 2001:db8::1)
2. Dual-stack allocation attempted → IPv4 allocated, IPv6 allocation fails
3. Code enters "else if result.IPv4Address != nil" branch
4. Sets: PDUAddressIPv4, UseStaticIP, SelectedPDUSessionType = IPv4
5. DOES NOT clear: PDUAddressIPv6, UseStaticIPv6, PDUAddressIPv6PrefixLen
6. Later in datapath.go:
   - ipv4, hasIPv4 := smContext.PDUIPv4() → returns (allocated_ipv4, true)
   - ipv6, hasIPv6 := smContext.PDUIPv6() → returns (2001:db8::1, true) ← STALE!
7. PFCP UEIPAddress IE constructed with:
   - V4=true, Ipv4Address=allocated_ipv4
   - V6=true, Ipv6Address=2001:db8::1 ← WRONG!
   - Ipv6d=true, Ipv6PrefixDelegationBits=64 ← INVALID!
8. UPF receives dual-stack PFCP but session is IPv4-only → reject or incorrect forwarding
```

### Solution Implemented

Added explicit state cleanup in all three downgrade branches to ensure only the negotiated address family remains in the context.

#### Change 1: IPv4-only Downgrade (lines 887-893)

```go
} else if result.IPv4Address != nil {
    // Downgrade to IPv4-only
    c.PDUAddress = result.IPv4Address
    c.PDUAddressIPv4 = result.IPv4Address
    c.UseStaticIP = result.UseStaticIPv4
    c.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv4
    c.EstAcceptCause5gSMValue = nasMessage.Cause5GSMPDUSessionTypeIPv4OnlyAllowed
    // WNC: Clear stale IPv6 state to prevent dual-stack mismatch in PFCP messages
    c.PDUAddressIPv6 = nil
    c.UseStaticIPv6 = false
    c.PDUAddressIPv6PrefixLen = 0
    if c.SelectionParam != nil {
        c.SelectionParam.PDUAddressIPv6 = nil
    }
    c.Log.Warnf("WNC: Dual-stack requested but only IPv4 available - downgraded to IPv4-only [%s]",
        result.IPv4Address.String())
}
```

**Cleared fields**:
- `PDUAddressIPv6 = nil`: Helper `HasPDUIPv6()` will now return `false`
- `UseStaticIPv6 = false`: Prevents static IPv6 processing
- `PDUAddressIPv6PrefixLen = 0`: Removes stale prefix delegation metadata
- `SelectionParam.PDUAddressIPv6 = nil`: Clears selection parameter for UPF lookup

#### Change 2: IPv6-only Downgrade (lines 902-905)

```go
} else if result.IPv6Address != nil {
    // Downgrade to IPv6-only
    c.PDUAddressIPv6 = result.IPv6Address
    c.UseStaticIPv6 = result.UseStaticIPv6
    c.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv6
    c.EstAcceptCause5gSMValue = nasMessage.Cause5GSMPDUSessionTypeIPv6OnlyAllowed
    // WNC: Clear stale IPv4 state to prevent dual-stack mismatch in PFCP messages
    c.PDUAddress = nil
    c.PDUAddressIPv4 = nil
    c.UseStaticIP = false
    c.Log.Warnf("WNC: Dual-stack requested but only IPv6 available - downgraded to IPv6-only [%s]",
        result.IPv6Address.String())
    // ... IPv6 prefix length extraction ...
}
```

**Cleared fields**:
- `PDUAddress = nil`: Legacy field cleared for consistency
- `PDUAddressIPv4 = nil`: Helper `HasPDUIPv4()` will now return `false`
- `UseStaticIP = false`: Prevents static IPv4 processing

#### Change 3: Static IPv6 Fallback (lines 921-924)

```go
} else if c.PDUAddressIPv6 != nil {
    // WNC: Dual-stack requested but allocator couldn't serve it - keep preconfigured static IPv6
    c.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv6
    c.EstAcceptCause5gSMValue = nasMessage.Cause5GSMPDUSessionTypeIPv6OnlyAllowed
    // WNC: Clear stale IPv4 state to prevent dual-stack mismatch in PFCP messages
    c.PDUAddress = nil
    c.PDUAddressIPv4 = nil
    c.UseStaticIP = false
    c.Log.Warnf("WNC: Dual-stack requested but allocator failed - using preconfigured static IPv6 [%s]",
        c.PDUAddressIPv6.String())
    // ... IPv6 prefix length extraction ...
}
```

**Cleared fields**: Same as Change 2 (IPv6-only downgrade)

### Changes Made

**File: `NFs/smf/internal/context/sm_context.go`**

**Lines 887-893 (IPv4-only downgrade)**:
- Clear `PDUAddressIPv6`, `UseStaticIPv6`, `PDUAddressIPv6PrefixLen`
- Clear `SelectionParam.PDUAddressIPv6` if `SelectionParam` exists
- Added WNC comment explaining the cleanup

**Lines 902-905 (IPv6-only downgrade)**:
- Clear `PDUAddress`, `PDUAddressIPv4`, `UseStaticIP`
- Added WNC comment explaining the cleanup

**Lines 921-924 (static IPv6 fallback)**:
- Clear `PDUAddress`, `PDUAddressIPv4`, `UseStaticIP`
- Added WNC comment explaining the cleanup

### Verification of Fix

**1. Helper Function Behavior**:
```go
// After IPv4-only downgrade:
func (smContext *SMContext) HasPDUIPv6() bool {
    return smContext.PDUAddressIPv6 != nil  // Returns FALSE ✓
}

func (smContext *SMContext) PDUIPv6() (net.IP, bool) {
    if !smContext.HasPDUIPv6() {
        return nil, false  // Returns (nil, false) ✓
    }
    return smContext.PDUAddressIPv6, true
}
```

**2. PFCP Message Construction** (datapath.go:544-562):
```go
ipv4, hasIPv4 := smContext.PDUIPv4()  // (allocated_ipv4, true)
ipv6, hasIPv6 := smContext.PDUIPv6()  // (nil, false) ✓

if hasIPv4 || hasIPv6 {
    ULPDR.PDI.UEIPAddress = &pfcpType.UEIPAddress{
        V4: hasIPv4,  // true
        V6: hasIPv6,  // false ✓
    }
    if hasIPv4 {
        ULPDR.PDI.UEIPAddress.Ipv4Address = ipv4
    }
    if hasIPv6 {  // NOT EXECUTED ✓
        ULPDR.PDI.UEIPAddress.Ipv6Address = ipv6
        // Ipv6d flag not set ✓
    }
}
```

**3. Symmetric Fix for IPv6-only**:
The same logic applies when downgrading to IPv6-only - IPv4 state is properly cleared, preventing `HasPDUIPv4()` from returning stale data.

### Build Verification

```bash
cd free5gc && make smf
# Build successful - no compilation errors
```

### Testing Recommendations

**Critical Test Scenarios**:

1. **Dual-stack → IPv4-only downgrade with static IPv6**:
   - Pre-configure static IPv6 (e.g., 2001:db8::1/64)
   - Request dual-stack (IPv4v6)
   - IPv4 pool available, IPv6 pool exhausted
   - Expected: IPv4-only session, no IPv6 in PFCP messages

2. **Dual-stack → IPv6-only downgrade with static IPv4**:
   - Pre-configure static IPv4 (e.g., 10.60.0.10)
   - Request dual-stack (IPv4v6)
   - IPv6 pool available, IPv4 pool exhausted
   - Expected: IPv6-only session, no IPv4 in PFCP messages

3. **Dual-stack → static IPv6 fallback**:
   - Pre-configure static IPv6
   - Request dual-stack (IPv4v6)
   - Both pools fail allocation
   - Expected: IPv6-only session using static address, no IPv4 in PFCP

4. **PFCP message inspection**:
   - Capture PFCP Session Establishment messages to UPF
   - Verify `UEIPAddress` IE contains only negotiated address families
   - Verify `Ipv6d` flag and `Ipv6PrefixDelegationBits` only set for IPv6 sessions

5. **UPF session acceptance**:
   - Verify UPF accepts sessions without rejecting due to address mismatches
   - Verify packet forwarding works correctly for downgraded sessions

### Integration with Other Fixes

This fix complements:

- **Bug Fix 1** (PFCP IPv6 Delegation Flag): Ensures delegation flag is only set when valid, and now only for IPv6 sessions
- **Bug Fix 3** (ULCL Dual-Stack): Ensures downgrade logic works correctly for both ULCL and standard paths

### 3GPP Compliance

This fix ensures compliance with:

- **TS 29.244 Section 5.2.1**: UE IP Address IE must match the PDU Session Type
- **TS 23.502 Section 4.3.2**: Session establishment procedures with proper PDU Session Type negotiation
- **TS 23.501 Section 5.8.2**: PDU Session Types (IPv4, IPv6, IPv4v6) must be consistently applied

### Code Quality

The fix follows Free5GC coding standards:
- **WNC prefix**: All comments and logs use "WNC:" prefix for traceability
- **Symmetric handling**: Both IPv4 and IPv6 downgrade paths have equivalent cleanup logic
- **Defensive programming**: Checks `SelectionParam != nil` before clearing its fields
- **Clear documentation**: Inline comments explain the purpose of state cleanup

---

## Summary of All Fixes

### Overall Impact

These four fixes address critical issues in the Free5GC IPv6 implementation:

1. **PFCP Compliance**: Ensures PFCP messages conform to 3GPP TS 29.244
2. **Static IPv6 Support**: Enables static IPv6 addresses in ULCL deployments
3. **Dual-Stack ULCL**: Provides true dual-stack capability for ULCL sessions
4. **Dual-Stack Downgrade**: Prevents stale address state from causing session type mismatches

### Files Modified

- `NFs/smf/internal/context/datapath.go`: PFCP IPv6 delegation flag fix
- `NFs/smf/internal/context/user_plane_information.go`: ULCL IPv6 static address fix
- `NFs/smf/internal/context/ue_defaultPath.go`: ULCL dual-stack allocation (major rewrite)
- `NFs/smf/internal/context/sm_context.go`: ULCL call site simplification + dual-stack downgrade state cleanup

### Build Status

All changes verified to compile successfully:
```bash
make smf
# All builds successful
```

### Testing Status

**Recommended Test Scenarios**:
1. IPv4-only sessions (verify no regression)
2. IPv6-only sessions with static addresses
3. IPv6-only sessions with dynamic addresses
4. Dual-stack sessions (IPv4+IPv6)
5. Dual-stack sessions with static IPs
6. ULCL deployments with all above scenarios
7. PFCP session establishment with various UPF implementations

### Future Enhancements

Potential areas for further improvement:
1. **Unit tests**: Add comprehensive test coverage for ULCL dual-stack scenarios
2. **Performance optimization**: Consider caching pool lookups
3. **Enhanced metrics**: Track dual-stack success/fallback rates
4. **Configuration validation**: Validate static IP configs at startup
5. **Documentation**: Update operator guides with dual-stack ULCL configuration examples

---

---

## Bug Fix 5: Dual-Stack Downgrade SelectionParam Synchronization Issue

### Date: October 22, 2025
### Files Modified: `NFs/smf/internal/context/sm_context.go`

### Problem Identified

When a dual-stack (IPv4v6) request falls back to IPv4-only or IPv6-only, the code updates `c.SelectedPDUSessionType` but leaves `c.SelectionParam.SelectedPDUSessionType` at its original IPv4v6 value. Similarly, when falling back to IPv4-only, the code clears `SelectionParam.PDUAddressIPv6` but doesn't update the session type; when falling back to IPv6-only, it doesn't clear `SelectionParam.PDUAddress`.

**Impact**: Later flows such as ULCL default-path selection (`internal/context/ue_defaultPath.go:196`) derive `needIPv4`/`needIPv6` from `selection.SelectedPDUSessionType`. Because the selection param still advertises dual-stack, the code keeps re-entering the dual-stack allocation path and keeps asking for an IPv6 (or IPv4) address even though the session already decided to run IPv4-only (or IPv6-only). This can lead to:
- Repeated PFCP allocation failures
- Spurious downgrade loops
- Inconsistent IP family handling across different code paths

### Root Cause

Three downgrade scenarios failed to synchronize the `SelectionParam.SelectedPDUSessionType` field with the actual downgraded session type:

**1. IPv4-only fallback** (lines 880-896):
```go
} else if result.IPv4Address != nil {
    // Downgrade to IPv4-only
    c.PDUAddress = result.IPv4Address
    c.PDUAddressIPv4 = result.IPv4Address
    c.UseStaticIP = result.UseStaticIPv4
    c.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv4  // ✓ Updated
    c.EstAcceptCause5gSMValue = nasMessage.Cause5GSMPDUSessionTypeIPv4OnlyAllowed
    // WNC: Clear stale IPv6 state to prevent dual-stack mismatch in PFCP messages
    c.PDUAddressIPv6 = nil
    c.UseStaticIPv6 = false
    c.PDUAddressIPv6PrefixLen = 0
    if c.SelectionParam != nil {
        c.SelectionParam.PDUAddressIPv6 = nil  // ✓ Cleared
        // MISSING: c.SelectionParam.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv4
    }
}
```

**2. IPv6-only fallback** (lines 897-921):
```go
} else if result.IPv6Address != nil {
    // Downgrade to IPv6-only
    c.PDUAddressIPv6 = result.IPv6Address
    c.UseStaticIPv6 = result.UseStaticIPv6
    c.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv6  // ✓ Updated
    c.EstAcceptCause5gSMValue = nasMessage.Cause5GSMPDUSessionTypeIPv6OnlyAllowed
    // WNC: Clear stale IPv4 state to prevent dual-stack mismatch in PFCP messages
    c.PDUAddress = nil
    c.PDUAddressIPv4 = nil
    c.UseStaticIP = false
    // MISSING: Clear SelectionParam.PDUAddress
    // MISSING: c.SelectionParam.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv6
}
```

**3. Static IPv6 fallback** (lines 922-944):
```go
} else if c.PDUAddressIPv6 != nil {
    // WNC: Dual-stack requested but allocator couldn't serve it - keep preconfigured static IPv6
    c.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv6  // ✓ Updated
    c.EstAcceptCause5gSMValue = nasMessage.Cause5GSMPDUSessionTypeIPv6OnlyAllowed
    // WNC: Clear stale IPv4 state to prevent dual-stack mismatch in PFCP messages
    c.PDUAddress = nil
    c.PDUAddressIPv4 = nil
    c.UseStaticIP = false
    // MISSING: Clear SelectionParam.PDUAddress
    // MISSING: c.SelectionParam.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv6
}
```

### How the Bug Manifests

**Scenario**: Dual-stack request falls back to IPv4-only, then ULCL path selection occurs

```
1. Initial request: PDUSessionTypeIPv4IPv6
2. Allocator returns IPv4-only (no IPv6 available)
3. Code enters IPv4-only downgrade branch:
   - c.SelectedPDUSessionType = PDUSessionTypeIPv4 ✓
   - c.SelectionParam.SelectedPDUSessionType remains PDUSessionTypeIPv4IPv6 ✗
4. Later ULCL path selection (ue_defaultPath.go:196):
   sessionType := selection.SelectedPDUSessionType  // PDUSessionTypeIPv4IPv6 (stale!)
   needIPv4 := sessionType == PDUSessionTypeIPv4 || sessionType == PDUSessionTypeIPv4IPv6  // true
   needIPv6 := sessionType == PDUSessionTypeIPv6 || sessionType == PDUSessionTypeIPv4IPv6  // true ✗
5. ULCL code attempts dual-stack allocation again:
   - Requests IPv6 address even though session is IPv4-only
   - IPv6 allocation fails (same reason as before)
   - May enter fallback/retry loops
6. Potential outcomes:
   - Repeated allocation failures logged
   - Session establishment delay or failure
   - Inconsistent state between different code paths
```

### Solution Implemented

Synchronize `SelectionParam.SelectedPDUSessionType` with the downgraded session type in all three fallback branches.

#### Change 1: IPv4-only Downgrade (line 893)

```go
} else if result.IPv4Address != nil {
    // Downgrade to IPv4-only
    c.PDUAddress = result.IPv4Address
    c.PDUAddressIPv4 = result.IPv4Address
    c.UseStaticIP = result.UseStaticIPv4
    c.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv4
    c.EstAcceptCause5gSMValue = nasMessage.Cause5GSMPDUSessionTypeIPv4OnlyAllowed
    // WNC: Clear stale IPv6 state to prevent dual-stack mismatch in PFCP messages
    c.PDUAddressIPv6 = nil
    c.UseStaticIPv6 = false
    c.PDUAddressIPv6PrefixLen = 0
    if c.SelectionParam != nil {
        c.SelectionParam.PDUAddressIPv6 = nil
        c.SelectionParam.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv4  // NEW
    }
    c.Log.Warnf("WNC: Dual-stack requested but only IPv4 available - downgraded to IPv4-only [%s]",
        result.IPv4Address.String())
}
```

**Added**: `c.SelectionParam.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv4`

#### Change 2: IPv6-only Downgrade (lines 908-909)

```go
} else if result.IPv6Address != nil {
    // Downgrade to IPv6-only
    c.PDUAddressIPv6 = result.IPv6Address
    c.UseStaticIPv6 = result.UseStaticIPv6
    c.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv6
    c.EstAcceptCause5gSMValue = nasMessage.Cause5GSMPDUSessionTypeIPv6OnlyAllowed
    // WNC: Clear stale IPv4 state to prevent dual-stack mismatch in PFCP messages
    c.PDUAddress = nil
    c.PDUAddressIPv4 = nil
    c.UseStaticIP = false
    if c.SelectionParam != nil {
        c.SelectionParam.PDUAddress = nil                                       // NEW
        c.SelectionParam.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv6  // NEW
    }
    c.Log.Warnf("WNC: Dual-stack requested but only IPv6 available - downgraded to IPv6-only [%s]",
        result.IPv6Address.String())
    // ... IPv6 prefix length extraction ...
}
```

**Added**:
- `c.SelectionParam.PDUAddress = nil` (clear stale IPv4 address)
- `c.SelectionParam.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv6`

#### Change 3: Static IPv6 Fallback (lines 931-932)

```go
} else if c.PDUAddressIPv6 != nil {
    // WNC: Dual-stack requested but allocator couldn't serve it - keep preconfigured static IPv6
    c.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv6
    c.EstAcceptCause5gSMValue = nasMessage.Cause5GSMPDUSessionTypeIPv6OnlyAllowed
    // WNC: Clear stale IPv4 state to prevent dual-stack mismatch in PFCP messages
    c.PDUAddress = nil
    c.PDUAddressIPv4 = nil
    c.UseStaticIP = false
    if c.SelectionParam != nil {
        c.SelectionParam.PDUAddress = nil                                       // NEW
        c.SelectionParam.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv6  // NEW
    }
    c.Log.Warnf("WNC: Dual-stack requested but allocator failed - using preconfigured static IPv6 [%s]",
        c.PDUAddressIPv6.String())
    // ... IPv6 prefix length extraction ...
}
```

**Added**: Same as Change 2 (both are IPv6-only downgrades)

### Changes Made

**File: `NFs/smf/internal/context/sm_context.go`**

**Line 893 (IPv4-only downgrade)**:
- Added: `c.SelectionParam.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv4`

**Lines 908-909 (IPv6-only downgrade)**:
- Added: `c.SelectionParam.PDUAddress = nil`
- Added: `c.SelectionParam.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv6`

**Lines 931-932 (static IPv6 fallback)**:
- Added: `c.SelectionParam.PDUAddress = nil`
- Added: `c.SelectionParam.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv6`

### Verification of Fix

**After IPv4-only downgrade**:
```go
// Main context
c.SelectedPDUSessionType == PDUSessionTypeIPv4  // ✓

// Selection parameters (synchronized)
c.SelectionParam.SelectedPDUSessionType == PDUSessionTypeIPv4  // ✓
c.SelectionParam.PDUAddressIPv6 == nil  // ✓

// ULCL path selection (ue_defaultPath.go:196)
sessionType := selection.SelectedPDUSessionType  // PDUSessionTypeIPv4 ✓
needIPv4 := sessionType == PDUSessionTypeIPv4 || sessionType == PDUSessionTypeIPv4IPv6  // true ✓
needIPv6 := sessionType == PDUSessionTypeIPv6 || sessionType == PDUSessionTypeIPv4IPv6  // false ✓
```

**After IPv6-only downgrade**:
```go
// Main context
c.SelectedPDUSessionType == PDUSessionTypeIPv6  // ✓

// Selection parameters (synchronized)
c.SelectionParam.SelectedPDUSessionType == PDUSessionTypeIPv6  // ✓
c.SelectionParam.PDUAddress == nil  // ✓

// ULCL path selection (ue_defaultPath.go:196)
sessionType := selection.SelectedPDUSessionType  // PDUSessionTypeIPv6 ✓
needIPv4 := sessionType == PDUSessionTypeIPv4 || sessionType == PDUSessionTypeIPv4IPv6  // false ✓
needIPv6 := sessionType == PDUSessionTypeIPv6 || sessionType == PDUSessionTypeIPv4IPv6  // true ✓
```

### Build Verification

```bash
cd free5gc && make smf
# Build successful - no compilation errors
```

### Testing Recommendations

**Critical Test Scenarios**:

1. **Dual-stack → IPv4-only fallback with ULCL**:
   - Request dual-stack (IPv4v6)
   - IPv4 available, IPv6 unavailable
   - Session uses ULCL path
   - Expected: Single IPv4-only allocation, no IPv6 retry attempts

2. **Dual-stack → IPv6-only fallback with ULCL**:
   - Request dual-stack (IPv4v6)
   - IPv6 available, IPv4 unavailable
   - Session uses ULCL path
   - Expected: Single IPv6-only allocation, no IPv4 retry attempts

3. **Verify SelectionParam synchronization**:
   - Add debug logging in ULCL path to print `selection.SelectedPDUSessionType`
   - Confirm it matches the downgraded session type
   - Confirm `needIPv4`/`needIPv6` are calculated correctly

4. **Performance test**:
   - Multiple dual-stack sessions with fallback
   - Verify no allocation retry loops
   - Verify session establishment times are normal

### Integration with Other Fixes

This fix complements:

- **Bug Fix 3** (ULCL Dual-Stack): Ensures ULCL allocation logic receives correct session type
- **Bug Fix 4** (Dual-Stack Downgrade State Cleanup): Together these ensure complete state synchronization

### Code Affected by This Fix

**Direct callers that read `SelectionParam.SelectedPDUSessionType`**:

1. **`ue_defaultPath.go:196` (SelectUPFAndAllocUEIPForULCL)**:
   ```go
   sessionType := selection.SelectedPDUSessionType
   needIPv4 := sessionType == nasMessage.PDUSessionTypeIPv4 ||
               sessionType == nasMessage.PDUSessionTypeIPv4IPv6
   needIPv6 := sessionType == nasMessage.PDUSessionTypeIPv6 ||
               sessionType == nasMessage.PDUSessionTypeIPv4IPv6
   ```
   **Before fix**: Would incorrectly request dual-stack after downgrade
   **After fix**: Correctly requests only the downgraded family

2. **`user_plane_information.go:getUEIPPoolDualStack`**:
   ```go
   origSessionType := selection.SelectedPDUSessionType
   // Temporarily modify session type for pool selection
   selection.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv4
   ipv4Pools, useStaticIPv4 = getUEIPPool(upNode, selection)
   // Restore original
   selection.SelectedPDUSessionType = origSessionType
   ```
   **Before fix**: Would restore stale IPv4v6 value
   **After fix**: Restores correct downgraded value

### 3GPP Compliance

This fix ensures compliance with:

- **TS 23.502 Section 4.3.2**: PDU Session Establishment with consistent PDU Session Type throughout the procedure
- **TS 29.502 Section 5.2.2**: Nsmf_PDUSession_CreateSMContext - session type consistency
- **TS 24.501 Section 6.4.1**: PDU Session Type must be consistent between negotiation and resource allocation

### Root Cause Summary

The `SelectionParam` structure is passed to various allocation functions (`SelectUPFAndAllocUEIPForULCL`, `getUEIPPoolDualStack`) that make decisions based on `SelectedPDUSessionType`. When the main context downgrades from dual-stack to single-stack but `SelectionParam` retains the old dual-stack value, these functions incorrectly attempt to allocate addresses for both families, leading to:

1. **Allocation inefficiency**: Repeated attempts to allocate unavailable address family
2. **Inconsistent state**: Different parts of code operate on different session type assumptions
3. **Potential failures**: Some UPFs may reject mismatched allocation requests

By synchronizing `SelectionParam.SelectedPDUSessionType` with the actual downgraded type, all downstream code paths receive consistent information about the negotiated session type.

---

## Document History

- **2025-10-22**: Initial creation with all five bug fixes
  - Bug Fix 1: PFCP IPv6 Delegation Flag Issue
  - Bug Fix 2: ULCL IPv6 Static Address Allocation Issue
  - Bug Fix 3: ULCL Dual-Stack Allocation Issue
  - Bug Fix 4: Dual-Stack Downgrade State Cleanup Issue
  - Bug Fix 5: Dual-Stack Downgrade SelectionParam Synchronization Issue
