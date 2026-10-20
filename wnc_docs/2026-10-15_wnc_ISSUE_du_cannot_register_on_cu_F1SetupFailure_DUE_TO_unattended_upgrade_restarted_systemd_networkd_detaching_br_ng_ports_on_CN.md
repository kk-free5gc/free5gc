# ISSUE: DU cannot register on CU, CU sends `F1SetupFailure` — `unattended-upgrade` restarted `systemd-networkd` on cn, which detached the ports of `br-ng`

| Field | Value |
|---|---|
| Date | 2026-10-15 |
| Repo | `free5gc`. The capture set was collected into this tree. The defect itself is in the network setup of the `cn` host, not in any source tree. |
| Tree | `/home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc` |
| Branch | `my-changes-v4.0.1` |
| Commit | `37c302c` feat(ipv6): hand out the cn DNS64 server to UEs for 464XLAT; smfcfg.yaml becomes a symlink |
| Symptom | `1868    11:12:49.451829    192.168.30.184    192.168.30.200    F1AP    F1SetupFailure` |
| Scope | The N2 link (CU to AMF, SCTP port 38412) and the N3 link (GTP-U to the UPF at `5.5.5.2`) on the `cn` host. The PLAT (Jool NAT64 and unbound DNS64) was checked and is not involved. |
| Fix | On `cn`: the ports were re-attached to `br-ng` by hand, and `apt-daily-upgrade.timer` was disabled. In `/home/loren/Downloads/log/bootup-scripts/cn/bashrc_cn.sh`: the new function `check_br_ng_ports` is called from `run_free5gc`. That directory is not a git repository, so the script change is not committed anywhere. |
| Rounds | 1 |
| Status | **Fixed and verified.** The DU registered after the ports were re-attached. §7 names the one part that has not been run on `cn`. |
| Prior art | `2026-10-14_wnc_HOWTO_enable_plat_nat64_dns64_on_cn_VIA_jool_on_upf_host_and_dns64_addr_in_smfcfg_AVOID_upfcfg_ra_dns_list_not_sent_to_ue.md` describes the PLAT change that was first suspected. This doc rules that change out. |

---

## SECTION 0. Symptom — evidence collected at the time of the failure

The capture directory is
`/home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc/my_logs/test8-du-cannot-register-on-cu-after-auto-plat-enable-on-cn/`.

**1. Verbatim failure output.** The user reported these two lines from the CU packet capture
`/home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc/my_logs/test8-du-cannot-register-on-cu-after-auto-plat-enable-on-cn/cu1_log/bin/tcpdump-cu1-261015_1110.pcap`:

```
1868    11:12:49.451829    192.168.30.184    192.168.30.200    F1AP    F1SetupFailure
2065    11:13:02.680832    192.168.0.184    192.168.0.184    ICMP    Destination unreachable (Host unreachable)
```

`192.168.30.184` is the CU address on F1, the interface between the DU and the CU, and `192.168.30.200` is the DU. `192.168.0.184` is the CU N2 address.

A `tshark` filter on SCTP, NGAP, F1AP and ICMP over the same capture printed this (excerpt, tab-separated):

```
1799	2026-10-15T11:12:44.448126000+0800	192.168.30.200	192.168.30.184	SCTP	INIT 
1800	2026-10-15T11:12:44.448166000+0800	192.168.30.184	192.168.30.200	SCTP	INIT_ACK 
1804	2026-10-15T11:12:44.448624000+0800	192.168.30.200	192.168.30.184	F1AP	F1SetupRequest, MIB, SIB1 
1810	2026-10-15T11:12:44.452065000+0800	192.168.0.184	192.168.0.2	SCTP	INIT 
1815	2026-10-15T11:12:45.463822000+0800	192.168.0.184	192.168.0.2	SCTP	INIT 
1860	2026-10-15T11:12:47.380007000+0800	192.168.30.200	192.168.30.184	F1AP	F1SetupRequest, MIB, SIB1 
1864	2026-10-15T11:12:47.512827000+0800	192.168.0.184	192.168.0.2	SCTP	INIT 
1868	2026-10-15T11:12:49.451829000+0800	192.168.30.184	192.168.30.200	F1AP	F1SetupFailure
1915	2026-10-15T11:12:51.544822000+0800	192.168.0.184	192.168.0.2	SCTP	INIT 
1946	2026-10-15T11:12:54.452166000+0800	192.168.30.200	192.168.30.184	F1AP	F1SetupRequest, MIB, SIB1 
2019	2026-10-15T11:12:59.452865000+0800	192.168.30.184	192.168.30.200	F1AP	F1SetupFailure
2065	2026-10-15T11:13:02.680832000+0800	192.168.0.184,192.168.0.184	192.168.0.184,192.168.0.2	ICMP	Destination unreachable (Host unreachable)
```

The capture holds no NGAP packet at all, and no SCTP `INIT_ACK` from `192.168.0.2`.

**2. Variations of the same symptom.** The `F1SetupRequest` / `F1SetupFailure` pair repeats about every 10
seconds while the DU retries. The ICMP `Host unreachable` line repeats from `192.168.0.184` to itself, and
only the frame number and time change. The same fault would also break the N3 user plane to `5.5.5.2`,
because `br-ng` carries both addresses. In this occurrence, nothing got far enough to show that.

