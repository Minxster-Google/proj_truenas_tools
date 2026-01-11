#!/bin/bash
# TrueNAS Disk Inventory Script
# Displays disk inventory with enclosure/slot info, temperatures, and SMART health

# Enable debug mode by setting DEBUG=1
DEBUG=${DEBUG:-0}

debug() {
    if [ "$DEBUG" = "1" ]; then
        echo "[DEBUG] $1" >&2
    fi
}

echo "Starting disk inventory scan..."

# Get sas3ircu output
SAS3IRCU_OUTPUT=$(sas3ircu 0 display 2>/dev/null)
if [ $? -ne 0 ]; then
    echo "ERROR: sas3ircu 0 display failed"
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
declare -A DISK_WEAR_PERCENT  # SSD wear level
declare -A DISK_POWER_ON_HOURS  # Power on time

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
                Unit\ Serial\ No*)
                    # Use VPD serial (more reliable than "Serial No")
                    vpd_serial=$(echo "$line_trimmed" | cut -d: -f2- | sed 's/^[[:space:]]*//' | tr -d ' ')
                    if [ -n "$vpd_serial" ] && [ "$vpd_serial" != "N/A" ]; then
                        DISK_SERIAL["${enclosure}:${slot}"]="${vpd_serial:0:20}"
                        debug "Using VPD serial: $vpd_serial for slot $slot"
                    fi
                    ;;
                Firmware\ Revision*)
                    fw=$(echo "$line_trimmed" | cut -d: -f2- | sed 's/^[[:space:]]*//' | tr -d ' ')
                    DISK_FW_REV["${enclosure}:${slot}"]="$fw"
                    ;;
                GUID*)
                    # Don't exit yet - Drive Type comes after GUID
                    ;;
                "Drive Type"*)
                    # This comes AFTER GUID in the output
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
    echo -n "Mapping devices to serial numbers... "
    local count=0
    
    for dev in /dev/sd*; do
        # Skip partitions (only whole disks)
        [[ "$dev" =~ [0-9]$ ]] && continue
        
        # Check if block device exists
        [ -b "$dev" ] || continue
        
        # Get serial from smartctl
        serial=$(smartctl -i "$dev" 2>/dev/null | grep -i "serial number" | awk '{print $NF}' | tr -d ' ')
        
        if [ -n "$serial" ]; then
            DEVICE_SERIAL_MAP["$serial"]="$dev"
            ((count++))
            debug "Mapped serial $serial -> $dev"
        fi
    done
    echo "found $count devices"
}

