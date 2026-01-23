#!/bin/bash

# spinpid2_scale_optimized.sh - TrueNAS SCALE Fan Control Script (OPTIMIZED)
# Based on spinpid2.sh (2020-08-20) by Kevin Horton
# Adapted for TrueNAS SCALE with IPMI over LAN
# OPTIMIZED: Reduced polling, SDR caching, better mismatch handling
VERSION="2026-01-23-optimized"

# Run as superuser

##############################################
#
#  OPTIMIZATION CHANGES FROM ORIGINAL:
#
#  1. SDR CACHING: Reads sensor data once per cycle instead of multiple times
#  2. REDUCED CPU POLLING: CPU_T increased to 30s (was 1s) = 97% fewer calls
#  3. REDUCED DRIVE POLLING: DRIVE_T set to 5m default (was 1m) = 80% fewer calls
#  4. MISMATCH LIMITS: Maximum 2 retries (was unlimited) = prevents retry spiral
#  5. METRICS: Tracks IPMI call count for monitoring
#
#  RESULT: ~90% reduction in IPMI load while maintaining fan control effectiveness
#
##############################################

DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
source "$DIR/spinpid2_scale.config"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# OPTIMIZATION: Initialize metrics tracking
IPMI_CALL_COUNT=0
SDR_CACHE=""
SDR_CACHE_TIME=0
SDR_CACHE_TTL=60  # Cache SDR for 60 seconds

##############################################
# function get_disk_name
# Get disk name from lsblk output
# TrueNAS SCALE uses Linux device naming (sd*)
##############################################
function get_disk_name {
   DEVID=$(echo "$LINE" | awk '{print $1}')
}

############################################################
# function print_header
# Called when script starts and each quarter day
############################################################
function print_header {
   DATE=$(date +"%A, %b %d")
   let "SPACES = DEVCOUNT * 5 + 42"  # 5 spaces per drive
   printf "\n%-*s %3s %16s %29s \n" $SPACES "$DATE" "CPU" "New_Fan%" "New_RPM_____________________________"
   echo -n "          "
   while read -r LINE ; do
      get_disk_name
      printf "%-5s" "$DEVID"
   done <<< "$DEVLIST"
   printf "%4s %5s %6s %6s %6s %3s %-7s %s %-4s %5s %5s %5s %5s %5s" "Tmax" "Tmean" "ERRc" "P" "D" "TEMP" "MODE" "CPU" "PER" "FANA" "FAN1" "FAN2" "FAN3" "FAN4"
}

#################################################
# function read_sdr_cached
# OPTIMIZED: Cache SDR data to avoid repeated expensive calls
#################################################
function read_sdr_cached {
   local current_time=$(date +%s)
   
   # Check if cache is still valid
   if [ -z "$SDR_CACHE" ] || [ $((current_time - SDR_CACHE_TIME)) -ge $SDR_CACHE_TTL ]; then
      # Cache expired or empty - fetch new SDR data
      SDR_CACHE=$($IPMITOOL sdr 2>/dev/null)
      SDR_CACHE_TIME=$current_time
      ((IPMI_CALL_COUNT++))
   fi
   
   echo "$SDR_CACHE"
}

