# Phase 3 – User Plane & Kernel Updates - Detailed Implementation Plan

## Overview
Phase 3 enables complete IPv6 UE traffic handling by implementing IPv6 support across the kernel (gtp5g), UPF userspace, and SMF control plane. This phase builds upon Phase 2's control plane foundation to deliver end-to-end IPv6 data plane functionality.

**Key Deliverables:**
- IPv6-aware gtp5g kernel module with extended UAPI
- UPF userspace with IPv6 PFCP and routing support
- SMF Router Advertisement delivery mechanism
- End-to-end IPv6 packet forwarding capability

---

## Phase 3 Component Breakdown

### 3.1 gtp5g Kernel Module (C Development)

**Owner:** gtp5g kernel team
**Dependencies:** None (foundational work)
**Estimated Effort:** 3-4 weeks

#### ⚠️ CRITICAL SAFETY REQUIREMENTS FOR KERNEL MODULE DEVELOPMENT

**Module Loading Protocol:**
```bash
# NEVER auto-load during development
# ALWAYS manual load/test/unload cycle

# Only install it persistently (e.g., sudo make install, depmod, modprobe) after you’re satisfied it’s stable—the manual insmod/rmmod loop is safer during development.

# 1. Build
cd gtp5g && make clean && make

# 2. Manual load (check for immediate crashes)
sudo insmod gtp5g.ko
# If kernel panics here, VM snapshot allows instant recovery

# 3. Check kernel logs immediately
dmesg | grep -E "(WNC|gtp5g|BUG|oops|panic)" | tail -50

# 4. Test functionality (keep session active to monitor)
# ... run UPF tests ...

# 5. Clean unload (check for memory leaks)
sudo rmmod gtp5g
dmesg | grep -E "(WNC|gtp5g)" | tail -20

# 6. Verify no memory leaks
sudo cat /sys/kernel/debug/kmemleak
```

**Installation Command Restriction:**
```bash
# FORBIDDEN during development phase:
sudo make install  # DO NOT RUN - creates auto-load config

# Only after stability proven (1+ week manual testing):
# Check Makefile doesn't create /etc/modules-load.d/gtp5g.conf
# If needed, manually install WITHOUT auto-load:
sudo cp gtp5g.ko /lib/modules/$(uname -r)/extra/
sudo depmod -a
# Still load manually: sudo modprobe gtp5g
```

#### 3.1.1 UAPI Extensions (Netlink Attributes)

**Objective:** Extend genetlink API to carry IPv6 addresses, prefixes, and flow descriptors.

**Files to Modify:**
- `gtp5g/include/genl_pdr.h` - Add new enum attributes
- `gtp5g/src/genl/genl_pdr.c` - Implement parse/fill functions

**New Netlink Attributes:**

```c
// In enum gtp5g_pdi_attrs (genl_pdr.h:35-43)
enum gtp5g_pdi_attrs {
    GTP5G_PDI_UNSPEC,
    GTP5G_PDI_UE_ADDR_IPV4,      // Existing
    GTP5G_PDI_UE_ADDR_IPV6,      // NEW - 16 bytes for UE IPv6 address
    GTP5G_PDI_F_TEID,
    GTP5G_PDI_SDF_FILTER,
    GTP5G_PDI_SRC_INTF,
    __GTP5G_PDI_ATTR_MAX,
};

// In enum gtp5g_f_teid_attrs (genl_pdr.h:47-53)
enum gtp5g_f_teid_attrs {
    GTP5G_F_TEID_UNSPEC,
    GTP5G_F_TEID_I_TEID,
    GTP5G_F_TEID_GTPU_ADDR_IPV4,  // Existing
    GTP5G_F_TEID_GTPU_ADDR_IPV6,  // NEW - 16 bytes for GTP-U endpoint IPv6
    __GTP5G_F_TEID_ATTR_MAX,
};

// In enum gtp5g_flow_description_attrs (genl_pdr.h:68-81)
enum gtp5g_flow_description_attrs {
    GTP5G_FLOW_DESCRIPTION_ACTION = 1,
    GTP5G_FLOW_DESCRIPTION_DIRECTION,
    GTP5G_FLOW_DESCRIPTION_PROTOCOL,
    GTP5G_FLOW_DESCRIPTION_SRC_IPV4,      // Existing
    GTP5G_FLOW_DESCRIPTION_SRC_MASK,
    GTP5G_FLOW_DESCRIPTION_DEST_IPV4,     // Existing
    GTP5G_FLOW_DESCRIPTION_DEST_MASK,
    GTP5G_FLOW_DESCRIPTION_SRC_IPV6,      // NEW - 16 bytes
    GTP5G_FLOW_DESCRIPTION_SRC_IPV6_MASK, // NEW - 16 bytes
    GTP5G_FLOW_DESCRIPTION_DEST_IPV6,     // NEW - 16 bytes
    GTP5G_FLOW_DESCRIPTION_DEST_IPV6_MASK,// NEW - 16 bytes
    GTP5G_FLOW_DESCRIPTION_SRC_PORT,
    GTP5G_FLOW_DESCRIPTION_DEST_PORT,
    GTP5G_FLOW_DESCRIPTION_FLOW_LABEL,    // NEW - 20-bit IPv6 flow label
    __GTP5G_FLOW_DESCRIPTION_ATTR_MAX,
};
```

**Implementation Tasks:**

1. **Update parse_pdi() in genl_pdr.c:520**
   ```c
   // Add after existing PDI_UE_ADDR_IPV4 handling (line 538)
   if (attrs[GTP5G_PDI_UE_ADDR_IPV6]) {
       if (!pdi->ue_addr_ipv6) {
           pdi->ue_addr_ipv6 = kzalloc(sizeof(struct in6_addr), GFP_ATOMIC);
           if (!pdi->ue_addr_ipv6)
               return -ENOMEM;
       }
       memcpy(pdi->ue_addr_ipv6, nla_data(attrs[GTP5G_PDI_UE_ADDR_IPV6]), 16);
       GTP5G_INF(NULL, "WNC: PDI UE IPv6: %pI6\n", pdi->ue_addr_ipv6);
   }
   ```

