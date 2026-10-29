# PDU Session Drop, Step 1 (Graceful Release) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an SMF OAM API that releases a chosen PDU session with a PDU Session Release Command, rejects the UE's retries until restore, and lets the session return on `DELETE`.

**Architecture:** An in-memory drop list in `NFs/smf/internal/context/pdu_drop.go` holds drop entries. `NFs/smf/internal/sbi/processor/pdu_drop.go` validates requests and runs one handler per mode behind the `pduDropMode` interface; step 1 ships only the `graceful` handler. `HandlePDUSessionSMContextCreate()` asks the drop list whether to reject a new session. Three routes under `/nsmf-oam/v1/pdu-drop` are registered only when `pduDrop.enable` is true.

**Tech Stack:** Go, gin, `github.com/free5gc/nas` v1.1.5, `github.com/free5gc/openapi`, `gopkg.in/yaml.v2`, testify.

**Spec:** `wnc_docs/2026-10-21_wnc_SPEC_manual_pdu_session_drop_on_smf_VIA_oam_api_FOR_graceful_release_blackhole_and_silent_delete.md`

## Global Constraints

- Every new comment line and log message carries `#WNC PDU-DROP/<SUB-TOPIC>`. Sub-topics used in step 1: `CONFIG`, `API`, `REGISTRY`, `REJECT`, `RESTORE`, `BACKOFF`, `GRACEFUL-RELEASE`.
- A Go comment with the tag sits on its own line above the code, never at the end of a code line. Example: `// #WNC PDU-DROP/REJECT`.
- A log message puts the tag at the start of the string. Example: `"#WNC PDU-DROP/REJECT rejecting supi=%s dnn=%s"`.
- Defaults: `releaseCause` 36 (`nasMessage.Cause5GSMRegularDeactivation`), `rejectCause` 26 (`nasMessage.Cause5GSMInsufficientResources`), `backoffSeconds` 0.
- The SMF's behavior on UPF loss must not change: `releaseAllResourcesOfUPF()` keeps sending cause 38 (`nasMessage.Cause5GSMNetworkFailure`) with no back-off.
- Nothing is committed during Tasks 1-6. All commits happen once, in Task 7, after the user has verified the PDU drop behavior on the UE.
- `NFs/smf` is its own git repository on branch `my-smf-changes-v1.3.2`. Its commit uses `git -c user.email=lori041987@users.noreply.github.com commit ...`. The parent free5gc repo then commits the config file and the submodule bump with no identity override.
- Every change to existing free5gc code (a new call argument, a changed signature, a function turned into a wrapper) gets a `#WNC` comment above it saying why it changed.
- `pkg/factory/config.go` and `internal/context/gsm_build.go` are already not `gofmt`-clean before this work. Do not run `gofmt -w` on those two files. Write new code in `gofmt` style by hand. Every other touched or new file must pass `gofmt -l` with no output.
- Before this work, `go test ./internal/context/` already fails in `TestPDUAddressToNAS`. That failure is not caused by this plan. Run new context tests with `-run` so the result shows only the new tests.
- All commands below run from `NFs/smf` unless a step says otherwise.

## File Map

| File | New or changed | Job |
|---|---|---|
| `pkg/factory/config.go` | changed | `PduDropConfig` struct, `PduDrop` field, two getters |
| `pkg/factory/pdu_drop_config_test.go` | new | Tests for the getters and YAML parsing |
| `internal/context/gsm_build.go` | changed | `GPRSTimer3` encoder; Reject and Release Command builders that can add the Back-off timer value IE |
| `internal/context/gsm_build_backoff_test.go` | new | Encoder and NAS decode tests |
| `internal/context/pdu_drop.go` | new | `DropMode`, `DropSelector`, `DropEntry`, `DropRegistry`, `SMContextsMatching()` |
| `internal/context/pdu_drop_test.go` | new | Drop list tests |
| `internal/sbi/processor/association.go` | changed | `requestAMFToReleasePDUResources()` takes cause and back-off |
| `internal/sbi/processor/pdu_drop.go` | new | Request types, validation, `pduDropMode`, `gracefulDropMode`, three handlers, reject lookup |
| `internal/sbi/processor/pdu_drop_test.go` | new | Validation and handler tests |
| `internal/sbi/processor/pdu_session.go` | changed | Reject check in `HandlePDUSessionSMContextCreate()`; reject helper with back-off |
| `internal/sbi/processor/pdu_session_test.go` | changed | One table case: a drop entry makes the create request fail with cause 26 |
| `internal/sbi/api_pdudrop.go` | new | Routes, HTTP handlers, `registerPduDropRoutes()` |
| `internal/sbi/api_pdudrop_test.go` | new | Route registration tests for the three config states |
| `internal/sbi/server.go` | changed | Calls `registerPduDropRoutes()` from `newRouter()` |
| `../../config/smfcfg_unbound_dns64.yaml` | changed | `pduDrop` block |

---

### Task 1: Config switch `pduDrop`

**Files:**
- Modify: `pkg/factory/config.go` (the `Configuration` struct near line 79, and the end of the file)
- Test: `pkg/factory/pdu_drop_config_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces: `factory.PduDropConfig{Enable bool; SkipOAuth bool}`, field `Configuration.PduDrop *PduDropConfig`, `func (c *Config) GetPduDropEnable() bool`, `func (c *Config) GetPduDropSkipOAuth() bool`.

- [ ] **Step 1: Write the failing test**

Create `pkg/factory/pdu_drop_config_test.go`:

```go
package factory

import (
	"testing"

	"github.com/stretchr/testify/require"
	"gopkg.in/yaml.v2"
)

// #WNC PDU-DROP/CONFIG
// A missing pduDrop block must leave the drop API off.
func TestPduDropConfigDefaultsOff(t *testing.T) {
	c := &Config{Configuration: &Configuration{}}
	require.False(t, c.GetPduDropEnable())
	require.False(t, c.GetPduDropSkipOAuth())

	empty := &Config{}
	require.False(t, empty.GetPduDropEnable())
	require.False(t, empty.GetPduDropSkipOAuth())
}