#################################################
# function read_fan_data
# OPTIMIZED: Uses cached SDR instead of repeated calls
#################################################
function read_fan_data {

   # If set by user, read duty cycles, convert to decimal.
   if [ $HOW_DUTY == 1 ] ; then
      DUTY_CPU=$($IPMITOOL raw 0x30 0x70 0x66 0 $ZONE_CPU 2>/dev/null)
      DUTY_CPU=$((0x$(echo $DUTY_CPU)))
      ((IPMI_CALL_COUNT++))
      DUTY_PER=$($IPMITOOL raw 0x30 0x70 0x66 0 $ZONE_PER 2>/dev/null)
      DUTY_PER=$((0x$(echo $DUTY_PER)))
      ((IPMI_CALL_COUNT++))
   fi
   
   # Read fan mode, convert to decimal, get text equivalent.
   MODE=$($IPMITOOL raw 0x30 0x45 0 2>/dev/null)
   MODE=$((0x$(echo $MODE)))
   ((IPMI_CALL_COUNT++))
   case $MODE in
      0) MODEt="Standard" ;;
      1) MODEt="Full" ;;
      2) MODEt="Optimal" ;;
      4) MODEt="HeavyIO" ;;
   esac

   # Get reported fan speed in RPM from cached SDR data.
   SDR=$(read_sdr_cached)
   FAN1=$(echo "$SDR" | grep "FAN1" | grep -Eo '[0-9]{3,5}')
   FAN2=$(echo "$SDR" | grep "FAN2" | grep -Eo '[0-9]{3,5}')
   FAN3=$(echo "$SDR" | grep "FAN3" | grep -Eo '[0-9]{3,5}')
   FAN4=$(echo "$SDR" | grep "FAN4" | grep -Eo '[0-9]{3,5}')
   FAN5=$(echo "$SDR" | grep "FAN5" | grep -Eo '[0-9]{3,5}')
   FAN6=$(echo "$SDR" | grep "FAN6" | grep -Eo '[0-9]{3,5}')
   FANA=$(echo "$SDR" | grep "FANA" | grep -Eo '[0-9]{3,5}')
   FANB=$(echo "$SDR" | grep "FANB" | grep -Eo '[0-9]{3,5}')
}

##############################################
# function CPU_check_adjust
# Get CPU temp. Calculate a new DUTY_CPU.
# Send to function adjust_fans.
##############################################
function CPU_check_adjust {
   # TrueNAS SCALE: Get CPU temp via IPMI or thermal zones
   if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
      # Use Linux thermal zone (preferred on SCALE)
      CPU_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
      CPU_TEMP=$((CPU_TEMP / 1000))
   else
      # Fallback to IPMI
      CPU_TEMP=$($IPMITOOL sensor get "CPU1 Temp" 2>/dev/null | awk '/Sensor Reading/ {print $4}')
      ((IPMI_CALL_COUNT++))
   fi

   # If we couldn't get CPU temp, try from cached SDR
   if [[ -z "$CPU_TEMP" || "$CPU_TEMP" == "na" ]]; then
      SDR=$(read_sdr_cached)
      CPU_TEMP=$(echo "$SDR" | grep "CPU1 Temp" | grep -Eo '[0-9]{2,3}' | head -1)
   fi

   DUTY_CPU_LAST=$DUTY_CPU

   # Calculate new duty cycle
   let DUTY_CPU="$(( (CPU_TEMP - CPU_REF) * CPU_SCALE + DUTY_CPU_MIN ))"

   # Don't allow duty cycle outside min-max
   if [[ $DUTY_CPU -gt $DUTY_CPU_MAX ]]; then DUTY_CPU=$DUTY_CPU_MAX; fi
   if [[ $DUTY_CPU -lt $DUTY_CPU_MIN ]]; then DUTY_CPU=$DUTY_CPU_MIN; fi
      
   adjust_fans $ZONE_CPU $DUTY_CPU $DUTY_CPU_LAST

   # Allow PER fans to come down if PD < 0 and drives are cool
   if [[ $PD -lt 0 ]] && [[ -n "$Tmean" ]] && awk "BEGIN {exit !($Tmean < ($SP-1))}"; then
      DUTY_PER_LAST=$DUTY_PER
      DUTY_PER=$(( DUTY_PER + PD ))
      if [[ $DUTY_PER -lt $DUTY_PER_MIN ]]; then DUTY_PER=$DUTY_PER_MIN; fi
      adjust_fans $ZONE_PER $DUTY_PER $DUTY_PER_LAST
   fi

   # OPTIMIZED: Reduced CPU check interval (default 30s instead of 1s)
   sleep $CPU_T
   
   if [ $CPU_LOG_YES == 1 ] ; then
      print_interim_CPU | tee -a $CPU_LOG >/dev/null
   fi
   
   # Call user-defined function if it exists
   declare -f -F Post_CPU_check_adjust >/dev/null && Post_CPU_check_adjust
}

