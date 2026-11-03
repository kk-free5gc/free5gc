# Recover From a Lost PDU Session Release Complete Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the SMF and the AMF recover by themselves when a UE's PDU Session Release Complete is lost
on the radio side, so that a stale PFCP Session Deletion never removes another PDU session's UPF
session, and every PDU Session Release Request gets an answer.

**Architecture:** All decisions come from §6 of the ISSUE doc below. The SMF skips the PFCP Session
Deletion when a release arrives while the SM context is in `InActivePending` (change 1a, defect 1). The
SMF accepts a deletion answer of `Session context not found` as a successful release, with a warning
(defect 3). The last T3592 expiry releases the SM context locally (defect 5). The T3592 resend callback
always unlocks `SMLock` (defect 6). The AMF forwards the SMF's N1 Release Reject to the UE (defect 4).
The UPF is not changed.

**Tech Stack:** Go 1.21, gin, `github.com/free5gc/pfcp` v1.0.7, `github.com/free5gc/openapi`,
testify `require`.

**Spec:** `wnc_docs/2026-10-30_wnc_ISSUE_new_pdu_session_no_ipv6_prefix_and_release_request_unanswered_DUE_TO_smf_deletes_reused_up_seid_after_lost_release_complete.md`,
§4 (defects) and §6 (decision).

## Global Constraints