# Get temperature and health using serial number - IMPROVED
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
    
    # Get basic SMART data (fast)
    local smart_output=$(smartctl -AH "$dev" 2>/dev/null)
    
    # Extract temperature - TRY MULTIPLE METHODS
    local temp=""
    
    # Method 1: "Current Drive Temperature:" format (used by many SSDs and some WD drives)
    temp=$(echo "$smart_output" | grep -i "Current Drive Temperature" | awk '{print $4}')
    debug "Method 1 (Current Drive Temp): temp='$temp'"
    
    # Method 2: Attribute 194 (Temperature_Celsius) - most common
    if [ -z "$temp" ] || [ "$temp" == "0" ]; then
        temp=$(echo "$smart_output" | grep "^194 " | awk '{print $10}')
        debug "Method 2 (194): temp='$temp'"
    fi
    
    # Method 3: Attribute 190 (Airflow_Temperature)
    if [ -z "$temp" ] || [ "$temp" == "0" ]; then
        temp=$(echo "$smart_output" | grep "^190 " | awk '{print $10}')
        debug "Method 3 (190): temp='$temp'"
    fi
    
    # Method 4: Any line with temperature
    if [ -z "$temp" ] || [ "$temp" == "0" ]; then
        temp=$(echo "$smart_output" | grep -i "temperature" | grep -v "Drive Trip" | head -1 | awk '{print $NF}')
        debug "Method 4 (generic): temp='$temp'"
    fi
    
    # Clean up temp value (remove non-numeric except dash)
    if [ -n "$temp" ] && [ "$temp" != "0" ] && [ "$temp" != "-" ]; then
        # Extract just the number
        temp=$(echo "$temp" | grep -oE '[0-9]+' | head -1)
    fi
    
    if [ -z "$temp" ] || [ "$temp" == "0" ]; then
        temp="-"
    fi
    DISK_TEMPERATURE["$serial"]="$temp"
    debug "Final temp for serial $serial: $temp"
    
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
    
    # Extract SSD wear level (for SSDs)
    local wear=""
    
    # For SSDs, try to get wear indicator
    # Check if it's an SSD by looking for SSD-specific attributes
    if echo "$smart_output" | grep -qi "SSD\|Solid State"; then
        # Get extended info only for SSDs (faster than doing it for all disks)
        local ssd_extended=$(smartctl -x "$dev" 2>/dev/null)
        wear=$(echo "$ssd_extended" | grep -i "Percentage used endurance indicator" | grep -oE '[0-9]+%' | head -1)
        
        if [ -z "$wear" ]; then
            # Try power hours from extended output for SSDs
            local ssd_power=$(echo "$ssd_extended" | grep -i "Accumulated power on time" | grep -oE '[0-9]+' | head -1)
            if [ -n "$ssd_power" ]; then
                DISK_POWER_ON_HOURS["$serial"]="$ssd_power"
            fi
        fi
    fi
    
    # Try attribute-based wear indicators
    if [ -z "$wear" ]; then
        wear=$(echo "$smart_output" | grep -i "Percentage used endurance indicator" | grep -oE '[0-9]+%' | head -1)
    fi
    
    if [ -z "$wear" ]; then
        # Try attribute 177 (Wear Leveling Count)
        wear=$(echo "$smart_output" | grep "^177 " | awk '{print $10}')
        if [ -n "$wear" ] && [ "$wear" != "0" ]; then
            wear="${wear}%"
        else
            wear=""
        fi
    fi
    
    if [ -z "$wear" ]; then
        # Try attribute 233 (Media Wearout Indicator) - higher is better
        local media_wear=$(echo "$smart_output" | grep "^233 " | awk '{print $4}')
        if [ -n "$media_wear" ] && [ "$media_wear" != "0" ]; then
            # Convert to wear percentage (100 - value)
            local wear_pct=$((100 - media_wear))
            wear="${wear_pct}%"
        fi
    fi
    
    DISK_WEAR_PERCENT["$serial"]="${wear:--}"
    debug "SSD wear: $wear"
    
    # Extract power on hours
    local power_hours=$(echo "$smart_output" | grep "^  9 Power_On_Hours" | awk '{print $10}')
    if [ -z "$power_hours" ]; then
        # Try alternative format (from -x output)
        power_hours=$(echo "$smart_output" | grep -i "Accumulated power on time" | grep -oE '[0-9]+' | head -1)
    fi
    DISK_POWER_ON_HOURS["$serial"]="${power_hours:--}"
    debug "Power on hours: $power_hours"
}

