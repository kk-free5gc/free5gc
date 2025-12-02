# go-gtp5gnl Instrumentation Fixes

## Overview

This document describes the instrumentation and fixes applied to `go-gtp5gnl/report.go` to diagnose and resolve the kernel truncation issue:

```
[gtp5g] gtp1u_udp_encap_recv: No PDR match this skb : teid[2]
[gtp5g] gtp5g_genl_get_multi_usage_reports: WNC:multi_usage_reports truncated: URR_NUM=4 parsed=3 remaining=0
```

## Root Cause Analysis

The truncation occurred because:

1. **Missing SEID validation**: OIDs without SEID were silently skipped during TLV construction, creating a mismatch between `URR_NUM` (set to `len(oids)`) and actual TLV count sent to kernel
2. **No visibility**: No logging of actual TLVs sent, making it impossible to correlate userland requests with kernel warnings
3. **Silent failures**: Kernel rejections (0 reports returned) were treated as success, preventing proper error handling

## Fixes Applied

### 1. Fail-Fast Validation (Issue #2 from review)

**Location**: `go-gtp5gnl/report.go:157-179`

**Problem**: Code silently skipped OIDs without SEID, creating URR_NUM mismatch.

**Solution**: Validate all OIDs BEFORE any netlink operations and fail immediately on invalid OIDs.

```go
func getMultiReportsOIDChunk(c *Client, link *Link, oids []OID, chunkOffset int) ([]USAReport, error) {
    // WNC: Validate all OIDs BEFORE test hook or netlink operations
    for i, oid := range oids {
        urrid, ok := oid.ID()
        if !ok {
            return nil, fmt.Errorf("WNC: chunk[%d] OID[%d] has invalid ID: %v",
                chunkOffset, chunkOffset+i, oid)
        }

        seid, ok := oid.SEID()
        if !ok {
            // WNC: Fail fast - don't silently skip OIDs without SEID
            return nil, fmt.Errorf("WNC: chunk[%d] OID[%d] missing SEID (urrid=%d): %v - caller must provide valid SEID for CMD_GET_MULTI_REPORTS",
                chunkOffset, chunkOffset+i, urrid, oid)
        }

        tlvPairs = append(tlvPairs, oidPair{SEID: seid, URRID: uint32(urrid)})
    }
    // ... rest of function
}
```

**Benefits**:
- Prevents URR_NUM mismatch from ever being created
- Clear error message identifies which caller provided malformed OIDs
- Includes chunk offset for multi-chunk request debugging

### 2. Structured Logging with Debug Flag (Issues #1 and #2 from review)

**Location**: `go-gtp5gnl/report.go:18-29, 241-291`

**Problem**:
- No visibility into actual TLVs sent to kernel
- Verbose logging would flood stdout in production with high-frequency PERIO polling

**Solution**: Add debug flag with environment variable control.

```go
/* WNC: Debug flag to control verbose chunk logging. Set via environment variable
   GTP5GNL_DEBUG=1 or programmatically. When false, only errors are logged. */
var DebugLogging = false

func init() {
    if os.Getenv("GTP5GNL_DEBUG") == "1" {
        DebugLogging = true
    }
}
```

**Logging strategy**:
- **Debug logs** (only when `DebugLogging=true`):
  - TLVs being sent before each request
  - Success confirmations
- **Error logs** (always logged):
  - Netlink errors
  - Decode errors
  - Kernel rejections
  - Truncation warnings

**Usage**:
```bash
# Enable debug logging
export GTP5GNL_DEBUG=1
./upf-binary

# Or in code
gtp5gnl.DebugLogging = true
```

**Example output with debug enabled**:
```
[gtp5g] WNC: chunk[0] sending URR_NUM=4 link=1 TLVs=[{SEID:1000 URRID:1} {SEID:2000 URRID:2} {SEID:3000 URRID:3} {SEID:4000 URRID:4}]
[gtp5g] WNC: chunk[0] SUCCESS - URR_NUM=4, received 4 reports
```