// #WNC PDU-DROP/CONFIG
func TestPduDropConfigFromYAML(t *testing.T) {
	var cfg Configuration
	err := yaml.Unmarshal([]byte("pduDrop:\n  enable: true\n  skipOAuth: true\n"), &cfg)
	require.NoError(t, err)

	c := &Config{Configuration: &cfg}
	require.True(t, c.GetPduDropEnable())
	require.True(t, c.GetPduDropSkipOAuth())
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `go test ./pkg/factory/ -run PduDrop -v`
Expected: build failure, `c.GetPduDropEnable undefined`.

- [ ] **Step 3: Add the field to `Configuration`**

In `pkg/factory/config.go`, add these lines inside `type Configuration struct`, directly after the `RouterAdvertisement` field:

```go
	// #WNC PDU-DROP/CONFIG
	// PduDrop turns on the OAM API that drops and restores PDU sessions for UE recovery tests.
	PduDrop *PduDropConfig `yaml:"pduDrop,omitempty" valid:"optional"`
```

- [ ] **Step 4: Add the type and getters at the end of `pkg/factory/config.go`**

```go
// #WNC PDU-DROP/CONFIG
// PduDropConfig controls the OAM API that drops and restores PDU sessions.
// SkipOAuth true registers the drop routes without the NRF token check.
type PduDropConfig struct {
	Enable    bool `yaml:"enable" valid:"type(bool),optional"`
	SkipOAuth bool `yaml:"skipOAuth" valid:"type(bool),optional"`
}

// #WNC PDU-DROP/CONFIG
// GetPduDropEnable returns false when the pduDrop block is missing.
func (c *Config) GetPduDropEnable() bool {
	c.RLock()
	defer c.RUnlock()
	if c.Configuration == nil || c.Configuration.PduDrop == nil {
		return false
	}
	return c.Configuration.PduDrop.Enable
}

// #WNC PDU-DROP/CONFIG
// GetPduDropSkipOAuth returns false when the pduDrop block is missing.
func (c *Config) GetPduDropSkipOAuth() bool {
	c.RLock()
	defer c.RUnlock()
	if c.Configuration == nil || c.Configuration.PduDrop == nil {
		return false
	}
	return c.Configuration.PduDrop.SkipOAuth
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `go test ./pkg/factory/ -v`
Expected: `ok  github.com/free5gc/smf/pkg/factory`. The existing `config_test.go` tests also pass.

- [ ] **Step 6: Check formatting of the new test file**

Run: `gofmt -l pkg/factory/pdu_drop_config_test.go`
Expected: no output.

---

### Task 2: Back-off timer value IE in the Reject and the Release Command

**Files:**
- Modify: `internal/context/gsm_build.go` (`BuildGSMPDUSessionEstablishmentReject()` near line 197, `BuildGSMPDUSessionReleaseCommand()` near line 219)
- Test: `internal/context/gsm_build_backoff_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `type GPRSTimer3 struct { Unit uint8; Value uint8 }`
  - `func EncodeGPRSTimer3(seconds uint32) *GPRSTimer3` (returns nil for 0)
  - `func (t *GPRSTimer3) Seconds() uint32` (returns 0 for nil)
  - `func BuildGSMPDUSessionEstablishmentRejectWithBackoff(smContext *SMContext, cause uint8, backoff *GPRSTimer3) ([]byte, error)`
  - `func BuildGSMPDUSessionReleaseCommandWithBackoff(smContext *SMContext, cause uint8, isTriggeredByUE bool, backoff *GPRSTimer3) ([]byte, error)`
  - The old `BuildGSMPDUSessionEstablishmentReject()` and `BuildGSMPDUSessionReleaseCommand()` keep their signatures and call the new functions with `nil`.

GPRS timer 3 (3GPP TS 24.008 clause 10.5.7.4a) is one octet. Bits 8-6 hold the unit and bits 5-1 hold a value from 0 to 31. The units are: 3 = 2 s, 4 = 30 s, 5 = 1 min, 0 = 10 min, 1 = 1 h, 2 = 10 h, 6 = 320 h.

- [ ] **Step 1: Write the failing test**

Create `internal/context/gsm_build_backoff_test.go`:

```go
package context

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/free5gc/nas"
	"github.com/free5gc/nas/nasMessage"
)

// #WNC PDU-DROP/BACKOFF
func TestEncodeGPRSTimer3RoundsUp(t *testing.T) {
	cases := []struct{ in, want uint32 }{
		{0, 0}, {2, 2}, {3, 4}, {62, 62}, {63, 90}, {1800, 1800}, {3600, 3600},
	}
	for _, tc := range cases {
		require.Equal(t, tc.want, EncodeGPRSTimer3(tc.in).Seconds(), "input %d", tc.in)
	}
	require.Nil(t, EncodeGPRSTimer3(0))
	require.Equal(t, &GPRSTimer3{Unit: 3, Value: 2}, EncodeGPRSTimer3(3))
	require.Equal(t, &GPRSTimer3{Unit: 4, Value: 3}, EncodeGPRSTimer3(63))
}

// #WNC PDU-DROP/BACKOFF
func TestRejectCarriesBackoff(t *testing.T) {
	sc := &SMContext{PDUSessionID: 5, Pti: 7}
	buf, err := BuildGSMPDUSessionEstablishmentRejectWithBackoff(
		sc, nasMessage.Cause5GSMInsufficientResources, EncodeGPRSTimer3(60))
	require.NoError(t, err)

	m := nas.NewMessage()
	require.NoError(t, m.PlainNasDecode(&buf))
	rej := m.GsmMessage.PDUSessionEstablishmentReject
	require.Equal(t, nasMessage.Cause5GSMInsufficientResources, rej.GetCauseValue())
	require.NotNil(t, rej.BackoffTimerValue)
	require.Equal(t, nasMessage.PDUSessionEstablishmentRejectBackoffTimerValueType, rej.BackoffTimerValue.GetIei())
	require.Equal(t, uint8(3), rej.BackoffTimerValue.GetUnitTimerValue())
	require.Equal(t, uint8(30), rej.BackoffTimerValue.GetTimerValue())
}

// #WNC PDU-DROP/BACKOFF
func TestRejectWithoutBackoffHasNoIE(t *testing.T) {
	sc := &SMContext{PDUSessionID: 5, Pti: 7}
	buf, err := BuildGSMPDUSessionEstablishmentReject(sc, nasMessage.Cause5GSMInsufficientResources)
	require.NoError(t, err)

	m := nas.NewMessage()
	require.NoError(t, m.PlainNasDecode(&buf))
	require.Nil(t, m.GsmMessage.PDUSessionEstablishmentReject.BackoffTimerValue)
}

// #WNC PDU-DROP/BACKOFF
func TestReleaseCommandCarriesCauseAndBackoff(t *testing.T) {
	sc := &SMContext{PDUSessionID: 5, Pti: 7}
	buf, err := BuildGSMPDUSessionReleaseCommandWithBackoff(
		sc, nasMessage.Cause5GSMRegularDeactivation, false, EncodeGPRSTimer3(120))
	require.NoError(t, err)

	m := nas.NewMessage()
	require.NoError(t, m.PlainNasDecode(&buf))
	rel := m.GsmMessage.PDUSessionReleaseCommand
	require.Equal(t, nasMessage.Cause5GSMRegularDeactivation, rel.GetCauseValue())
	require.Equal(t, uint8(0), rel.GetPTI())
	require.NotNil(t, rel.BackoffTimerValue)
	// 120 s does not fit the 2 s unit (60 > 31), so the encoder picks the 30 s unit with value 4.
	require.Equal(t, uint8(4), rel.BackoffTimerValue.GetUnitTimerValue())
	require.Equal(t, uint8(4), rel.BackoffTimerValue.GetTimerValue())
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `go test ./internal/context/ -run 'GPRSTimer3|Backoff' -v`
Expected: build failure, `undefined: EncodeGPRSTimer3`.

- [ ] **Step 3: Add the encoder to `internal/context/gsm_build.go`**

Add after the import block. `nasType` is already imported in this file.

```go
// #WNC PDU-DROP/BACKOFF
// GPRSTimer3 is the GPRS timer 3 format defined in 3GPP TS 24.008 clause 10.5.7.4a.
// A plain timer would carry a whole number of seconds. GPRS timer 3 instead packs the
// duration into one octet with two fields:
//
//	bit:    8   7   6 | 5   4   3   2   1
//	field:  Unit      | Value
//
// Unit (3 bits) selects the length of one timer step, and Value (5 bits, 0-31) is the
// number of steps. The UE computes the duration as:
//
//	Duration (seconds) = Value x Step
//
// NAS uses this format for several timers, and T3396 is one of them. The SMF sends T3396 as the
// Back-off timer value IE (IEI 0x37) in a PDU Session Establishment Reject or a PDU Session
// Release Command. While T3396 runs, the UE does not request a PDU session for the same DNN
// and S-NSSAI again.
type GPRSTimer3 struct {
	Unit  uint8
	Value uint8
}

// #WNC PDU-DROP/BACKOFF
// gprsTimer3Units maps each Unit code to its step length. The step is in seconds.
// The entries are sorted from the shortest step to the longest, so EncodeGPRSTimer3 tries
// the finest step first. The Unit codes are therefore not in numeric order: code 3 (2 s)
// is the shortest step, and code 0 (10 min) sits in the middle.
// Unit code 7 means "timer deactivated" and has no step, so the table leaves it out.
var gprsTimer3Units = []struct {
	unit uint8
	step uint32
}{
	// 2 seconds
	{unit: 3, step: 2},
	// 30 seconds
	{unit: 4, step: 30},
	// 1 minute
	{unit: 5, step: 60},
	// 10 minutes
	{unit: 0, step: 600},
	// 1 hour
	{unit: 1, step: 3600},
	// 10 hours
	{unit: 2, step: 36000},
	// 320 hours
	{unit: 6, step: 1152000},
}

// #WNC PDU-DROP/BACKOFF
// EncodeGPRSTimer3 picks the shortest step whose Value fits in 5 bits (at most 31), and
// rounds the duration up to a whole number of steps. Example: 63 seconds needs 32 steps
// of 2 seconds, which does not fit, so it becomes 3 steps of 30 seconds, which is 90 seconds.
// Durations beyond 31 x 320 hours are capped at that value.
// For 0 seconds it returns nil, and the caller then leaves the IE out of the message.
func EncodeGPRSTimer3(seconds uint32) *GPRSTimer3 {
	if seconds == 0 {
		return nil
	}
	for _, u := range gprsTimer3Units {
		value := (seconds + u.step - 1) / u.step
		if value <= 31 {
			return &GPRSTimer3{Unit: u.unit, Value: uint8(value)}
		}
	}
	last := gprsTimer3Units[len(gprsTimer3Units)-1]
	return &GPRSTimer3{Unit: last.unit, Value: 31}
}

// #WNC PDU-DROP/BACKOFF
// Seconds returns Value x Step, which is the duration that the UE applies.
// A nil timer returns 0.
func (t *GPRSTimer3) Seconds() uint32 {
	if t == nil {
		return 0
	}
	for _, u := range gprsTimer3Units {
		if u.unit == t.Unit {
			return u.step * uint32(t.Value)
		}
	}
	return 0
}

// #WNC PDU-DROP/BACKOFF
// toNasBackoff builds the Back-off timer value IE with the given IEI.
// The IE is the IEI octet, a length octet holding 1, and the GPRS timer 3 octet.
func (t *GPRSTimer3) toNasBackoff(iei uint8) *nasType.BackoffTimerValue {
	b := nasType.NewBackoffTimerValue(iei)
	b.SetLen(1)
	b.SetUnitTimerValue(t.Unit)
	b.SetTimerValue(t.Value)
	return b
}
```

- [ ] **Step 4: Replace `BuildGSMPDUSessionEstablishmentReject()`**

Replace the whole existing function with:

```go
// #WNC PDU-DROP/BACKOFF
// The body moved to BuildGSMPDUSessionEstablishmentRejectWithBackoff so the PDU drop reject can add
// a Back-off timer value IE. This wrapper passes no back-off, so existing callers get the same bytes as before.
func BuildGSMPDUSessionEstablishmentReject(smContext *SMContext, cause uint8) ([]byte, error) {
	return BuildGSMPDUSessionEstablishmentRejectWithBackoff(smContext, cause, nil)
}

// #WNC PDU-DROP/BACKOFF
// BuildGSMPDUSessionEstablishmentRejectWithBackoff adds the Back-off timer value IE when backoff is not nil.
func BuildGSMPDUSessionEstablishmentRejectWithBackoff(
	smContext *SMContext, cause uint8, backoff *GPRSTimer3,
) ([]byte, error) {
	m := nas.NewMessage()
	m.GsmMessage = nas.NewGsmMessage()
	m.GsmHeader.SetMessageType(nas.MsgTypePDUSessionEstablishmentReject)
	m.GsmHeader.SetExtendedProtocolDiscriminator(nasMessage.Epd5GSSessionManagementMessage)
	m.PDUSessionEstablishmentReject = nasMessage.NewPDUSessionEstablishmentReject(0x0)
	pDUSessionEstablishmentReject := m.PDUSessionEstablishmentReject

	pDUSessionEstablishmentReject.SetMessageType(nas.MsgTypePDUSessionEstablishmentReject)
	pDUSessionEstablishmentReject.SetPTI(smContext.Pti)
	pDUSessionEstablishmentReject.SetExtendedProtocolDiscriminator(nasMessage.Epd5GSSessionManagementMessage)
	pDUSessionEstablishmentReject.SetPDUSessionID(uint8(smContext.PDUSessionID))
	pDUSessionEstablishmentReject.SetCauseValue(cause)
	if backoff != nil {
		pDUSessionEstablishmentReject.BackoffTimerValue =
			backoff.toNasBackoff(nasMessage.PDUSessionEstablishmentRejectBackoffTimerValueType)
	}

	return m.PlainNasEncode()
}
```

- [ ] **Step 5: Replace `BuildGSMPDUSessionReleaseCommand()`**

Keep the existing doc comment above the old function. Directly below that doc comment, add a `//` separator line and the `#WNC` comment, and replace the function itself, so the result reads:

```go
// ...existing doc comment lines stay here...
//
// #WNC PDU-DROP/BACKOFF
// The body moved to BuildGSMPDUSessionReleaseCommandWithBackoff so the graceful drop mode can add
// a Back-off timer value IE. This wrapper passes no back-off, so existing callers get the same bytes as before.
func BuildGSMPDUSessionReleaseCommand(smContext *SMContext, cause uint8, isTriggeredByUE bool) ([]byte, error) {
	return BuildGSMPDUSessionReleaseCommandWithBackoff(smContext, cause, isTriggeredByUE, nil)
}

// #WNC PDU-DROP/BACKOFF
// BuildGSMPDUSessionReleaseCommandWithBackoff adds the Back-off timer value IE when backoff is not nil.
func BuildGSMPDUSessionReleaseCommandWithBackoff(
	smContext *SMContext, cause uint8, isTriggeredByUE bool, backoff *GPRSTimer3,
) ([]byte, error) {
	m := nas.NewMessage()
	m.GsmMessage = nas.NewGsmMessage()
	m.GsmHeader.SetMessageType(nas.MsgTypePDUSessionReleaseCommand)
	m.GsmHeader.SetExtendedProtocolDiscriminator(nasMessage.Epd5GSSessionManagementMessage)
	m.PDUSessionReleaseCommand = nasMessage.NewPDUSessionReleaseCommand(0x0)
	pDUSessionReleaseCommand := m.PDUSessionReleaseCommand

	pDUSessionReleaseCommand.SetMessageType(nas.MsgTypePDUSessionReleaseCommand)
	pDUSessionReleaseCommand.SetExtendedProtocolDiscriminator(nasMessage.Epd5GSSessionManagementMessage)
	pDUSessionReleaseCommand.SetPDUSessionID(uint8(smContext.PDUSessionID))

	if isTriggeredByUE {
		pDUSessionReleaseCommand.SetPTI(smContext.Pti)
	} else {
		pDUSessionReleaseCommand.SetPTI(0x00)
	}
	pDUSessionReleaseCommand.SetCauseValue(cause)
	if backoff != nil {
		pDUSessionReleaseCommand.BackoffTimerValue =
			backoff.toNasBackoff(nasMessage.PDUSessionReleaseCommandBackoffTimerValueType)
	}

	return m.PlainNasEncode()
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `go test ./internal/context/ -run 'GPRSTimer3|Backoff' -v`
Expected: 4 tests `PASS`.

- [ ] **Step 7: Check that the rest of the SMF still builds and the processor tests still pass**

Run: `go build ./... && go test ./internal/sbi/processor/`
Expected: no build output, then `ok  github.com/free5gc/smf/internal/sbi/processor`.

- [ ] **Step 8: Check formatting**

Run: `gofmt -l internal/context/gsm_build_backoff_test.go`
Expected: no output.

Run: `gofmt -d internal/context/gsm_build.go | grep -n 'PDU-DROP\|GPRSTimer3\|WithBackoff'`
Expected: no output. Any `gofmt` difference in that file must come from lines that were there before this task.

---

### Task 3: Drop list in the SMF context

**Files:**
- Create: `internal/context/pdu_drop.go`
- Test: `internal/context/pdu_drop_test.go`

**Interfaces:**
- Consumes: `GPRSTimer3` from Task 2.
- Produces:
  - `type DropMode string` with constants `DropModeGraceful = "graceful"`, `DropModeBlackhole = "blackhole"`, `DropModeSilent = "silent"`
  - `type DropSelector struct { Dnn string; Snssai models.Snssai; Supi string }` and `func (s DropSelector) Matches(supi, dnn string, snssai *models.Snssai) bool`
  - `type DropEntry struct { DropId string; Mode DropMode; Selector DropSelector; ReleaseCause uint8; RejectCause uint8; Backoff *GPRSTimer3; EncodedBackoffSeconds uint32; CreatedAt time.Time }`
  - `func NewDropRegistry() *DropRegistry`, `func GetDropRegistry() *DropRegistry`
  - `func (r *DropRegistry) Add(entry *DropEntry) (conflictId string, added bool)`
  - `func (r *DropRegistry) Match(supi, dnn string, snssai *models.Snssai, filter func(*DropEntry) bool) *DropEntry`
  - `func (r *DropRegistry) Get(dropId string) *DropEntry`
  - `func (r *DropRegistry) Remove(dropId string) bool`
  - `func (r *DropRegistry) List() []*DropEntry`
  - `func SMContextsMatching(sel DropSelector) []*SMContext`

- [ ] **Step 1: Write the failing test**

Create `internal/context/pdu_drop_test.go`:

```go
package context

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/free5gc/openapi/models"
)