# Check ZPool status for each device
check_zpool_status() {
    echo -n "Checking ZPool status... "
    local zpool_output=$(zpool status 2>/dev/null)
    local count=0
    
    for serial in "${!DEVICE_SERIAL_MAP[@]}"; do
        local dev="${DEVICE_SERIAL_MAP[$serial]}"
        local dev_basename=$(basename "$dev")
        
        # Check if device appears in zpool status
        if echo "$zpool_output" | grep -q "$dev_basename"; then
            if echo "$zpool_output" | grep "$dev_basename" | grep -qi "DEGRADED\|FAULTED\|UNAVAIL"; then
                DISK_ZPOOL_STATUS["$serial"]="ISSUE"
                ((count++))
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
    echo "done"
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
echo "Found ${#DISK_MODEL[@]} disks in enclosure"

build_device_serial_map

# Get SMART data for all disks
echo -n "Collecting SMART data... "
for slot in $(seq 0 $((ENCLOSURE_MAX_SLOT - 1))); do
    key="2:${slot}"
    if [ -n "${DISK_SERIAL[$key]:-}" ]; then
        serial="${DISK_SERIAL[$key]}"
        get_smart_data "$serial"
    fi
done
echo "done"

check_zpool_status

# Generate report
echo ""
echo "=============================================="
echo "TrueNAS Disk Inventory Report"
echo "Generated: $(date)"
echo "=============================================="
echo ""
echo "ENCLOSURE #2 (Main Chassis) - 24 slots"
echo "-----------------------------------------------------------------------------------------"
printf "%-4s | %-11s | %-20s | %-8s | %-8s | %-15s | %-5s | %-5s | %-6s | %-12s | %s\n" \
    "SLOT" "STATE" "MODEL" "SIZE" "TYPE" "SERIAL" "TEMP" "WEAR" "POH" "HEALTH" "NOTES"
echo "-----------------------------------------------------------------------------------------"

sas_ssd_count=0
sata_hdd_count=0
sas_ssd_capacity=0
sata_hdd_capacity=0
health_warn_count=0
health_fail_count=0
failed_disks_details=""

for slot in $(seq 0 $((ENCLOSURE_MAX_SLOT - 1))); do
    key="2:${slot}"

    if [ -n "${DISK_MODEL[$key]:-}" ]; then
        state="${DISK_STATE[$key]:-N/A}"
        model="${DISK_MODEL[$key]:-N/A}"
        size_mb=${DISK_SIZE_MB[$key]:-0}
        size=$(format_size_mb $size_mb)
        dtype="${DISK_TYPE[$key]:-N/A}"
        serial="${DISK_SERIAL[$key]:-N/A}"
        
        # Get temperature, health, wear, and power-on hours from cached data
        temp="${DISK_TEMPERATURE[$serial]:-"-"}"
        health="${DISK_HEALTH[$serial]:-"UNKNOWN"}"
        zpool_status="${DISK_ZPOOL_STATUS[$serial]:-"NOT_IN_POOL"}"
        wear="${DISK_WEAR_PERCENT[$serial]:-"-"}"
        power_hours="${DISK_POWER_ON_HOURS[$serial]:-"-"}"
        
        # Convert power hours to days for display
        if [ "$power_hours" != "-" ] && [ "$power_hours" -gt 0 ]; then
            power_days=$((power_hours / 24))
            power_display="${power_days}d"
        else
            power_display="-"
        fi

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
        
        # Count health warnings/failures and track failed disks
        if [[ "$health" == "WARN"* ]]; then
            ((health_warn_count++))
        elif [[ "$health" == "FAILED" ]]; then
            ((health_fail_count++))
        fi
        
        if [[ "$state" == *"Failed"* ]] || [[ "$health" == "FAILED" ]] || [[ "$zpool_status" == "ISSUE" ]]; then
            failed_disks_details+="Slot $slot: $model - State: $state, Health: $health, ZPool: $zpool_status"$'\n'
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

        printf "%-4s | %-11s | %-20s | %-8s | %-8s | %-15s | %-5s | %-5s | %-6s | %-12s | %s\n" \
            "$slot" "$state" "${model:0:20}" "$size" "$dtype" "${serial:0:15}" "${temp}°C" "$wear" "$power_display" "$health" "$notes"
    else
        printf "%-4s | %-11s | %-20s | %-8s | %-8s | %-15s | %-5s | %-5s | %-6s | %-12s | %s\n" \
            "$slot" "Empty" "(no disk detected)" "-" "-" "-" "-" "-" "-" "-" "-"
    fi
done

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

if [ -n "$failed_disks_details" ]; then
    echo "$failed_disks_details"
else
    echo "No failed disks detected"
fi

echo "=============================================="
