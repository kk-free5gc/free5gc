# Router Solicitation Monitoring - Per-DNN Configuration

## Overview

This document describes the implementation of per-DNN Router Solicitation (RS) monitoring in the Free5GC SMF. This feature allows independent control of RS event reporting for each DNN, working independently of CHF (Charging Function) configuration.

**Implementation Date**: December 9, 2025
**Author**: WNC Team
**Related 3GPP Specs**: TS 29.244 (PFCP), TS 24.501 (NAS)

---

## Problem Statement

### Original Issue

In the original Free5GC implementation, URRs (Usage Reporting Rules) were only created when CHF charging was configured. This created a fundamental problem for Router Solicitation monitoring:

```
Without CHF enabled:
  → node.UpLinkTunnel.PDR.URR stays nil
  → urrList loop in processor/datapath.go appends nothing
  → PFCP builder never emits a Create URR IE
  → No URR on uplink PDR = no place to attach Event Reporting IE
  → UPF never gets told "report Event ID 26"
  → Kernel and SMF never see Router Solicitation events
```

### Root Cause

URRs are only created in two scenarios:
1. **CHF Charging Path**: When `smContext.UrrReportTime != 0 || smContext.UrrReportThreshold != 0`
2. **No other path**: No mechanism to create URRs for event reporting without charging

This tight coupling between URRs and charging meant that Router Solicitation event reporting was impossible when CHF was disabled.

---

## Solution Architecture

### Design Principles

1. **Independent Operation**: RS monitoring works regardless of CHF configuration
2. **Per-DNN Control**: Each DNN can independently enable/disable RS monitoring
3. **Clean Separation**: RS monitoring URRs are separate from CHF charging URRs
4. **CHF Compatibility**: Existing CHF behavior remains completely unchanged
5. **State Persistence**: RS monitoring flag persists in SMContext, surviving UPF pointer churn

### Key Components

#### 1. Configuration Schema (`routerSolicitationMonitor` flag)

**Location**: `DnnUpfInfoItem` in UPF configuration

**Files Modified**:
- `/NFs/smf/pkg/factory/config.go:591` - Factory config schema
- `/NFs/smf/internal/context/snssai_dnn_smf_info.go:15` - Top-level SMF context
- `/NFs/smf/internal/context/snssai.go:41` - UPF-level context

**Example Configuration**:
```yaml
userplaneInformation:
  upNodes:
    UPF:
      sNssaiUpfInfos:
        - sNssai:
            sst: 1
          dnnUpfInfoList:
            - dnn: fast.t-mobile.com
              ipv6Pools:
                - prefix: 2001:db8:0111::/48
                  uePrefixLength: 64
              routerSolicitationMonitor: true  # Enable RS monitoring for this DNN
```

#### 2. URR Type Extension (`RS_MONITOR_URR`)

**Location**: `/NFs/smf/internal/context/sm_context.go:44-54`

**New URR Type**:
```go
const (
    N3N6_MBQE_URR UrrType = iota
    N3N6_MAQE_URR
    N3N9_MBQE_URR
    N3N9_MAQE_URR
    N9N6_MBQE_URR
    N9N6_MAQE_URR
    RS_MONITOR_URR // WNC: Router Solicitation monitoring URR (independent of CHF)
    NOT_FOUND_URR
)
```

**Properties**:
- `IsBeforeQos()`: Returns `false` (RS monitoring is after QoS)
- `Direct()`: Returns `"N3N6"` (uses N3-N6 path)
- `String()`: Returns `"RS_MONITOR"`

#### 3. SMContext State Persistence

**Location**: `/NFs/smf/internal/context/sm_context.go:186-191`

**New Field**:
```go
type SMContext struct {
    // ... existing fields ...

    DNNInfo *SnssaiSmfDnnInfo

    // WNC: Router Solicitation monitoring flag (persisted from DNN config)
    // This flag is set during session creation and persists regardless of SelectedUPF state
    // Avoids repeated config tree traversal and survives UPF pointer churn (handover, release, etc.)
    EnableRouterSolicitationMonitor bool

    // ... more fields ...
}
```

