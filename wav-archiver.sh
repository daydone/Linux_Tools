#!/bin/bash

# This script organizes and transfers media files, sorting and archiving them based on modification dates.
# It adjusts dates to PST and handles file transfers safely with dry-run capabilities.

# WARNING: Do not run this script manually. It is intended to be run by crontab.

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

# Function to transfer directories with error handling
transfer_directory() {
    local dirpath=$1
    local destination_base=$2
    local relative_dir=$(basename "$dirpath")

    if $DRY_RUN; then
        log "DRY RUN: Would transfer directory $dirpath to $destination_base/$relative_dir"
    else
        log "Transferring directory $dirpath to $destination_base/$relative_dir"
        timeout 300 rsync -av --remove-source-files "$dirpath" "fromflowpnp@archive-pnp:$destination_base/$relative_dir" &>> $temp_log
        if [ $? -eq 0 ]; then
            log "rsync successful for directory $dirpath"
        else
            log "rsync failed for directory $dirpath"
            log "Error details for directory $dirpath:"
            cat $temp_log >> "$log_file"
        fi
    fi
}

# First part: Sort files starting with "1-" into YYYY-MM-DD directories
log "Starting file sorting operation"
base_dirs="/media"
for base_dir in $base_dirs; do
    find "$base_dir" -maxdepth 1 -type f -name "1-*" | while IFS= read -r filepath; do
        # Get the modification date of the file in YYYY-MM-DD format
        mod_date=$(date -d "2 days ago 13:00" "+%Y-%m-%d")
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

# Collect files and directories older than today's date into an array
dirs_to_transfer=()
files_to_transfer=()
for item in /media/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*; do
    if [ -d "$item" ]; then
        item_date=$(basename "$item")
        item_date_sec=$(date -d "$item_date 13:00" +%s)
        if [ $item_date_sec -lt $today_date ]; then
            dirs_to_transfer+=("$item")
        fi
    elif [ -f "$item" ]; then
        item_date=$(basename "$item")
        item_date_sec=$(date -d "$item_date 13:00" +%s)
        if [ $item_date_sec -lt $today_date ]; then
            files_to_transfer+=("$item")
        fi
    fi
done

# Create a temporary file for capturing rsync output
temp_log=$(mktemp)

# Transfer all collected directories using rsync with more verbosity and a timeout
if [ ${#dirs_to_transfer[@]} -gt 0 ]; then
    for dir in "${dirs_to_transfer[@]}"; do
        # Extract the date part of the directory name
        date_str=$(basename "$dir")
        destination=$(get_destination "$date_str")

        transfer_directory "$dir" "$destination"
    done
else
    log "No directories to transfer"
fi

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
            timeout 300 rsync --remove-source-files -av "$file" "fromflowpnp@archive-pnp:$destination/$date_str" &>> $temp_log
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
    date_str=$(date -d "2 days ago 13:00" "+%Y-%m-%d")
    destination=$(get_destination "$date_str")
    
    if $DRY_RUN; then
        log "DRY RUN: Would transfer $file to $destination/$date_str"
    else
        log "Transferring $file to $destination/$date_str"
        rsync --remove-source-files -av "$file" "fromflowpnp@archive-pnp:$destination/$date_str" &>> $temp_log
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
