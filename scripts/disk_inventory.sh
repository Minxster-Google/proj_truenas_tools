#!/bin/bash
# TrueNAS Disk Inventory Script - IMPROVED VERSION
# Generates a table of all disks with enclosure/slot info, SMART status, and health
# Improvements:
# - Fixed Drive Type parsing
# - Serial number-based device mapping
# - SMART health status checking
# - ZPool status cross-reference

OUTPUT_FILE="/mnt/RaidZ3/local_TrueNAS_scripts/HDD_Info/disk_inventory_$(date +%Y%m%d_%H%M%S).txt"
HTML_FILE="/mnt/RaidZ3/local_TrueNAS_scripts/HDD_Info/disk_inventory_$(date +%Y%m%d_%H%M%S).html"
LOG_FILE="/mnt/RaidZ3/local_TrueNAS_scripts/HDD_Info/disk_inventory.log"

# Enable debug mode by setting DEBUG=1
DEBUG=${DEBUG:-0}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

debug() {
    if [ "$DEBUG" = "1" ]; then
        echo "[DEBUG] $1" >&2
    fi
}

log "Starting disk inventory (improved version)..."

# Get sas3ircu output
SAS3IRCU_OUTPUT=$(sas3ircu 0 display 2>/dev/null)
if [ $? -ne 0 ]; then
    log "ERROR: sas3ircu 0 display failed"
    exit 1
fi

# Declare associative arrays
declare -A DISK_STATE
declare -A DISK_SAS_ADDR
declare -A DISK_MODEL
declare -A DISK_SERIAL
declare -A DISK_SIZE_MB
declare -A DISK_TYPE
declare -A DISK_FW_REV
declare -A DEVICE_SERIAL_MAP  # Maps serial -> /dev/sdX
declare -A DISK_TEMPERATURE
declare -A DISK_HEALTH
declare -A DISK_ZPOOL_STATUS

ENCLOSURE_MAX_SLOT=25

# Parse sas3ircu output
parse_sas3ircu() {
    local in_device=0
    local enclosure=""
    local slot=""

    while IFS= read -r line; do
        line_trimmed=$(echo "$line" | sed 's/^[[:space:]]*//')
        
        if [[ "$line_trimmed" == "Device is a Hard disk" ]]; then
            in_device=1
            continue
        fi

        if [[ $in_device -eq 1 ]]; then
            case "$line_trimmed" in
                Enclosure*)
                    enclosure=$(echo "$line_trimmed" | cut -d: -f2 | tr -d ' ')
                    ;;
                Slot*)
                    slot=$(echo "$line_trimmed" | cut -d: -f2 | tr -d ' ')
                    ;;
                SAS\ Address*)
                    DISK_SAS_ADDR["${enclosure}:${slot}"]=$(echo "$line_trimmed" | cut -d: -f2 | tr -d ' ')
                    ;;
                State*)
                    state=$(echo "$line_trimmed" | cut -d: -f2- | sed 's/^[[:space:]]*//' | tr -d ' ')
                    DISK_STATE["${enclosure}:${slot}"]="$state"
                    ;;
                Size*)
                    size_mb=$(echo "$line_trimmed" | grep -oE '[0-9,]+' | head -1 | tr -d ',')
                    DISK_SIZE_MB["${enclosure}:${slot}"]=$size_mb
                    ;;
                Model\ Number*)
                    model=$(echo "$line_trimmed" | cut -d: -f2- | sed 's/^[[:space:]]*//' | tr -d ' ')
                    DISK_MODEL["${enclosure}:${slot}"]="${model:0:50}"
                    ;;
                Serial\ No*)
                    serial=$(echo "$line_trimmed" | cut -d: -f2- | sed 's/^[[:space:]]*//' | tr -d ' ')
                    DISK_SERIAL["${enclosure}:${slot}"]="${serial:0:20}"
                    ;;
                Firmware\ Revision*)
                    fw=$(echo "$line_trimmed" | cut -d: -f2- | sed 's/^[[:space:]]*//' | tr -d ' ')
                    DISK_FW_REV["${enclosure}:${slot}"]="$fw"
                    ;;
                GUID*)
                    # Don't exit yet - Drive Type comes after GUID
                    ;;
                "Drive Type"*)
                    # FIXED: Use quoted pattern to match "Drive Type" correctly
                    # This comes AFTER GUID in the output, so we process it but then exit
                    dtype=$(echo "$line_trimmed" | cut -d: -f2 | sed 's/^[[:space:]]*//' | tr -d ' ')
                    DISK_TYPE["${enclosure}:${slot}"]="$dtype"
                    debug "Found Drive Type: $dtype for slot $slot"
                    in_device=0  # Exit after Drive Type (last field we care about)
                    ;;
            esac
        fi
    done <<< "$SAS3IRCU_OUTPUT"
}

