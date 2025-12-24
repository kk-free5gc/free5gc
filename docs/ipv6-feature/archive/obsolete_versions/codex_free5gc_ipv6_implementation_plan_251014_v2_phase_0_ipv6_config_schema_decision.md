# IPv6 Config Schema Decision (Phase 0)

## 1. SMF Schema Updates
- Extend each DNN entry under `userplaneInformation.sNssaiUpfInfos[].dnnUpfInfoList[]` to keep current IPv4 `pools`/`staticPools` and add:
  - `ipv6Pools`: array of IPv6 pool definitions with fields `{ prefix, uePrefixLength, iidAllocation: random|eui64|manual, exclude: [], raProfile }`.
  - `ipv6StaticPools`: optional array mirroring `ipv6Pools` for dedicated IPv6 ranges.
  - `ipv6StaticAssignments`: optional per-UE bindings `{ supi, address, prefixLength, comment }`.
    - **Containment rule**: Each static assignment MUST fall within the address space defined by `ipv6Pools` or `ipv6StaticPools`.
    - **Validation**: SMF factory loader SHALL reject configurations where static bindings cannot be advertised/routed from configured pools.
  - **`pduSessionTypes` structure change**: Upgrade from simple array `[]models.PduSessionType` to OpenAPI models struct `*models.PduSessionTypes` with `{ defaultSessionType, allowedSessionTypes }` to match UDR-provided configuration format and enable explicit default session type declaration.
    - **Relationship with existing field**: The factory config field `PduSessionTypes` changes from `[]models.PduSessionType` to `*models.PduSessionTypes` to align with the OpenAPI models used at runtime (`smContext.DnnConfiguration.PduSessionTypes`).
    - **Backward compatibility**: Existing configs using simple array will need migration; provide conversion utility or validation error guidance.
- Allow IPv6 endpoints/FQDNs in `interfaces[].endpoints`; validation must accept IPv4 or IPv6 literals.

## 2. SMF Factory Struct Changes (`free5gc/NFs/smf/pkg/factory/config.go`)
- Retain the existing `UEIPPool` for IPv4 and introduce a parallel `UEIPv6Pool` that understands `{ prefix, uePrefixLength }` semantics; validation must enforce a single address family per entry and forbid mixing IPv4/IPv6 fields in the same item.
- Add new structs for `UEIPv6Pool` and `StaticUEIPv6Assignment` with validators for prefixes, IID modes, and SUPI format.
- **PduSessionTypes field update**: Change `DnnUpfInfoItem.PduSessionTypes` from `[]models.PduSessionType` to `*models.PduSessionTypes` to match OpenAPI models structure (eliminates redundancy with UDR-provided configuration and enables default session type specification).
  - **Validation logic**: Ensure `defaultSessionType` is present in `allowedSessionTypes` array; validate session type values are one of `IPV4|IPV6|IPV4V6|ETHERNET`.
  - **Default behavior**: If `pduSessionTypes` is nil/omitted, default to IPv4-only for backward compatibility: `&models.PduSessionTypes{DefaultSessionType: "IPV4", AllowedSessionTypes: []models.PduSessionType{"IPV4"}}`.
- **Static assignment validator**: Implement containment check ensuring each `StaticUEIPv6Assignment.address` falls within the union of `UeIPv6Pools` and `StaticIPv6Pools` address space; fail config load if violations detected.
- Extend `DnnUpfInfoItem` to include the new slices (`UeIPv6Pools`, `StaticIPv6Pools`, `IPv6StaticAssignments`).
- Update pool construction logic in `internal/context/user_plane_information.go` to branch on IPv4 vs IPv6 fields (actual allocation handled in Phase 1).

## 3. UPF Schema Updates (`free5gc/config/upfcfg.yaml`)
- For each `dnnList` entry keep `cidr` for IPv4 but add an `ipv6` block `{ prefix, uePrefixLength, allocation: random|delegated|manual, raProfile, delegatedPrefixLength?, staticPrefixes: [] }`.
- Add top-level `routerAdvertisements` map; each profile defines `{ enable, routerAddress, prefixLength, linkMtu, flags, lifetime, reachableTimer, retransTimer, dns: [] }`.
- Permit IPv6 addresses in `pfcp.addr`/`nodeID` and `gtpu.ifList[]`; add optional `addr6`, `linkLocal`, `raProfile` per interface.

## 4. UPF Factory Struct Changes (`free5gc/NFs/upf/pkg/factory/config.go`)
- Refactor `DnnList` to require at least one of IPv4 or IPv6 pools; introduce nested structs `IPv4Pool`, `IPv6Pool` with the new fields and validations.
- Extend `IfInfo` with IPv6 attributes and RA profile references; add a `RouterAdvertisementProfile` struct on `Config` for the new map.
- Add integrity checks ensuring pools reference existing RA profiles, prefix lengths are coherent, and timers are non-negative.

## 5. Assumptions & Follow-Ups
- Default UE IPv6 delegation is /64 unless `uePrefixLength` overrides it (needs stakeholder confirmation).
- RA generation responsibility sits in UPF via `routerAdvertisements`; revisit if ownership shifts.
- IID allocation modes limited to `random`, `eui64`, or `manual` for now; confirm before Phase 1 implementation.

## 6. Schema Relationship Clarification: `pduSessionTypes` Field

### Problem Identified
The original plan introduced a new `sessionTypePolicy` field while `DnnUpfInfoItem` already had `pduSessionTypes` field, creating ambiguity:
- **Factory config** (`factory.DnnUpfInfoItem.PduSessionTypes`): Was `[]models.PduSessionType` (simple array)
- **Runtime context** (`context.DnnUPFInfoItem.PduSessionTypes`): Was `[]models.PduSessionType` (simple array)
- **UDR-provided data** (`models.DnnConfiguration.PduSessionTypes`): Uses `*models.PduSessionTypes` struct with `DefaultSessionType` + `AllowedSessionTypes`

This mismatch created confusion about which field controls session type policy and required manual conversion between factory config and UDR-compatible formats.

### Solution: Reuse OpenAPI Models Structure
**Decision**: Change factory config to use `*models.PduSessionTypes` directly instead of creating redundant `SessionTypePolicy` struct.

**Benefits**:
1. **Single source of truth**: Factory config matches OpenAPI models used at runtime
2. **No conversion needed**: Direct pass-through from config to runtime context
3. **Consistency**: Same structure whether config comes from YAML or UDR
4. **Less code**: Eliminates need for custom `SessionTypePolicy` struct and conversion logic

**Migration Impact**:
- **Old YAML format** (deprecated):
  ```yaml
  pduSessionTypes: ["IPV4", "IPV6"]
  ```
- **New YAML format** (required):
  ```yaml
  pduSessionTypes:
    defaultSessionType: "IPV4"
    allowedSessionTypes: ["IPV4", "IPV6", "IPV4V6"]
  ```

**Validation Requirements**:
1. `defaultSessionType` must be in `allowedSessionTypes` array
2. Session type values must be valid: `IPV4|IPV6|IPV4V6|ETHERNET`
3. If omitted, default to IPv4-only for backward compatibility

## Next Steps
1. Share schema with SMF/UPF owners for approval on pool semantics and RA handling.
2. Implement factory struct/validation updates and modify SMF/UPF context loaders to accept the new fields.
3. **Update existing config files** to use new `pduSessionTypes` structure with `defaultSessionType` and `allowedSessionTypes`.
4. Draft migration guidance to translate existing IPv4-only configs into the expanded schema ahead of Phase 1.
