# Session Continuation Prompt

## Context
K3S/ArgoCD GitOps deployment for Noctel across two clusters: pdx1 and pdx2.

## Clusters
- **pdx1**: 5 server nodes + 2 worker nodes (newer cluster, being configured)
- **pdx2**: Production cluster (reference implementation)

## What's Been Completed

### pdx1 Infrastructure (DONE)
- Cilium CNI running (managed via Ansible, not ArgoCD)
- MetalLB deployed and healthy with 4 IP pools:
  - Management VLAN: 10.0.95.150-160
  - Dev VLAN: 10.0.97.150-160
  - QA VLAN: 10.0.98.150-160
  - Prod VLAN: 10.0.99.150-160
- Traefik deployed for all 3 environments (dev: 1 pod, qa: 2 pods, prod: 2 pods)
- 48 ArgoCD applications deployed

### Helm Chart Fixes Applied
- Fixed Traefik templates to use `.Values.traefik.*` prefix (was `.Values.*`)
- Fixed qa-traefik.yaml path from `charts/infrastructure/traefik` to `charts/traefik`
- Fixed qa-traefik values path to `../../environments/pdx1/pdx1-qa-config.yaml`
- Consolidated duplicate traefik sections in config files

### Documentation Created
- README.md - repo structure
- ARCHITECTURE.md - multi-cluster design
- prompt.txt - AI context preservation

## pdx2 Production Incident (RESOLVED - needs verification)

### Problem
d.noc.tel (prod display service) was flapping in monitoring.

### Root Cause Identified
- pdx2-kworker1 had severe network issues:
  - 2.2M TCP retransmit failures
  - 1744 send buffer errors
  - Bond interfaces recreated ~2 hours before investigation
- MetalLB speakers couldn't communicate with kworker1
- Speaker pod on kworker1 was stuck in Init:0/3 due to missing `metallb-excludel2` configmap

### Actions Taken
1. Deleted problematic speaker pod on kworker1
2. Created empty `metallb-excludel2` configmap in metallb-system namespace
3. All 5 speaker pods now showing 4/4 Running (verified just before session ended)

### Still Needs
- Verify display service is stable
- Consider draining kworker1 at 10pm PST if issues persist
- Clean up 4 stuck ACME certificate challenges (9-27 days pending)

## Next Tasks (Not Started)

### pdx1 Ingress Setup
- IngressClass template created in `manifests/traefik/templates/ingressclass.yaml`
- Creates `traefik-{namespace}` IngressClass per environment
- Need to create pdx1-specific ingresses with pdx1 hostnames
- Reference: `/networking` directory has qa ingress examples

## Key Files
- `argocd-applications/pdx1/` - pdx1 ArgoCD apps
- `argocd-applications/pdx2/` - pdx2 ArgoCD apps
- `environments/pdx1/pdx1-*-config.yaml` - pdx1 env configs
- `manifests/traefik/` - Traefik Helm chart
- `charts/traefik/` - Copy of Traefik chart (used by ArgoCD)
- `/Users/finbar.day/Documents/BitBucket/k3s-config/metal-lb/` - MetalLB configs

## Commands
Always use `--context` flag:
- `kubectl --context pdx1-cluster ...`
- `kubectl --context pdx2-cluster ...`

## User Preferences
- Short, direct commit messages (e.g., "Fix qa-traefik path")
- No verbose explanations in commits
