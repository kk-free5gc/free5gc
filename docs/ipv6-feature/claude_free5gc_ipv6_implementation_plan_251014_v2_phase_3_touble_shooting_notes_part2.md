# Free5GC IPv6 Implementation - Phase 3 Troubleshooting Notes Part 2

## Date: 2025-11-03

## Critical Bug Fixes - PFCP Context and IPv6 Address Formatting

### Issue 1: PFCP Context Nil Dereference (HIGH SEVERITY)

**Location:** `free5gc/NFs/smf/internal/context/sm_context.go:1566`

**Problem:**
Direct map access without nil check when retrieving PFCP context. If the PFCP session hasn't been established yet or was already torn down when the event report fires, this causes a panic before the RA is built, leaving the session stuck with no advertisement.

```go
// BEFORE (VULNERABLE):
pfcpContext := smContext.PFCPContext[upfNode.GetNodeIP()]
seid := pfcpContext.RemoteSEID  // PANIC if pfcpContext is nil!
```

**Root Cause:**
- Map access returns `nil` if key doesn't exist
- No validation before dereferencing `pfcpContext.RemoteSEID`
- Timing issue: Event report can fire before PFCP session is fully established

**Fix Applied:**
```go
// AFTER (SAFE):
pfcpContext := smContext.PFCPContext[upfNode.GetNodeIP()]
if pfcpContext == nil {
    smContext.Log.Errorln("WNC: PFCP context not found for UPF")
    return errors.New("WNC: PFCP context not found for UPF")
}
seid := pfcpContext.RemoteSEID
```

**Impact:**
- Prevents SMF panic during Router Advertisement delivery
- Provides clear error logging for debugging
- Graceful failure instead of session lock-up

---

### Issue 2: IPv6 Address Formatting (HIGH SEVERITY)

**Problem:**
Multiple locations used `fmt.Sprintf("%s:%d", addr, port)` for building listen addresses and URIs. For IPv6 addresses like `2001:db8::1`, this produces invalid formats like `2001:db8::1:8080` which `net.Listen` and HTTP clients reject due to "too many colons in address".

**Impact:**
- HTTP services fail to bind on IPv6 addresses
- Inter-NF communication fails with IPv6 endpoints
- Service registration with NRF fails for IPv6 deployments

**Solution:**
Replace all occurrences with `net.JoinHostPort()` which properly handles both IPv4 and IPv6 addresses by adding brackets around IPv6 addresses: `[2001:db8::1]:8080`

---

### Locations Fixed (7 Files)

#### 1. SMF HTTP Server Binding
**File:** `free5gc/NFs/smf/internal/sbi/server.go:57`

```go
// BEFORE:
bindAddr := fmt.Sprintf("%s:%d", s.Context().BindingIPv4, s.Context().SBIPort)

// AFTER:
bindAddr := net.JoinHostPort(s.Context().BindingIPv4, strconv.Itoa(int(s.Context().SBIPort)))
```

**Added imports:**
```go
import (
    "net"
    "strconv"
)
```

---

#### 2. NF Service URI Construction
**File:** `free5gc/NFs/smf/internal/util/search_nf_service.go:40`

```go
// BEFORE:
func getSbiUri(scheme models.UriScheme, ipv4Address string, port int32) (uri string) {
    if port != 0 {
        uri = fmt.Sprintf("%s://%s:%d", scheme, ipv4Address, port)
    } else {
        switch scheme {
        case models.UriScheme_HTTP:
            uri = fmt.Sprintf("%s://%s:80", scheme, ipv4Address)
        case models.UriScheme_HTTPS:
            uri = fmt.Sprintf("%s://%s:443", scheme, ipv4Address)
        }
    }
    return
}

// AFTER:
func getSbiUri(scheme models.UriScheme, ipv4Address string, port int32) (uri string) {
    if port != 0 {
        uri = fmt.Sprintf("%s://%s", scheme, net.JoinHostPort(ipv4Address, strconv.Itoa(int(port))))
    } else {
        switch scheme {
        case models.UriScheme_HTTP:
            uri = fmt.Sprintf("%s://%s", scheme, net.JoinHostPort(ipv4Address, "80"))
        case models.UriScheme_HTTPS:
            uri = fmt.Sprintf("%s://%s", scheme, net.JoinHostPort(ipv4Address, "443"))
        }
    }
    return
}
```

**Added imports:**
```go
import (
    "net"
    "strconv"
)
```

---

