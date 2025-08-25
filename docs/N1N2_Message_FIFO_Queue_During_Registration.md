# N1N2 Message FIFO Queue During Registration Implementation

## Implementation Date: July 25, 2025

## Overview

This document describes the implementation of a FIFO (First-In-First-Out) queue mechanism for handling multiple N1N2 messages during UE registration procedures in the Free5GC AMF. This feature ensures proper message ordering and prevents message loss when multiple N1N2 messages arrive while a UE is still in the `OnGoingProcedureRegistration` state.

## Problem Statement

### Original Issue
When multiple N1N2 messages (such as UE Policy Container deliveries) arrive during UE registration, the original implementation would:
1. Reject each message with `409 Conflict - TEMPORARY_REJECT_REGISTRATION_ONGOING`
2. Not provide any retry mechanism
3. Potentially lose messages if the sender doesn't implement retry logic
4. Process messages out of order if multiple concurrent requests were made

### Requirements
1. **FIFO Processing**: Messages must be processed in the order they were received
2. **Timeout Handling**: If registration doesn't complete within 30 seconds, queued messages should be discarded
3. **Thread Safety**: Multiple concurrent messages must be handled safely
4. **Resource Management**: Queue processor should be properly started/stopped

## Architecture

### Core Components

#### 1. N1N2MessageQueueItem Structure
```go
type N1N2MessageQueueItem struct {
    UeContextID                string
    ReqUri                     string
    N1N2MessageTransferRequest models.N1N2MessageTransferRequest
    Timestamp                  time.Time
    RetryCount                 int
}
```

#### 2. N1N2MessageQueue Structure
```go
type N1N2MessageQueue struct {
    Items []N1N2MessageQueueItem
    mutex sync.Mutex
}
```

**Methods:**
- `Enqueue(item N1N2MessageQueueItem)`: Add message to end of queue (FIFO)
- `Dequeue() (N1N2MessageQueueItem, bool)`: Remove and return first message
- `IsEmpty() bool`: Check if queue is empty
- `Size() int`: Return number of queued messages

#### 3. AmfUe Context Enhancement
```go
type AmfUe struct {
    // ... existing fields ...
    N1N2MessageQueue       *N1N2MessageQueue
    N1N2QueueProcessorStop chan bool
}
```

#### 4. Queue Processor Methods
- `StartN1N2QueueProcessor()`: Start background processor goroutine
- `StopN1N2QueueProcessor()`: Stop processor goroutine

### Message Flow

#### Normal Operation (No Registration Ongoing)
```
1. N1N2MessageTransferRequest arrives
2. Check ue.OnGoing().Procedure
3. If OnGoingProcedureNothing → Process immediately
4. Return response to sender
```

#### During Registration (OnGoingProcedureRegistration)
```
1. N1N2MessageTransferRequest arrives
2. Check ue.OnGoing().Procedure == OnGoingProcedureRegistration
3. Create N1N2MessageQueueItem with timestamp
4. Enqueue message to ue.N1N2MessageQueue
5. Start queue processor (if first message)
6. Return 409 Conflict response to sender
7. Queue processor monitors registration state
8. When OnGoingProcedureNothing → Process all queued messages in FIFO order
```

#### Timeout Handling
```
1. Queue processor runs with 30-second timeout
2. Every 100ms, check if registration complete
3. If timeout reached:
   - Log warning with queue size
   - Clear all queued messages
   - Stop processor
```

## Implementation Details

### File Modifications

#### 1. `/NFs/amf/internal/context/amf_ue.go`
- **Added**: `N1N2MessageQueueItem` struct
- **Added**: `N1N2MessageQueue` struct with thread-safe methods
- **Added**: Queue fields to `AmfUe` struct
- **Added**: Queue initialization in UE constructor
- **Added**: `StartN1N2QueueProcessor()` method
- **Added**: `StopN1N2QueueProcessor()` method

#### 2. `/NFs/amf/internal/sbi/processor/n1n2message.go`
- **Added**: `time` import
- **Modified**: `OnGoingProcedureRegistration` case to use FIFO queue
- **Added**: Queue item creation and enqueuing logic
- **Added**: Queue processor startup logic

### Key Implementation Features

#### Thread Safety
- `sync.Mutex` protects queue operations
- UE context lock prevents race conditions
- Channel-based processor stop mechanism

#### FIFO Guarantee
- `append()` adds to end of slice
- `Items[0]` and `Items[1:]` removes from front
- Sequential processing in queue processor

#### Memory Management
- Queue cleared on timeout
- Processor goroutine terminates after processing
- Stop channel prevents goroutine leaks

