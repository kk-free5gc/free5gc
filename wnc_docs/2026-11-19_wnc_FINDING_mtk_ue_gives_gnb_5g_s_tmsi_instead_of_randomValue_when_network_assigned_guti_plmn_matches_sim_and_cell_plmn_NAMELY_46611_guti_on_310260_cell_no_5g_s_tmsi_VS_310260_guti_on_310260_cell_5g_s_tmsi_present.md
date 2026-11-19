# FINDING: the MTK test UE gives the gNB its 5G-S-TMSI instead of randomValue when the PLMN of the 5G-GUTI from the network matches the SIM and cell PLMN

| Field | Value |
|---|---|
| Date | 2026-11-19 |
| Repo | free5gc (parent repo, with the `NFs/amf` submodule). The UE side was observed on the MTK test UE `imsi-310260000013069`; **Not recorded:** the UE model and modem firmware version were not written down. |
| Tree | `/home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc` |
| Branch | `my-changes-v4.0.1` (parent), `my-amf-changes-v1.3.2` (`NFs/amf`) |
| Commit | `60ba28b` (`NFs/amf`, the 5G-GUTI PLMN fix that caused the change) |
| Symptom | Before the 5G-GUTI PLMN fix, no InitialUEMessage from the MTK test UE carried the NGAP IE "5G-S-TMSI". Stock free5gc then answers a Service Request, a mobility or periodic registration updating and a Deregistration Request with ErrorIndication and UEContextReleaseCommand, so the gNB released the UE about 120 ms after RRC setup. |
| Scope | Which InitialUEMessages from the MTK test UE carry the NGAP IE "5G-S-TMSI", before and after the AMF gave the UE a 5G-GUTI with the PLMN of the cell. It also covers one RRCSetupRequest after the fix, decoded from the CU log. It does not cover other UE models. |
| Fix | **Not applicable.** No fix was made for this finding. The change came from the 5G-GUTI PLMN fix (`#WNC GUTI-PLMN/REALLOCATE` in `NFs/amf/internal/context/context.go`). |
| Rounds | **Not applicable.** No diagnose-and-fix cycle. |
| Status | **Seen in one live run, RRC confirmed.** test19 on 2026-11-19, 14:16 to 16:25, with the AMF build that holds the 5G-GUTI PLMN fix. The CU log shows an RRCSetupRequest with `ue-Identity: ng-5G-S-TMSI-Part1` for the 5G-GUTI `310260cafe0300000002` (§2). Not confirmed: a second run, and why the MTK modem makes this choice. |
| Prior art | The comment on `nasIdentityFallbackIfNgapSTmsiMissing` in `config/amfcfg.yaml`, which said until this finding that the MTK UE always sends `randomValue`. |

---

## SECTION 0. The summary — what the topic is, in plain words, before any detail

The MTK test UE has a T-Mobile SIM (PLMN 310-260) and camps on a cell that broadcasts 310-260. Until 2026-11-19, the AMF gave that UE a 5G-GUTI with PLMN 466-11, the PLMN of the AMF's first served GUAMI. While the UE held that 466-11 5G-GUTI, it put `randomValue` into RRCSetupRequest. The gNB therefore had no 5G-S-TMSI to copy, and not one of 3103 InitialUEMessages in 16 recorded runs carried the NGAP IE "5G-S-TMSI".

The 5G-GUTI PLMN fix makes the AMF give that UE a 310-260 5G-GUTI (`310260cafe03…`). In the first live run with the fix, 6 of 7 InitialUEMessages carried the NGAP IE "5G-S-TMSI". The AMF found the UE by that IE, and the NAS identity fallback (`#WNC STMSI-FALLBACK`) never ran. The CU log confirms the cause on the radio side: RRCSetupRequest now carries `ue-Identity: ng-5G-S-TMSI-Part1` instead of `randomValue`.

TS 24.501 does not require this change of behaviour. The rule in clause 5.3.1.1 depends on the registration area, and the registration area held the cell's TAI in both cases. The behaviour is a choice made by the MTK modem.

## SECTION 1. How it works — the mechanism, in enough detail to reason about the topic

### The identities involved

