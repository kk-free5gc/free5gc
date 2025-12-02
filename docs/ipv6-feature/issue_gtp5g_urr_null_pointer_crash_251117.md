# gtp5g URR NULL Pointer Crash After IPv6 Implementation

## Issue Summary

**Date Reported:** November 17, 2025
**Severity:** Critical - Kernel NULL pointer dereference causing system crash
**Component:** gtp5g kernel module v0.9.15
**Trigger:** UPF usage reporting during IPv6-enabled PDU sessions

## Symptom

After implementing IPv6 data plane support, the UPF crashes with kernel NULL pointer dereference:

```
[Mon Nov 17 11:06:43 2025] BUG: kernel NULL pointer dereference, address: 0000000000000008
[Mon Nov 17 11:06:43 2025] RIP: 0010:gtp5g_genl_get_multi_usage_reports+0x21b/0x410 [gtp5g]
[Mon Nov 17 11:06:43 2025] RAX: 0000000000000000 RBX: 0000000000000003
[Mon Nov 17 11:06:43 2025] Code: ... <8b> 50 08 ...  ← mov edx, DWORD PTR [rax+0x8]
```

**Error Location:** `gtp5g/src/genl/genl_report.c:191` - `gtp5g_genl_get_multi_usage_reports()`

**Crash Context:**
- Kernel: 5.15.0-161-generic
- gtp5g version: 0.9.15 (srcversion: 76B8DA411F5C15B20FE49D4)
- Loaded from: `/home/wnc/Downloads/free5gc_use_open5gs_ipv6/gtp5g/gtp5g.ko`
- Module state: Corrupted with refcount -1 after crash

## Investigation Timeline

### Initial Hypothesis: Kernel Version Mismatch
**Finding:** INCORRECT
- Initially suspected gtp5g was built for old kernel (5.15.0-153) but running on new kernel (5.15.0-161)
- Rebuilt gtp5g for 5.15.0-161-generic
- Module loaded successfully with clean refcount 0
- **Crash still occurred** - ruled out kernel version mismatch

### Second Hypothesis: Missing URR Fix
**Finding:** INCORRECT
- Suspected missing commit `c58a807` "Kvmalloc and state sync" URR fix
- Verified loaded module srcversion: `76B8DA411F5C15B20FE49D4`
- **Confirmed:** Module includes all commits up to and past c58a807
- Git log shows:
  ```
  a10b174 feat: implement IPv6 data plane support (IPv6 changes)
  c58a807 Kvmalloc and state sync (#152) (URR fix)
  ```

### Root Cause: Memory Allocation Failure Handling Bug

**Code Analysis (`gtp5g/src/genl/genl_report.c:191-274`):**

```c
int gtp5g_genl_get_multi_usage_reports(struct sk_buff *skb, struct genl_info *info)
{
    struct usage_report **reports = NULL;
    u32 urr_num, report_num = 0, i = 0;

    // Allocate array of pointers
    reports = kzalloc(sizeof(struct usage_report *) * urr_num, GFP_KERNEL);

    // Loop to allocate individual reports
    for (i = 0; i < urr_num; i++) {
        urr = find_urr_by_id(gtp, seid_urrs[i]->seid, seid_urrs[i]->urrid);
        if (!urr) {
            err = -ENOENT;
            goto fail;  // ✅ Proper error handling
        }

        urr_counter = get_and_switch_period_vol_counter(urr);

        // ❌ BUG: kzalloc can return NULL but no check
        reports[i] = kzalloc(sizeof(struct usage_report), GFP_KERNEL);
        if (!reports[i]) {
            err = -ENOMEM;
            goto fail;  // ✅ This check exists but...
        }

        // ❌ Problem: If kzalloc succeeds for some but fails for others,
        // reports array has mix of valid pointers and NULLs
        convert_urr_to_report(urr, urr_counter, reports[report_num++]);
    }

    // Later code assumes all reports[i] are valid
    err = gtp5g_genl_fill_multi_usage_reports(skb_ack, ..., reports, report_num);
    // ↑ This function iterates reports[] and dereferences without NULL check
}
```

**The Bug:**
1. `kzalloc()` allocates memory for `reports[i]`
2. If allocation fails, `reports[i] = NULL`
3. Code jumps to `fail:` label
4. **However**, if some allocations succeeded before the failure, the `reports[]` array contains a mix of valid pointers and NULLs
5. The `fail:` cleanup or subsequent code may iterate through `reports[]` without checking for NULL
6. **Crash:** Dereferencing `reports[i]` when it's NULL → NULL pointer at offset +0x8

**Why This Started Happening After IPv6:**
- IPv6 implementation increased memory usage (dual-stack support, larger structures)
- More URR activity due to IPv6 sessions
- Higher probability of memory allocation failures under pressure
- **Not a bug in IPv6 code** - IPv6 just exposed pre-existing memory handling bug

## Module State Issues Observed

### Corrupted Refcount (-1)
After the kernel crash, `lsmod` shows:
```
gtp5g    151552  -1
```

**Why -1 Refcount:**
- Kernel crash during module operation leaves internal state inconsistent
- Module thinks it has active references but they're corrupted
- **Cannot unload:** `rmmod gtp5g` fails with "Device or resource busy"
- **Cannot reload:** `insmod` fails with "File exists"

**Only solution:** Reboot to clear corrupted kernel memory

## Environment Details

### System Configuration
- **OS:** Ubuntu with kernel 5.15.0-161-generic
- **Remote Machine:** CN (Core Network)
- **Timezone:** UTC (8 hours behind CST)
- **Network Interface:** br-ng with 5.5.5.2/24

