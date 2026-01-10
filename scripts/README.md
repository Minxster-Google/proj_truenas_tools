# Scripts

This directory contains operational scripts for TrueNAS management.

## Available Scripts

### disk_inventory.sh
**Status**: Production
**Last Updated**: 2026-01-10

Generates comprehensive disk inventory reports with enclosure/slot mapping, temperatures, and health status.

See [../docs/TRUENAS_DISK_INVENTORY.md](../docs/TRUENAS_DISK_INVENTORY.md) for detailed documentation.

## Testing Scripts

When developing changes to production scripts, create test versions with `_TEST` suffix:

```bash
cp disk_inventory.sh disk_inventory_TEST.sh
# Make changes to disk_inventory_TEST.sh
# Test thoroughly
# Only after validation, update disk_inventory.sh
```

## Deployment

Scripts in this directory are version-controlled. To deploy to TrueNAS:

```bash
scp disk_inventory.sh root@truenas.local.fishsniffer.co.uk:/mnt/RaidZ3/local_TrueNAS_scripts/HDD_Info/
```

Always backup the current production version before deploying changes.
