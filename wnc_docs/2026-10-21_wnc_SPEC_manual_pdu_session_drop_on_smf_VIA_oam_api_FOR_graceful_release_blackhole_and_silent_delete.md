# SPEC: manual PDU session drop on the SMF

| Field | Value |
|---|---|
| Date | 2026-10-21 |
| Status | Approved design, not implemented |
| Component | `NFs/smf` (Session Management Function) |
| Delivery | 4 steps; this spec details step 1 and fixes the extension points for steps 2-4 |

## 1. Purpose

The test UE opens 3 PDU sessions, one per slice, and gets one WAN IP address on each of 3 interfaces.
In a live operator network, one of those PDU sessions can fail for a while and then come back.
That event is random, so the UE's automatic recovery cannot be tested on demand.

This feature lets a tester drop a chosen PDU session from the core network, and later let it return.
The tester picks the session and picks the moment of return.

## 2. Terms

- **PDU session** (Protocol Data Unit session): the 5G data connection between the UE and a data network. "PDN connection" is the 4G name for the same idea.
- **DNN** (Data Network Name): the 5G name for the APN, for example `internet`.
- **S-NSSAI** (Single Network Slice Selection Assistance Information): the slice, written as SST (Slice/Service Type) plus an optional SD (Slice Differentiator), for example `sst=1, sd=000001`.
- **SUPI** (Subscription Permanent Identifier): the subscriber identity, for example `imsi-466110000000548`.
- **5GSM cause**: the numeric reason inside a 5G Session Management message (3GPP TS 24.501 clause 9.11.4.2).
- **Back-off timer value**: an optional IE (Information Element), IEI `0x37`, encoded as GPRS timer 3. The UE starts timer T3396 with the value from this IE, and does not retry the same DNN and slice until T3396 expires.
- **FAR** (Forwarding Action Rule): a PFCP (Packet Forwarding Control Protocol) rule that tells the UPF to forward (`FORW`) or drop (`DROP`) packets.
- **Drop entry**: one record in the SMF's in-memory drop list, created by one `POST /pdu-drop` call.

## 3. Drop modes

| Mode | Value of `mode` | What the UE sees | What "return" means | Delivery step |
|---|---|---|---|---|
| Graceful release | `graceful` | A PDU Session Release Command with the chosen cause. The UE's re-establishment requests get a PDU Session Establishment Reject until restore. | The SMF accepts the UE's next PDU Session Establishment Request. | 1 |
| Black hole | `blackhole` | No signaling. The UE keeps its IP address, but the UPF drops every packet of the session. | The SMF sets the session's FARs back to `FORW`; the same IP address works again. | 2 |
| Silent core-side delete | `silent` | No signaling at drop time. The UE learns later, through the PDU Session Status IE or a rejected request. | The SMF accepts the UE's next PDU Session Establishment Request. | 3 |

Step 4 adds a webconsole page that calls the same API.

## 4. Configuration

A new optional block goes under `configuration:` in the SMF config file.

```yaml
configuration:
  pduDrop:
    enable: true
    skipOAuth: true
```

- `enable: false`, or a missing `pduDrop` block, means the SMF does not register the drop routes. A call to them returns `404`.
- `skipOAuth: true` registers the drop routes in their own route group under `/nsmf-oam/v1`, without `NewRouterAuthorizationCheck`. A plain `curl` call works.
- `skipOAuth: false` registers the drop routes inside the existing OAM group in `NFs/smf/internal/sbi/server.go`. Each call then needs a Bearer token from the NRF; section 9.3 shows how a caller gets one.
- `config/smfcfg.yaml` is a symlink to `config/smfcfg_unbound_dns64.yaml`. The block is added to the link target, and the symlink is kept.
- The struct goes in `NFs/smf/pkg/factory/config.go`, next to the other fields of `Configuration`.

## 5. HTTP API

All routes sit under `factory.SmfOamUriPrefix`, which is `/nsmf-oam/v1`. The SMF SBI address on the cn host is `127.0.0.2:8000`.

### 5.1 `POST /pdu-drop` - create a drop entry

Request body:

```json
{
  "mode": "graceful",
  "dnn": "internet",
  "snssai": { "sst": 1, "sd": "000001" },
  "supi": "imsi-466110000000548",
  "releaseCause": 36,
  "rejectCause": 26,
  "backoffSeconds": 0
}
```

