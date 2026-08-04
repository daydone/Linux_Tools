# PDX1 Cilium L2 Migration Notes

## Date
2026-02-02/03

## Goal
Migrate from MetalLB to Cilium L2 announcements to fix LoadBalancer IP routing issues.

## What We Changed

### 1. Cilium Configuration
Updated ConfigMap `cilium-config` in namespace `kube-system`:
```yaml
kube-proxy-replacement: "true"
l2-announcements-enabled: "true"
routing-mode: "native"
auto-direct-node-routes: "true"
enable-ipv4-masquerade: "true"
```

### 2. Created Cilium L2 Resources
Location: `networking/pdx1/cilium/`

**Files:**
- `pdx1-l2-config.yaml` - CiliumLoadBalancerIPPool and CiliumL2AnnouncementPolicy resources
- `worker-node-config.yaml` - CiliumNodeConfig for worker nodes

**IP Pools:**
- management-vlan-pool: 10.0.95.150-160
- dev-vlan-pool: 10.0.97.150-160
- qa-vlan-pool: 10.0.98.150-160
- prod-vlan-pool: 10.0.99.150-160

**L2 Announcement Policies:**
Each policy targets services with label `cilium.io/l2-pool: <vlan>` and announces on specific bond interface:
- management-vlan-policy → bond0.675
- dev-vlan-policy → bond0.677
- qa-vlan-policy → bond0.678
- prod-vlan-policy → bond0.679

### 3. Updated Traefik Services
Location: `networking/pdx1/{dev,qa,prod,management}/traefik-*-service.yaml`

**Changes:**
- Removed MetalLB annotations: `metallb.universe.tf/address-pool`
- Added Cilium annotation: `io.cilium/lb-ipam-ips: <IP>`
- Added label: `cilium.io/l2-pool: <vlan>`

### 4. Worker Node Configuration
Created `CiliumNodeConfig` to specify VLAN devices on worker nodes only:
```yaml
spec:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: "true"
  defaults:
    devices: "bond0.675 bond0.677 bond0.678 bond0.679"
```

**Why:** Server nodes don't have VLAN interfaces, so devices config needed to be node-specific.

### 5. Deleted MetalLB
- Deleted ArgoCD application: `metallb-pdx1`
- Deleted application manifest: `argocd-applications/infrastructure/pdx1-metallb.yaml`
- Deleted namespace: `metallb-system`

## What's Working

✅ Cilium kube-proxy-replacement (services work internally)
✅ Services get LoadBalancer IPs from Cilium
✅ All VLAN devices recognized by Cilium on worker nodes
✅ Internal cluster connectivity works

## What's NOT Working

❌ Cilium L2 announcements don't send ARP responses
❌ No L2 leases being created
❌ No L2 activity in Cilium logs
❌ External access to LoadBalancer IPs fails

## Debugging Attempted

1. Verified `l2-announcements-enabled: "true"` in ConfigMap
2. Checked l2-announcer and l2-responder processes are running
3. Created L2AnnouncementPolicies with correct selectors
4. Added service labels to match policies
5. Configured devices via CiliumNodeConfig
6. Verified ExternalTrafficPolicy: Cluster (not Local)
7. Verified all VLAN devices attached in Cilium status
8. Restarted Cilium pods multiple times

## Possible Causes

1. Bug in Cilium 1.16.5 L2 announcements
2. Incompatibility with bonded VLAN interfaces
3. Missing configuration requirement not documented
4. Known issue: [cilium/cilium#38223](https://github.com/cilium/cilium/issues/38223) - L2 lease created but no ARP responses

## Research Sources

- [Cilium L2 Announcements Docs](https://docs.cilium.io/en/stable/network/l2-announcements/)
- [Complete Guide: Cilium L2 Announcements](https://dev.to/azalio/complete-guide-cilium-l2-announcements-for-loadbalancer-services-in-bare-metal-kubernetes-3jl2)
- [Cilium Per-Node Config](https://docs.cilium.io/en/stable/configuration/per-node-config/)
- [GitHub Issue: ARP not working](https://github.com/cilium/cilium/issues/38223)

## Decision

Reinstalling MetalLB with current Cilium configuration:
- Keep Cilium kube-proxy-replacement enabled (it's working)
- Use MetalLB for L2 announcements only
- Previous MetalLB routing issues should be resolved by:
  - Cilium kube-proxy-replacement now handling service proxy
  - Native routing mode in Cilium
  - ICMP redirects disabled on worker nodes

## To Resume Cilium L2 Debugging Later

If MetalLB still has issues, to continue Cilium L2 debugging:
1. Check Cilium operator logs for L2-related errors
2. Try upgrading to newer Cilium version (1.18+ recommended)
3. Test with simple single-interface setup first
4. Contact Cilium community with specific bonded VLAN setup details