**3. The confirming state.** On `cn`, the bridge `br-ng` holds the AMF address and the UPF address, but its
link is `DOWN` with `NO-CARRIER`. Meanwhile the physical port `enp23s0f3` is `UP` with `LOWER_UP`, and it
carries no `master br-ng`:

```
enp23s0f3        UP             fe80::f2b2:b9ff:fe0a:3be3/64 
br-ng            DOWN           192.168.0.2/24 5.5.5.2/24 fe80::409:5bff:fe0e:dabd/64 
```

```
enp23s0f3        UP             f0:b2:b9:0a:3b:e3 <BROADCAST,MULTICAST,UP,LOWER_UP> 
br-ng            DOWN           06:09:5b:0e:da:bd <NO-CARRIER,BROADCAST,MULTICAST,UP> 
```

```
[root@75N0-01N0SA-sled2-CN free5gc]#   ip link show master br-ng
[root@75N0-01N0SA-sled2-CN free5gc]# 
```

In the CU capture, the CU asks for the AMF address 66 times and gets no answer. Nothing in the capture
comes from `192.168.0.2`:

```
     66 1873 157.916807 Intel_01:cf:8b → ARP Who has 192.168.0.2? Tell 192.168.0.184
```

**4. The sequence.** The failure is about order. A package upgrade early in the morning broke `br-ng`
hours before free5gc was started and before the DU tried to register.

Legend. `apt` is `/var/log/apt/history.log` on `cn`. `journal` is `journalctl` on `cn`, with times to the
second. `free5gc` is `/home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc/my_logs/test8-du-cannot-register-on-cu-after-auto-plat-enable-on-cn/free5gc/log/20261015_111039/free5gc.log`, with times to the
nanosecond. `CU pcap` is `/home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc/my_logs/test8-du-cannot-register-on-cu-after-auto-plat-enable-on-cn/cu1_log/bin/tcpdump-cu1-261015_1110.pcap`, with times
to the microsecond in UTC+8. This doc does not record whether the `cn` journal clock and the CU capture
clock agree. The order below does not depend on that, because the gap between row 5 and row 8 is more than
four hours.

| # | From | Time | Evidence | Explain |
|---|---|---|---|---|
| 1 | apt | 2026-10-15 06:42:36 | `Commandline: /usr/bin/unattended-upgrade` / `Upgrade: ... systemd:amd64 (249.11-0ubuntu3.22, 249.11-0ubuntu3.23) ...` | The automatic upgrade service installed a new `systemd` package; no person started this upgrade. |
| 2 | journal | Oct 15 06:42:38 | `systemd[1]: Stopping Network Configuration...` | The package upgrade stopped `systemd-networkd`, whose process id was `1309`. |
| 3 | journal | Oct 15 06:42:38 | `systemd-networkd[30756]: br-ng: Link UP` / `br-ng: Gained carrier` | A new `systemd-networkd` with process id `30756` started, and at that moment `br-ng` still had a working port. |
| 4 | journal | Oct 15 06:42:38 | `systemd-networkd[30756]: enp23s0f3: Link UP` / `enp23s0f3: Gained carrier`, logged twice | The new `systemd-networkd` set up `enp23s0f3` again, and that port is the one cabled toward the CU. |
| 5 | journal | Oct 15 06:42:39 | `systemd-networkd[30756]: br-ng: Lost carrier` | One second later `br-ng` lost carrier, which means it no longer had a member port with a link. |
| 6 | journal | Oct 15 06:42:43 | `ntpd[1368]: Deleting interface #9 br-ng:NGC, 192.168.0.2#123, interface stats: received=0, sent=0, dropped=0, active_time=214542 secs` | `ntpd` stopped using `192.168.0.2`, which had been active for 214542 seconds (about 59.6 hours) before this point. |
| 7 | journal | Oct 15 11:10:38 | `kernel: Jool: Created instance 'plat'.` | `run_free5gc` restarted the PLAT, more than four hours after `br-ng` broke. |
| 8 | free5gc | 2026-10-15T11:10:40.627188897+08:00 | `Listen on 192.168.0.2:38412` | The AMF bound its N2 address successfully, because the address existed on `br-ng` even though the bridge had no link. |
| 9 | CU pcap | 11:12:44.448624 | frame `1804` `F1SetupRequest, MIB, SIB1` | The DU asked the CU to register it. |
| 10 | CU pcap | 11:12:44.452065 | frame `1810` `192.168.0.184` → `192.168.0.2` `SCTP INIT` | The CU tried to open its N2 connection to the AMF. |
| 11 | CU pcap | absence | no `INIT_ACK`, and no ARP reply for `192.168.0.2` in 66 requests | The ARP requests from the CU never reached the AMF address, because `enp23s0f3` was not part of `br-ng`. |
| 12 | CU pcap | 11:12:49.451829 | frame `1868` `F1SetupFailure` | The CU rejected the DU while the CU had no N2 connection. |
| 13 | CU pcap | 11:13:02.680832 | frame `2065` `Destination unreachable (Host unreachable)` | The CU kernel gave up on the unanswered ARP for `192.168.0.2` and reported the host as unreachable. |

**5. Check command.** Run on `cn`. It prints one line for each port that is missing from `br-ng`, and
nothing when all four ports are members:

