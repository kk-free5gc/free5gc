  # IPv6 Phase 0 Baseline (free5gc + gtp5g)

  ## 1. Scope Alignment
  - Target is dual-stack SMF/UPF behaviour with per-S-NSSAI IPv6 pools while keeping the existing IPv4 flow untouched
  (mirrors open5gs findings in `open5gs/docs/codex_IPv6_UE_Addressing_Findings.md`).
  - Current code already negotiates DNS IPv6 entries at the config layer, but address allocation and PFCP programming
  remain IPv4-only end to end.

  ## 2. SMF IPv4 Allocation Path & Required IPv6 Hooks
  - `SMFContext.SupportedPDUSessionType` is hard-coded to “IPv4” (`free5gc/NFs/smf/internal/context/context.go:69`), so
  NAS handlers never attempt IPv6/IPv4v6.
  - UE pool creation happens when loading `userplaneInformation` (`free5gc/NFs/smf/internal/context/
  user_plane_information.go:185`), wrapping each YAML `cidr` entry in a `UeIPPool`. Pools use `pool.LazyReusePool`
  with 32-bit indices (`free5gc/NFs/smf/internal/context/ue_ip_pool.go:15`, `free5gc/NFs/smf/internal/context/pool/
  lazyReusePool.go:46`), so everything assumes IPv4 arithmetic.
  - Session selection and allocation (`SelectUPFAndAllocUEIP`, `getUEIPPool`; `free5gc/NFs/smf/internal/context/
  user_plane_information.go:859` & `917`) return a single `net.IP` that is converted back to IPv4 when building PFCP rules
  or NAS payloads.
  - PFCP requests force `PDNTypeIpv4` and populate only IPv4 F-TEIDs/UE IP (`free5gc/NFs/smf/internal/pfcp/message/
  build.go:445`, `518`). Any IPv6 work must branch here to set `PdnType` to IPv6/IPv4v6, attach `UEIPAddress` with `V6`
  bits, and populate dual-stack F-SEIDs.
  - `SMContext.PDUAddress` is a single `net.IP` (`free5gc/NFs/smf/internal/context/sm_context.go:134`) shared across
  flows. For IPv6 we need parallel storage (prefix + IID) and to propagate both families to PCF/AMF consumers (all
  referencing `PDUAddress` today).
  - Missing behaviours compared to open5gs: there is no Router Solicitation/Advertisement detection path, so
  IPv6 SLAAC is impossible until we add a GTP-U ICMPv6 handler (equivalent to `check_if_router_solicit()` and
  `send_router_advertisement()` in open5gs).

  ## 3. UPF & gtp5g IPv4 Assumptions
  - PFCP session handling only echoes IPv4 UE addresses, with a TODO for v6 (`free5gc/NFs/upf/internal/pfcp/session.go:87-
  105`). `ie.NewUEIPAddress` is invoked with the “V4-only” flag and the string value of `ueIPAddress.IPv4Address`.
  - Netlink translation to gtp5g uses IPv4-specific attributes (`free5gc/NFs/upf/internal/forwarder/gtp5g.go:312-361`,
  `598-606`); there is no handling for `PDI_UE_ADDR_IPV6`, `OUTER_HEADER_CREATION_PEER_ADDR_IPV6`, etc.
  - Kernel dataplane mirrors this: uplink encapsulation rewrites `iph->saddr/daddr` with `gtpu_addr_ipv4` (`gtp5g/src/
  gtpu/encap.c:882-904`), and the entry point itself is `gtp5g_handle_skb_ipv4` (`gtp5g/src/gtpu/encap.c:1110`). There are
  no IPv6-capable TEID structures or neighbour-discovery helpers.
  - `go-gtp5gnl` (cloned by `free5gc/make_gtp5gtunnel.sh`) currently exposes only IPv4 attrs; we will need to extend both
  the userspace library and the kernel module in tandem to plumb IPv6 addresses.

  ## 4. PFCP Pool Management Gap vs open5gs
  - Free5GC keeps UE pools only inside SMF (`UeIPPools` on `SnssaiUPFInfo`, `free5gc/NFs/smf/internal/context/
  snssai.go:24`); UPF rebuilds its view from PFCP messages and does not track pools locally. Open5GS, in contrast,
  centralizes pools in `ogs_pfcp_*` so SMF and UPF share allocation helpers.
  - Because UPF never owns the pool, there is no notion of IPv6 prefix length/IID generation. Implementing IPv6 means
  either adding equivalent pool logic to free5gc’s PFCP lib or aligning with an open5gs-style shared allocator that both
  SMF and UPF can invoke.
  - Static IP handling (`selection.PDUAddress` branch in `getUEIPPool`) assumes IPv4 containment logic; we need a new
  abstraction that understands IPv6 pools and static addresses.

  ## 5. Config & Tooling Impact
  - `smfcfg.yaml` only allows IPv4 pools (`pools`/`staticPools` under each DNN; `free5gc/config/smfcfg.yaml:156-180`). DNS
  entries already have IPv6 placeholders but no pool configuration.
  - `upfcfg.yaml` lists IPv4-only CIDRs (`free5gc/config/upfcfg.yaml:29-69`). No fields exist for IPv6 prefix, gateway, or
  RA behaviour.
  - Factory structs only validate IPv4 defaults (`free5gc/NFs/smf/pkg/factory/config.go:220-538`, `627`; `free5gc/NFs/upf/
  pkg/factory/config.go:11-51`), so schema updates plus validation logic will be required to accept IPv6 CIDRs.
  - Schema plan: keep `UEIPPool` for IPv4 allocations and add a dedicated `UEIPv6Pool` (plus static IPv6 binding structs) so we extend validation without refactoring existing IPv4 callers.
  - `free5gc/run.sh` brings up NFs but never configures TUN/TAP IPv6 gateways; Phase 3/4 will need helper commands akin to
  open5gs (assigning `ogstun` IPv6 addresses).
  - `make_gtp5gtunnel.sh` pins a version of `go-gtp5gnl` that lacks IPv6 attrs; updating this dependency is part of the
  dataplane work.

  ## 6. Risk Notes
  - Pool allocator (`LazyReusePool`) is 32-bit and not concurrency-safe for 128-bit IPv6 math; redesign is mandatory to
  avoid overflow and to support prefix/IID split.
  - Without RA handling, even if PFCP hands out IPv6 prefixes the UE will never configure them; control-plane deliverables
  must include RS/RA handling before integration.
  - Extending gtp5g risks upstream drift; we should stage kernel-module changes behind feature gates and document minimum
  kernel versions.
  - Dual-stack sessions must keep IPv4 untouched; regression risk is highest around PFCP builder changes and config
  migrations.

  ## 7. Open Questions (needs stakeholder sign-off)
  1. Confirm per-S-NSSAI IPv6 pool semantics: /64 per UE, shared prefix length, and whether static IPv6 assignments are
  required alongside dynamic pools.
  2. Decide where RA generation should live (SMF like open5gs vs UPF vs new helper) and how to signal it in configs.
  3. Clarify if UPF should allocate IPv6 IIDs independently or rely entirely on SMF (affects PFCP message design and pool
  ownership).
  4. Determine expected logging granularity for IPv6 (plan requires `WNC`-prefixed logs—agree on log level/fields).
  5. Validate whether existing go-gtp5gnl/gtp5g upstreams have partial IPv6 support we can reuse or if we maintain a fork.
  6. Confirm operator tooling requirements: should `run.sh` and CI scripts auto-configure IPv6 gateways, or will operators
  manage it manually?

  Next steps you might want to take:

  1. Review/annotate the baseline with SMF, UPF, and ops owners to close the open questions.
  2. Decide on the target schema (YAML + factory structs) so Phase 1 work can begin with clear field names and validation
     rules.
