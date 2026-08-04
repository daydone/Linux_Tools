# PDX1 Cluster Routing and Ingress Fix

## Date: 2026-02-02

## Issue
Ingresses were not accessible from external sources (e.g., HAProxy at 10.0.97.101). LoadBalancer IPs were timing out despite MetalLB L2 announcements working correctly.

## Root Cause
Two issues were identified:
1. **Cilium kube-proxy-replacement incompatibility**: Cilium's eBPF-based kube-proxy replacement was not properly handling external traffic to LoadBalancer IPs in the same subnets as node VLAN interfaces.
2. **Firewalld blocking forwarded traffic**: Firewalld was blocking traffic being forwarded from external sources to the pod network, even though ports 80 and 443 were open.

## Solution

### 1. Disabled Cilium kube-proxy-replacement
- Changed `kube-proxy-replacement: "false"` in cilium-config ConfigMap
- K3s's built-in service proxy now handles LoadBalancer and NodePort services
- Cilium still provides CNI and network policy enforcement

### 2. Configured Cilium nodeport-addresses
- Added `nodeport-addresses: 10.0.95.0/24,10.0.97.0/24,10.0.98.0/24,10.0.99.0/24`
- Tells Cilium which interfaces to monitor for service traffic

### 3. Fixed Firewalld Configuration
On both worker nodes (pdx1-kworker0 and pdx1-kworker1):
```bash
# Set public zone target to ACCEPT to allow forwarding to pods
firewall-cmd --permanent --set-target=ACCEPT --zone=public
firewall-cmd --reload
```

## Verification
All LoadBalancer IPs are now accessible:
- Dev VLAN: 10.0.97.151 (bond0.677)
- QA VLAN: 10.0.98.151 (bond0.678)
- Prod VLAN: 10.0.99.151 (bond0.679)
- Management VLAN: 10.0.95.151 (bond0.675)

## Current Configuration
- **CNI**: Cilium 1.16.5 (native routing mode)
- **Service Proxy**: K3s built-in (kube-proxy functionality)
- **Load Balancer**: MetalLB v0.15.3 (L2 announcements)
- **Firewall**: firewalld with public zone target=ACCEPT

## Notes
- Cilium L2 announcement configurations remain in networking/pdx1/cilium/ for potential future use
- The combination of K3s proxy + MetalLB + Cilium CNI is working correctly
- Firewall security is still maintained through iptables rules managed by K3s and Cilium