```
for i in enp23s0f0 enp23s0f1 enp23s0f2 enp23s0f3; do ip -o link show master br-ng | grep -q ": $i:" || echo "$i not in br-ng"; done
```

This exact loop was not run during the investigation. The command it is built on, `ip link show master
br-ng`, printed nothing before the fix and printed all four ports after the fix (§7). The function
`check_br_ng_ports` in §6 runs the same test.

**6. What this is NOT.**

- It is not a DU or CU configuration fault. The CU sent a correct `SCTP INIT` to the configured AMF address,
  and the user had not changed the DU or the CU.
- It is not the AMF failing to start. `free5gc.log` shows `Listen on 192.168.0.2:38412`.
- It is not the PLAT. §11 gives the evidence.

**7. The artifacts.**

| File | Contents |
|---|---|
| `/home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc/my_logs/test8-du-cannot-register-on-cu-after-auto-plat-enable-on-cn/cu1_log/bin/tcpdump-cu1-261015_1110.pcap` | CU packet capture with the F1 Setup, SCTP `INIT`, ARP and ICMP packets |
| `/home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc/my_logs/test8-du-cannot-register-on-cu-after-auto-plat-enable-on-cn/cu1_log/bin/cu_26_10_15_11_10_14_part_0.log` | CU application log; it holds SCTP setup lines and no NG Setup line |
| `/home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc/my_logs/test8-du-cannot-register-on-cu-after-auto-plat-enable-on-cn/cu1_log/bin/misc_info.txt` | CU interface listing, which shows `192.168.0.184/24` on `enp23s0f3:ng-c` |
| `/home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc/my_logs/test8-du-cannot-register-on-cu-after-auto-plat-enable-on-cn/free5gc/log/20261015_111039/free5gc.log` | free5gc log with the AMF `Listen on 192.168.0.2:38412` line |
| `/home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc/my_logs/test8-du-cannot-register-on-cu-after-auto-plat-enable-on-cn/free5gc/log/console_free5gc.log` | free5gc console output of the same run |
| `/home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc/my_logs/test8-du-cannot-register-on-cu-after-auto-plat-enable-on-cn/free5gc/config/amfcfg.yaml` | AMF configuration with `ngapIpList` |

The `cn` command output quoted in this doc was pasted into the session by the user and was not saved as a file.

## SECTION 1. Summary — what broke, in one paragraph

The DU could not register on the CU because the CU could not reach the AMF on the `cn` host. On `cn`, the
AMF address `192.168.0.2` and the UPF address `5.5.5.2` live on the bridge `br-ng`. The script
`set_network_bridge_free5gc_251117.sh` builds that bridge with `brctl` and adds the ports
`enp23s0f0`..`enp23s0f3` to it. At 06:42 on 2026-10-15, `unattended-upgrade` installed a new `systemd`
package, and the package upgrade restarted `systemd-networkd`. The new `systemd-networkd` set up the four
ports again from the netplan file, which declares each port as a plain DHCP port, and the ports were no
longer members of `br-ng`. From then on, ARP requests from the CU for `192.168.0.2` reached `enp23s0f3` but
never reached the bridge. The CU could not open its N2 connection, so the CU answered every DU
`F1SetupRequest` with `F1SetupFailure`. The PLAT change that the user suspected ran hours later and played
no part.

## SECTION 2. Background — how the system is meant to behave

The lab topology is `lan-client <-> ue <-> du1 <-> cu1 <-> cn`. Three interfaces carry the control traffic
between those hosts:

- **F1** connects the DU and the CU. The DU registers on the CU with an F1AP `F1SetupRequest`, and the CU
  answers with `F1SetupResponse` or `F1SetupFailure`. In this lab, F1 runs between `192.168.30.200` (DU) and
  `192.168.30.184` (CU).
- **N2** connects the CU and the AMF. It is an SCTP association to port `38412`, and NGAP (the protocol
  between a gNB and an AMF) runs over it. The first NGAP exchange is NG Setup.
- **N3** carries user-plane GTP-U packets between the CU and the UPF.

The CU in this capture sent `F1SetupFailure` while it had no N2 connection. The CU log captured here does
not state the reason it gave for the failure. The explanation used in this doc is that a CU without a
working N2 connection to an AMF cannot accept a DU, and the evidence in §0 is consistent with it.

The CU N2 address is on the port `enp23s0f3:ng-c` of the CU, as `/home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc/my_logs/test8-du-cannot-register-on-cu-after-auto-plat-enable-on-cn/cu1_log/bin/misc_info.txt` shows:

```
    inet 192.168.0.184/24 brd 192.168.0.255 scope global enp23s0f3:ng-c
```

The AMF N2 address comes from
`/home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc/my_logs/test8-du-cannot-register-on-cu-after-auto-plat-enable-on-cn/free5gc/config/amfcfg.yaml:7-9`:

```
  ngapIpList:  # the IP list of N2 interfaces on this AMF
    - 192.168.0.2
  ngapPort: 38412 # the SCTP port listened by NGAP
```

On `cn`, `192.168.0.2` (N2, and also the SMF PFCP address) and `5.5.5.2` (N3) are not on a physical port.
They are on the Linux bridge `br-ng`, and the four ports of the network card `enp23s0f0`..`enp23s0f3` are
members of that bridge. The user brings `cn` up in two steps after power-on: first
`/home/loren/Downloads/log/bootup-scripts/cn/set_network_bridge_free5gc_251117.sh`, then `run_free5gc`,
which is defined in `/home/loren/Downloads/log/bootup-scripts/cn/bashrc_cn.sh`.