# Build serial number to device map
build_device_serial_map() {
    log "Building device-to-serial map (this may take 30-60 seconds)..."
    local count=0
    local total=0
    
    # Count total devices first
    for dev in /dev/sd*; do
        [[ "$dev" =~ [0-9]$ ]] && continue
        [ -b "$dev" ] || continue
        ((total++))
    done
    
    for dev in /dev/sd*; do
        # Skip partitions (only whole disks)
        [[ "$dev" =~ [0-9]$ ]] && continue
        
        # Check if block device exists
        [ -b "$dev" ] || continue
        
        ((count++))
        echo -ne "\rScanning devices: $count/$total..." >&2
        
        # Get serial from smartctl
        serial=$(smartctl -i "$dev" 2>/dev/null | grep -i "serial number" | awk '{print $NF}' | tr -d ' ')
        
        if [ -n "$serial" ]; then
            DEVICE_SERIAL_MAP["$serial"]="$dev"
            debug "Mapped serial $serial -> $dev"
        fi
    done
    echo -e "\rFound ${#DEVICE_SERIAL_MAP[@]} devices with serial numbers      " >&2
    log "Device mapping complete: ${#DEVICE_SERIAL_MAP[@]} devices"
}

# Get temperature and health using serial number
get_smart_data() {
    local serial="$1"
    local dev="${DEVICE_SERIAL_MAP[$serial]:-}"
    
    if [ -z "$dev" ]; then
        debug "No device found for serial $serial"
        DISK_TEMPERATURE["$serial"]="-"
        DISK_HEALTH["$serial"]="UNKNOWN"
        return
    fi
    
    debug "Getting SMART data for $dev (serial: $serial)"
    
    # Get SMART data in one call for efficiency
    local smart_output=$(smartctl -AH "$dev" 2>/dev/null)
    
    # Extract temperature
    local temp=$(echo "$smart_output" | grep -iE "temperature|airflow" | head -1 | awk '{print $10}')
    if [ -z "$temp" ] || [ "$temp" == "0" ]; then
        temp="-"
    fi
    DISK_TEMPERATURE["$serial"]="$temp"
    
    # Extract health status
    local health=$(echo "$smart_output" | grep -i "SMART overall-health" | awk '{print $NF}')
    
    if [ -z "$health" ]; then
        # Try alternative format
        health=$(echo "$smart_output" | grep -i "test result" | awk '{print $NF}')
    fi
    
    # Check critical SMART attributes
    if [ "$health" == "PASSED" ]; then
        local realloc=$(echo "$smart_output" | grep "Reallocated_Sector" | awk '{print $10}')
        local pending=$(echo "$smart_output" | grep "Current_Pending_Sector" | awk '{print $10}')
        local uncorrect=$(echo "$smart_output" | grep "Offline_Uncorrectable" | awk '{print $10}')
        
        if [ -n "$realloc" ] && [ "$realloc" -gt 0 ]; then
            health="WARN:REALLOC($realloc)"
        elif [ -n "$pending" ] && [ "$pending" -gt 0 ]; then
            health="WARN:PENDING($pending)"
        elif [ -n "$uncorrect" ] && [ "$uncorrect" -gt 0 ]; then
            health="WARN:UNCORRECT($uncorrect)"
        else
            health="PASSED"
        fi
    else
        health="${health:-UNKNOWN}"
    fi
    
    DISK_HEALTH["$serial"]="$health"
    debug "SMART data: temp=$temp, health=$health"
}

