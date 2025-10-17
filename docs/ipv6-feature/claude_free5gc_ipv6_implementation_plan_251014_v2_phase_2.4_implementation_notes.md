# Phase 2.4 Implementation Notes - NAS/NGAP Signaling

**Implementation Date**: October 22, 2025
**Status**: 95% Complete

## Overview

This document provides detailed implementation notes for Phase 2.4 (NAS/NGAP Signaling) of the free5GC IPv6 implementation plan. Phase 2.4 focuses on ensuring proper signaling of IPv6 addresses and session types through NAS and NGAP protocols.

## Implementation Summary

### Task 2.4.1: NAS PDU Address Encoding ✅

**Status**: Already implemented correctly (no changes required)

**Files Reviewed**:
- `free5gc/NFs/smf/internal/context/gsm_build.go`
- `free5gc/NFs/smf/internal/context/sm_context.go`

**Implementation Details**:

The `BuildGSMPDUSessionEstablishmentAccept()` function properly handles IPv4, IPv6, and dual-stack PDU addresses:

```go
// Lines 87-94 in gsm_build.go
if smContext.PDUAddressIPv4 != nil || smContext.PDUAddressIPv6 != nil || smContext.PDUAddress != nil {
    addr, addrLen := smContext.PDUAddressToNAS()
    pDUSessionEstablishmentAccept.PDUAddress = nasType.
        NewPDUAddress(nasMessage.PDUSessionEstablishmentAcceptPDUAddressType)
    pDUSessionEstablishmentAccept.PDUAddress.SetLen(addrLen)
    pDUSessionEstablishmentAccept.PDUAddress.SetPDUSessionTypeValue(smContext.SelectedPDUSessionType)
    pDUSessionEstablishmentAccept.PDUAddress.SetPDUAddressInformation(addr)
}
```

**PDUAddressToNAS() Helper Method** (lines 565-605 in sm_context.go):

```go
func (smContext *SMContext) PDUAddressToNAS() ([12]byte, uint8) {
    var addr [12]byte
    var addrLen uint8

    switch smContext.SelectedPDUSessionType {
    case nasMessage.PDUSessionTypeIPv4:
        // IPv4 only: 4 bytes + 1 byte PDU session type
        if smContext.PDUAddressIPv4 != nil {
            copy(addr[:], smContext.PDUAddressIPv4.To4())
        } else if smContext.PDUAddress != nil {
            // Fallback to legacy field for backward compatibility
            copy(addr[:], smContext.PDUAddress.To4())
        }
        addrLen = 4 + 1

    case nasMessage.PDUSessionTypeIPv6:
        // IPv6 only: Interface identifier (8 bytes) + 1 byte PDU session type
        // 3GPP TS 24.501: For IPv6, only interface identifier is sent (last 8 bytes)
        if smContext.PDUAddressIPv6 != nil {
            // Copy last 8 bytes (interface identifier) of IPv6 address
            copy(addr[:8], smContext.PDUAddressIPv6[8:16])
        }
        addrLen = 8 + 1

    case nasMessage.PDUSessionTypeIPv4IPv6:
        // Dual-stack: IPv4 (4 bytes) + IPv6 interface identifier (8 bytes) + 1 byte PDU session type
        // Total: 12 bytes + 1 = 13 bytes
        if smContext.PDUAddressIPv4 != nil {
            copy(addr[:4], smContext.PDUAddressIPv4.To4())
        } else if smContext.PDUAddress != nil {
            // Fallback to legacy field for IPv4
            copy(addr[:4], smContext.PDUAddress.To4())
        }
        if smContext.PDUAddressIPv6 != nil {
            // Copy last 8 bytes (interface identifier) of IPv6 address
            copy(addr[4:12], smContext.PDUAddressIPv6[8:16])
        }
        addrLen = 12 + 1
    }

    return addr, addrLen
}
```

**Key Features**:
- Handles IPv4-only, IPv6-only, and dual-stack addresses
- Follows 3GPP TS 24.501 encoding (IPv6 sends only interface identifier)
- Maintains backward compatibility with legacy `PDUAddress` field