`/home/loren/Downloads/log/bootup-scripts/cn/set_network_bridge_free5gc_251117.sh:6-13` names the bridge, the addresses and the ports:

```
NG_IFACE=br-ng
CN_CP_IP=192.168.0.2
CN_UP_IP=5.5.5.2

N2N3_IFACE_0=enp23s0f0
N2N3_IFACE_1=enp23s0f1
N2N3_IFACE_2=enp23s0f2
N2N3_IFACE_3=enp23s0f3
```

`/home/loren/Downloads/log/bootup-scripts/cn/set_network_bridge_free5gc_251117.sh:71-83` builds the bridge with `brctl`, adds the ports, and assigns the
two addresses:

```
# Create bridge
brctl addbr "$NG_IFACE"

# Add interfaces to bridge
for iface in $N2N3_IFACE_0 $N2N3_IFACE_1 $N2N3_IFACE_2 $N2N3_IFACE_3; do
    brctl addif "$NG_IFACE" "$iface"
done

# Bring bridge and subinterfaces up
ip link set "$NG_IFACE" up

ifconfig "$NG_IFACE:NGC" "$CN_CP_IP" netmask 255.255.255.0 up
ifconfig "$NG_IFACE:NGU" "$CN_UP_IP" netmask 255.255.255.0 up
```

Separately, Ubuntu netplan configures the same four ports through `systemd-networkd`.
`/etc/netplan/00-installer-config.yaml` on `cn` is the installer's file, and it does not mention `br-ng`:

```
# This is the network config written by 'subiquity'
network:
  ethernets:
    enp23s0f0:
      dhcp4: true
    enp23s0f1:
      dhcp4: true
    enp23s0f2:
      dhcp4: true
    enp23s0f3:
      dhcp4: true
    enp5s0:
      dhcp4: true
  version: 2
```

Several tools report "correct" while `br-ng` has no ports, so it matters which tool sees which layer:

| Tool | What it shows when `br-ng` has no ports |
|---|---|
| `free5gc.log` | `Listen on 192.168.0.2:38412`, because a bind needs only the local address to exist. |
| `ip -br addr` | `192.168.0.2/24 5.5.5.2/24` on `br-ng`, because the addresses stay on the bridge. |
| `bridge link` | `enp23s0f3` with `hwmode VEPA`, which describes the network card and not membership in `br-ng`. |
| `ip -br link` | `br-ng DOWN ... NO-CARRIER`, which is the first visible sign of the fault. |
| `ip link show master br-ng` | nothing, which is the direct proof that the bridge has no ports. |

## SECTION 3. Investigation — how the root cause was tracked down

