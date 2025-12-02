# SMF IPv6 Configuration Guide

This document explains how the SMF interprets the IPv6-related settings in `config/smfcfg.yaml`. It focuses on how dynamic pools, static pools, and per-UE static bindings interact when allocating addresses and delegated prefixes.

## Overview of IPv6 Address Sources

The SMF can assign a UE IPv6 address from three sources, evaluated in this order:

1. **Static assignments (`ipv6StaticAssignments`)** — Per-SUPI overrides that return an explicit address and prefix length.
2. **Static pools (`ipv6StaticPools`)** — Pre-reserved subnets for static bindings, typically paired with `UseStaticIPv6` subscribers.
3. **Dynamic pools (`ipv6Pools`)** — General-purpose pools used when no static binding applies.

Each pool stores both the configured network prefix and the range of Interface Identifiers (IIDs) that may be allocated. The IID is always preserved in full (64 bits) so static bindings with non-zero bits in positions 64–95 continue to work.

## `ipv6Pools`

```yaml
ipv6Pools:
  - prefix: 2001:db8:0111::/48
    uePrefixLength: 64
    iidAllocation: random
    raProfile: default
```

- **`prefix`** — The network delegated to the SMF for dynamic allocations. Prefix lengths from `/1` to `/128` are accepted, but a `/64` or shorter (larger network) is recommended so the SMF can assign unique 64-bit IIDs per UE.
- **`uePrefixLength`** — The prefix length advertised to the UE via Router Advertisements (if NAS-triggered RA is enabled) and encoded into PFCP `UE IP Address` when the SMF delegates a prefix. This value does **not** constrain the actual IID width; it describes what the UE should treat as its subnet.
- **`iidAllocation`** — Strategy for populating the IID field when the SMF selects an address: `random`, `eui64`, or `manual`. The current implementation preserves the IID returned by the pool; custom strategies can plug in here.
- **`raProfile`** — Optional reference to a Router Advertisement profile that controls lifetime, flags, and other RA parameters for this pool.

When allocating dynamically, the SMF:

1. Combines the stored `prefix` (upper bits) with the IID pulled from the pool (lower 64 bits by default).
2. Advertises `uePrefixLength` to both the UE and UPF.
3. Records the exact address/IID so it can release it later.

## `ipv6StaticPools`

```yaml
ipv6StaticPools:
  - prefix: 2001:db8:0111:100::/64
    uePrefixLength: 64
    iidAllocation: manual
    raProfile: default
```

Static pools mirror the schema of `ipv6Pools` but are intended for statically-assigned subscribers. During initialization the SMF removes any overlapping ranges from the dynamic pool so the same IID cannot be issued to both static and dynamic UEs. Allocation and prefix length handling behave exactly like dynamic pools, using the `uePrefixLength` defined here.

## `ipv6StaticAssignments`

```yaml
ipv6StaticAssignments:
  - supi: imsi-001010123456789
    address: 2001:db8:0111:100::10
    prefixLength: 64
    comment: UE-1 static IPv6
```

- **`supi`** — The subscriber identifier (`imsi-…`) that triggers this override.
- **`address`** — The full IPv6 address supplied to both the UE and the UPF. This value must lie within one of the configured IPv6 prefixes, but the SMF does not recompute it; it simply installs the address verbatim.
- **`prefixLength`** — The delegated prefix length advertised for this UE. It can differ from the pool’s `uePrefixLength` (for example, `/128` to provide a host-only route). When present, it overrides the pool setting. If omitted, the SMF falls back to the containing pool’s `uePrefixLength`.
- **`comment`** — Optional operator notes retained for documentation.

### Why duplicate the prefix in `address` and `prefixLength`?

- The SMF does not infer the host portion from other fields. Including the full address keeps the static binding self-contained and allows different UEs to reside in different subnets managed by the same pool group.
- `prefixLength` is required so the SMF can encode the correct value in PFCP and Router Advertisement messages. Static bindings frequently use `/128` even when the surrounding pool advertises `/64` to dynamically allocated UEs.

## Interaction Between Pools and Assignments

1. On startup the SMF loads dynamic and static pools, recording both the prefix and the factory configuration so it can report accurate prefix lengths later.
2. Any static pool that sits inside a dynamic pool causes the overlapping IID range to be reserved from the dynamic pool, preventing accidental reuse.
3. When a session is created, the SMF checks for a matching `ipv6StaticAssignments` entry. If found, it returns that exact address and `prefixLength` and marks it as in use.
4. If no static assignment exists, the SMF tries the static pools next, pulling the next available IID from the configured range.
5. Finally, if neither static source applies, the SMF allocates from the dynamic pool, combining the pool prefix with the IID and using the pool’s `uePrefixLength`.

Because the implementation stores and releases the full 64-bit IID, static addresses with non-zero bits in positions 64–95 (for example `2001:db8:abcd:1234:5678:9abc:def0:1234`) are now preserved exactly when allocated, released, and reallocated.

## Operational Tips

- Keep dynamic pools at `/64` or shorter so the SMF can safely generate unique IIDs without exhausting the pool. Smaller subnets (e.g. `/96`) are supported, but document them carefully and ensure the IID space is large enough for the subscriber base.
- Use `ipv6StaticAssignments` for one-off bindings that require `/128` prefixes or addresses outside the main static pool range.
- If both IPv4 and IPv6 are configured, remember that the SMF tracks address families independently; static IPv6 bindings do not affect IPv4 pool usage.
- After modifying pools, restart the SMF to reload configuration and reapply exclusion rules between dynamic and static pools.

## Related Code Paths

- Pool creation and allocation: `NFs/smf/internal/context/ue_ip_pool.go`
- Configuration parsing: `NFs/smf/pkg/factory/config.go`
- UE allocation logic and prefix-length extraction: `NFs/smf/internal/context/sm_context.go`

Refer to those files for implementation details when troubleshooting allocation issues.
