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

**Before building Free5GC, you must configure the go-gtp5gnl library with system-specific kernel parameters.**

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

# 5. Build Free5GC
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

## Branches

- `baseline-v4.0.1` — Frozen snapshot at upstream tag **v4.0.1** (clean anchor; don’t merge into this).
- `main` — Tracks **upstream/main**; I periodically fast-forward and mirror it to this fork.
- `my-changes-v4.0.1` — My custom changes based on **v4.0.1** baseline.

## Logs

Remember, go-gtp5gnl logs appear in the UPF userspace logs, while gtp5g logs appear in dmesg.