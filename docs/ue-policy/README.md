# UE Policy Control Implementation Documentation

## Overview

This directory contains comprehensive documentation for the **UE Policy Control** implementation in Free5GC. The implementation provides complete 3GPP TS 23.502 and TS 29.525 compliant UE policy management, including policy association lifecycle, transparent policy delivery, and robust message handling during UE registration.

## Implementation Status

**Status:** ✅ **COMPLETE** - Production Ready (July 2025)

All three major features have been successfully implemented, tested, and integrated into Free5GC:

1. **3GPP-Compliant UE Policy Control Flow** - Complete policy association lifecycle
2. **Transparent UE Policy Delivery** - PCF-to-UE policy forwarding via AMF
3. **N1N2 Message FIFO Queue** - Robust message handling during registration

## Quick Navigation

### Active Documentation

| Document | Description | Status |
|----------|-------------|--------|
| **[IMPLEMENTATION_SUMMARY.md](./IMPLEMENTATION_SUMMARY.md)** | **Consolidated summary of all three features** | ✅ Complete |
| [REFERENCE_Examples/](./REFERENCE_Examples/) | Real-world packet captures (QXDM, Wireshark) | Reference |
| [archive/](./archive/) | Detailed documentation and planning documents | Reference |

### Archived Documentation

All detailed implementation files have been archived for historical reference:
- `archive/Detailed_Documentation/UE-Policy-Control-Flow-Implementation-Complete-250718-3.md` - Detailed UE Policy Control Flow
- `archive/Detailed_Documentation/N1N2_Message_FIFO_Queue_During_Registration.md` - FIFO queue implementation
- `archive/Detailed_Documentation/Claude_UE_Policy_Implementation_Discussion.md` - Original design discussion
- `archive/Planning_Documents/` - All planning and design documents (10 files)

### Quick Start

For a quick understanding of the implementation:
1. Read [IMPLEMENTATION_SUMMARY.md](./IMPLEMENTATION_SUMMARY.md) for complete overview
2. Check [REFERENCE_Examples/](./REFERENCE_Examples/) for real-world packet captures
3. Refer to `/free5gc/CLAUDE.md` for detailed integration information

## Key Features Implemented

### 1. UE Policy Control Flow (3GPP TS 23.502 Section 5.2.5.6)

**Implementation Date:** July 18, 2025

Complete 3GPP-compliant policy association lifecycle:
- **AMF-PCF Integration**: UE Policy Association creation after registration
- **Asynchronous Policy Delivery**: Non-blocking policy notification handling
- **Policy Lookup**: UE discovery by policy association ID
- **HTTP Callback Routes**: RESTful notification endpoints
- **Default Policy Fallback**: Graceful degradation when PCF unavailable

**Key Components:**
- `UEPolicyControlCreate()` - AMF consumer for PCF policy association
- `AmfUeFindByUePolicyAssociationID()` - UE lookup by association ID
- `HTTPUePolicyControlUpdateNotify()` - AMF callback handler
- `HandleUePolicyControlUpdateNotify()` - Notification processor
- `SendUEPolicyToUE()` - Policy delivery to UE via NAS transport

### 2. Transparent UE Policy Delivery (3GPP TS 23.502 Clause 4.2.4.3)

**Implementation Date:** July 24, 2025

PCF-initiated transparent policy delivery mechanism:
- **PCF AMF Service Consumer**: N1N2MessageTransfer client for policy forwarding
- **Async Policy Evaluation**: Post-association policy update evaluation
- **UE Policy Container**: NAS container construction for transparent delivery
- **CM-CONNECTED/CM-IDLE Support**: Proper handling for both UE states
- **UDR PSI Updates**: Policy Set Information persistence framework

**Key Components:**
- `TriggerAsyncUEPolicyEvaluation()` - PCF policy evaluation trigger
- `UpdateUEPolicy()` - Transparent delivery via AMF N1N2MessageTransfer
- `buildUEPolicyContainer()` - NAS UE Policy Container construction
- Enhanced AMF N1N2MessageTransfer handler with UE policy logging
- `SendN1MessageNotify()` - UE policy response forwarding

### 3. N1N2 Message FIFO Queue During Registration

**Implementation Date:** July 25, 2025

Robust message queuing for registration procedures:
- **FIFO Processing**: Messages processed in arrival order
- **30-Second Timeout**: Prevents infinite waiting for registration completion
- **Thread-Safe Operations**: Concurrent message handling with mutex protection
- **Automatic Retry**: Queued messages processed when registration completes
- **Resource Management**: Proper goroutine lifecycle management

**Key Components:**
- `N1N2MessageQueue` - Thread-safe FIFO queue structure
- `N1N2MessageQueueItem` - Queue item with timestamp and retry tracking
- `StartN1N2QueueProcessor()` - Background queue processor
- `StopN1N2QueueProcessor()` - Clean processor termination