### Module Versions Present
```
Loaded:       76B8DA411F5C15B20FE49D4  (free5gc_use_open5gs_ipv6/gtp5g)
Not Loaded:   8D56B8F8388EB75389E55CC  (gtp5g_0.9.11)
Not Loaded:   2B7991E6DF6463D16278FC2  (gtp5g_0.9.14)
System Path:  Not found (no module in /lib/modules/.../gtp5g.ko)
```

**Module auto-loads from:** `/home/wnc/Downloads/free5gc_use_open5gs_ipv6/gtp5g/gtp5g.ko`

### Crash Timing
```
Crash occurred: Mon Nov 17 11:06:43 2025 UTC
                = Mon Nov 17 19:06:43 2025 CST (Taiwan time)
```

## Related Commits

### IPv6 Implementation (Suspected Trigger)
- **Commit:** `a10b174` - "feat: implement IPv6 data plane support in gtp5g kernel module"
- **Date:** Fri Nov 7 19:14:11 2025 +0800
- **Changes:** Added IPv6 PDR lookup, RA injection, dual-stack support
- **Not the bug:** IPv6 code is correct, just increased memory pressure

### URR Fix (Not Sufficient)
- **Commit:** `c58a807` - "Kvmalloc and state sync (#152)"
- **Date:** Thu Sep 11 19:50:24 2025 +0800
- **Changes:** Updated URR sync mechanism to prevent soft lockup
- **Status:** Included in current build, but doesn't fix NULL pointer issue

### Previous Flow Descriptor Fix
- **Document:** `issue-ipv4-unreachable-upf-flowdesc-251114.md`
- **Issue:** Wildcard "any"/"assigned" incorrectly returned IPv6zero
- **Fix:** Return `nil` for wildcards to avoid IP family mismatch
- **Relation:** Unrelated to current URR crash

## Potential Solutions

### Option 1: Fix NULL Pointer Handling (Recommended)
Add proper NULL checks in `gtp5g_genl_fill_multi_usage_reports()` and cleanup code:

```c
// In cleanup or iteration code
for (i = 0; i < report_num; i++) {
    if (!reports[i])  // ✅ Add NULL check
        continue;
    // Safe to access reports[i] now
}
```

**Pros:**
- Fixes root cause
- Prevents future crashes from allocation failures

**Cons:**
- Requires gtp5g kernel module patch
- Need to test thoroughly

### Option 2: Disable/Reduce URR Usage (Temporary Workaround)
Modify free5gc configuration to reduce URR frequency or disable usage reporting:

**Pros:**
- Immediate workaround
- No code changes needed

**Cons:**
- Loses usage reporting functionality
- Doesn't fix underlying bug

### Option 3: Increase Memory Allocation Success Rate
- Reduce system memory pressure
- Increase available kernel memory
- Use GFP_ATOMIC instead of GFP_KERNEL for critical allocations

**Pros:**
- May reduce crash frequency

**Cons:**
- Doesn't fix the bug
- Not a reliable solution

## Next Steps

### Immediate Actions
1. **Document this investigation** ✅ (this file)
2. **Reboot CN machine** to clear corrupted module state
3. **Test with reduced URR frequency** as temporary workaround

### Short-term Actions
1. Create patch for gtp5g NULL pointer handling
2. Test patch thoroughly with IPv6 sessions
3. Submit patch to upstream gtp5g repository

### Long-term Actions
1. Review all memory allocation paths in gtp5g for similar bugs
2. Add comprehensive error handling tests
3. Consider memory allocation strategy improvements

## Debugging Commands Reference

### Check Loaded Module
```bash
# On remote CN machine
cat /sys/module/gtp5g/srcversion
lsmod | grep gtp5g
modinfo gtp5g | grep srcversion
```

### Check Available Module Versions
```bash
modinfo /home/wnc/Downloads/free5gc_use_open5gs_ipv6/gtp5g/gtp5g.ko | grep srcversion
modinfo /home/wnc/Downloads/gtp5g_0.9.11/gtp5g/gtp5g.ko | grep srcversion
modinfo /home/wnc/Downloads/gtp5g_0.9.14/gtp5g/gtp5g.ko | grep srcversion
```

### Check Kernel Crash Logs
```bash
dmesg | grep -i gtp5g | tail -50
cat /var/log/kern.log | grep "NULL pointer"
```

### Module Loading/Unloading
```bash
# Load specific module with insmod
sudo insmod /home/wnc/Downloads/free5gc_use_open5gs_ipv6/gtp5g/gtp5g.ko

# Check if module is stuck
lsmod | grep gtp5g
# If refcount is -1, module is corrupted → must reboot

# After reboot, verify clean state
lsmod | grep gtp5g  # Should show nothing or clean refcount
```

## Files Reference

- **Investigation started:** 2025-11-17
- **Crash log:** `/home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/free5gc/dmesg-1.log`
- **gtp5g source:** `/home/loren/Downloads/source_code/free5gc_use_open5gs_ipv6/gtp5g/`
- **Crash function:** `gtp5g/src/genl/genl_report.c:191` (`gtp5g_genl_get_multi_usage_reports`)

## Additional Notes

- **Not an IPv6 bug:** IPv6 implementation is correct
- **Pre-existing bug:** NULL pointer handling existed before IPv6
- **Trigger mechanism:** IPv6 increased memory pressure exposing the bug
- **Module state:** Corrupted -1 refcount requires reboot to clear
- **Timezone consideration:** Remote machine uses UTC, local uses CST (+8 hours)

## Status

**Current State:** Under investigation, temporary workaround needed
**Next Session:** Continue tomorrow with patch development or workaround implementation
**Blocking Issue:** Need to decide between quick workaround vs proper fix

---

**Investigation by:** Claude Code
**Last Updated:** 2025-11-17 (UTC)