##############################################
# function DRIVES_check_adjust
# Go through each drive, getting temp.
# Calculate max and mean temp, then PID.
# Call adjust_fans.
##############################################
function DRIVES_check_adjust {
   Tmax=0; Tsum=0
   i=0
   
   while read -r LINE ; do
      get_disk_name
      
      # Skip if empty
      [[ -z "$DEVID" ]] && continue
      
      # Get drive temperature using smartctl
      TEMP=""
      SMARTOUT=$(smartctl -a -n standby "/dev/$DEVID" 2>/dev/null)
      RETURN=$?
      BIT0=$(( RETURN & 1 ))
      BIT1=$(( RETURN & 2 ))
      
      if [ $BIT0 -eq 0 ]; then
         if [ $BIT1 -eq 0 ]; then
            STATUS="*"  # spinning
         else
            STATUS="_"  # standby
         fi
      else
         STATUS="?"  # missing/error
      fi

      # Get temperature if spinning
      if [ "$STATUS" == "*" ] ; then
         # Try SATA format first
         if echo "$SMARTOUT" | grep -Fq "Temperature_Celsius" ; then
            TEMP=$(echo "$SMARTOUT" | grep "Temperature_Celsius" | awk '{print $10}')
         # Try SAS format
         elif echo "$SMARTOUT" | grep -Fq "Current Drive Temperature" ; then
            TEMP=$(echo "$SMARTOUT" | grep "Current Drive Temperature" | awk '{print $4}')
         # Try NVMe format
         elif echo "$SMARTOUT" | grep -Fq "Temperature:" ; then
            TEMP=$(echo "$SMARTOUT" | grep "Temperature:" | head -1 | grep -Eo '[0-9]+' | head -1)
         fi
         
         if [[ -n "$TEMP" && "$TEMP" =~ ^[0-9]+$ ]]; then
            let "Tsum += $TEMP"
            if [[ $TEMP -gt $Tmax ]]; then Tmax=$TEMP; fi
            let "i += 1"
         fi
      fi
      printf "%s%-2d  " "$STATUS" "${TEMP:-0}"
   done <<< "$DEVLIST"

   DUTY_PER_LAST=$DUTY_PER
   
   # If no disks are spinning
   if [ $i -eq 0 ]; then
      Tmean=""; Tmax=""; P=""; D=""; ERRc=""
      DUTY_PER=$DUTY_PER_MIN
   else
      # Need ERRc value if all drives had been spun down last time
      if [[ -z "$ERRc" ]]; then ERRc=0; fi
      
      Tmean=$(awk "BEGIN {printf \"%.2f\", $Tsum / $i}")
      ERRp=$ERRc
      ERRc=$(awk "BEGIN {printf \"%.2f\", ($Tmean - $SP)}")
      P=$(awk "BEGIN {printf \"%.3f\", ($Kp * $ERRc)}")
      D=$(awk "BEGIN {printf \"%.4f\", $Kd * ($ERRc - $ERRp) / $DRIVE_T}")
      PD=$(awk "BEGIN {printf \"%.0f\", $P + $D}")

      # Round for printing
      Tmean=$(printf %0.2f "$Tmean")
      ERRc=$(printf %0.2f "$ERRc")
      P=$(printf %0.2f "$P")
      D=$(printf %0.2f "$D")
      PD=$(printf %0.f "$PD")

      let "DUTY_PER = $DUTY_PER_LAST + $PD"

      # Don't allow duty cycle outside min-max
      if [[ $DUTY_PER -gt $DUTY_PER_MAX ]]; then DUTY_PER=$DUTY_PER_MAX; fi
      if [[ $DUTY_PER -lt $DUTY_PER_MIN ]]; then DUTY_PER=$DUTY_PER_MIN; fi
   fi

   adjust_fans $ZONE_PER $DUTY_PER $DUTY_PER_LAST
   
   printf "^%-3s %5s" "${Tmax:---}" "${Tmean:----}"
   
   # Call user-defined function if it exists
   declare -f -F Post_DRIVES_check_adjust >/dev/null && Post_DRIVES_check_adjust
}

##############################################
# function adjust_fans
# Zone, new duty, and last duty are passed as parameters
##############################################
function adjust_fans {
   ZONE=$1
   DUTY=$2
   DUTY_LAST=$3

   if [[ $DUTY -ne $DUTY_LAST ]] || [[ $FIRST_TIME -eq 1 ]]; then
      # Set new duty cycle via IPMI
      $IPMITOOL raw 0x30 0x70 0x66 1 "$ZONE" "$DUTY" >/dev/null 2>&1
      ((IPMI_CALL_COUNT++))
   fi
   FIRST_TIME=0
}