**Why Persist in SMContext?**

1. **Survives UPF Churn**: `SelectedUPF` is cleared during handover, release, and error recovery. The flag persists regardless.
2. **Avoids Repeated Lookups**: Multiple callers need this flag. Persisting it eliminates duplicate config tree traversal.
3. **Consistent Decisions**: The session always knows "this DNN requested RS monitoring" regardless of current UPF pointer state.

**Population Logic** (`populateRouterSolicitationMonitorFlag()`):
```go
// Called after SelectedUPF is assigned (sm_context.go:859)
func (c *SMContext) populateRouterSolicitationMonitorFlag() {
    // 1. Try UPF configuration first (most authoritative)
    if c.SelectedUPF != nil && c.SelectedUPF.UPF != nil {
        // Traverse SNssaiInfos → DnnList to find flag
    }

    // 2. Fallback to top-level DNNInfo
    if c.DNNInfo != nil {
        c.EnableRouterSolicitationMonitor = c.DNNInfo.RouterSolicitationMonitor
    }

    // 3. Default to false if not found
}
```

#### 4. URR Creation in Datapath

**Location**: `/NFs/smf/internal/context/datapath.go:409-500`

**Function**: `addRSMonitorUrrToPath(smContext *SMContext)`

**Call Site**: `ActivateTunnelAndPDR()` at line 439 (after tunnel activation, before PDR activation)

**Logic Flow**:
```go
func (datapath *DataPath) addRSMonitorUrrToPath(smContext *SMContext) {
    // 1. Check IPv6 support
    if !hasIPv6 { return }

    // 2. Check persisted flag (no config tree traversal!)
    if !smContext.EnableRouterSolicitationMonitor { return }

    // 3. Allocate URR ID
    if id, err := smContext.UrrIDGenerator.Allocate(); err == nil {
        smContext.UrrIdMap[RS_MONITOR_URR] = uint32(id)
    }

    // 4. Create URR with minimal configuration
    urr, err := curDataPathNode.UPF.AddURR(rsMonitorUrrId,
        NewMeasureInformation(true, false))  // Only MeasureMethod

    // 5. Set ReportingTriggers.Start = true
    urr.ReportingTrigger.Start = true

    // 6. Attach to uplink PDR only (detect RS from UE)
    curDataPathNode.UpLinkTunnel.PDR.AppendURRs([]*URR{urr})
}
```

**Key Design Decisions**:

1. **No MeasurementPeriod/VolumeThreshold**: Calling `NewMeasurementPeriod(0)` or `NewVolumeThreshold(0)` sets trigger bits but doesn't emit PFCP IEs, violating TS 29.244. We only need `Start` and `Eveth` triggers.

2. **Uplink PDR Only**: RS packets come from UE, so we only attach the URR to the uplink PDR.

3. **Anchor UPF Only**: Only PSA (anchor) UPF needs RS monitoring, not intermediate UPFs.

#### 5. PFCP Message Construction

**Location**: `/NFs/smf/internal/pfcp/message/build.go:232-286`

**Function**: `urrToCreateURR(urr *context.URR, pdrID uint16, smContext *context.SMContext)`