- Put every `#WNC` comment on its own line above the code, never at the end of a code line.
- Tag new comments and new log lines as `#WNC TOPIC/SUB`, not `WNC:`.
- Tags used by this plan, SMF: `#WNC LOST-RELEASE-COMPLETE/SKIP-PFCP`, `#WNC LOST-RELEASE-COMPLETE/NOT-FOUND`, `#WNC LOST-RELEASE-COMPLETE/T3592-LAST-EXPIRY`, `#WNC LOST-RELEASE-COMPLETE/T3592-UNLOCK`.
- Tag used by this plan, AMF: `#WNC SMF-REJECT/FORWARD`, the tag that AMF commit `a3caee8` already uses.
- Write comments in full sentences, one idea in each. Do not use `we` or `us`.
- Do not change `NFs/upf`. Leave the uncommitted `NFs/upf/go.mod` and `NFs/upf/go.sum` edits as they are.
- The normal UE-requested release must behave exactly as before: same PFCP messages, same answers, same log lines.
- Commit only after the tester approves, with `git -c user.email=lori041987@users.noreply.github.com commit`.
- End every commit message with the line `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Do not put test-run names (such as `test13`) in commit messages.
- Run Go commands inside the submodule directory, `NFs/smf` or `NFs/amf`.
- Line numbers in this plan refer to the code before Task 1. Earlier tasks move later code, so find each place by the quoted code, not by the line number.

## Baseline

Before Task 1, these pass (checked on 2026-11-02):

```
cd NFs/smf && go test ./internal/sbi/processor/ ./internal/pfcp/message/
ok  	github.com/free5gc/smf/internal/sbi/processor
ok  	github.com/free5gc/smf/internal/pfcp/message
cd NFs/amf && go test ./internal/gmm/
ok  	github.com/free5gc/amf/internal/gmm
```

## File Map

| File | Change | Task |
|---|---|---|
| `NFs/smf/internal/sbi/processor/pdu_session.go` | `releaseTunnel` variable, `upfSessionAlreadyDeleted`, `staleUpSeids`; 1a in `HandlePDUSessionSMContextRelease` and `HandlePDUSessionSMContextLocalRelease` | 1 |
| `NFs/smf/internal/sbi/processor/lost_release_complete_test.go` | new: `fakeSmf`, test helpers, tests for Tasks 1, 2 and 3 | 1, 2, 3 |
| `NFs/smf/internal/pfcp/message/send.go` | `isDeletionSessionNotFound`; the SEID check lets that answer through | 2 |
| `NFs/smf/internal/pfcp/message/send_lost_release_complete_test.go` | new: test of `isDeletionSessionNotFound` | 2 |
| `NFs/smf/internal/sbi/processor/datapath.go` | `deletionStatus`; `deletePfcpSession` uses it and logs the not-found case | 2 |
| `NFs/smf/internal/sbi/processor/pdu_session.go` | T3592 callbacks moved into `resendReleaseCommand` and `releaseOnLastT3592Expiry` | 3 |
| `NFs/amf/internal/gmm/handler.go` | `smfUpdateRejectN1Message`; `forward5GSMMessageToSMF` forwards the reject first | 4 |
| `NFs/amf/internal/gmm/handler_reject_test.go` | test of `smfUpdateRejectN1Message` | 4 |
| ISSUE doc §6, §7, §13 | record what was implemented and verified | 5 |

## Not in this plan

- **The `InActive` window.** The Release Complete branch (`pdu_session.go:469-481`) sets `InActive` and
  keeps the SM context when the gNB's N2 PDU Session Resource Release Response has not arrived yet. A
  Release SM Context in that window would also send a deletion to a stale UP SEID. Change 1a checks
  only `InActivePending`, as agreed. This window has not been seen in a run.
- **Two UPFs on one PDU session.** Change 1b would cover a deletion that one UPF accepted and another
  refused. The test setup has one UPF, so change 1b was not chosen.
- **The T3592 retry count.** `smfcfg.yaml` sets `maxRetryTimes: 3`; TS 24.501 §6.3.3.5 retransmits
  four times. The value stays as it is.

---

### Task 1: Skip the PFCP deletion in `InActivePending` (defect 1, change 1a)

**Files:**
- Modify: `NFs/smf/internal/sbi/processor/pdu_session.go` (`releaseSession` near line 1142, `HandlePDUSessionSMContextRelease` lines 1005-1012, `HandlePDUSessionSMContextLocalRelease` lines 1105-1107)
- Create: `NFs/smf/internal/sbi/processor/lost_release_complete_test.go`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces:
  - `var releaseTunnel func(*smf_context.SMContext) []SendPfcpResult` — package variable, default `ReleaseTunnel`; tests replace it.
  - `func upfSessionAlreadyDeleted(smContext *smf_context.SMContext) bool`
  - `func staleUpSeids(smContext *smf_context.SMContext) string`
  - test helpers in package `processor`: `type fakeSmf`, `func newTestProcessor(t *testing.T) *Processor`, `func stubReleaseTunnel(t *testing.T) *int`, `func newTestSMContext(t *testing.T, psi int32, state smf_context.SMContextState) *smf_context.SMContext`

- [ ] **Step 1: Route `releaseSession` through a replaceable variable**

This step changes no behaviour. It lets a test count the PFCP Session Deletions without a UPF.

In `NFs/smf/internal/sbi/processor/pdu_session.go`, replace:

```go
func releaseSession(smContext *smf_context.SMContext) smf_context.PFCPSessionResponseStatus {
	smContext.SetState(smf_context.PFCPModification)

	for _, res := range ReleaseTunnel(smContext) {
```

with:

```go
// #WNC LOST-RELEASE-COMPLETE/SKIP-PFCP
// releaseTunnel is ReleaseTunnel. Tests replace it to count the PFCP Session Deletions that releaseSession
// would send, without a UPF.
var releaseTunnel = ReleaseTunnel

func releaseSession(smContext *smf_context.SMContext) smf_context.PFCPSessionResponseStatus {
	smContext.SetState(smf_context.PFCPModification)

	for _, res := range releaseTunnel(smContext) {
```

Run: `cd NFs/smf && go build ./... && go test ./internal/sbi/processor/`
Expected: build succeeds, `ok  	github.com/free5gc/smf/internal/sbi/processor`.

- [ ] **Step 2: Write the failing handler tests**

Create `NFs/smf/internal/sbi/processor/lost_release_complete_test.go`:

```go
package processor

import (
	"math"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"

	"github.com/free5gc/openapi/models"
	smf_context "github.com/free5gc/smf/internal/context"
	"github.com/free5gc/smf/internal/sbi/consumer"
	"github.com/free5gc/smf/pkg/factory"
	"github.com/free5gc/util/idgenerator"
)

// #WNC LOST-RELEASE-COMPLETE/SKIP-PFCP
// fakeSmf gives the processor the SMF context and a consumer without starting the SMF. The test package
// cannot import pkg/service, because pkg/service imports this package.
type fakeSmf struct {
	consumer *consumer.Consumer
}

func (f *fakeSmf) SetLogEnable(bool)                  {}
func (f *fakeSmf) SetLogLevel(string)                 {}
func (f *fakeSmf) SetReportCaller(bool)               {}
func (f *fakeSmf) Start()                             {}
func (f *fakeSmf) Terminate()                         {}
func (f *fakeSmf) Context() *smf_context.SMFContext   { return smf_context.GetSelf() }
func (f *fakeSmf) Config() *factory.Config            { return factory.SmfConfig }
func (f *fakeSmf) Consumer() *consumer.Consumer       { return f.consumer }

func newTestProcessor(t *testing.T) *Processor {
	t.Helper()
	gin.SetMode(gin.TestMode)
	if smf_context.GetSelf().Ues == nil {
		smf_context.GetSelf().Ues = smf_context.InitSmfUeData()
	}
	// NewSMContext allocates a TEID. InitSmfContext normally creates the generator.
	if smf_context.TeidGenerator == nil {
		smf_context.TeidGenerator = idgenerator.NewGenerator(1, math.MaxUint32)
	}
	f := &fakeSmf{}
	c, err := consumer.NewConsumer(f)
	require.NoError(t, err)
	f.consumer = c
	p, err := NewProcessor(f)
	require.NoError(t, err)
	return p
}

// stubReleaseTunnel replaces releaseTunnel for one test. The returned counter holds how many times
// releaseSession tried to send PFCP Session Deletions.
func stubReleaseTunnel(t *testing.T) *int {
	t.Helper()
	calls := 0
	orig := releaseTunnel
	releaseTunnel = func(*smf_context.SMContext) []SendPfcpResult {
		calls++
		return []SendPfcpResult{{Status: smf_context.SessionReleaseSuccess}}
	}
	t.Cleanup(func() { releaseTunnel = orig })
	return &calls
}

// newTestSMContext builds an SM context that still holds UP SEID 0x3 for one UPF, as PSI 15 did after
// its UPF session was deleted.
func newTestSMContext(t *testing.T, psi int32, state smf_context.SMContextState) *smf_context.SMContext {
	t.Helper()
	smContext := smf_context.NewSMContext("imsi-208930000007487", psi)
	// Supi is a field of the embedded create data, which Create SM Context fills in a real run.
	smContext.SmfPduSessionSmContextCreateData = &models.SmfPduSessionSmContextCreateData{
		Supi:         "imsi-208930000007487",
		PduSessionId: psi,
	}
	smContext.PFCPContext["127.0.0.8"] = &smf_context.PFCPSessionContext{RemoteSEID: 0x3}
	smContext.SetState(state)
	t.Cleanup(func() { smf_context.RemoveSMContext(smContext.Ref) })
	return smContext
}

func smContextRemoved(ref string) func() bool {
	return func() bool { return smf_context.GetSMContextByRef(ref) == nil }
}

// #WNC LOST-RELEASE-COMPLETE/SKIP-PFCP
// The AMF's Release SM Context for a PSI in InActivePending must not send a PFCP Session Deletion, must
// answer 204 and must remove the SM context.
func TestReleaseSMContextInActivePendingSendsNoPfcp(t *testing.T) {
	p := newTestProcessor(t)
	calls := stubReleaseTunnel(t)
	smContext := newTestSMContext(t, 15, smf_context.InActivePending)
	ref := smContext.Ref

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	p.HandlePDUSessionSMContextRelease(c, models.ReleaseSmContextRequest{}, ref)

	require.Equal(t, 0, *calls, "a PFCP Session Deletion was sent for a deleted UPF session")
	require.Equal(t, http.StatusNoContent, c.Writer.Status())
	require.Eventually(t, smContextRemoved(ref), time.Second, 10*time.Millisecond)
}

// #WNC LOST-RELEASE-COMPLETE/SKIP-PFCP
// A new Establishment Request that reuses the PSI of an SM context in InActivePending must not send a
// PFCP Session Deletion for the old context.
func TestLocalReleaseInActivePendingSendsNoPfcp(t *testing.T) {
	p := newTestProcessor(t)
	calls := stubReleaseTunnel(t)
	smContext := newTestSMContext(t, 15, smf_context.InActivePending)
	ref := smContext.Ref

	p.HandlePDUSessionSMContextLocalRelease(smContext, &models.SmfPduSessionSmContextCreateData{})

	require.Equal(t, 0, *calls, "a PFCP Session Deletion was sent for a deleted UPF session")
	require.Eventually(t, smContextRemoved(ref), time.Second, 10*time.Millisecond)
}
```

In this file, `c.Writer.Status()` is read instead of `w.Code`. gin writes the status of `c.Status(204)`
into the recorder only when a body is written, so `w.Code` would still read `200`.

- [ ] **Step 3: Run the tests to see them fail**

Run: `cd NFs/smf && go test ./internal/sbi/processor/ -run 'InActivePendingSendsNoPfcp' -v`
Expected: both tests FAIL with `a PFCP Session Deletion was sent for a deleted UPF session`, `expected: 0, actual: 1`.

- [ ] **Step 4: Add `upfSessionAlreadyDeleted` and `staleUpSeids`**

In `pdu_session.go`, add `"sort"` to the standard-library import block (between `"reflect"` and
`"strings"`). Then add these two functions directly below `releaseSession`:

```go
// #WNC LOST-RELEASE-COMPLETE/SKIP-PFCP
// upfSessionAlreadyDeleted reports whether the UPF session of this PDU session is already gone. The SMF
// sets InActivePending only after the UPF accepted a PFCP Session Deletion, after a pdu-drop deleted the
// session, or after the UPF association was lost. A release that arrives in this state means that the
// UE's PDU Session Release Complete did not reach the SMF. A second deletion would carry a UP SEID that
// the UPF may already have given to another PDU session, so the caller must not send one.
func upfSessionAlreadyDeleted(smContext *smf_context.SMContext) bool {
	if !smContext.CheckState(smf_context.InActivePending) {
		return false
	}
	smContext.Log.Warnf("#WNC LOST-RELEASE-COMPLETE/SKIP-PFCP release in InActivePending: "+
		"PDU Session Release Complete was not received and the UPF session is already deleted, "+
		"so no PFCP Session Deletion is sent to the stale UP SEID [%s]", staleUpSeids(smContext))
	return true
}

// #WNC LOST-RELEASE-COMPLETE/SKIP-PFCP
// staleUpSeids lists the UP SEID that the SMF still holds for each UPF, as "<UPF IP>=<UP SEID>", for the
// log line in upfSessionAlreadyDeleted.
func staleUpSeids(smContext *smf_context.SMContext) string {
	parts := make([]string, 0, len(smContext.PFCPContext))
	for nodeIP, pfcpCtx := range smContext.PFCPContext {
		parts = append(parts, fmt.Sprintf("%s=%#x", nodeIP, pfcpCtx.RemoteSEID))
	}
	sort.Strings(parts)
	return strings.Join(parts, ",")
}
```

- [ ] **Step 5: Use it in `HandlePDUSessionSMContextRelease`**

The check must run before the state is changed to `PFCPModification`, because that change hides
`InActivePending`. Replace:

```go
	if !smContext.CheckState(smf_context.InActive) {
		smContext.SetState(smf_context.PFCPModification)
	}
	pfcpResponseStatus := releaseSession(smContext)
```

with:

```go
	// #WNC LOST-RELEASE-COMPLETE/SKIP-PFCP
	// In InActivePending the UPF session is already deleted, so only the PFCP Session Deletion is skipped.
	// The cleanup above and RemoveSMContextFromAllNF at the end of this function still run.
	var pfcpResponseStatus smf_context.PFCPSessionResponseStatus
	if upfSessionAlreadyDeleted(smContext) {
		pfcpResponseStatus = smf_context.SessionReleaseSuccess
	} else {
		if !smContext.CheckState(smf_context.InActive) {
			smContext.SetState(smf_context.PFCPModification)
		}
		pfcpResponseStatus = releaseSession(smContext)
	}
```

- [ ] **Step 6: Use it in `HandlePDUSessionSMContextLocalRelease`**

Replace:

```go
	smContext.SetState(smf_context.PFCPModification)

	pfcpResponseStatus := releaseSession(smContext)
```

with:

```go
	// #WNC LOST-RELEASE-COMPLETE/SKIP-PFCP
	// A new Establishment Request reused the PSI of this SM context. If this context is in InActivePending,
	// its UPF session is already deleted, so no PFCP Session Deletion is sent.
	var pfcpResponseStatus smf_context.PFCPSessionResponseStatus
	if upfSessionAlreadyDeleted(smContext) {
		pfcpResponseStatus = smf_context.SessionReleaseSuccess
	} else {
		smContext.SetState(smf_context.PFCPModification)
		pfcpResponseStatus = releaseSession(smContext)
	}
```

- [ ] **Step 7: Run the tests to see them pass**

Run: `cd NFs/smf && go test ./internal/sbi/processor/ -run 'InActivePendingSendsNoPfcp' -v`
Expected: both tests PASS. The log shows one `#WNC LOST-RELEASE-COMPLETE/SKIP-PFCP` line per test, ending in `[127.0.0.8=0x3]`.

- [ ] **Step 8: Add the tests that keep the normal release unchanged**

Append to `lost_release_complete_test.go`:

```go
// #WNC LOST-RELEASE-COMPLETE/SKIP-PFCP
// Only InActivePending skips the deletion. In every other state the UPF session may still exist.
func TestUpfSessionAlreadyDeleted(t *testing.T) {
	cases := []struct {
		state smf_context.SMContextState
		want  bool
	}{
		{smf_context.InActivePending, true},
		{smf_context.Active, false},
		{smf_context.ActivePending, false},
		{smf_context.ModificationPending, false},
		{smf_context.InActive, false},
	}
	for _, tc := range cases {
		t.Run(tc.state.String(), func(t *testing.T) {
			smContext := newTestSMContext(t, 15, tc.state)
			require.Equal(t, tc.want, upfSessionAlreadyDeleted(smContext))
		})
	}
}

// #WNC LOST-RELEASE-COMPLETE/SKIP-PFCP
// A Release SM Context for an Active PDU session still deletes its UPF session, as before the change.
func TestReleaseSMContextActiveStillSendsPfcp(t *testing.T) {
	p := newTestProcessor(t)
	calls := stubReleaseTunnel(t)
	smContext := newTestSMContext(t, 16, smf_context.Active)

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	p.HandlePDUSessionSMContextRelease(c, models.ReleaseSmContextRequest{}, smContext.Ref)

	require.Equal(t, 1, *calls)
	require.Equal(t, http.StatusNoContent, c.Writer.Status())
}

func TestStaleUpSeids(t *testing.T) {
	smContext := newTestSMContext(t, 15, smf_context.InActivePending)
	smContext.PFCPContext["127.0.0.9"] = &smf_context.PFCPSessionContext{RemoteSEID: 0x1a}
	require.Equal(t, "127.0.0.8=0x3,127.0.0.9=0x1a", staleUpSeids(smContext))
}
```

`TestReleaseSMContextActiveStillSendsPfcp` also runs `ReleaseChargingSession`. With no CHF selected,
that call logs `Send Charging Data Request[Termination] Failed Problem` and returns; the error does not
affect the test.

- [ ] **Step 9: Run the whole package and vet**

Run: `cd NFs/smf && go vet ./internal/sbi/processor/ && go test ./internal/sbi/processor/`
Expected: no vet output, `ok  	github.com/free5gc/smf/internal/sbi/processor`.

- [ ] **Step 10: Commit (only after the tester approves)**

```bash
cd NFs/smf
git add internal/sbi/processor/pdu_session.go internal/sbi/processor/lost_release_complete_test.go
git -c user.email=lori041987@users.noreply.github.com commit -m "fix(smf): skip the PFCP deletion when a release arrives in InActivePending

A release that arrives while the SM context is in InActivePending means that
the UE's PDU Session Release Complete was lost. The UPF session is already
deleted, and the UPF may have given its UP SEID to another PDU session, so a
second PFCP Session Deletion removed that other session.

HandlePDUSessionSMContextRelease and HandlePDUSessionSMContextLocalRelease now
skip the deletion in InActivePending and log #WNC LOST-RELEASE-COMPLETE/SKIP-PFCP.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
cd ../..
```

### Task 2: Accept `Session context not found` as a successful release, with a warning (defect 3)

**Files:**
- Modify: `NFs/smf/internal/pfcp/message/send.go` (`SendPfcpSessionDeletionRequest`, the SEID check at lines 342-346)
- Create: `NFs/smf/internal/pfcp/message/send_lost_release_complete_test.go`
- Modify: `NFs/smf/internal/sbi/processor/datapath.go` (`deletePfcpSession`, lines 455-486)
- Modify: `NFs/smf/internal/sbi/processor/lost_release_complete_test.go`

**Interfaces:**
- Consumes: `lost_release_complete_test.go` from Task 1 (package `processor`, imports `require` and `smf_context`).
- Produces:
  - `func isDeletionSessionNotFound(msg *pfcpUdp.Message) bool` in package `message`
  - `func deletionStatus(cause *pfcpType.Cause) (smf_context.PFCPSessionResponseStatus, bool)` in package `processor`

How the UPF answers a deletion for an unknown UP SEID: `NFs/upf/internal/pfcp/session.go:343-355`
sends a PFCP Session Deletion Response with header SEID `0` and cause `Session context not found`.
Today the SMF's SEID check rejects that answer before the cause is read, so the release fails with
`500`. After this task, the release succeeds, and the SMF logs a warning, because the answer can also
mean that the SMF looked up the wrong session.

- [ ] **Step 1: Write the failing tests**

Create `NFs/smf/internal/pfcp/message/send_lost_release_complete_test.go`:

```go
package message

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/free5gc/pfcp"
	"github.com/free5gc/pfcp/pfcpType"
	"github.com/free5gc/pfcp/pfcpUdp"
)

func deletionResponse(seid uint64, cause *pfcpType.Cause) *pfcpUdp.Message {
	return &pfcpUdp.Message{
		PfcpMessage: &pfcp.Message{
			Header: pfcp.Header{MessageType: pfcp.PFCP_SESSION_DELETION_RESPONSE, SEID: seid},
			Body:   pfcp.PFCPSessionDeletionResponse{Cause: cause},
		},
	}
}

// #WNC LOST-RELEASE-COMPLETE/NOT-FOUND
// Only header SEID 0 together with cause "Session context not found" passes the SEID check.
func TestIsDeletionSessionNotFound(t *testing.T) {
	notFound := &pfcpType.Cause{CauseValue: pfcpType.CauseSessionContextNotFound}
	accepted := &pfcpType.Cause{CauseValue: pfcpType.CauseRequestAccepted}
	cases := []struct {
		name string
		msg  *pfcpUdp.Message
		want bool
	}{
		{"SEID 0 and session context not found", deletionResponse(0, notFound), true},
		{"SEID 0 and request accepted", deletionResponse(0, accepted), false},
		{"SEID 0 and no cause", deletionResponse(0, nil), false},
		{"CP SEID 0x1a and session context not found", deletionResponse(0x1a, notFound), false},
		{"no message", nil, false},
		{"no PFCP message", &pfcpUdp.Message{}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			require.Equal(t, tc.want, isDeletionSessionNotFound(tc.msg))
		})
	}
}
```

Append to `NFs/smf/internal/sbi/processor/lost_release_complete_test.go`, and add
`"github.com/free5gc/pfcp/pfcpType"` to its import block:

```go
// #WNC LOST-RELEASE-COMPLETE/NOT-FOUND
// "Session context not found" counts as a successful release and is flagged for the warning log.
func TestDeletionStatus(t *testing.T) {
	cases := []struct {
		name         string
		cause        *pfcpType.Cause
		wantStatus   smf_context.PFCPSessionResponseStatus
		wantNotFound bool
	}{
		{"request accepted", &pfcpType.Cause{CauseValue: pfcpType.CauseRequestAccepted},
			smf_context.SessionReleaseSuccess, false},
		{"session context not found", &pfcpType.Cause{CauseValue: pfcpType.CauseSessionContextNotFound},
			smf_context.SessionReleaseSuccess, true},
		{"request rejected", &pfcpType.Cause{CauseValue: pfcpType.CauseRequestRejected},
			smf_context.SessionReleaseFailed, false},
		{"no cause", nil, smf_context.SessionReleaseFailed, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			status, notFound := deletionStatus(tc.cause)
			require.Equal(t, tc.wantStatus, status)
			require.Equal(t, tc.wantNotFound, notFound)
		})
	}
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd NFs/smf && go test ./internal/pfcp/message/ ./internal/sbi/processor/ -run 'IsDeletionSessionNotFound|DeletionStatus'`
Expected: FAIL with `undefined: isDeletionSessionNotFound` and `undefined: deletionStatus`.

- [ ] **Step 3: Let the not-found answer through the SEID check in `send.go`**

In `NFs/smf/internal/pfcp/message/send.go`, inside `SendPfcpSessionDeletionRequest`, replace:

```go
	localSEID := ctx.PFCPContext[nodeIDtoIP.String()].LocalSEID
	if resMsg.PfcpMessage.Header.SEID != localSEID {
		return resMsg, fmt.Errorf("received unexpected SEID response message: %+v, exptcted: %d",
			resMsg.PfcpMessage.Header, localSEID)
	}

	return resMsg, nil
}
```

with:

```go
	localSEID := ctx.PFCPContext[nodeIDtoIP.String()].LocalSEID
	if resMsg.PfcpMessage.Header.SEID != localSEID {
		// #WNC LOST-RELEASE-COMPLETE/NOT-FOUND
		// A UPF that has no session for the UP SEID answers with SEID 0, so the SEID check would reject the
		// answer before its cause is read. deletePfcpSession decides what that cause means.
		if isDeletionSessionNotFound(resMsg) {
			return resMsg, nil
		}
		return resMsg, fmt.Errorf("received unexpected SEID response message: %+v, exptcted: %d",
			resMsg.PfcpMessage.Header, localSEID)
	}

	return resMsg, nil
}

// #WNC LOST-RELEASE-COMPLETE/NOT-FOUND
// isDeletionSessionNotFound reports whether a PFCP Session Deletion Response says that the UPF has no
// session for the UP SEID in the request. The UPF then sends header SEID 0 and the cause "Session context
// not found", as NFs/upf/internal/pfcp/session.go does.
func isDeletionSessionNotFound(msg *pfcpUdp.Message) bool {
	if msg == nil || msg.PfcpMessage == nil || msg.PfcpMessage.Header.SEID != 0 {
		return false
	}
	rsp, ok := msg.PfcpMessage.Body.(pfcp.PFCPSessionDeletionResponse)
	return ok && rsp.Cause != nil && rsp.Cause.CauseValue == pfcpType.CauseSessionContextNotFound
}
```

`send.go` already imports `pfcp`, `pfcpType` and `pfcpUdp`.

- [ ] **Step 4: Map the cause to a status in `datapath.go`**

In `NFs/smf/internal/sbi/processor/datapath.go`, replace the body of `deletePfcpSession` from
`rsp := rcvMsg.PfcpMessage.Body.(pfcp.PFCPSessionDeletionResponse)` to the end of the function:

```go
	rsp := rcvMsg.PfcpMessage.Body.(pfcp.PFCPSessionDeletionResponse)
	if rsp.Cause != nil && rsp.Cause.CauseValue == pfcpType.CauseRequestAccepted {
		logger.PduSessLog.Info("Received PFCP Session Deletion Accepted Response")
		resCh <- SendPfcpResult{
			Status: smf_context.SessionReleaseSuccess,
		}
		if rsp.UsageReport != nil {
			SEID := rcvMsg.PfcpMessage.Header.SEID
			upfNodeID := ctx.GetNodeIDByLocalSEID(SEID)
			ctx.HandleReports(nil, nil, rsp.UsageReport, upfNodeID, "")
		}
	} else {
		logger.PduSessLog.Warn("Received PFCP Session Deletion Not Accepted Response")
		resCh <- SendPfcpResult{
			Status: smf_context.SessionReleaseFailed,
			Err:    fmt.Errorf("cause[%d] if not request accepted", rsp.Cause.CauseValue),
		}
	}
}
```

with:

```go
	rsp := rcvMsg.PfcpMessage.Body.(pfcp.PFCPSessionDeletionResponse)
	status, notFound := deletionStatus(rsp.Cause)
	switch {
	case notFound:
		// #WNC LOST-RELEASE-COMPLETE/NOT-FOUND
		// The session to be removed is already gone, so the release succeeds. The answer is still
		// abnormal, because it can also mean that the SMF looked up the wrong session.
		upSeid := ctx.PFCPContext[upf.NodeID.ResolveNodeIdToIp().String()].RemoteSEID
		ctx.Log.Warnf("#WNC LOST-RELEASE-COMPLETE/NOT-FOUND UPF[%s] has no session for UP SEID %#x; "+
			"the UPF session is already gone, so the release continues",
			upf.NodeID.ResolveNodeIdToIp(), upSeid)
		resCh <- SendPfcpResult{Status: status}
	case status == smf_context.SessionReleaseSuccess:
		logger.PduSessLog.Info("Received PFCP Session Deletion Accepted Response")
		resCh <- SendPfcpResult{Status: status}
		if rsp.UsageReport != nil {
			SEID := rcvMsg.PfcpMessage.Header.SEID
			upfNodeID := ctx.GetNodeIDByLocalSEID(SEID)
			ctx.HandleReports(nil, nil, rsp.UsageReport, upfNodeID, "")
		}
	default:
		logger.PduSessLog.Warn("Received PFCP Session Deletion Not Accepted Response")
		resCh <- SendPfcpResult{
			Status: status,
			Err:    fmt.Errorf("PFCP Session Deletion not accepted, cause %+v", rsp.Cause),
		}
	}
}

// #WNC LOST-RELEASE-COMPLETE/NOT-FOUND
// deletionStatus maps the cause of a PFCP Session Deletion Response to a release status. The cause
// "Session context not found" means that the session to be removed is already gone, so the release
// succeeds, and the second return value is true so that the caller logs the abnormal answer.
func deletionStatus(cause *pfcpType.Cause) (smf_context.PFCPSessionResponseStatus, bool) {
	if cause == nil {
		return smf_context.SessionReleaseFailed, false
	}
	switch cause.CauseValue {
	case pfcpType.CauseRequestAccepted:
		return smf_context.SessionReleaseSuccess, false
	case pfcpType.CauseSessionContextNotFound:
		return smf_context.SessionReleaseSuccess, true
	default:
		return smf_context.SessionReleaseFailed, false
	}
}
```

The old error text read `rsp.Cause.CauseValue`, which panicked when the answer had no cause; the new
text prints `rsp.Cause` and works when it is `nil`. `datapath.go` already imports `pfcp` and `pfcpType`.

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd NFs/smf && go test ./internal/pfcp/message/ ./internal/sbi/processor/ -run 'IsDeletionSessionNotFound|DeletionStatus' -v`
Expected: all cases PASS.

- [ ] **Step 6: Run both packages and vet**

Run: `cd NFs/smf && go vet ./internal/pfcp/message/ ./internal/sbi/processor/ && go test ./internal/pfcp/message/ ./internal/sbi/processor/`
Expected: no vet output, two `ok` lines.

- [ ] **Step 7: Commit (only after the tester approves)**

```bash
cd NFs/smf
git add internal/pfcp/message/send.go internal/pfcp/message/send_lost_release_complete_test.go \
  internal/sbi/processor/datapath.go internal/sbi/processor/lost_release_complete_test.go
git -c user.email=lori041987@users.noreply.github.com commit -m "fix(smf): treat a PFCP deletion answer of session context not found as released

A UPF with no session for the UP SEID answers a PFCP Session Deletion with
SEID 0 and cause Session context not found. The SEID check rejected that
answer before its cause was read, so the release failed with 500 and the UE
got no answer.

The SEID check now lets that answer through, deletePfcpSession counts it as a
successful release, and the SMF logs #WNC LOST-RELEASE-COMPLETE/NOT-FOUND,
because the answer can also mean a wrong session lookup.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
cd ../..
```

### Task 3: T3592 — always unlock `SMLock`, and release locally on the last expiry (defects 6 and 5)

**Files:**
- Modify: `NFs/smf/internal/sbi/processor/pdu_session.go` (`sendGSMPDUSessionReleaseCommand`, lines 1194-1240)
- Modify: `NFs/smf/internal/sbi/processor/lost_release_complete_test.go`

**Interfaces:**
- Consumes: from Task 1, `newTestProcessor`, `newTestSMContext` and `smContextRemoved` in `lost_release_complete_test.go`.
- Produces:
  - `func (p *Processor) resendReleaseCommand(ctx context.Context, smContext *smf_context.SMContext, n1n2Request models.N1N2MessageTransferRequest)`
  - `func (p *Processor) releaseOnLastT3592Expiry(smContext *smf_context.SMContext)`

The two T3592 callbacks are closures today, and a test cannot call a closure. Step 1 moves each one into
a method without changing what it does. The tests then fail for the real defects, and Step 4 fixes them.

The spec reasons for defect 5 are in §6 of the ISSUE doc, under "The last T3592 expiry and the specs".
TS 24.501 §6.3.3.5 requires a local release of the PDU session on the last expiry. The AMF answers a
`RELEASED` notification by deleting only its own record, so nothing else removes the SMF's SM context.

- [ ] **Step 1: Move the callbacks into methods, with no change in behaviour**

In `pdu_session.go`, add `"context"` as the first entry of the standard-library import block.

In `sendGSMPDUSessionReleaseCommand`, replace:

```go
		smContext.T3592 = smf_context.NewTimer(t3592.ExpireTime, t3592.MaxRetryTimes, func(expireTimes int32) {
			smContext.SMLock.Lock()
			rspData, errMsgTransfer := p.Consumer().
				N1N2MessageTransfer(ctx, smContext.Supi, n1n2Request, smContext.CommunicationClientApiPrefix)
			if errMsgTransfer != nil {
				logger.ConsumerLog.Warnf("N1N2MessageTransfer for GSMPDUSessionReleaseCommand failed: %+v", errMsgTransfer)
				return
			}

			if rspData.Cause == models.N1N2MessageTransferCause_N1_MSG_NOT_TRANSFERRED {
				smContext.Log.Warnf("%v", rspData.Cause)
			}

			smContext.SMLock.Unlock()
		}, func() {
			smContext.Log.Warn("T3592 Expires 3 times, abort notification procedure")
			smContext.SMLock.Lock()
			smContext.T3592 = nil
			p.SendReleaseNotification(smContext)
			smContext.SMLock.Unlock()
		})
	}
}
```

with:

```go
		smContext.T3592 = smf_context.NewTimer(t3592.ExpireTime, t3592.MaxRetryTimes, func(expireTimes int32) {
			p.resendReleaseCommand(ctx, smContext, n1n2Request)
		}, func() {
			p.releaseOnLastT3592Expiry(smContext)
		})
	}
}

