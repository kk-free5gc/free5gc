# UPF Flow Description Wildcard Handling

## Root Cause Analysis
- Problem: UE cannot ping 8.8.8.8 even though:
  - UE has IP 10.155.0.1 (PDU Session 1, TEID 2)
  - GTP-U packets ARE arriving at CN from gNodeB (confirmed by tcpdump)
  - gtp5g kernel module is loaded and receiving packets
  - But packets are dropped with error (get from dmesg): "upfgtp:[gtp5g] gtp1u_udp_encap_recv: No PDR match this skb : teid[2]"

- The Bug:

In free5gc/NFs/upf/internal/forwarder/flowdesc.go lines 131-136:

```
  func ParseFlowDescIPNet(s string) (*net.IPNet, error) {
      if s == "any" || s == "assigned" {
          return &net.IPNet{
              IP:   net.IPv6zero,              // ← BUG: Returns :: (IPv6)
              Mask: net.CIDRMask(0, 128),      // ← IPv6 /128 mask
          }, nil
      }
```
- Why This Breaks IPv4 Sessions:

  1. SMF/PCF creates flow descriptors with "any" or "assigned" for source/destination
  2. ParseFlowDescIPNet() converts "any" → net.IPv6zero (::/0)
  3. newFlowDesc() detects IPv6 because IPv6zero.To4() == nil:
  isIPv6 := false
  if fd.Src != nil && fd.Src.IP != nil && fd.Src.IP.To4() == nil {
      isIPv6 = true  // ← Incorrectly detects as IPv6!
  }
  4. UPF installs PDR with IPv6 flow descriptors in gtp5g
  5. Incoming IPv4 packets from UE don't match IPv6 PDRs → dropped

  Evidence from Logs:

  2025-11-14T08:37:38.255167928Z [INFO][SMF] WNC: Allocated IPv4 address [10.155.0.1]
  2025-11-14T08:37:38.386077739Z [DEBU][SMF][CTX] WNC: Set ULPDR F-TEID with IPv4 5.5.5.2 TEID 0x2
  2025-11-14T08:37:38.389698960Z [INFO][UPF][Gtp5g] WNC: Flow descriptor with IPv6 source: ::/0
  2025-11-14T08:37:38.389771979Z [INFO][UPF][Gtp5g] WNC: Flow descriptor with IPv6 destination: ::/0

  Session is IPv4, but flow descriptors are IPv6!
  UPF programmed IPv6 wildcards, so gtp5g rejected the traffic.


Detailed bug path:
1. Flow descriptions with `any`/`assigned` go through `ParseFlowDescIPNet`, which used to return `net.IPv6zero` with a `/0` mask.
2. `newFlowDesc` detects IPv6 because `IPv6zero.To4() == nil`, so `isIPv6 = true`.
3. UPF programs IPv6 flow descriptor TLVs in gtp5g.
4. IPv4 packets from the UE never match those IPv6 PDRs, causing drops.

## Background
The default PCC rules installed by SMF/PCF often include flow descriptions like `permit out ip from any to assigned`. These are meant to match UE traffic without constraining the source/destination IP family so that the same rule works for IPv4, IPv6, or IPv4v6 PDU sessions.  

Historically `ParseFlowDescIPNet` converted `any`/`assigned` into `::/0`. That coerced every wildcard SDF into the IPv6 code path, leading to gtp5g programming IPv6 match fields even for IPv4 sessions. Incoming IPv4 packets could not match those PDRs, producing the observed `No PDR match this skb` drops.

## Current Fix (Option 1 – Adopted)
- Treat `any`/`assigned` as “no address constraint” by returning `nil`.
- `newFlowDesc` already checks `fd.Src != nil` / `fd.Dst != nil` before touching IP data, so leaving them `nil` simply skips installing IP match attributes in gtp5g.
- Result: wildcard filters now behave like the 3GPP spec intends, matching both IPv4 and IPv6 packets while still honoring direction, ports, and other fields.

This approach avoids misclassifying IPv4 flows without needing extra context and matches the expectations baked into `TestNewFlowDesc` (which verifies that the wildcard case emits no address TLVs).

### Implementation Diff (ParseFlowDescIPNet)
To make it easy to see the code delta, here’s the relevant hunk from `NFs/upf/internal/forwarder/flowdesc.go`:
```diff
 func ParseFlowDescIPNet(s string) (*net.IPNet, error) {
 	if s == "any" || s == "assigned" {
-		return &net.IPNet{
-			IP:   net.IPv6zero,
-			Mask: net.CIDRMask(0, 128),
-		}, nil
+		// Wildcards don't map to a concrete IP family and shouldn't constrain IPs,
+		// so let the caller skip both IPv4 and IPv6 TLVs (type-length-value attrs)
+		// and keep the flow applicable to any UE address.
+		return nil, nil
 	}
 	_, ipnet, err := net.ParseCIDR(s)
 	if err == nil {
 		return ipnet, nil
 	}
```

## Future Options (Not Chosen Yet)

### Option 2 – Thread PDU Session Type
- Propagate the PDU session type all the way down to `ParseFlowDescIPNet` and choose either 0.0.0.0/0 or ::/0 depending on the context.
- Pros: explicit control per session type.
- Cons: large intrusive change (PFCP→PDI→SDF filter plumbing) and still ambiguous for IPv4v6 sessions unless duplicate SDFs are generated.

### Option 3 – Infer From UE IP Address
- Deduce the packet family from the UE IP in each PDI and pass that hint to SDF parsing.
- Pros: no new parameters if UE IP is always signaled.
- Cons: some UL rules omit UEIPAddress entirely, and dual-stack sessions again need additional logic. Still requires threading hints through multiple functions.

Both options remain viable if we later need explicit-family wildcards, but for now the spec-aligned `nil` behavior is the simplest and most correct.

## Meaning of `any` vs `assigned`
- `any` appears on the external side of the flow (e.g., `from any`) and literally means traffic from any peer IP address.
- `assigned` refers to “the UE address currently assigned inside this PFCP session.” It avoids encoding the UE’s IP directly in the SDF so rules stay valid even when the SMF reassigns the UE IP.
- In both cases, the flow description intentionally omits a concrete address. The actual UE IP is already bound through the PFCP PDR (via UEIPAddress IE) and FAR, so the SDF field remains a wildcard in the SDF grammar even though the control-plane knows the UE’s real IP elsewhere.

`ParseFlowDescIPNet` is used when building the SDF filter section inside the PDI (and therefore the PDR). The UE IP that anchors the rule is already captured elsewhere in the PDI/FAR, but the SDF still has to understand any extra subnet or host selectors that the policy includes. Returning `nil` for `any`/`assigned` keeps those selectors open-ended, so the PDI/FAR continue to supply the UE binding while the SDF only constrains traffic when the policy explicitly asks for it.

For more details, please refer to sdf_qfi_pdr_pdi_far_explaination_251114.md