2. **Update parse_f_teid() for IPv6 GTP-U endpoints**
   ```c
   // Parse both IPv4 and IPv6 F-TEID addresses
   if (attrs[GTP5G_F_TEID_GTPU_ADDR_IPV6]) {
       if (!f_teid->gtpu_addr_ipv6) {
           f_teid->gtpu_addr_ipv6 = kzalloc(sizeof(struct in6_addr), GFP_ATOMIC);
           if (!f_teid->gtpu_addr_ipv6)
               return -ENOMEM;
       }
       memcpy(f_teid->gtpu_addr_ipv6, nla_data(attrs[GTP5G_F_TEID_GTPU_ADDR_IPV6]), 16);
   }
   ```

3. **Update gtp5g_genl_fill_f_teid() in genl_pdr.c:852**
   ```c
   // Add IPv6 F-TEID serialization
   if (f_teid->gtpu_addr_ipv6) {
       if (nla_put(skb, GTP5G_F_TEID_GTPU_ADDR_IPV6, 16, f_teid->gtpu_addr_ipv6))
           return -EMSGSIZE;
   }
   ```

4. **Update gtp5g_genl_fill_pdi() in genl_pdr.c:877**
   ```c
   // Add IPv6 UE address serialization
   if (pdi->ue_addr_ipv6) {
       if (nla_put(skb, GTP5G_PDI_UE_ADDR_IPV6, 16, pdi->ue_addr_ipv6))
           return -EMSGSIZE;
   }
   ```

5. **Update parse_flow_desc() for IPv6 flow matching**
   - Parse `GTP5G_FLOW_DESCRIPTION_SRC_IPV6/DEST_IPV6/FLOW_LABEL`
   - Store in extended `struct ip_filter_rule`

**Validation:**
- Add WNC-prefixed logs for all IPv6 attr parsing
- Verify netlink message size limits (max 4KB per message)
- Test dual-stack scenarios (both IPv4 and IPv6 attrs present)

#### 3.1.2 Kernel Data Structures

**Objective:** Extend kernel structs to hold IPv6 addressing and support dual-stack.

**Files to Modify:**
- `gtp5g/include/pdr.h` - Core data structures

**Structure Updates:**

```c
// In struct local_f_teid (pdr.h:17-20)
struct local_f_teid {
    u32 teid;
    struct in_addr gtpu_addr_ipv4;   // Existing
    struct in6_addr *gtpu_addr_ipv6; // NEW - dynamically allocated
};

// In struct ip_filter_rule (pdr.h:22-34)
struct ip_filter_rule {
    uint8_t action;
    uint8_t direction;
    uint8_t proto;

    // IPv4 fields (existing)
    struct in_addr src;
    struct in_addr smask;
    struct in_addr dest;
    struct in_addr dmask;

    // IPv6 fields (NEW)
    struct in6_addr *src_ipv6;
    struct in6_addr *smask_ipv6;
    struct in6_addr *dest_ipv6;
    struct in6_addr *dmask_ipv6;
    u32 flow_label;  // 20-bit IPv6 flow label

    int sport_num;
    struct range *sport;
    int dport_num;
    struct range *dport;
};

// In struct pdi (pdr.h:47-52)
struct pdi {
    u8 srcIntf;
    struct in_addr *ue_addr_ipv4;   // Existing
    struct in6_addr *ue_addr_ipv6;  // NEW - dynamically allocated
    struct local_f_teid *f_teid;
    struct sdf_filter *sdf;
};

// In struct pdr (pdr.h:62-101)
struct pdr {
    // ... existing fields ...
    u16 af;  // Existing - extend to support AF_INET6 and dual-stack

    // af values:
    // AF_INET (2) - IPv4 only
    // AF_INET6 (10) - IPv6 only
    // AF_INET | AF_INET6 - Dual-stack (bitwise OR for multi-family)
};
```

**Implementation Tasks:**

1. **Update pdr_context_free() in pfcp/pdr.c:33**
   ```c
   // Add IPv6 cleanup
   if (pdi) {
       if (pdi->ue_addr_ipv4)
           kfree(pdi->ue_addr_ipv4);
       if (pdi->ue_addr_ipv6)  // NEW
           kfree(pdi->ue_addr_ipv6);
       if (pdi->f_teid) {
           if (pdi->f_teid->gtpu_addr_ipv6)  // NEW
               kfree(pdi->f_teid->gtpu_addr_ipv6);
           kfree(pdi->f_teid);
       }
       // ... rest of cleanup
   }
   ```

2. **Update AF assignment in genl_pdr.c:474**
   ```c
   // Replace hardcoded AF_INET with dynamic detection
   if (pdr->pdi->ue_addr_ipv4 && pdr->pdi->ue_addr_ipv6) {
       pdr->af = AF_INET | AF_INET6;  // Dual-stack
   } else if (pdr->pdi->ue_addr_ipv6) {
       pdr->af = AF_INET6;
   } else {
       pdr->af = AF_INET;  // Default to IPv4
   }
   ```

**Validation:**
- Memory leak testing with kmemleak
- Verify proper reference counting
- Test allocation failures (GFP_ATOMIC can fail under memory pressure)

#### 3.1.3 Packet Matching and Hash Functions

**Objective:** Update PDR lookup to match IPv6 packets and hash UE IPv6 addresses.

**Files to Modify:**
- `gtp5g/src/pfcp/pdr.c` - Packet matching logic
- `gtp5g/include/hash.h` - Hash function declarations
- `gtp5g/src/gtpu/hash.c` - Hash implementations

**Implementation Tasks:**

1. **Add IPv6 hash function (hash.c)**
   ```c
   // Parallel to ipv4_hashfn()
   static inline u32 ipv6_hashfn(const struct in6_addr *addr, u32 hash_size) {
       // Use Jenkins hash on IPv6 bytes
       return jhash2((u32 *)addr->s6_addr32, 4, 0) % hash_size;
   }
   ```

2. **Add pdr_find_by_ipv6() in pfcp/pdr.c:351 (after pdr_find_by_ipv4)**
   ```c
   struct pdr *pdr_find_by_ipv6(struct gtp5g_dev *gtp, struct sk_buff *skb,
           unsigned int hdrlen, const struct in6_addr *addr)
   {
       struct hlist_head *head;
       struct pdr *pdr;
       struct pdi *pdi;

       head = &gtp->addr_hash[ipv6_hashfn(addr, gtp->hash_size)];

       hlist_for_each_entry_rcu(pdr, head, hlist_addr) {
           pdi = pdr->pdi;

           // Check IPv6 family and address match
           if (!((pdr->af & AF_INET6) && pdi->ue_addr_ipv6 &&
                 ipv6_addr_equal(pdi->ue_addr_ipv6, addr)))
               continue;

           // Apply SDF filter if present
           if (pdi->sdf)
               if (!sdf_filter_match(pdi->sdf, skb, hdrlen, GTP5G_SDF_FILTER_OUT))
                   continue;

           GTP5G_INF(NULL, "WNC: Match PDR ID:%d (IPv6)\n", pdr->id);
           return pdr;
       }
       return NULL;
   }
   ```