// #WNC PDU-DROP/REGISTRY
func TestDropSelectorMatches(t *testing.T) {
	sel := DropSelector{Dnn: "internet", Snssai: models.Snssai{Sst: 1, Sd: "000001"}}
	withSupi := sel
	withSupi.Supi = "imsi-001"
	noSd := DropSelector{Dnn: "internet", Snssai: models.Snssai{Sst: 1}}
	upperSd := DropSelector{Dnn: "internet", Snssai: models.Snssai{Sst: 1, Sd: "0007D0"}}

	cases := []struct {
		name  string
		sel   DropSelector
		supi  string
		dnn   string
		nssai *models.Snssai
		want  bool
	}{
		{"same slice, any UE", sel, "imsi-002", "internet", &models.Snssai{Sst: 1, Sd: "000001"}, true},
		{"SD compare ignores case", upperSd, "imsi-002", "internet", &models.Snssai{Sst: 1, Sd: "0007d0"}, true},
		{"other SD", sel, "imsi-002", "internet", &models.Snssai{Sst: 1, Sd: "000002"}, false},
		{"other DNN", sel, "imsi-002", "ims", &models.Snssai{Sst: 1, Sd: "000001"}, false},
		{"other SST", sel, "imsi-002", "internet", &models.Snssai{Sst: 2, Sd: "000001"}, false},
		{"nil S-NSSAI", sel, "imsi-002", "internet", nil, false},
		{"SUPI given and equal", withSupi, "imsi-001", "internet", &models.Snssai{Sst: 1, Sd: "000001"}, true},
		{"SUPI given and different", withSupi, "imsi-002", "internet", &models.Snssai{Sst: 1, Sd: "000001"}, false},
		{"no SD matches no SD", noSd, "imsi-002", "internet", &models.Snssai{Sst: 1}, true},
		{"no SD does not match an SD", noSd, "imsi-002", "internet", &models.Snssai{Sst: 1, Sd: "000001"}, false},
	}
	for _, tc := range cases {
		require.Equal(t, tc.want, tc.sel.Matches(tc.supi, tc.dnn, tc.nssai), tc.name)
	}
}

// #WNC PDU-DROP/REGISTRY
func TestDropRegistryAddConflictMatchRemove(t *testing.T) {
	r := NewDropRegistry()
	sel := DropSelector{Dnn: "internet", Snssai: models.Snssai{Sst: 1, Sd: "000001"}}

	older := &DropEntry{Mode: DropModeGraceful, Selector: sel, RejectCause: 26}
	conflictId, added := r.Add(older)
	require.True(t, added)
	require.Empty(t, conflictId)
	require.Equal(t, "1", older.DropId)
	require.False(t, older.CreatedAt.IsZero())

	duplicate := &DropEntry{Mode: DropModeGraceful, Selector: sel}
	conflictId, added = r.Add(duplicate)
	require.False(t, added)
	require.Equal(t, "1", conflictId)

	narrower := &DropEntry{Mode: DropModeGraceful, Selector: DropSelector{
		Dnn: "internet", Snssai: models.Snssai{Sst: 1, Sd: "000001"}, Supi: "imsi-001",
	}, RejectCause: 27}
	_, added = r.Add(narrower)
	require.True(t, added)
	require.Equal(t, "2", narrower.DropId)

	nssai := &models.Snssai{Sst: 1, Sd: "000001"}
	require.Same(t, older, r.Match("imsi-001", "internet", nssai, nil), "the oldest matching entry wins")
	require.Same(t, narrower, r.Match("imsi-001", "internet", nssai,
		func(e *DropEntry) bool { return e.RejectCause == 27 }), "the filter skips the older entry")
	require.Nil(t, r.Match("imsi-001", "ims", nssai, nil))

	require.Len(t, r.List(), 2)
	require.Same(t, narrower, r.Get("2"))
	require.Nil(t, r.Get("9"))

	require.True(t, r.Remove("1"))
	require.False(t, r.Remove("1"))
	require.Same(t, narrower, r.Match("imsi-001", "internet", nssai, nil))
	require.NotNil(t, r.List())
}