func (p *Processor) resendReleaseCommand(
	ctx context.Context, smContext *smf_context.SMContext, n1n2Request models.N1N2MessageTransferRequest,
) {
	smContext.SMLock.Lock()
	rspData, errMsgTransfer := p.Consumer().
		N1N2MessageTransfer(ctx, smContext.Supi, n1n2Request, smContext.CommunicationClientApiPrefix)
	if errMsgTransfer != nil {
		logger.ConsumerLog.Warnf("N1N2MessageTransfer for GSMPDUSessionReleaseCommand failed: %+v", errMsgTransfer)
		return
	}

	if rspData.Cause == models.N1N2MessageTransferCause_N1_MSG_NOT_TRANSFERRED {
		smContext.Log.Warnf("%v", rspData.Cause)
	}

	smContext.SMLock.Unlock()
}

func (p *Processor) releaseOnLastT3592Expiry(smContext *smf_context.SMContext) {
	smContext.Log.Warn("T3592 Expires 3 times, abort notification procedure")
	smContext.SMLock.Lock()
	smContext.T3592 = nil
	p.SendReleaseNotification(smContext)
	smContext.SMLock.Unlock()
}
```

Run: `cd NFs/smf && go build ./... && go test ./internal/sbi/processor/`
Expected: build succeeds, `ok  	github.com/free5gc/smf/internal/sbi/processor`.

- [ ] **Step 2: Write the failing tests**

Append to `lost_release_complete_test.go`, and add `"context"` to its import block:

```go
// #WNC LOST-RELEASE-COMPLETE/T3592-UNLOCK
// An N1N2MessageTransfer error during a T3592 resend must not leave SMLock held. An empty
// CommunicationClientApiPrefix makes N1N2MessageTransfer fail at once with "client is nil".
func TestResendReleaseCommandUnlocksOnTransferError(t *testing.T) {
	p := newTestProcessor(t)
	smContext := newTestSMContext(t, 15, smf_context.InActivePending)
	smContext.CommunicationClientApiPrefix = ""

	p.resendReleaseCommand(context.Background(), smContext, models.N1N2MessageTransferRequest{})

	require.True(t, smContext.SMLock.TryLock(), "SMLock is still held after an N1N2MessageTransfer error")
	smContext.SMLock.Unlock()
}

