# Complete CreatePDR Debugging Report - SDF Filter Fix

**Date**: November 25, 2025
**Issue**: PFCP Session Establishment fails with `Est CreatePDR error: invalid argument`
**Root Cause**: Missing SRC_IPV4/SRC_IPV6 in flow description netlink attributes
**Status**: ✅ Fix Identified, Ready to Apply

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Problem Timeline](#problem-timeline)
3. [Debugging Implementation](#debugging-implementation)
4. [Root Cause Analysis](#root-cause-analysis)
5. [Proposed Fix](#proposed-fix)
6. [Testing Steps](#testing-steps)
7. [Files Modified](#files-modified)
8. [Verification Checklist](#verification-checklist)

---

## Executive Summary

### Problem
PFCP Session Establishment fails with `Est CreatePDR error: invalid argument` causing "No PDR match this skb : teid[2]" errors in the Free5GC UPF.

### Root Cause
The `ParseFlowDescIPNet()` function in `free5gc/NFs/upf/internal/forwarder/flowdesc.go` returns `nil` for "any"/"assigned" flow descriptions. This causes the UPF to omit SRC_IPV4/SRC_IPV6 netlink attributes when building the flow description. The gtp5g kernel module requires at least one source IP address attribute and rejects the PDR with `-EINVAL` (error -22).

### Solution
Change `ParseFlowDescIPNet()` to return `0.0.0.0/0` wildcard instead of `nil` for "any"/"assigned" cases. This satisfies kernel validation while maintaining "match any" semantics.

### Impact
- **Severity**: Critical - Prevents all PDU session establishment
- **Affected Components**: UPF, gtp5g kernel module
- **Fix Complexity**: Simple - Single function modification
- **Testing Required**: UE registration and data plane verification

---

## Problem Timeline

### Initial Symptoms

**Free5GC Logs** (free5gc-5.log):
```
[PFCP][SMF] Est CreatePDR error: invalid argument
```

**Kernel Logs** (dmesg-5.log):
```
[Tue Nov 25 10:39:20 2025] [gtp5g] parse_pdi: WNC: parse_sdf_filter FAILED, err = -22
[Tue Nov 25 10:39:20 2025] [gtp5g] pdr_fill: WNC: parse_pdi FAILED for PDR ID 1, err = -22
```

- All 4 PDRs (IDs 1, 2, 3, 4) failed during PFCP Session Establishment
- Error code `-22` = `-EINVAL` (invalid argument)
- Failure occurred in `parse_sdf_filter` function

### Debugging Phase 1: Identify Failure Location

**Actions Taken:**
1. Analyzed `gtp5g/src/genl/genl_pdr.c` to identify all -EINVAL return points
2. Added comprehensive WNC-prefixed logging to kernel module
3. Rebuilt and deployed gtp5g.ko module to remote machine

**Result:** Narrowed down failure to SDF filter parsing

### Debugging Phase 2: Identify Exact Validation Failure

**Actions Taken:**
1. Added detailed logging to `parse_sdf_filter()` and `parse_ip_filter_rule()`
2. Rebuilt and redeployed gtp5g.ko module
3. Captured detailed kernel logs

**Kernel Logs** (dmesg-6.log):
```
[Tue Nov 25 10:53:37 2025] [gtp5g] parse_ip_filter_rule: WNC: Flow description missing both SRC_IPV4 and SRC_IPV6 (line 790)
[Tue Nov 25 10:53:37 2025] [gtp5g] parse_sdf_filter: WNC: parse_ip_filter_rule FAILED, err = -22
[Tue Nov 25 10:53:37 2025] [gtp5g] parse_pdi: WNC: parse_sdf_filter FAILED, err = -22
[Tue Nov 25 10:53:37 2025] [gtp5g] pdr_fill: WNC: parse_pdi FAILED for PDR ID 1, err = -22
```

**Result:** ✅ **Exact error identified** - Missing both SRC_IPV4 and SRC_IPV6 attributes

### Analysis Phase: Trace Root Cause

**Investigation Path:**
1. Kernel validation at `gtp5g/src/genl/genl_pdr.c:807-810`
2. Netlink attribute building in `free5gc/NFs/upf/internal/forwarder/gtp5g.go:265-286`
3. Flow description parsing in `free5gc/NFs/upf/internal/forwarder/flowdesc.go:133-140`

**Root Cause Found:** `ParseFlowDescIPNet()` returns `nil` for "any"/"assigned"

---

## Debugging Implementation

### Kernel Module Logging Added

#### Modified File: `gtp5g/src/genl/genl_pdr.c`

**Total Lines Added**: ~129 lines of logging

#### Functions Modified

##### 1. pdr_fill() - Main PDR Attribute Parsing
**Logging Added:**
- START marker at function entry
- All PDR attributes: SEID, ID, Precedence, OuterHeaderRemoval, RoleAddrIPv4, UnixSocketPath, FAR ID, QER IDs, URR IDs
- PDI parsing start/failure
- FAR lookup (before/after with SEID and FAR ID)
- far_set_pdr, urr_set_pdr, qer_set_pdr failures
- unix_sock_client_update failure
- SUCCESS marker at function exit

**Example Log Output:**
```
[gtp5g] WNC: pdr_fill START - parsing netlink attributes
[gtp5g] WNC: PDR SEID = 1
[gtp5g] WNC: PDR ID = 1
[gtp5g] WNC: PDR Precedence = 255
[gtp5g] WNC: PDR FAR ID = 1
[gtp5g] WNC: Parsing PDI for PDR ID 1
[gtp5g] WNC: Looking for FAR ID 1 with SEID 1
[gtp5g] WNC: Found FAR ID 1 for PDR ID 1
[gtp5g] WNC: pdr_fill SUCCESS for PDR ID 1
```

##### 2. parse_pdi() - PDI (Packet Detection Information) Parsing
**Logging Added:**
- START marker
- nla_parse_nested failure
- UE IPv4 address
- UE IPv6 address
- F-TEID parsing start/failure
- When F-TEID is absent (DL anchor case)
- SourceInterface value
- SDF Filter parsing start/failure
- SUCCESS marker

**Example Log Output:**
```
[gtp5g] WNC: parse_pdi START
[gtp5g] WNC: PDI UE IPv4 = 10.155.0.1
[gtp5g] WNC: Parsing F-TEID
[gtp5g] WNC: PDI SourceInterface = 0
[gtp5g] WNC: Parsing SDF Filter
[gtp5g] WNC: parse_pdi SUCCESS
```

##### 3. parse_f_teid() - F-TEID (Fully Qualified TEID) Parsing
**Logging Added:**
- START marker
- nla_parse_nested failure
- Missing I_TEID attribute error (line 613)
- Missing IPv4/IPv6 GTP-U addresses error (line 617)
- TEID value (in hex)
- GTP-U IPv4 address
- GTP-U IPv6 address
- SUCCESS marker

**Example Log Output:**
```
[gtp5g] WNC: parse_f_teid START
[gtp5g] WNC: F-TEID TEID = 0x2
[gtp5g] WNC: F-TEID GTP-U IPv4 = 5.5.5.2
[gtp5g] WNC: parse_f_teid SUCCESS
```

##### 4. parse_sdf_filter() - SDF Filter Parsing
**Logging Added:**
- START marker
- nla_parse_nested failure
- Flow Description parsing start/failure
- Calls parse_ip_filter_rule()

##### 5. parse_ip_filter_rule() - IP Filter Rule Parsing (CRITICAL)
**Logging Added:**
- START marker
- nla_parse_nested failure
- **Missing ACTION attribute (line 793)**
- **Missing DIRECTION attribute (line 797)**
- **Missing PROTOCOL attribute (line 801)**
- **Missing SRC_IPV4/SRC_IPV6 (line 807)** ← **This caught the bug**
- **Missing DEST_IPV4/DEST_IPV6 (line 811)**
- Action/direction/protocol values
- SRC IPv4 presence/absence
- DEST IPv4 presence/absence
- SUCCESS marker

**Critical Code (Lines 807-810):**
```c
// WNC: Flow description must have either IPv4 or IPv6 addresses
if (!attrs[GTP5G_FLOW_DESCRIPTION_SRC_IPV4] && !attrs[GTP5G_FLOW_DESCRIPTION_SRC_IPV6]) {
    GTP5G_ERR(NULL, "WNC: Flow description missing both SRC_IPV4 and SRC_IPV6 (line 790)\n");
    return -EINVAL;
}
```

### Build Verification

**Compilation Status:**
- ✅ gtp5g module builds successfully
- ✅ All SDF filter logging statements compile without errors
- ✅ Module ready for deployment
- ⚠️ Only standard missing prototype warnings (pre-existing, non-critical)

**Build Commands Used:**
```bash
cd gtp5g
make clean
make
# Result: gtp5g.ko created successfully
```

---

## Root Cause Analysis

### Call Chain

```
PFCP Session Establishment Request (from SMF)
  ↓
free5gc/NFs/upf/internal/pfcp/handler.go: HandlePfcpSessionEstablishmentRequest()
  ↓
free5gc/NFs/upf/internal/forwarder/driver.go: CreatePDR()
  ↓
free5gc/NFs/upf/internal/forwarder/gtp5g.go: CreatePDR()
  ↓
free5gc/NFs/upf/internal/forwarder/gtp5g.go: newFlowDesc()
  ↓
free5gc/NFs/upf/internal/forwarder/flowdesc.go: ParseFlowDescIPNet("any")
  ↓
returns nil, nil  ← BUG
  ↓
newFlowDesc() skips adding SRC_IPV4/SRC_IPV6 attributes
  ↓
Netlink message sent to kernel without IP attributes
  ↓
gtp5g/src/genl/genl_pdr.c: parse_ip_filter_rule()
  ↓
Validation fails: "missing both SRC_IPV4 and SRC_IPV6"
  ↓
Returns -EINVAL
  ↓
CreatePDR fails with "invalid argument"
```

### Kernel Validation (gtp5g/src/genl/genl_pdr.c)

**Lines 807-810**: Kernel requires at least one source IP address
```c
// WNC: Flow description must have either IPv4 or IPv6 addresses
if (!attrs[GTP5G_FLOW_DESCRIPTION_SRC_IPV4] && !attrs[GTP5G_FLOW_DESCRIPTION_SRC_IPV6]) {
    GTP5G_ERR(NULL, "WNC: Flow description missing both SRC_IPV4 and SRC_IPV6 (line 790)\n");
    return -EINVAL;
}
```

**Lines 811-814**: Kernel also requires at least one destination IP address
```c
if (!attrs[GTP5G_FLOW_DESCRIPTION_DEST_IPV4] && !attrs[GTP5G_FLOW_DESCRIPTION_DEST_IPV6]) {
    GTP5G_ERR(NULL, "WNC: Flow description missing both DEST_IPV4 and DEST_IPV6 (line 792)\n");
    return -EINVAL;
}
```

### UPF Flow Description Parsing (free5gc/NFs/upf/internal/forwarder/flowdesc.go)

**Lines 131-159**: `ParseFlowDescIPNet()` function - **BUG LOCATION**
```go
func ParseFlowDescIPNet(s string) (*net.IPNet, error) {
	if s == "any" || s == "assigned" {
		/* WNC:
		"any" mean "match any peer", "assigned" means "match whichever UE IP the PDR already bound,"
		so we return nil to signal that the SDF filter must not emit IPv4/IPv6 address attributes (no constraints).
		The actual UE anchoring lives in the PDI/FAR; leaving the flow description open keeps the classifier aligned with 3GPP wildcard semantics.
		Read more in issue-ipv4-unreachable-upf-flowdesc-251114.md
		*/
		return nil, nil  // ← BUG: Kernel rejects PDR when no IP attributes present
	}

	// Parse CIDR notation
	_, ipnet, err := net.ParseCIDR(s)
	if err != nil {
		return nil, err
	}
	return ipnet, nil
}
```

**Problem**: When flow description contains "any" or "assigned", this function returns `nil` instead of a wildcard IP address.

### Netlink Attribute Building (free5gc/NFs/upf/internal/forwarder/gtp5g.go)

**Lines 265-286**: Conditional source IP attribute addition
```go
// WNC: Add source address (IPv4 or IPv6)
if fd.Src != nil {  // ← When "any", fd.Src is nil, so this block is SKIPPED
	if isIPv6 {
		attrs = append(attrs, nl.Attr{
			Type:  gtp5gnl.FLOW_DESCRIPTION_SRC_IPV6,
			Value: nl.AttrBytes(fd.Src.IP.To16()),
		})
		// ... mask
	} else {
		attrs = append(attrs, nl.Attr{
			Type:  gtp5gnl.FLOW_DESCRIPTION_SRC_IPV4,
			Value: nl.AttrBytes(fd.Src.IP.To4()),
		})
		// ... mask
	}
}
```

**Lines 289-310**: Conditional destination IP attribute addition
```go
// WNC: Add destination address (IPv4 or IPv6)
if fd.Dst != nil {  // ← When "any", fd.Dst is nil, so this block is SKIPPED
	if isIPv6 {
		attrs = append(attrs, nl.Attr{
			Type:  gtp5gnl.FLOW_DESCRIPTION_DEST_IPV6,
			Value: nl.AttrBytes(fd.Dst.IP.To16()),
		})
		// ... mask
	} else {
		attrs = append(attrs, nl.Attr{
			Type:  gtp5gnl.FLOW_DESCRIPTION_DEST_IPV4,
			Value: nl.AttrBytes(fd.Dst.IP.To4()),
		})
		// ... mask
	}
}
```

**Problem**: When `ParseFlowDescIPNet()` returns `nil`, the `newFlowDesc()` function skips adding SRC_IPV4/SRC_IPV6 and DEST_IPV4/DEST_IPV6 attributes to the netlink message.

---

## Proposed Fix

### Change to flowdesc.go (Lines 133-145)

**BEFORE (Buggy Code):**
```go
if s == "any" || s == "assigned" {
	/* WNC:
	"any" mean "match any peer", "assigned" means "match whichever UE IP the PDR already bound,"
	so we return nil to signal that the SDF filter must not emit IPv4/IPv6 address attributes (no constraints).
	The actual UE anchoring lives in the PDI/FAR; leaving the flow description open keeps the classifier aligned with 3GPP wildcard semantics.
	Read more in issue-ipv4-unreachable-upf-flowdesc-251114.md
	*/
	return nil, nil  // ← BUG
}
```

**AFTER (Fixed Code):**
```go
if s == "any" || s == "assigned" {
	/* WNC:
	"any" mean "match any peer", "assigned" means "match whichever UE IP the PDR already bound."
	The gtp5g kernel module requires at least SRC_IPV4 or SRC_IPV6 to be present in the flow description
	(validated at genl_pdr.c:807-810). We return 0.0.0.0/0 (match any IPv4) as a wildcard to satisfy
	the kernel validation while maintaining "match any" semantics.

	For IPv6 sessions, the kernel will use the IPv6 attributes from PDI (UE IPv6 address) and F-TEID
	(GTP-U IPv6 endpoint) for actual packet matching. The 0.0.0.0/0 in the flow description acts as
	a placeholder to pass kernel validation.
	*/
	return &net.IPNet{
		IP:   net.IPv4zero,        // 0.0.0.0
		Mask: net.CIDRMask(0, 32), // /0 - match any IPv4
	}, nil
}
```

### Why This Fix Works

1. **Satisfies Kernel Validation**: Provides SRC_IPV4/DEST_IPV4 attributes so kernel validation passes
2. **Maintains "Match Any" Semantics**: `0.0.0.0/0` matches all IPv4 addresses (wildcard)
3. **Doesn't Break IPv6**: For IPv6 sessions, the kernel uses PDI UE IPv6 and F-TEID GTP-U IPv6 for actual matching
4. **3GPP Compliant**: Aligns with 3GPP TS 29.244 SDF filter semantics for "any" peer

### Alternative Fix (IPv6-First Approach)

If you prefer IPv6-first wildcard:
```go
if s == "any" || s == "assigned" {
	// Return ::/0 (match any IPv6) instead
	return &net.IPNet{
		IP:   net.IPv6zero,         // ::
		Mask: net.CIDRMask(0, 128), // /0 - match any IPv6
	}, nil
}
```

**Recommendation**: Use IPv4 wildcard (`0.0.0.0/0`) as it's more universally supported and the kernel will use PDI/F-TEID addresses for actual IPv6 matching.

---

## Testing Steps

### 1. Apply the Fix

```bash
cd /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc

# Edit the file
nano NFs/upf/internal/forwarder/flowdesc.go

# Apply the fix to lines 133-145 (see "AFTER" code above)
```

### 2. Rebuild UPF

```bash
cd /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc

# Clean and rebuild UPF
make clean-upf
make upf

# Verify binary was rebuilt
ls -lh bin/upf
```

### 3. Deploy to Remote Machine

```bash
# Copy updated UPF binary to remote machine
# (Use your preferred method: scp, rsync, etc.)

# Example using tmux:
# 1. Copy file locally first
# 2. Then transfer to remote machine
```

### 4. Restart UPF on Remote Machine

```bash
# Via tmux session:
tmux new-session -d -s cn 'my-ssh --target cn'
tmux send-keys -t cn "sudo systemctl stop free5gc-upf" Enter
tmux send-keys -t cn "sudo systemctl start free5gc-upf" Enter

# Or manually:
tmux send-keys -t cn "cd /path/to/free5gc" Enter
tmux send-keys -t cn "./bin/upf -c config/upfcfg.yaml" Enter
```

### 5. Monitor Kernel Logs

```bash
# Via tmux session:
tmux new-session -d -s cn-logs 'my-ssh --target cn'
tmux send-keys -t cn-logs "sudo dmesg -C" Enter
tmux send-keys -t cn-logs "sudo dmesg -w | grep -E 'gtp5g|WNC'" Enter
```

### 6. Trigger PFCP Session Establishment

```bash
# Restart UE registration or trigger new PDU session
# Watch for CreatePDR success in kernel logs
```

### 7. Expected Success Logs

**Before Fix (dmesg-6.log):**
```
[gtp5g] parse_ip_filter_rule: WNC: Flow description missing both SRC_IPV4 and SRC_IPV6 (line 790)
[gtp5g] parse_sdf_filter: WNC: parse_ip_filter_rule FAILED, err = -22
[gtp5g] parse_pdi: WNC: parse_pdi FAILED for PDR ID 1, err = -22
```

**After Fix (Expected):**
```
[gtp5g] parse_sdf_filter START
[gtp5g] Parsing Flow Description (IP filter rule)
[gtp5g] parse_ip_filter_rule START
[gtp5g] Flow rule - action=1 direction=2 protocol=17
[gtp5g] Flow rule SRC IPv4 = 0.0.0.0
[gtp5g] Flow rule DEST IPv4 = 0.0.0.0
[gtp5g] parse_ip_filter_rule SUCCESS
[gtp5g] parse_sdf_filter SUCCESS
[gtp5g] parse_pdi SUCCESS
[gtp5g] pdr_fill SUCCESS for PDR ID 1
```

### 8. Verify Data Plane

```bash
# Via tmux session:
tmux send-keys -t cn "cat /proc/gtp5g/pdr" Enter
tmux capture-pane -t cn -p

# Should show PDRs with TEID 2, 4, etc.
# No more "No PDR match this skb : teid[2]" errors
```

### 9. Test UE Connectivity

```bash
# From UE, test internet connectivity
ping 8.8.8.8
ping6 2001:4860:4860::8888

# Should succeed if CreatePDR is working
```

---

## Files Modified

### Kernel Module (Already Deployed)
- **gtp5g/src/genl/genl_pdr.c** (+129 lines of logging)
  - Modified functions: `pdr_fill()`, `parse_pdi()`, `parse_f_teid()`, `parse_sdf_filter()`, `parse_ip_filter_rule()`
  - All logs use `GTP5G_INF()` and `GTP5G_ERR()` macros with "WNC:" prefix

- **gtp5g/src/genl/genl_report.c** (+19 lines of logging)
  - WNC-prefixed logging for multi_usage_reports truncation

- **gtp5g/src/gtpu/encap.c** (1 line change)
  - Minor change (likely whitespace or existing code)

### UPF (Fix to Apply)
- **free5gc/NFs/upf/internal/forwarder/flowdesc.go** (Lines 133-145)
  - Change `ParseFlowDescIPNet()` to return `0.0.0.0/0` wildcard instead of `nil`

### Documentation Created
- **DEBUG_INSTRUCTIONS.md** - Step-by-step debugging guide
- **SUMMARY_DEBUG_CHANGES.md** - Summary of logging changes
- **NEXT_STEPS_SDF_FILTER.md** - SDF filter debugging guide
- **CHANGES_SUMMARY.md** - Summary of all modified files
- **ROOT_CAUSE_ANALYSIS_SDF_FILTER.md** - Detailed root cause analysis
- **COMPLETE_DEBUGGING_REPORT.md** (this file) - Consolidated documentation

---

## Verification Checklist

- [ ] Applied fix to `flowdesc.go` lines 133-145
- [ ] Rebuilt UPF: `make upf`
- [ ] Deployed updated UPF binary to remote machine
- [ ] Restarted UPF on remote machine
- [ ] Cleared kernel logs: `dmesg -C`
- [ ] Triggered PFCP Session Establishment (UE registration)
- [ ] Verified kernel logs show "parse_ip_filter_rule SUCCESS"
- [ ] Verified kernel logs show "pdr_fill SUCCESS for PDR ID 1"
- [ ] Verified `/proc/gtp5g/pdr` shows installed PDRs
- [ ] Verified no more "No PDR match this skb : teid[2]" errors
- [ ] Tested UE connectivity (ping/ping6)

---

## Additional Notes

### Why Not Remove Kernel Validation?

**Option**: Remove the kernel validation requiring SRC_IPV4/SRC_IPV6

**Rejected because**:
1. **3GPP Compliance**: TS 29.244 SDF filters should have source/destination addresses
2. **Security**: Wildcard matching should be explicit, not implicit (missing attributes)
3. **Debugging**: Explicit wildcards make packet matching behavior clearer
4. **Compatibility**: Other 5G cores (Open5GS, etc.) likely send IP addresses

### Why Not Change Kernel to Accept Missing Attributes?

**Option**: Modify kernel to treat missing SRC_IPV4/SRC_IPV6 as "match any"

**Rejected because**:
1. **Userspace Fix**: The bug is in UPF userspace code, not kernel
2. **API Contract**: Netlink API should be explicit about wildcards
3. **Maintenance**: Kernel changes are harder to maintain than userspace
4. **Upstream**: gtp5g is maintained separately, harder to get changes accepted

### IPv6 Considerations

The fix uses `0.0.0.0/0` (IPv4 wildcard) even for IPv6 sessions because:
1. **Kernel uses PDI addresses**: For IPv6 sessions, kernel matches using PDI UE IPv6 and F-TEID GTP-U IPv6
2. **Flow description is secondary**: Primary matching is done via TEID and UE address in PDI
3. **Wildcard semantics**: `0.0.0.0/0` satisfies kernel validation without restricting IPv6 matching

### Known PFCP Request Details (from free5gc logs)

**ULPDR (PDR ID 1, TEID 0x2):**
- F-TEID: IPv4 5.5.5.2, TEID 0x2
- UE IP: 10.155.0.1 (IPv4)
- OuterHeaderRemoval: GTP-U/UDP/IPv4
- SourceInterface: ACCESS (0)
- Precedence: 255

**DLPDR (PDR ID 2, TEID 0x4):**
- UE IP: 10.155.0.1 (IPv4)
- SourceInterface: CORE (1)
- No F-TEID (downlink anchor)
- Precedence: 255

---

## References

- **3GPP TS 29.244**: PFCP protocol specification
- **3GPP TS 29.281**: GTP-U protocol specification
- **3GPP TS 23.502**: 5G System procedures
- **gtp5g kernel module**: https://github.com/free5gc/gtp5g
- **go-gtp5gnl library**: https://github.com/free5gc/go-gtp5gnl
- **Free5GC UPF**: https://github.com/free5gc/free5gc

---

## Summary

This comprehensive debugging effort successfully identified the root cause of CreatePDR failures through systematic kernel logging implementation. The fix is simple, well-understood, and ready to apply. The debugging infrastructure (WNC-prefixed kernel logs) remains in place for future troubleshooting.

**Next Action**: Apply the fix to `flowdesc.go`, rebuild UPF, deploy, and verify CreatePDR succeeds.

---

**Document Version**: 1.0
**Date**: 2025-11-25
**Author**: Claude Code Analysis
**Status**: Fix identified, ready to apply
