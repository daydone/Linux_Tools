#!/bin/bash

# Calculate current time in seconds since the epoch
current_time=$(date +%s)

# Calculate target time in seconds since the epoch (2:30 UTC the next day)
target_time=$(date -d '02:30 tomorrow' +%s)

# Calculate the difference in seconds
sleep_time=$((target_time - current_time))

# Wait for the calculated duration and then execute the script
sleep $sleep_time && /root/remove_files.sh >> removed_files_log