// #WNC LOST-RELEASE-COMPLETE/T3592-LAST-EXPIRY
// The last T3592 expiry must release the SM context locally (TS 24.501 clause 6.3.3.5), because the AMF
// does not ask the SMF to release it after the RELEASED notification.
func TestLastT3592ExpiryReleasesSMContext(t *testing.T) {
	p := newTestProcessor(t)
	smContext := newTestSMContext(t, 15, smf_context.InActivePending)
	ref := smContext.Ref

	p.releaseOnLastT3592Expiry(smContext)

	require.Eventually(t, smContextRemoved(ref), time.Second, 10*time.Millisecond,
		"the SM context is still in the SMF after the last T3592 expiry")
	require.True(t, smContext.CheckState(smf_context.InActive))
	require.Nil(t, smContext.T3592)
}
```

The test SM context has an empty `SmStatusNotifyUri`, so neither the old nor the new code sends an HTTP
notification during the test.

- [ ] **Step 3: Run the tests to see them fail**

Run: `cd NFs/smf && go test ./internal/sbi/processor/ -run 'ResendReleaseCommandUnlocks|LastT3592Expiry' -v`
Expected: both FAIL. `TestResendReleaseCommandUnlocksOnTransferError` fails with `SMLock is still held after an N1N2MessageTransfer error`. `TestLastT3592ExpiryReleasesSMContext` fails after one second with `the SM context is still in the SMF after the last T3592 expiry`.

- [ ] **Step 4: Fix both methods**

Replace the two methods from Step 1 with:

```go
// #WNC LOST-RELEASE-COMPLETE/T3592-UNLOCK
// resendReleaseCommand runs on each T3592 expiry before the last one. It used to return on an
// N1N2MessageTransfer error with SMLock still held, so every later request for this PDU session waited
// for ever. The deferred Unlock now runs on every return.
func (p *Processor) resendReleaseCommand(
	ctx context.Context, smContext *smf_context.SMContext, n1n2Request models.N1N2MessageTransferRequest,
) {
	smContext.SMLock.Lock()
	defer smContext.SMLock.Unlock()

	rspData, errMsgTransfer := p.Consumer().
		N1N2MessageTransfer(ctx, smContext.Supi, n1n2Request, smContext.CommunicationClientApiPrefix)
	if errMsgTransfer != nil || rspData == nil {
		logger.ConsumerLog.Warnf("N1N2MessageTransfer for GSMPDUSessionReleaseCommand failed: %+v", errMsgTransfer)
		return
	}

	if rspData.Cause == models.N1N2MessageTransferCause_N1_MSG_NOT_TRANSFERRED {
		smContext.Log.Warnf("%v", rspData.Cause)
	}
}