| # | Command | Purpose | Outcome | Meaning |
|---|---|---|---|---|
| 1 | `tshark -r /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc/my_logs/test8-du-cannot-register-on-cu-after-auto-plat-enable-on-cn/cu1_log/bin/tcpdump-cu1-261015_1110.pcap -Y 'ngap \|\| f1ap \|\| icmp \|\| sctp.chunk_type==1 \|\| sctp.chunk_type==6 \|\| sctp.chunk_type==2' ...` | Find out whether the failure lies between the DU and the CU, or behind the CU. | The output in §0 item 1: F1 Setup completes its SCTP handshake, but the CU's SCTP `INIT` to `192.168.0.2` never gets an `INIT_ACK`. | The DU-to-CU link works, and the CU itself cannot reach the AMF, so the fault lies on N2. |
| 2 | `grep -inE 'ngsetup\|ng setup\|f1setup\|f1 setup\|amf\|sctp\|cause' /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc/my_logs/test8-du-cannot-register-on-cu-after-auto-plat-enable-on-cn/cu1_log/bin/cu_26_10_15_11_10_14_part_0.log` | Look for an NG Setup attempt or a failure reason in the CU log. | SCTP server setup lines and one `sctp_ng_client.cpp:211` line; no NG Setup line. | The CU log confirms that the CU started its N2 client, and it gives no failure reason. |
| 3 | `grep -nA3 ngapIpList /home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc/my_logs/test8-du-cannot-register-on-cu-after-auto-plat-enable-on-cn/free5gc/config/amfcfg.yaml` and a grep of `/home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc/my_logs/test8-du-cannot-register-on-cu-after-auto-plat-enable-on-cn/free5gc/log/20261015_111039/free5gc.log` for `ngap\|sctp\|listen` | Check whether the AMF was listening on the address the CU dials. | `ngapIpList:` `- 192.168.0.2` and `Listen on 192.168.0.2:38412`. | The AMF was configured and listening on the right address, so the AMF is not the fault. |
| 4 | `tshark -r ... -Y 'arp'`, counted with `uniq -c` | Find out why the CU reports `Host unreachable` for its own SCTP packets. | `66 ... ARP Who has 192.168.0.2? Tell 192.168.0.184`, and no reply. A filter on `ip.src==192.168.0.2 \|\| arp.src.proto_ipv4==192.168.0.2` printed nothing. | The `cn` host never answered ARP for `192.168.0.2`, so the fault is at layer 2 on the `cn` side. |
| 5 | `ip -br addr; ip -br link; ip addr show \| grep -B3 192.168.0.2; ip route get 192.168.0.184` on `cn` | Find which interface holds `192.168.0.2` and whether its link is up. | `br-ng DOWN 192.168.0.2/24 5.5.5.2/24`, `<NO-CARRIER,...>`; `enp23s0f3 UP ... <...,LOWER_UP>` with no `master`. | The address sits on a bridge that has no carrier, while the port cabled to the CU is up but outside the bridge. |
| 6 | `timeout 15 tcpdump -ni br-ng arp or sctp` on `cn` | Confirm that the ARP requests from the CU never reach `br-ng`. | `0 packets captured` | Nothing from the wire reaches `br-ng`, which matches a bridge with no ports. |
| 7 | `sysctl -a \| grep -E 'arp_ignore\|arp_filter\|arp_announce\|rp_filter'`, `nft list ruleset`, `arptables -L`, `ip netns list` on `cn` | Rule out an ARP setting, a firewall rule or a network namespace. | All `arp_*` values `0`; `nft` holds only `oifname "enp5s0" ... masquerade`; `arptables` chains empty with policy `ACCEPT`; no namespaces. | None of these explains the missing ARP reply. |
| 8 | `systemctl cat` on the enabled `jool*` units, `ls /etc/netplan/`, `journalctl -b \| grep -iE 'jool\|plat\|netplan\|192.168.0.2\|link (is )?down'` on `cn` | Find what the PLAT auto-enable runs, and when the address changed. | `jool.service` runs only `modprobe jool` and `jool file handle`. The journal shows `ntpd ... Deleting interface #9 br-ng:NGC, 192.168.0.2` at `Oct 15 06:42:43`, beside `netplan-ovs-cleanup.service` warnings from `06:42:37`. | `br-ng` lost `192.168.0.2` from the view of `ntpd` at 06:42, hours before the next Jool event at 11:09. |
| 9 | Reading `set_network_bridge_free5gc_251117.sh` and `run_plat` / `stop_plat` in `bashrc_cn.sh` | Check whether the boot-up scripts remove ports from `br-ng`. | The bridge script adds all four ports; `run_plat` and `stop_plat` touch only `lo`, Jool, unbound and two `sysctl` values. | The user's scripts do not detach the ports. |
| 10 | `bridge link` and `ip link show master br-ng` on `cn` | Prove whether `br-ng` has any member port. | `bridge link` lists the four ports with `hwmode VEPA` and no `master`; `ip link show master br-ng` prints nothing. | `br-ng` has no member port at all. |
| 11 | `journalctl --since "2026-10-15 06:30" --until "2026-10-15 06:50"`, `grep -B2 -A8 "Start-Date: 2026-10-15" /var/log/apt/history.log`, `journalctl -u systemd-networkd` for the same window, on `cn` | Find what restarted the network at 06:42. | The full journal was filled with `open5gs-seppd` DEBUG lines. `apt` shows `unattended-upgrade` installing `systemd` at `06:42:36`. The `systemd-networkd` journal shows the restart at `06:42:38` and `br-ng: Lost carrier` at `06:42:39`. | The `systemd` upgrade restarted `systemd-networkd`, and `br-ng` lost carrier one second after the new process configured the ports. |

The user ran `ip -br addr` with the other step 5 commands, and the output contained:

```
192.168.0.184 dev br-ng src 192.168.0.2 uid 0 
    cache 
```

That route lookup shows the kernel on `cn` would answer the CU through `br-ng`, so an answer would have gone
out of a bridge with no ports as well.

## SECTION 4. Root cause — the defect, and what it does

**Proven.** The bridge `br-ng` on `cn` had no member ports. `ip link show master br-ng` printed nothing, and
`br-ng` showed `NO-CARRIER` while `enp23s0f3` showed `LOWER_UP`. Frames from the CU arrived on
`enp23s0f3` and were never delivered to `br-ng`, so `cn` never answered ARP for `192.168.0.2`.

**Proven.** The ports were lost at 06:42 on 2026-10-15, during an automatic `systemd` upgrade. The
`systemd-networkd` journal records the old process `1309` stopping at `06:42:38`, the new process `30756`
setting up `enp23s0f0`..`enp23s0f3` at `06:42:38`, and `br-ng: Lost carrier` at `06:42:39`. Before 06:42,
`192.168.0.2` had been in use for 214542 seconds, according to `ntpd`.

**Probable, not proven.** The new `systemd-networkd` removed the ports from `br-ng` while applying the
netplan configuration to them. netplan declares `enp23s0f0`..`enp23s0f3` as plain ports with `dhcp4: true`
(§2), and nothing in netplan tells `systemd-networkd` that the ports belong to `br-ng`. The bridge itself
was created by `brctl` outside netplan. So two programs own the same ports with conflicting views:
`set_network_bridge_free5gc_251117.sh` puts them in `br-ng`, and `systemd-networkd` treats them as
standalone. The investigation did not read the files that netplan generates under `/run/systemd/network/`,
and it did not read the `systemd-networkd` source, so the exact step that detached the ports is not
demonstrated.