**Example output in production (debug disabled)**:
```
# Only errors are logged
[gtp5g] WNC: chunk[0] REJECTED - sent URR_NUM=4 TLVs=[{SEID:1000 URRID:1} ...], kernel returned 0 reports (check NLMSG_ERROR and dmesg)
```

### 3. Chunk Offset Tracking (Issue #1 from review)

**Location**: `go-gtp5gnl/report.go:130, 142, 157`

**Problem**:
- Test hook couldn't observe chunk offsets
- Error messages didn't include chunk context for multi-chunk requests

**Solution**: Add `chunkOffset` parameter to function signature and test hook.

```go
// Updated function signature
func getMultiReportsOIDChunk(c *Client, link *Link, oids []OID, chunkOffset int) ([]USAReport, error)

// Updated test hook signature
var testChunkHook func(*Client, *Link, []OID, int) ([]USAReport, error)

// Callers pass offset
GetMultiReportsOID:
    if len(oids) <= maxBatchSize {
        return getMultiReportsOIDChunk(c, link, oids, 0)  // Single chunk at offset 0
    }

    for i := 0; i < len(oids); i += maxBatchSize {
        chunk := oids[i:end]
        reports, err := getMultiReportsOIDChunk(c, link, chunk, i)  // Pass chunk offset
        // ...
    }
```

**Benefits**:
- Error messages show `chunk[0] OID[58]` instead of just `OID[2]`
- Easy correlation with netlink sequence numbers in strace
- Tests can verify chunk-level behavior

### 4. Error on Rejection/Truncation (Issue #3 from review)

**Location**: `go-gtp5gnl/report.go:267-291`

**Problem**: When kernel returned 0 reports (rejection) or partial reports (truncation), function returned `(reports, nil)`, making it impossible for callers to detect failures.

**Solution**: Return error for both rejection and truncation cases.

```go
/* WNC: Validate kernel response and return error on rejection or truncation. */
if len(reports) != len(oids) {
    if len(reports) == 0 {
        // WNC: Kernel rejected the entire request
        err := fmt.Errorf("chunk[%d] REJECTED - sent URR_NUM=%d TLVs=%v, kernel returned 0 reports (check NLMSG_ERROR and dmesg)",
            chunkOffset, len(oids), tlvPairs)
        log.Printf("[gtp5g] WNC: %v", err)
        return nil, err
    } else {
        // WNC: Kernel truncated the response
        err := fmt.Errorf("chunk[%d] TRUNCATION - sent URR_NUM=%d TLVs=%v, kernel returned %d reports (partial)",
            chunkOffset, len(oids), tlvPairs, len(reports))
        log.Printf("[gtp5g] WNC: %v", err)
        return nil, err
    }
}

if DebugLogging {
    log.Printf("[gtp5g] WNC: chunk[%d] SUCCESS - URR_NUM=%d, received %d reports",
        chunkOffset, len(oids), len(reports))
}

return reports, nil  // Success case
```

**Benefits**:
- Callers can distinguish success from failure
- Error messages include full TLV list for debugging
- Prevents silent data loss

## Behavior Matrix

| Scenario | DebugLogging=false | DebugLogging=true | Return Value |
|----------|-------------------|-------------------|--------------|
| **Success** | No logs | "chunk[N] sending..." + "chunk[N] SUCCESS..." | `(reports, nil)` |
| **Rejection** | "chunk[N] REJECTED..." | Same + sending log | `(nil, error)` |
| **Truncation** | "chunk[N] TRUNCATION..." | Same + sending log | `(nil, error)` |
| **Netlink error** | "chunk[N] netlink error..." | Same | `(nil, error)` |
| **Decode error** | "chunk[N] decode error..." | Same | `(nil, error)` |
| **Invalid OID** | N/A (fails before netlink) | N/A | `(nil, error)` |

## Migration Guide for Consumers

### Before (Silent Failures)

```go
reports, _ := gtp5gnl.GetMultiReportsOID(client, link, oids)
// Problem: Might get 0 reports on rejection, no way to know!
for _, report := range reports {
    // This loop might never execute
    processReport(report)
}
```

### After (Proper Error Handling)

