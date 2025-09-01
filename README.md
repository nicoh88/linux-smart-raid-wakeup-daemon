# Smart RAID Wakeup Daemon

A smart daemon to spin up all drives in a Linux software RAID array simultaneously upon first access, avoiding long sequential spin-up delays.

> **A Note from the Author**
>
> I am not a professional software developer, but an IT admin with a background in scripting. This project came to life through a combination of practical experience, assistance from AI / KI, and a good amount of trial and error to solve a real-world problem.
>
> Since this is a practical solution, improvements and suggestions are highly encouraged! Please feel free to submit a Pull Request with any enhancements. If you have any questions about the approach or need help, you're welcome to open an Issue.

## The Problem

When using Linux software RAID (`mdadm`) with multiple mechanical hard drives, a common annoyance occurs when accessing the array after the drives have entered standby mode (spin-down) to save power. Instead of waking up simultaneously, the drives often spin up one by one.

If a single drive takes 10 seconds to wake up, accessing a 3-drive RAID 5 array can result in a frustrating **30-second delay** before the array is responsive. This script is designed to reduce that delay to the time it takes for a single drive to spin up (~10 seconds).

## The Challenge: Finding the Right Trigger

The core challenge is to detect the very first I/O attempt *before* the spin-up process is complete. Several approaches were considered and discarded:

* **Polling I/O Statistics (`/proc/diskstats`):** This is the most obvious approach. However, these statistics are only updated *after* an I/O operation is **complete**. This means the trigger would fire after the first drive has already finished its 10-second spin-up, which is too late to achieve true parallelism.

* **Event-Driven (`udev`):** The "textbook" solution for reacting to hardware events in Linux is `udev`. The idea is to create a rule that triggers an action on a device "change" event. However, testing revealed that many systems (depending on the kernel version and SATA driver, e.g., `ahci`) **do not generate a reliable `uevent`** when a drive begins to spin up from standby. This makes a `udev`-based solution non-portable and unreliable in many real-world scenarios.

## The Solution: The `inflight` Monitor

This daemon implements a more elegant and reliable solution by monitoring the kernel's I/O scheduler queue.

The file `/sys/block/<device>/inflight` instantly reflects the number of I/O requests that have been **queued** for a device, but not yet completed. This is the perfect near-real-time trigger.

The daemon's logic is as follows:
1.  It polls the `inflight` file for all configured drives at a high frequency (e.g., every 200ms).
2.  Upon detecting a non-zero value (meaning the kernel has just tried to access a drive), it immediately triggers the main wakeup logic.
3.  The wakeup logic runs **in parallel** for all drives in the array.
4.  Each parallel task checks the drive's power status using `hdparm -C`.
5.  A wakeup command (`dd iflag=direct`) is sent **only** to the drives that are currently in standby. This prevents an infinite loop of waking up already-active drives.

This process is highly optimized to ensure that the wakeup commands for the sleeping drives are sent within milliseconds of the initial I/O attempt, achieving the fastest possible parallel spin-up.

### Key Features
-   **True Parallel Spin-Up:** Reduces array access time from `N * spindown_time` to `1 * spindown_time`.
-   **Intelligent Trigger:** Uses the `inflight` I/O queue for near-instant detection, superior to `iostat` or `udev`.
-   **Robust Operation:**
    -   Uses stable `/dev/disk/by-id/` names.
    -   Checks drive status in parallel to avoid bottlenecks.
    -   Only sends wakeup commands to drives that are actually sleeping.
    -   Bypasses the kernel's page cache using `iflag=direct` to guarantee a physical wakeup every time.
-   **Systemd Integration:** Runs as a reliable background service.

## Installation

1.  **Copy the Script and Service Files:**
    Place `raid-inflight-wakeup-daemon.sh` in `/usr/local/bin/` and `raid-inflight-wakeup-daemon.service` in `/etc/systemd/system/`.

2.  **Configure the Script:**
    Open `/usr/local/bin/raid-inflight-wakeup-daemon.sh` and edit the `DISK_IDS` array to match the device IDs of your RAID members. You can find them with `ls -l /dev/disk/by-id/`.
    ```bash
    DISK_IDS=(
        "ata-YOUR_DRIVE_ID_1"
        "ata-YOUR_DRIVE_ID_2"
        "ata-YOUR_DRIVE_ID_3"
    )
    ```

3.  **Make the script executable:**
    ```bash
    sudo chmod +x /usr/local/bin/raid-inflight-wakeup-daemon.sh
    ```

4.  **Enable and start the daemon:**
    ```bash
    sudo systemctl daemon-reload
    sudo systemctl enable raid-inflight-wakeup-daemon.service
    sudo systemctl start raid-inflight-wakeup-daemon.service
    ```

## Usage

The daemon runs automatically in the background. You can manage it using standard `systemctl` commands:

-   **Check status and logs:**
    ```bash
    sudo systemctl status raid-inflight-wakeup-daemon.service
    journalctl -u raid-inflight-wakeup-daemon.service -f
    tail -f /var/log/raid-inflight-wakeup.log
    ```
-   **Stop the service:**
    ```bash
    sudo systemctl stop raid-inflight-wakeup-daemon.service
    ```
-   **Start the service:**
    ```bash
    sudo systemctl start raid-inflight-wakeup-daemon.service
    ```
-   **Disable autostart on boot:**
    ```bash
    sudo systemctl disable raid-inflight-wakeup-daemon.service
    ```