| Field | Required | Default | Rule |
|---|---|---|---|
| `mode` | yes | none | `graceful`, `blackhole` or `silent`. In step 1, `blackhole` and `silent` return `501 Not Implemented`. |
| `dnn` | yes | none | Compared exactly against the session's DNN. |
| `snssai.sst` | yes | none | 0-255. |
| `snssai.sd` | no | none | 6 hex digits. When `sd` is omitted, the entry matches only sessions that have no SD. This follows the rule that `smfcfg` already uses for its SST-only slice entry. |
| `supi` | no | none | When present, the entry matches only that UE. When omitted, the entry matches every UE on that DNN and slice. |
| `releaseCause` | no | 36 (regular deactivation) | 5GSM cause placed in the PDU Session Release Command. Used by `graceful`. |
| `rejectCause` | no | 26 (insufficient resources) | 5GSM cause placed in the PDU Session Establishment Reject. Used by `graceful` and `silent`. |
| `backoffSeconds` | no | 0 | 0 omits the Back-off timer value IE. A value above 0 adds the IE to both the Release Command and the Reject. The SMF rounds the value up to the nearest value that GPRS timer 3 can encode, and the response reports the encoded value. |

Responses:

- `201 Created` with a `Location` header and this body:
  ```json
  {
    "dropId": "1",
    "mode": "graceful",
    "selector": { "dnn": "internet", "snssai": { "sst": 1, "sd": "000001" }, "supi": "imsi-466110000000548" },
    "encodedBackoffSeconds": 0,
    "affected": [ { "supi": "imsi-466110000000548", "pduSessionId": 2, "result": "released" } ],
    "skipped":  [ ]
  }
  ```
  `affected` lists the sessions that the SMF released. `skipped` lists matching sessions that were not in the `Active` state, with the state name. Both lists may be empty; the block still applies to sessions set up later.
- `400 Bad Request` with ProblemDetails when a required field is missing, a cause is outside 0-255, or `sd` is not 6 hex digits.
- `409 Conflict` when an entry with exactly the same `mode`, `dnn`, `snssai` and `supi` already exists. The body names the existing `dropId`.
- `501 Not Implemented` for a mode whose delivery step has not landed.

### 5.2 `GET /pdu-drop` - list drop entries

Returns `200 OK` with an array of entries in the shape of the `201` body above, plus `createdAt`.

### 5.3 `DELETE /pdu-drop/:dropId` - restore

- `204 No Content` after the SMF has run the mode's restore step and removed the entry.
- `404 Not Found` when no entry has that ID.

For `graceful`, the restore step only removes the entry. The SMF sends nothing to the UE. The UE's next PDU Session Establishment Request succeeds, and that retry is the behavior under test.

## 6. Components

| File | New or changed | Job |
|---|---|---|
| `NFs/smf/pkg/factory/config.go` | changed | `PduDrop` struct with `Enable` and `SkipOAuth`, plus getter methods that return false when the block is missing. |
| `NFs/smf/internal/context/pdu_drop.go` | new | The drop list. Holds `DropEntry` values behind a mutex, issues IDs, matches a session against the list, and rejects an exact duplicate selector. It has no HTTP or PFCP code, so unit tests can drive it directly. |
| `NFs/smf/internal/context/gsm_build.go` | changed | Adds the Back-off timer value IE to the Reject and the Release Command when a back-off value is given. Adds the GPRS timer 3 encoder. Existing callers keep their current output. |
| `NFs/smf/internal/sbi/processor/association.go` | changed | `requestAMFToReleasePDUResources()` takes the 5GSM cause and back-off as parameters. `releaseAllResourcesOfUPF()` passes `Cause5GSMNetworkFailure` and no back-off, so UPF-loss behavior does not change. |
| `NFs/smf/internal/sbi/processor/pdu_drop.go` | new | Request validation, the per-mode apply and restore steps, and the reject check called from the create handler. |
| `NFs/smf/internal/sbi/processor/pdu_session.go` | changed | `HandlePDUSessionSMContextCreate()` calls the reject check right after `HandlePDUSessionEstablishmentRequest()` succeeds. At that point `smContext.Pti` is set, and the existing `makeEstRejectResAndReleaseSMContext()` path can build and send the Reject. |
| `NFs/smf/internal/sbi/api_pdudrop.go` | new | The three routes and their handlers. |
| `NFs/smf/internal/sbi/server.go` | changed | Registers the drop routes according to `enable` and `skipOAuth`. |