**Logic Flow**:
```go
// WNC: Router Solicitation Monitoring - Why we need RouterSolicitationMonitor flag
//
// PROBLEM: In the original code, URRs are only created when charging (CHF) is configured.
// If we run without charging, node.UpLinkTunnel.PDR.URR stays nil, the urrList loop in
// processor/datapath.go appends nothing, and the PFCP builder never emits a Create URR IE.
// No URR on the uplink PDR means there is no place to hang the Event Reporting IE, so the
// UPF never gets told "report Event ID 26", and neither the kernel nor the SMF ever see a
// Router Solicitation event.
//
// SOLUTION: The RouterSolicitationMonitor flag allows creating a URR unconditionally
// (even when CHF is disabled) specifically for Router Solicitation event reporting.
// This ensures RS monitoring works independently of charging configuration.

if pdrID != 0 && smContext != nil {
    // WNC: Check if this URR is the dedicated RS monitoring URR
    // Do NOT add RS event reporting to CHF charging URRs (MBQE/MAQE)
    rsMonitorUrrId, rsMonitorExists := smContext.UrrIdMap[context.RS_MONITOR_URR]
    if rsMonitorExists && urr.URRID == rsMonitorUrrId {
        // This is the RS monitoring URR - add event reporting
        createURR.EventInformation = &pfcp.EventInformation{
            EventID: &pfcpType.EventID{
                EventId: context.EventIDRouterSolicitation,
            },
            EventThreshold: &pfcpType.EventThreshold{
                EventThreshold: 1, // Trigger on first RS
            },
        }

        // Set Eveth bit in ReportingTriggers
        if createURR.ReportingTriggers == nil {
            createURR.ReportingTriggers = &pfcpType.ReportingTriggers{}
        }
        createURR.ReportingTriggers.Eveth = true
    }
}
```

**Critical Design Point**: Only add RS event reporting to `RS_MONITOR_URR`, not to CHF charging URRs (MBQE/MAQE). This keeps CHF behavior completely unchanged.

---

## Separation of Concerns - Option A Design

### Why Split ReportingTrigger Configuration?

The implementation uses **Option A**: Split responsibility between datapath and PFCP builder.

#### Datapath Layer (`addRSMonitorUrrToPath`)
- **Purpose**: Create URR structure and set generic reporting triggers
- **Sets**: `ReportingTrigger.Start = true`
  - Generic trigger that applies to all URRs
  - Part of URR's basic configuration
  - Independent of specific events being monitored

#### PFCP Builder Layer (`urrToCreateURR`)
- **Purpose**: Build PFCP message and add RS-specific event reporting
- **Sets**: `ReportingTriggers.Eveth = true` + `EventInformation` with Event ID 26
  - RS-specific configuration
  - Only applies to RS_MONITOR_URR
  - Added during PFCP message construction with full context

### Rationale

**Pros of Option A**:
- Clean separation: Datapath doesn't know about PFCP protocol details
- Flexible: Can conditionally add Eveth based on other factors
- Layered: URR creation logic separate from PFCP message construction

**Alternative (Option B)**: Set both `Start` and `Eveth` in datapath
- **Pros**: All trigger configuration in one place, more explicit
- **Cons**: Datapath layer knows about RS-specific PFCP details, less flexible

**Decision**: Keep Option A for better separation of concerns and flexibility.

---

## Configuration Propagation Flow

```
1. YAML Config (smfcfg.yaml)
   ↓
2. Factory Config (factory.DnnUpfInfoItem)
   ↓
3. UPF Context (context.DnnUPFInfoItem)
   ↓ (during user_plane_information.go loading)
4. SMContext (SMContext.EnableRouterSolicitationMonitor)
   ↓ (during UPF selection in sm_context.go:859)
5. URR Creation (addRSMonitorUrrToPath checks flag)
   ↓
6. PFCP Message (urrToCreateURR adds EventInformation)
```

**Key Files**:
1. `/NFs/smf/pkg/factory/config.go:591` - Schema definition
2. `/NFs/smf/internal/context/user_plane_information.go:221-230, 551-560` - Config loading
3. `/NFs/smf/internal/context/sm_context.go:859` - Flag population
4. `/NFs/smf/internal/context/datapath.go:439` - URR creation
5. `/NFs/smf/internal/pfcp/message/build.go:255-286` - PFCP message construction

---

## PFCP Compliance (TS 29.244)

### Correct URR Configuration

