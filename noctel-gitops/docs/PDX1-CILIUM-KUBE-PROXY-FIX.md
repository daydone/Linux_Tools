# PDX1 LoadBalancer IP Fix - Cilium kube-proxy Replacement

**Date:** February 2, 2026
**Cluster:** pdx1 (k3s with Cilium CNI)
**Issue:** LoadBalancer IPs not working - all ingresses timing out from HAProxy
**Solution:** Enable Cilium kube-proxy-replacement

---

## Problem Summary

After implementing policy-based routing on PDX1 worker nodes for MetalLB multi-VLAN support, all ingresses became inaccessible from HAProxy. Investigation revealed that:

1. **No service proxy was running** - Cilium had `kube-proxy-replacement: false` but kube-proxy wasn't running either
2. **No iptables/eBPF rules** existed to forward LoadBalancer IP traffic to pods
3. **MetalLB was announcing IPs correctly** via L2/ARP, but packets arriving at nodes had nowhere to go
4. **Cluster IP services worked fine** internally, confirming Cilium pod networking was healthy

### Root Cause

K3s cluster was configured with Cilium CNI but:
- Cilium configured with `kube-proxy-replacement: "false"`
- K3s kube-proxy was disabled (standard practice with Cilium)
- **Result:** No component was handling service load balancing

LoadBalancer IPs were allocated by MetalLB and announced via ARP, but when traffic arrived at cluster nodes, there were no rules to DNAT the traffic from the LoadBalancer IP (10.0.97.151) to the actual pod IP (10.42.6.82).

---

## Solution Implemented

### Changes Made

Updated Cilium ConfigMap (`cilium-config` in `kube-system` namespace) with the following settings:

```yaml
data:
  kube-proxy-replacement: "true"           # Was: "false"
  enable-node-port: "true"                 # Was: "false"
  enable-external-ips: "true"              # Was: "false"
  enable-health-check-loadbalancer-ip: "true"  # Was: "false"
  bpf-lb-external-clusterip: "true"        # Was: "false"
```

### Implementation Steps

```bash
# 1. Patch Cilium configuration
kubectl patch configmap -n kube-system cilium-config --type=json -p='[
  {"op": "replace", "path": "/data/kube-proxy-replacement", "value": "true"},
  {"op": "replace", "path": "/data/enable-node-port", "value": "true"},
  {"op": "replace", "path": "/data/enable-external-ips", "value": "true"},
  {"op": "replace", "path": "/data/enable-health-check-loadbalancer-ip", "value": "true"}
]'

# 2. Enable external cluster IP handling
kubectl patch configmap -n kube-system cilium-config --type=json -p='[
  {"op": "replace", "path": "/data/bpf-lb-external-clusterip", "value": "true"}
]'

# 3. Restart Cilium pods to apply changes
kubectl rollout restart daemonset/cilium -n kube-system

# 4. Wait for rollout to complete
kubectl rollout status daemonset/cilium -n kube-system --timeout=120s

# 5. Verify Cilium now handles LoadBalancer IPs
kubectl exec -n kube-system <cilium-pod> -- cilium service list | grep LoadBalancer
```

---

## Verification

### Check Cilium Service Mappings

```bash
$ kubectl exec -n kube-system cilium-wtwfl -- cilium service list | grep "10.0.97.151"
116   10.0.97.151:80        LoadBalancer   1 => 10.42.6.82:80 (active)
117   10.0.97.151:443       LoadBalancer   1 => 10.42.6.82:443 (active)
118   10.0.97.151:9100      LoadBalancer   1 => 10.42.6.82:9100 (active)
```

### Test Connectivity

From HAProxy node:
```bash
$ curl -I http://dev-api.telnoc.com
HTTP/1.1 200 OK
...

$ curl -I http://qa-api.telnoc.com
HTTP/1.1 200 OK
...

$ curl -I http://api.noc.tel
HTTP/1.1 200 OK
...
```