// #WNC PDU-DROP/REGISTRY
func TestSMContextsMatching(t *testing.T) {
	hit := &SMContext{Ref: "pdu-drop-test-hit", SmfPduSessionSmContextCreateData: &models.SmfPduSessionSmContextCreateData{
		Supi: "imsi-001", Dnn: "pdu-drop-test", SNssai: &models.Snssai{Sst: 1, Sd: "000001"},
	}}
	miss := &SMContext{Ref: "pdu-drop-test-miss", SmfPduSessionSmContextCreateData: &models.SmfPduSessionSmContextCreateData{
		Supi: "imsi-001", Dnn: "pdu-drop-test", SNssai: &models.Snssai{Sst: 1, Sd: "000002"},
	}}
	noData := &SMContext{Ref: "pdu-drop-test-nodata"}
	for _, sc := range []*SMContext{hit, miss, noData} {
		smContextPool.Store(sc.Ref, sc)
		defer smContextPool.Delete(sc.Ref)
	}

	got := SMContextsMatching(DropSelector{Dnn: "pdu-drop-test", Snssai: models.Snssai{Sst: 1, Sd: "000001"}})
	require.Equal(t, []*SMContext{hit}, got)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `go test ./internal/context/ -run 'DropSelector|DropRegistry|SMContextsMatching' -v`
Expected: build failure, `undefined: DropSelector`.

- [ ] **Step 3: Write `internal/context/pdu_drop.go`**

```go
package context

import (
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/free5gc/openapi/models"
)

// #WNC PDU-DROP/REGISTRY
// DropMode names how a drop entry takes a PDU session down.
type DropMode string

const (
	DropModeGraceful  DropMode = "graceful"
	DropModeBlackhole DropMode = "blackhole"
	DropModeSilent    DropMode = "silent"
)

// #WNC PDU-DROP/REGISTRY
// DropSelector picks the PDU sessions that a drop entry applies to.
// An empty Supi matches every UE. An empty Snssai.Sd matches only sessions that have no SD.
type DropSelector struct {
	Dnn    string        `json:"dnn"`
	Snssai models.Snssai `json:"snssai"`
	Supi   string        `json:"supi,omitempty"`
}

// #WNC PDU-DROP/REGISTRY
// Matches reports whether a PDU session with this SUPI, DNN and S-NSSAI falls under the selector.
func (s DropSelector) Matches(supi, dnn string, snssai *models.Snssai) bool {
	if snssai == nil || s.Dnn != dnn || s.Snssai.Sst != snssai.Sst {
		return false
	}
	if !strings.EqualFold(s.Snssai.Sd, snssai.Sd) {
		return false
	}
	return s.Supi == "" || s.Supi == supi
}

// #WNC PDU-DROP/REGISTRY
// sameSelector reports whether two selectors pick exactly the same sessions.
func sameSelector(a, b DropSelector) bool {
	return a.Dnn == b.Dnn && a.Supi == b.Supi && a.Snssai.Sst == b.Snssai.Sst &&
		strings.EqualFold(a.Snssai.Sd, b.Snssai.Sd)
}

// #WNC PDU-DROP/REGISTRY
// DropEntry is one record in the drop list, created by one POST /pdu-drop call.
// The fields do not change after Add stores the entry.
type DropEntry struct {
	DropId                string       `json:"dropId"`
	Mode                  DropMode     `json:"mode"`
	Selector              DropSelector `json:"selector"`
	ReleaseCause          uint8        `json:"releaseCause"`
	RejectCause           uint8        `json:"rejectCause"`
	Backoff               *GPRSTimer3  `json:"-"`
	EncodedBackoffSeconds uint32       `json:"encodedBackoffSeconds"`
	CreatedAt             time.Time    `json:"createdAt"`
}

// #WNC PDU-DROP/REGISTRY
// DropRegistry holds the drop entries in creation order, so the oldest matching entry is found first.
type DropRegistry struct {
	mu      sync.Mutex
	lastId  uint64
	entries []*DropEntry
}

var dropRegistry = NewDropRegistry()

func NewDropRegistry() *DropRegistry {
	return &DropRegistry{}
}

// #WNC PDU-DROP/REGISTRY
// GetDropRegistry returns the drop list shared by the whole SMF.
func GetDropRegistry() *DropRegistry {
	return dropRegistry
}

// #WNC PDU-DROP/REGISTRY
// Add stores the entry and fills in DropId and CreatedAt.
// When an entry with the same mode and selector already exists, Add stores nothing and returns that DropId.
func (r *DropRegistry) Add(entry *DropEntry) (conflictId string, added bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, e := range r.entries {
		if e.Mode == entry.Mode && sameSelector(e.Selector, entry.Selector) {
			return e.DropId, false
		}
	}
	r.lastId++
	entry.DropId = strconv.FormatUint(r.lastId, 10)
	entry.CreatedAt = time.Now()
	r.entries = append(r.entries, entry)
	return "", true
}

// #WNC PDU-DROP/REGISTRY
// Match returns the oldest entry that matches the session and passes the filter, or nil.
// A nil filter accepts every entry.
func (r *DropRegistry) Match(
	supi, dnn string, snssai *models.Snssai, filter func(*DropEntry) bool,
) *DropEntry {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, e := range r.entries {
		if e.Selector.Matches(supi, dnn, snssai) && (filter == nil || filter(e)) {
			return e
		}
	}
	return nil
}

// #WNC PDU-DROP/REGISTRY
// Get returns the entry with this DropId, or nil.
func (r *DropRegistry) Get(dropId string) *DropEntry {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, e := range r.entries {
		if e.DropId == dropId {
			return e
		}
	}
	return nil
}

// #WNC PDU-DROP/REGISTRY
// Remove deletes the entry with this DropId and reports whether one was found.
func (r *DropRegistry) Remove(dropId string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	for i, e := range r.entries {
		if e.DropId == dropId {
			r.entries = append(r.entries[:i], r.entries[i+1:]...)
			return true
		}
	}
	return false
}

// #WNC PDU-DROP/REGISTRY
// List returns a copy of the entry list, oldest first. An empty list is a non-nil empty slice,
// so the HTTP answer is [] and not null.
func (r *DropRegistry) List() []*DropEntry {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]*DropEntry, 0, len(r.entries))
	return append(out, r.entries...)
}

// #WNC PDU-DROP/REGISTRY
// SMContextsMatching returns the SM contexts whose SUPI, DNN and S-NSSAI fall under the selector.
// The caller locks each SM context before changing it.
func SMContextsMatching(sel DropSelector) []*SMContext {
	var out []*SMContext
	smContextPool.Range(func(_, value interface{}) bool {
		sc := value.(*SMContext)
		if sc.SmfPduSessionSmContextCreateData != nil && sel.Matches(sc.Supi, sc.Dnn, sc.SNssai) {
			out = append(out, sc)
		}
		return true
	})
	return out
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `go test ./internal/context/ -run 'DropSelector|DropRegistry|SMContextsMatching|GPRSTimer3|Backoff' -v`
Expected: 7 tests `PASS`.

- [ ] **Step 5: Check formatting**

Run: `gofmt -l internal/context/pdu_drop.go internal/context/pdu_drop_test.go`
Expected: no output.

---

### Task 4: Processor - graceful release, validation and the three handlers

**Files:**
- Modify: `internal/sbi/processor/association.go` (`releaseAllResourcesOfUPF()` near line 226, `requestAMFToReleasePDUResources()` near line 240)
- Create: `internal/sbi/processor/pdu_drop.go`
- Test: `internal/sbi/processor/pdu_drop_test.go`

**Interfaces:**
- Consumes: `smf_context.GPRSTimer3`, `smf_context.BuildGSMPDUSessionReleaseCommandWithBackoff()` (Task 2); `smf_context.DropEntry`, `DropMode*`, `DropSelector`, `GetDropRegistry()`, `SMContextsMatching()` (Task 3).
- Produces:
  - `func (p *Processor) requestAMFToReleasePDUResources(smContext *smf_context.SMContext, cause uint8, backoff *smf_context.GPRSTimer3) (sendNotify bool, releaseContext bool)`
  - `type PduDropRequest struct`, `type PduDropSnssai struct`, `type PduDropSessionResult struct`, `type PduDropResponse struct`
  - `func (p *Processor) HandleCreatePduDrop(c *gin.Context, req PduDropRequest)`
  - `func (p *Processor) HandleListPduDrop(c *gin.Context)`
  - `func (p *Processor) HandleDeletePduDrop(c *gin.Context, dropId string)`
  - `func (p *Processor) pduDropRejectEntry(smContext *smf_context.SMContext) *smf_context.DropEntry` (used by Task 5)

The `graceful` apply step reuses the release path that the SMF already runs when a UPF is lost. That path is not unit-tested here, because it sends a real `Namf_Communication_N1N2MessageTransfer` to the AMF. Task 7 tests it on the cn host.

- [ ] **Step 1: Give `requestAMFToReleasePDUResources()` cause and back-off parameters**

In `internal/sbi/processor/association.go`, change the call inside `releaseAllResourcesOfUPF()` from:

```go
			needToSendNotify, removeContext := p.requestAMFToReleasePDUResources(smContext)
```

to:

```go
			// #WNC PDU-DROP/GRACEFUL-RELEASE
			// requestAMFToReleasePDUResources now takes the 5GSM cause and back-off from the caller,
			// so the graceful drop mode can send its own values. UPF loss keeps the cause it always
			// sent, Cause5GSMNetworkFailure (#38), with no back-off, so this path behaves as before.
			needToSendNotify, removeContext := p.requestAMFToReleasePDUResources(
				smContext, nasMessage.Cause5GSMNetworkFailure, nil)
```

Then change the function header and its first lines from:

```go
func (p *Processor) requestAMFToReleasePDUResources(
	smContext *smf_context.SMContext,
) (sendNotify bool, releaseContext bool) {
	n1n2Request := models.N1N2MessageTransferRequest{}
	// TS 23.502 4.3.4.2 3b. Send Namf_Communication_N1N2MessageTransfer Request, SMF->AMF
	n1n2Request.JsonData = &models.N1N2MessageTransferReqData{
		PduSessionId: smContext.PDUSessionID,
		SkipInd:      true,
	}
	cause := nasMessage.Cause5GSMNetworkFailure
	if buf, err := smf_context.BuildGSMPDUSessionReleaseCommand(smContext, cause, false); err != nil {
```

to:

```go
// #WNC PDU-DROP/GRACEFUL-RELEASE
// The 5GSM cause used to be hard-coded to Cause5GSMNetworkFailure (#38) here. The caller now chooses
// the cause and the optional back-off timer: UPF loss passes #38 and no back-off, and the graceful drop
// mode passes the values from its drop entry. A nil backoff leaves the Back-off timer value IE out.
func (p *Processor) requestAMFToReleasePDUResources(
	smContext *smf_context.SMContext, cause uint8, backoff *smf_context.GPRSTimer3,
) (sendNotify bool, releaseContext bool) {
	n1n2Request := models.N1N2MessageTransferRequest{}
	// TS 23.502 4.3.4.2 3b. Send Namf_Communication_N1N2MessageTransfer Request, SMF->AMF
	n1n2Request.JsonData = &models.N1N2MessageTransferReqData{
		PduSessionId: smContext.PDUSessionID,
		SkipInd:      true,
	}
	if buf, err := smf_context.BuildGSMPDUSessionReleaseCommandWithBackoff(smContext, cause, false, backoff); err != nil {
```

Leave the rest of the function unchanged.

- [ ] **Step 2: Check that the change keeps the build and the existing tests green**

Run: `go build ./... && go test ./internal/sbi/processor/`
Expected: no build output, then `ok  github.com/free5gc/smf/internal/sbi/processor`.

- [ ] **Step 3: Write the failing test**

Create `internal/sbi/processor/pdu_drop_test.go`:

```go
package processor

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"

	"github.com/free5gc/openapi/models"
	smf_context "github.com/free5gc/smf/internal/context"
)

func intPtr(v int) *int {
	return &v
}

func int32Ptr(v int32) *int32 {
	return &v
}

func int64Ptr(v int64) *int64 {
	return &v
}

// #WNC PDU-DROP/API
// pduDropTestRequest uses a DNN that no SM context in the test binary uses,
// so HandleCreatePduDrop finds no session and never calls the AMF.
func pduDropTestRequest() PduDropRequest {
	return PduDropRequest{
		Mode:   smf_context.DropModeGraceful,
		Dnn:    "pdu-drop-unit-test",
		Snssai: &PduDropSnssai{Sst: int32Ptr(1), Sd: "000001"},
	}
}

// #WNC PDU-DROP/API
func TestBuildDropEntryDefaults(t *testing.T) {
	req := pduDropTestRequest()
	entry, reason := buildDropEntry(&req)
	require.Empty(t, reason)
	require.Equal(t, uint8(36), entry.ReleaseCause)
	require.Equal(t, uint8(26), entry.RejectCause)
	require.Nil(t, entry.Backoff)
	require.Equal(t, uint32(0), entry.EncodedBackoffSeconds)
	require.Equal(t, "000001", entry.Selector.Snssai.Sd)
}

// #WNC PDU-DROP/API
func TestBuildDropEntryBackoffIsRoundedUp(t *testing.T) {
	req := pduDropTestRequest()
	req.BackoffSeconds = int64Ptr(63)
	entry, reason := buildDropEntry(&req)
	require.Empty(t, reason)
	require.Equal(t, uint32(90), entry.EncodedBackoffSeconds)
}

// #WNC PDU-DROP/API
func TestBuildDropEntryRejectsBadInput(t *testing.T) {
	cases := []struct {
		name   string
		change func(r *PduDropRequest)
	}{
		{"no mode", func(r *PduDropRequest) { r.Mode = "" }},
		{"no dnn", func(r *PduDropRequest) { r.Dnn = "" }},
		{"no snssai", func(r *PduDropRequest) { r.Snssai = nil }},
		{"no sst", func(r *PduDropRequest) { r.Snssai.Sst = nil }},
		{"sst too big", func(r *PduDropRequest) { r.Snssai.Sst = int32Ptr(256) }},
		{"sd not 6 hex digits", func(r *PduDropRequest) { r.Snssai.Sd = "12" }},
		{"releaseCause too big", func(r *PduDropRequest) { r.ReleaseCause = intPtr(300) }},
		{"rejectCause negative", func(r *PduDropRequest) { r.RejectCause = intPtr(-1) }},
		{"backoff negative", func(r *PduDropRequest) { r.BackoffSeconds = int64Ptr(-1) }},
		{"backoff too big", func(r *PduDropRequest) { r.BackoffSeconds = int64Ptr(pduDropMaxBackoffSeconds + 1) }},
	}
	for _, tc := range cases {
		req := pduDropTestRequest()
		tc.change(&req)
		entry, reason := buildDropEntry(&req)
		require.Nil(t, entry, tc.name)
		require.NotEmpty(t, reason, tc.name)
	}
}

// #WNC PDU-DROP/API
func callCreatePduDrop(p *Processor, req PduDropRequest) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	p.HandleCreatePduDrop(c, req)
	return w
}

// #WNC PDU-DROP/API
func TestPduDropHandlersLifecycle(t *testing.T) {
	gin.SetMode(gin.TestMode)
	p := &Processor{}

	w := callCreatePduDrop(p, pduDropTestRequest())
	require.Equal(t, http.StatusCreated, w.Code)
	var rsp PduDropResponse
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &rsp))
	require.NotEmpty(t, rsp.DropId)
	require.Equal(t, "/nsmf-oam/v1/pdu-drop/"+rsp.DropId, w.Header().Get("Location"))
	require.Empty(t, rsp.Affected)
	require.Empty(t, rsp.Skipped)
	dropId := rsp.DropId
	defer smf_context.GetDropRegistry().Remove(dropId)

	w = callCreatePduDrop(p, pduDropTestRequest())
	require.Equal(t, http.StatusConflict, w.Code)

	blackhole := pduDropTestRequest()
	blackhole.Mode = smf_context.DropModeBlackhole
	require.Equal(t, http.StatusNotImplemented, callCreatePduDrop(p, blackhole).Code)

	unknown := pduDropTestRequest()
	unknown.Mode = "unplug"
	require.Equal(t, http.StatusBadRequest, callCreatePduDrop(p, unknown).Code)

	w = httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	p.HandleListPduDrop(c)
	require.Equal(t, http.StatusOK, w.Code)
	require.Contains(t, w.Body.String(), `"dropId":"`+dropId+`"`)

	w = httptest.NewRecorder()
	c, _ = gin.CreateTestContext(w)
	p.HandleDeletePduDrop(c, dropId)
	require.Equal(t, http.StatusNoContent, w.Code)

	w = httptest.NewRecorder()
	c, _ = gin.CreateTestContext(w)
	p.HandleDeletePduDrop(c, dropId)
	require.Equal(t, http.StatusNotFound, w.Code)
}

// #WNC PDU-DROP/REJECT
func TestPduDropRejectEntry(t *testing.T) {
	p := &Processor{}
	req := pduDropTestRequest()
	entry, _ := buildDropEntry(&req)
	_, added := smf_context.GetDropRegistry().Add(entry)
	require.True(t, added)
	defer smf_context.GetDropRegistry().Remove(entry.DropId)

	sc := &smf_context.SMContext{}
	sc.SmfPduSessionSmContextCreateData = &models.SmfPduSessionSmContextCreateData{
		Supi: "imsi-001", Dnn: "pdu-drop-unit-test", SNssai: &models.Snssai{Sst: 1, Sd: "000001"},
	}
	require.Same(t, entry, p.pduDropRejectEntry(sc))

	sc.Dnn = "internet"
	require.Nil(t, p.pduDropRejectEntry(sc))
}
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `go test ./internal/sbi/processor/ -run 'DropEntry|PduDrop' -v`
Expected: build failure, `undefined: PduDropRequest`.

- [ ] **Step 5: Write the types and validation in `internal/sbi/processor/pdu_drop.go`**

```go
package processor

import (
	"fmt"
	"net/http"
	"regexp"

	"github.com/gin-gonic/gin"

	"github.com/free5gc/nas/nasMessage"
	"github.com/free5gc/openapi/models"
	smf_context "github.com/free5gc/smf/internal/context"
	"github.com/free5gc/smf/internal/logger"
	"github.com/free5gc/smf/pkg/factory"
)

// #WNC PDU-DROP/API
// PduDropSnssai uses a pointer for Sst, so a missing sst can be told apart from sst 0.
type PduDropSnssai struct {
	Sst *int32 `json:"sst"`
	Sd  string `json:"sd,omitempty"`
}

// #WNC PDU-DROP/API
// PduDropRequest is the body of POST /nsmf-oam/v1/pdu-drop.
// The pointer fields are optional; buildDropEntry fills in the defaults.
type PduDropRequest struct {
	Mode           smf_context.DropMode `json:"mode"`
	Dnn            string               `json:"dnn"`
	Snssai         *PduDropSnssai       `json:"snssai"`
	Supi           string               `json:"supi,omitempty"`
	ReleaseCause   *int                 `json:"releaseCause,omitempty"`
	RejectCause    *int                 `json:"rejectCause,omitempty"`
	BackoffSeconds *int64               `json:"backoffSeconds,omitempty"`
}

// #WNC PDU-DROP/API
// PduDropSessionResult reports what a drop did to one PDU session.
type PduDropSessionResult struct {
	Supi         string `json:"supi"`
	PduSessionId int32  `json:"pduSessionId"`
	Result       string `json:"result"`
}

// #WNC PDU-DROP/API
// PduDropResponse is the body of the 201 answer to POST /pdu-drop.
type PduDropResponse struct {
	*smf_context.DropEntry
	Affected []PduDropSessionResult `json:"affected"`
	Skipped  []PduDropSessionResult `json:"skipped"`
}

// #WNC PDU-DROP/API
// pduDropMaxBackoffSeconds is the longest GPRS timer 3 duration: 31 steps of 320 hours.
const pduDropMaxBackoffSeconds = 31 * 1152000

var pduDropSdPattern = regexp.MustCompile(`^[0-9A-Fa-f]{6}$`)

// #WNC PDU-DROP/API
// pduDropKnownModes lists every mode name the API accepts.
// A known mode that has no handler yet gets 501 Not Implemented.
var pduDropKnownModes = map[smf_context.DropMode]bool{
	smf_context.DropModeGraceful:  true,
	smf_context.DropModeBlackhole: true,
	smf_context.DropModeSilent:    true,
}

// #WNC PDU-DROP/API
// buildDropEntry checks the request and turns it into a drop entry.
// A non-empty string is the reason for a 400 answer, and the entry is then nil.
func buildDropEntry(req *PduDropRequest) (*smf_context.DropEntry, string) {
	if req.Mode == "" {
		return nil, "mode is required"
	}
	if req.Dnn == "" {
		return nil, "dnn is required"
	}
	if req.Snssai == nil || req.Snssai.Sst == nil {
		return nil, "snssai.sst is required"
	}
	if *req.Snssai.Sst < 0 || *req.Snssai.Sst > 255 {
		return nil, "snssai.sst must be 0-255"
	}
	if req.Snssai.Sd != "" && !pduDropSdPattern.MatchString(req.Snssai.Sd) {
		return nil, "snssai.sd must be 6 hex digits"
	}
	releaseCause, reason := pduDropCause(req.ReleaseCause, nasMessage.Cause5GSMRegularDeactivation, "releaseCause")
	if reason != "" {
		return nil, reason
	}
	rejectCause, reason := pduDropCause(req.RejectCause, nasMessage.Cause5GSMInsufficientResources, "rejectCause")
	if reason != "" {
		return nil, reason
	}
	var backoffSeconds int64
	if req.BackoffSeconds != nil {
		backoffSeconds = *req.BackoffSeconds
	}
	if backoffSeconds < 0 || backoffSeconds > pduDropMaxBackoffSeconds {
		return nil, fmt.Sprintf("backoffSeconds must be 0-%d", pduDropMaxBackoffSeconds)
	}
	backoff := smf_context.EncodeGPRSTimer3(uint32(backoffSeconds))
	return &smf_context.DropEntry{
		Mode: req.Mode,
		Selector: smf_context.DropSelector{
			Dnn:    req.Dnn,
			Snssai: models.Snssai{Sst: *req.Snssai.Sst, Sd: req.Snssai.Sd},
			Supi:   req.Supi,
		},
		ReleaseCause:          releaseCause,
		RejectCause:           rejectCause,
		Backoff:               backoff,
		EncodedBackoffSeconds: backoff.Seconds(),
	}, ""
}

// #WNC PDU-DROP/API
// pduDropCause returns def when the request leaves the cause out.
func pduDropCause(value *int, def uint8, name string) (uint8, string) {
	if value == nil {
		return def, ""
	}
	if *value < 0 || *value > 255 {
		return 0, name + " must be 0-255"
	}
	return uint8(*value), ""
}

// #WNC PDU-DROP/API
// pduDropProblem logs the reason and answers with ProblemDetails.
func pduDropProblem(c *gin.Context, status int, detail string) {
	logger.PduSessLog.Warnf("#WNC PDU-DROP/API status=%d %s", status, detail)
	c.JSON(status, models.ProblemDetails{
		Title:  http.StatusText(status),
		Status: int32(status),
		Detail: detail,
	})
}
```

- [ ] **Step 6: Append the mode interface and the graceful mode to `internal/sbi/processor/pdu_drop.go`**

```go
// #WNC PDU-DROP/API
// pduDropMode is the work that one drop mode does.
// Step 1 of the feature ships graceful. Steps 2 and 3 add blackhole and silent as new types,
// and add one case each to Processor.pduDropMode.
type pduDropMode interface {
	// Apply runs when the entry is created, once for each matching session.
	// The caller holds smContext.SMLock.
	Apply(smContext *smf_context.SMContext, entry *smf_context.DropEntry) (result string, err error)
	// Restore runs when the entry is deleted, before the entry leaves the drop list.
	Restore(entry *smf_context.DropEntry) error
	// RejectOnCreate reports whether a new PDU session that matches the entry is rejected.
	RejectOnCreate() bool
}

// #WNC PDU-DROP/API
// pduDropMode returns the handler for a mode, or nil when the mode has no handler yet.
func (p *Processor) pduDropMode(mode smf_context.DropMode) pduDropMode {
	switch mode {
	case smf_context.DropModeGraceful:
		return &gracefulDropMode{p: p}
	}
	return nil
}

// #WNC PDU-DROP/GRACEFUL-RELEASE
// gracefulDropMode sends a PDU Session Release Command, and then rejects the UE's retries until restore.
type gracefulDropMode struct {
	p *Processor
}

// #WNC PDU-DROP/GRACEFUL-RELEASE
// Apply runs the same release steps as releaseAllResourcesOfUPF, with the entry's cause and back-off.
func (m *gracefulDropMode) Apply(
	smContext *smf_context.SMContext, entry *smf_context.DropEntry,
) (string, error) {
	needToSendNotify, removeContext := m.p.requestAMFToReleasePDUResources(
		smContext, entry.ReleaseCause, entry.Backoff)
	if needToSendNotify {
		m.p.SendReleaseNotification(smContext)
	}
	if removeContext {
		m.p.RemoveSMContextFromAllNF(smContext, false)
		smContext.Log.Infof("#WNC PDU-DROP/GRACEFUL-RELEASE dropId=%s released, UE is CM-IDLE", entry.DropId)
		return "released-ue-idle", nil
	}
	if smContext.CheckState(smf_context.InActivePending) {
		smContext.Log.Infof("#WNC PDU-DROP/GRACEFUL-RELEASE dropId=%s release command sent, cause=%d",
			entry.DropId, entry.ReleaseCause)
		return "release-initiated", nil
	}
	err := fmt.Errorf("SM context state is %s after N1N2MessageTransfer", smContext.State())
	smContext.Log.Errorf("#WNC PDU-DROP/GRACEFUL-RELEASE dropId=%s release failed: %v", entry.DropId, err)
	return "release-failed", err
}

// #WNC PDU-DROP/GRACEFUL-RELEASE
// Restore has nothing to undo. Removing the entry lets the UE's next retry succeed.
func (m *gracefulDropMode) Restore(*smf_context.DropEntry) error {
	return nil
}

// #WNC PDU-DROP/GRACEFUL-RELEASE
func (m *gracefulDropMode) RejectOnCreate() bool {
	return true
}
```

- [ ] **Step 7: Append the handlers and the reject lookup to `internal/sbi/processor/pdu_drop.go`**

```go
// #WNC PDU-DROP/API
// HandleCreatePduDrop stores a drop entry and applies its mode to every matching session.
func (p *Processor) HandleCreatePduDrop(c *gin.Context, req PduDropRequest) {
	entry, reason := buildDropEntry(&req)
	if reason != "" {
		pduDropProblem(c, http.StatusBadRequest, reason)
		return
	}
	if !pduDropKnownModes[entry.Mode] {
		pduDropProblem(c, http.StatusBadRequest, fmt.Sprintf("unknown mode %q", entry.Mode))
		return
	}
	mode := p.pduDropMode(entry.Mode)
	if mode == nil {
		pduDropProblem(c, http.StatusNotImplemented, fmt.Sprintf("mode %q is not implemented yet", entry.Mode))
		return
	}
	if conflictId, added := smf_context.GetDropRegistry().Add(entry); !added {
		pduDropProblem(c, http.StatusConflict,
			"an entry with the same mode and selector already exists: dropId="+conflictId)
		return
	}
	logger.PduSessLog.Infof("#WNC PDU-DROP/REGISTRY added dropId=%s mode=%s dnn=%s sst=%d sd=%q supi=%q",
		entry.DropId, entry.Mode, entry.Selector.Dnn, entry.Selector.Snssai.Sst,
		entry.Selector.Snssai.Sd, entry.Selector.Supi)

	rsp := PduDropResponse{
		DropEntry: entry,
		Affected:  []PduDropSessionResult{},
		Skipped:   []PduDropSessionResult{},
	}
	for _, smContext := range smf_context.SMContextsMatching(entry.Selector) {
		result, applied := p.applyPduDrop(mode, smContext, entry)
		if applied {
			rsp.Affected = append(rsp.Affected, result)
		} else {
			rsp.Skipped = append(rsp.Skipped, result)
		}
	}
	c.Header("Location", factory.SmfOamUriPrefix+"/pdu-drop/"+entry.DropId)
	c.JSON(http.StatusCreated, rsp)
}

// #WNC PDU-DROP/API
// applyPduDrop runs the mode on one session when the session is in a state that
// releaseAllResourcesOfUPF also releases. Any other state is reported as skipped.
func (p *Processor) applyPduDrop(
	mode pduDropMode, smContext *smf_context.SMContext, entry *smf_context.DropEntry,
) (PduDropSessionResult, bool) {
	smContext.SMLock.Lock()
	defer smContext.SMLock.Unlock()
	result := PduDropSessionResult{Supi: smContext.Supi, PduSessionId: smContext.PDUSessionID}
	switch smContext.State() {
	case smf_context.Active, smf_context.ModificationPending, smf_context.PFCPModification:
	default:
		result.Result = "state=" + smContext.State().String()
		return result, false
	}
	result.Result, _ = mode.Apply(smContext, entry)
	return result, true
}

// #WNC PDU-DROP/API
// HandleListPduDrop answers with every drop entry, oldest first.
func (p *Processor) HandleListPduDrop(c *gin.Context) {
	c.JSON(http.StatusOK, smf_context.GetDropRegistry().List())
}

// #WNC PDU-DROP/RESTORE
// HandleDeletePduDrop runs the mode's restore step and removes the entry.
func (p *Processor) HandleDeletePduDrop(c *gin.Context, dropId string) {
	registry := smf_context.GetDropRegistry()
	entry := registry.Get(dropId)
	if entry == nil {
		pduDropProblem(c, http.StatusNotFound, "no drop entry with dropId="+dropId)
		return
	}
	if mode := p.pduDropMode(entry.Mode); mode != nil {
		if err := mode.Restore(entry); err != nil {
			pduDropProblem(c, http.StatusInternalServerError, "restore failed: "+err.Error())
			return
		}
	}
	registry.Remove(dropId)
	logger.PduSessLog.Infof("#WNC PDU-DROP/RESTORE removed dropId=%s mode=%s", dropId, entry.Mode)
	c.Status(http.StatusNoContent)
	c.Writer.WriteHeaderNow()
}

// #WNC PDU-DROP/REJECT
// pduDropRejectEntry returns the oldest drop entry that blocks this new PDU session, or nil.
func (p *Processor) pduDropRejectEntry(smContext *smf_context.SMContext) *smf_context.DropEntry {
	return smf_context.GetDropRegistry().Match(smContext.Supi, smContext.Dnn, smContext.SNssai,
		func(e *smf_context.DropEntry) bool {
			mode := p.pduDropMode(e.Mode)
			return mode != nil && mode.RejectOnCreate()
		})
}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `go test ./internal/sbi/processor/ -v -run 'DropEntry|PduDrop'`
Expected: 5 tests `PASS`.

Run: `go test ./internal/sbi/processor/`
Expected: `ok  github.com/free5gc/smf/internal/sbi/processor`.

- [ ] **Step 9: Check formatting**

Run: `gofmt -l internal/sbi/processor/association.go internal/sbi/processor/pdu_drop.go internal/sbi/processor/pdu_drop_test.go`
Expected: no output.

---

### Task 5: Reject new PDU sessions while a drop entry blocks them

**Files:**
- Modify: `internal/sbi/processor/pdu_session.go` (`HandlePDUSessionSMContextCreate()` after line 155; `makeEstRejectResAndReleaseSMContext()` near line 1141)
- Test: `internal/sbi/processor/pdu_session_test.go` (the table in `TestHandlePDUSessionSMContextCreate()`)

**Interfaces:**
- Consumes: `p.pduDropRejectEntry()` (Task 4); `smf_context.BuildGSMPDUSessionEstablishmentRejectWithBackoff()` (Task 2); `smf_context.GetDropRegistry()` and `DropEntry` (Task 3).
- Produces: `func (p *Processor) makeEstRejectResAndReleaseSMContextWithBackoff(c *gin.Context, smContext *smf_context.SMContext, nasErrorCause uint8, backoff *smf_context.GPRSTimer3, sbiError *models.SmfPduSessionExtProblemDetails)`.

The reject check sits after `HandlePDUSessionEstablishmentRequest()` because that function sets `smContext.Pti`, and the Reject message must carry the PTI of the UE's request. The existing 5GSM-error reject path sits at the same place.

- [ ] **Step 1: Write the failing test case**

In `internal/sbi/processor/pdu_session_test.go`, add this helper after `initDiscAMFStubNRF()`:

```go
// #WNC PDU-DROP/REJECT
// pduDropTestEntryId remembers the drop entry that initPduDropEntry adds, so the test can remove it.
var pduDropTestEntryId string

// #WNC PDU-DROP/REJECT
// initPduDropEntry blocks DNN internet on slice 1/112232 for every UE, with reject cause 26 and no back-off.
func initPduDropEntry() {
	entry := &smf_context.DropEntry{
		Mode: smf_context.DropModeGraceful,
		Selector: smf_context.DropSelector{
			Dnn:    "internet",
			Snssai: models.Snssai{Sst: 1, Sd: "112232"},
		},
		ReleaseCause: nasMessage.Cause5GSMRegularDeactivation,
		RejectCause:  nasMessage.Cause5GSMInsufficientResources,
	}
	smf_context.GetDropRegistry().Add(entry)
	pduDropTestEntryId = entry.DropId
}
```

Then add this case as the **last** entry of the `testCases` table, after the case whose `paramStr` is `"input correct PostSmContexts Request\n"`. It must be last, because the drop entry would also block that earlier case.

```go
		// #WNC PDU-DROP/REJECT
		// This case must stay last: its drop entry would also block the passing case above.
		{
			initFuncs: []func(){
				initDiscUDMStubNRF, initDiscPCFStubNRF,
				initGetSMDataStubUDM, initSMPoliciesPostStubPCF, initDiscAMFStubNRF,
				initPduDropEntry,
			},
			request: models.PostSmContextsRequest{
				JsonData: &models.SmfPduSessionSmContextCreateData{
					Supi:         "imsi-208930000007487",
					Pei:          "imeisv-1110000000000000",
					Gpsi:         "msisdn-0900000000",
					PduSessionId: 10,
					Dnn:          "internet",
					SNssai: &models.Snssai{
						Sst: 1,
						Sd:  "112232",
					},
					ServingNfId: "c8d0ee65-f466-48aa-a42f-235ec771cb52",
					Guami: &models.Guami{
						PlmnId: &models.PlmnIdNid{
							Mcc: "208",
							Mnc: "93",
						},
						AmfId: "cafe00",
					},
					AnType: "3GPP_ACCESS",
					ServingNetwork: &models.PlmnIdNid{
						Mcc: "208",
						Mnc: "93",
					},
				},
				BinaryDataN1SmMessage: buildPDUSessionEstablishmentRequest(10, 4, nasMessage.PDUSessionTypeIPv4),
			},
			paramStr:     "#WNC PDU-DROP/REJECT request while a drop entry blocks DNN internet\n",
			resultStr:    "PDUSessionSMContextCreate should reject with cause 26\n",
			responseBody: &models.PostSmContextsError{},
			expectedHTTPRsp: &httpwrapper.Response{
				Header: nil,
				Status: http.StatusForbidden,
				Body: models.PostSmContextsError{
					JsonData: &models.SmContextCreateError{
						Error:   &PDUSession_errors.N1SmError,
						N1SmMsg: &models.RefToBinaryData{ContentId: "n1SmMsg"},
					},
					BinaryDataN1SmMessage: buildPDUSessionEstablishmentReject(
						10, 4, nasMessage.Cause5GSMInsufficientResources),
				},
			},
		},
```

Finally, directly before the line `err = udp.ClosePfcp()` at the end of the test function, add:

```go
	// #WNC PDU-DROP/REJECT
	smf_context.GetDropRegistry().Remove(pduDropTestEntryId)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `go test ./internal/sbi/processor/ -run TestHandlePDUSessionSMContextCreate -v`
Expected: the new sub-test FAILS. The handler still accepts the session, so the status is `201` and not `403`.

- [ ] **Step 3: Split the reject helper so that it can carry a back-off**

In `internal/sbi/processor/pdu_session.go`, replace the whole `makeEstRejectResAndReleaseSMContext()` function with:

```go
// #WNC PDU-DROP/REJECT
// The body moved to makeEstRejectResAndReleaseSMContextWithBackoff so the PDU drop reject can add
// a Back-off timer value IE. This wrapper passes no back-off, so existing callers behave as before.
func (p *Processor) makeEstRejectResAndReleaseSMContext(
	c *gin.Context,
	smContext *smf_context.SMContext,
	nasErrorCause uint8,
	sbiError *models.SmfPduSessionExtProblemDetails,
) {
	p.makeEstRejectResAndReleaseSMContextWithBackoff(c, smContext, nasErrorCause, nil, sbiError)
}

// #WNC PDU-DROP/REJECT
// makeEstRejectResAndReleaseSMContextWithBackoff adds the Back-off timer value IE to the
// PDU Session Establishment Reject when backoff is not nil.
func (p *Processor) makeEstRejectResAndReleaseSMContextWithBackoff(
	c *gin.Context,
	smContext *smf_context.SMContext,
	nasErrorCause uint8,
	backoff *smf_context.GPRSTimer3,
	sbiError *models.SmfPduSessionExtProblemDetails,
) {
	postSmContextsError := models.PostSmContextsError{
		JsonData: &models.SmContextCreateError{
			Error:   sbiError,
			N1SmMsg: &models.RefToBinaryData{ContentId: "n1SmMsg"},
		},
	}
	if buf, err := smf_context.
		BuildGSMPDUSessionEstablishmentRejectWithBackoff(
			smContext,
			nasErrorCause,
			backoff); err != nil {
		logger.PduSessLog.Errorf("Build GSM PDUSessionEstablishmentReject failed: %+v", err)
	} else {
		postSmContextsError.BinaryDataN1SmMessage = buf
	}
	p.nasErrorResponse(c, int(sbiError.Status), postSmContextsError)
	p.RemoveSMContextFromAllNF(smContext, false)
}
```

- [ ] **Step 4: Add the reject check to `HandlePDUSessionSMContextCreate()`**

In `internal/sbi/processor/pdu_session.go`, find the block that ends:

```go
		p.makeEstRejectResAndReleaseSMContext(c, smContext,
			nasMessage.Cause5GSMRequestRejectedUnspecified,
			&smf_errors.N1SmError)
		return
	}
```

Directly after that closing `}`, and before the comment `// Discover and new Namf_Comm client for use later`, insert:

```go

	// #WNC PDU-DROP/REJECT
	// A drop entry blocks new PDU sessions on its DNN and slice until DELETE /pdu-drop/:dropId removes it.
	// The check sits after HandlePDUSessionEstablishmentRequest because that function sets smContext.Pti,
	// and the Reject must carry the PTI of the UE's request.
	if entry := p.pduDropRejectEntry(smContext); entry != nil {
		smContext.Log.Infof("#WNC PDU-DROP/REJECT rejecting supi=%s dnn=%s dropId=%s cause=%d backoff=%ds",
			smContext.Supi, smContext.Dnn, entry.DropId, entry.RejectCause, entry.EncodedBackoffSeconds)
		p.makeEstRejectResAndReleaseSMContextWithBackoff(c, smContext,
			entry.RejectCause, entry.Backoff, &smf_errors.N1SmError)
		return
	}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `go test ./internal/sbi/processor/ -run TestHandlePDUSessionSMContextCreate -v`
Expected: every sub-test `PASS`, including `#WNC PDU-DROP/REJECT request while a drop entry blocks DNN internet`.

Run: `go test ./internal/sbi/processor/`
Expected: `ok  github.com/free5gc/smf/internal/sbi/processor`.

- [ ] **Step 6: Check formatting**

Run: `gofmt -l internal/sbi/processor/pdu_session.go internal/sbi/processor/pdu_session_test.go`
Expected: no output.

---

### Task 6: HTTP routes and config-controlled registration

**Files:**
- Create: `internal/sbi/api_pdudrop.go`
- Modify: `internal/sbi/server.go` (`newRouter()`, after the `for _, serviceName := range ...` loop)
- Test: `internal/sbi/api_pdudrop_test.go`

**Interfaces:**
- Consumes: `factory.Config.GetPduDropEnable()` and `GetPduDropSkipOAuth()` (Task 1); `processor.PduDropRequest`, `HandleCreatePduDrop()`, `HandleListPduDrop()`, `HandleDeletePduDrop()` (Task 4).
- Produces: `func (s *Server) getPduDropRoutes() []Route`, `func registerPduDropRoutes(router *gin.Engine, cfg *factory.Config, routes []Route)`.

With `skipOAuth: false`, the drop group gets the same `util_oauth.NewRouterAuthorizationCheck(models.ServiceName_NSMF_OAM)` middleware as the other OAM routes. That middleware lets every request through when `smf_context.GetSelf().OAuth2Required` is false, and answers `401` to a request without a valid token when it is true.

- [ ] **Step 1: Write the failing test**

Create `internal/sbi/api_pdudrop_test.go`:

```go
package sbi

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"

	smf_context "github.com/free5gc/smf/internal/context"
	"github.com/free5gc/smf/pkg/factory"
)

// #WNC PDU-DROP/CONFIG
// pduDropProbe registers one stub route through registerPduDropRoutes and returns the status of a GET to it.
func pduDropProbe(t *testing.T, cfg *factory.Config) int {
	t.Helper()
	gin.SetMode(gin.TestMode)
	router := gin.New()
	routes := []Route{{
		Name:    "probe",
		Method:  http.MethodGet,
		Pattern: "/pdu-drop",
		APIFunc: func(c *gin.Context) { c.Status(http.StatusOK) },
	}}
	registerPduDropRoutes(router, cfg, routes)

	w := httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest(http.MethodGet, factory.SmfOamUriPrefix+"/pdu-drop", nil))
	return w.Code
}

// #WNC PDU-DROP/CONFIG
func pduDropConfig(block *factory.PduDropConfig) *factory.Config {
	return &factory.Config{Configuration: &factory.Configuration{PduDrop: block}}
}

// #WNC PDU-DROP/CONFIG
func TestRegisterPduDropRoutes(t *testing.T) {
	smfSelf := smf_context.GetSelf()
	oldRequired := smfSelf.OAuth2Required
	defer func() { smfSelf.OAuth2Required = oldRequired }()
	smfSelf.OAuth2Required = true

	require.Equal(t, http.StatusNotFound, pduDropProbe(t, pduDropConfig(nil)), "missing block")
	require.Equal(t, http.StatusNotFound,
		pduDropProbe(t, pduDropConfig(&factory.PduDropConfig{Enable: false, SkipOAuth: true})), "enable false")
	require.Equal(t, http.StatusOK,
		pduDropProbe(t, pduDropConfig(&factory.PduDropConfig{Enable: true, SkipOAuth: true})), "skipOAuth true")
	require.Equal(t, http.StatusUnauthorized,
		pduDropProbe(t, pduDropConfig(&factory.PduDropConfig{Enable: true, SkipOAuth: false})), "skipOAuth false")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `go test ./internal/sbi/ -run TestRegisterPduDropRoutes -v`
Expected: build failure, `undefined: registerPduDropRoutes`.

- [ ] **Step 3: Write `internal/sbi/api_pdudrop.go`**

```go
package sbi

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/free5gc/openapi/models"
	smf_context "github.com/free5gc/smf/internal/context"
	"github.com/free5gc/smf/internal/logger"
	"github.com/free5gc/smf/internal/sbi/processor"
	util_oauth "github.com/free5gc/smf/internal/util/oauth"
	"github.com/free5gc/smf/pkg/factory"
)