The defect is that ownership conflict, and it is still present. Any restart of `systemd-networkd` while
`cn` keeps running can detach the ports again. A reboot does not, because the user re-runs
`set_network_bridge_free5gc_251117.sh` after every power-on.

## SECTION 5. Trigger — what changed to make this bug surface

**The defect was always there and was never reached until 2026-10-15.** `br-ng` has been built outside
netplan since `set_network_bridge_free5gc_251117.sh` was written, and the conflict with the netplan port
definitions needs a restart of `systemd-networkd` without a reboot. That restart came from
`unattended-upgrade`, as recorded in `/var/log/apt/history.log` on `cn`:

```
Start-Date: 2026-10-15  06:42:36
Commandline: /usr/bin/unattended-upgrade
Upgrade: libpam-systemd:amd64 (249.11-0ubuntu3.22, 249.11-0ubuntu3.23), libsystemd0:amd64 (249.11-0ubuntu3.22, 249.11-0ubuntu3.23), libnss-systemd:amd64 (249.11-0ubuntu3.22, 249.11-0ubuntu3.23), systemd:amd64 (249.11-0ubuntu3.22, 249.11-0ubuntu3.23), systemd-sysv:amd64 (249.11-0ubuntu3.22, 249.11-0ubuntu3.23)
End-Date: 2026-10-15  06:42:39
```

The same `unattended-upgrade` run also upgraded `udev` (06:43:05) and `openssh-server` (06:43:50).

The change the user suspected, the PLAT auto-enable in `run_free5gc`, coincided with the failure only
because free5gc had not been restarted between the upgrade and the test. The last known-good state is not
recorded as a DU registration. The nearest evidence is that `192.168.0.2` had been active on `br-ng` for
214542 seconds up to 06:42:43, which covers the Jool runs at `Oct 14 16:57:18` and `Oct 14 16:58:54`.

The bug comes back on any of these: an `apt upgrade` run by hand that includes `systemd` or `udev`, a
`netplan apply`, or a `systemctl restart systemd-networkd`.

## SECTION 6. The fix — what was changed, location, diff, revert

**Restore the link (on `cn`, by hand, not persistent across a reboot or a `systemd-networkd` restart).**
Re-attach the four ports to `br-ng`. The addresses stay where they are, so the running AMF and UPF keep their
sockets and free5gc does not need a restart:

```
for i in enp23s0f0 enp23s0f1 enp23s0f2 enp23s0f3; do ip link set $i master br-ng; done
```

Re-running `set_network_bridge_free5gc_251117.sh` also restores the ports. That script deletes and rebuilds
`br-ng`, so `run_free5gc` must be run again after it.

**Remove the trigger (on `cn`, persistent).** Automatic package upgrades were turned off:

```
systemctl disable --now apt-daily-upgrade.timer
sed -i 's/^APT::Periodic::Unattended-Upgrade "1";/APT::Periodic::Unattended-Upgrade "0";/' /etc/apt/apt.conf.d/20auto-upgrades
```

`apt-daily-upgrade.timer` starts `apt-daily-upgrade.service`, which runs `unattended-upgrade`. The `sed`
line also turns off `unattended-upgrade` in its own setting, so a timer that is turned back on still installs
nothing. `apt-daily.timer` was left on, because it only refreshes the package lists and installs nothing.

Revert:

```
systemctl enable --now apt-daily-upgrade.timer
sed -i 's/^APT::Periodic::Unattended-Upgrade "0";/APT::Periodic::Unattended-Upgrade "1";/' /etc/apt/apt.conf.d/20auto-upgrades
```

**Detect it before starting free5gc (in `/home/loren/Downloads/log/bootup-scripts/cn/bashrc_cn.sh`, not
committed, because that directory is not a git repository).** A new function `check_br_ng_ports` stops
`run_free5gc` when `br-ng` is missing or any of its four ports is not a member, and prints the command that
fixes it. `/home/loren/Downloads/log/bootup-scripts/cn/bashrc_cn.sh:309-333`:

```
# Check that enp23s0f0..enp23s0f3 are ports of the bridge br-ng.
# br-ng holds the AMF N2 address 192.168.0.2 and the UPF N3 address 5.5.5.2.
# A systemd-networkd restart (for example an apt upgrade of systemd) removes the ports from br-ng,
# and then the CU gets no ARP reply for 192.168.0.2 and sends F1SetupFailure to the DU.
# Usage: check_br_ng_ports
check_br_ng_ports(){
  local ng_bridge=br-ng
  local missing_ports=()
  local port
  if ! ip link show "$ng_bridge" >/dev/null 2>&1; then
    echo "check_br_ng_ports: $ng_bridge does not exist. Run set_network_bridge_free5gc_251117.sh first."
    return 1
  fi
  for port in enp23s0f0 enp23s0f1 enp23s0f2 enp23s0f3; do
    if ! ip -o link show master "$ng_bridge" | grep -q ": $port:"; then
      missing_ports+=("$port")
    fi
  done
  if [ ${#missing_ports[@]} -gt 0 ]; then
    echo "check_br_ng_ports: ${missing_ports[*]} not in $ng_bridge, so the CU cannot reach 192.168.0.2. Add them back first:"
    echo "    for i in ${missing_ports[*]}; do ip link set \$i master $ng_bridge; done"
    return 1
  fi
  echo "check_br_ng_ports: all ports are in $ng_bridge"
}
```