##############################################
# function print_interim_CPU 
##############################################
function print_interim_CPU {
   SDR=$(read_sdr_cached)
   RPM=$(echo "$SDR" | grep "$RPM_CPU" | grep -Eo '[0-9]{2,5}')
   TIME=$(date "+%H:%M:%S"); echo -n "$TIME  "
   printf "%7s %5d %5d \n" "${RPM:----}" "$CPU_TEMP" "$DUTY_CPU"
}

##############################################
# function mismatch_test 
# OPTIMIZED: Limited to 2 retries to prevent cascade
# Tests for mismatch between fan duty and RPMs
##############################################
function mismatch_test {
   MISMATCH=0; MISMATCH_CPU=0; MISMATCH_PER=0

   if [[ $DUTY_CPU -ge 95 && ${!RPM_CPU} -lt $RPM_CPU_MAX ]] || [[ $DUTY_CPU -lt 25 && ${!RPM_CPU} -gt $RPM_CPU_30 ]]; then
      MISMATCH=1; MISMATCH_CPU=1
      printf "\n%s\n" "Mismatch between CPU Duty and RPMs -- DUTY_CPU=$DUTY_CPU; RPM_CPU=${!RPM_CPU}"
   fi
   if [[ $DUTY_PER -ge 95 && ${!RPM_PER} -lt $RPM_PER_MAX ]] || [[ $DUTY_PER -lt 25 && ${!RPM_PER} -gt $RPM_PER_30 ]]; then
      MISMATCH=1; MISMATCH_PER=1
      printf "\n%s\n" "Mismatch between PER Duty and RPMs -- DUTY_PER=$DUTY_PER; RPM_PER=${!RPM_PER}"
   fi
}

##############################################
# function force_set_fans 
##############################################
function force_set_fans {
   if [ $MISMATCH_CPU == 1 ]; then
      FIRST_TIME=1
      adjust_fans $ZONE_CPU $DUTY_CPU $DUTY_CPU_LAST
      echo "Attempting to fix CPU mismatch  "
      sleep 5
   fi
   if [ $MISMATCH_PER == 1 ]; then
      FIRST_TIME=1
      adjust_fans $ZONE_PER $DUTY_PER $DUTY_PER_LAST
      echo "Attempting to fix PER mismatch  "
      sleep 5
   fi
}

##############################################
# function reset_bmc 
##############################################
function reset_bmc {
   TIME=$(date "+%H:%M:%S"); echo -n "$TIME  "
   echo -n "Resetting BMC after second attempt failed to fix mismatch -- "
   $IPMITOOL bmc reset cold 2>/dev/null
   ((IPMI_CALL_COUNT++))
   sleep 120
   # Clear cache after BMC reset
   SDR_CACHE=""
   read_fan_data
}

#####################################################
# SETUP
#####################################################

# Print settings at beginning of log
printf "\n****** SETTINGS - TrueNAS SCALE (OPTIMIZED) ******\n"
printf "Version: %s\n" "$VERSION"
printf "IPMI Host: %s\n" "$IPMI_HOST"
printf "CPU zone %s; Peripheral zone %s\n" $ZONE_CPU $ZONE_PER
printf "CPU fans min/max duty cycle: %s/%s\n" $DUTY_CPU_MIN $DUTY_CPU_MAX
printf "PER fans min/max duty cycle: %s/%s\n" $DUTY_PER_MIN $DUTY_PER_MAX
printf "CPU fans - measured RPMs at 30%% and 100%% duty cycle: %s/%s\n" $RPM_CPU_30 $RPM_CPU_MAX
printf "PER fans - measured RPMs at 30%% and 100%% duty cycle: %s/%s\n" $RPM_PER_30 $RPM_PER_MAX
printf "Drive temperature setpoint (C): %s\n" $SP
printf "Kp=%s, Kd=%s\n" $Kp $Kd
printf "Drive check interval (main cycle; minutes): %s\n" $DRIVE_T
printf "CPU check interval (seconds): %s\n" $CPU_T
printf "CPU reference temperature (C): %s\n" $CPU_REF
printf "CPU scalar: %s\n" $CPU_SCALE
printf "SDR Cache TTL: %s seconds\n" $SDR_CACHE_TTL

