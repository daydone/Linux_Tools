#!/bin/bash
#
# setup-kubectl-config.sh
#
# This script connects to K3s cluster servers via SSH and pulls current certificates
# to build a fresh kubectl configuration file.
#
# Requirements:
# - SSH access to cluster nodes with key-based authentication
# - Sudo privileges on remote nodes to read /etc/rancher/k3s/k3s.yaml
#

set -e  # Exit on error

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
KUBECONFIG_PATH="${HOME}/.kube/config"
BACKUP_PATH="${HOME}/.kube/config.backup.$(date +%Y%m%d_%H%M%S)"

# Cluster definitions
# Format: "cluster_name,hostname,ip_address"
declare -a CLUSTERS=(
    "pdx1-cluster,pdx-kserver1.telnoc.com,10.0.96.8"
    "pdx2-cluster,pdx2-kserver0.telnoc.com,10.0.96.22"
)

# Default current context
DEFAULT_CONTEXT="pdx2-cluster"

# Remote kubeconfig location on K3s servers
REMOTE_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

echo -e "${GREEN}=== K3s Kubectl Config Setup ===${NC}\n"

# Backup existing config if it exists
if [ -f "${KUBECONFIG_PATH}" ]; then
    echo -e "${YELLOW}Backing up existing kubeconfig to:${NC}"
    echo -e "  ${BACKUP_PATH}"
    cp "${KUBECONFIG_PATH}" "${BACKUP_PATH}"
    echo ""
fi

# Ensure .kube directory exists
mkdir -p "${HOME}/.kube"

# Start building the new config
echo "apiVersion: v1" > "${KUBECONFIG_PATH}"
echo "clusters:" >> "${KUBECONFIG_PATH}"

declare -a CLUSTER_NAMES=()

# Process each cluster
for cluster_def in "${CLUSTERS[@]}"; do
    IFS=',' read -r cluster_name hostname ip_address <<< "${cluster_def}"
    CLUSTER_NAMES+=("${cluster_name}")

    echo -e "${GREEN}Processing ${cluster_name} (${hostname})...${NC}"

    # Pull the kubeconfig from the remote server
    echo "  - Connecting to ${hostname} via SSH..."
    REMOTE_CONFIG=$(ssh "${hostname}" "sudo cat ${REMOTE_KUBECONFIG}" 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo -e "${RED}  ERROR: Failed to retrieve kubeconfig from ${hostname}${NC}"
        echo -e "${RED}  Please ensure SSH access and sudo privileges are configured${NC}"
        exit 1
    fi

    # Extract certificate-authority-data
    CA_DATA=$(echo "${REMOTE_CONFIG}" | grep "certificate-authority-data:" | awk '{print $2}')

    # Extract client-certificate-data
    CLIENT_CERT=$(echo "${REMOTE_CONFIG}" | grep "client-certificate-data:" | awk '{print $2}')

    # Extract client-key-data
    CLIENT_KEY=$(echo "${REMOTE_CONFIG}" | grep "client-key-data:" | awk '{print $2}')

    # Validate extracted data
    if [ -z "${CA_DATA}" ] || [ -z "${CLIENT_CERT}" ] || [ -z "${CLIENT_KEY}" ]; then
        echo -e "${RED}  ERROR: Failed to extract certificate data from ${hostname}${NC}"
        exit 1
    fi

    echo "  - Successfully extracted certificates"

    # Append cluster configuration
    cat >> "${KUBECONFIG_PATH}" << EOF
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: https://${ip_address}:6443
  name: ${cluster_name}
EOF

    # Store cert data for user section (we'll add it later)
    eval "CLIENT_CERT_${cluster_name//-/_}='${CLIENT_CERT}'"
    eval "CLIENT_KEY_${cluster_name//-/_}='${CLIENT_KEY}'"

    echo -e "${GREEN}  ✓ ${cluster_name} configured${NC}\n"
done

# Add contexts section
echo "contexts:" >> "${KUBECONFIG_PATH}"
for cluster_name in "${CLUSTER_NAMES[@]}"; do
    cat >> "${KUBECONFIG_PATH}" << EOF
- context:
    cluster: ${cluster_name}
    user: ${cluster_name}
  name: ${cluster_name}
EOF
done

# Set current context
echo "current-context: ${DEFAULT_CONTEXT}" >> "${KUBECONFIG_PATH}"
echo "kind: Config" >> "${KUBECONFIG_PATH}"
echo "preferences: {}" >> "${KUBECONFIG_PATH}"

# Add users section
echo "users:" >> "${KUBECONFIG_PATH}"
for cluster_name in "${CLUSTER_NAMES[@]}"; do
    # Get the stored certificate data
    var_name="CLIENT_CERT_${cluster_name//-/_}"
    client_cert="${!var_name}"
    var_name="CLIENT_KEY_${cluster_name//-/_}"
    client_key="${!var_name}"

    cat >> "${KUBECONFIG_PATH}" << EOF
- name: ${cluster_name}
  user:
    client-certificate-data: ${client_cert}
    client-key-data: ${client_key}
EOF
done

# Set proper permissions
chmod 600 "${KUBECONFIG_PATH}"

echo -e "${GREEN}=== Configuration Complete ===${NC}\n"
echo -e "Kubeconfig created at: ${KUBECONFIG_PATH}"
echo -e "Current context: ${DEFAULT_CONTEXT}\n"

# Test connectivity
echo -e "${YELLOW}Testing cluster connectivity...${NC}\n"
for cluster_name in "${CLUSTER_NAMES[@]}"; do
    echo -n "  ${cluster_name}: "
    if kubectl --context="${cluster_name}" cluster-info &>/dev/null; then
        echo -e "${GREEN}✓ Connected${NC}"
    else
        echo -e "${RED}✗ Connection failed${NC}"
    fi
done

echo ""
echo -e "${GREEN}Available contexts:${NC}"
kubectl config get-contexts

echo -e "\n${YELLOW}To switch between clusters, use:${NC}"
for cluster_name in "${CLUSTER_NAMES[@]}"; do
    echo "  kubectl config use-context ${cluster_name}"
done