`run_free5gc` calls it after loading `gtp5g` and before restarting the PLAT, `/home/loren/Downloads/log/bootup-scripts/cn/bashrc_cn.sh:368-369`:

```
    echo -e "\n========== Check br-ng Bridge Ports =========="
    check_br_ng_ports || return 1
```

Revert: delete the function and those two lines.

**Deliberately not done.** The ownership conflict in §4 was not removed.

- **Declaring `br-ng` in netplan was rejected by the user on 2026-10-15.** The user prefers to bring
  `br-ng` up by hand with `set_network_bridge_free5gc_251117.sh` after every power-on, so the bridge stays
  outside netplan.
- **Removing `enp23s0f0`..`enp23s0f3` from `/etc/netplan/00-installer-config.yaml` was not done and not
  decided.** It keeps the script as the way `br-ng` is built. §13 records it.

## SECTION 7. Verified — how the fix was proven

After the re-attach loop, on `cn`:

```
[root@75N0-01N0SA-sled2-CN free5gc]#   ip link show master br-ng
3: enp23s0f0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc mq master br-ng state DOWN mode DEFAULT group default qlen 1000
    link/ether f0:b2:b9:0a:3b:e0 brd ff:ff:ff:ff:ff:ff
4: enp23s0f1: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc mq master br-ng state DOWN mode DEFAULT group default qlen 1000
    link/ether f0:b2:b9:0a:3b:e1 brd ff:ff:ff:ff:ff:ff
5: enp23s0f2: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc mq master br-ng state DOWN mode DEFAULT group default qlen 1000
    link/ether f0:b2:b9:0a:3b:e2 brd ff:ff:ff:ff:ff:ff
6: enp23s0f3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq master br-ng state UP mode DEFAULT group default qlen 1000
    link/ether f0:b2:b9:0a:3b:e3 brd ff:ff:ff:ff:ff:ff
[root@75N0-01N0SA-sled2-CN free5gc]#   ip -br link show br-ng
br-ng            UP             06:09:5b:0e:da:bd <BROADCAST,MULTICAST,UP,LOWER_UP> 
```

The user then reported "DU registered now". free5gc was not restarted. No CU capture of the successful F1
Setup was saved.

The trigger removal was checked on `cn`:

```
[root@75N0-01N0SA-sled2-CN free5gc]#   systemctl disable --now apt-daily-upgrade.timer
Removed /etc/systemd/system/timers.target.wants/apt-daily-upgrade.timer.
[root@75N0-01N0SA-sled2-CN free5gc]#   sed -i 's/^APT::Periodic::Unattended-Upgrade "1";/APT::Periodic::Unattended-Upgrade "0";/' /etc/apt/apt.conf.d/20auto-upgrades
[root@75N0-01N0SA-sled2-CN free5gc]#   systemctl is-enabled apt-daily-upgrade.timer
disabled
[root@75N0-01N0SA-sled2-CN free5gc]#   systemctl is-active apt-daily-upgrade.timer
inactive
[root@75N0-01N0SA-sled2-CN free5gc]#   grep Unattended /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Unattended-Upgrade "0";
```

**Not verified on `cn`:** `check_br_ng_ports`. The edited `bashrc_cn.sh` passed `bash -n` on the workstation,
and the port pattern was tested against the `enp23s0f3` line from the output above:

```
syntax OK
enp23s0f3 matched
enp23s0f0 correctly not matched
```

The function has not been run on `cn`, and it has not been run against a `br-ng` with missing ports.

## SECTION 8. Handoff — Ownership — who owns each defect, and the evidence that assigns ownership

**Not applicable.** The defect is in the network setup of the lab `cn` host, which the user owns. The
`systemd` upgrade only exposed it.

## SECTION 9. Handoff — Demonstration — how to prove the defect belongs to a third party

**Not applicable.** No third party owns the defect, so no exhibit set is needed.

## SECTION 10. Handoff — Stopgap — how to keep running until the owner ships a fix

**Not applicable.** No external owner has to ship a fix. The manual re-attach is described in §6.

## SECTION 11. Ruled out — dead hypotheses

- **The PLAT auto-enable (Jool NAT64 and unbound DNS64).** `run_plat` changes only forwarding sysctls, an
  address on `lo`, the Jool module and unbound. `/home/loren/Downloads/log/bootup-scripts/cn/bashrc_cn.sh:210-213`:

  ```
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
    # "replace" adds the address, or keeps it if it already exists
    ip -6 addr replace "$dns64_addr"/128 dev lo
  ```

  `jool.service` only runs `/sbin/modprobe jool` and `/usr/bin/jool file handle /etc/jool/jool.conf`. The Jool
  instance runs in `netfilter` mode, and the only `nft` rule is the masquerade on `enp5s0`. The Jool runs on
  `Oct 14 16:57:18` and `Oct 14 16:58:54` happened while `192.168.0.2` stayed active on `br-ng` until
  06:42:43 on Oct 15.
- **The AMF not listening.** `free5gc.log` shows `Listen on 192.168.0.2:38412`.
- **An ARP sysctl, an `arptables` rule or an `nft` filter on `cn`.** All `arp_ignore`, `arp_filter` and
  `arp_announce` values were `0`; `arptables` was empty with policy `ACCEPT`; `nft` held only the NAT
  masquerade rule.