// #WNC LOST-RELEASE-COMPLETE/T3592-LAST-EXPIRY
// releaseOnLastT3592Expiry runs when T3592 expires for the last time. TS 24.501 clause 6.3.3.5 says that
// the SMF shall then abort the procedure and perform a local release of the PDU session. The SMF used to
// send only the RELEASED notification and keep the SM context. The AMF answers RELEASED by deleting only
// its own record (TS 29.502 clause 5.2.2.5.1), so nothing removed the SMF's SM context.
// RemoveSMContextFromAllNF with sendNotification true releases the SM context and then sends RELEASED.
func (p *Processor) releaseOnLastT3592Expiry(smContext *smf_context.SMContext) {
	smContext.SMLock.Lock()
	defer smContext.SMLock.Unlock()

	smContext.T3592 = nil
	smContext.Log.Warnf("#WNC LOST-RELEASE-COMPLETE/T3592-LAST-EXPIRY T3592 expired for the last time "+
		"in state %s: PDU Session Release Complete was not received, so the SM context is released locally",
		smContext.State())
	p.RemoveSMContextFromAllNF(smContext, true)
}
```

`RemoveSMContextFromAllNF` starts a goroutine that takes `SMLock` before it removes the SM context. That
goroutine waits until the deferred Unlock runs, the same way as in the Release Complete branch at
`pdu_session.go:480`. `rspData == nil` is also checked now. `N1N2MessageTransfer`
(`NFs/smf/internal/sbi/consumer/amf_service.go:56-58`) returns `nil, nil` when the client returns neither
a response nor an error, and the old code would then panic on `rspData.Cause`.

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd NFs/smf && go test ./internal/sbi/processor/ -run 'ResendReleaseCommandUnlocks|LastT3592Expiry' -v`
Expected: both PASS. The log shows one `#WNC LOST-RELEASE-COMPLETE/T3592-LAST-EXPIRY ... in state InActivePending` line.