### 6.1 Extension point for steps 2 and 3

`processor/pdu_drop.go` defines one handler per mode behind a small interface:

```go
type pduDropMode interface {
	// Apply runs when the entry is created, on each matching session.
	Apply(smContext *smf_context.SMContext, entry *smf_context.DropEntry) (result string, err error)
	// Restore runs when the entry is deleted.
	Restore(entry *smf_context.DropEntry) error
	// RejectOnCreate reports whether a new PDU session matching the entry is rejected.
	RejectOnCreate() bool
}
```

| Mode | `Apply` | `Restore` | `RejectOnCreate` |
|---|---|---|---|
| `graceful` (step 1) | Sends the Release Command and N2 release through `requestAMFToReleasePDUResources()`, then removes the SM context. | Nothing. | true |
| `blackhole` (step 2) | Sets every FAR of the session to `DROP` and sends a PFCP Session Modification. Records the session in the entry. | Sets the recorded sessions' FARs back to `FORW` and sends PFCP Session Modification. | Decided in the step 2 spec. |
| `silent` (step 3) | Removes the SM context and the PFCP session without any N1 or N2 message. | Nothing. | true |

Step 1 implements `graceful` only. Steps 2 and 3 each add one type and one row in the mode table, without changing the API, the drop list, or the reject check.

### 6.2 Matching

A session matches an entry when all of these hold:

- the DNN strings are equal;
- the SSTs are equal;
- the SDs are equal, where "no SD" equals only "no SD";
- the entry has no SUPI, or the SUPIs are equal.

When several entries match a new session, the oldest entry decides the reject cause and back-off.

## 7. Flows

### 7.1 Drop, mode `graceful`

1. The handler validates the body and returns `400` on the first error.
2. The handler adds the entry to the drop list, or returns `409`.
3. The handler walks `smContextPool` with `Range`. For each matching session it takes `smContext.SMLock`.
4. If the session state is `Active`, `ModificationPending` or `PFCPModification` (the same set that `releaseAllResourcesOfUPF()` uses), the handler calls `requestAMFToReleasePDUResources(smContext, releaseCause, backoff)`. It then runs the same follow-up steps as `releaseAllResourcesOfUPF()`: `SendReleaseNotification()` when needed, then `RemoveSMContextFromAllNF()`. Any other state goes into `skipped`.
5. The handler returns `201` with `affected` and `skipped`.

When the UE is CM-IDLE (no radio connection), `requestAMFToReleasePDUResources()` already leaves out the N2 part, and the AMF decides whether to page the UE.

### 7.2 Reject while dropped

1. The UE sends a PDU Session Establishment Request. The AMF forwards it to the SMF as `POST /sm-contexts`.
2. `HandlePDUSessionSMContextCreate()` runs as today up to the end of `HandlePDUSessionEstablishmentRequest()`.
3. The reject check looks for a matching entry whose mode returns true from `RejectOnCreate()`.
4. On a match, the SMF calls `makeEstRejectResAndReleaseSMContext()` with `rejectCause` and the back-off value, and returns.

### 7.3 Restore

1. `DELETE /pdu-drop/:dropId` finds the entry, or returns `404`.
2. The handler runs the mode's `Restore()`, removes the entry, and returns `204`.

## 8. Comment and log tags

Every new comment line and log message carries `#WNC PDU-DROP/<SUB-TOPIC>`. A Go comment reads `// #WNC PDU-DROP/REJECT` on its own line above the code. A log message reads `"#WNC PDU-DROP/REJECT rejecting supi=%s dnn=%s"`.

Sub-topics shared by every mode do not carry a mode name. Sub-topics for one mode start with the mode name, so later steps add sub-topics without renaming existing ones.

