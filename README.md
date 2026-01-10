# TrueNAS Tools

Tools for managing and monitoring TrueNAS SCALE servers.

## ⚠️ Production Server Warning

Scripts in this repository are designed for **TrueNAS (truenas.local.fishsniffer.co.uk)**, a production storage server. Always test changes carefully.

## Scripts

### disk_inventory.sh

Generate comprehensive disk inventory with enclosure/slot mapping, temperatures, and SMART health status.

**Features:**
- SAS3008 controller integration via sas3ircu
- 24-bay enclosure slot mapping
- Serial number-based device correlation
- Temperature monitoring via smartctl
- SMART health status checking
- HTML and text report generation

**Usage:**
```bash
# On TrueNAS:
cd /mnt/RaidZ3/local_TrueNAS_scripts/HDD_Info/
./disk_inventory.sh

# Remote execution:
ssh root@truenas.local.fishsniffer.co.uk \
  "/mnt/RaidZ3/local_TrueNAS_scripts/HDD_Info/disk_inventory.sh"
```

**Output:**
- Text report: `disk_inventory_YYYYMMDD_HHMMSS.txt`
- HTML report: `disk_inventory_YYYYMMDD_HHMMSS.html` (with color-coded health status)
- Log file: `disk_inventory.log`

## Installation

### Initial Setup

1. Clone this repository to `/opt/opencode_master/proj_truenas_tools/`
2. Copy scripts to TrueNAS:
   ```bash
   scp scripts/disk_inventory.sh root@truenas.local.fishsniffer.co.uk:/mnt/RaidZ3/local_TrueNAS_scripts/HDD_Info/
   ```
3. Set execute permissions on TrueNAS:
   ```bash
   ssh root@truenas.local.fishsniffer.co.uk "chmod +x /mnt/RaidZ3/local_TrueNAS_scripts/HDD_Info/disk_inventory.sh"
   ```

### Updating Scripts

1. Edit scripts in `proj_truenas_tools/scripts/`
2. Test locally if possible, or create `*_TEST.sh` version
3. Copy to TrueNAS after validation
4. Commit changes to version control

## Requirements

### TrueNAS Side
- TrueNAS SCALE 25.10.1 or later
- sas3ircu tool (pre-installed)
- smartmontools (pre-installed)
- Python 3 (for HTML generation)

### Management Side (opencode-ubuntu)
- SSH access to TrueNAS
- expect tool (for password-based SSH)
- Vaultwarden credentials

## Documentation

See `docs/` directory for detailed documentation:
- `TRUENAS_DISK_INVENTORY.md` - Comprehensive guide
- `PARSING_METHODS.md` - Technical implementation notes

## License

Internal use only - Minxster Infrastructure