#### 3. PCF Notification URI
**File:** `free5gc/NFs/smf/internal/sbi/consumer/pcf_service.go:72`

```go
// BEFORE:
smPolicyData.NotificationUri = fmt.Sprintf("%s://%s:%d/nsmf-callback/sm-policies/%s",
    smf_context.GetSelf().URIScheme,
    smf_context.GetSelf().RegisterIPv4,
    smf_context.GetSelf().SBIPort,
    smContext.Ref,
)

// AFTER:
smPolicyData.NotificationUri = fmt.Sprintf("%s://%s/nsmf-callback/sm-policies/%s",
    smf_context.GetSelf().URIScheme,
    net.JoinHostPort(smf_context.GetSelf().RegisterIPv4, strconv.Itoa(int(smf_context.GetSelf().SBIPort))),
    smContext.Ref,
)
```

**Note:** Imports already present in this file.

---

#### 4. CHF Notification URI
**File:** `free5gc/NFs/smf/internal/sbi/consumer/chf_service.go:93`

```go
// BEFORE:
NotifyUri: fmt.Sprintf("%s://%s:%d/nsmf-callback/notify_%s",
    smfContext.URIScheme,
    smfContext.RegisterIPv4,
    smfContext.SBIPort,
    smContext.Ref,
),

// AFTER:
NotifyUri: fmt.Sprintf("%s://%s/nsmf-callback/notify_%s",
    smfContext.URIScheme,
    net.JoinHostPort(smfContext.RegisterIPv4, strconv.Itoa(int(smfContext.SBIPort))),
    smContext.Ref,
),
```

**Added imports:**
```go
import (
    "net"
    "strconv"
)
```

---

#### 5. N1N2 Failure Notification URI
**File:** `free5gc/NFs/smf/internal/pfcp/handler/handler.go:153`

```go
// BEFORE:
N1n2FailureTxfNotifURI: fmt.Sprintf("%s://%s:%d",
    smf_context.GetSelf().URIScheme,
    smf_context.GetSelf().RegisterIPv4,
    smf_context.GetSelf().SBIPort),

// AFTER:
N1n2FailureTxfNotifURI: fmt.Sprintf("%s://%s",
    smf_context.GetSelf().URIScheme,
    net.JoinHostPort(smf_context.GetSelf().RegisterIPv4, strconv.Itoa(int(smf_context.GetSelf().SBIPort)))),
```

**Added imports:**
```go
import (
    "net"
    "strconv"
)
```

---

#### 6. NF Profile API Prefix
**File:** `free5gc/NFs/smf/internal/context/nf_profile.go:41`

```go
// BEFORE:
ApiPrefix: fmt.Sprintf("%s://%s:%d", GetSelf().URIScheme, GetSelf().RegisterIPv4, GetSelf().SBIPort),

// AFTER:
ApiPrefix: fmt.Sprintf("%s://%s", GetSelf().URIScheme, net.JoinHostPort(GetSelf().RegisterIPv4, strconv.Itoa(int(GetSelf().SBIPort)))),
```

**Added imports:**
```go
import (
    "net"
    "strconv"
)
```

---

#### 7. NRF URI Fallback
**File:** `free5gc/NFs/smf/internal/context/context.go:173`

```go
// BEFORE:
if configuration.NrfUri != "" {
    smfContext.NrfUri = configuration.NrfUri
} else {
    logger.CtxLog.Warn("NRF Uri is empty! Using localhost as NRF IPv4 address.")
    smfContext.NrfUri = fmt.Sprintf("%s://%s:%d", smfContext.URIScheme, "127.0.0.1", 29510)
}

// AFTER:
if configuration.NrfUri != "" {
    smfContext.NrfUri = configuration.NrfUri
} else {
    logger.CtxLog.Warn("NRF Uri is empty! Using localhost as NRF IPv4 address.")
    smfContext.NrfUri = fmt.Sprintf("%s://%s", smfContext.URIScheme, net.JoinHostPort("127.0.0.1", strconv.Itoa(29510)))
}
```

**Added imports:**
```go
import (
    "strconv"
)
```
**Note:** `net` import already present in this file.

---

## Build Verification

```bash
cd free5gc && make smf
```

**Result:** ✅ SMF builds successfully with all changes

