# IMMEDIATE ACTION REQUIRED: Duplicate spinpid2_scale.sh Instances

**Date:** January 23, 2026  
**Severity:** 🔴 CRITICAL  
**Impact:** IPMI CPU load is DOUBLED due to two script instances running simultaneously

---

## The Problem

Your TrueNAS system is currently running **TWO instances** of `spinpid2_scale.sh`:

| Instance | PID | Started | CPU Time | Status |
|----------|-----|---------|----------|--------|
| Original | 1754739 | Jan 11 | 46+ hours | Zombie - needs cleanup |
| Duplicate | 3995XXX | Jan 23 00:27 | Minimal | Spawned by POSTINIT task |

**Result:** BMC is servicing IPMI requests from TWO scripts simultaneously, doubling the load.

---

## Immediate Actions (5 minutes)

### Step 1: Identify Both Instances

```bash
ssh root@192.168.1.236
ps aux | grep spinpid2_scale | grep -v grep
```

Note the PIDs - should show two entries.

### Step 2: Kill the Duplicate Instance

The newer instance (lower PID, newer timestamp) is the duplicate:

```bash
# Replace XXXX with the newer PID
kill 3995XXX

# Verify it's gone
ps aux | grep spinpid2_scale | grep -v grep
# Should now show only ONE instance
```

### Step 3: Disable TrueNAS POSTINIT Auto-Start

The duplicate keeps respawning because TrueNAS is configured to auto-start it on boot.

**Option A: Via SSH (Immediate)**

```bash
# Disable the POSTINIT task (ID 3)
midclt call initshutdownscript.update 3 '{"enabled":false}'

# Verify it's disabled
midclt call initshutdownscript.query | grep -A5 '"id": 3'
# Should show "enabled": false
```

**Option B: Via TrueNAS GUI (Persistent)**

1. Login to TrueNAS web interface (192.168.1.236)
2. Navigate to **System** → **Init/Shutdown Scripts**
3. Find the row with **"Auto Fan speeds"** (Comment column)
4. Click the row to edit it
5. **UNCHECK the "Enabled" checkbox**
6. Click **Save**
7. Done - this prevents respawn on next reboot

**⚠️ Important:** The SSH method is temporary - it resets on reboot. Use the GUI method for permanent fix.

### Step 4: Verify Single Instance

```bash
ps aux | grep spinpid2_scale | grep -v grep
# Should show ONLY:
# root     1754739  0.2  0.0   4812  2560 ?  S  Jan11  46:03 /bin/bash ...
# (Should NOT show a second instance)
```

### Step 5: Monitor IPMI CPU in Zabbix

1. Login to Zabbix dashboard
2. Check **IPMI CPU %** for TrueNAS host
3. Wait 5-10 minutes for metrics to update
4. **Expected:** IPMI CPU should drop by ~50% (from 80%+ → ~40%)

---

## Why This Happened

The POSTINIT task in TrueNAS was configured to run:
```bash
/mnt/RaidZ3/local_TrueNAS_scripts/fan_control/spinpid2_scale.sh &
```

This command:
1. Started the script in background when TrueNAS was first set up (Jan 11)
2. **Also ran again today** when someone or something triggered POSTINIT tasks
3. Script has **no locking mechanism**, so second instance started alongside the first
4. Both are now polling IPMI independently, causing 2× the load

---

## Preventing Future Issues

Once duplicates are cleaned up, add instance locking to prevent this in the future.

### Add to spinpid2_scale.sh (after line 32)

```bash
# Prevent duplicate instances
LOCKFILE="/mnt/RaidZ3/local_TrueNAS_scripts/fan_control/spinpid2_scale.lock"
exec 200>"$LOCKFILE"
flock -n 200 || { echo "ERROR: Script already running"; exit 1; }
echo $$ > "$LOCKFILE"
```

This ensures only ONE instance can run at a time, even if started multiple times.

---

## Testing After Fix

### Immediate Check (2 minutes)
```bash
# Verify single instance
ps aux | grep spinpid2_scale | grep -v grep
# Check fan control is still working
cat /mnt/RaidZ3/local_TrueNAS_scripts/fan_control/spinpid2_scale.status
```

### Monitor (next hour)
1. Watch Zabbix IPMI CPU % - should drop significantly
2. Verify drive temps stay normal (38-42°C mean)
3. Check fans respond appropriately to temp changes

### Confirm Persistence (after next reboot)
After you reboot TrueNAS:
```bash
ps aux | grep spinpid2_scale | grep -v grep
# Should show ONLY ONE instance (or none if permanently disabled)
```

---

## Expected Outcomes

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| IPMI CPU % | 80%+ | ~40% | 50% reduction |
| Fan Control | Working | Working | No change (just less load) |
| Drive Temps | Normal | Normal | No change |
| BMC Responsiveness | Slow | Responsive | Much better |

---

## If You Still See High IPMI CPU After Fix

After removing the duplicate:

1. **Check for instance lock failure:**
   ```bash
   ps aux | grep spinpid2_scale | wc -l
   # Should be exactly 2 (one grep + one script)
   ```

2. **Monitor actual IPMI commands:**
   ```bash
   # Watch ipmitool processes
   watch -n 1 "ps aux | grep ipmitool | grep -v grep | wc -l"
   # Should be 0-2 at any given time, not continuous
   ```

3. **If still high**, the remaining single instance polling is the issue. Then optimize:
   - Increase DRIVE_T from 1 to 5 minutes
   - Increase CPU_T from 1 to 30 seconds
   - Implement SDR caching (see IPMI_CPU_LOAD_ANALYSIS.md)

---

## Reference

- **Analysis:** `/opt/opencode_master/proj_truenas_tools/docs/IPMI_CPU_LOAD_ANALYSIS.md`
- **Optimized Script:** `/opt/opencode_master/proj_truenas_tools/scripts/fan_control/spinpid2_scale_optimized.sh`
- **Original Script:** `/mnt/RaidZ3/local_TrueNAS_scripts/fan_control/spinpid2_scale.sh`
- **Status File:** `/mnt/RaidZ3/local_TrueNAS_scripts/fan_control/spinpid2_scale.status`
