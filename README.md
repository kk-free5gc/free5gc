<p align="center">
<a href="https://free5gc.org"><img width="40%" src="https://forum.free5gc.org/uploads/default/original/1X/324695bfc6481bd556c11018f2834086cf5ec645.png" alt="free5GC"/></a>
</p>

<p align="center">
<a href="https://github.com/free5gc/free5gc/releases"><img src="https://img.shields.io/github/v/release/free5gc/free5gc?color=orange" alt="Release"/></a>
<a href="https://github.com/free5gc/free5gc/blob/master/LICENSE.txt"><img src="https://img.shields.io/github/license/free5gc/free5gc?color=blue" alt="License"/></a>
<a href="https://forum.free5gc.org"><img src="https://img.shields.io/discourse/topics?server=https%3A%2F%2Fforum.free5gc.org&color=lightblue" alt="Forum"/></a>
<a href="https://www.codefactor.io/repository/github/free5gc/free5gc"><img src="https://www.codefactor.io/repository/github/free5gc/free5gc/badge" alt="CodeFactor" /></a>
<a href="https://goreportcard.com/report/github.com/free5gc/free5gc"><img src="https://goreportcard.com/badge/github.com/free5gc/free5gc" alt="Go Report Card" /></a>
<a href="https://github.com/free5gc/free5gc/pulls"><img src="https://img.shields.io/badge/PRs-Welcome-brightgreen" alt="PRs Welcome"/></a>
<a href="https://www.bestpractices.dev/projects/9435"><img src="https://www.bestpractices.dev/projects/9435/badge"></a>
</p>

## What is free5GC

The free5GC (a Linux Foundation project) is an open-source project for 5th generation (5G) mobile core networks. The ultimate goal of this project is to implement the 5G core network (5GC) defined in 3GPP Release 15 (R15) and beyond.