- **The address in another network namespace.** `ip netns list` printed nothing.
- **A DU or CU configuration change.** The user changed neither, and the CU dialled the configured AMF
  address `192.168.0.2`.
- **A `netplan apply` run by a person.** `apt/history.log` shows the 06:42 activity came from
  `/usr/bin/unattended-upgrade`, and the `systemd-networkd` restart at 06:42:38 falls inside that upgrade's
  `06:42:36`–`06:42:39` window.

## SECTION 12. Traps — what slowed the debugging down, and how to avoid the same delay next time

- **`F1SetupFailure` points at the DU and the CU, but the fault was two hops further on.** Filter the CU
  capture for SCTP and ICMP toward the AMF before looking at F1 itself. An SCTP `INIT` with no `INIT_ACK`
  moves the search to the N2 link at once.
- **The most recent change made by a person was not the change that broke it.** The PLAT auto-enable was
  suspected because the user made it shortly before the failure, while the real change was an automatic
  upgrade made by nobody. Read `/var/log/apt/history.log` early whenever something breaks on a host that
  nobody touched.
- **`free5gc.log` and `ip -br addr` both look healthy.** The AMF binds successfully and the addresses are
  present on `br-ng`, even though the bridge has no path to the wire. Check `ip -br link show br-ng` for
  `NO-CARRIER`.
- **`bridge link` looks like a list of bridge members, but it is not.** On `cn` it lists all four
  `enp23s0f*` ports with `hwmode VEPA` whether or not they belong to `br-ng`. Use `ip link show master
  br-ng`, which prints nothing when the bridge has no ports.
- **The full journal around 06:42 was filled with `open5gs-seppd` DEBUG lines**, so `head -80` showed only
  the first minute of the window. Query `journalctl -u systemd-networkd` and `/var/log/apt/history.log`
  directly instead.

## SECTION 13. Open / not done — known gaps, what is left, and the next step

- **(Highest value) Known defect, accepted: the ownership conflict over `enp23s0f0`..`enp23s0f3` is still
  present.** `br-ng` is built by `brctl`, while netplan declares its ports as standalone DHCP ports. On
  2026-10-15 the user rejected declaring `br-ng` in netplan and chose to keep bringing it up by hand with
  `set_network_bridge_free5gc_251117.sh`. The conflict is therefore kept as a known risk. Three measures
  limit that risk: `apt-daily-upgrade.timer` is disabled, `check_br_ng_ports` stops `run_free5gc` when ports
  are missing, and the script runs again after every power-on. One option that keeps the script remains
  open and untested: remove the four `enp23s0f*` entries from `/etc/netplan/00-installer-config.yaml`, so
  that `systemd-networkd` stops configuring the ports. Next step, if that option is chosen: remove the
  entries, run `systemctl restart systemd-networkd` on `cn`, and confirm `ip link show master br-ng` still
  lists all four ports.
- **Hypothesis: the exact `systemd-networkd` step that detached the ports is not proven** (§4). Next step:
  read the files netplan generates for the ports under `/run/systemd/network/` on `cn`, then restart
  `systemd-networkd` and watch `ip monitor link` for the moment the `master br-ng` attribute disappears.
- **Not done: `check_br_ng_ports` has not been run on `cn`** (§7). Next step: copy the edited
  `bashrc_cn.sh` to `cn`, detach one port with `ip link set enp23s0f0 nomaster`, run `check_br_ng_ports` and
  confirm it names `enp23s0f0`, then re-attach the port.
- **Not version-controlled:** `/home/loren/Downloads/log/bootup-scripts` is not a git repository, so the
  `check_br_ng_ports` change has no history.
- **Unexplained:** `ntpd` logged `Deleting interface #9 br-ng:NGC, 192.168.0.2` at 06:42:43, yet
  `192.168.0.2/24` was present on `br-ng` when checked after 11:10. Whether the address was really removed
  and later re-added, or `ntpd` dropped it only because `br-ng` lost carrier, was not established.
- **Unexplained:** during this session, `my-ssh --target cn` exited at once and the user reported that SSH to
  `cn` might be failing. The `openssh-server` upgrade at 06:43:50 in the same `unattended-upgrade` run is a
  hypothesis that was not checked.
- **Manual upgrades still trigger it.** Automatic upgrades are off, but an `apt upgrade` run by hand that
  includes `systemd` or `udev` restarts `systemd-networkd`. While `enp23s0f0`..`enp23s0f3` stay in netplan,
  run `check_br_ng_ports` or the §0 check command after every such upgrade, and after any `netplan apply`.

## SECTION 14. Related — other docs connected to this doc

- `2026-10-14_wnc_HOWTO_enable_plat_nat64_dns64_on_cn_VIA_jool_on_upf_host_and_dns64_addr_in_smfcfg_AVOID_upfcfg_ra_dns_list_not_sent_to_ue.md`
  sets up the PLAT on `cn`. That change was first suspected for this failure and was ruled out in §11.
- `2026-10-14_wnc_FINDING_plat_464xlat_on_cn_NAMELY_jool_translates_64_ff9b_96_to_ipv4_VS_unbound_dns64_answers_64_ff9b_addr_for_ipv4_only_names.md`
  explains what Jool and unbound do on `cn`, which is the background for ruling the PLAT out.
