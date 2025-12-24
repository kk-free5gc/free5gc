# Phase 3 – User Plane & Kernel Implementation Plan

**Status**: ✅ COMPLETE (December 12, 2025)

**Note**: This document describes the original implementation plan created in October 2025. All Phase 3 work has been successfully completed. For actual implementation details, completion status, and troubleshooting, see:
- **Implementation Details**: [phase_3_implementation_consolidated.md](phase_3_implementation_consolidated.md)
- **Recent Fixes**: Issue files dated December 2025 (RS-monitoring, wildcard flows, etc.)

**Historical Reference**: This plan guided Phase 3 development from October-December 2025. The actual implementation followed this plan with some adaptations based on real-world testing and bug fixes.

---

## Scope & Goals
- Deliver IPv6 UE data-path support end-to-end (SMF trigger ➜ UPF control ➜ gtp5g kernel) without regressing IPv4 or enabling the kernel module automatically.
- Land control-path only changes first (no kernel dependency) to unblock Phase 2/3 integration, then gate IPv6 data-plane behind explicit module version checks.
- Maintain crash resistance: all new gtp5g paths must feature bounds checks, feature flags, and CI stress suites before we allow installation guidance.

## Workstream Breakdown

### SMF (Control Hooks)
1. Extend RS handler to invoke the UPF RA inject endpoint when an IPv6-only or IPv4v6 PDU session is active; keep retries + guard behind "gtp5g_supports_ipv6" capability.
2. Ensure PFCP session establishment requests include IPv6 UE IP flag when available; keep existing IPv4 behavior untouched and log downgrades with `WNC` prefix.
3. Add integration tests (Phase 2 suite) that stub the UPF RA endpoint to validate sequencing without requiring kernel bits.

### UPF (Go control-plane & netlink client)
1. Parse IPv6 pool config (already Phase 2) and extend the existing `CreatePDR`/`UpdatePDR` flow (via `newPdi`) to accept IPv6 PDNType, populate PFCP PDR/FAR structs with IPv6 fields, and add dual-stack conflict checks.
2. Update go-gtp5gnl bindings with new genetlink attribute constants (`PDI_UE_ADDR_IPV6`, `F_TEID_GTPU_ADDR_IPV6`, IPv6 SDF filters). Guard operations by probing kernel-reported ABI version on module init.
3. Implement control-path RA inject endpoint that accepts `{seid, pdrId, rawRA}` payload; initially mock by logging and returning success until kernel support lands.
4. When kernel features are present, send IPv6 attrs through the `Create*/Update*` helper paths, and route RA requests via the new netlink op. Add `WNC` logs for enqueue success/failure.
5. Expand unit tests around `forwarder/gtp5g` to cover version gating, attribute marshaling, and negative cases (e.g., kernel lacks IPv6 attr ➜ expect graceful fallback).

### gtp5g (Kernel module & UAPI)
1. **UAPI additions**
   - Extend `gtp5g/include/genl_pdr.h` with IPv6-specific PDI/F-TEID/SDF attribute IDs, mirror F-TEID exposure in `gtp5g/include/genl_far.h`, and adjust shared limits or version enums in `gtp5g/include/genl.h` plus `gtp5g/include/genl_version.h` so userspace can probe capabilities. If we split IPv6 constants into a dedicated header, document the include chain and keep legacy values defined for back-compat.
   - Extend user/kernel compat versioning; bump minor ABI and expose via the existing `GTP5G_VERSION` attribute reported by `gtp5g_genl_get_version`. Document the requirement in `README.md`.
2. **Generic netlink parsing**
   - Update `src/genl/genl_pdr.c` to parse/fill IPv6 attrs: set `pdr->af` based on incoming attr, allow dual-stack by storing both v4 + v6 structures.
   - Ensure length validation, use `nla_len` guards, and zero-init structs to avoid uninitialized reads.
3. **Data-path structures & matching**
   - Grow `struct gtp5g_pdr` and related match structures to carry IPv6 addresses, prefix lengths, and flow-label metadata.
   - Update hash keys and lookup paths to include IPv6; ensure `AF_INET6` branches co-exist with IPv4 without extra copies.
4. **SDF filter & classifier**
   - Teach `src/pfcp/pdr.c` to parse IPv6 flow descriptions, support masks, and default to deny when unsupported fields are seen.
   - Validate uplink and downlink classification with unit tests under `KERNEL_UNIT` harness (add new test vectors).
5. **Encap/decap pipeline**
   - Allow uplink classifier to accept IPv6 inner packets; ensure GTP-U header assembly unaffected (outer IP stays IPv4 unless configured otherwise).
   - Add runtime assertion that rejects IPv6 installs when kernel compiled without CONFIG_IPV6.
6. **Module safety & loading**
   - Keep module autoload disabled: document manual `insmod` steps; add module parameter `ipv6_data_path=0` defaulting to off until QA sign-off.
   - On module init, advertise feature bits so userspace can detect support (`gtp5g_features` netlink op).
7. **Testing & validation**
   - Extend `selftests` (if available) or add new kselftest-style harness to replay PFCP sessions with IPv6 addresses.
   - Run `syzbot`-style fuzz scripts focused on IPv6 attrs; include instructions for maintainers.

### Shared Deliverables
- Update `free5gc/docs/IPv6.md` (or create) with steps to enable IPv6 data plane, manual module load instructions, and fallback guidance.
- Provide sample config stanzas showing dual-stack pools and RA injection usage.

## Sequencing & Milestones
1. **M1 – Control-plane unlock (Week 1)**: Land SMF RS ➜ UPF RA flow + UPF config consumption. Kernel feature probe returns "unsupported" but control path compiles.
2. **M2 – UAPI & bindings (Week 2)**: Merge gtp5g UAPI changes with userspace bindings; publish temporary branch + docs. UPF detects new ABI in CI.
3. **M3 – Kernel data-path (Weeks 3-4)**: Complete IPv6 PDR/FAR handling, classifier updates, and unit coverage. Module feature flag stays off by default.
4. **M4 – Integration bring-up (Week 5)**: Enable `ipv6_data_path=1` in lab; execute dual-stack traffic smoke (ping6/iperf) and RA injection loop.
5. **M5 – Hardening & release prep (Week 6)**: Finalize docs, ensure fallback/regression tests green, cut release notes.

## Validation & Guardrails
- Add CI job that runs UPF unit tests with mocked netlink version permutations.
- Gate kernel module release on kselftest suite + manual soak (24h) with IPv6 traffic; capture crash metrics.
- Verify IPv4-only deployments by running regression suite with module IPv6 flag disabled.
- Ensure RA injection path logs warnings instead of failing when kernel feature absent.

## Open Questions & Follow-ups
- Decide whether RA crafting lives in kernel or userspace helper; current plan assumes raw frame injection from userspace.
- Confirm whether outer GTP-U transport must support IPv6 (if yes, schedule follow-up milestone).
- Determine ownership for long-term maintenance of kselftest harness and syzbot triage.