// #WNC PDU-DROP/API
// getPduDropRoutes returns the routes under /nsmf-oam/v1 that drop and restore PDU sessions.
func (s *Server) getPduDropRoutes() []Route {
	return []Route{
		{
			Name:    "Create PDU Drop",
			Method:  http.MethodPost,
			Pattern: "/pdu-drop",
			APIFunc: s.HTTPCreatePduDrop,
		},
		{
			Name:    "List PDU Drops",
			Method:  http.MethodGet,
			Pattern: "/pdu-drop",
			APIFunc: s.HTTPListPduDrop,
		},
		{
			Name:    "Delete PDU Drop",
			Method:  http.MethodDelete,
			Pattern: "/pdu-drop/:dropId",
			APIFunc: s.HTTPDeletePduDrop,
		},
	}
}

// #WNC PDU-DROP/API
func (s *Server) HTTPCreatePduDrop(c *gin.Context) {
	var req processor.PduDropRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		logger.SBILog.Warnf("#WNC PDU-DROP/API cannot parse request body: %v", err)
		c.JSON(http.StatusBadRequest, models.ProblemDetails{
			Title:  http.StatusText(http.StatusBadRequest),
			Status: http.StatusBadRequest,
			Detail: err.Error(),
		})
		return
	}
	s.Processor().HandleCreatePduDrop(c, req)
}