- **5G-GUTI** is the temporary identity the AMF gives the UE in Registration Accept. It is PLMN (MCC + MNC) + AMF ID + 5G-TMSI. This AMF writes it as a string, for example `46611cafe0000000002` (466-11, AMF ID `cafe00`, 5G-TMSI `00000002`) or `310260cafe0300000002` (310-260, AMF ID `cafe03`).
- **5G-S-TMSI** is the short form of the 5G-GUTI without the PLMN and without the AMF Region ID. It is AMF Set ID + AMF Pointer + 5G-TMSI, for example `fe0300000002`.
- **RRCSetupRequest** field `ue-Identity` (TS 38.331) is either `ng-5G-S-TMSI-Part1` (the low 39 bits of the 5G-S-TMSI) or `randomValue`. The UE uses `ng-5G-S-TMSI-Part1` only when its NAS layer hands RRC a 5G-S-TMSI.
- **NGAP IE "5G-S-TMSI"** (IE id 26) is the IE in InitialUEMessage that the gNB fills from the 5G-S-TMSI the UE gave in RRC. When the UE sent `randomValue`, the gNB has nothing to copy and leaves the IE out.

### What TS 24.501 says the UE NAS must hand to RRC

TS 24.501 clause 5.3.1.1 lists when the UE NAS gives the lower layers the 5G-S-TMSI. For 3GPP access, when the UE holds a 5G-GUTI and no special case applies:

- If the tracking area of the current cell is in the registration area, the UE NAS gives the 5G-S-TMSI.
- If the tracking area of the current cell is not in the registration area, the UE NAS gives the GUAMI of the 5G-GUTI and not the 5G-S-TMSI.

The registration area is the TAI list in Registration Accept. This AMF builds it in `AllocateRegistrationArea` (`NFs/amf/internal/context/context.go`) from exactly one TAI: `ue.Tai`, the TAI the gNB reported, 310-260 / TAC 000001. The 5G-GUTI PLMN fix did not change that function. By the clause 5.3.1.1 rule, the UE should have given the 5G-S-TMSI with the 466-11 5G-GUTI too.

### What the MTK test UE did instead

| 5G-GUTI the UE held | Cell PLMN | RRCSetupRequest `ue-Identity` (CU log) | NGAP IE "5G-S-TMSI" in InitialUEMessage |
|---|---|---|---|
| 466-11, AMF ID `cafe00` (every run before 2026-11-19, except test2, which used 001-01) | 310-260 | `randomValue (1)` | Never present, in 3099 messages |
| 310-260, AMF ID `cafe03` (first run with the 5G-GUTI PLMN fix) | 310-260 | `ng-5G-S-TMSI-Part1 (0)` | Present in 6 of 7 messages |

The likely reason is that the MTK modem treats a 5G-GUTI from a PLMN other than the selected PLMN as unusable for RRC, and falls back to `randomValue`. This reason is an inference. The modem code was not read, and no modem log was checked. In this lab the SIM PLMN and the cell PLMN are both 310-260, so the logs cannot show which of the two the modem compares with the PLMN of the 5G-GUTI.

### Why the UE held a 466-11 5G-GUTI

`NewAmfUe` allocates the first 5G-GUTI before the AMF has decoded any identity, so `SelectServedGuami` finds no PLMN and falls back to `ServedGuamiList[0]`. In `config/amfcfg.yaml`, `ServedGuamiList[0]` is 466-11 / `cafe00`. Stock free5gc sends that 5G-GUTI in Registration Accept unchanged. The 5G-GUTI PLMN fix (`AlignGutiWithServingPlmn`) replaces it before each Registration Accept with a 5G-GUTI from the served GUAMI of the TAI PLMN, here 310-260 / `cafe03`.

### The one message in test19 without the IE

The first InitialUEMessage of test19 (14:26:03) is an Initial Registration with ngKSI 7, which means the UE had no NAS security context. Its NAS 5G-GUTI is already `310260cafe0300000002`, which an earlier run with the fix had given the UE. That run is not in `my_logs/`. This message carried no NGAP IE "5G-S-TMSI". The two later Initial Registrations of test19 (ngKSI 0 and ngKSI 1) did carry it. §8 lists this as an open question.

## SECTION 2. Evidence — how the mechanism was established: which tree was read, and what was seen on a unit

### Every recorded run, by the 5G-GUTI the UE sent

A Python script read every AMF `Packet content:` hex dump of an InitialUEMessage in `my_logs/*/free5gc/log/*/free5gc.log` (trace level). For each message it decoded the NAS-PDU (IE id 38): the message type, the registration type and ngKSI, and the PLMN and AMF ID of the NAS 5G-GUTI. It also checked whether the NGAP IE "5G-S-TMSI" (IE id 26) was present. "S-TMSI in NAS" means a Service Request, whose NAS identity is a 5G-S-TMSI and so holds no PLMN.