For more information, please refer to [free5GC official site](https://free5gc.org/).

## Documentation

For document, please refer to [free5gc.org/guide/](https://free5gc.org/guide/).

## Discussion

For questions and support please use the [official forum](https://forum.free5gc.org). The issue list of this repo is exclusively for bug reports and feature requests.

## Contributing

We welcome you for contribution via [GitHub Pull Request](https://github.com/free5gc/free5gc/pulls).

## Release Note

Detailed changes for each release are documented in the release notes. Detailed changes for each release are documented in the [release notes](https://github.com/free5gc/free5gc/releases).

## License

free5GC is now under [Apache 2.0](https://github.com/free5gc/free5gc/blob/master/LICENSE.txt) license.

## After clone:
```bash
git submodule update --init --recursive --checkout
./scripts/install-guards.sh
```

## ⚠️ WNC: IMPORTANT - go-gtp5gnl Configuration Required

**Before building free5GC, you must configure the go-gtp5gnl library with system-specific kernel parameters.**

### Quick Setup (Required on Each System)

```bash
# 1. Navigate to go-gtp5gnl directory
cd ../go-gtp5gnl

# 2. Generate system-specific configuration
./scripts/detect_kernel_params.sh > go-gtp5gnl.yaml

# 3. Verify configuration
./scripts/detect_kernel_params.sh --verify

# 4. Return to free5gc directory
cd ../free5gc

# 5. Build free5GC
make nfs
```

### Why This Is Required

go-gtp5gnl is used by the UPF (User Plane Function) to communicate with the gtp5g kernel module via netlink. The netlink message sizes depend on kernel-specific parameters that vary by system:

- **PAGE_SIZE**: System page size (4KB, 8KB, 16KB, or 64KB)
- **CONFIG_MAX_SKB_FRAGS**: Kernel SKB fragment configuration (16, 17, 18, etc.)
- **SKB_OVERHEAD**: Socket buffer overhead calculation

**Using incorrect values causes:**
- ❌ Netlink communication failures (EMSGSIZE errors)
- ❌ UPF unable to program gtp5g rules
- ❌ Data plane failures (no UE traffic forwarding)

### For More Details

See the go-gtp5gnl configuration documentation:
- **Quick Guide**: `../go-gtp5gnl/README.md`
- **Detailed Instructions**: `../go-gtp5gnl/CONFIG.md`

**Note**: Configuration must be regenerated on each deployment target system with different kernel versions or architectures.

## ⚠️ WNC: PFCP vs Netlink Trigger Bitmaps (three formats!)

Router Solicitation reporting carries the same “Eveth” concept through **three different encodings**:

1. **gtp5g netlink USAReport bitmap** – 32 bits (kernel → go-gtp5gnl). Eveth is bit 15 (`0x00008000`).  
   - `go-gtp5gnl/attr_report.go` must decode this as little-endian so `r.USARTrigger == 0x00008000`.  
   - `UsageReportTrigger.SetReportingTrigger()` switches on `USAR_TRIG_*` (the kernel bit positions declared at the top of `free5gc/NFs/upf/internal/report/report.go`) and sets internal `RPT_TRIG_*` (the PFCP flags in the same file).  
   - Logging tip: `[go-gtp5gnl] URR 7 raw trigger bytes … → LE=0x00008000`.

2. **PFCP ReportingTriggers IE** (TS 29.244, Create/Update URR) – 2/3 bytes. Eveth lives at bit 12 (`0x1000`), i.e. bit 5 (`0x10`) of octet 6.  
   - `buildUrrAttrs()` must serialize `rptTrig.MarshalReportingTriggersIE()` (see the comment block in `free5gc/NFs/upf/internal/report/report.go` that maps `RPT_TRIG_*` to octets) and append `URR_EVENT_ID/THRESHOLD` when `rptTrig.EVETH() == true`.  
   - Log the octets before sending: `URR %d PFCP ReportingTriggers octets=%02x%02x (expect oct6 bit 0x10 for Eveth)`.

3. **PFCP UsageReportTrigger IE** (Session Report Request → SMF) – 3 bytes. Eveth is bit 8 (`0x80`) of octet 6.  
   - `UsageReportTrigger.IE()` must map `RPT_TRIG_*` to the TS 29.244 layout and set `buf[1] |= 0x80`.  
   - Log what you send: `[UPF][PFCP] UsageReportTrigger flags=… → octets [%02x %02x %02x] (expect oct6 bit 0x80)`.  
   - On the SMF side log the decoded octets too, so if Eveth is still false you see the mismatch immediately.  
   - Reference: go-pfcp `HasEVETH()`/`UsageReportTrigger()` logic (Eveth uses `has8thBit(v[1])` for Session Report Request). The bit layout comments in `UsageReportTrigger.IE()` show every octet and which `RPT_TRIG_*` bit sets it.

**Debug flow:** gtp5g (kernel) → go-gtp5gnl log → buffnetlink log → PFCP builder logs → SMF PFCP handler log. If any link shows the wrong bit, fix the serializer at that stage.

## Branches

- `baseline-v4.0.1` — Frozen snapshot at upstream tag **v4.0.1** (clean anchor; don’t merge into this).
- `main` — Tracks **upstream/main**; I periodically fast-forward and mirror it to this fork.
- `my-changes-v4.0.1` — My custom changes based on **v4.0.1** baseline.

## Logs

Remember, go-gtp5gnl logs appear in the UPF userspace logs, while gtp5g logs appear in dmesg.

## How to Manage MongoDB (Subscriber Data)

### Update a Subscriber's PDU Session Types in MongoDB

#### PDU Session Type Policy Layers

1. **SMF global capability** — currently fixed inside `NFs/smf/internal/context/context.go` (upstream default was `"IPv4"`, we set it to `"IPv4v6"` so IPv6-only DNNs are allowed).
2. **Subscriber WebGUI** — per UE/DNN `defaultSessionType` and `allowedSessionTypes` that will save in MongoDB.
3. **`smfcfg.yaml`** — per DNN fallback policy when Mongo lacks `pduSessionTypes` for that UE/S-NSSAI.

```bash
# 1. Log into the free5GC subscriber database
mongosh "mongodb://127.0.0.1:27017/free5gc"

# 2. Inspect UE imsi-466110000013068's SessionManagementSubscriptionData
db.getCollection("subscriptionData.provisionedData.smData").find({
  ueId: "imsi-466110000013068",
  servingPlmnId: "46611"
}).pretty();

# 3. Change that UE's V5GA01INTERNET DNN to request IPv6-only sessions
db.getCollection("subscriptionData.provisionedData.smData").updateOne(
  {
    ueId: "imsi-466110000013068",
    servingPlmnId: "46611",
    "singleNssai.sst": 1,
    "singleNssai.sd": "050601"
  },
  {
    $set: {
      "dnnConfigurations.vzwadmin.pduSessionTypes.defaultSessionType": "IPV6",
      "dnnConfigurations.vzwadmin.pduSessionTypes.allowedSessionTypes": [ "IPV6" ]
    }
  }
);
```

Successful updates return:

```json
{
  "acknowledged": true,
  "insertedId": null,
  "matchedCount": 1,
  "modifiedCount": 1,
  "upsertedCount": 0
}
```

### How to Dump the Whole Database into a Human-Readable JSON File

1. Create a full dump (binary BSON):

```sh
mongodump --uri "mongodb://127.0.0.1:27017/free5gc" --out ./free5gc_dump
```

2. Convert those BSON files to human-readable JSON:

- For a single file:
```sh
bsondump free5gc_dump/free5gc/registrationData.bson > registrationData.json
```

- Or all collections into one JSON file (append mode):
```sh
bash -c '> free5gc_all.json && for bson in free5gc_dump/free5gc/*.bson; do bsondump "$bson" >> free5gc_all.json; done'
```

## How to Write SDF Filter in UPF

Example: RS SDF filter - `rsFlowDesc`

**File:** `free5gc/NFs/smf/internal/context/datapath.go`

gtp5g normalizes `permit in` flows as downlink and `permit out` flows as uplink because "in"/"out" are from the UPF's perspective: "in" means packets entering the core (so they're downlink relative to UE), "out" means packets leaving toward the UE (uplink). That's why your RS PDR summary shows:

- `permit out ...`: Dir=UL
- `permit in ...`: Dir=DL

Since Router Solicitations are uplink (UE → ff02::2), use `permit out` so the kernel installs the rule as Dir=UL. The remaining problem is the address order: even with Dir=UL, the kernel is still showing IPv6-Src=ff02::2, IPv6-Dst=fe80::/64. To get a rule that actually matches fe80::/64 → ff02::2, flip the addresses in the string you send:

```go
rsFlowDesc := "permit out 58 from ff02::2 to fe80::/64"
```

When the kernel normalizes that UL filter, it will flip the endpoints and you'll end up with Dir=UL, Src=fe80::/64, Dst=ff02::2, so the actual RS packets will finally hit the PDR. The logs will then show URR 7 firing, the SMF will get EventID 26, and the Router Advertisement code will run.


## Interface

ip -6 addr add 2001:db8::5:5:5:2/64 dev br-ng label br-ng:NGU

## Note

PFCP (SMF → go-pfcp), userspace (go-pfcp → go-gtp5gnl), kernel netlink (go-gtp5gnl → gtp5g).