All ingresses now respond correctly from HAProxy.

---

## Technical Details

### How Cilium kube-proxy-replacement Works

With kube-proxy-replacement enabled:

1. **eBPF Program Attachment:** Cilium attaches eBPF programs at TC (traffic control) layer
2. **Service Translation:** eBPF programs perform service IP → pod IP translation in kernel space
3. **LoadBalancer Support:** Recognizes LoadBalancer IPs and performs DNAT to backend pods
4. **MetalLB Integration:** Works alongside MetalLB:
   - MetalLB handles L2 ARP announcements to attract traffic to cluster nodes
   - Cilium handles service load balancing once packets arrive at nodes

### Cilium Configuration

Current relevant settings:
```yaml
routing-mode: tunnel              # Using vxlan tunnel mode
tunnel-protocol: vxlan
kube-proxy-replacement: "true"    # ← Key change
enable-node-port: "true"          # Enables NodePort support
enable-external-ips: "true"       # Enables LoadBalancer IP support
enable-health-check-loadbalancer-ip: "true"
bpf-lb-external-clusterip: "true"
ipv4-native-routing-cidr: 10.42.0.0/16  # Pod CIDR
```

---

## Related Configurations

### MetalLB (Unchanged)

MetalLB configuration remains the same:
- L2 mode announcements
- Separate IP pools per VLAN (dev: 10.0.97.x, qa: 10.0.98.x, prod: 10.0.99.x)
- Interface-specific L2Advertisements (bond0.677, bond0.678, bond0.679)

### Policy-Based Routing (Unchanged)

Worker node policy routing configuration remains in place:
- `/etc/NetworkManager/dispatcher.d/10-policy-routing`
- Custom routing tables (vlan677, vlan678, vlan679)
- IP rules for symmetric routing
- `rp_filter=2` on VLAN interfaces

These configurations ensure symmetric routing for MetalLB LoadBalancer IPs.

---

## Impact Assessment

### Services Affected
- ✅ All LoadBalancer services (Traefik ingress controllers)
- ✅ NodePort services
- ✅ ClusterIP services (already working, unchanged)

### Risk Level
**LOW to MEDIUM**
- Cilium kube-proxy-replacement is a mature, production-ready feature
- Changes are configuration-only, no CNI mode changes
- Easy rollback by reverting ConfigMap changes

### Rollback Procedure

If issues occur:
```bash
# Revert Cilium configuration
kubectl patch configmap -n kube-system cilium-config --type=json -p='[
  {"op": "replace", "path": "/data/kube-proxy-replacement", "value": "false"},
  {"op": "replace", "path": "/data/enable-node-port", "value": "false"},
  {"op": "replace", "path": "/data/enable-external-ips", "value": "false"},
  {"op": "replace", "path": "/data/enable-health-check-loadbalancer-ip", "value": "false"},
  {"op": "replace", "path": "/data/bpf-lb-external-clusterip", "value": "false"}
]'

# Restart Cilium
kubectl rollout restart daemonset/cilium -n kube-system
```

---

## Lessons Learned

1. **Always verify service proxy is running** - Don't assume kube-proxy or Cilium kube-proxy-replacement is active
2. **Check Cilium service mappings** - Use `cilium service list` to verify Cilium knows about services
3. **MetalLB + Cilium integration** - MetalLB handles IP announcement, CNI handles service routing
4. **Cluster IP working ≠ LoadBalancer working** - Different code paths in service networking

---

## References

- [Cilium kube-proxy replacement](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)
- [Cilium service load balancing](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/#load-balancing)
- [MetalLB + Cilium integration](https://metallb.universe.tf/configuration/cilium/)

---

## Status

✅ **RESOLVED** - All PDX1 ingresses accessible from HAProxy
**Implemented:** February 2, 2026
**Tested:** February 2, 2026
**Monitoring:** Ongoing

---

**Document Owner:** Network Engineering Team
**Cluster:** pdx1
**Last Updated:** February 2, 2026