| Run | NAS identity | NAS message | NGAP IE "5G-S-TMSI" | Count |
|---|---|---|---|---|
| test2 | 5G-GUTI 001-01 `800101` | Initial Registration, ngKSI 7 | absent | 4 |
| test-3 | 5G-S-TMSI in NAS | Service Request | absent | 3020 |
| test-3 | 5G-GUTI 466-11 `cafe00` | Initial Registration | absent | 3 |
| test4 to test14 | 5G-S-TMSI in NAS | Service Request | absent | 42 |
| test4 to test14 | 5G-GUTI 466-11 `cafe00` | Initial Registration, periodic registration updating | absent | 17 |
| test15 | 5G-GUTI 466-11 `cafe00` | mobility registration updating, ngKSI 7 | absent | 5 |
| test16, test17 | 5G-S-TMSI in NAS | Service Request | absent | 3 |
| test16, test17 | 5G-GUTI 466-11 `cafe00` | Initial Registration, Deregistration Request | absent | 4 |
| test18 | 5G-GUTI 466-11 `cafe00` | periodic registration updating, ngKSI 2 | absent | 5 |
| **test19** | 5G-S-TMSI in NAS | Service Request | **present** | 3 |
| **test19** | 5G-GUTI 310-260 `cafe03` | Deregistration Request | **present** | 1 |
| **test19** | 5G-GUTI 310-260 `cafe03` | Initial Registration, ngKSI 0 and ngKSI 1 | **present** | 2 |
| test19 | 5G-GUTI 310-260 `cafe03` | Initial Registration, ngKSI 7 | absent | 1 |

The AMF console logs agree. The stock AMF line `Find 5G-S-TMSI [...] in InitialUEMessage` (`NFs/amf/internal/ngap/handler.go`, present since upstream commit `7907d3c`) appears 0 times in every console log before test19, and 6 times in test19. test12 has no console log, so only the hex dumps above cover test12.

### The two packets that show the change

The test18 InitialUEMessage at 16:23:00 on 2026-11-10 carries no IE 26. Its NAS-PDU holds a periodic registration updating (`7e 00 41 23`) with 5G-GUTI `f2 64 f6 11 ca fe 00 00 00 00 02` = 466-11, `cafe00`, 5G-TMSI `00000002`. The last visited registered TAI (`52 13 00 62 00 00 01`) is 310-260 / TAC 000001.

The test19 InitialUEMessage at 14:26:31 on 2026-11-19 carries IE 26, which the AMF logged as `Find 5G-S-TMSI ["fe0300000002"] in InitialUEMessage`. The UE had received the 5G-GUTI `310260cafe0300000002` 26 seconds earlier, in the Registration Accept after `#WNC GUTI-PLMN/REALLOCATE 5G-GUTI "46611cafe0000000001" -> "310260cafe0300000002"`.

### The RRCSetupRequest in the CU log

The tester decoded one F1AP InitialULRRCMessageTransfer from the CU log with Wireshark. F1AP carries the RRC message from the DU to the CU. The time of that message was not recorded with the decode. The relevant fields are:

```
NRCGI
    pLMN-Identity: 132006
        Mobile Country Code (MCC): United States (310)
        Mobile Network Code (MNC): T-Mobile USA (260)
RRCContainer: 006000000048
    rrcSetupRequest
        ue-Identity: ng-5G-S-TMSI-Part1 (0)
            ng-5G-S-TMSI-Part1: 0600000004 [bit length 39, 1 LSB pad bits, ... decimal value 12884901890]
        establishmentCause: mo-Data (4)
```