**What We Send**:
```
Create URR:
  URR ID: <allocated_id>
  Measurement Method: Volume = 1
  Measurement Information: MBQE = 0, ISTM = 0, MNOP = 0, RADI = 0, INAM = 0, SSPOC = 0
  Reporting Triggers: Start = 1, Eveth = 1
  Event Information:
    Event ID: 26 (Router Solicitation)
    Event Threshold: 1
```

**What We DON'T Send** (avoiding TS 29.244 violations):
- ❌ `Measurement Period` IE (would require `Perio` trigger bit)
- ❌ `Volume Threshold` IE (would require `Volth` trigger bit)

**Why This Matters**:
- TS 29.244 §8.2.56/§8.2.55 require that when `Perio` or `Volth` trigger bits are set, the corresponding IEs must be present
- Setting trigger bits without IEs causes UPFs to reject or ignore the URR
- We only need `Start` and `Eveth` for RS monitoring, so we don't set `Perio` or `Volth`

### Event Reporting (TS 29.244 §5.8.2)

**Critical Requirement**: Event Information IE is only acted upon when `Eveth` or `Evequ` is set in ReportingTriggers.

**Our Implementation**:
```go
// Set Eveth bit to activate event reporting
if createURR.ReportingTriggers == nil {
    createURR.ReportingTriggers = &pfcpType.ReportingTriggers{}
}
createURR.ReportingTriggers.Eveth = true
```

Without `Eveth = true`, the UPF would ignore the Event Information IE, and RS events would never be reported.

---

## Testing and Verification

### Build Verification

```bash
cd /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc
make smf
```

**Expected Result**: Clean build with no compilation errors.

### Configuration Example

```yaml
# /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc/config/smfcfg.yaml

userplaneInformation:
  upNodes:
    UPF:
      type: UPF
      nodeID: 127.0.0.8
      sNssaiUpfInfos:
        - sNssai:
            sst: 1
          dnnUpfInfoList:
            - dnn: fast.t-mobile.com
              pduSessionTypes:
                defaultSessionType: IPV4V6
                allowedSessionTypes:
                  - IPV4
                  - IPV6
                  - IPV4V6
              ipv6Pools:
                - prefix: 2001:db8:0111::/48
                  uePrefixLength: 64
                  iidAllocation: random
                  raProfile: default
              routerSolicitationMonitor: true  # WNC: Enable RS monitoring
```

### Runtime Verification

**Expected Log Messages** (with WNC prefix):

1. **During Session Creation**:
   ```
   [INFO][SMContext] WNC: Set EnableRouterSolicitationMonitor=true from UPF config (DNN: fast.t-mobile.com)
   ```

2. **During URR Creation**:
   ```
   [INFO][PduSess] WNC: Allocated URR ID 7 for Router Solicitation monitoring (DNN: fast.t-mobile.com)
   [INFO][PduSess] WNC: Created RS monitor URR 7 for UPF <uuid> (DNN: fast.t-mobile.com, triggers: Start=true, Eveth will be added in PFCP builder)
   [INFO][PduSess] WNC: Attached RS monitor URR 7 to uplink PDR 1 (DNN: fast.t-mobile.com)
   ```

3. **During PFCP Message Construction**:
   ```
   [INFO][SMContext] WNC: Added Event Reporting (Event ID 26 - Router Solicitation) to RS_MONITOR_URR 7, PDR 1 for IPv6 session (DNN fast.t-mobile.com), Eveth=true
   ```

4. **When RS Monitoring is Disabled**:
   ```
   [DEBUG][PduSess] WNC: Skipping RS monitor URR creation - RouterSolicitationMonitor disabled for DNN internet
   ```

### PFCP Packet Capture

**Capture Command**:
```bash
tcpdump -ni <N4_interface> port 8805 -w pfcp_capture.pcap
```

**What to Look For**:
1. **PFCP Session Establishment Request** should contain:
   - Create URR IE with URR ID matching RS_MONITOR_URR
   - Reporting Triggers with `Start=1, Eveth=1`
   - Event Information with Event ID = 26
   - Event Threshold = 1

