#!/bin/bash

# List of server IPs
servers=("10.0.96.7" "10.0.96.8" "10.0.96.9" "10.0.96.10" "10.0.96.11" "10.0.96.12" "10.0.96.13")

# Loop through each server and execute the commands
for server in "${servers[@]}"
do
    echo "Configuring firewall on $server"

    ssh $USER@$server 'bash -s' << 'EOF'
    # Check if firewalld is running
    if systemctl is-active --quiet firewalld; then
        echo "firewalld is running on $(hostname)"
        
        # Allow etcd ports
        sudo firewall-cmd --add-port=2379/tcp --permanent
        sudo firewall-cmd --add-port=2380/tcp --permanent
        sudo firewall-cmd --reload

        # Verify rules
        sudo firewall-cmd --list-all
    else
        echo "firewalld is not running on $(hostname)"
    fi
EOF

    echo "Firewall configuration completed on $server"
done

