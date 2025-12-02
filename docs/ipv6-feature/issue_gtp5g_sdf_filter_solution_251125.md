# Plan: Ensuring Flow Descriptions Always Provide SRC/DST IPs

  ## Step 1. Understand the current free5gc path
  - Review `free5gc/NFs/upf/internal/forwarder/flowdesc.go` / `gtp5g.go` to map how “any”/“assigned” strings propagate
  into `newFlowDesc` and ultimately `GTP5G_CMD_CONFIG_PDR`.
  - Revisit `gtp5g/src/genl/genl_pdr.c:798-818` to enumerate every FLOW_DESCRIPTION attribute the kernel insists on
  (ACTION, DIRECTION, PROTOCOL, plus SRC/DST IPv4 or IPv6).

  ## Step 2. Define explicit fallback rules for free5gc
  - Decide what to emit when the PFCP Flow Description omits addresses:
    * IPv4 sessions: use UE IPv4 (/32) for “assigned”, `0.0.0.0/0` for “any”.
    * IPv6 sessions: use UE IPv6 (/64 or /128) for “assigned”, `::/0` for “any”.
    * Dual-stack: send both IPv4 and IPv6 TLVs when both anchors exist.
  - Capture these rules in code comments referencing the kernel requirement.

  ## Step 3. Thread UE/peer addressing into `newFlowDesc`
  - Extend the `newFlowDesc` signature (or wrap it) to accept precomputed default source/destination `net.IPNet` values
  derived from the PDI (UEIPAddress) and FAR peer.
  - In `newSdfFilter`, after calling `i.SDFFilter()`, pull the UE IPv4/IPv6 (and remote IP if needed) from `newPdi`’s
  context and pass them down so `newFlowDesc` can substitute them when `ParseFlowDescIPNet` returns `nil`.

  ## Step 4. Always emit SRC/DST TLVs
  - Update the “Add source address” and “Add destination address” sections in `newFlowDesc` so they:
    * Use the parsed `fd.Src`/`fd.Dst` when present.
    * Otherwise, fall back to the UE or wildcard nets computed above.
  - Ensure we emit the IPv6 variants (`SRC_IPV6`, `SRC_IPV6_MASK`, etc.) whenever the fallback is IPv6, and guard with
  `SupportsIPv6()`.

  ## Step 5. Tests and validation
  - Add a focused test (e.g., `flowdesc_test.go`) that feeds “permit out ip from any to assigned” with mocked UE IPv4/IPv6
  values and asserts that the resulting `nl.AttrList` contains the wildcard/UE TLVs.
  - Run SMF+UPF to confirm PFCP session establishment succeeds and dmesg no longer shows `parse_sdf_filter` errors.
  - Re-run URR polling to ensure no regressions.

  ## Step 6. Document the change
  - Update `issue_gtp5g_sdf_filter_analysis_251125.md` (or add a new doc) with a “Fix” section describing the fallback logic,
  referencing both the kernel requirement and the Open5GS comparison below.
  - Note in the commit message that we’re aligning free5gc’s behavior with proven practice rather than weakening the
  kernel check.

  ---

  ## How does Open5gs not having this problem?

  - Open5GS doesn’t use the gtp5g kernel datapath at all. Its UPF (under open5gs/src/upf) installs packet filters through its own ipfw abstraction (lib/ipfw/ogs-ipfw.c), not via GTP5G_CMD_CONFIG_PDR. When a flow description says “permit … from any to assigned”, the ipfw parser rewrites the text to “to any” before compiling the rule. Because Open5GS never calls into the gtp5g generic netlink API, it never needs to emit FLOW_DESCRIPTION_SRC_* / DEST_* TLVs or satisfy the validation in genl_pdr.c.

  - Due to that architectural difference, there isn’t a ready-made Open5GS fix we can lift into free5gc. Open5GS sidesteps this entirely by controlling its own kernel classifier rules. Free5GC’s gtp5g backend, on the other hand, must satisfy the gtp5g kernel requirements: the netlink message must include SRC and DEST IPv4/IPv6 attributes. That’s why the right solution for free5gc is to populate those fields itself (with UE IPs or explicit wildcards) before sending the request, rather than trying to mirror Open5GS’s ipfw behavior.

  ## Since the relation between ipfw and open5gs is the same as gtp5g and free5gc. Why we cannot let gtp5g work the same as ipfw do, so that free5gc don't need to change?

  - ipfw is an internal helper library inside Open5GS. The SMF builds an ogs_ipfw_rule_t, Open5GS converts that to a struct ip_fw and pokes it straight into the kernel’s ipfw tables. Because the same project owns both sides of that interface, it can decide that “to assigned” should become “to any”, or add other shortcuts, and nothing else is affected.

  gtp5g is different:

  - It’s a generic kernel module with a published netlink ABI (GTP5G_CMD_CONFIG_PDR, FLOW_DESCRIPTION_* TLVs). Multiple userlands (free5gc, UPG-VPP, research projects) rely on the same contract. If we “make gtp5g be like ipfw” by silently treating missing SRC/DST as wildcards, we change the behaviour for every consumer and risk traffic leaks between UEs.
  - Accepting a PDR without any IP addresses also leaves the kernel classifier without key match criteria. Today those checks aren’t arbitrary—they prevent us from programming a rule that matches every packet. If we relaxed them to save a free5gc change, the kernel would have to conjure up its own wildcard semantics, and debugging misrouted flows becomes much harder.
  - Free5gc already has the information to fill those TLVs (UE IPv4/IPv6 from the PDI). Supplying them keeps the kernel ABI intact and mirrors how Open5GS ensures its own classifier always gets concrete addresses.

  So while you could fork gtp5g and alter its validation, the cleaner and safer fix is to teach free5gc to emit explicit SRC/DST addresses or wildcards. That keeps gtp5g predictable for every user and aligns with the principle that the user plane (not the kernel) knows the UE context.


  ## Comparison: Free5GC vs Open5GS Handling

  - Datapath
    Free5GC uses the gtp5g kernel module through go-gtp5gnl.
    Open5GS installs ipfw rules directly and never talks to gtp5g.
  - “any”/“assigned” handling
    Free5GC currently lets ParseFlowDescIPNet return nil, so the SRC/DST TLVs are omitted and the kernel rejects the PDR.
    Open5GS rewrites “to assigned” to “to any” (lib/ipfw/ogs-ipfw.c) before compiling the rule, so the classifier always
    has explicit IPs.
  - Kernel validation
    Free5GC must satisfy genl_pdr.c:798-818, which demands SRC/DST IPv4/IPv6 attributes.
    Open5GS doesn’t face this check because it doesn’t use gtp5g.
  - Fix direction
    Free5GC will inject wildcard or UE IP nets before encoding TLVs so gtp5g always receives SRC/DST attributes.
    Open5GS already emits concrete addresses, so no change is needed there.
