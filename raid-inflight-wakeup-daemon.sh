#!/bin/bash

# --- Configuration ---
# Enter the stable device IDs of your RAID members here.
# Find them using the command: ls -l /dev/disk/by-id/
DISK_IDS=(
    "ata-WDC_WD80EFAX-68KNBN0_VAKKATYL"
    "ata-WDC_WD80EFAX-68KNBN0_VAG81VEL"
    "ata-WDC_WD80EFAX-68KNBN0_VDHLMYRD"
)

# Polling interval in seconds. A short interval is crucial for responsiveness.
POLL_INTERVAL=0.2

# --- Initialization & Mapping ---
# Use a lock file to prevent multiple instances from running
LOCK_FILE="/var/run/raid-inflight-wakeup.pid"
if [ -e "$LOCK_FILE" ] && kill -0 "$(cat "$LOCK_FILE")" 2>/dev/null; then
    echo "Script is already running."
    exit 1
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

echo "Daemon started. Mapping device IDs..."

declare -a DEVICES
for id in "${DISK_IDS[@]}"; do
    id_path="/dev/disk/by-id/${id}"
    if [[ -L "$id_path" ]]; then # Check if it's a symbolic link
        device_path=$(readlink -f "$id_path")
        device_name=$(basename "$device_path")
        DEVICES+=("$device_name")
        echo "Mapping successful: ${id} -> ${device_name}"
    else
        echo "ERROR: Device ID ${id} not found or is not a symlink. Exiting."
        exit 1
    fi
done

if [ ${#DEVICES[@]} -eq 0 ]; then
    echo "ERROR: No valid devices found after mapping. Exiting."
    exit 1
fi

# --- Final Wakeup Function with Parallel Probing ---
wakeup_sleeping_drives() {
    echo "-> Starting parallel status checks and waking up sleeping drives..."
    
    for dev in "${DEVICES[@]}"; do
        # Start a subshell in the background for each device
        (
            # Logic for a single drive
            status=$(hdparm -C "/dev/$dev")
            
            if echo "$status" | grep -q "standby"; then
                # This message is only logged if the drive is sleeping
                echo "  - ${dev} is in standby. Sending wakeup command (dd with direct I/O)..."
                dd if="/dev/$dev" of=/dev/null bs=512 count=1 status=none iflag=direct
            fi
        ) &
    done
    
    # Wait for all background subshells (the individual checks) to complete
    wait
    echo "-> Parallel wakeup routine finished."
}

# --- Main Loop ---
echo "Monitoring started for devices: ${DEVICES[*]}"

while true; do
    for dev in "${DEVICES[@]}"; do
        # Read the number of read and write requests in the queue
        if ! read -r reads writes < "/sys/block/$dev/inflight"; then
            echo "Warning: Could not read inflight status for ${dev}. It might be offline."
            # Wait a bit longer before retrying to avoid spamming logs if a drive is disconnected
            sleep 10 
            continue
        fi
        
        # If the sum is greater than 0, the kernel has queued an I/O operation
        if [[ $((reads + writes)) -gt 0 ]]; then
            echo "In-flight request detected on ${dev} (${reads}r/${writes}w). Triggering wakeup."
            
            wakeup_sleeping_drives
            
            # A longer pause after an action to let the system stabilize
            echo "Waiting 15 seconds after trigger..."
            sleep 15
            
            # Jump to the beginning of the outer while loop for a new round
            continue 2
        fi
    done
    
    sleep "$POLL_INTERVAL"
done