3. **Update pdr_find_by_gtp1u() in pfcp/pdr.c:332**
   ```c
   // Inside the loop, add IPv6 inner packet matching
   if (pdi->ue_addr_ipv4) {
       iph = (struct iphdr *)(skb->data + hdrlen);
       if ((!(pdr->af & AF_INET)) || (!ip_match(iph, pdr))) {
           continue;
       }
   } else if (pdi->ue_addr_ipv6) {  // NEW
       struct ipv6hdr *ip6h = (struct ipv6hdr *)(skb->data + hdrlen);
       if ((!(pdr->af & AF_INET6)) || (!ipv6_match(ip6h, pdr))) {
           continue;
       }
   }
   ```

4. **Implement ipv6_match() helper**
   ```c
   static bool ipv6_match(struct ipv6hdr *ip6h, struct pdr *pdr) {
       struct pdi *pdi = pdr->pdi;

       if (!pdi->ue_addr_ipv6)
           return false;

       // Match destination IPv6 for downlink
       if (is_downlink(pdr)) {
           return ipv6_addr_equal(&ip6h->daddr, pdi->ue_addr_ipv6);
       }
       // Match source IPv6 for uplink
       else if (is_uplink(pdr)) {
           return ipv6_addr_equal(&ip6h->saddr, pdi->ue_addr_ipv6);
       }
       return false;
   }
   ```

5. **Update pdr_update_hlist_table() for IPv6 hash insertion**
   ```c
   // Add IPv6 UE address hash (after IPv4 hash at line ~400)
   if (pdi && pdi->ue_addr_ipv6) {
       head = &gtp->addr_hash[ipv6_hashfn(pdi->ue_addr_ipv6, gtp->hash_size)];
       hlist_add_head_rcu(&pdr->hlist_addr, head);
   }
   ```

6. **Update SDF filter matching in pfcp/pdr.c:332,364**
   ```c
   // Enhance sdf_filter_match() to support IPv6 5-tuple
   bool sdf_filter_match(struct sdf_filter *sdf, struct sk_buff *skb,
                        unsigned int hdrlen, int direction) {
       struct ip_filter_rule *rule = sdf->rule;

       // Detect IPv4 vs IPv6
       u8 ip_version = (*(u8 *)(skb->data + hdrlen)) >> 4;

       if (ip_version == 6) {
           struct ipv6hdr *ip6h = (struct ipv6hdr *)(skb->data + hdrlen);

           // Match IPv6 source/dest addresses
           if (rule->src_ipv6) {
               struct in6_addr masked_src;
               ipv6_addr_mask(&masked_src, &ip6h->saddr, rule->smask_ipv6);
               if (!ipv6_addr_equal(&masked_src, rule->src_ipv6))
                   return false;
           }

           // Match flow label if specified
           if (sdf->flow_label &&
               (*sdf->flow_label != (ntohl(ip6h->flow_lbl[0]) & 0xFFFFF)))
               return false;

           // Continue with L4 matching (ports)...
       } else {
           // Existing IPv4 logic
       }
   }
   ```

**Validation:**
- Test PDR lookup performance with mixed IPv4/IPv6 traffic
- Verify hash distribution (avoid collisions)
- Test with fragmented IPv6 packets

#### 3.1.4 GTP-U Encap/Decap for IPv6 Inner Packets

**Objective:** Ensure GTP-U tunnel processing accepts IPv6 inner packets.

**Files to Modify:**
- `gtp5g/src/gtpu/encap.c` - Encapsulation logic
- `gtp5g/src/gtpu/dev.c` - Device RX/TX handlers

**Implementation Tasks:**

1. **Update gtp5g_encap_recv() to detect IPv6 inner packets**
   ```c
   // After GTP-U header parsing, detect inner IP version
   u8 *inner_ip = skb->data + hdrlen;
   u8 ip_version = (*inner_ip) >> 4;

   if (ip_version == 6) {
       struct ipv6hdr *ip6h = (struct ipv6hdr *)inner_ip;
       // Use IPv6 destination for PDR lookup
       pdr = pdr_find_by_ipv6(gtp, skb, hdrlen, &ip6h->daddr);
   } else {
       // Existing IPv4 path
   }
   ```

2. **Verify encapsulation preserves IPv6 headers**
   - No changes needed if GTP-U treats inner payload as opaque
   - Ensure MTU calculations account for IPv6 header (40 bytes vs 20 for IPv4)

**Validation:**
- Packet capture verification: tcpdump showing correct GTP-U(IPv6) encap
- MTU discovery testing for IPv6 (RFC 8201)

#### 3.1.5 Router Advertisement Injection (Optional for Phase 3.0)

**Objective:** Provide mechanism for UPF to inject ICMPv6 Router Advertisement to UE.

**Approach:** Add simple netlink operation to send raw RA packet to UE by SEID/PDR.

**Files to Create/Modify:**
- `gtp5g/src/genl/genl_ra.c` - New file for RA operations
- `gtp5g/include/genl_ra.h` - New header

**Deferred to Phase 3.1:**
- Can be implemented after basic IPv6 data path is working
- SMF can log RA construction for now (already done in Phase 2.5)

---

### 3.2 UPF Userspace (Go Development)

**Owner:** UPF Go team
**Dependencies:** 3.1.1 (UAPI extensions)
**Estimated Effort:** 2-3 weeks

#### 3.2.1 go-gtp5gnl Bindings Update

**Objective:** Extend Go bindings to use new IPv6 netlink attributes.

**Note:** free5gc uses `github.com/free5gc/go-gtp5gnl` package which wraps kernel API.

**Files to Modify:**
- External dependency: `github.com/free5gc/go-gtp5gnl` (separate repo)
- Local usage: `free5gc/NFs/upf/internal/forwarder/gtp5g.go`

**Implementation Tasks:**

