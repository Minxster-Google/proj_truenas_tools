# TrueNAS Disk Inventory Tool

## Overview

The `disk_inventory.sh` script generates a comprehensive inventory of all disks in a TrueNAS server with SAS expander enclosure, providing detailed information about disk location, status, and health.

## Features

### Current Features
- **Enclosure/Slot Mapping**: Maps physical enclosure slots to disk identities using `sas3ircu`
- **Disk Information**: Model, serial number, size, firmware revision
- **Disk Type Detection**: Identifies SAS-SSD, SATA-HDD, etc.
- **State Detection**: Reports disk state (Ready, Failed, Standby, etc.)
- **Temperature Monitoring**: Reads disk temperatures via smartctl
- **Summary Statistics**: Counts and capacities by disk type
- **Dual Output Formats**: Text and HTML reports with color-coded status
- **Failed Disk Detection**: Highlights failed or missing disks

### Planned Features
- Serial number-based temperature matching (more reliable than SCSI slot order)
- SMART health status with critical attribute checking
- ZPool status cross-reference
- Enhanced error detection and reporting

## Hardware Configuration

### TrueNAS Server
- **Hostname**: truenas.local.fishsniffer.co.uk
- **IP**: 192.168.1.236
- **Version**: TrueNAS SCALE 25.10.1
- **OS**: Debian 12 (bookworm)
- **Kernel**: 6.12.33-production+truenas

### Storage Hardware
- **Enclosure**: GOOXIBM 4U24SXP 36Sx12G (24-slot SAS expander)
- **Controller**: SAS3008 (LSI/Broadcom)
  - Firmware: 16.00.10.00
  - BIOS: 8.37.00.00
- **Enclosure ID**: 2
- **Total Slots**: 24 (Slot 0-23, Slot 24 is enclosure services)

## Technical Details

### Detection Methods

1. **sas3ircu 0 display**
   - Primary source for enclosure/slot mapping
   - Provides: enclosure ID, slot number, SAS address, state, model, serial, size, type, firmware
   - Limitation: Failed disks may not appear in output

2. **lsscsi -s**
   - Maps SCSI devices to `/dev/sdX` names
   - Note: SCSI slot order ≠ physical enclosure slot order (requires serial number matching)

3. **smartctl**
   - Temperature data from SMART attributes
   - Health status and critical attribute values
   - Device identification via serial numbers

4. **zpool status** (planned)
   - Pool-level disk status
   - Cross-reference with sas3ircu data
   - Detect pool-specific issues

### Parsing Strategy

The script parses `sas3ircu 0 display` output using bash case patterns:

```bash
while IFS= read -r line; do
    line_trimmed=$(echo "$line" | sed 's/^[[:space:]]*//')
    
    case "$line_trimmed" in
        "Device is a Hard disk")
            in_device=1
            ;;
        Enclosure*)
            enclosure=$(echo "$line_trimmed" | cut -d: -f2 | tr -d ' ')
            ;;
        Slot*)
            slot=$(echo "$line_trimmed" | cut -d: -f2 | tr -d ' ')
            ;;
        # ... more patterns
    esac
done
```

**Key lesson learned**: Patterns with spaces must be quoted: `"Drive Type"*)` not `Drive*)`

### Known Issues and Solutions

#### Issue 1: Drive Type Not Parsing
**Problem**: Pattern `Drive*)` doesn't match "Drive Type" line
**Solution**: Use quoted pattern `"Drive Type"*)` and improve extraction:
```bash
"Drive Type"*)
    dtype=$(echo "$line_trimmed" | cut -d: -f2 | sed 's/^[[:space:]]*//' | tr -d ' ')
    DISK_TYPE["${enclosure}:${slot}"]="$dtype"
    ;;
```

#### Issue 2: Temperature Mapping Incorrect
**Problem**: `lsscsi` slot order doesn't match physical enclosure slots
**Solution**: Serial number-based device matching (see planned features)

#### Issue 3: Case-Sensitive Filesystem
**Problem**: Created `hdd_info` folder when `HDD_Info` already existed
**Solution**: Always verify exact case with `ls -la` on TrueNAS

## Usage Examples

### Basic Execution
```bash
ssh root@truenas.local.fishsniffer.co.uk
cd /mnt/RaidZ3/local_TrueNAS_scripts/HDD_Info/
./disk_inventory.sh
```

### Remote Execution
```bash
expect -c "
spawn ssh -o StrictHostKeyChecking=no root@truenas.local.fishsniffer.co.uk \\
  \"/mnt/RaidZ3/local_TrueNAS_scripts/HDD_Info/disk_inventory.sh\"
expect \"password:\"
send \"PASSWORD\r\"
expect eof
"
```

### Output Files
- `disk_inventory_20260110_233045.txt` - Text report
- `disk_inventory_20260110_233045.html` - HTML report with color coding
- `disk_inventory.log` - Execution log

## Development Workflow

### Testing Changes

1. Create test version:
   ```bash
   cp disk_inventory.sh disk_inventory_TEST.sh
   ```

2. Add debug output:
   ```bash
   echo "DEBUG: Found Drive Type: $dtype for slot $slot" >&2
   ```

3. Run test version:
   ```bash
   ./disk_inventory_TEST.sh
   ```

4. Validate output:
   - Check TYPE column shows correct values
   - Verify temperatures are reasonable (30-50°C typical)
   - Ensure execution time is acceptable (<2 minutes)
   - Review log file for errors

5. Update production script only after validation

### Version Control

Scripts are maintained in the `proj_truenas_tools` git submodule:
- **Repository**: `git@github.com:Minxster-Google/proj_truenas_tools.git`
- **Local path**: `/opt/opencode_master/proj_truenas_tools/`
- **Production path**: `/mnt/RaidZ3/local_TrueNAS_scripts/HDD_Info/`

After making changes:
```bash
cd /opt/opencode_master/proj_truenas_tools
git add scripts/disk_inventory.sh
git commit -m "Description of changes"
git push
```

## Safety Guidelines

### Production Server Warnings
- TrueNAS is a **production storage server** with live data
- **Read-only operations only** during development/testing
- Always create `*_TEST.sh` versions for testing
- Backup working scripts before modifications
- Never install packages or modify system configuration without explicit approval

### Pre-Production Checklist
- [ ] Create test version (`*_TEST.sh`)
- [ ] Add debug output to verify logic
- [ ] Run test version and inspect output
- [ ] Validate key fields (TYPE, TEMP, HEALTH, etc.)
- [ ] Check execution time (<2 minutes for 24 disks)
- [ ] Verify no errors in log file
- [ ] Compare output to previous working version
- [ ] Get explicit approval before updating production script

### Rollback Plan
If a script update causes issues:
1. Git history has all previous versions
2. Copy working version from version control
3. Historical output files available for comparison

## Performance Considerations

- **sas3ircu scanning**: ~1-2 seconds
- **smartctl queries**: ~1-2 seconds per disk
- **Total execution time**: ~30-60 seconds for 24-disk array (acceptable)

Future serial number mapping will add ~30-60 seconds at startup but provides more accurate device correlation.