// #WNC PDU-DROP/API
func (s *Server) HTTPListPduDrop(c *gin.Context) {
	s.Processor().HandleListPduDrop(c)
}

// #WNC PDU-DROP/RESTORE
func (s *Server) HTTPDeletePduDrop(c *gin.Context) {
	s.Processor().HandleDeletePduDrop(c, c.Params.ByName("dropId"))
}

// #WNC PDU-DROP/CONFIG
// registerPduDropRoutes adds the drop routes only when pduDrop.enable is true.
// With pduDrop.skipOAuth true, the routes skip the NRF token check that the other OAM routes use.
func registerPduDropRoutes(router *gin.Engine, cfg *factory.Config, routes []Route) {
	if !cfg.GetPduDropEnable() {
		logger.InitLog.Debugf("#WNC PDU-DROP/CONFIG pduDrop.enable is false, drop routes not registered")
		return
	}
	group := router.Group(factory.SmfOamUriPrefix)
	if cfg.GetPduDropSkipOAuth() {
		logger.InitLog.Warnf("#WNC PDU-DROP/CONFIG drop routes registered under %s without OAuth2 check",
			factory.SmfOamUriPrefix)
	} else {
		routerAuthorizationCheck := util_oauth.NewRouterAuthorizationCheck(models.ServiceName_NSMF_OAM)
		group.Use(func(c *gin.Context) {
			routerAuthorizationCheck.Check(c, smf_context.GetSelf())
		})
		logger.InitLog.Infof("#WNC PDU-DROP/CONFIG drop routes registered under %s with OAuth2 check",
			factory.SmfOamUriPrefix)
	}
	applyRoutes(group, routes)
}
```

- [ ] **Step 4: Call `registerPduDropRoutes()` from `newRouter()`**

In `internal/sbi/server.go`, inside `newRouter()`, find the end of the service loop:

```go
			applyRoutes(smfOAMGroup, smfOAMRoutes)
		}
	}

	return router
}
```

Change it to:

```go
			applyRoutes(smfOAMGroup, smfOAMRoutes)
		}
	}

	// #WNC PDU-DROP/CONFIG
	// The PDU drop routes are registered outside the service loop above, because pduDrop.enable
	// and pduDrop.skipOAuth in smfcfg decide whether the routes exist and whether the routes need a token.
	registerPduDropRoutes(router, factory.SmfConfig, s.getPduDropRoutes())

	return router
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `go test ./internal/sbi/ -run TestRegisterPduDropRoutes -v`
Expected: `PASS`.

