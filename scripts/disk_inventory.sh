
#!/bin/bash
# TrueNAS Disk Inventory Script
# Generates a table of all disks with enclosure/slot info, SMART status, and health

OUTPUT_FILE="/mnt/RaidZ3/local_TrueNAS_scripts/HDD_Info/disk_inventory_$(date +%Y%m%d_%H%M%S).txt"
HTML_FILE="/mnt/RaidZ3/local_TrueNAS_scripts/HDD_Info/disk_inventory_$(date +%Y%m%d_%H%M%S).html"
LOG_FILE="/mnt/RaidZ3/local_TrueNAS_scripts/HDD_Info/disk_inventory.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "Starting disk inventory..."

SAS3IRCU_OUTPUT=$(sas3ircu 0 display 2>/dev/null)
if [ $? -ne 0 ]; then
    log "ERROR: sas3ircu 0 display failed"
    exit 1
fi

declare -A DISK_STATE
declare -A DISK_SAS_ADDR
declare -A DISK_MODEL
declare -A DISK_SERIAL
declare -A DISK_SIZE_MB
declare -A DISK_TYPE
declare -A DISK_FW_REV

ENCLOSURE_MAX_SLOT=25

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
                Drive*)
                    dtype=$(echo "$line_trimmed" | sed 's/Drive Type.*://' | sed 's/^[[:space:]]*//' | tr -d ' ')
                    DISK_TYPE["${enclosure}:${slot}"]="$dtype"
                    ;;
                GUID*)
                    in_device=0
                    ;;
            esac
        fi
    done <<< "$SAS3IRCU_OUTPUT"
}

get_temperature() {
    local dev="$1"
    local temp=""

    temp=$(smartctl -A "$dev" 2>/dev/null | grep -i "temperature" | head -1 | awk '{print $10}')

    if [ -z "$temp" ]; then
        temp=$(smartctl -A "$dev" 2>/dev/null | grep "194 Temperature_Celsius" | awk '{print $10}')
    fi

    if [ -z "$temp" ]; then
        temp="-"
    fi

    echo "$temp"
}