2. **Verify No Violations**:
   - No `Measurement Period` IE when `Perio` bit is not set
   - No `Volume Threshold` IE when `Volth` bit is not set

---

## CHF Compatibility

### Coexistence with Charging

**When CHF is Enabled**:
- CHF creates its own URRs (MBQE, MAQE) with charging-specific configuration
- RS monitoring creates separate `RS_MONITOR_URR` with event reporting
- Both URRs coexist on the same uplink PDR
- **Critical**: `urrToCreateURR` only adds RS event reporting to `RS_MONITOR_URR`, not to CHF URRs

**When CHF is Disabled**:
- No CHF URRs are created
- Only `RS_MONITOR_URR` is created (if `routerSolicitationMonitor: true`)
- RS monitoring works independently

### URR List on Uplink PDR

**With CHF + RS Monitoring**:
```
Uplink PDR:
  URR[0]: N3N6_MBQE_URR (CHF charging, before QoS)
  URR[1]: N3N6_MAQE_URR (CHF charging, after QoS)
  URR[2]: RS_MONITOR_URR (RS event reporting, after QoS)
```

**Without CHF, With RS Monitoring**:
```
Uplink PDR:
  URR[0]: RS_MONITOR_URR (RS event reporting, after QoS)
```

**Without CHF, Without RS Monitoring**:
```
Uplink PDR:
  URR: (empty - no URRs created)
```

---

## Implementation Summary

### Files Modified

| File | Lines | Purpose |
|------|-------|---------|
| `/NFs/smf/pkg/factory/config.go` | 591 | Add `RouterSolicitationMonitor` to factory config schema |
| `/NFs/smf/internal/context/snssai_dnn_smf_info.go` | 15 | Add flag to top-level SMF DNN info |
| `/NFs/smf/internal/context/snssai.go` | 41 | Add flag to UPF-level DNN context |
| `/NFs/smf/internal/context/user_plane_information.go` | 221-230, 551-560 | Propagate flag from factory config to context |
| `/NFs/smf/internal/context/sm_context.go` | 44-78, 186-191, 859, 1723-1756 | Add URR type, SMContext field, population logic |
| `/NFs/smf/internal/context/datapath.go` | 409-500, 439 | Create RS monitoring URR, attach to uplink PDR |
| `/NFs/smf/internal/pfcp/message/build.go` | 232-286 | Add RS event reporting to PFCP message |
| `/config/smfcfg.yaml` | 315 | Example configuration |

### Total Changes

- **8 files modified**
- **~300 lines added** (including comments and documentation)
- **0 lines removed** (backward compatible)
- **0 breaking changes**

### Key Features

✅ **Per-DNN Control**: Each DNN independently enables/disables RS monitoring
✅ **CHF Independent**: Works with or without CHF charging
✅ **CHF Compatible**: Coexists with CHF URRs without interference
✅ **State Persistence**: Flag survives UPF pointer churn
✅ **PFCP Compliant**: Follows TS 29.244 requirements
✅ **WNC Logging**: All operations use "WNC:" prefix for tracing
✅ **Backward Compatible**: No impact on existing functionality

---

## Troubleshooting

### Issue: RS Events Not Reported

**Symptoms**: No "Router Solicitation event" logs in SMF

**Checklist**:
1. ✅ `routerSolicitationMonitor: true` in config for the DNN?
2. ✅ Session is IPv6 or IPv4v6?
3. ✅ URR creation logs show "Created RS monitor URR"?
4. ✅ PFCP message logs show "Added Event Reporting (Event ID 26)"?
5. ✅ PFCP capture shows Create URR IE with Event ID 26?
6. ✅ UPF supports Event ID 26 (Router Solicitation)?

### Issue: Build Failures

**Symptoms**: Compilation errors