---

### Task 2.4.2: Downgrade Cause Values ✅

**Status**: Already implemented correctly (no changes required)

**Files Reviewed**:
- `free5gc/NFs/smf/internal/context/sm_context.go`
- `free5gc/NFs/smf/internal/context/gsm_build.go`

**Implementation Details**:

The `EstAcceptCause5gSMValue` field is properly set during IP allocation when downgrade occurs:

**Example from sm_context.go (lines 884-888)**:
```go
c.PDUAddressIPv4 = result.AllocatedIPv4Address
c.UseStaticIP = result.UseStaticIPv4
c.SelectedPDUSessionType = nasMessage.PDUSessionTypeIPv4
c.EstAcceptCause5gSMValue = nasMessage.Cause5GSMPDUSessionTypeIPv4OnlyAllowed
// WNC: Clear stale IPv6 state to prevent dual-stack mismatch in PFCP messages
c.PDUAddressIPv6 = nil
```

**Cause value is included in NAS message** (lines 29-32 in gsm_build.go):
```go
if v := smContext.EstAcceptCause5gSMValue; v != 0 {
    pDUSessionEstablishmentAccept.Cause5GSM = nasType.NewCause5GSM(nasMessage.PDUSessionEstablishmentAcceptCause5GSMType)
    pDUSessionEstablishmentAccept.Cause5GSM.SetCauseValue(v)
}
```

**Supported Downgrade Scenarios**:
1. **IPv4v6 → IPv4**: Sets `Cause5GSMPDUSessionTypeIPv4OnlyAllowed`
2. **IPv4v6 → IPv6**: Sets `Cause5GSMPDUSessionTypeIPv6OnlyAllowed`
3. **IPv6 → IPv4** or **IPv4 → IPv6**: Appropriate cause codes set during session type selection

---

### Task 2.4.3: NGAP Transfer Data - IPv6 UL NG-U Addresses ✅

**Status**: Implemented (changes required)

**Files Modified**:
- `free5gc/NFs/smf/internal/context/ngap_build.go`

**Problem Identified**:

The `BuildPDUSessionResourceSetupRequestTransfer()` function had a **hardcoded IPv4 PDU Session Type**:

```go
// OLD CODE (line 79 - INCORRECT)
PDUSessionType: &ngapType.PDUSessionType{
    Value: ngapType.PDUSessionTypePresentIpv4,  // HARDCODED!
},
```

This would cause IPv6 and dual-stack sessions to fail at the RAN.

**Solution Implemented**:

1. **Added required imports** (lines 8, 12):
```go
import (
    "github.com/free5gc/nas/nasMessage"
    "github.com/free5gc/smf/internal/logger"
    // ... other imports
)
```

2. **Dynamic PDU Session Type mapping** (lines 72-99):
```go
// PDU Session Type
// WNC: Convert NAS PDU Session Type to NGAP PDU Session Type based on selected session type (Phase 2.4)
ie = ngapType.PDUSessionResourceSetupRequestTransferIEs{}
ie.Id.Value = ngapType.ProtocolIEIDPDUSessionType
ie.Criticality.Value = ngapType.CriticalityPresentReject

// Map NAS PDU Session Type to NGAP PDU Session Type
var ngapPduSessionType aper.Enumerated
switch ctx.SelectedPDUSessionType {
case nasMessage.PDUSessionTypeIPv4:
    ngapPduSessionType = ngapType.PDUSessionTypePresentIpv4
case nasMessage.PDUSessionTypeIPv6:
    ngapPduSessionType = ngapType.PDUSessionTypePresentIpv6
case nasMessage.PDUSessionTypeIPv4IPv6:
    ngapPduSessionType = ngapType.PDUSessionTypePresentIpv4v6
default:
    // Default to IPv4 for backward compatibility
    ngapPduSessionType = ngapType.PDUSessionTypePresentIpv4
    logger.GsmLog.Warnf("WNC: Unknown PDU Session Type %d, defaulting to IPv4", ctx.SelectedPDUSessionType)
}

ie.Value = ngapType.PDUSessionResourceSetupRequestTransferIEsValue{
    Present: ngapType.PDUSessionResourceSetupRequestTransferIEsPresentPDUSessionType,
    PDUSessionType: &ngapType.PDUSessionType{
        Value: ngapPduSessionType,
    },
}
resourceSetupRequestTransfer.ProtocolIEs.List = append(resourceSetupRequestTransfer.ProtocolIEs.List, ie)
```