# Check ZPool status for each device
check_zpool_status() {
    log "Checking ZPool status..."
    local zpool_output=$(zpool status 2>/dev/null)
    
    for serial in "${!DEVICE_SERIAL_MAP[@]}"; do
        local dev="${DEVICE_SERIAL_MAP[$serial]}"
        local dev_basename=$(basename "$dev")
        
        # Check if device appears in zpool status
        if echo "$zpool_output" | grep -q "$dev_basename"; then
            if echo "$zpool_output" | grep "$dev_basename" | grep -qi "DEGRADED\|FAULTED\|UNAVAIL"; then
                DISK_ZPOOL_STATUS["$serial"]="ISSUE"
                debug "ZPool issue detected for $dev_basename"
            elif echo "$zpool_output" | grep "$dev_basename" | grep -qi "ONLINE"; then
                DISK_ZPOOL_STATUS["$serial"]="ONLINE"
            else
                DISK_ZPOOL_STATUS["$serial"]="UNKNOWN"
            fi
        else
            DISK_ZPOOL_STATUS["$serial"]="NOT_IN_POOL"
        fi
    done
    log "ZPool status check complete"
}

format_size_mb() {
    local size_mb=$1
    local size_gb=$((size_mb / 1024))

    if [ $size_gb -ge 1000 ]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $size_gb / 1024}")TB"
    else
        echo "${size_gb}GB"
    fi
}

# Main execution
parse_sas3ircu
log "Found ${#DISK_MODEL[@]} disks in sas3ircu output"

build_device_serial_map

# Get SMART data for all disks
log "Collecting SMART data for all disks..."
for slot in $(seq 0 $((ENCLOSURE_MAX_SLOT - 1))); do
    key="2:${slot}"
    if [ -n "${DISK_SERIAL[$key]:-}" ]; then
        serial="${DISK_SERIAL[$key]}"
        get_smart_data "$serial"
    fi
done

check_zpool_status