- [ ] **Step 6: Run the changed packages with the race detector, and vet the module**

Run: `cd NFs/smf && go vet ./... && go test -race ./internal/sbi/processor/ ./internal/pfcp/message/`
Expected: no vet output, two `ok` lines, and no `WARNING: DATA RACE`. Both commands gave this result on
the unchanged tree on 2026-11-02.

- [ ] **Step 7: Commit (only after the tester approves)**

```bash
cd NFs/smf
git add internal/sbi/processor/pdu_session.go internal/sbi/processor/lost_release_complete_test.go
git -c user.email=lori041987@users.noreply.github.com commit -m "fix(smf): release the SM context on the last T3592 expiry and always unlock SMLock

On the last T3592 expiry the SMF sent the RELEASED notification but kept its
SM context. The AMF answers RELEASED by deleting only its own record (TS
29.502 clause 5.2.2.5.1), so the context stayed in InActivePending with a
stale UP SEID. TS 24.501 clause 6.3.3.5 requires a local release instead; the
SMF now calls RemoveSMContextFromAllNF(smContext, true) and logs
#WNC LOST-RELEASE-COMPLETE/T3592-LAST-EXPIRY.

The T3592 resend callback returned on an N1N2MessageTransfer error without
unlocking SMLock, so every later request for that PDU session blocked. The
unlock is now deferred.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
cd ../..
```