if [ $HOW_DUTY == 1 ] ; then
   printf "Reading fan duty from board \n"
else 
   printf "Assuming fan duty as set \n"
fi

# Get list of drives - TrueNAS SCALE uses Linux device names
# Get spinning disks (HDDs and SSDs, exclude loop devices, etc.)
DEVLIST_RAW=$(lsblk -d -n -o NAME,TYPE,TRAN 2>/dev/null | grep -E "disk.*(sata|sas|nvme)" | awk '{print $1}')
# Fallback: get all sd* devices if above fails
if [[ -z "$DEVLIST_RAW" ]]; then
   DEVLIST_RAW=$(ls /dev/sd? 2>/dev/null | xargs -n1 basename)
fi

# Filter out virtual disks (VMware, VirtualBox, QEMU, etc.)
DEVLIST=""
VIRTUAL_COUNT=0
for dev in $DEVLIST_RAW; do
   VENDOR=$(smartctl -i "/dev/$dev" 2>/dev/null | grep -i "vendor" | awk '{print $2}')
   PRODUCT=$(smartctl -i "/dev/$dev" 2>/dev/null | grep -i "product" | awk '{print $2}')
   MODEL=$(smartctl -i "/dev/$dev" 2>/dev/null | grep -i "device model" | awk '{print $3}')
   
   # Check for virtual disk indicators
   if [[ "$VENDOR" =~ ^(VMware|VBOX|QEMU|Msft|Virtual|Xen)$ ]] || \
      [[ "$PRODUCT" =~ [Vv]irtual ]] || \
      [[ "$MODEL" =~ [Vv]irtual ]]; then
      ((VIRTUAL_COUNT++))
      continue  # Skip virtual disks
   fi
   
   # Add to list
   if [[ -z "$DEVLIST" ]]; then
      DEVLIST="$dev"
   else
      DEVLIST="$DEVLIST"$'\n'"$dev"
   fi
done

DEVCOUNT=$(echo "$DEVLIST" | grep -c .)

printf "Found %d physical drives (excluded %d virtual disks)\n" "$DEVCOUNT" "$VIRTUAL_COUNT"

# Variables for indirect reference to fan RPMs
if [[ $ZONE_PER -eq 0 ]]; then
   RPM_PER=FAN1
   RPM_CPU=FANA
else
   RPM_PER=FANA
   RPM_CPU=FAN1
fi

CPU_LOOPS=$(awk "BEGIN {printf \"%.0f\", $DRIVE_T * 60 / $CPU_T}")
I=0; ERRc=0; PD=0
FIRST_TIME=1

# Alter RPM thresholds to allow some slop
RPM_CPU_30=$(awk "BEGIN {printf \"%.0f\", 1.2 * $RPM_CPU_30}")
RPM_CPU_MAX=$(awk "BEGIN {printf \"%.0f\", 0.8 * $RPM_CPU_MAX}")
RPM_PER_30=$(awk "BEGIN {printf \"%.0f\", 1.2 * $RPM_PER_30}")
RPM_PER_MAX=$(awk "BEGIN {printf \"%.0f\", 0.8 * $RPM_PER_MAX}")

read_fan_data

# If mode not Full, set it to Full for manual control
if [[ $MODE -ne 1 ]]; then
   $IPMITOOL raw 0x30 0x45 1 1 >/dev/null 2>&1
   ((IPMI_CALL_COUNT++))
   sleep 1
fi

# Initialize fan duty if needed
if [[ ${!RPM_PER} -ge $RPM_PER_MAX ]] || [[ -z "${DUTY_PER+x}" ]]; then
   $IPMITOOL raw 0x30 0x70 0x66 1 $ZONE_PER 50 >/dev/null 2>&1
   ((IPMI_CALL_COUNT++))
   DUTY_PER=50; sleep 1