# Generate report
{
    echo "=============================================="
    echo "TrueNAS Disk Inventory Report (IMPROVED)"
    echo "Generated: $(date)"
    echo "=============================================="
    echo ""
    echo "ENCLOSURE #2 (Main Chassis) - ${ENCLOSURE_MAX_SLOT} slots total"
    echo "----------------------------------------------"
    printf "%-5s | %-12s | %-25s | %-10s | %-8s | %-15s | %-6s | %-12s | %s\n" \
        "SLOT" "STATE" "MODEL" "SIZE" "TYPE" "SERIAL" "TEMP" "HEALTH" "NOTES"
    echo "----------------------------------------------"

    sas_ssd_count=0
    sata_hdd_count=0
    sas_ssd_capacity=0
    sata_hdd_capacity=0
    health_warn_count=0
    health_fail_count=0

    for slot in $(seq 0 $((ENCLOSURE_MAX_SLOT - 1))); do
        key="2:${slot}"

        if [ -n "${DISK_MODEL[$key]:-}" ]; then
            state="${DISK_STATE[$key]:-N/A}"
            model="${DISK_MODEL[$key]:-N/A}"
            size_mb=${DISK_SIZE_MB[$key]:-0}
            size=$(format_size_mb $size_mb)
            dtype="${DISK_TYPE[$key]:-N/A}"
            serial="${DISK_SERIAL[$key]:-N/A}"
            
            # Get temperature and health from cached data
            temp="${DISK_TEMPERATURE[$serial]:-"-"}"
            health="${DISK_HEALTH[$serial]:-"UNKNOWN"}"
            zpool_status="${DISK_ZPOOL_STATUS[$serial]:-"NOT_IN_POOL"}"

            notes=""
            if [[ "$state" == *"Failed"* ]]; then
                notes="FAILED"
            elif [[ "$state" == *"Standby"* ]]; then
                notes="SPIN DOWN"
            fi
            
            # Add ZPool status to notes if there's an issue
            if [[ "$zpool_status" == "ISSUE" ]]; then
                notes="${notes:+$notes, }ZPOOL_ISSUE"
            fi
            
            # Count health warnings/failures
            if [[ "$health" == "WARN"* ]]; then
                ((health_warn_count++))
            elif [[ "$health" == "FAILED" ]]; then
                ((health_fail_count++))
            fi

            if [[ "$dtype" == "SAS_SSD" ]]; then
                dtype="SAS-SSD"
                sas_ssd_count=$((sas_ssd_count + 1))
                sas_ssd_capacity=$((sas_ssd_capacity + size_mb))
            elif [[ "$dtype" == "SATA_HDD" ]]; then
                dtype="SATA-HDD"
                sata_hdd_count=$((sata_hdd_count + 1))
                sata_hdd_capacity=$((sata_hdd_capacity + size_mb))
            fi

            printf "%-5s | %-12s | %-25s | %-10s | %-8s | %-15s | %-6s | %-12s | %s\n" \
                "$slot" "$state" "${model:0:25}" "$size" "$dtype" "${serial:0:15}" "${temp}°C" "$health" "$notes"
        else
            printf "%-5s | %-12s | %-25s | %-10s | %-8s | %-15s | %-6s | %-12s | %s\n" \
                "$slot" "Empty" "(no disk detected)" "-" "-" "-" "-" "-" "-"
        fi
    done

    echo ""
    echo "----------------------------------------------"
    echo "ENCLOSURE SERVICES (Slot 24)"
    echo "----------------------------------------------"
    echo "Slot 24: Enclosure services device (GOOXIBM 4U24SXP)"
    echo ""
    echo "----------------------------------------------"
    echo "DISK SUMMARY BY TYPE"
    echo "----------------------------------------------"
    echo "SAS SSDs: $sas_ssd_count disks ($(format_size_mb $sas_ssd_capacity) total)"
    echo "SATA HDDs: $sata_hdd_count disks ($(format_size_mb $sata_hdd_capacity) total)"
    total_capacity=$((sas_ssd_capacity + sata_hdd_capacity))
    echo "Total Storage: $(format_size_mb $total_capacity)"
    echo ""
    echo "----------------------------------------------"
    echo "HEALTH SUMMARY"
    echo "----------------------------------------------"
    echo "Disks with warnings: $health_warn_count"
    echo "Disks with failures: $health_fail_count"
    echo ""
    echo "----------------------------------------------"
    echo "POTENTIAL FAILED/MISSING DISKS"
    echo "----------------------------------------------"

    failed_count=0
    for slot in $(seq 0 $((ENCLOSURE_MAX_SLOT - 1))); do
        key="2:${slot}"
        if [ -n "${DISK_STATE[$key]:-}" ]; then
            state="${DISK_STATE[$key]}"
            serial="${DISK_SERIAL[$key]}"
            health="${DISK_HEALTH[$serial]:-UNKNOWN}"
            zpool_status="${DISK_ZPOOL_STATUS[$serial]:-NOT_IN_POOL}"
            
            if [[ "$state" == *"Failed"* ]] || [[ "$health" == "FAILED" ]] || [[ "$zpool_status" == "ISSUE" ]]; then
                echo "Slot $slot: ${DISK_MODEL[$key]:-Unknown} - State: $state, Health: $health, ZPool: $zpool_status"
                failed_count=$((failed_count + 1))
            fi
        fi
    done

    if [ $failed_count -eq 0 ]; then
        echo "No failed disks detected"
    fi

    echo ""
    echo "----------------------------------------------"
    echo "DETECTION METHODS USED"
    echo "----------------------------------------------"
    echo "1. sas3ircu 0 display - Primary source for enclosure/slot mapping"
    echo "2. Serial number matching - Correlates physical slots to /dev/sdX devices"
    echo "3. smartctl - Temperature and SMART health data"
    echo "4. zpool status - Pool-level disk status"
    echo ""
    echo "IMPROVEMENTS IN THIS VERSION:"
    echo "- Fixed Drive Type parsing (now correctly detects SAS_SSD, SATA_HDD)"
    echo "- Serial number-based device mapping (more reliable than lsscsi slot order)"
    echo "- SMART health status with critical attribute checking"
    echo "- ZPool status cross-reference"
    echo ""
    echo "Note: Failed disks may not appear in sas3ircu output"
    echo "Check zpool status for complete pool health information"
    echo ""
    echo "=============================================="
    echo "End of Report"
    echo "=============================================="

} | tee "$OUTPUT_FILE"

log "Inventory saved to $OUTPUT_FILE"
log "Disk inventory complete (improved version)"
echo ""
echo "Output files:"
echo "  - $OUTPUT_FILE"
echo ""
echo "Summary:"
echo "  - Total disks: ${#DISK_MODEL[@]}"
echo "  - SAS SSDs: $sas_ssd_count"
echo "  - SATA HDDs: $sata_hdd_count"
echo "  - Health warnings: $health_warn_count"
echo "  - Health failures: $health_fail_count"