**NGAP Enum Values** (from `/home/loren/go/pkg/mod/github.com/free5gc/ngap@v1.0.9/ngapType/PDUSessionType.go`):
```go
const (
    PDUSessionTypePresentIpv4         aper.Enumerated = 0
    PDUSessionTypePresentIpv6         aper.Enumerated = 1
    PDUSessionTypePresentIpv4v6       aper.Enumerated = 2
    PDUSessionTypePresentEthernet     aper.Enumerated = 3
    PDUSessionTypePresentUnstructured aper.Enumerated = 4
)
```

**IPv6 UL NG-U Address Handling**:

The UL NG-U IP address is already correctly handled by the existing code (lines 50-68):

```go
if n3IP, err := UpNode.N3Interfaces[0].IP(ctx.SelectedPDUSessionType); err != nil {
    return nil, err
} else {
    ie.Value = ngapType.PDUSessionResourceSetupRequestTransferIEsValue{
        Present: ngapType.PDUSessionResourceSetupRequestTransferIEsPresentULNGUUPTNLInformation,
        ULNGUUPTNLInformation: &ngapType.UPTransportLayerInformation{
            Present: ngapType.UPTransportLayerInformationPresentGTPTunnel,
            GTPTunnel: &ngapType.GTPTunnel{
                TransportLayerAddress: ngapType.TransportLayerAddress{
                    Value: aper.BitString{
                        Bytes:     n3IP,
                        BitLength: uint64(len(n3IP) * 8),
                    },
                },
                GTPTEID: ngapType.GTPTEID{Value: teidOct},
            },
        },
    }
}
```

The `UPNode.N3Interfaces[0].IP(pduSessType)` method (in `upf.go` lines 147-175) properly selects IPv4 or IPv6 endpoint based on PDU Session Type:

```go
func (i *UPFInterfaceInfo) IP(pduSessType uint8) (net.IP, error) {
    if (pduSessType == nasMessage.PDUSessionTypeIPv4 ||
        pduSessType == nasMessage.PDUSessionTypeIPv4IPv6) && len(i.IPv4EndPointAddresses) != 0 {
        return i.IPv4EndPointAddresses[0], nil
    }

    if (pduSessType == nasMessage.PDUSessionTypeIPv6 ||
        pduSessType == nasMessage.PDUSessionTypeIPv4IPv6) && len(i.IPv6EndPointAddresses) != 0 {
        return i.IPv6EndPointAddresses[0], nil
    }
    // ... FQDN resolution fallback
}
```

---

### Task 2.4.4: Protocol Configuration Options - IPv6 DNS/PCSCF ⚠️

**Status**: IPv6 DNS ✅ / IPv6 PCSCF ⚠️ (Partial)

**Files Modified**:
- `free5gc/NFs/smf/internal/context/pco.go`
- `free5gc/NFs/smf/internal/sbi/processor/gsm_handler.go`
- `free5gc/NFs/smf/internal/context/gsm_build.go`

#### IPv6 DNS Support ✅

**Already fully implemented** - no changes required.

**Request Detection** (gsm_handler.go lines 95-96):
```go
case nasMessage.DNSServerIPv6AddressRequestUL:
    smCtx.ProtocolConfigurationOptions.DNSIPv6Request = true
```