**Common Causes**:
- Missing import for `nasMessage` in `datapath.go`
- Incorrect URR type enum order
- Missing WNC comments

**Solution**: Check all modified files match the implementation exactly.

### Issue: CHF URRs Have RS Event Reporting

**Symptoms**: CHF charging URRs show Event ID 26 in PFCP capture

**Root Cause**: `urrToCreateURR` not checking URR ID before adding event reporting

**Solution**: Verify the URR ID check at `build.go:258-259`:
```go
rsMonitorUrrId, rsMonitorExists := smContext.UrrIdMap[context.RS_MONITOR_URR]
if rsMonitorExists && urr.URRID == rsMonitorUrrId {
    // Only add to RS_MONITOR_URR
}
```

### Issue: UPF Rejects Create URR

**Symptoms**: PFCP Session Establishment fails

**Common Causes**:
- `Perio` or `Volth` trigger bits set without corresponding IEs
- Missing `Eveth` bit when Event Information is present

**Solution**: Verify URR creation uses only `NewMeasureInformation()`, not `NewMeasurementPeriod(0)` or `NewVolumeThreshold(0)`.

---

## Future Enhancements

### Potential Improvements

1. **Dynamic Enable/Disable**: Allow runtime toggling of RS monitoring without session restart
2. **Event Threshold Configuration**: Make Event Threshold configurable per DNN
3. **Multiple Event Types**: Support other event types (e.g., Neighbor Solicitation)
4. **Statistics**: Track RS event counts per DNN
5. **Policy Integration**: Integrate with PCF for dynamic RS monitoring policies

### 3GPP Compliance Extensions

1. **Event Quota**: Support Event Quota IE (TS 29.244 §8.2.134)
2. **Event Time Stamp**: Include Event Time Stamp in usage reports
3. **Additional Events**: Support full event reporting catalog (TS 29.244 Table 8.2.133-1)

---

## References

### 3GPP Specifications

- **TS 29.244**: PFCP (Packet Forwarding Control Protocol)
  - §5.8.2: Event Reporting
  - §8.2.55: Measurement Period IE
  - §8.2.56: Volume Threshold IE
  - §8.2.133: Event ID IE
  - §8.2.134: Event Threshold IE
  - Table 8.2.133-1: Event ID values

- **TS 24.501**: NAS Protocol for 5GS
  - PDU Session Type definitions

- **TS 23.502**: Procedures for 5G System
  - Session management procedures

### Free5GC Documentation

- **Free5GC Guide**: https://free5gc.org/guide/
- **SMF Architecture**: https://free5gc.org/guide/Smf/design/
- **PFCP Implementation**: Internal documentation

### Related Features

- **IPv6 Router Advertisement**: `/docs/ipv6-feature/router-advertisement.md`
- **UE Policy Control**: `/CLAUDE.md` (UE Policy Control Flow section)
- **CHF Integration**: `/docs/charging/chf-integration.md`

---

## Appendix: Complete Code Snippets

### A. URR Creation (datapath.go)

