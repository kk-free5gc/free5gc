# Design: Config-gated "all subscribed S-NSSAI" in Registration Accept Allowed NSSAI

**Date:** 2026-07-21
**Component:** free5gc AMF
**Status:** Approved

## Problem

The Registration Accept NAS message currently advertises only a single slice in
the Allowed NSSAI IE (e.g. `EMBB_000001`), even when the subscriber (SIM) is
provisioned with multiple S-NSSAIs in the web console. Operators want the AMF to
be able to advertise **all** provisioned slices to the UE.

### Root cause

When the UE's Registration Request carries no Requested NSSAI (or none that
match the subscription), the AMF runs a fallback in
`NFs/amf/internal/gmm/handler.go` (`handleRequestedNssai`, lines ~1331-1342):

```go
if len(ue.AllowedNssai[anType]) == 0 {
    for _, snssai := range ue.SubscribedNssai {
        if snssai.DefaultIndication {                       // <-- the gate
            if amfSelf.InPlmnSupportList(*snssai.SubscribedSnssai) {
                allowedSnssai := models.AllowedSnssai{
                    AllowedSnssai: snssai.SubscribedSnssai,
                }
                ue.AllowedNssai[anType] = append(ue.AllowedNssai[anType], allowedSnssai)
            }
        }
    }
}
```

The `if snssai.DefaultIndication` filter keeps only the default-indicated slice,
which is why only `EMBB_000001` is returned.

### Data already available

`ue.SubscribedNssai` already contains the **complete** SIM slice set. It is
populated in `NFs/amf/internal/sbi/consumer/udm_service.go` (~298-317) from
UDM's `GetNSSAI` (Slice Selection Subscription Data):

- `nssai.Nssai.DefaultSingleNssais` -> `SubscribedSnssai{ DefaultIndication: true }`
- `nssai.Nssai.SingleNssais`        -> `SubscribedSnssai{ DefaultIndication: false }`

So no new fetch is required; we only need to relax the filter.

## Goals

- Provide a config option so the AMF can advertise all provisioned subscribed
  S-NSSAIs in the Allowed NSSAI of the Registration Accept.
- Preserve stock (3GPP-conservative) behavior by default.
- Shape the option so it can later extend to the "requested NSSAI present" case
  without changing the meaning of existing config values.

## Non-goals

- Any NSSF-driven slice selection path (`NSSelectionGetForRegistration`) — that
  populates `ue.AllowedNssai` from the NSSF response and is unaffected. The
  `allSubscribedAlways` augmentation only runs on the local (no-reroute) path.
- Changing the RejectedNSSAI / ConfiguredNSSAI IEs.

## Design

### Config: string mode enum

Instead of a bare boolean, add a string `allowedNssaiMode` to the AMF
`Configuration` struct (`NFs/amf/pkg/factory/config.go`). A growing vocabulary
means adding a value never changes what existing values mean.

| Value                  | Behavior                                                                                     | Status         |
|------------------------|----------------------------------------------------------------------------------------------|----------------|
| `""` / `default`       | Stock ("ask = allow"): Allowed NSSAI = Requested ∩ Subscribed ∩ supported. When no (matching) Requested NSSAI, only the default-indicated subscribed slice. | Implemented    |
| `allSubscribedNoReq`   | Fallback (no matching Requested NSSAI) advertises ALL subscribed slices supported by the AMF. | Implemented    |
| `allSubscribedAlways`  | Advertise ALL subscribed slices supported by the AMF, even when the UE requested a specific NSSAI. | Implemented    |

**Note (root cause of first attempt):** real UEs typically send a Requested
NSSAI, which makes `handleRequestedNssai` take the requested-NSSAI branch and
skip the fallback entirely. `allSubscribedNoReq` therefore has no effect for such
UEs; `allSubscribedAlways` is required to add the extra subscribed slices in that
case.

```go
// AllowedNssaiMode selects how the AMF populates Allowed NSSAI in the
// Registration Accept. See AllowAllSubscribedNssaiOnFallback /
// AllowAllSubscribedNssaiAlways.
AllowedNssaiMode string `yaml:"allowedNssaiMode,omitempty" valid:"in(default|allSubscribedNoReq|allSubscribedAlways),optional"`
```

`optional` lets an omitted field (empty string) pass validation and behave like
`default`, preserving existing deployments. A misspelled value fails at config
load rather than silently falling back.

### Config helpers (encapsulation)

Named constants plus helper methods keep raw string comparisons out of the
handler and make the future extension a one-line change:

