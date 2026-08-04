#!/bin/bash
# Disable Longhorn replica scheduling on control plane nodes
# This ensures that all new volumes (and their replicas) are only scheduled on worker nodes

for node in pdx1-kserver0 pdx1-kserver1 pdx1-kserver2 pdx1-kserver3 pdx1-kserver4; do
  diskname=$(kubectl get nodes.longhorn.io -n longhorn-system $node -o json | jq -r '.spec.disks | keys[] | select(. != "")')
  if [ -n "$diskname" ]; then
    kubectl patch nodes.longhorn.io -n longhorn-system $node --type merge -p "{\"spec\":{\"disks\":{\"$diskname\":{\"allowScheduling\":false}}}}"
  fi
done