1. **Add constants to go-gtp5gnl (external repo)**
   ```go
   // In gtp5gnl package constants
   const (
       // ... existing constants ...
       PDI_UE_ADDR_IPV4           = 1  // Existing
       PDI_UE_ADDR_IPV6           = 2  // NEW
       F_TEID_GTPU_ADDR_IPV4      = 2  // Existing
       F_TEID_GTPU_ADDR_IPV6      = 3  // NEW
       FLOW_DESCRIPTION_SRC_IPV6  = 8  // NEW
       FLOW_DESCRIPTION_DEST_IPV6 = 10 // NEW
       // ... etc
   )
   ```

2. **Version gating in UPF**
   ```go
   // Add minimum version check for IPv6 support
   const minGtp5gVersionForIPv6 = "0.9.0"  // Adjust based on actual gtp5g release

   func (g *Gtp5g) supportsIPv6() bool {
       // Compare g.version with minGtp5gVersionForIPv6
       return versionCompare(g.version, minGtp5gVersionForIPv6) >= 0
   }
   ```

**Validation:**
- Build against both old and new gtp5g versions
- Graceful degradation if IPv6 attrs not supported

#### 3.2.2 PFCP IE Encoding for IPv6

**Objective:** Update UPF to populate IPv6 fields in PDI/F-TEID when processing PFCP messages.

**Files to Modify:**
- `free5gc/NFs/upf/internal/forwarder/gtp5g.go:310-379` - `newPdi()` function

**Current State Analysis:**
- Line 353-361: Only handles `ie.UEIPAddress` with IPv4Address field
- Line 340-351: Only handles `ie.FTEID` with IPv4Address field

**Implementation Tasks:**

1. **Update newPdi() for UE IPv6 Address (line 353-361)**
   ```go
   case ie.UEIPAddress:
       v, err := x.UEIPAddress()
       if err != nil {
           break
       }

       // WNC: Handle IPv4 UE address
       if len(v.IPv4Address) > 0 {
           attrs = append(attrs, nl.Attr{
               Type:  gtp5gnl.PDI_UE_ADDR_IPV4,
               Value: nl.AttrBytes(v.IPv4Address),
           })
       }

       // WNC: Handle IPv6 UE address (NEW)
       if len(v.IPv6Address) > 0 {
           if g.supportsIPv6() {
               attrs = append(attrs, nl.Attr{
                   Type:  gtp5gnl.PDI_UE_ADDR_IPV6,
                   Value: nl.AttrBytes(v.IPv6Address),
               })
               logger.MainLog.Infof("WNC: PDI UE IPv6 address: %v",
                   net.IP(v.IPv6Address))
           } else {
               logger.MainLog.Warnf("WNC: IPv6 UE address present but gtp5g version %s does not support IPv6",
                   g.version)
           }
       }
   ```

2. **Update newPdi() for F-TEID IPv6 (line 340-351)**
   ```go
   case ie.FTEID:
       v, err := x.FTEID()
       if err != nil {
           break
       }

       // Start F-TEID attribute list
       fteidAttrs := nl.AttrList{
           {
               Type:  gtp5gnl.F_TEID_I_TEID,
               Value: nl.AttrU32(v.TEID),
           },
       }

       // WNC: Handle IPv4 GTP-U endpoint
       if len(v.IPv4Address) > 0 {
           fteidAttrs = append(fteidAttrs, nl.Attr{
               Type:  gtp5gnl.F_TEID_GTPU_ADDR_IPV4,
               Value: nl.AttrBytes(v.IPv4Address),
           })
       }

       // WNC: Handle IPv6 GTP-U endpoint (NEW)
       if len(v.IPv6Address) > 0 {
           if g.supportsIPv6() {
               fteidAttrs = append(fteidAttrs, nl.Attr{
                   Type:  gtp5gnl.F_TEID_GTPU_ADDR_IPV6,
                   Value: nl.AttrBytes(v.IPv6Address),
               })
               logger.MainLog.Infof("WNC: F-TEID GTP-U IPv6 endpoint: %v",
                   net.IP(v.IPv6Address))
           } else {
               logger.MainLog.Warnf("WNC: F-TEID IPv6 address present but gtp5g version %s does not support IPv6",
                   g.version)
           }
       }

       attrs = append(attrs, nl.Attr{
           Type:  gtp5gnl.PDI_F_TEID,
           Value: fteidAttrs,
       })
   ```

3. **Update newSdfFilter() for IPv6 flow descriptors**
   ```go
   func (g *Gtp5g) newSdfFilter(sdfIE *ie.IE, srcIf uint8) (nl.AttrList, error) {
       // ... existing code ...

       // Detect IPv6 in flow description
       if strings.Contains(flowDesc, "::") || strings.Contains(flowDesc, "IPV6") {
           if !g.supportsIPv6() {
               return nil, fmt.Errorf("WNC: IPv6 SDF filter but gtp5g version %s lacks IPv6 support", g.version)
           }

           // Parse IPv6 addresses and add FLOW_DESCRIPTION_SRC_IPV6/DEST_IPV6
           // Implementation depends on flow description format
       }
   }
   ```

**Validation:**
- PFCP session establishment with IPv6 PDN Type
- Verify gtp5g receives correct IPv6 addresses via netlink
- Test dual-stack sessions (both IPv4 and IPv6 attrs)

#### 3.2.3 IPv6 Routing and TUN/TAP Setup

**Objective:** Configure UPF network interfaces to route IPv6 traffic per pool.

**Files to Modify:**
- `free5gc/NFs/upf/internal/forwarder/` - Interface setup code
- Configuration: `free5gc/config/upfcfg.yaml` (already done in Phase 1)

**Implementation Tasks:**

1. **Add IPv6 routes when UPF starts**
   ```go
   // After IPv4 route setup
   for _, ipv6Pool := range dnnInfo.UeIPv6Pools {
       // Add route: ip -6 route add <pool> dev <upfInterface>
       cmd := exec.Command("ip", "-6", "route", "add", ipv6Pool.String(),
           "dev", upfInterface)
       if err := cmd.Run(); err != nil {
           logger.MainLog.Errorf("WNC: Failed to add IPv6 route %s: %v",
               ipv6Pool.String(), err)
       } else {
           logger.MainLog.Infof("WNC: Added IPv6 route %s dev %s",
               ipv6Pool.String(), upfInterface)
       }
   }
   ```