- `ue-Identity: ng-5G-S-TMSI-Part1 (0)` is the RRC choice that the UE did not make while it held a 466-11 5G-GUTI. The CU log then showed `nr-rrc.ue_Identity == 1`, which is `randomValue`.
- `ng-5G-S-TMSI-Part1` is the low 39 bits of the 48-bit 5G-S-TMSI. Wireshark shows the 39 bits left-aligned in 5 bytes (`0600000004`). After the 1 pad bit is removed, the value is `0x300000002` (decimal 12884901890). The low 32 bits are the 5G-TMSI `00000002`. The 7 bits above them are `0000011`, the low 7 bits of AMF Set ID and AMF Pointer `fe03`, and `fe03` belongs to AMF ID `cafe03`. The value therefore matches the 5G-S-TMSI `fe0300000002` of the 5G-GUTI `310260cafe0300000002`. The remaining 9 bits (Part2) travel later, in RRCSetupComplete.
- `establishmentCause: mo-Data` means the UE set up RRC to send uplink data, which fits a Service Request. The test19 Service Request at 14:26:31 used `fe0300000002`. The run before test19, which is not in `my_logs/`, gave the UE the same 5G-GUTI, so the decode may come from that run instead.
- `pLMN-Identity: 132006` decodes to 310-260, so the cell PLMN is confirmed as 310-260.

### Log files

- Before: `my_logs/test18-verify-rrc-release-fix/free5gc/log/console_free5gc.log` and `.../log/20261110_162137/free5gc.log`
- After: `my_logs/test19-verify-rrc-release-fix/free5gc/log/console_free5gc.log` and `.../log/20261119_141625/free5gc.log`

## SECTION 3. Check it yourself — what to run on your own unit today, and what the commands should print

1. Count the InitialUEMessages that carried the NGAP IE "5G-S-TMSI":

   ```
   grep -cE 'Find 5G-S-TMSI' log/console_free5gc.log
   grep -cE 'Handle InitialUEMessage' log/console_free5gc.log
   ```

   With the 5G-GUTI PLMN fix, the first count should be close to the second. Only an Initial Registration from a UE without a 5G-GUTI, or with ngKSI 7, should be missing.

2. Confirm the AMF gave the UE a 310-260 5G-GUTI:

   ```
   grep -E '#WNC GUTI-PLMN/REALLOCATE' log/console_free5gc.log
   ```

   It should print `-> "310260cafe03…"` for each Initial Registration.

3. Confirm the NAS identity fallback did not run:

   ```
   grep -cE '#WNC STMSI-FALLBACK' log/console_free5gc.log
   ```

   It should print 0 while the UE holds a 310-260 5G-GUTI.

4. On the CU, filter RRCSetupRequest with `nr-rrc.ue_Identity == 0` (`ng-5G-S-TMSI-Part1`). Before the fix, the CU log showed `nr-rrc.ue_Identity == 1` (`randomValue`). **Done for one message:** §2 shows an RRCSetupRequest with `ng-5G-S-TMSI-Part1` for the 5G-GUTI `310260cafe0300000002`. To match Part1 to a 5G-GUTI, drop the pad bit, and compare the low 32 bits with the 5G-TMSI at the end of the 5G-GUTI.

## SECTION 4. Effect on your plan — does what you were about to do still work?

- The NAS identity fallback (`nasIdentityFallbackIfNgapSTmsiMissing`) stays useful, but as a safety net, not as the normal path. It still covers a UE that holds an old 466-11 5G-GUTI, for example after the AMF build changes, and a UE that sends `randomValue` for another reason.
- `trustGutiInNasIdentityFallback` and `requireMacForNasIdentityFallbackDeregistration` matter only when the fallback runs, so with a 310-260 5G-GUTI they are not used.
- The release about 120 ms after RRC setup, first seen in test15, came from the 466-11 5G-GUTI. The fallback treated the symptom, and the 5G-GUTI PLMN fix removed the cause.
- The UDM `INVALID_GUAMI` on UECM deregistration and the PCF `CONTEXT_NOT_FOUND` on AM policy delete still happen in test19. This finding does not change them.

## SECTION 5. Alternatives — other ways to reach the same goal, when the planned route is ruled out

- **Put 310-260 first in `servedGuamiList`.** Then `ServedGuamiList[0]` is 310-260, and a 310-260 SIM gets a 310-260 5G-GUTI even without the 5G-GUTI PLMN fix. A SIM of another PLMN (466-11, 001-01, 311-480) would then get a 310-260 5G-GUTI, and could show the same `randomValue` behaviour.
- **Rely on the NAS identity fallback alone.** This works for Service Requests and Deregistration Requests. For a mobility or periodic registration updating it needs `trustGutiInNasIdentityFallback: true`, and the MTK UE still sends `randomValue`.

## SECTION 6. The reusable rules — what to carry from this finding to similar situations

