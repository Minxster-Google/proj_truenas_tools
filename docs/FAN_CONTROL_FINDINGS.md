# TrueNAS Fan Control - Research Findings

## Summary

On the TrueNAS SCALE server (192.168.1.236), we attempted to adapt the legacy TrueNAS Core fan control script (`spinpid2.sh`) for SCALE compatibility.

## Original TrueNAS Core Method (spinpid2.sh)

**Pre-installed Executable:** `ipmitool`
- **IPMI Control Commands:**
  - Read fan mode: `ipmitool raw 0x30 0x45 0`
  - Read duty cycle: `ipmitool raw 0x30 0x70 0x66 0 <ZONE>`
  - Set duty cycle: `ipmitool raw 0x30 0x70 0x66 1 <ZONE> <DUTY>`
  - Read sensors: `ipmitool sdr`

- **Fan Zones:** Two zones (CPU and Peripheral)
- **Monitoring:** CPU temp via `sysctl` or IPMI sensor, drive temps via `smartctl`

## TrueNAS SCALE Findings

### Tools Available
✅ **ipmitool** v1.8.19 - Available
✅ **lm-sensors** - Available (provides drive temperature monitoring)
✅ **sensors** command - Working

### Limitation: IPMI Device Not Available
❌ **IPMI Device Access:**
```
No /dev/ipmi0 or /dev/ipmi/0 device found
No local BMC (Baseboard Management Controller) access available
LAN session establishment also failed
```

### What Works
1. **Drive Temperature Reading:**
   ```bash
   sensors | grep drivetemp-scsi
   ```
   - Provides SCSI drive temperatures via hwmon interface

2. **System Information:**
   - CPU count and temperature may be available via `/proc/cpuinfo`
   - Kernel hwmon interface available for monitoring

## Status

### ✅ Successfully Tested
- SSH connectivity to TrueNAS SCALE ✓
- ipmitool presence ✓
- lm-sensors availability ✓
- Drive temperature monitoring via sensors ✓

### ⚠️ Cannot Test
- IPMI fan control commands (no BMC device access)
- Setting fan duty cycles via IPMI
- Setting fan mode via IPMI

## Recommendations

### Option 1: IPMI Pass-Through (Recommended if available)
If the hardware supports it, enable IPMI over LAN through:
- TrueNAS UI system settings
- Motherboard BIOS configuration
- Verify `/dev/ipmi0` availability

### Option 2: Alternative Fan Control
If IPMI is not available on this system:
- Use TrueNAS API for fan control (if exposed)
- Use PWM control via sysfs (if fans support it)
- Use ipmitool over network/LAN with proper authentication

### Option 3: Monitoring Only
Adapt script to monitor temperatures without control:
- Read drive temps via sensors
- Read CPU temp via system metrics
- Log and alert but do not adjust fans

## Next Steps

1. Check TrueNAS system settings for IPMI configuration
2. Verify if BMC is disabled or needs hardware enablement
3. Contact hardware vendor for IPMI support on this system
4. Implement temperature monitoring script as interim solution

## Reference Files

- Original script: `/mnt/RaidZ3/local_TrueNAS_scripts/spinscripts_2020-08-20/spinpid2.sh`
- TrueNAS Core used: FreeBSD-based with native IPMI support
- TrueNAS SCALE uses: Debian/Linux-based with optional IPMI support
