#!/bin/bash

# Diagnostic Script for IPMI CPU Load Investigation
# Purpose: Determine if spinpid2_scale.sh is causing high IPMI CPU utilization
# Usage: Run on TrueNAS system via SSH

set -euo pipefail

echo "=========================================="
echo "TrueNAS IPMI Load Diagnostic"
echo "=========================================="
echo "Date: $(date)"
echo ""

# Source the config file for IPMI connection details
SCRIPT_DIR="/mnt/RaidZ3/local_TrueNAS_scripts/fan_control"
CONFIG_FILE="${SCRIPT_DIR}/spinpid2_scale.config"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found at $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

echo "1. CHECKING IF SCRIPT IS RUNNING"
echo "=================================="
if pgrep -f "spinpid2_scale.sh" > /dev/null; then
    SCRIPT_PID=$(pgrep -f "spinpid2_scale.sh" | head -1)
    echo "✓ Script IS RUNNING (PID: $SCRIPT_PID)"
    ps aux | grep -E "spinpid2_scale|$$" | grep -v grep
else
    echo "✗ Script is NOT running"
fi
echo ""

echo "2. CHECKING SYSTEMD SERVICE STATUS"
echo "===================================="
if systemctl list-units --all | grep -q "ix-postinit"; then
    echo "ix-postinit service status:"
    systemctl status ix-postinit --no-pager || echo "(Service info unavailable)"
else
    echo "ix-postinit service not found"
fi
echo ""

echo "3. CHECKING FOR IPMITOOL PROCESSES"
echo "==================================="
if pgrep -f "ipmitool" > /dev/null; then
    echo "✓ ipmitool processes found:"
    ps aux | grep ipmitool | grep -v grep || true
    IPMITOOL_COUNT=$(pgrep -f "ipmitool" | wc -l)
    echo "Total ipmitool processes: $IPMITOOL_COUNT"
else
    echo "✗ No ipmitool processes running"
fi
echo ""

echo "4. TESTING IPMI CONNECTIVITY"
echo "============================="
echo "IPMI Host: $IPMI_HOST"
echo "Testing connection and measuring latency..."

# Test 1: Simple ping to IPMI host
if ping -c 1 -W 2 "$IPMI_HOST" &>/dev/null; then
    echo "✓ IPMI host is reachable"
else
    echo "✗ IPMI host is NOT reachable"
fi

# Test 2: Try a simple IPMI command with timing
echo "Testing 'ipmitool raw 0x06 0x01' (Get Device ID)..."
START_TIME=$(date +%s%N)
if $IPMITOOL raw 0x06 0x01 >/dev/null 2>&1; then
    END_TIME=$(date +%s%N)
    ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))
    echo "✓ IPMI command succeeded in ${ELAPSED_MS}ms"
else
    echo "✗ IPMI command failed"
fi
echo ""

echo "5. MEASURING IPMITOOL COMMAND OVERHEAD"
echo "======================================"
echo "Running 5 iterations of each IPMI command type..."
echo ""

# Test SDR command (the expensive one)
echo "A) SDR command (Sensor Data Repository - EXPENSIVE):"
TOTAL_MS=0
for i in {1..5}; do
    START=$(date +%s%N)
    $IPMITOOL sdr > /dev/null 2>&1
    END=$(date +%s%N)
    MS=$(( (END - START) / 1000000 ))
    echo "  Iteration $i: ${MS}ms"
    TOTAL_MS=$((TOTAL_MS + MS))
done
AVG_MS=$(( TOTAL_MS / 5 ))
echo "  Average: ${AVG_MS}ms per call"
echo ""

# Test raw command (less expensive)
echo "B) Raw command (Get sensor reading - CHEAPER):"
TOTAL_MS=0
for i in {1..5}; do
    START=$(date +%s%N)
    $IPMITOOL raw 0x30 0x45 0 > /dev/null 2>&1
    END=$(date +%s%N)
    MS=$(( (END - START) / 1000000 ))
    echo "  Iteration $i: ${MS}ms"
    TOTAL_MS=$((TOTAL_MS + MS))
done
AVG_MS=$(( TOTAL_MS / 5 ))
echo "  Average: ${AVG_MS}ms per call"
echo ""

echo "6. ANALYZING SCRIPT CONFIGURATION"
echo "=================================="
echo "Current intervals:"
echo "  DRIVE_T (drive check): $DRIVE_T minute(s) = $(( DRIVE_T * 60 )) seconds"
echo "  CPU_T (CPU check): $CPU_T second(s)"
echo ""

CPU_LOOPS=$(awk "BEGIN {printf \"%.0f\", $DRIVE_T * 60 / $CPU_T}")
echo "CPU loops per drive check: $CPU_LOOPS"
echo ""

echo "Calculated IPMI commands per DRIVE_T cycle:"
echo "  - read_fan_data() calls: 2+ (initial + mismatch testing)"
echo "  - Each read_fan_data() calls: ipmitool sdr (expensive)"
echo "  - CPU_check_adjust() loops: $CPU_LOOPS times"
echo "  - Each CPU check: 1 additional ipmitool command"
echo ""

echo "Estimated load with current config:"
echo "  Minimum SDR calls per cycle: $((CPU_LOOPS + 2))"
echo "  If DRIVE_T=1 minute: $(( CPU_LOOPS + 2 )) calls per minute"
echo "  If DRIVE_T=5 minutes: $(( (CPU_LOOPS + 2) / 5 )) calls per minute"
echo ""

echo "7. CHECKING LOG FILES"
echo "====================="
LOG_FILE="${LOG_DIR}/spinpid2_scale.log"
if [ -f "$LOG_FILE" ]; then
    echo "Log file exists: $LOG_FILE"
    echo "File size: $(du -h "$LOG_FILE" | cut -f1)"
    echo "Last 10 lines:"
    tail -10 "$LOG_FILE"
else
    echo "Log file not found"
fi
echo ""

echo "8. CHECKING RECENT IPMITOOL ACTIVITY"
echo "===================================="
echo "Looking for ipmitool in system logs (last 100 lines with 'ipmi')..."
journalctl -n 200 2>/dev/null | grep -i ipmi | tail -10 || echo "(No recent IPMI log entries)"
echo ""

echo "9. RECOMMENDATIONS"
echo "=================="
if pgrep -f "spinpid2_scale.sh" > /dev/null; then
    echo "✓ Script IS RUNNING - likely cause of high IPMI CPU"
    echo ""
    echo "IMMEDIATE ACTIONS:"
    echo "1. Consider temporarily stopping the script:"
    echo "   pkill -f spinpid2_scale.sh"
    echo ""
    echo "2. Monitor IPMI CPU before/after to confirm correlation:"
    echo "   - Check Zabbix dashboard for IPMI CPU % drop"
    echo ""
    echo "LONG-TERM FIXES:"
    echo "1. Increase DRIVE_T from $DRIVE_T to 5 minutes"
    echo "   - Reduces SDR polling by 80%"
    echo ""
    echo "2. Increase CPU_T from $CPU_T to 10-30 seconds"
    echo "   - Reduces CPU loop iterations significantly"
    echo ""
    echo "3. Implement SDR caching"
    echo "   - Avoid re-reading sensor data every cycle"
else
    echo "✗ Script is NOT running"
    echo ""
    echo "If high IPMI CPU persists, investigate other sources:"
    echo "1. Check BMC web interface for other management tools"
    echo "2. Review IPMI system logs for error/retry patterns"
    echo "3. Contact hardware vendor for BMC optimization"
fi
echo ""

echo "=========================================="
echo "Diagnostic Complete"
echo "=========================================="