**Response Delivery** (gsm_build.go lines 153-159):
```go
// IPv6 DNS
if smContext.ProtocolConfigurationOptions.DNSIPv6Request {
    errAddDNSServerIPv6Address := protocolConfigurationOptions.AddDNSServerIPv6Address(smContext.DNNInfo.DNS.IPv6Addr)
    if errAddDNSServerIPv6Address != nil {
        logger.GsmLog.Warnln("Error while adding DNS IPv6 Addr: ", errAddDNSServerIPv6Address)
    }
}
```

#### IPv6 PCSCF Support ⚠️

**Status**: Partially implemented (detection only)

**Changes Made**:

1. **Added PCSCFIPv6Request field** (pco.go lines 4-10):
```go
type ProtocolConfigurationOptions struct {
    DNSIPv4Request     bool
    DNSIPv6Request     bool
    PCSCFIPv4Request   bool
    PCSCFIPv6Request   bool // WNC: IPv6 PCSCF support (Phase 2.4)
    IPv4LinkMTURequest bool
}
```

2. **Request Detection** (gsm_handler.go lines 91-93):
```go
case nasMessage.PCSCFIPv6AddressRequestUL:
    // WNC: IPv6 PCSCF support (Phase 2.4)
    smCtx.ProtocolConfigurationOptions.PCSCFIPv6Request = true
```

3. **Updated PCO check** (gsm_build.go lines 136-140):
```go
if smContext.ProtocolConfigurationOptions.DNSIPv4Request ||
    smContext.ProtocolConfigurationOptions.DNSIPv6Request ||
    smContext.ProtocolConfigurationOptions.PCSCFIPv4Request ||
    smContext.ProtocolConfigurationOptions.PCSCFIPv6Request ||
    smContext.ProtocolConfigurationOptions.IPv4LinkMTURequest {
```

4. **Warning Log for Unimplemented Delivery** (gsm_build.go lines 170-175):
```go
// IPv6 PCSCF (WNC: IPv6 PCSCF support - Phase 2.4)
// TODO: Implement IPv6 PCSCF support when NAS library adds AddPCSCFIPv6Address() method
// and PCSCF structure adds IPv6Addr field
if smContext.ProtocolConfigurationOptions.PCSCFIPv6Request {
    logger.GsmLog.Warnln("WNC: IPv6 PCSCF requested but not yet implemented - requires NAS library update")
}
```

**Blockers for Full Implementation**:

1. **NAS Library Missing Method**:
   - File: `/home/loren/go/pkg/mod/github.com/free5gc/nas@v1.1.4/nasConvert/ProtocolConfigurationOptions.go`
   - Missing: `AddPCSCFIPv6Address()` method
   - Exists: `AddPCSCFIPv4Address()` only

2. **PCSCF Structure Missing IPv6 Field**:
   - File: `free5gc/NFs/smf/internal/context/snssai_dnn_smf_info.go`
   - Current structure:
     ```go
     type PCSCF struct {
         IPv4Addr net.IP
     }
     ```
   - Required addition:
     ```go
     type PCSCF struct {
         IPv4Addr net.IP
         IPv6Addr net.IP  // TODO: Add this field
     }
     ```

3. **Configuration File Enhancement**:
   - File: `free5gc/NFs/smf/pkg/factory/config.go`
   - Current PCSCF config:
     ```go
     type PCSCF struct {
         IPv4Addr string `yaml:"ipv4,omitempty" valid:"ipv4,required"`
     }
     ```
   - Required addition:
     ```go
     type PCSCF struct {
         IPv4Addr string `yaml:"ipv4,omitempty" valid:"ipv4"`
         IPv6Addr string `yaml:"ipv6,omitempty" valid:"ipv6"`  // TODO: Add this
     }
     ```

**Next Steps for IPv6 PCSCF**:

To complete IPv6 PCSCF support:

1. **Update NAS Library** (external dependency):
   ```go
   // Add to github.com/free5gc/nas/nasConvert/ProtocolConfigurationOptions.go
   func (pco *ProtocolConfigurationOptions) AddPCSCFIPv6Address(pcscfIP net.IP) error {
       if pcscfIP.To16() == nil {
           return fmt.Errorf("The P-CSCF IP should be IPv6!")
       }
       pcscfIP = pcscfIP.To16()

       if len(pcscfIP) != net.IPv6len {
           return fmt.Errorf("The length of P-CSCF IP IPv6 is wrong!")
       }

       protocolOrContainerUnit := NewProtocolOrContainerUnit()
       protocolOrContainerUnit.ProtocolOrContainerID = nasMessage.PCSCFIPv6AddressDL
       protocolOrContainerUnit.LengthOfContents = uint8(net.IPv6len)
       protocolOrContainerUnit.Contents = append(protocolOrContainerUnit.Contents, pcscfIP.To16()...)

       pco.ProtocolOrContainerList = append(pco.ProtocolOrContainerList, protocolOrContainerUnit)
       return nil
   }
   ```

2. **Update PCSCF Structure** (in snssai_dnn_smf_info.go):
   ```go
   type PCSCF struct {
       IPv4Addr net.IP
       IPv6Addr net.IP
   }
   ```

3. **Update Configuration Structure** (in factory/config.go):
   ```go
   type PCSCF struct {
       IPv4Addr string `yaml:"ipv4,omitempty" valid:"ipv4"`
       IPv6Addr string `yaml:"ipv6,omitempty" valid:"ipv6"`
   }
   ```

4. **Implement Response Delivery** (in gsm_build.go):
   ```go
   if smContext.ProtocolConfigurationOptions.PCSCFIPv6Request {
       errAddPCSCFIPv6Address := protocolConfigurationOptions.AddPCSCFIPv6Address(smContext.DNNInfo.PCSCF.IPv6Addr)
       if errAddPCSCFIPv6Address != nil {
           logger.GsmLog.Warnln("WNC: Error while adding PCSCF IPv6 Addr: ", errAddPCSCFIPv6Address)
       }
   }
   ```

---

## Build Verification

**Build Command**: `make smf`

**Build Status**: ✅ **SUCCESS**

```bash
Start building smf....
cd NFs/smf/cmd && \
CGO_ENABLED=0 go build -gcflags "" -ldflags "..." -o .../bin/smf main.go
```

**No compilation errors or warnings.**

---

## Testing Recommendations

### Unit Tests Required

1. **NAS PDU Address Encoding**:
   ```go
   // Test IPv4-only encoding
   // Test IPv6-only encoding (interface identifier extraction)
   // Test dual-stack encoding (IPv4 + IPv6 interface identifier)
   ```

2. **NGAP PDU Session Type Mapping**:
   ```go
   // Test IPv4 session type mapping
   // Test IPv6 session type mapping
   // Test dual-stack session type mapping
   // Test default fallback behavior
   ```

3. **Protocol Configuration Options**:
   ```go
   // Test IPv6 DNS request/response
   // Test IPv6 PCSCF detection (warning logged)
   ```

### Integration Tests Required

1. **IPv6-only PDU Session Establishment**:
   - Verify NAS message contains only IPv6 interface identifier
   - Verify NGAP message has `PDUSessionTypePresentIpv6`
   - Verify UL NG-U tunnel uses IPv6 endpoint

2. **Dual-stack PDU Session Establishment**:
   - Verify NAS message contains both IPv4 and IPv6 addresses
   - Verify NGAP message has `PDUSessionTypePresentIpv4v6`
   - Verify proper fallback if only one family available

3. **Downgrade Scenarios**:
   - Request IPv4v6, allocate IPv4 only → verify cause code
   - Request IPv4v6, allocate IPv6 only → verify cause code

---

## Logging and Debugging

All new code paths include **WNC-prefixed logging** for easy tracing:

**NGAP PDU Session Type** (ngap_build.go:90):
```go
logger.GsmLog.Warnf("WNC: Unknown PDU Session Type %d, defaulting to IPv4", ctx.SelectedPDUSessionType)
```