```go
reports, err := gtp5gnl.GetMultiReportsOID(client, link, oids)
if err != nil {
    if strings.Contains(err.Error(), "REJECTED") {
        log.Printf("Kernel rejected request: %v", err)
        // Check NLMSG_ERROR in netlink response
        // Check dmesg for kernel-side errors
        // Fix malformed TLVs in caller
        return err
    } else if strings.Contains(err.Error(), "TRUNCATION") {
        log.Printf("Kernel truncated response: %v", err)
        // Reduce batch size
        // Check MaxNetlinkUsageReportNum()
        return err
    } else if strings.Contains(err.Error(), "missing SEID") {
        log.Printf("Caller provided invalid OID: %v", err)
        // Fix OID construction in caller
        return err
    }
    return err
}

// reports is guaranteed to match requested OIDs
for _, report := range reports {
    processReport(report)
}
```

## Testing

All existing tests updated and passing:

1. **TestGetMultiReportsOID_FailFastOnMissingSEID**: Verifies fail-fast behavior for invalid OIDs
2. **TestGetMultiReportsOID_ActualChunking**: Verifies chunk offset tracking
3. **TestGetMultiReportsOID_ChunkBoundaries**: Verifies no gaps/overlaps in chunking
4. **TestGetMultiReportsOID_ZeroBatchSizeGuard**: Verifies infinite loop protection
5. All other existing tests updated to use new hook signature

## Debugging Workflow

### Step 1: Enable Debug Logging

```bash
export GTP5GNL_DEBUG=1
./upf-binary 2>&1 | tee upf.log
```

### Step 2: Correlate Logs

Look for patterns like:

```
[gtp5g] WNC: chunk[0] sending URR_NUM=4 link=1 TLVs=[{SEID:1000 URRID:1} {SEID:2000 URRID:2} {SEID:3000 URRID:3} {SEID:4000 URRID:4}]
[gtp5g] WNC: chunk[0] TRUNCATION - sent URR_NUM=4 TLVs=[...], kernel returned 3 reports (partial)
```

### Step 3: Check Kernel Logs

```bash
dmesg | grep gtp5g
```

Look for corresponding kernel warnings:
```
[gtp5g] gtp5g_genl_get_multi_usage_reports: WNC:multi_usage_reports truncated: URR_NUM=4 parsed=3 remaining=0
```

### Step 4: Cross-Reference

- **Userland log** shows which TLVs were sent
- **Kernel log** shows how many were parsed
- **Timestamp correlation** confirms they're related
- **TLV list** in error message shows exact SEID/URRID pairs for investigation

### Step 5: Fix Root Cause

Common issues:
1. **Invalid OIDs**: Error message shows which OID lacks SEID
2. **Message too large**: Reduce `MaxNetlinkUsageReportNum()`
3. **Kernel bug**: TLV list helps reproduce issue in kernel debugging

## Files Modified

- `go-gtp5gnl/report.go`: Core instrumentation and fixes
- `go-gtp5gnl/report_test.go`: Updated all test hooks to new signature

## Commit Message Template

```
fix(gtp5gnl): Add instrumentation and fail-fast validation for multi-reports

Fixes kernel truncation issue where URR_NUM mismatched actual TLV count.

Changes:
- Add fail-fast validation for OIDs without SEID (prevents URR_NUM mismatch)
- Add DebugLogging flag (env: GTP5GNL_DEBUG=1) to gate verbose logs
- Add chunkOffset parameter for better error context
- Return error on kernel rejection/truncation (was silently returning empty list)
- Log actual TLVs sent for correlation with kernel warnings

Breaking change: Callers must now handle errors from GetMultiReportsOID.
Previously silent failures (0 reports) now return explicit errors.

Resolves: kernel truncation warnings "URR_NUM=4 parsed=3"

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
```

## References

- Original kernel error: `gtp5g_genl_get_multi_usage_reports: WNC:multi_usage_reports truncated: URR_NUM=4 parsed=3 remaining=0`
- Related kernel code: `gtp5g/src/genl_urr.c`
- 3GPP TS 29.244: PFCP protocol specification