Run: `go build ./... && go vet ./internal/sbi/... && go test ./internal/sbi/... ./pkg/factory/`
Expected: no build or vet output, then `ok` for `internal/sbi`, `internal/sbi/processor` and `pkg/factory`. Packages with no test files print `[no test files]`.

- [ ] **Step 6: Check formatting**

Run: `gofmt -l internal/sbi/api_pdudrop.go internal/sbi/api_pdudrop_test.go internal/sbi/server.go`
Expected: no output.

---

### Task 7: Config file, build, live test on the cn host, and the submodule bump

**Files:**
- Modify: `config/smfcfg_unbound_dns64.yaml` in the parent free5gc repo (the target of the symlink `config/smfcfg.yaml`)
- Modify: the `NFs/smf` submodule pointer in the parent free5gc repo

**Interfaces:**
- Consumes: everything from Tasks 1-6.
- Produces: a running SMF with the drop API turned on, and one parent-repo commit.

The commands in this task run from the parent free5gc directory, `/home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc`, unless a step says otherwise.

- [ ] **Step 1: Check that the symlink is intact before editing**

Run: `ls -l config/smfcfg.yaml`
Expected: `config/smfcfg.yaml -> smfcfg_unbound_dns64.yaml`.

- [ ] **Step 2: Add the `pduDrop` block to `config/smfcfg_unbound_dns64.yaml`**