```go
// WNC: Add Router Solicitation monitoring URR to datapath (independent of CHF charging)
// This function creates a URR specifically for RS event reporting when routerSolicitationMonitor is enabled
func (datapath *DataPath) addRSMonitorUrrToPath(smContext *SMContext) {
	// Check if session has IPv6 support
	hasIPv6 := smContext.SelectedPDUSessionType == nasMessage.PDUSessionTypeIPv6 ||
		smContext.SelectedPDUSessionType == nasMessage.PDUSessionTypeIPv4IPv6

	if !hasIPv6 {
		logger.PduSessLog.Debugf("WNC: Skipping RS monitor URR creation - session is not IPv6")
		return
	}

	// WNC: Use persisted flag from SMContext instead of traversing config tree
	// This avoids repeated lookups and works even when SelectedUPF is nil
	if !smContext.EnableRouterSolicitationMonitor {
		logger.PduSessLog.Debugf("WNC: Skipping RS monitor URR creation - RouterSolicitationMonitor disabled for DNN %s",
			smContext.Dnn)
		return
	}

	// Allocate URR ID for RS monitoring
	if _, exists := smContext.UrrIdMap[RS_MONITOR_URR]; !exists {
		if id, err := smContext.UrrIDGenerator.Allocate(); err == nil {
			smContext.UrrIdMap[RS_MONITOR_URR] = uint32(id)
			logger.PduSessLog.Infof("WNC: Allocated URR ID %d for Router Solicitation monitoring (DNN: %s)",
				id, smContext.Dnn)
		} else {
			logger.PduSessLog.Errorf("WNC: Failed to allocate URR ID for RS monitoring: %v", err)
			return
		}
	}

	rsMonitorUrrId := smContext.UrrIdMap[RS_MONITOR_URR]

	// Add RS monitoring URR to uplink PDR only (to detect RS from UE)
	for curDataPathNode := datapath.FirstDPNode; curDataPathNode != nil; curDataPathNode = curDataPathNode.Next() {
		// Only add to anchor UPF (PSA)
		if curDataPathNode.IsAnchorUPF() {
			var urr *URR
			var ok bool
			var err error
			currentUUID := curDataPathNode.UPF.UUID()
			id := getUrrIdKey(currentUUID, rsMonitorUrrId)

			if urr, ok = smContext.UrrUpfMap[id]; !ok {
				// WNC: Create URR with minimal configuration for RS event reporting only
				// Only set MeasureMethod and ReportingTriggers.Start
				// Do NOT set MeasurementPeriod or VolumeThreshold to avoid TS 29.244 violations
				// (setting trigger bits without corresponding IEs)
				if urr, err = curDataPathNode.UPF.AddURR(rsMonitorUrrId,
					NewMeasureInformation(true, false)); err != nil { // Measure volume, after QoS
					logger.PduSessLog.Errorf("WNC: Failed to create RS monitor URR: %v", err)
					return
				}

				// WNC: Set ReportingTriggers.Start = true for session start reporting
				// Eveth will be set later in urrToCreateURR when building PFCP message
				urr.ReportingTrigger.Start = true

				smContext.UrrUpfMap[id] = urr
				logger.PduSessLog.Infof("WNC: Created RS monitor URR %d for UPF %s (DNN: %s, triggers: Start=true, Eveth will be added in PFCP builder)",
					rsMonitorUrrId, currentUUID, smContext.Dnn)
			}

			// Attach URR to uplink PDR only (to detect RS from UE)
			if curDataPathNode.UpLinkTunnel != nil && curDataPathNode.UpLinkTunnel.PDR != nil {
				curDataPathNode.UpLinkTunnel.PDR.AppendURRs([]*URR{urr})
				logger.PduSessLog.Infof("WNC: Attached RS monitor URR %d to uplink PDR %d (DNN: %s)",
					rsMonitorUrrId, curDataPathNode.UpLinkTunnel.PDR.PDRID, smContext.Dnn)
			}
		}
	}
}
```

### B. PFCP Message Construction (build.go)