**Build output:**
```
Start building smf....
cd NFs/smf/cmd && \
CGO_ENABLED=0 go build -gcflags "" -ldflags "-X github.com/free5gc/util/version.VERSION=v4.0.1-kk-snap-003-3-gb56d948 -X github.com/free5gc/util/version.BUILD_TIME=2025-11-03T13:13:34Z -X github.com/free5gc/util/version.COMMIT_HASH=7a3baa20 -X github.com/free5gc/util/version.COMMIT_TIME=2025-10-23T11:50:09Z" -o /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc/bin/smf main.go
```

---

## Testing Recommendations

### 1. PFCP Context Nil Check Testing
- Test RA delivery during UE registration timing edge cases
- Monitor logs for "WNC: PFCP context not found for UPF" messages
- Verify graceful error handling instead of panics

### 2. IPv6 Address Formatting Testing

#### HTTP Server Binding
```bash
# Test SMF with IPv6 binding address in config
# config/smfcfg.yaml:
configuration:
  sbi:
    bindingIPv4: "2001:db8::1"  # IPv6 address
    port: 8000
```

**Expected behavior:**
- SMF HTTP server binds successfully to `[2001:db8::1]:8000`
- No "too many colons in address" error

#### Inter-NF Communication
Test scenarios:
1. **SMF → PCF** policy association with IPv6 NotificationUri
2. **SMF → CHF** charging session with IPv6 NotifyUri
3. **SMF → AMF** N1N2MessageTransfer with IPv6 callback URI
4. **SMF → NRF** registration with IPv6 ApiPrefix

#### Service Discovery
- Verify NRF can discover SMF services with IPv6 endpoints
- Check proper URI construction in NF profiles

---

## Impact Analysis

### Before Fix
❌ **Critical failures:**
- SMF panic during RA delivery if PFCP session not established
- HTTP server fails to bind on IPv6 addresses
- Inter-NF communication broken for IPv6 deployments
- Service registration fails with IPv6 endpoints

### After Fix
✅ **Improvements:**
- Graceful error handling for PFCP context issues
- Full IPv6 support for HTTP server binding
- Proper IPv6 URI formatting across all NF communications
- Compatible with both IPv4 and IPv6 deployments

---

## Related Issues

These fixes address fundamental IPv6 compatibility issues that would have blocked the entire Router Advertisement implementation. The bugs were discovered during code review of the RA HTTP endpoint implementation.

**Reference:** Phase 3.2.4 RA endpoint implementation
**Related files:**
- `free5gc/NFs/smf/internal/context/upf_ra_client.go` (RA HTTP client)
- `free5gc/NFs/smf/internal/context/sm_context.go` (RA delivery orchestration)

---

## Lessons Learned

1. **Always use `net.JoinHostPort()`** for IPv6-compatible address formatting
2. **Never dereference map values** without nil checks in Go
3. **Test with IPv6 addresses early** in implementation to catch formatting issues
4. **Validate PFCP session state** before accessing session-specific data

---

## Additional Code Cleanup

During this fix, we also removed duplicate code:
- Deleted `free5gc/NFs/smf/internal/sbi/consumer/upf_service.go` (unused duplicate RA client)
- Kept `free5gc/NFs/smf/internal/context/upf_ra_client.go` (active implementation)

**Rationale:** Maintains clean architecture by keeping UPF-specific HTTP logic in the context package where it's used, avoiding unnecessary SBI consumer dependencies.

---

## Commit Message Template

```
fix(smf): Add PFCP context nil check and fix IPv6 address formatting

Critical bug fixes for IPv6 support and Router Advertisement delivery:

1. PFCP Context Safety (sm_context.go:1566)
   - Add nil check before dereferencing PFCP context
   - Prevents panic during RA delivery if session not established
   - Provides clear error logging for debugging

2. IPv6 Address Formatting (7 locations)
   - Replace fmt.Sprintf("%s:%d") with net.JoinHostPort()
   - Fixes HTTP server binding on IPv6 addresses
   - Enables inter-NF communication with IPv6 endpoints
   - Files updated:
     * internal/sbi/server.go
     * internal/util/search_nf_service.go
     * internal/sbi/consumer/pcf_service.go
     * internal/sbi/consumer/chf_service.go
     * internal/pfcp/handler/handler.go
     * internal/context/nf_profile.go
     * internal/context/context.go

Impact:
- Enables full IPv6 support for SMF
- Prevents session lock-up during RA delivery
- Compatible with both IPv4 and IPv6 deployments

Build verified: SMF compiles successfully
```

---

## Status

✅ **COMPLETE** - All fixes applied and verified
- 1 nil check added
- 7 IPv6 formatting issues fixed
- Build successful
- Ready for integration testing