## 3GPP Compliance

This implementation follows these 3GPP specifications:

- **TS 23.502**: Procedures for the 5G System (5GS)
  - Section 5.2.5.6: UE Policy Control
  - Clause 4.2.4.3: UE Configuration Update for Transparent UE Policy Delivery
- **TS 29.525**: Npcf_UEPolicyControl API
  - Policy Association CRUD operations
  - Policy update notifications
  - Conditional PRA (Presence Reporting Area) inclusion
- **TS 24.501**: Non-Access-Stratum (NAS) protocol
  - UE Policy Container format
  - Manage UE Policy Command message

## Architecture Overview

### Complete Message Flow

```
1. UE Registration
   ↳ AMF: HandleInitialRegistration()
   ↳ AMF: SendRegistrationAccept()
   ↳ AMF: UEPolicyControlCreate() → PCF

2. PCF Policy Association
   ↳ PCF: Create UE Policy Association
   ↳ PCF: Return Association ID to AMF
   ↳ PCF: TriggerAsyncUEPolicyEvaluation()

3. Transparent Policy Delivery
   ↳ PCF: UpdateUEPolicy() via N1N2MessageTransfer
   ↳ AMF: Receive N1N2MessageTransferRequest
   ↳ AMF: Queue if OnGoingProcedureRegistration (FIFO)
   ↳ AMF: Process queue when registration complete

4. Policy Forwarding to UE
   ↳ AMF: SendUEPolicyToUE()
   ↳ AMF: BuildManageUEPolicyCommand()
   ↳ AMF: Send via DL NAS Transport
   ↳ UE: Receive and apply policy
```

### Key Network Functions Modified

| Network Function | Files Modified | Purpose |
|------------------|----------------|---------|
| **AMF** | `context/amf_ue.go` | UE context enhancement with policy fields |
| **AMF** | `sbi/consumer/pcf_service.go` | PCF UE Policy Control client |
| **AMF** | `gmm/handler.go` | Registration flow integration |
| **AMF** | `sbi/api_httpcallback.go` | HTTP callback routes |
| **AMF** | `sbi/processor/callback.go` | Notification processing |
| **AMF** | `sbi/processor/n1n2message.go` | FIFO queue integration |
| **PCF** | `context/ue.go` | UE Policy context structures |
| **PCF** | `sbi/api_uepolicy.go` | UE Policy HTTP endpoints |
| **PCF** | `sbi/processor/uepolicy.go` | UE Policy business logic |
| **PCF** | `sbi/consumer/amf_service.go` | AMF N1N2MessageTransfer client |

## API Endpoints

### AMF Callback Endpoints

| Method | Endpoint | Purpose | Status |
|--------|----------|---------|--------|
| POST | `/namf-callback/v1/ue-policy/{uePolicyAssociationId}` | Receive PCF policy notifications | ✅ Complete |
| POST | `/namf-callback/v1/n1-n2-message-transfer-failure` | N1N2 transfer failure notifications | ✅ Enhanced |
| POST | `/namf-callback/v1/n1-message-notify` | UE policy response forwarding | ✅ Enhanced |

### PCF UE Policy Control Endpoints

| Method | Endpoint | Purpose | Status |
|--------|----------|---------|--------|
| POST | `/npcf-ue-policy-control/v1/policies` | Create UE Policy Association | ✅ Complete |
| GET | `/npcf-ue-policy-control/v1/policies/{polAssoId}` | Read policy association | ✅ Complete |
| DELETE | `/npcf-ue-policy-control/v1/policies/{polAssoId}` | Delete policy association | ✅ Complete |
| POST | `/npcf-ue-policy-control/v1/policies/{polAssoId}/update` | Report observed triggers | ✅ Complete |

## Configuration

### Default Policy Configuration

The implementation supports flexible policy configuration:

- **YAML Configuration**: `./config/pcfcfg_ue_policy_wnc.yaml`
- **Fallback Policy**: `policy.QXDMPolicyConfig` (hardcoded)
- **Profile Selection**: QXDM and Wireshark profiles available

### Notification URI Pattern

```go
NotificationUri: amfSelf.GetIPv4Uri() + factory.AmfCallbackResUriPrefix + "/ue-policy/"
// Results in: http://127.0.0.10:8000/namf-callback/v1/ue-policy/
```

### FIFO Queue Configuration

- **Timeout**: 30 seconds (hardcoded, configurable in future)
- **Polling Interval**: 100ms
- **Queue Size**: Unlimited (bounded by timeout window)

## Testing and Verification

### Build Commands