2. **Enable IPv6 forwarding on UPF interfaces**
   ```go
   // sysctl -w net.ipv6.conf.<interface>.forwarding=1
   sysctlPath := fmt.Sprintf("/proc/sys/net/ipv6/conf/%s/forwarding", upfInterface)
   if err := ioutil.WriteFile(sysctlPath, []byte("1"), 0644); err != nil {
       logger.MainLog.Errorf("WNC: Failed to enable IPv6 forwarding on %s: %v",
           upfInterface, err)
   }
   ```

3. **Assign IPv6 gateway address to TUN interface**
   ```go
   // For each IPv6 pool, assign gateway as first usable address
   // ip -6 addr add <gatewayIPv6>/<prefixLen> dev <tunInterface>
   gatewayIPv6 := calculateGatewayIPv6(ipv6Pool) // e.g., first address in pool
   cmd := exec.Command("ip", "-6", "addr", "add",
       fmt.Sprintf("%s/%d", gatewayIPv6, prefixLen), "dev", tunInterface)
   if err := cmd.Run(); err != nil {
       logger.MainLog.Errorf("WNC: Failed to assign IPv6 gateway %s: %v",
           gatewayIPv6, err)
   }
   ```

**Validation:**
- `ip -6 route show` on UPF host shows IPv6 pool routes
- `ip -6 addr show` shows gateway addresses on TUN interfaces
- Ping6 from UPF to UE IPv6 address (after end-to-end integration)

#### 3.2.4 Router Advertisement Endpoint (Deferred to Phase 3.1)

**Objective:** Expose endpoint for SMF to trigger RA injection.

**Approach:** HTTP endpoint or direct PFCP extension.

**Deferred Rationale:**
- Requires 3.1.5 (gtp5g RA injection) to be complete first
- Can test basic IPv6 forwarding without RA initially
- UEs can use stateless autoconfiguration if RA not strictly required

---

### 3.3 SMF Control Plane (Go Development)

**Owner:** SMF team
**Dependencies:** 3.2.2 (UPF PFCP support), Phase 2 (IPv6 allocation)
**Estimated Effort:** 1-2 weeks

#### 3.3.1 Router Solicitation Detection

**Objective:** Detect RS from UE and trigger RA response.

**Current State:**
- `free5gc/NFs/smf/internal/context/router_advertisement.go` - RA builder exists (Phase 2.5)
- `free5gc/NFs/smf/internal/pfcp/handler/handler.go:202` - Event report placeholder

**Files to Modify:**
- `free5gc/NFs/smf/internal/pfcp/handler/handler.go` - PFCP Session Report handler
- `free5gc/NFs/smf/internal/context/sm_context.go:1456` - `HandleEventReport()`

**Implementation Tasks:**

1. **Parse PFCP Event Report for RS (handler.go)**
   ```go
   // In handleSessionReportRequest()
   if req.EventReport != nil {
       for _, eventReport := range req.EventReport {
           eventID := eventReport.EventID

           // WNC: Detect Router Solicitation event
           if eventID == 26 { // PFCP_EVENT_RS (3GPP TS 29.244)
               logger.PfcpLog.Infof("WNC: Router Solicitation event for SEID %d", seid)

               // Find SMContext by SEID
               smContext := smf_context.GetSMContextBySEID(seid)
               if smContext != nil {
                   smContext.HandleEventReport(eventID)
               }
           }
       }
   }
   ```

2. **Complete HandleEventReport() implementation (sm_context.go:1458)**
   ```go
   // Remove "Phase 3" TODO comments
   func (smContext *SMContext) HandleEventReport(eventID uint32) {
       switch eventID {
       case EventIDRouterSolicitation:
           smContext.Log.Infof("WNC: Router Solicitation event received")

           // Validate IPv6 session
           if smContext.SelectedPDUSessionType != nasMessage.PDUSessionTypeIPv6 &&
              smContext.SelectedPDUSessionType != nasMessage.PDUSessionTypeIPv4IPv6 {
               smContext.Log.Warnf("WNC: RS for non-IPv6 session")
               return
           }

           // Build RA packet
           raPacket, err := BuildRouterAdvertisement(
               smContext.PDUAddressIPv6,
               smContext.PDUAddressIPv6PrefixLen,
           )
           if err != nil {
               smContext.Log.Errorf("WNC: Failed to build RA: %v", err)
               return
           }

           // Trigger RA delivery to UPF (Phase 3.1)
           if err := smContext.SendRouterAdvertisement(raPacket); err != nil {
               smContext.Log.Errorf("WNC: Failed to send RA: %v", err)
           }
       }
   }
   ```

**Validation:**
- UE sends RS → SMF logs show event detection
- RA packet built successfully (validate with Wireshark dissector)

#### 3.3.2 Router Advertisement Delivery to UPF

**Objective:** Send constructed RA to UPF for injection to UE.

**Approach 1 (Phase 3.1):** PFCP Session Modification with DL Data Notification
**Approach 2 (Phase 3.2):** Direct UPF HTTP/gRPC endpoint

**Deferred to Phase 3.1:**
- Requires UPF endpoint (3.2.4) and gtp5g support (3.1.5)
- For Phase 3.0, SMF logs RA construction (already done)

**Placeholder Implementation:**
```go
func (smContext *SMContext) SendRouterAdvertisement(raPacket []byte) error {
    smContext.Log.Infof("WNC: Sending RA (%d bytes) to UPF for UE %s",
        len(raPacket), smContext.Supi)

    // TODO Phase 3.1: Call UPF RA injection endpoint
    // For now, just log
    smContext.Log.Warnf("WNC: RA delivery to UPF not yet implemented")

    return nil
}
```

#### 3.3.3 PFCP Session Establishment with IPv6

**Objective:** Ensure SMF sends IPv6 UE address and prefix to UPF in PFCP messages.

**Current State:**
- Phase 2 already populates `PDUAddressIPv6` and `PDUAddressIPv6PrefixLen`
- PFCP library (`github.com/free5gc/pfcp`) should encode these in UE IP Address IE

**Validation Required:**
- Verify `pfcpType.UEIPAddress` includes IPv6Prefix and IPv6PrefixDelegationBits
- Check PFCP Session Establishment Request contains correct IE flags

**Files to Check:**
- `free5gc/NFs/smf/internal/pfcp/message/send.go` - PFCP message construction
- External: `github.com/free5gc/pfcp` library

