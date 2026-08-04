# Patches Directory

This directory contains Kustomize patches for K3s-managed components and other system-level services that need customization but aren't part of the main application deployments.

## Purpose

K3s manages certain components (like CoreDNS) as built-in addons. These patches allow us to override default configurations while maintaining GitOps principles through the gitops repo.

## Structure

Each subdirectory contains patches for a specific component:
- `coredns/` — DNS service patches

## How to Apply Patches

Patches can be applied in two ways:

### Option 1: Direct kubectl apply (for immediate fixes)
```bash
kubectl apply -k patch/coredns/
```

### Option 2: ArgoCD Application (for GitOps management)
Create an ArgoCD Application that references the patch directory.

## Patches

### coredns/

**Problem Fixed**: CoreDNS SPOF (Single Point of Failure)
- Original: 1 replica (complete DNS failure if that pod goes down)
- Fixed: 2 replicas with pod anti-affinity

**Changes**:
- Replicas: 1 → 2
- Added pod anti-affinity (preferredDuringSchedulingIgnoredDuringExecution)
  - Spreads CoreDNS pods across different nodes
  - Ensures DNS availability if one node fails

**Status**: ✅ Applied to cluster on 2026-05-27

### metrics-server/

**Problem Fixed**: Metrics-server SPOF (Single Point of Failure)
- Original: 1 replica (cluster metrics unavailable if pod goes down)
- Fixed: 2 replicas with pod anti-affinity

**Changes**:
- Replicas: 1 → 2
- Added pod anti-affinity (preferredDuringSchedulingIgnoredDuringExecution)
  - Spreads metrics-server pods across different nodes
  - Ensures metrics collection and HPA/VPA functionality if one node fails

**Status**: ✅ Applied to cluster on 2026-05-27

## Next Steps

1. Create ArgoCD Applications to manage these patches long-term
2. Add patches for other K3s-managed components (as needed)
3. Add patches for ArgoCD pod anti-affinity spread