```bash
# Build AMF with UE Policy Control support
make amf

# Build PCF with UE Policy Association management
make pcf

# Build all network functions
make nfs

# Full rebuild for integration testing
make clean && make all
```

### Verification Steps

1. **Compilation**: All network functions build successfully
2. **Registration Flow**: UE policy association creation works
3. **Policy Delivery**: Transparent forwarding to CM-CONNECTED/CM-IDLE UEs
4. **FIFO Queue**: Messages queued and processed in order during registration
5. **Error Handling**: Proper conflict detection and retry mechanisms
6. **Logging**: WNC-prefixed logs for complete operation traceability

### Log Monitoring

All UE Policy operations include **"WNC:"** prefixed logging:

```
[INFO][Gmm] WNC: AMF Initiating UE Policy Association for SUPI: imsi-466110000000548
[INFO][UEPolicy] WNC: PCF Handle UE Policy Association Create
[INFO][Producer] WNC: Queued N1N2 message for UE imsi-466110000000548 during registration (queue size: 2)
[INFO][Gmm] WNC: Processing queued N1N2 message for UE imsi-466110000000548
[INFO][Callback] WNC: Handle UE Policy Control Update Notify
```

## Troubleshooting

### Common Issues

**1. Empty polAssoId in Logs**
- **Issue**: Association ID empty during CREATE operations
- **Solution**: Extract from location header after creation

**2. 409 Conflict Errors**
- **Issue**: AMF returns 409 during N1N2MessageTransfer
- **Causes**: Registration ongoing, handover in progress, CM-IDLE state
- **Solution**: Messages automatically queued and retried

**3. Policy Not Delivered**
- **Issue**: UE doesn't receive policy
- **Checks**: UE CM-Connected state, NAS transport capability, queue processing

**4. Queue Timeout**
- **Issue**: Messages discarded after 30 seconds
- **Cause**: Registration stuck or taking too long
- **Solution**: Check registration procedure logs

## Future Enhancements

### Planned Improvements

1. **Full Policy Container Support**: Complete URSP rules and traffic descriptors
2. **UDR Integration**: Full PSI CRUD operations with proper versioning
3. **Policy Fragmentation**: Support for large policy payloads
4. **Enhanced Retry Logic**: Sophisticated failure recovery mechanisms
5. **Configurable Timeout**: Make FIFO queue timeout configurable
6. **Priority Queuing**: Support message priorities within FIFO order
7. **Performance Optimization**: Caching and connection pooling improvements

### 3GPP Compliance Extensions

1. **Additional Policy Types**: ANDSP and other policy container types
2. **Policy Versioning**: Proper PSI tracking with timestamps
3. **Conflict Resolution**: Advanced priority-based conflict handling
4. **Subscription Management**: Dynamic policy update subscriptions

## Related Documentation

### Free5GC Documentation
- `/free5gc/CLAUDE.md` - Free5GC-specific guidance and integration details
- `/CLAUDE.md` - Multi-project repository overview

### 3GPP Specifications
- **TS 23.502**: 5G System Procedures
- **TS 29.525**: Npcf_UEPolicyControl API
- **TS 24.501**: NAS Protocol for 5GS

### External Resources
- [Free5GC Documentation](https://free5gc.org/guide/)
- [3GPP Specifications](https://www.3gpp.org/specifications)
- [Free5GC Forum](https://forum.free5gc.org)

## Cross-References

### Related Features

- **AM Policy Control**: Similar architecture for Access and Mobility policies
- **IPv6 Support**: UE Policy delivery works with IPv6 configurations
- **N3IWF Integration**: UE Policy support for non-3GPP access
- **Multi-UPF Support**: Policy-based UPF selection

### Implementation Patterns

This implementation follows established Free5GC patterns:
- **Service-Based Architecture**: HTTP/2 RESTful APIs
- **OAuth2 Authentication**: Secure inter-NF communication
- **Asynchronous Processing**: Non-blocking operations
- **Comprehensive Logging**: WNC-prefixed operational visibility

## Contributing

When extending this implementation:

1. **Follow 3GPP Specifications**: Maintain compliance with TS 23.502, TS 29.525, TS 24.501
2. **Use WNC Logging**: Prefix all logs with "WNC:" for consistency
3. **Thread Safety**: Use proper mutex protection for concurrent operations
4. **Error Handling**: Implement graceful degradation and proper error responses
5. **Documentation**: Update this README and related docs with changes

## Contact and Support

For questions or issues related to this implementation:

- **Free5GC Forum**: https://forum.free5gc.org
- **GitHub Issues**: https://github.com/free5gc/free5gc/issues
- **Documentation**: Refer to files in this directory

---

**Last Updated:** December 24, 2025
**Implementation Version:** Free5GC v4.0.1 (custom branch: my-changes-v4.0.1)
**Status:** Production Ready