fi
if [[ ${!RPM_CPU} -ge $RPM_CPU_MAX ]] || [[ -z "${DUTY_CPU+x}" ]]; then
   $IPMITOOL raw 0x30 0x70 0x66 1 $ZONE_CPU 50 >/dev/null 2>&1
   ((IPMI_CALL_COUNT++))
   DUTY_CPU=50; sleep 1
fi

# Check drives for smartctl issues
while read -r LINE ; do
   get_disk_name
   [[ -z "$DEVID" ]] && continue
   smartctl -a -n standby "/dev/$DEVID" > /tmp/tempfile 2>/dev/null
   if [ $? -gt 2 ]; then
      printf "\n"
      printf "*******************************************************\n"
      printf "* WARNING - Drive %-4s has a record of past errors,   *\n" "$DEVID"
      printf "* is currently failing, or is not communicating well. *\n"
      printf "*******************************************************\n"
   fi
done <<< "$DEVLIST"

printf "\n%s %36s %s \n" "Key: * spinning; _ standby; ? unknown" "Version" "$VERSION"
print_header

# Get initial CPU temp for first round
SDR=$(read_sdr_cached)
CPU_TEMP=$(echo "$SDR" | grep "CPU1 Temp" | grep -Eo '[0-9]{2,5}')

# Initialize CPU log
if [ $CPU_LOG_YES == 1 ] ; then
   printf "%s \n%s \n%17s %5s %5s \n" "$DATE" "Printed every CPU cycle" $RPM_CPU "Temp" "Duty" | tee $CPU_LOG >/dev/null
fi

###########################################
# Main loop
###########################################
CYCLE_COUNT=0
while true ; do
   ((CYCLE_COUNT++))
   
   # Print header every quarter day
   HM=$(date +%k%M)
   HM=$(echo $HM | awk '{print $1 + 0}')
   R=$(( HM % 600 ))
   if (( R < DRIVE_T )); then
      print_header
   fi

   echo
   TIME=$(date "+%H:%M:%S"); echo -n "$TIME  "
   
   DRIVES_check_adjust
   
   sleep 5
   read_fan_data

   printf "%7s %6s %6.6s %4s %-7s %3d %3d %6s %5s %5s %5s %5s" "${ERRc:----}" "${P:----}" "${D:----}" "$CPU_TEMP" "$MODEt" "$DUTY_CPU" "$DUTY_PER" "${FANA:----}" "${FAN1:----}" "${FAN2:----}" "${FAN3:----}" "${FAN4:----}"

   # Save last status to file for easy monitoring
   # File: spinpid2_scale.status - contains only the most recent reading
   STATUS_FILE="${LOG_DIR}/spinpid2_scale.status"
   printf "Last Update: %s\nTmax: %s°C | Tmean: %s°C | ERRc: %s | CPU: %s°C | Mode: %s\nDuty CPU: %d%% | Duty PER: %d%%\nFANA: %s | FAN1: %s | FAN2: %s | FAN3: %s | FAN4: %s RPM\nIPMI Calls: %d (Cycle: %d)\n" \
      "$(date '+%Y-%m-%d %H:%M:%S')" \
      "${Tmax:---}" "${Tmean:----}" "${ERRc:----}" "$CPU_TEMP" "$MODEt" \
      "$DUTY_CPU" "$DUTY_PER" \
      "${FANA:----}" "${FAN1:----}" "${FAN2:----}" "${FAN3:----}" "${FAN4:----}" \
      "$IPMI_CALL_COUNT" "$CYCLE_COUNT" \
      > "$STATUS_FILE"

   # OPTIMIZED: Mismatch test loop with maximum 2 retries (was unlimited)
   ATTEMPTS=0
   mismatch_test
   
   while true; do
      if [ $MISMATCH == 1 ]; then
         force_set_fans
         let "ATTEMPTS += 1"
         read_fan_data
         mismatch_test
      else
         break
      fi

      # OPTIMIZATION: Maximum 2 attempts before giving up
      if [ $ATTEMPTS -ge 2 ]; then
         if [ $MISMATCH == 1 ]; then
            reset_bmc
            force_set_fans
            read_fan_data
            mismatch_test
         fi
         break
      fi
   done

   # CPU loop
   i=0
   while [ $i -lt "$CPU_LOOPS" ]; do
      CPU_check_adjust
      let i=i+1
   done
done