#### Logging
- All log messages prefixed with `"WNC:"` for easy tracing
- Queue size logging for operational visibility
- Timestamp logging for message processing order verification

## Usage Example

### Scenario: Multiple UE Policy Messages
```
Time: T0 - UE starts registration (OnGoingProcedureRegistration)
Time: T1 - PCF sends UE Policy Message #1 → Queued (queue size: 1)
Time: T2 - PCF sends UE Policy Message #2 → Queued (queue size: 2)  
Time: T3 - PCF sends UE Policy Message #3 → Queued (queue size: 3)
Time: T4 - Registration completes (OnGoingProcedureNothing)
Time: T5 - Queue processor processes Message #1 (FIFO)
Time: T6 - Queue processor processes Message #2 (FIFO)
Time: T7 - Queue processor processes Message #3 (FIFO)
Time: T8 - Queue processor terminates
```

### Log Output Example
```
[INFO][Producer] WNC: Queued N1N2 message for UE imsi-466110000000548 during registration (queue size: 1)
[INFO][Producer] WNC: Starting N1N2 queue processor for UE imsi-466110000000548
[INFO][Producer] WNC: Queued N1N2 message for UE imsi-466110000000548 during registration (queue size: 2)
[INFO][Producer] WNC: Queued N1N2 message for UE imsi-466110000000548 during registration (queue size: 3)
[INFO][Gmm] WNC: Processing queued N1N2 message for UE imsi-466110000000548 (queued at 2025-07-25 10:30:15)
[INFO][Gmm] WNC: Processing queued N1N2 message for UE imsi-466110000000548 (queued at 2025-07-25 10:30:16)
[INFO][Gmm] WNC: Processing queued N1N2 message for UE imsi-466110000000548 (queued at 2025-07-25 10:30:17)
```

## Error Handling

### Timeout Scenarios
- **Registration stuck**: 30-second timeout prevents infinite waiting
- **Messages discarded**: All queued messages cleared on timeout
- **Warning logged**: Operational visibility of timeout events

### Edge Cases
- **Queue processor already running**: Idempotent start logic
- **Empty queue dequeue**: Safe handling returns false
- **Concurrent access**: Mutex protection prevents corruption
- **Processor stop**: Channel mechanism prevents blocking

## Performance Considerations

### Memory Usage
- Each queued message stores full `N1N2MessageTransferRequest`
- Queue cleared after processing or timeout
- No memory leaks from processor goroutines

### CPU Usage
- Queue processor polls every 100ms (minimal overhead)
- Sequential message processing (no unnecessary parallelism)
- Processor terminates after completing work

### Scalability
- One queue per UE (isolated processing)
- Queue size limited by 30-second timeout window
- Thread-safe operations support concurrent UEs

## Future Enhancements

### Potential Improvements
1. **Configurable Timeout**: Make 30-second timeout configurable
2. **Priority Queuing**: Support message priorities within FIFO order
3. **Persistent Queue**: Survive AMF restarts (if needed)
4. **Queue Size Limits**: Prevent memory exhaustion under extreme load
5. **Retry Counts**: Track and limit retry attempts per message
6. **Metrics**: Queue depth and processing time metrics

### Integration Points
1. **Registration Completion Event**: Trigger immediate queue processing
2. **UE Cleanup**: Ensure queue cleanup on UE context deletion
3. **Load Balancing**: Consider queue state in UE distribution

## Testing Strategy

### Unit Tests
- Queue operations (enqueue/dequeue)
- Thread safety verification
- Timeout handling
- Message ordering validation

### Integration Tests
- Multiple concurrent messages during registration
- Registration completion triggering
- Timeout scenarios
- Resource cleanup verification

### Performance Tests
- Queue processing under load
- Memory usage patterns
- Processor goroutine lifecycle

## Build and Deployment

### Build Commands
```bash
make amf    # Build AMF with FIFO queue support
make all    # Build complete system
```

### Verification Steps
1. **Compilation**: Ensure all files compile without errors
2. **Functionality**: Test message queuing during registration
3. **FIFO Order**: Verify messages processed in correct order
4. **Timeout**: Test 30-second timeout handling
5. **Cleanup**: Verify no goroutine or memory leaks

## Conclusion

This implementation provides a robust, production-ready solution for handling multiple N1N2 messages during UE registration procedures. The FIFO queue ensures message ordering, timeout handling prevents resource leaks, and comprehensive logging provides operational visibility.

The design is extensible and can be enhanced with additional features as needed while maintaining backward compatibility with existing Free5GC deployments.