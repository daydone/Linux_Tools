#!/bin/bash

# Default to dry run mode
DRY_RUN=true

# Check for dry run option
if [[ $1 == "--dry-run" ]]; then
    DRY_RUN=true
else
    DRY_RUN=false
fi

# Log file
log_file="/var/log/check_logs.log"

# Function to log messages
log() {
    echo "$(date "+%Y-%m-%d %H:%M:%S") - $1" >> "$log_file"
}

# Log process start time
log "Archive process started"

# Get today's date in seconds since the Unix epoch
today_date=$(date +%s)

# Function to move files with error handling
move_file() {
    local filepath=$1
    local target_dir=$2

    if $DRY_RUN; then
        log "DRY RUN: Would move $filepath to $target_dir/"
    else
        # Create the target directory if it doesn't exist
        if mkdir -p "$target_dir"; then
            log "Created directory: $target_dir"
        else
            log "Failed to create directory: $target_dir"
            return 1
        fi

        # Move the file to the target directory
        if mv "$filepath" "$target_dir/"; then
            log "Moved File: $filepath to $target_dir/"
        else
            log "Failed to move $filepath to $target_dir/"
            return 1
        fi
    fi
}

# First part: Sort files starting with "1-" into YYYY-MM-DD directories
log "Starting file sorting operation"
base_dirs="/media"
for base_dir in $base_dirs; do
    find "$base_dir" -maxdepth 1 -type f -name "1-*" | while IFS= read -r filepath; do
        # Get the modification date of the file in YYYY-MM-DD format
        mod_date=$(stat --format '%y' "$filepath" | cut -d ' ' -f 1)
        if [ $? -ne 0 ]; then
            log "Failed to get modification date for $filepath"
            continue
        fi
        
        # Create the target directory path
        target_dir="$base_dir/$mod_date"

        # Move the file
        move_file "$filepath" "$target_dir"
    done
done
log "File sorting operation completed"

# Function to determine destination based on day of the month
get_destination() {
    local date_str=$1
    local day=${date_str:8:2}
    if [ "$day" -le 15 ]; then
        echo "/media/"
    else
        echo "/media2/"
    fi
}

# Collect files older than today's date into an array
files_to_transfer=()
for item in /media/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*; do
    if [ -f "$item" ] || [ -d "$item" ]; then
        item_date=$(echo "$item" | grep -oP '^\d{4}-\d{2}-\d{2}')
        item_date_sec=$(date -d "$item_date" +%s)
        if [ $item_date_sec -lt $today_date ]; then
            files_to_transfer+=("$item")
        fi
    fi
done

# Create a temporary file for capturing rsync output
temp_log=$(mktemp)

# Transfer all collected files using rsync with more verbosity and a timeout
if [ ${#files_to_transfer[@]} -gt 0 ]; then
    for file in "${files_to_transfer[@]}"; do
        # Extract the date part of the filename
        date_str=$(basename "$file")
        destination=$(get_destination "$date_str")
        
        if $DRY_RUN; then
            log "DRY RUN: Would transfer $file to $destination"
        else
            log "Transferring $file to $destination"
            timeout 300 rsync --remove-source-files -av "$file" "user@host:$destination" &>> $temp_log
            if [ $? -eq 0 ]; then
                log "rsync successful for $file"
            else
                log "rsync failed for $file"
                log "Error details for $file:"
                cat $temp_log >> "$log_file"
            fi
        fi
    done
else
    log "No files to transfer"
fi

# Transfer any files for inbound recordings older than 1 day
# Create a temporary file for capturing rsync output
temp_log=$(mktemp)

# Find and transfer files that start with '1-' and are older than 1 day
find /media -type f -name '1-*' -mtime +1 -print0 | while IFS= read -r -d '' file; do
    date_str=$(stat --format '%y' "$file" | cut -d ' ' -f 1)
    destination=$(get_destination "$date_str")
    
    if $DRY_RUN; then
        log "DRY RUN: Would transfer $file to $destination"
    else
        log "Transferring $file to $destination"
        rsync --remove-source-files -av "$file" "fromflowpnp@archive-pnp:$destination" &>> $temp_log
        if [ $? -eq 0 ]; then
            log "rsync successful for $file"
        else
            log "rsync failed for $file"
            log "Error details for $file:"
            cat $temp_log >> "$log_file"
        fi
    fi
done

# Clean up the temporary log file
rm $temp_log

# Log process completion
log "Archive process completed"

