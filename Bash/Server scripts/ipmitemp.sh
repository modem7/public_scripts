#!/bin/bash

# Set the IPMI tool command for Supermicro X11 motherboards to adjust the fan speed
IPMIBASE="ipmitool raw 0x30 0x70 0x66 0x01 0x00"

# Define the fan curve as an array of temperature/fan speed pairs
# The fan speed values should be in decimal format (0-100)
FAN_CURVE=( [0]=15 [35]=25 [40]=35 [50]=40 [55]=50 [70]=60 [80]=80 )

# Enable manual fan control (this might vary depending on your motherboard)
# Modify this command according to your motherboard's IPMI settings
$IPMIBASE

# Initialize the fan speed to 0
FAN_SPEED=0

# Initialize the CPU temperature to 0
CPU_TEMP=0

# Set the temperature change threshold for anticipatory fan speed changes
TEMP_THRESHOLD=5

# Set the time the script will wait for before checking the temperature again
SLEEP_TIME=5

# Loop indefinitely to monitor CPU temperatures
while true
do
  # Read the CPU temperature using lm-sensors
  NEW_CPU_TEMP=$(sensors | grep 'Package id 0:' | awk '{print $4}' | cut -c 2- | awk '{printf "%.0f\n", $1}')

  # Print the CPU temperature to the console if it has changed
  if [ $NEW_CPU_TEMP -ne $CPU_TEMP ]
  then
    echo "CPU Temperature: $NEW_CPU_TEMP°C"
    CPU_TEMP=$NEW_CPU_TEMP
  fi

  # Find the fan speed corresponding to the current temperature
  for TEMP in "${!FAN_CURVE[@]}"
  do
    if [ $CPU_TEMP -ge $TEMP ]
    then
      NEW_FAN_SPEED=${FAN_CURVE[$TEMP]}
      break
    fi
  done

  # Apply hysteresis to prevent rapid fan speed changes
  if [ $NEW_FAN_SPEED -gt $((FAN_SPEED + TEMP_THRESHOLD)) ] || [ $NEW_FAN_SPEED -lt $((FAN_SPEED - TEMP_THRESHOLD)) ]
  then
    echo "Setting fan speed to $NEW_FAN_SPEED"
    $IPMIBASE $NEW_FAN_SPEED
    FAN_SPEED=$NEW_FAN_SPEED
  fi

  # Wait for 5 seconds before checking the temperature again
  echo "Sleeping for $SLEEP_TIME seconds"
  sleep $SLEEP_TIME
done