**Implementation Task:**
```go
// In BuildPFCPSessionEstablishmentRequest()
if smContext.PDUAddressIPv6 != nil {
    ueIPAddr := &pfcpType.UEIPAddress{
        Ipv6d: true,  // IPv6 prefix delegation
        Ipv6:  true,  // IPv6 address present
        Ipv4:  false,
    }

    // Set IPv6 address
    copy(ueIPAddr.Ipv6Address[:], smContext.PDUAddressIPv6.To16())

    // Set IPv6 prefix delegation bits
    ueIPAddr.Ipv6PrefixDelegationBits = smContext.PDUAddressIPv6PrefixLen

    // WNC: Log for verification
    logger.PfcpLog.Infof("WNC: PFCP UE IP Address IE - IPv6: %s/%d",
        smContext.PDUAddressIPv6, smContext.PDUAddressIPv6PrefixLen)

    // Add to PDR/FAR IEs...
}
```

**Validation:**
- Wireshark capture of PFCP messages shows IPv6 UE IP Address IE
- UPF receives and parses IPv6 address correctly

---

## Phase 3 Sequencing and Milestones

### Milestone 3.0: Basic IPv6 Data Path (4 weeks)
**Critical Path:**
1. **Week 1-2:** gtp5g UAPI extensions (3.1.1) + data structures (3.1.2)
2. **Week 2-3:** gtp5g packet matching (3.1.3) + encap/decap (3.1.4)
3. **Week 3:** UPF go-gtp5gnl bindings (3.2.1) + PFCP encoding (3.2.2)
4. **Week 4:** UPF routing setup (3.2.3) + SMF PFCP validation (3.3.3)

**Success Criteria:**
- UE with IPv6 PDU session can send/receive IPv6 packets through UPF
- PFCP Session Establishment includes IPv6 UE address
- gtp5g kernel module processes IPv6 inner packets correctly
- No kernel crashes or memory leaks under IPv6 traffic

**Testing:**
```bash
# On UE namespace
ping6 2001:db8::1  # Ping external IPv6 destination

# On UPF
tcpdump -i upfgtp -n 'ip6'  # Should see GTP-U encapsulated IPv6 packets
```

### Milestone 3.1: Router Advertisement Support (2 weeks)
**Dependencies:** Milestone 3.0 complete

1. **Week 5:** gtp5g RA injection netlink op (3.1.5)
2. **Week 5-6:** UPF RA delivery endpoint (3.2.4) + SMF integration (3.3.2)

**Success Criteria:**
- UE sends RS → SMF detects via PFCP event → UPF injects RA → UE receives RA
- UE autoconfigures IPv6 address based on RA prefix information
- RA parameters (lifetimes, flags) correctly encoded

**Testing:**
```bash
# On UE namespace
rdisc6 upfgtp  # Should receive RA with correct prefix
ip -6 addr show  # Should show SLAAC-configured address
```

### Milestone 3.2: Production Hardening (1-2 weeks)
1. Error handling and edge cases
2. Performance optimization (hash tuning, memory allocation)
3. Comprehensive logging and metrics
4. Documentation updates

---

## Component Responsibility Matrix

| Component | Kernel UAPI | Data Structures | Packet Processing | PFCP Handling | Routing | RA Delivery |
|-----------|-------------|-----------------|-------------------|---------------|---------|-------------|
| **gtp5g** | ✓ Owner | ✓ Owner | ✓ Owner | - | - | ✓ (3.1) |
| **UPF** | ✓ Bindings | - | - | ✓ Owner | ✓ Owner | ✓ (3.1) |
| **SMF** | - | - | - | ✓ Owner | - | ✓ Owner |

---

## Testing Strategy

### ⚠️ Kernel Module Testing Safety Protocol

**BEFORE ANY TESTING:**
1. Create VM snapshot or backup system state
2. Verify recovery kernel in boot menu
3. Test in isolated environment only
4. Monitor console output (not SSH only - kernel panic kills SSH)
5. Keep serial console or VM console accessible

**Testing Progression:**
```bash
# Stage 1: Build validation (no loading)
cd gtp5g && make clean && make
# Check for compilation warnings - fix ALL before loading

# Stage 2: First load test (VM snapshot recommended)
sudo insmod gtp5g.ko
dmesg | tail -100  # Check module_init() succeeded
sudo rmmod gtp5g
dmesg | tail -50   # Check module_exit() cleanup

# Stage 3: Basic netlink test (manual crafted messages)
# ... use Go test harness to send simple UAPI messages ...

# Stage 4: Integration with UPF (controlled)
# Start UPF, verify PFCP session setup works

# Stage 5: Stress testing (after 100+ successful load/unload)
# ... traffic tests, rapid PDR create/delete ...

# ONLY AFTER 1 WEEK STABLE: Consider production deployment
```

### Unit Tests
- **gtp5g:** Kernel module tests with crafted netlink messages
  - **MANDATORY:** Run in VM with snapshot capability
  - **MANDATORY:** Manual load/unload only, no auto-load
  - **MANDATORY:** Monitor dmesg for all WNC log points
- **UPF:** Go unit tests for PFCP IE encoding/decoding
- **SMF:** RA packet construction validation

### Integration Tests
- **Test 1:** IPv6-only PDU session establishment
  - PFCP messages contain IPv6 UE address
  - UPF creates PDR with IPv6 matching rules
  - UE can ping6 external destination

- **Test 2:** Dual-stack PDU session
  - Both IPv4 and IPv6 addresses allocated
  - Both address families in PFCP messages
  - Concurrent IPv4 and IPv6 traffic

- **Test 3:** Router Advertisement flow
  - UE sends RS
  - SMF receives PFCP event report
  - RA delivered to UE
  - UE configures address

- **Test 4:** IPv6 SDF filters
  - PCF policy with IPv6 flow descriptors
  - gtp5g correctly matches IPv6 5-tuple
  - QoS applied per IPv6 flow

### Performance Tests
- Throughput: 1 Gbps IPv6 traffic through UPF
- Latency: < 5ms added by IPv6 processing
- PDR lookup: < 100ns for 10k IPv6 PDRs

### Regression Tests
- IPv4-only sessions still work (backward compatibility)
- Phase 1 config parsing unchanged
- Phase 2 control plane unaffected

---

## Risk Mitigation