| Sub-topic | Used for | Step |
|---|---|---|
| `CONFIG` | Reading `pduDrop` and registering routes | 1 |
| `API` | Request parsing, validation and responses | 1 |
| `REGISTRY` | Adding, matching and removing drop entries | 1 |
| `REJECT` | Rejecting a new PDU session that matches an entry | 1 |
| `RESTORE` | Removing an entry, for every mode | 1 |
| `BACKOFF` | GPRS timer 3 encoding | 1 |
| `GRACEFUL-RELEASE` | Release Command and N2 release for `graceful` | 1 |
| `BLACKHOLE-FAR` | Setting FARs to `DROP` | 2 |
| `BLACKHOLE-RESTORE` | Setting FARs back to `FORW` | 2 |
| `SILENT-DELETE` | Removing the session without signaling | 3 |
| `WEBCONSOLE` | The webconsole page and its backend calls | 4 |

## 9. Testing

### 9.1 Unit tests

- `internal/context/pdu_drop_test.go`: matching with and without SUPI, with and without SD, the oldest-entry rule, the duplicate-selector `409` case, and removal.
- `internal/context/gsm_build_test.go`: build a Reject and a Release Command with back-off, decode the bytes with the `nas` library, and check the cause and IEI `0x37`. Build both without back-off and check that the IE is absent.
- GPRS timer 3 encoding: 0, 2, 3 (rounds up to 4), 62, 63 (rounds up to 90), 1800 and 3600 seconds.

### 9.2 Live test on the cn host with `skipOAuth: true`

1. Bring up the UE with its 3 PDU sessions.
2. Drop one session:
   ```
   curl -s -X POST http://127.0.0.2:8000/nsmf-oam/v1/pdu-drop -H 'Content-Type: application/json' -d '{"mode":"graceful","dnn":"internet","snssai":{"sst":1,"sd":"000001"},"supi":"imsi-466110000000548"}'
   ```
3. Check that the UE interface for that session goes down, that the UE's retries get a Reject with cause 26 (in QXDM, Qualcomm's modem log tool, and in the SMF log under `#WNC PDU-DROP/REJECT`), and that the other 2 sessions keep working.
4. Restore:
   ```
   curl -s -X DELETE http://127.0.0.2:8000/nsmf-oam/v1/pdu-drop/1
   ```
5. Check that the UE re-establishes the session and gets an IP address on that interface again.

### 9.3 Live test with `skipOAuth: false`

The NRF issues a token only for a registered NF instance whose certificate file `cert/<nftype>_<nfInstanceId>.pem` exists (`NFs/nrf/internal/sbi/processor/access_token.go`). The caller therefore borrows the AMF's instance ID. The NRF address below comes from `config/nrfcfg.yaml`. Each token expires, so the caller fetches a new token for every call.

```
AMF_ID=$(ls cert/amf_*.pem | sed 's/.*amf_\(.*\)\.pem/\1/')
TOKEN=$(curl -s -X POST http://<nrf-sbi-addr>:8000/oauth2/token -d "grant_type=client_credentials&nfInstanceId=$AMF_ID&nfType=AMF&targetNfType=SMF&scope=nsmf-oam" | jq -r .access_token)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.2:8000/nsmf-oam/v1/pdu-drop
```

These commands were derived from the NRF source and have not been run on the cn host yet.

## 10. Out of scope

- Drop entries are kept only in SMF memory. Restarting the SMF clears every entry.
- The drop entry does not expire on its own. Only `DELETE` removes it.
- Step 1 does not change the PCF. Step 1 originally left the AMF and the UPF unchanged too, but the fix for live test10 changed both: the AMF log names the 5GSM cause of every forwarded SMF reject, and the UPF's `RemoteSess` skips freed session slots. The ISSUE doc in section 11 explains both changes.

## 11. Related

- `2026-10-22_wnc_FINDING_ue_pdu_session_retry_NAMELY_3gpp_allows_ue_stops_retrying_when_no_backoff_5x3s_VS_backoff_t3396_60s_3x_VS_no_answer_t3580_16s.md` — how the test UE retried during the step 1 live tests, and why TS 24.501 allows the UE to stop retrying.
- `2026-10-28_wnc_ISSUE_pdu_session_still_rejected_after_delete_pdu_drop_through_API_DUE_TO_upf_crash_on_orphan_session_from_graceful_drop.md` — the graceful drop sent no PFCP Session Deletion, and the orphan sessions it left crashed the UPF in live test10. The fix changes the SMF, the UPF and the AMF, and `## 10. Out of scope` was updated to say so.
