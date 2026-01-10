# Parsing Methods - Technical Notes

## sas3ircu Output Parsing

### Output Structure

The `sas3ircu 0 display` command outputs information in a hierarchical format:

```
LSI Corporation SAS3 IR Configuration Utility.
...
IR Volume information
...
Physical device information
...
Enclosure#     : 2
Slot#          : 0
...
Device is a Hard disk
  Enclosure #                             : 2
  Slot #                                  : 0
  SAS Address                             : 5000cca-2-6d5b-e2a5
  State                                   : Ready (RDY)
  Size (in MB)/(in sectors)               : 3815447/7814037167
  Manufacturer                            : ATA
  Model Number                            : WDC WD4000FYYZ-0
  Firmware Revision                       : 1A01
  Serial No                               : WD-WCC131234567
  GUID                                    : 5000cca26d5be2a4
  Drive Type                              : SATA_HDD
```

### Parsing Challenges

#### Challenge 1: Leading Whitespace
Lines within device sections have variable leading whitespace. Solution: trim before matching.

```bash
line_trimmed=$(echo "$line" | sed 's/^[[:space:]]*//')
```

#### Challenge 2: Multi-word Field Names
Field names with spaces require quoted patterns in bash case statements.

**Wrong:**
```bash
Drive*)  # Matches "Drive" but not "Drive Type"
```

**Correct:**
```bash
"Drive Type"*)  # Matches the full "Drive Type" field
```

#### Challenge 3: Values After Colons
Most fields use format: `Field Name : Value`

Extract value using:
```bash
value=$(echo "$line_trimmed" | cut -d: -f2 | sed 's/^[[:space:]]*//' | tr -d ' ')
```

**Breakdown:**
- `cut -d: -f2` - Get everything after first colon
- `sed 's/^[[:space:]]*//'` - Remove leading whitespace
- `tr -d ' '` - Remove all spaces (optional, for compact storage)

### State Machine Approach

The parser uses a state machine to track context:

```bash
in_device=0  # Flag: are we inside a device block?

while IFS= read -r line; do
    if [[ "$line_trimmed" == "Device is a Hard disk" ]]; then
        in_device=1  # Enter device context
        continue
    fi
    
    if [[ $in_device -eq 1 ]]; then
        # Process device fields
        case "$line_trimmed" in
            Enclosure*)
                # Extract enclosure number
                ;;
            GUID*)
                in_device=0  # Exit device context
                ;;
        esac
    fi
done
```

**Why GUID?** The GUID field is always the last field in a device block, so we use it as an exit marker.

## Serial Number to Device Mapping

### Problem

The SCSI slot order reported by `lsscsi` doesn't match the physical enclosure slot order:

```bash
lsscsi -s
[0:0:0:0]  disk  /dev/sda   3.49TB
[0:0:1:0]  disk  /dev/sdb   1.82TB
[0:0:2:0]  disk  /dev/sdc   3.49TB
```

Physical slot 0 might be `/dev/sdc`, not `/dev/sda`.

### Solution

Map devices by serial number instead of slot:

1. **Build Serial-to-Device Map** (once at startup):
```bash
declare -A DEVICE_SERIAL_MAP

for dev in /dev/sd*; do
    # Skip partitions
    [[ "$dev" =~ [0-9]$ ]] && continue
    
    # Get serial from smartctl
    serial=$(smartctl -i "$dev" 2>/dev/null | \
             grep -i "serial number" | \
             awk '{print $NF}' | \
             tr -d ' ')
    
    if [ -n "$serial" ]; then
        DEVICE_SERIAL_MAP["$serial"]="$dev"
    fi
done
```

2. **Look Up Device by Serial**:
```bash
serial="${DISK_SERIAL[${enclosure}:${slot}]}"  # From sas3ircu
dev="${DEVICE_SERIAL_MAP[$serial]:-}"          # Find device path

if [ -n "$dev" ]; then
    temp=$(smartctl -A "$dev" | grep -i "temperature" | awk '{print $10}')
fi
```

### Performance Impact

- **Building map**: ~1-2 seconds per disk (~30-60 seconds for 24 disks)
- **Lookups**: O(1) - instant via associative array
- **Total overhead**: 30-60 seconds at startup (acceptable for inventory script)

### Optimization Opportunities

If performance becomes an issue:
1. **Cache the map**: Save to file, check if devices changed
2. **Parallel queries**: Use GNU parallel for smartctl calls
3. **Skip sleeping disks**: Use `hdparm -C` to check power state first

## Temperature Extraction

### SMART Attribute Format

Different drives report temperature in different SMART attributes:

**Common formats:**
```
194 Temperature_Celsius     0x0022   167   108   000    Old_age   Always       -       35
190 Airflow_Temperature_Cel 0x0022   067   056   045    Old_age   Always       -       33
```

### Extraction Strategy

Try multiple methods, use first success:

```bash
get_temperature() {
    local dev="$1"
    
    # Method 1: Generic temperature grep
    temp=$(smartctl -A "$dev" 2>/dev/null | \
           grep -i "temperature" | head -1 | awk '{print $10}')
    
    # Method 2: Specific attribute ID
    if [ -z "$temp" ]; then
        temp=$(smartctl -A "$dev" 2>/dev/null | \
               grep "194 Temperature_Celsius" | awk '{print $10}')
    fi
    
    # Method 3: Alternative attribute
    if [ -z "$temp" ]; then
        temp=$(smartctl -A "$dev" 2>/dev/null | \
               grep "190 Airflow_Temperature" | awk '{print $10}')
    fi
    
    # Fallback
    [ -z "$temp" ] && temp="-"
    
    echo "$temp"
}
```

### Validation

Typical disk temperatures:
- **Idle**: 30-40°C
- **Active**: 35-50°C
- **Hot**: 50-60°C
- **Critical**: >60°C

Invalid values to reject:
- 0 or negative
- >100°C (likely parsing error)
- Non-numeric

## SMART Health Status

### Health Check Methods

1. **Overall health test result**:
```bash
smartctl -H "$dev" | grep -i "SMART overall-health" | awk '{print $NF}'
```

2. **Critical attributes**:
```bash
# Reallocated sectors (should be 0)
smartctl -A "$dev" | grep "Reallocated_Sector" | awk '{print $10}'

# Pending sectors (should be 0)
smartctl -A "$dev" | grep "Current_Pending_Sector" | awk '{print $10}'

# Uncorrectable sectors (should be 0)
smartctl -A "$dev" | grep "Offline_Uncorrectable" | awk '{print $10}'
```

### Health Status Levels

- **PASSED**: Overall health good, no critical attributes
- **WARN:REALLOC**: Health passed but has reallocated sectors (monitor)
- **WARN:PENDING**: Health passed but has pending sectors (may fail soon)
- **FAILED**: Overall health test failed (replace immediately)
- **UNKNOWN**: Unable to read SMART data

## ZPool Status Integration

### Cross-Reference Strategy

Compare sas3ircu state with zpool status:

```bash
zpool status -v | grep -A5 "/dev/sdX"
```

**Expected states:**
- sas3ircu: Ready → zpool: ONLINE ✓
- sas3ircu: Failed → zpool: FAULTED ✓
- sas3ircu: Ready → zpool: DEGRADED ⚠ (investigate)
- sas3ircu: (missing) → zpool: UNAVAIL ✗ (disk not detected)

### Mismatch Detection

Flag mismatches that indicate problems:
- Disk shows Ready in sas3ircu but FAULTED/DEGRADED in zpool
- Disk not in sas3ircu but referenced in zpool
- Pool has DEGRADED/FAULTED vdevs but all disks show Ready

## Performance Optimization

### Minimize smartctl Calls

smartctl is slow (~1-2 seconds per query). Optimize:

1. **Single smartctl call per disk**:
```bash
# Bad: Multiple calls
temp=$(smartctl -A "$dev" | grep Temperature)
health=$(smartctl -H "$dev" | grep health)

# Good: One call, cache output
smart_output=$(smartctl -AH "$dev" 2>/dev/null)
temp=$(echo "$smart_output" | grep Temperature | awk '{print $10}')
health=$(echo "$smart_output" | grep health | awk '{print $NF}')
```

2. **Parallel execution** (if needed):
```bash
# Use GNU parallel for multiple disks
parallel -j8 'smartctl -AH {} 2>/dev/null' ::: /dev/sd{a..x}
```

3. **Skip unnecessary queries**:
- Skip temperature for failed disks
- Skip SMART for devices not in zpool

### Progress Indication

For operations taking >10 seconds, show progress:

```bash
echo "Scanning 24 disks for serial numbers... (this may take 30-60 seconds)"

count=0
for dev in /dev/sd*; do
    ((count++))
    echo -ne "\rProgress: $count/24 disks scanned..."
    # ... do work
done
echo -e "\rCompleted: $count disks scanned     "
```

## Error Handling

### Graceful Degradation

Always provide fallback values:

```bash
# If temperature unavailable, show "-"
temp="${temperature:-"-"}"

# If health check fails, show "UNKNOWN"
health="${health:-"UNKNOWN"}"

# If device not found, show "N/A"
dev="${DEVICE_SERIAL_MAP[$serial]:-"N/A"}"
```

### Logging

Log errors without stopping execution:

```bash
if ! smartctl -H "$dev" >/dev/null 2>&1; then
    log "WARN: Unable to read SMART data from $dev"
fi
```

### Exit Codes

Use appropriate exit codes:
- `0` - Success
- `1` - General error (missing dependencies, permissions)
- `2` - Partial success (some disks failed to query)

## Testing Recommendations

### Unit Testing Parsing Logic

Test with sample sas3ircu output:

```bash
# Save real output
sas3ircu 0 display > test_output.txt

# Test parser
source disk_inventory.sh
parse_sas3ircu < test_output.txt
echo "Found ${#DISK_MODEL[@]} disks"
```

### Integration Testing

Test full script with debug output:

```bash
DEBUG=1 ./disk_inventory_TEST.sh
```

Add debug statements:
```bash
if [ "$DEBUG" = "1" ]; then
    echo "DEBUG: Slot $slot -> Serial $serial -> Device $dev -> Temp $temp"
fi
```

### Validation

Compare output to known values:
- Manually verify 2-3 random slots match physical disks
- Check temperatures are reasonable
- Verify serial numbers match `smartctl -i /dev/sdX`
- Confirm disk counts match physical inventory