### Risk 0: Kernel Module Boot Crash (CRITICAL)
**Impact:** CATASTROPHIC - system unbootable if gtp5g crashes during auto-load
**Mitigation:**
- **NEVER enable auto-load at boot during development**
- **Manual module loading only** until stability proven
- **Safe testing environment requirements:**

```bash
# SAFE: Manual load/unload workflow
cd gtp5g
make clean && make

# Test in isolated environment first
sudo insmod gtp5g.ko
dmesg | tail -50  # Check for WNC logs and errors
lsmod | grep gtp5g

# Verify basic functionality before any auto-load
# ... run tests ...

# Clean unload
sudo rmmod gtp5g
dmesg | tail -20  # Check for cleanup errors
```

**Auto-load Prevention:**
```bash
# DO NOT create /etc/modules-load.d/gtp5g.conf during development
# DO NOT run "make install" until module is stable

# If accidentally installed, remove auto-load:
sudo rm -f /etc/modules-load.d/gtp5g.conf
sudo rm -f /lib/modules/$(uname -r)/extra/gtp5g.ko
sudo depmod -a
```

**Safe Testing Checklist:**
- [ ] Develop and test in VM or isolated test system (NOT production)
- [ ] Keep known-good kernel available for recovery boot
- [ ] Test module load/unload 100+ times without errors
- [ ] Run 24-hour stress test with load/unload cycles
- [ ] Verify all memory cleanup in module_exit()
- [ ] Only enable auto-load after 1 week of stable manual testing

**Emergency Recovery:**
If system becomes unbootable due to gtp5g:
```bash
# Boot to recovery mode or alternate kernel
# Remove faulty module
sudo rm -f /lib/modules/*/extra/gtp5g.ko
sudo rm -f /etc/modules-load.d/gtp5g.conf
sudo depmod -a
# Reboot normally
```

### Risk 1: Kernel UAPI Incompatibility
**Impact:** High - breaks UPF communication with kernel
**Mitigation:**
- Version gating in UPF code
- Graceful fallback to IPv4-only if gtp5g lacks IPv6 support
- Clear error messages guiding users to upgrade gtp5g

### Risk 2: Memory Leaks in Kernel Module
**Impact:** Critical - kernel crash in production
**Mitigation:**
- Extensive kmemleak testing during development
- Reference counting audits for all IPv6 allocations
- Stress testing with rapid PDR create/delete cycles
- **All testing must follow Risk 0 safe environment procedures**

### Risk 3: IPv6 Packet Fragmentation Issues
**Impact:** Medium - large packets dropped
**Mitigation:**
- MTU calculation for IPv6 (1280 minimum per RFC 8200)
- Path MTU Discovery (PMTUD) support
- Fragment reassembly testing

### Risk 4: RA Delivery Timing
**Impact:** Medium - UE cannot autoconfigure
**Mitigation:**
- Implement RA retry mechanism
- Support unsolicited periodic RAs (RFC 4861)
- Fallback to manual IPv6 configuration if RA fails

---

## Documentation Deliverables

1. **gtp5g Kernel Module:**
   - Updated UAPI documentation (netlink attributes)
   - IPv6 flow matching algorithm description
   - Memory management patterns for IPv6 structs

2. **UPF:**
   - IPv6 routing configuration guide
   - PFCP IE encoding reference
   - Troubleshooting guide (logs, tcpdump filters)

3. **SMF:**
   - Router Advertisement parameter tuning
   - PFCP event handling flow diagrams
   - Integration with Phase 2 IPv6 allocation

4. **Operator Guide:**
   - End-to-end IPv6 deployment checklist
   - Performance tuning recommendations
   - Common error scenarios and resolution

---

## Success Metrics

**Functional:**
- [ ] IPv6-only UE can establish PDU session and send/receive data
- [ ] Dual-stack UE has both IPv4 and IPv6 connectivity
- [ ] Router Solicitation/Advertisement flow completes successfully
- [ ] IPv6 SDF filters enforced correctly by gtp5g

**Non-Functional:**
- [ ] IPv6 throughput ≥ 95% of IPv4 throughput
- [ ] No memory leaks detected in 24-hour stress test
- [ ] Build succeeds on Ubuntu 20.04/22.04 with kernel 5.4+
- [ ] All WNC-prefixed logs present for operational debugging

**Compliance:**
- [ ] 3GPP TS 29.244 (PFCP) IPv6 support
- [ ] 3GPP TS 29.281 (GTP-U) IPv6 encapsulation
- [ ] RFC 4861 (IPv6 Neighbor Discovery) for RA
- [ ] RFC 8200 (IPv6 specification) packet handling

---

## Appendix A: Code Locations Reference

### gtp5g (C)
```
gtp5g/
├── include/
│   ├── genl_pdr.h          # UAPI attribute enums (3.1.1)
│   ├── pdr.h               # PDR/PDI/F-TEID structs (3.1.2)
│   └── hash.h              # Hash function declarations (3.1.3)
├── src/
│   ├── genl/
│   │   └── genl_pdr.c      # Netlink parse/fill (3.1.1, 3.1.4)
│   ├── pfcp/
│   │   └── pdr.c           # PDR matching logic (3.1.3)
│   └── gtpu/
│       ├── encap.c         # GTP-U encap/decap (3.1.4)
│       └── hash.c          # Hash implementations (3.1.3)
```

### UPF (Go)
```
free5gc/NFs/upf/
├── internal/
│   └── forwarder/
│       └── gtp5g.go        # Lines 310-379: newPdi() (3.2.2)
│                           # Interface setup code (3.2.3)
```

### SMF (Go)
```
free5gc/NFs/smf/
├── internal/
│   ├── context/
│   │   ├── router_advertisement.go  # RA builder (3.3.1)
│   │   └── sm_context.go           # Line 1456: HandleEventReport (3.3.1)
│   └── pfcp/
│       ├── handler/
│       │   └── handler.go          # Line 202: Event report parsing (3.3.1)
│       └── message/
│           └── send.go             # PFCP message construction (3.3.3)
```

---

## Appendix B: WNC Logging Conventions

All Phase 3 implementations MUST follow WNC logging:

```c
// gtp5g kernel (C)
GTP5G_INF(NULL, "WNC: PDI UE IPv6: %pI6\n", pdi->ue_addr_ipv6);
GTP5G_ERR(NULL, "WNC: Failed to allocate IPv6 address: %d\n", err);
```