```go
const (
    AllowedNssaiModeDefault             = "default"
    AllowedNssaiModeAllSubscribedNoReq  = "allSubscribedNoReq"
    AllowedNssaiModeAllSubscribedAlways = "allSubscribedAlways"
)

// AllowAllSubscribedNssaiOnFallback reports whether the no-Requested-NSSAI
// fallback should advertise every supported subscribed S-NSSAI (not just the
// default-indicated one). True for both allSubscribedNoReq and (future)
// allSubscribedAlways.
func (c *Configuration) AllowAllSubscribedNssaiOnFallback() bool {
    switch c.AllowedNssaiMode {
    case AllowedNssaiModeAllSubscribedNoReq, AllowedNssaiModeAllSubscribedAlways:
        return true
    default:
        return false
    }
}

// AllowAllSubscribedNssaiAlways reports whether all subscribed slices should be
// advertised even when a Requested NSSAI is present. Reserved for a future
// change; the requested-NSSAI path does not consult it yet.
func (c *Configuration) AllowAllSubscribedNssaiAlways() bool {
    return c.AllowedNssaiMode == AllowedNssaiModeAllSubscribedAlways
}
```

Both helpers are consumed: `AllowAllSubscribedNssaiOnFallback()` gates the
fallback loop, and `AllowAllSubscribedNssaiAlways()` gates a second block that
augments the requested-NSSAI result (see below).

### Fallback logic change

In `handleRequestedNssai` fallback block, gate the `DefaultIndication` check on
the helper. When enabled, include any subscribed slice supported by the AMF
regardless of `DefaultIndication`:

```go
if len(ue.AllowedNssai[anType]) == 0 {
    allowAll := factory.AmfConfig.Configuration.AllowAllSubscribedNssaiOnFallback()
    for _, snssai := range ue.SubscribedNssai {
        if allowAll || snssai.DefaultIndication {
            if amfSelf.InPlmnSupportList(*snssai.SubscribedSnssai) {
                allowedSnssai := models.AllowedSnssai{
                    AllowedSnssai: snssai.SubscribedSnssai,
                }
                ue.AllowedNssai[anType] = append(ue.AllowedNssai[anType], allowedSnssai)
            }
        }
    }
}
```

The `InPlmnSupportList` guard is retained so the AMF never advertises a slice it
cannot serve.

### Requested-NSSAI augmentation (allSubscribedAlways)

Real UEs send a Requested NSSAI, so the requested-NSSAI branch fills
`ue.AllowedNssai` and the fallback above is skipped. To advertise all subscribed
slices in that case, a second block runs after the fallback, gated by
`AllowAllSubscribedNssaiAlways()`. It appends every supported subscribed slice
not already present (dedup via `InAllowedNssai`):

```go
if factory.AmfConfig.Configuration.AllowAllSubscribedNssaiAlways() {
    added := 0
    for _, snssai := range ue.SubscribedNssai {
        if !amfSelf.InPlmnSupportList(*snssai.SubscribedSnssai) {
            continue
        }
        if ue.InAllowedNssai(*snssai.SubscribedSnssai, anType) {
            continue
        }
        ue.AllowedNssai[anType] = append(ue.AllowedNssai[anType], models.AllowedSnssai{
            AllowedSnssai: snssai.SubscribedSnssai,
        })
        added++
    }
    // [WNC] log added / total
}
```

### Config documentation

Add `allowedNssaiMode` (commented, default `default`) to `config/amfcfg.yaml`
with the value table above so operators can discover and toggle it.

## Data flow (unchanged upstream)

```
UDM GetNSSAI
  -> ue.SubscribedNssai  (default + non-default slices)
  -> handleRequestedNssai fallback  (filter relaxed by allowedNssaiMode)
  -> ue.AllowedNssai[anType]
  -> BuildRegistrationAccept AllowedNSSAI IE  (build.go:562-570)
  -> Registration Accept NAS message to UE
```

## Files changed

1. `NFs/amf/pkg/factory/config.go` — add `AllowedNssaiMode` field, mode
   constants, and the two helper methods.
2. `NFs/amf/internal/gmm/handler.go` — relax fallback filter via
   `AllowAllSubscribedNssaiOnFallback()`.
3. `config/amfcfg.yaml` — document the new option.

## Testing

- **Build:** `make amf` compiles cleanly.
- **Unit (optional):** table test for `AllowAllSubscribedNssaiOnFallback()` /
  `AllowAllSubscribedNssaiAlways()` across `""`, `default`,
  `allSubscribedNoReq`, `allSubscribedAlways`.
- **Manual / integration:**
  1. Provision a subscriber in the web console with a default S-NSSAI plus at
     least one additional S-NSSAI.
  2. Register a UE that sends no Requested NSSAI (or one not matching the
     subscription) so the fallback runs.
  3. With `allowedNssaiMode: allSubscribedNoReq`, capture the Registration
     Accept and confirm the Allowed NSSAI IE lists **all** provisioned slices.
  4. With the option absent / `default`, confirm only the default-indicated
     slice appears (regression check for stock behavior).

## Risks

- Advertising more slices than a UE expects is generally benign, but a UE could
  attempt PDU sessions on newly-allowed slices; ensure SMF/UPF are provisioned
  for every advertised slice before enabling in production.
- `allSubscribedAlways` is accepted by config validation but currently behaves
  like `allSubscribedNoReq` (fallback-only). This is documented to avoid the
  surprise of selecting it and seeing no effect on the requested-NSSAI path.
