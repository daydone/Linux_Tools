#!/bin/bash

# Define the directory to search for .wav files
SEARCH_DIR="/media/"

# Define the remote server and path
REMOTE_SERVER="fromflowpnp@archive-pnp:/media/"

# Find .wav files older than 2 days
find "$SEARCH_DIR" -name "*.wav" -mtime +2 | while read file
do
  # Start rsync in the background
  rsync --remove-source-files -av "$file" "$REMOTE_SERVER" &
  
  # Get the PID of the rsync command
  RSYNC_PID=$!

  # Limit the rsync CPU usage to 10%
  cpulimit -p $RSYNC_PID -l 10

  # Wait for the rsync process to finish
  wait $RSYNC_PID
done

