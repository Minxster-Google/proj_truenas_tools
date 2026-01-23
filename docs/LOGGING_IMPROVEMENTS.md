# Logging Improvements - spinpid2_scale.sh

**Date:** January 23, 2026  
**Change:** Implemented date-based logging with automatic cleanup

---

## What Changed

### Before
- Script output was **not logged** by default (commented out `exec` statements)
- Manual runs required explicit `>> spinpid2_scale.log 2>&1` redirection
- Single log file would grow indefinitely if logging was enabled
- No automatic cleanup of old log files
- **CRITICAL:** Lost all historical data when I cleared the log with `>`

### After
- **Automatic daily logging** - each day gets its own file
- **Format:** `spinpid2_scale-YYYY-MM-DD.log` (e.g., `spinpid2_scale-2026-01-23.log`)
- **Automatic cleanup** - logs older than 7 days are deleted
- **Cleanup happens** at startup + periodically during operation (every hour)
- **All output is captured** - fans, temps, IPMI data, errors

---

## Implementation Details

### Config Changes (spinpid2_scale.config)

```bash
# Date-based log files with automatic cleanup
LOG_DATE=$(date +"%Y-%m-%d")
LOG="${LOG_DIR}/spinpid2_scale-${LOG_DATE}.log"

# Enable logging to disk - all output goes to dated log file
exec >> "$LOG" 2>&1
```

**Effect:** All script output (stdout + stderr) automatically goes to dated log file

### Script Changes (spinpid2_scale.sh)

1. **New cleanup function:**
```bash
function cleanup_old_logs {
   find "$LOG_DIR" -name "spinpid2_scale-*.log" -type f -mtime +7 -delete 2>/dev/null
   find "$LOG_DIR" -name "spinpid2_scale-cpu-*.log" -type f -mtime +7 -delete 2>/dev/null
}
```

2. **Cleanup at startup:**
```bash
cleanup_old_logs
echo "$(date '+%Y-%m-%d %H:%M:%S') - Log cleanup completed. Logs older than 7 days removed."
```

3. **Periodic cleanup during operation:**
```bash
CLEANUP_COUNTER=0
CLEANUP_INTERVAL=$(( 60 / DRIVE_T ))  # Every hour

while true ; do
   ((CLEANUP_COUNTER++))
   if [ $CLEANUP_COUNTER -ge $CLEANUP_INTERVAL ]; then
      cleanup_old_logs
      CLEANUP_COUNTER=0
   fi
   ...
done
```

---

## Log File Format

### Location
```
/mnt/RaidZ3/local_TrueNAS_scripts/fan_control/spinpid2_scale-YYYY-MM-DD.log
```

### Contents

Each day's log contains:

1. **Startup banner** - Configuration summary
2. **Drive warnings** - Which disks have SMART errors
3. **Column headers** - Field names (printed daily)
4. **Fan control cycles** - Every 5 minutes with timestamps:

```
00:45:37  *37  *35  *36  *37  *42  ... ^47  38.71  -1.29  -5.16 -10.32   49 Full  50  55  800  1000  1000  1000  ------
```

Columns:
- `00:45:37` - Timestamp
- `*37  *35  ...` - Drive temperatures (24 drives)
- `^47` - Max drive temp
- `38.71` - Mean drive temp
- `-1.29` - Error correction (how far from setpoint)
- `-5.16` - Proportional component (P)
- `-10.32` - Derivative component (D)
- `49` - CPU temp
- `Full` - Fan mode
- `50  55` - CPU and PER duty cycles (%)
- `800  1000  1000  1000  ------` - Fan RPMs (FANA, FAN1-4)

---

## Benefits

| Aspect | Before | After |
|--------|--------|-------|
| **Logging** | Optional, manual | Automatic, always on |
| **Data loss** | Easy (one file cleared) | Protected (daily rotation) |
| **Disk usage** | Unbounded growth | Controlled (7-day retention) |
| **Troubleshooting** | No historical data | Full historical data available |
| **Debugging** | Difficult | Easy - specific dates available |

---

## Retention Policy

- **Keep:** Last 7 days of logs
- **Delete:** Automatically on next run if >7 days old
- **Cleanup:** Runs at startup + every hour during operation
- **Disk space:** ~50-100KB per day (manageable)

---

## Viewing Logs

### Current day's log
```bash
tail -50 /mnt/RaidZ3/local_TrueNAS_scripts/fan_control/spinpid2_scale-2026-01-23.log
```

### Specific date
```bash
tail -50 /mnt/RaidZ3/local_TrueNAS_scripts/fan_control/spinpid2_scale-2026-01-22.log
```

### All logs
```bash
ls -lh /mnt/RaidZ3/local_TrueNAS_scripts/fan_control/spinpid2_scale-*.log
```

### Search across dates
```bash
grep "ERROR" /mnt/RaidZ3/local_TrueNAS_scripts/fan_control/spinpid2_scale-*.log
```

---

## File Examples

### File naming
```
spinpid2_scale-2026-01-23.log   (created today)
spinpid2_scale-2026-01-22.log   (yesterday)
spinpid2_scale-2026-01-21.log   (3 days ago)
...
spinpid2_scale-2026-01-17.log   (7 days ago - will be deleted tomorrow)
spinpid2_scale-2026-01-16.log   (8+ days ago - deleted at startup)
```

### CPU log (if enabled)
```
spinpid2_scale-cpu-2026-01-23.log
spinpid2_scale-cpu-2026-01-22.log
```

---

## What This Solves

✅ **Prevents accidental data loss** - can't clear 7 days of history with one command  
✅ **Provides historical record** - troubleshoot issues days later  
✅ **Automatic cleanup** - no manual log management needed  
✅ **Organized** - easy to find logs by date  
✅ **Safe size limits** - can't grow to GB sizes  

---

## Important Notes

1. **Cleanup happens automatically** - no user action needed
2. **7-day retention is hardcoded** - can be changed in cleanup function if needed
3. **Log cleanup at startup** - old logs deleted when script starts each morning
4. **Periodic cleanup** - also runs every hour to catch logs turning 8+ days old mid-day
5. **No data loss risk** - must explicitly delete files to lose data

---

## Testing the Logging

To verify logging is working:

```bash
# Check if today's log exists and has data
ls -lh /mnt/RaidZ3/local_TrueNAS_scripts/fan_control/spinpid2_scale-$(date +%Y-%m-%d).log

# View recent entries
tail -20 /mnt/RaidZ3/local_TrueNAS_scripts/fan_control/spinpid2_scale-$(date +%Y-%m-%d).log

# Check for IPMI data (should show fan speeds)
grep "FANA" /mnt/RaidZ3/local_TrueNAS_scripts/fan_control/spinpid2_scale-$(date +%Y-%m-%d).log | tail -1
```

---

## Future Improvements (Optional)

- Compression of logs older than 3 days (`.gz`) to save space
- Sending alerts if cleanup fails or disk space runs low
- Log rotation via logrotate (if preferred over custom cleanup)
- Parsing logs for analytics/reporting
