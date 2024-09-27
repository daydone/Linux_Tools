#!/bin/bash

# Function to show usage
usage() {
  echo "Usage: $0 -h <hosts> -c <command>"
  echo "Commands:"
  echo "  diskusage   - Check largest directories and disk utilization"
  echo "  files       - Check largest files"
  echo "  run_all     - Run all checks: disk utilization, largest directories, and largest files"
  exit 1
}

# Variables
HOSTS=()
COMMAND=""

# Parse the command-line arguments
while getopts ":h:c:" opt; do
  case ${opt} in
    h)
      HOSTS+=(${OPTARG})  # Add the hosts to the array
      ;;
    c)
      COMMAND=${OPTARG}   # Set the command
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      usage
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      usage
      ;;
  esac
done

# Check if hosts and command are provided
if [[ ${#HOSTS[@]} -eq 0 || -z "$COMMAND" ]]; then
  usage
fi

# Function to check disk utilization for each partition
check_disk_utilization() {
  local host=$1
  echo "Disk utilization on $host:"
  ssh $host 'df -h'
  echo
}

# Function to check largest directories with sudo and suppress errors
check_disk_usage() {
  local host=$1
  echo "Checking largest directories on $host..."
  ssh $host 'sudo du -ah / 2>/dev/null | sort -rh | head -n 10'
}

# Function to check largest files with sudo and suppress errors
check_largest_files() {
  local host=$1
  echo "Checking largest files on $host..."
  ssh $host 'sudo find / -type f 2>/dev/null -exec du -h {} + | sort -rh | head -n 10'
}

# Main loop to execute command on each host
for host in "${HOSTS[@]}"; do
  case $COMMAND in
    diskusage)
      check_disk_utilization "$host"  # Step 1: Check disk utilization
      check_disk_usage "$host"        # Step 2: Check largest directories
      ;;
    files)
      check_largest_files "$host"     # Check largest files
      ;;
    run_all)
      echo "Running all checks on $host..."
      check_disk_utilization "$host"  # Step 1: Check disk utilization
      check_disk_usage "$host"        # Step 2: Check largest directories
      check_largest_files "$host"     # Step 3: Check largest files
      ;;
    *)
      echo "Invalid command: $COMMAND"
      usage
      ;;
  esac
done