### Task 4: The AMF forwards the SMF's Release Reject to the UE (defect 4)

**Files:**
- Modify: `NFs/amf/internal/gmm/handler.go` (`forward5GSMMessageToSMF`, lines 384-404)
- Modify: `NFs/amf/internal/gmm/handler_reject_test.go`

**Interfaces:**
- Consumes: nothing from other tasks. Follows the pattern of `smfRejectN1Message` from AMF commit `a3caee8`.
- Produces: `func smfUpdateRejectN1Message(errResponse *models.UpdateSmContextResponse400) []byte` in package `gmm`.

`SendUpdateSmContextRequest` (`NFs/amf/internal/sbi/consumer/smf_service.go:495-500`) sets `err` for
every non-2xx answer, also when the SMF put a PDU Session Release Reject in the body.
`forward5GSMMessageToSMF` checks `err` first and returns, so the reject branch below it never runs.
`a3caee8` fixed the same order for Create SM Context; this task does the same for Update SM Context.

- [ ] **Step 1: Write the failing test**

Append to `NFs/amf/internal/gmm/handler_reject_test.go`:

```go
// #WNC SMF-REJECT/FORWARD
// TestSmfUpdateRejectN1Message checks that the AMF picks the N1 SM message out of the SMF's error answer
// to Update SM Context, and ignores an answer that carries no N1 message.
func TestSmfUpdateRejectN1Message(t *testing.T) {
	// A PDU Session Release Reject as the SMF builds it: EPD 0x2E, PDU session ID 4, PTI 1,
	// message type 0xD2, 5GSM cause 31 (request rejected, unspecified).
	reject := []byte{46, 4, 1, 210, 31}

	cases := []struct {
		name        string
		errResponse *models.UpdateSmContextResponse400
		want        []byte
	}{
		{name: "no answer", errResponse: nil, want: nil},
		{name: "answer without N1 message", errResponse: &models.UpdateSmContextResponse400{}, want: nil},
		{
			name:        "answer with empty N1 message",
			errResponse: &models.UpdateSmContextResponse400{BinaryDataN1SmMessage: []byte{}},
			want:        nil,
		},
		{
			name: "answer with release reject",
			errResponse: &models.UpdateSmContextResponse400{
				JsonData:              &models.SmContextUpdateError{},
				BinaryDataN1SmMessage: reject,
			},
			want: reject,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := smfUpdateRejectN1Message(tc.errResponse)
			if tc.want == nil {
				if got != nil {
					t.Fatalf("got %v, want nil", got)
				}
				return
			}
			if !bytes.Equal(got, tc.want) {
				t.Fatalf("got %v, want %v", got, tc.want)
			}
		})
	}
}
```

- [ ] **Step 2: Run the test to see it fail**

Run: `cd NFs/amf && go test ./internal/gmm/ -run SmfUpdateRejectN1Message`
Expected: FAIL with `undefined: smfUpdateRejectN1Message`.

- [ ] **Step 3: Add the helper and forward the reject first**

In `NFs/amf/internal/gmm/handler.go`, add this function directly above `func forward5GSMMessageToSMF(`:

```go
// #WNC SMF-REJECT/FORWARD
// smfUpdateRejectN1Message returns the N1 SM message, such as a PDU Session Release Reject, that the SMF
// put in its error answer to Update SM Context. It returns nil when the answer is missing or carries no
// N1 message, because an empty DL NAS Transport would give the UE nothing to act on.
func smfUpdateRejectN1Message(errResponse *models.UpdateSmContextResponse400) []byte {
	if errResponse == nil || len(errResponse.BinaryDataN1SmMessage) == 0 {
		return nil
	}
	return errResponse.BinaryDataN1SmMessage
}
```

In `forward5GSMMessageToSMF`, replace:

```go
	if err != nil {
		// TODO: error handling
		ue.GmmLog.Errorf("Update SMContext error [pduSessionID: %d], Error[%v]", pduSessionID, err)
		return nil
	} else if problemDetail != nil {
```

with:

```go
	// #WNC SMF-REJECT/FORWARD
	// When the SMF rejects a 5GSM message, such as a PDU Session Release Request, it answers with an HTTP
	// error status and a body that holds the reject for the UE. SendUpdateSmContextRequest then returns
	// err, problemDetail and errResponse all set, so the err check used to return before the reject was
	// sent. The reject check now comes first, as commit a3caee8 did for Create SM Context.
	if n1Reject := smfUpdateRejectN1Message(errResponse); n1Reject != nil {
		ue.GmmLog.Warnf("#WNC SMF-REJECT/FORWARD 5GSM message is rejected by SMF[pduSessionId:%d], "+
			"forwarding the SMF's N1 message to the UE", pduSessionID)
		gmm_message.SendDLNASTransport(ue.RanUe[accessType], nasMessage.PayloadContainerTypeN1SMInfo,
			n1Reject, pduSessionID, 0, nil, 0)
	} else if err != nil {
		// TODO: error handling
		ue.GmmLog.Errorf("Update SMContext error [pduSessionID: %d], Error[%v]", pduSessionID, err)
		return nil
	} else if problemDetail != nil {
```

The `else if errResponse != nil` branch further down stays as it is. After this change it runs only for
an error answer without an N1 message.

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd NFs/amf && go vet ./internal/gmm/ && go test ./internal/gmm/ -v -run 'SmfUpdateRejectN1Message|SmfRejectN1Message|RejectGSMCause'`
Expected: no vet output; all cases PASS.

- [ ] **Step 5: Commit (only after the tester approves)**

```bash
cd NFs/amf
git add internal/gmm/handler.go internal/gmm/handler_reject_test.go
git -c user.email=lori041987@users.noreply.github.com commit -m "fix(amf): forward the SMF's 5GSM reject from Update SM Context to the UE

When the SMF rejects a 5GSM message such as a PDU Session Release Request, it
answers Update SM Context with an HTTP error status and the reject in the body.
SendUpdateSmContextRequest returns err for every error status, and
forward5GSMMessageToSMF checked err first and returned, so the UE got no answer
and resent its request every 16 seconds.

forward5GSMMessageToSMF now forwards the reject in a DL NAS Transport before it
looks at err, as commit a3caee8 did for Create SM Context.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
cd ../..
```

---

### Task 5: Build, live check on the cn host, ISSUE doc, and the submodule bump

**Files:**
- Modify: `wnc_docs/2026-10-30_wnc_ISSUE_new_pdu_session_no_ipv6_prefix_and_release_request_unanswered_DUE_TO_smf_deletes_reused_up_seid_after_lost_release_complete.md` (header, §6, §7, §13)
- Modify: the `NFs/smf` and `NFs/amf` submodule pointers in the parent free5gc repo

**Interfaces:**
- Consumes: the commits of Tasks 1-4.
- Produces: running SMF and AMF binaries, and one parent-repo commit.

The commands in this task run from the parent free5gc directory,
`/home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc`, unless a step says otherwise.

A lost Release Complete cannot be produced on demand yet (ISSUE doc §13). The live check therefore
proves that the normal paths did not change. The new code paths are proven by the unit tests of Tasks
1-4, and by the next field run that loses a Release Complete.

- [ ] **Step 1: Build both binaries**

Run: `make smf amf`
Expected: both builds finish without errors, and `ls -l bin/smf bin/amf` shows new modification times.

- [ ] **Step 2: Restart the core**

Stop the running core, then start it with `./run.sh`. `run.sh` writes the log to
`./log/<date>_<time>/free5gc.log`. In the steps below, `LOG` means that file:

```bash
LOG=$(ls -td log/*/ | head -1)free5gc.log
```

- [ ] **Step 3: Live check — PDU sessions come up**

Attach the UE and let it set up its PDU sessions.

Run: `grep -c 'Router Solicitation event received for SEID' $LOG`
Expected: one line or more for each IPv6 PDU session, and every UE interface gets its IPv6 prefix.

- [ ] **Step 4: Live check — a normal UE-requested release is unchanged**

Release one PDU session from the UE, the same way as in the earlier release tests.

Run: `grep -nE 'Received PFCP Session Deletion Accepted Response|#WNC LOST-RELEASE-COMPLETE|unexpected SEID response message' $LOG`
Expected: one `Received PFCP Session Deletion Accepted Response` line for the released session, no
`#WNC LOST-RELEASE-COMPLETE` line, and no `unexpected SEID response message` line. In QXDM, the UE
receives the PDU Session Release Command and sends the Release Complete.

- [ ] **Step 5: Live check — the other PDU sessions keep working**

Run traffic on the PDU sessions that were not released.
Expected: they keep passing traffic, and the UPF log shows exactly one `sess deleted` line, with the CP
SEID of the released session: `grep -n 'sess deleted' $LOG`.

- [ ] **Step 6: Update the ISSUE doc**

In `wnc_docs/2026-10-30_wnc_ISSUE_new_pdu_session_no_ipv6_prefix_and_release_request_unanswered_DUE_TO_smf_deletes_reused_up_seid_after_lost_release_complete.md`:

- Header row `Fix`: name the `NFs/smf` and `NFs/amf` commits of Tasks 1-4.
- Header row `Status`: `**Fixed, partly verified.**` — the unit tests and the normal-release live check passed; the lost-Release-Complete path has not run live.
- §6: replace `**No fix has been applied.**` with the commit hashes, and add one line per task naming the function that changed.
- §7: replace `**Not verified. No fix exists to verify.**` with the commands and results of Task 1 Step 9, Task 2 Step 6, Task 3 Step 6, Task 4 Step 4, and Steps 3-5 of this task. Keep the table of checks for the next run that loses a Release Complete.
- §13: change the first item to say that the fix is implemented, and keep the item on producing a lost Release Complete on demand.

Then run the three checks from `~/.claude/CLAUDE.md` on the changed sections: no `we` or `us`, no
ordinal as a subject, no sentence with two pronouns that point at different things.

- [ ] **Step 7: Commit the submodule bump and the docs (only after the tester confirms Steps 3-5)**

Run `git status` first. The deleted `cert/nrf.pem` and the untracked `my_logs/` must stay out of this
commit. Ask the tester whether the other modified files in `wnc_docs/`, which come from earlier work,
go into this commit too.

```bash
git add NFs/smf NFs/amf \
  wnc_docs/2026-10-30_wnc_ISSUE_new_pdu_session_no_ipv6_prefix_and_release_request_unanswered_DUE_TO_smf_deletes_reused_up_seid_after_lost_release_complete.md \
  wnc_docs/2026-11-02_wnc_PLAN_recover_from_lost_release_complete_FOR_smf_stale_up_seid_release_and_t3592.md \
  wnc_docs/2026-10-22_wnc_FINDING_ue_pdu_session_retry_NAMELY_3gpp_allows_ue_stops_retrying_when_no_backoff_5x3s_VS_backoff_t3396_60s_3x_VS_no_answer_t3580_16s.md \
  wnc_docs/2026-10-28_wnc_ISSUE_pdu_session_still_rejected_after_delete_pdu_drop_through_API_DUE_TO_upf_crash_on_orphan_session_from_graceful_drop.md
git -c user.email=lori041987@users.noreply.github.com commit -m "fix(smf,amf): recover from a lost PDU Session Release Complete; bump smf/amf

Add the ISSUE doc and the PLAN for this fix, and back-links from two earlier
docs.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```