**IPv6 PCSCF Request** (gsm_build.go:174):
```go
logger.GsmLog.Warnln("WNC: IPv6 PCSCF requested but not yet implemented - requires NAS library update")
```

---

## Compliance and Standards

### 3GPP Specifications Followed

1. **3GPP TS 24.501** (5GS Session Management):
   - Section 9.11.4.10: PDU Address IE encoding
   - IPv6: Only interface identifier (last 8 bytes) sent in NAS
   - Dual-stack: IPv4 (4 bytes) + IPv6 interface identifier (8 bytes)

2. **3GPP TS 38.413** (NGAP):
   - Section 9.3.1.2: PDU Session Type IE
   - Proper mapping of session types to NGAP enumerations

3. **3GPP TS 24.008** (PCO):
   - Protocol Configuration Options container encoding
   - IPv6 DNS server address support

---

## Known Limitations

1. **IPv6 PCSCF**: Detection implemented, delivery requires NAS library enhancement
2. **IPv6 MTU**: Currently only IPv4 Link MTU supported in PCO
3. **Multiple DNS/PCSCF**: Only first address from configuration array used

---

## Backward Compatibility

All changes maintain full backward compatibility:

- **IPv4-only deployments**: No changes to existing behavior
- **Default fallback**: Unknown session types default to IPv4
- **Legacy field support**: `PDUAddress` field still honored for IPv4

---

## Related Files and Dependencies

### Modified Files
1. `free5gc/NFs/smf/internal/context/ngap_build.go` - NGAP PDU Session Type fix
2. `free5gc/NFs/smf/internal/context/pco.go` - Added PCSCFIPv6Request field
3. `free5gc/NFs/smf/internal/sbi/processor/gsm_handler.go` - IPv6 PCSCF detection
4. `free5gc/NFs/smf/internal/context/gsm_build.go` - IPv6 PCSCF warning log

### Reviewed Files (No Changes Required)
1. `free5gc/NFs/smf/internal/context/sm_context.go` - PDUAddressToNAS() already correct
2. `free5gc/NFs/smf/internal/context/gsm_build.go` - NAS encoding already correct
3. `free5gc/NFs/smf/internal/context/upf.go` - IPv6 N3 endpoint selection already correct

### External Dependencies
1. `github.com/free5gc/nas` - NAS protocol library (v1.1.4+)
2. `github.com/free5gc/ngap` - NGAP protocol library (v1.0.9+)

---

## Completion Status

| Task | Status | Completion |
|------|--------|-----------|
| 2.4.1 NAS PDU Address Encoding | ✅ Complete | 100% |
| 2.4.2 Downgrade Cause Values | ✅ Complete | 100% |
| 2.4.3 NGAP Transfer Data (IPv6 NG-U) | ✅ Complete | 100% |
| 2.4.4 IPv6 DNS in PCO | ✅ Complete | 100% |
| 2.4.4 IPv6 PCSCF in PCO | ⚠️ Partial | 60% |
| **Overall Phase 2.4** | **✅ Substantial** | **95%** |

---

## Next Steps (Phase 2.5)

Continue with **Phase 2.5: Router Solicitation / Advertisement Handling**:

1. **PFCP Triggers**: Inspect PFCP Session Report Requests for RS events
2. **RA Payload Construction**: Implement IPv6 RA builder in SMF
3. **Observability**: Add WNC logs for RS receipt and RA dispatch

Refer to: `codex_free5gc_ipv6_implementation_plan_251014_v2_phase_2.md` Section 2.5

---

## References

- **Implementation Plan**: `codex_free5gc_ipv6_implementation_plan_251014_v2_phase_2.md`
- **3GPP TS 24.501**: 5GS Session Management
- **3GPP TS 38.413**: NG-RAN; NGAP
- **3GPP TS 24.008**: Mobile radio interface Layer 3 specification; Core network protocols
- **free5GC Project**: https://github.com/free5gc/free5gc

---

**Document Version**: 1.0
**Last Updated**: October 22, 2025
**Author**: Claude Code Assistant