```go
// WNC: Router Solicitation Monitoring - Why we need RouterSolicitationMonitor flag
//
// PROBLEM: In the original code, URRs are only created when charging (CHF) is configured.
// If we run without charging, node.UpLinkTunnel.PDR.URR stays nil, the urrList loop in
// processor/datapath.go appends nothing, and the PFCP builder never emits a Create URR IE.
// No URR on the uplink PDR means there is no place to hang the Event Reporting IE, so the
// UPF never gets told "report Event ID 26", and neither the kernel nor the SMF ever see a
// Router Solicitation event.
//
// SOLUTION: The RouterSolicitationMonitor flag allows creating a URR unconditionally
// (even when CHF is disabled) specifically for Router Solicitation event reporting.
// This ensures RS monitoring works independently of charging configuration.
//
// WNC: Add Event Reporting for Router Solicitation (Event ID 26) for IPv6 sessions
// CRITICAL: Only add to the dedicated RS_MONITOR_URR to keep CHF URRs unchanged
// Only add for uplink PDR (pdrID != 0) to detect RS from UE
if pdrID != 0 && smContext != nil {
	// WNC: Check if this URR is the dedicated RS monitoring URR
	// Do NOT add RS event reporting to CHF charging URRs (MBQE/MAQE)
	rsMonitorUrrId, rsMonitorExists := smContext.UrrIdMap[context.RS_MONITOR_URR]
	if rsMonitorExists && urr.URRID == rsMonitorUrrId {
		// This is the RS monitoring URR - add event reporting
		// Event ID = Router Solicitation (3GPP TS 29.244 Section 8.2.133)
		createURR.EventInformation = &pfcp.EventInformation{
			EventID: &pfcpType.EventID{
				EventId: context.EventIDRouterSolicitation,
			},
			EventThreshold: &pfcpType.EventThreshold{
				EventThreshold: 1, // Trigger on first RS
			},
		}

		// WNC: CRITICAL - Set Eveth bit in ReportingTriggers per TS 29.244 §5.8.2
		// The Event Information IE is only acted upon when Eveth or Evequ is set
		// We must update the ReportingTriggers to activate event reporting
		if createURR.ReportingTriggers == nil {
			createURR.ReportingTriggers = &pfcpType.ReportingTriggers{}
		}
		createURR.ReportingTriggers.Eveth = true

		smContext.Log.Infof("WNC: Added Event Reporting (Event ID 26 - Router Solicitation) to RS_MONITOR_URR %d, PDR %d for IPv6 session (DNN %s), Eveth=true",
			urr.URRID, pdrID, smContext.Dnn)
	} else {
		// This is a CHF charging URR or other URR - do NOT add RS event reporting
		smContext.Log.Debugf("WNC: Skipping RS Event Reporting for URR %d (not RS_MONITOR_URR), PDR %d",
			urr.URRID, pdrID)
	}
}
```

### C. Flag Population (sm_context.go)

```go
// WNC: populateRouterSolicitationMonitorFlag reads the routerSolicitationMonitor flag from DNN config
// and persists it in SMContext. This avoids repeated config tree traversal and ensures the flag
// survives UPF pointer churn (handover, release, error recovery, etc.)
func (c *SMContext) populateRouterSolicitationMonitorFlag() {
	// Default to false
	c.EnableRouterSolicitationMonitor = false

	// Try to read from UPF configuration first (most authoritative source)
	if c.SelectedUPF != nil && c.SelectedUPF.UPF != nil {
		for _, snssaiInfo := range c.SelectedUPF.UPF.SNssaiInfos {
			if snssaiInfo == nil || !snssaiInfo.SNssai.EqualModelsSnssai(c.SNssai) {
				continue
			}
			for _, dnnInfo := range snssaiInfo.DnnList {
				if dnnInfo != nil && dnnInfo.Dnn == c.Dnn {
					c.EnableRouterSolicitationMonitor = dnnInfo.RouterSolicitationMonitor
					c.Log.Infof("WNC: Set EnableRouterSolicitationMonitor=%v from UPF config (DNN: %s)",
						c.EnableRouterSolicitationMonitor, c.Dnn)
					return
				}
			}
		}
	}

	// Fallback: try to read from top-level DNN info (if UPF config not available)
	if c.DNNInfo != nil {
		c.EnableRouterSolicitationMonitor = c.DNNInfo.RouterSolicitationMonitor
		c.Log.Infof("WNC: Set EnableRouterSolicitationMonitor=%v from DNNInfo (DNN: %s)",
			c.EnableRouterSolicitationMonitor, c.Dnn)
		return
	}

	c.Log.Debugf("WNC: RouterSolicitationMonitor not found in config, defaulting to false (DNN: %s)", c.Dnn)
}
```

---

**End of Document**