get_lsscsi_device() {
    local slot="$1"

    lsscsi -s 2>/dev/null | grep "\[0:0:${slot}:0\]" | awk '{print $7}'
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

parse_sas3ircu

log "Found ${#DISK_MODEL[@]} disks in sas3ircu output"

{
    echo "=============================================="
    echo "TrueNAS Disk Inventory Report"
    echo "Generated: $(date)"
    echo "=============================================="
    echo ""
    echo "ENCLOSURE #2 (Main Chassis) - ${ENCLOSURE_MAX_SLOT} slots total"
    echo "----------------------------------------------"
    printf "%-5s | %-12s | %-25s | %-12s | %-8s | %-15s | %-6s | %s\n" \
        "SLOT" "STATE" "MODEL" "SIZE" "TYPE" "SERIAL" "TEMP" "NOTES"
    echo "----------------------------------------------"

    sas_ssd_count=0
    sata_hdd_count=0
    sas_ssd_capacity=0
    sata_hdd_capacity=0

    for slot in $(seq 0 $((ENCLOSURE_MAX_SLOT - 1))); do
        key="2:${slot}"

        if [ -n "${DISK_MODEL[$key]:-}" ]; then
            state="${DISK_STATE[$key]:-N/A}"
            model="${DISK_MODEL[$key]:-N/A}"
            size_mb=${DISK_SIZE_MB[$key]:-0}
            size=$(format_size_mb $size_mb)
            dtype="${DISK_TYPE[$key]:-N/A}"
            serial="${DISK_SERIAL[$key]:-N/A}"

            device=$(get_lsscsi_device $slot 2>/dev/null)
            temp=$(get_temperature "/dev/$device" 2>/dev/null)

            notes=""
            if [[ "$state" == *"Failed"* ]]; then
                notes="FAILED"
            elif [[ "$state" == *"Standby"* ]]; then
                notes="SPIN DOWN"
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

            printf "%-5s | %-12s | %-25s | %-12s | %-8s | %-15s | %-6s | %s\n" \
                "$slot" "$state" "${model:0:25}" "$size" "$dtype" "${serial:0:15}" "${temp}°C" "$notes"
        else
            printf "%-5s | %-12s | %-25s | %-12s | %-8s | %-15s | %-6s | %s\n" \
                "$slot" "Empty" "(no disk detected)" "-" "-" "-" "-" "-"
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
    echo "POTENTIAL FAILED/MISSING DISKS"
    echo "----------------------------------------------"

    failed_count=0
    for slot in $(seq 0 $((ENCLOSURE_MAX_SLOT - 1))); do
        key="2:${slot}"
        if [ -n "${DISK_STATE[$key]:-}" ]; then
            state="${DISK_STATE[$key]}"
            if [[ "$state" == *"Failed"* ]]; then
                echo "Slot $slot: ${DISK_MODEL[$key]:-Unknown} - $state"
                failed_count=$((failed_count + 1))
            fi
        fi
    done

    if [ $failed_count -eq 0 ]; then
        echo "No failed disks detected in sas3ircu output"
    fi

    echo ""
    echo "----------------------------------------------"
    echo "DETECTION METHODS USED"
    echo "----------------------------------------------"
    echo "1. sas3ircu 0 display - Primary source for enclosure/slot mapping"
    echo "2. lsscsi -s - Maps SCSI devices to /dev/sdX names"
    echo "3. smartctl - Temperature and health data"
    echo ""
    echo "Note: Failed disks may not appear in sas3ircu output"
    echo "Check zpool status for pool-level disk issues"
    echo ""
    echo "=============================================="
    echo "End of Report"
    echo "=============================================="

} | tee "$OUTPUT_FILE"

log "Inventory saved to $OUTPUT_FILE"

if command -v python3 &> /dev/null; then
    python3 - "$OUTPUT_FILE" "$HTML_FILE" << 'PYTHON_EOF'
import sys
import re
from datetime import datetime

txt_file = sys.argv[1]
html_file = sys.argv[2]

html_template = '''<!DOCTYPE html>
<html>
<head>
    <title>TrueNAS Disk Inventory</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; background: #1a1a2e; color: #eee; }
        h1 { color: #00d4ff; }
        h2 { color: #00d4ff; margin-top: 30px; }
        table { border-collapse: collapse; width: 100%; margin: 20px 0; background: #16213e; }
        th, td { border: 1px solid #0f3460; padding: 10px; text-align: left; }
        th { background: #0f3460; color: #00d4ff; }
        tr:nth-child(even) { background: #1a1a2e; }
        tr:hover { background: #0f3460; }
        .failed { color: #ff6b6b; font-weight: bold; }
        .ssd { color: #4ade80; }
        .hdd { color: #fbbf24; }
        .summary { background: #0f3460; padding: 15px; border-radius: 8px; margin: 20px 0; }
        .badge { padding: 3px 8px; border-radius: 4px; font-size: 0.85em; }
        .badge-ready { background: #166534; color: #86efac; }
        .badge-failed { background: #991b1b; color: #fca5a5; }
        .badge-standby { background: #713f12; color: #fde047; }
        .badge-empty { background: #374151; color: #9ca3af; }
    </style>
</head>
<body>
    <h1>TrueNAS Disk Inventory Report</h1>
    <p>Generated: TIMESTAMP</p>
    
    <div class="summary">
        <h2>Summary</h2>
        <p><strong>Total Slots:</strong> 24</p>
        <p><strong>Disks Detected:</strong> DISK_COUNT</p>
        <p><strong>Failed/Missing:</strong> FAILED_COUNT</p>
        <p><strong>Total Capacity:</strong> TOTAL_CAPACITY</p>
    </div>
    
    <h2>Disk Details</h2>
    <table>
        <tr>
            <th>Slot</th>
            <th>State</th>
            <th>Model</th>
            <th>Size</th>
            <th>Type</th>
            <th>Serial</th>
            <th>Temp</th>
            <th>Notes</th>
        </tr>
        TABLE_ROWS
    </table>
    
    <h2>Detection Notes</h2>
    <ul>
        <li>sas3ircu 0 display - Primary source for enclosure/slot mapping</li>
        <li>Failed disks may not appear in sas3ircu output</li>
        <li>Check zpool status for pool-level disk issues</li>
    </ul>
</body>
</html>
'''

try:
    with open(txt_file, "r") as f:
        content = f.read()
    
    disk_count = len(re.findall(r'SAS-SSD|SATA-HDD', content))
    failed_count = len(re.findall(r'FAILED|MISSING', content))
    
    total_capacity_match = re.search(r'Total Storage: (\S+)', content)
    total_capacity = total_capacity_match.group(1) if total_capacity_match else "Unknown"
    
    table_rows = ""
    in_table = False
    for line in content.split('\n'):
        if "SLOT" in line and "STATE" in line:
            in_table = True
            continue
        if in_table and line.strip() and "---" not in line and "===" not in line:
            if "Enclosure services" in line or "DETECTION" in line:
                continue
            
            parts = [p.strip() for p in line.split('|')]
            if len(parts) >= 8:
                slot = parts[0].strip()
                state = parts[1].strip()
                model = parts[2].strip()
                size = parts[3].strip()
                dtype = parts[4].strip()
                serial = parts[5].strip()
                temp = parts[6].strip()
                notes = parts[7].strip() if len(parts) > 7 else ""
                
                badge_class = "badge-ready"
                if "FAIL" in state or "MISSING" in notes:
                    badge_class = "badge-failed"
                elif "Standby" in state:
                    badge_class = "badge-standby"
                elif state == "Empty":
                    badge_class = "badge-empty"
                
                row_class = ""
                if dtype == "SAS-SSD":
                    row_class = "ssd"
                elif dtype == "SATA-HDD":
                    row_class = "hdd"
                elif state == "Empty":
                    row_class = "missing"
                
                if "FAILED" in notes or "MISSING" in notes:
                    row_class = "failed"
                
                table_rows += f'''<tr class="{row_class}">
                    <td><strong>{slot}</strong></td>
                    <td><span class="badge {badge_class}">{state}</span></td>
                    <td>{model}<br><small>{serial}</small></td>
                    <td>{size}</td>
                    <td>{dtype}</td>
                    <td><small>{serial}</small></td>
                    <td>{temp}</td>
                    <td>{notes}</td>
                </tr>
'''
    
    html_content = html_template.replace("TIMESTAMP", datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    html_content = html_content.replace("DISK_COUNT", str(disk_count))
    html_content = html_content.replace("FAILED_COUNT", str(failed_count))
    html_content = html_content.replace("TOTAL_CAPACITY", total_capacity)
    html_content = html_content.replace("TABLE_ROWS", table_rows)
    
    with open(html_file, "w") as f:
        f.write(html_content)
    
    print(f"HTML report generated: {html_file}")
except Exception as e:
    print(f"HTML generation skipped: {e}")
PYTHON_EOF
fi

log "Disk inventory complete"
echo ""
echo "Output files:"
echo "  - $OUTPUT_FILE"
echo "  - $HTML_FILE"