```go
// UPF/SMF (Go)
logger.MainLog.Infof("WNC: PDI UE IPv6 address: %v", net.IP(v.IPv6Address))
logger.MainLog.Errorf("WNC: Failed to add IPv6 route %s: %v", pool, err)
```

**Log Levels:**
- **INFO:** Successful operations, major milestones
- **WARN:** Fallbacks, version mismatches, non-critical failures
- **ERROR:** Critical failures requiring operator intervention
- **DEBUG:** Detailed state for troubleshooting (avoid in production)

---

## Appendix C: Compatibility Matrix

| gtp5g Version | UPF Version | SMF Version | IPv6 Support |
|---------------|-------------|-------------|--------------|
| < 0.8.0       | Any         | Any         | None         |
| ≥ 0.9.0       | ≥ Phase 3   | ≥ Phase 2   | Full IPv6    |
| ≥ 0.9.0       | < Phase 3   | Any         | None (needs UPF update) |

**Version Detection:**
```go
// UPF checks gtp5g version at startup
func (g *Gtp5g) checkVersion() error {
    if !g.supportsIPv6() {
        logger.MainLog.Warnf("WNC: gtp5g version %s does not support IPv6. "+
            "IPv6 PDU sessions will fail. Please upgrade to gtp5g >= 0.9.0",
            g.version)
    }
    return nil
}
```

---

## Appendix D: Kernel Module Development Safety Guidelines

### Why Kernel Module Safety is Critical

Unlike userspace crashes (which kill only the application), kernel module bugs can:
- **Panic the entire system** (instant crash, no graceful shutdown)
- **Corrupt filesystem** (if crash occurs during write operations)
- **Make system unbootable** (if module auto-loads at boot and crashes)
- **Corrupt memory** (affecting other kernel subsystems)
- **Lock up hardware** (requiring hard reset)

### Development Best Practices

**1. Memory Management (Most Common Crash Source)**
```c
// ALWAYS check allocation success
struct in6_addr *addr = kzalloc(sizeof(struct in6_addr), GFP_ATOMIC);
if (!addr) {
    GTP5G_ERR(NULL, "WNC: Failed to allocate IPv6 address\n");
    return -ENOMEM;  // Graceful failure, not crash
}

// ALWAYS free in reverse order of allocation
// ALWAYS check pointers before freeing
if (pdi->ue_addr_ipv6) {
    kfree(pdi->ue_addr_ipv6);
    pdi->ue_addr_ipv6 = NULL;  // Prevent double-free
}
```

**2. Locking and Concurrency**
```c
// ALWAYS use appropriate locking for shared data
// gtp5g uses RCU for PDR lookup - respect existing patterns
// NEVER sleep while holding spinlock
// NEVER call GFP_KERNEL allocation in atomic context (use GFP_ATOMIC)
```

**3. Input Validation**
```c
// ALWAYS validate netlink message sizes
if (nla_len(attrs[GTP5G_PDI_UE_ADDR_IPV6]) != 16) {
    GTP5G_ERR(NULL, "WNC: Invalid IPv6 address length: %d\n",
              nla_len(attrs[GTP5G_PDI_UE_ADDR_IPV6]));
    return -EINVAL;
}

// ALWAYS validate pointers from userspace
if (!pdi || !pdi->ue_addr_ipv6) {
    return -EINVAL;
}
```

**4. Logging for Debugging**
```c
// Use WNC prefix for all new logs
// Log at module load/unload
// Log all error paths
// Log successful major operations (PDR creation, etc.)

GTP5G_INF(NULL, "WNC: gtp5g IPv6 support initialized\n");
GTP5G_ERR(NULL, "WNC: Failed to parse IPv6 UE address: %d\n", err);
```

### Testing Checklist Before Each Load

- [ ] Compiled without warnings (`make clean && make`)
- [ ] All `kzalloc()` calls have NULL checks
- [ ] All `kfree()` calls check pointer validity
- [ ] All `memcpy()` calls validate buffer sizes
- [ ] All error paths return proper error codes (not crash)
- [ ] Module exit function mirrors module init (cleanup in reverse)
- [ ] WNC log points added for new code paths
- [ ] Reviewed diff for any `BUG()`, `BUG_ON()`, or `panic()` calls (avoid unless absolutely necessary)

### Debugging Kernel Crashes

**If module crashes on load:**
```bash
# Check dmesg for crash location
dmesg | grep -A 50 "BUG:"
dmesg | grep -A 50 "RIP:"  # Instruction pointer shows crash location

# Decode crash with gdb (if compiled with debug symbols)
gdb gtp5g.ko
(gdb) list *0x<RIP_address>
```

**Enable additional kernel debugging:**
```bash
# Before loading module
echo 1 | sudo tee /proc/sys/kernel/panic_on_oops  # Immediate panic on error
sudo modprobe kmemleak  # Memory leak detection

# After testing
sudo cat /sys/kernel/debug/kmemleak  # Check for leaks
```

### Recovery Procedures

**If system becomes unbootable:**
1. Boot to GRUB menu (hold Shift during boot)
2. Select "Advanced options" → older kernel version
3. Remove faulty module:
   ```bash
   sudo rm -f /lib/modules/*/extra/gtp5g.ko
   sudo rm -f /etc/modules-load.d/gtp5g.conf
   sudo depmod -a
   ```
4. Reboot normally

**If system freezes during testing:**
1. Magic SysRq keys (if enabled): `Alt+SysRq+b` (immediate reboot)
2. If VM: restore snapshot
3. If physical: hard reset, boot recovery kernel

### When is it Safe to Enable Auto-load?

**Minimum criteria (ALL must be met):**
- [ ] 1000+ successful manual load/unload cycles
- [ ] 7+ days continuous operation under production-like traffic
- [ ] Zero memory leaks detected by kmemleak
- [ ] Stress tested with 10000+ PDR create/delete operations
- [ ] Fuzz tested with malformed netlink messages
- [ ] Code reviewed by 2+ kernel developers
- [ ] Tested on multiple kernel versions (5.4, 5.10, 5.15+)
- [ ] All error paths tested and validated
- [ ] Rollback plan documented and tested

---

**Document Version:** 1.1
**Date:** 2025-01-23
**Status:** Ready for Implementation - WITH MANDATORY SAFETY PROTOCOLS
**Next Review:** After Milestone 3.0 completion
**CRITICAL:** All kernel module development MUST follow Appendix D safety guidelines