- When the NGAP IE "5G-S-TMSI" is missing, decode the NAS 5G-GUTI before blaming the UE. If its PLMN differs from the cell PLMN, fix the 5G-GUTI first.
- Give each UE a 5G-GUTI from the served GUAMI of the PLMN of its cell, not from `ServedGuamiList[0]`.
- A UE can follow a stricter rule than TS 24.501 requires. Check what the UE actually sends rather than predicting it from the specification.

## SECTION 7. Traps — what looks true and is not; check each claim before trusting it

- **"The MTK UE always sends `randomValue`" is wrong.** The CU log showed `nr-rrc.ue_Identity == 1` only while the UE held a 466-11 5G-GUTI. Until this finding, `config/amfcfg.yaml` stated it as a fixed property of the UE.
- **The old 5G-GUTI in the REALLOCATE log line is not the UE's 5G-GUTI.** `#WNC GUTI-PLMN/REALLOCATE 5G-GUTI "46611cafe0000000001" -> ...` shows the 5G-GUTI that `NewAmfUe` allocated in this AMF. The UE never received `46611cafe0000000001`. Decode the NAS-PDU to see the 5G-GUTI the UE sent.
- **The TS 24.501 rule does not predict this behaviour.** By clause 5.3.1.1, a cell TAI in the registration area means the 5G-S-TMSI should be given, and it was in the registration area in both cases.
- **`Find 5G-S-TMSI` is a stock log line, and `#WNC STMSI-FALLBACK` is not.** Count the stock line to see how often the IE was present. The `#WNC` line appears only when the IE is missing.

## SECTION 8. Limits — what this finding does not establish, and what would settle the open question

- **One run.** test19 is the only recorded run with the 5G-GUTI PLMN fix. A second run, preferably after a power cycle of the UE, would confirm it.
- **RRC confirmed for one message only.** One RRCSetupRequest from the CU log carries `ng-5G-S-TMSI-Part1` (§2). The time of that message was not recorded, so the message may come from test19 or from the unrecorded run before test19.
- **SIM PLMN or cell PLMN.** Both are 310-260 here, so the logs cannot show which of the two the modem compares with the PLMN of the 5G-GUTI. A cell that broadcasts another PLMN, with a 5G-GUTI of that PLMN, would separate the two.
- **Two things changed between test18 and test19.** The AMF build changed (5G-GUTI PLMN fix and the `findAmfUe` change for 5G-S-TMSI lookup), and `periodicRegistrationUpdating` was added to `nasIdentityFallbackIfNgapSTmsiMissing`. Neither change affects what the UE puts into RRCSetupRequest, except through the 5G-GUTI the UE receives. A direct check: give the UE a 466-11 5G-GUTI again, for example with a build without `AlignGutiWithServingPlmn`, and the IE should disappear again.
- **The exception at 14:26:03 is not explained.** That Initial Registration had ngKSI 7 and a 310-260 5G-GUTI, and carried no IE. The state of the UE before that message is not known, because the earlier run is not in `my_logs/`.
- **One UE model.** Other UEs may follow clause 5.3.1.1 more closely, and give the 5G-S-TMSI whatever the PLMN of the 5G-GUTI.

## SECTION 9. Revisions — update history, and what forced each change

| Date | Change | Reason |
|---|---|---|
| 2026-11-19 | First version | test19, the first live run with the 5G-GUTI PLMN fix, showed the NGAP IE "5G-S-TMSI" for the first time. |
| 2026-11-19 | Added the CU log decode (§2, §3 check 4, §8); renamed the doc to name `randomValue` and the SIM and cell PLMN | The tester supplied an RRCSetupRequest with `ng-5G-S-TMSI-Part1`; the old name did not say what the UE sends instead. |
| 2026-11-19 | Shortened the name to 227 bytes: PLMNs written as `46611` and `310260`, and `ngap` dropped from the NAMELY part | A 237-byte name broke the Edit tool, which saves through a temporary file with a suffix of up to 25 bytes; the `doc-format` skill now sets a 230-byte hard limit. The body still names the NGAP IE "5G-S-TMSI" in full. |

## SECTION 10. Related — other docs connected to this doc

- `config/amfcfg.yaml`, the comments on `nasIdentityFallbackIfNgapSTmsiMissing` and `trustGutiInNasIdentityFallback`, which were updated with this finding.
- `NFs/amf/internal/context/context.go`, the comment on `AlignGutiWithServingPlmn`.
