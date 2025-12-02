# WNC: IPv4-Only Debug Notes (Dec 2025)


## Problem description

- Currently priority of allowedSessionTypes
  - 1st prority : allowedSessionTypes from subscriber profile
  - 2nd prority (if 1st priorty not exist): allowedSessionTypes in smfcfg.yaml

- Eventhough free5gc/config/smfcfg.yaml and Mongodb all shows V5GA01INTERNET only support IPv4, UE still got IPv6 address assigned in PDU session accept NAS message.

- Will not have this problem if we delete ipv6Pools and ipv6StaticPools in free5gc/config/smfcfg.yaml. However, free5gc should respect the free5gc/config/smfcfg.yaml and Mongodb settings.


## Current Observations

- `V5GA01INTERNET` subscriber record in Mongo (`subscriptionData.provisionedData.smData`, SUPI `imsi-466110000013068`, PLMN `46611`, S-NSSAI `1/050601`) is already configured with `pduSessionTypes.allowedSessionTypes = ["IPV4"]`.
- UE requests `IPv4v6`; SMF sends Nudm-SDM query (seen in `free5gc-16.log` entries around 2062) and receives the IPv4-only policy, yet the session still ends up dual-stack.
- Indicates the issue happens after policy retrieval (likely during downgrade logic or selection parameter handling), not due to missing Mongo data.

## Instrumentation Added

- `NFs/smf/internal/context/sm_context.go`
  - `WNC:` logs now show which policy source is used (subscriber vs `smfcfg.yaml`) and list `defaultSessionType` + `allowedSessionTypes`.
  - Additional `WNC:` logs print the requested vs selected session type (with NAS codes) after validation.
  - `AllocUeIP` and `findPSAandAllocUeIP` log the effective `SelectedPDUSessionType` so we can see if something flips back to IPv4v6 during allocation.

## Next Steps

1. Restart SMF so new logging is active.
2. Reproduce the PDU session; capture `free5gc-*.log` to confirm:
   - Policy source reported as `subscriber`.
   - Requested type `IPv4v6`, selected type `IPv4`.
   - Whether the allocation path still logs dual-stack; if so, we know `SelectedPDUSessionType` is being reset before allocation.
3. Based on logs, trace and patch the code path that reverts `SelectedPDUSessionType` (likely in downgrade branches or selection parameter sync).


## Reference : Example commands to retrive mongodb data.

```
# mongosh mongodb://localhost:27017/free5gc --eval 'db.getCollectionNames()'
[
  'policyData.ues.smData',
  'urilist',
  'subscriptionData.provisionedData.smfSelectionSubscriptionData',
  'policyData.ues.amData',
  'subscriptionData.identityData',
  'subscriptionData.contextData.amf3gppAccess',
  'NfProfile',
  'subscriptionData.authenticationData.webAuthenticationSubscription',
  'subscriptionData.provisionedData.smData',
  'tenantData',
  'policyData.ues.chargingData',
  'subscriptionData.authenticationData.authenticationSubscription',
  'userData',
  'subscriptionData.authenticationData.authenticationStatus',
  'subscriptionData.provisionedData.amData'
]
```

```
# mongosh mongodb://localhost:27017/free5gc \
    --eval 'db.getCollection("subscriptionData.provisionedData.smData").find(
      {"ueId": "imsi-466110000013068"},
      {_id:1, servingPlmnId:1, singleNssai:1, dnnConfigurations:1}
    )'
[
  {
    _id: ObjectId('691da9667eaf2006eeac799c'),
    servingPlmnId: '46611',
    singleNssai: { sst: 1, sd: '050601' },
    dnnConfigurations: {
      V5GA01INTERNET: {
        pduSessionTypes: { defaultSessionType: 'IPV4', allowedSessionTypes: [ 'IPV4' ] },
        sscModes: {
          allowedSscModes: [ 'SSC_MODE_2', 'SSC_MODE_3' ],
          defaultSscMode: 'SSC_MODE_1'
        },
        '5gQosProfile': {
          '5qi': 9,
          arp: { priorityLevel: 8, preemptCap: '', preemptVuln: '' },
          priorityLevel: 8
        },
        sessionAmbr: { uplink: '1000 Mbps', downlink: '1000 Mbps' }
      },
      ims: {
        pduSessionTypes: { defaultSessionType: 'IPV4', allowedSessionTypes: [ 'IPV4' ] },
        sscModes: {
          defaultSscMode: 'SSC_MODE_1',
          allowedSscModes: [ 'SSC_MODE_2', 'SSC_MODE_3' ]
        },
        '5gQosProfile': {
          arp: { priorityLevel: 8, preemptCap: '', preemptVuln: '' },
          priorityLevel: 8,
          '5qi': 9
        },
        sessionAmbr: { uplink: '1000 Mbps', downlink: '1000 Mbps' }
      },
      internet: {
        pduSessionTypes: { defaultSessionType: 'IPV4', allowedSessionTypes: [ 'IPV4' ] },
        sscModes: {
          defaultSscMode: 'SSC_MODE_1',
          allowedSscModes: [ 'SSC_MODE_2', 'SSC_MODE_3' ]
        },
        '5gQosProfile': {
          '5qi': 9,
          arp: { priorityLevel: 8, preemptCap: '', preemptVuln: '' },
          priorityLevel: 8
        },
        sessionAmbr: { uplink: '1000 Mbps', downlink: '1000 Mbps' }
      },
      vzwadmin: {
        '5gQosProfile': {
          arp: { priorityLevel: 8, preemptCap: '', preemptVuln: '' },
          priorityLevel: 8,
          '5qi': 9
        },
        sessionAmbr: { uplink: '1000 Mbps', downlink: '1000 Mbps' },
        pduSessionTypes: { defaultSessionType: 'IPV4', allowedSessionTypes: [ 'IPV4' ] },
        sscModes: {
          defaultSscMode: 'SSC_MODE_1',
          allowedSscModes: [ 'SSC_MODE_2', 'SSC_MODE_3' ]
        }
      }
    }
  }
]
```

*Saved for continuation tomorrow.* 
