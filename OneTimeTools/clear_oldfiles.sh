#!/bin/bash

# Base directories to search within
base_dirs="/media /media2 /media3 /media4"
# Log file
log_file="/var/log/recording_organize.log"
# Dry run flag
dry_run=true

# Function to log messages
log() {
	echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" >> "$log_file"
}

# Function to remove directories with error handling
remove_dir() {
	local dirpath=$1

	if $dry_run; then
		echo "DRY RUN: Would remove directory $dirpath"
		log "DRY RUN: Would remove directory $dirpath"
	else
		if rm -rf "$dirpath"; then
			echo "Removed Directory: $dirpath"
			log "Removed Directory: $dirpath"
		else
			echo "Failed to remove directory $dirpath"
			log "Failed to remove directory $dirpath"
			return 1
		fi
	fi
}

# Loop through each base directory
echo "Starting directory cleanup process..."
for base_dir in $base_dirs; do
	echo "Checking base directory: $base_dir"
	# Find directories older than 90 days
	find "$base_dir" -mindepth 1 -maxdepth 1 -type d -name "[0-9]*-[0-9]*-[0-9]*" | while IFS= read -r dirpath; do
		echo "Evaluating directory: $dirpath"
		# Check if directory is older than 90 days
		dir_date=$(basename "$dirpath")
		dir_epoch=$(date -d "$dir_date" +%s)
		today_epoch=$(date +%s)
		diff_days=$(( (today_epoch - dir_epoch) / 86400 ))

		if [ $diff_days -gt 90 ]; then
			echo "Directory $dirpath is older than 90 days ($diff_days days old)."
			# Remove the directory
			remove_dir "$dirpath"
		else
			echo "Directory $dirpath is not older than 90 days ($diff_days days old)."
		fi
	done
done
echo "Directory cleanup process completed."
