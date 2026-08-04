# Longhorn Configuration

## Worker Node Tagging

Worker nodes (pdx1-kworker0, pdx1-kworker1) are tagged with the "worker" label in Longhorn to restrict replica scheduling to worker nodes only.

```bash
kubectl patch nodes.longhorn.io -n longhorn-system pdx1-kworker0 --type merge -p '{"spec":{"tags":["worker"]}}'
kubectl patch nodes.longhorn.io -n longhorn-system pdx1-kworker1 --type merge -p '{"spec":{"tags":["worker"]}}'
```

## Control Plane Node Scheduling Disabled

All control plane node disks (pdx1-kserver0 through pdx1-kserver4) have `allowScheduling: false` to prevent Longhorn from scheduling replicas on them.

This is applied via `disable-control-plane-scheduling.sh` and ensures that:
- All new volumes schedule only on worker nodes
- Prevents overallocation of control plane node disk space
- Stateful workloads are isolated to worker infrastructure

## Storage Classes

- `longhorn-worker-only`: Explicitly restricts to worker nodes via diskSelector "worker" (deprecated in favor of node-level scheduling control)
