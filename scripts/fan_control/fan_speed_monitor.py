#!/usr/bin/env python3
"""
TrueNAS SCALE Fan Speed Monitor

Monitors system temperatures and logs fan metrics.
Provides a foundation for future fan control implementation.

Note: Full IPMI fan control not available on this system due to BMC device access restrictions.
This script focuses on temperature monitoring and readiness for when IPMI becomes available.
"""

import subprocess
import json
import sys
from datetime import datetime
from pathlib import Path
import time

class TrueNASSensor:
    """Read sensor data from TrueNAS SCALE system"""
    
    def __init__(self, log_dir="/var/log/fan_control"):
        self.log_dir = Path(log_dir)
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self.log_file = self.log_dir / f"fan_monitor_{datetime.now().strftime('%Y%m%d')}.log"
    
    def get_drive_temperatures(self):
        """Read drive temperatures via lm-sensors"""
        try:
            result = subprocess.run(['sensors', '-u'], capture_output=True, text=True, timeout=5)
            temps = {}
            
            for line in result.stdout.split('\n'):
                if 'drivetemp-scsi' in line:
                    # Extract device ID from line like "drivetemp-scsi-0-f0"
                    parts = line.split('-')
                    if len(parts) >= 3:
                        device_id = parts[-1]
                        temps[device_id] = None
                elif 'temp1:' in line and device_id and device_id in temps:
                    # Extract temperature value
                    # Line format: "temp1:        +41.0°C  (low  =  +0.0°C, high = +60.0°C)"
                    try:
                        temp_str = line.split('+')[1].split('°')[0]
                        temps[device_id] = float(temp_str)
                    except (IndexError, ValueError):
                        pass
            
            return temps
        except (subprocess.TimeoutExpired, FileNotFoundError) as e:
            print(f"Error reading drive temperatures: {e}", file=sys.stderr)
            return {}
    
    def get_cpu_temperature(self):
        """Read CPU temperature from /proc/cpuinfo or sysfs"""
        try:
            # Try sysfs first (more reliable)
            result = subprocess.run(
                ['bash', '-c', 'cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | head -1'],
                capture_output=True, text=True, timeout=5
            )
            if result.stdout.strip():
                temp_millidegrees = int(result.stdout.strip())
                return temp_millidegrees / 1000.0
        except (subprocess.TimeoutExpired, ValueError):
            pass
        
        return None
    
    def get_fan_status(self):
        """Get fan RPM readings via ipmitool (if available)"""
        try:
            result = subprocess.run(['ipmitool', 'sdr'], capture_output=True, text=True, timeout=5)
            fans = {}
            
            for line in result.stdout.split('\n'):
                for fan_name in ['FAN1', 'FAN2', 'FAN3', 'FAN4', 'FANA', 'FANB']:
                    if fan_name in line:
                        # Extract RPM value (3-5 digits)
                        import re
                        rpm_match = re.search(r'(\d{3,5})', line)
                        if rpm_match:
                            fans[fan_name] = int(rpm_match.group(1))
            
            return fans if fans else None
        except (subprocess.TimeoutExpired, FileNotFoundError):
            # IPMI not available on this system
            return None
    
    def log_status(self):
        """Log current system status"""
        timestamp = datetime.now().isoformat()
        status = {
            'timestamp': timestamp,
            'drive_temps': self.get_drive_temperatures(),
            'cpu_temp': self.get_cpu_temperature(),
            'fan_status': self.get_fan_status()
        }
        
        # Print to console
        print(f"\n{'='*60}")
        print(f"Fan Monitor Status - {timestamp}")
        print(f"{'='*60}")
        
        # Drive temperatures
        if status['drive_temps']:
            print(f"\nDrive Temperatures:")
            for device_id, temp in sorted(status['drive_temps'].items()):
                if temp is not None:
                    print(f"  {device_id}: {temp:.1f}°C")
        
        # CPU temperature
        if status['cpu_temp'] is not None:
            print(f"\nCPU Temperature: {status['cpu_temp']:.1f}°C")
        
        # Fan status
        if status['fan_status']:
            print(f"\nFan Status (RPM):")
            for fan_name, rpm in sorted(status['fan_status'].items()):
                print(f"  {fan_name}: {rpm} RPM")
        else:
            print(f"\nFan Status: IPMI not available (BMC device not accessible)")
        
        # Log to file
        try:
            with open(self.log_file, 'a') as f:
                f.write(json.dumps(status) + '\n')
        except IOError as e:
            print(f"Warning: Could not write to log file: {e}", file=sys.stderr)
        
        return status


def main():
    """Main monitoring loop"""
    monitor = TrueNASSensor()
    
    print("TrueNAS SCALE Fan Speed Monitor")
    print(f"Logging to: {monitor.log_file}")
    print("\nPress Ctrl+C to stop")
    
    # Test single read
    status = monitor.log_status()
    
    # Check if IPMI is available
    if status['fan_status'] is None:
        print("\n" + "!"*60)
        print("WARNING: IPMI Fan Control NOT Available")
        print("This system does not have IPMI BMC device access.")
        print("Fan duty cycle control is not possible at this time.")
        print("See docs/FAN_CONTROL_FINDINGS.md for details.")
        print("!"*60)
        return 0
    
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n\nMonitoring stopped.")
        sys.exit(0)