Open the file with the Edit tool, not with a tool that rewrites the symlink. Insert these lines inside `configuration:`, at the same indent as `serviceNameList:`, directly above `serviceNameList:`:

```yaml
  # #WNC PDU-DROP/CONFIG
  # OAM API to drop and restore PDU sessions for UE recovery tests.
  # skipOAuth true lets a plain curl call reach /nsmf-oam/v1/pdu-drop without an NRF token.
  pduDrop:
    enable: true
    skipOAuth: true
```

- [ ] **Step 3: Check that the symlink survived and the YAML parses**

Run: `ls -l config/smfcfg.yaml`
Expected: still `config/smfcfg.yaml -> smfcfg_unbound_dns64.yaml`.

Run: `python3 -c "import yaml; print(yaml.safe_load(open('config/smfcfg.yaml'))['configuration']['pduDrop'])"`
Expected: `{'enable': True, 'skipOAuth': True}`.

- [ ] **Step 4: Build the SMF binary**

Run: `make smf`
Expected: the build finishes without errors, and `bin/smf` has a new modification time (`ls -l bin/smf`).

- [ ] **Step 5: Restart the core with the new SMF and check the route log line**

Restart the core the way it is normally started on the cn host. Then search the SMF log:

Run: `grep -n '#WNC PDU-DROP/CONFIG' <smf log file>`
Expected: `#WNC PDU-DROP/CONFIG drop routes registered under /nsmf-oam/v1 without OAuth2 check`.

- [ ] **Step 6: Live test - list with no entries**

Run: `curl -s http://127.0.0.2:8000/nsmf-oam/v1/pdu-drop`
Expected: `[]`.

- [ ] **Step 7: Live test - drop one PDU session of the test UE**

Bring up the UE so that it holds its 3 PDU sessions. Pick one session and use its DNN and slice from `config/smfcfg_unbound_dns64.yaml`. The example below uses DNN `internet` on slice `sst=1, sd=000001`. Replace the SUPI with the test UE's SUPI.

Run:
```
curl -s -i -X POST http://127.0.0.2:8000/nsmf-oam/v1/pdu-drop -H 'Content-Type: application/json' -d '{"mode":"graceful","dnn":"fast.t-mobile.com","snssai":{"sst":1,"sd":"000bb8"},"supi":"imsi-310260000013069"}'
```
Expected: `HTTP/1.1 201 Created`, a `Location: /nsmf-oam/v1/pdu-drop/1` header, and `"affected"` holding one session with `"result":"release-initiated"`.

Then check all of these:
- The SMF log shows `#WNC PDU-DROP/GRACEFUL-RELEASE dropId=1 release command sent, cause=36`.
- The UE interface for that session loses its WAN IP address.
- The UE's re-establishment attempts appear in the SMF log as `#WNC PDU-DROP/REJECT rejecting supi=imsi-310260000013069 dnn=internet dropId=1 cause=26 backoff=0s`.
- In QXDM, the UE receives a PDU Session Release Command with 5GSM cause 36, followed by PDU Session Establishment Reject messages with 5GSM cause 26.
- The other 2 PDU sessions keep passing traffic.

- [ ] **Step 8: Live test - restore**

Run: `curl -s -i -X DELETE http://127.0.0.2:8000/nsmf-oam/v1/pdu-drop/1`
Expected: `HTTP/1.1 204 No Content`, and the SMF log shows `#WNC PDU-DROP/RESTORE removed dropId=1 mode=graceful`.

Then check that the UE's next PDU Session Establishment Request succeeds and the interface gets a WAN IP address again.

Run: `curl -s -i -X DELETE http://127.0.0.2:8000/nsmf-oam/v1/pdu-drop/1`
Expected: `HTTP/1.1 404 Not Found`.

- [ ] **Step 9: Live test - back-off timer**

Run:
```
curl -s -X POST http://127.0.0.2:8000/nsmf-oam/v1/pdu-drop -H 'Content-Type: application/json' -d '{"mode":"graceful","dnn":"fast.t-mobile.com","snssai":{"sst":1,"sd":"000bb8"},"supi":"imsi-310260000013069","releaseCause":26,"backoffSeconds":60}'
```
Expected: `"encodedBackoffSeconds":60` in the answer. In QXDM, the Release Command carries cause 26 and a Back-off timer value of 60 seconds. The UE then waits about 60 seconds before it retries.

Restore with `curl -s -X DELETE http://127.0.0.2:8000/nsmf-oam/v1/pdu-drop/<dropId from the answer>`.

- [ ] **Step 10: Live test - API errors**

Run: `curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.2:8000/nsmf-oam/v1/pdu-drop -H 'Content-Type: application/json' -d '{"mode":"blackhole","dnn":"fast.t-mobile.com","snssai":{"sst":1,"sd":"000bb8"}}'`
Expected: `501`.

Run: `curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.2:8000/nsmf-oam/v1/pdu-drop -H 'Content-Type: application/json' -d '{"mode":"graceful","dnn":"fast.t-mobile.com"}'`
Expected: `400`.

- [ ] **Step 11: Commit everything, only after the user confirms Steps 5-10 passed on the UE**

This is the only commit step in the plan. Do not run it until the user has verified the PDU drop behavior.

First commit the SMF code in the `NFs/smf` repo, using the noreply email address:

```bash
cd NFs/smf
git add pkg/factory/config.go pkg/factory/pdu_drop_config_test.go \
  internal/context/gsm_build.go internal/context/gsm_build_backoff_test.go \
  internal/context/pdu_drop.go internal/context/pdu_drop_test.go \
  internal/sbi/processor/association.go internal/sbi/processor/pdu_drop.go internal/sbi/processor/pdu_drop_test.go \
  internal/sbi/processor/pdu_session.go internal/sbi/processor/pdu_session_test.go \
  internal/sbi/api_pdudrop.go internal/sbi/api_pdudrop_test.go internal/sbi/server.go
git -c user.email=lori041987@users.noreply.github.com commit -m "feat(pdu-drop): add manual PDU session drop API with graceful release mode"
cd ../..
```

Then commit the config file and the submodule bump in the parent repo. Run `git status` first. The deleted `cert/nrf.pem` and the untracked `my_logs/` must stay out of this commit.

```bash
git add config/smfcfg_unbound_dns64.yaml NFs/smf
git commit -m "feat(pdu-drop): turn on SMF PDU session drop API on cn; bump smf"
```

---

## Later steps (not in this plan)

- Step 2 adds `blackholeDropMode` in `internal/sbi/processor/pdu_drop.go` and one `case` in `Processor.pduDropMode()`, with tags `PDU-DROP/BLACKHOLE-FAR` and `PDU-DROP/BLACKHOLE-RESTORE`.
- Step 3 adds `silentDropMode` the same way, with tag `PDU-DROP/SILENT-DELETE`.
- Step 4 adds a webconsole page that calls `/nsmf-oam/v1/pdu-drop`, with tag `PDU-DROP/WEBCONSOLE`. With `skipOAuth: false`, that page has to fetch an NRF token first, as the spec's section 9.3 describes.
