# Multi-VLAN Ingress Solution Options for k3s with Cilium

**Date:** October 15, 2025
**Cluster:** pdx2-kcluster (k3s)
**Goal:** Enable separate ingress controllers (Traefik) on different VLANs (677-dev, 678-qa, 679-prod) with proper egress routing

---

## Executive Summary

After extensive research and hands-on troubleshooting, we've identified **three viable solutions** for achieving multi-VLAN ingress with Cilium. The root issue is that **Cilium in tunnel mode bypasses Linux kernel routing**, making traditional policy-based routing ineffective.

**Current Status:**
- ✅ Prod (VLAN 679): Working
- ❌ QA (VLAN 678): Not accessible externally
- ❌ Dev (VLAN 677): Not accessible externally

**Root Cause:** Asymmetric routing - traffic arrives on one VLAN interface but responses go out the default route (VLAN 679), causing packets to be dropped by firewall/router.

---

## Solution Options

### Option 1: Cilium Egress Gateway (RECOMMENDED) ⭐

**Overview:**
Use Cilium's native egress gateway feature to route traffic from specific namespaces through designated gateway nodes with specific egress interfaces/IPs.

**How It Works:**
- Create `CiliumEgressGatewayPolicy` resources per namespace (dev, qa, prod)
- Policy selects pods by namespace label
- Routes egress traffic through specific gateway nodes
- Gateway nodes configured with correct VLAN interface for egress

**Requirements:**
- Cilium 1.13+ (we have 1.15+) ✅
- `enable-ipv4-egress-gateway: true` in Cilium config
- `kube-proxy-replacement: true` (currently false) ⚠️
- BPF masquerading enabled (already enabled) ✅

**Configuration Example:**

```yaml
# Enable egress gateway in Cilium
apiVersion: v1
kind: ConfigMap
metadata:
  name: cilium-config
  namespace: kube-system
data:
  enable-ipv4-egress-gateway: "true"
  kube-proxy-replacement: "true"  # Required for egress gateway
```

```yaml
# QA namespace egress policy
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: qa-egress-gateway
spec:
  selectors:
  - podSelector:
      matchLabels:
        io.kubernetes.pod.namespace: qa
  destinationCIDRs:
  - "0.0.0.0/0"  # All external traffic
  egressGateway:
    nodeSelector:
      matchLabels:
        kubernetes.io/hostname: pdx2-kworker0
    interface: bond0.678  # QA VLAN interface
```

```yaml
# Dev namespace egress policy
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: dev-egress-gateway
spec:
  selectors:
  - podSelector:
      matchLabels:
        io.kubernetes.pod.namespace: dev
  destinationCIDRs:
  - "0.0.0.0/0"
  egressGateway:
    nodeSelector:
      matchLabels:
        kubernetes.io/hostname: pdx2-kworker0
    interface: bond0.677  # Dev VLAN interface
```

```yaml
# Prod namespace egress policy
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: prod-egress-gateway
spec:
  selectors:
  - podSelector:
      matchLabels:
        io.kubernetes.pod.namespace: prod
  destinationCIDRs:
  - "0.0.0.0/0"
  egressGateway:
    nodeSelector:
      matchLabels:
        kubernetes.io/hostname: pdx2-kworker0
    interface: bond0.679  # Prod VLAN interface
```

**Pros:**
- ✅ Cilium-native solution (no CNI change needed)
- ✅ Designed specifically for this use case
- ✅ Per-namespace granularity
- ✅ No manual iptables/routing rules
- ✅ Supports our existing MetalLB setup
- ✅ Clean, declarative configuration

**Cons:**
- ⚠️ Requires enabling kube-proxy replacement (moderate risk)
- ⚠️ Incompatible with Cluster Mesh (not currently used)
- ⚠️ Introduces slight delay in policy enforcement for new pods
- ⚠️ Gateway node becomes single point of failure per environment

**Risk Level:** MEDIUM
**Recommended Testing:** Enable in dev cluster first, then qa, then prod

**Implementation Steps:**
1. Backup current Cilium configuration
2. Update Cilium ConfigMap:
   - `enable-ipv4-egress-gateway: "true"`
   - `kube-proxy-replacement: "true"`
3. Restart Cilium pods (rolling restart)
4. Create CiliumEgressGatewayPolicy for each namespace
5. Test connectivity from each environment
6. Monitor Cilium logs for egress gateway events

**Testing Plan:**
```bash
# From within a QA pod
kubectl exec -n qa <pod-name> -- curl -I https://api.noctel.com
kubectl exec -n qa <pod-name> -- curl -I https://httpbin.org/ip

# Check egress gateway status
cilium bpf egress list
kubectl get ciliumegressgatewaypolicy -A
```

---

### Option 2: Switch to Cilium Native Routing Mode ⚠️

**Overview:**
Change Cilium from tunnel mode to native routing mode, which respects Linux kernel routing tables and ip rules.

**How It Works:**
- Cilium delegates routing decisions to Linux kernel
- Our existing policy routing rules would work
- Requires proper routing configuration between nodes

**Requirements:**
- Change `routing-mode: tunnel` → `routing-mode: native`
- Set `auto-direct-node-routes: true`
- Configure `ipv4-native-routing-cidr: "10.0.0.0/16"` (pod CIDR)
- Ensure L2 reachability or BGP between nodes

**Configuration:**

```yaml
# Update Cilium config
apiVersion: v1
kind: ConfigMap
metadata:
  name: cilium-config
  namespace: kube-system
data:
  routing-mode: "native"
  auto-direct-node-routes: "true"
  ipv4-native-routing-cidr: "10.244.0.0/16"  # Pod CIDR
  enable-ipv4-masquerade: "true"
```

**Required Routing Configuration (on each node):**

```bash
# Policy routing rules (already have these from earlier)
ip rule add from 10.0.97.0/24 lookup 677 priority 96
ip rule add from 10.0.98.0/24 lookup 678 priority 95

# Routing tables
ip route add default via 10.0.97.1 dev bond0.677 table 677
ip route add default via 10.0.98.1 dev bond0.678 table 678
ip route add default via 10.0.99.1 dev bond0.679 table 679  # main default
```

**Pros:**
- ✅ Uses standard Linux routing (more predictable)
- ✅ Policy routing rules work as expected
- ✅ Better integration with traditional networking
- ✅ More control over routing decisions

**Cons:**
- ❌ **MAJOR CHANGE** - affects all pod networking
- ❌ **HIGH RISK** - could break entire cluster if misconfigured
- ❌ Requires cluster maintenance window
- ❌ Need extensive testing in dev first
- ❌ May affect inter-pod communication
- ❌ Requires routing between nodes (BGP or static routes)
- ❌ More complex to maintain

**Risk Level:** VERY HIGH
**Recommended:** Only if Option 1 fails

**Implementation Steps:**
1. **DO NOT implement in production first**
2. Test in isolated dev cluster
3. Full cluster backup
4. Change Cilium configuration
5. Restart all Cilium pods
6. Verify all pods can communicate
7. Test ingress/egress on all VLANs
8. Monitor for 24-48 hours before considering for prod

---

### Option 3: MetalLB Interface Binding + Cilium L2 Announcements

**Overview:**
Configure MetalLB to announce LoadBalancer IPs only on specific interfaces per L2Advertisement, combined with careful node selection.

**How It Works:**
- Create separate L2Advertisement resources per VLAN
- Bind each advertisement to specific interface (bond0.677, bond0.678, bond0.679)
- Use nodeSelectors to control which nodes announce which services
- Combine with reverse path filtering (rp_filter) adjustments

**Configuration Example:**

```yaml
# QA L2 Advertisement
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: qa-vlan-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - qa-vlan-pool
  interfaces:
  - bond0.678  # Only announce on QA VLAN
  nodeSelectors:
  - matchLabels:
      node-role.kubernetes.io/worker: "true"
```

```yaml
# Dev L2 Advertisement
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: dev-vlan-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - dev-vlan-pool
  interfaces:
  - bond0.677  # Only announce on Dev VLAN
  nodeSelectors:
  - matchLabels:
      node-role.kubernetes.io/worker: "true"
```

```yaml
# Prod L2 Advertisement
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: prod-vlan-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - prod-vlan-pool
  interfaces:
  - bond0.679  # Only announce on Prod VLAN
  nodeSelectors:
  - matchLabels:
      node-role.kubernetes.io/worker: "true"
```

**Additional Required Configuration:**

```bash
# Disable reverse path filtering (on all nodes)
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.default.rp_filter=0
sysctl -w net.ipv4.conf.bond0/677.rp_filter=0
sysctl -w net.ipv4.conf.bond0/678.rp_filter=0
sysctl -w net.ipv4.conf.bond0/679.rp_filter=0

# Make persistent
cat >> /etc/sysctl.d/99-metallb.conf << 'EOF'
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
```

**Pros:**
- ✅ No Cilium changes required
- ✅ Uses existing MetalLB setup
- ✅ Lower risk than native routing
- ✅ Can be tested incrementally

**Cons:**
- ⚠️ Doesn't solve egress routing problem (only ingress)
- ⚠️ Still need solution for return traffic routing
- ⚠️ Disabling rp_filter reduces security
- ⚠️ May not work with Cilium tunnel mode egress
- ⚠️ Interface binding doesn't affect node leader election

**Risk Level:** MEDIUM
**Effectiveness:** PARTIAL (solves ingress, not egress)

---

## Comparison Matrix

| Criteria | Option 1: Egress Gateway | Option 2: Native Routing | Option 3: MetalLB Binding |
|----------|-------------------------|-------------------------|---------------------------|
| **Risk** | Medium | Very High | Medium |
| **Complexity** | Low | High | Medium |
| **CNI Changes** | Minor (enable features) | Major (mode change) | None |
| **Solves Ingress** | ✅ Yes | ✅ Yes | ✅ Yes |
| **Solves Egress** | ✅ Yes | ✅ Yes | ❌ No |
| **Maintenance** | Low | Medium | Medium |
| **Cilium Native** | ✅ Yes | ✅ Yes | ❌ No |
| **Testing Required** | Moderate | Extensive | Moderate |
| **Rollback Difficulty** | Easy | Very Hard | Easy |

---

## Recommended Implementation Plan

### Phase 1: Enable Cilium Egress Gateway (Option 1)

**Week 1: Research & Planning**
- ✅ Document current state (DONE)
- ✅ Research solutions (DONE)
- Review Cilium egress gateway docs thoroughly
- Plan testing scenarios

**Week 2: Dev Cluster Testing**
1. Backup Cilium config
2. Enable `kube-proxy-replacement: true`
3. Enable `enable-ipv4-egress-gateway: true`
4. Restart Cilium (rolling restart)
5. Create dev namespace egress policy
6. Test connectivity extensively
7. Monitor for issues (24 hours)

**Week 3: QA Cluster Testing**
1. Apply same changes to QA
2. Create qa namespace egress policy
3. Test external accessibility
4. Verify prod still works
5. Monitor for issues (48 hours)

**Week 4: Production Implementation**
1. Schedule maintenance window (low-traffic period)
2. Apply Cilium configuration changes
3. Create all three egress policies (dev, qa, prod)
4. Test all environments
5. Monitor closely for 72 hours

### Phase 2: Fallback Plan (If Option 1 Fails)

If Cilium Egress Gateway doesn't work or causes issues:
- Revert Cilium config
- Research Option 2 (Native Routing) more thoroughly
- Test in completely isolated environment
- Consider engaging Cilium community/support

---

## Key Insights from Research

### Why Our Original Approach Failed

1. **Cilium Tunnel Mode Bypasses Kernel:**
   - In `routing-mode: tunnel`, Cilium uses vxlan encapsulation
   - BPF programs make routing decisions, not Linux kernel
   - `ip rule` and policy routing are ignored for encapsulated traffic

2. **SNAT Happens Too Late:**
   - By the time packet reaches routing decision, source is already pod IP
   - Policy rules matching on VLAN subnets never trigger
   - Connection marking gets overwritten by Cilium BPF

3. **ICMP Redirects from Gateway:**
   - Multiple routing rules caused confusion
   - Gateway saw traffic routing incorrectly and sent redirects
   - Redirects prevented proper packet delivery

### What Works in Production Today

- **Prod VLAN 679:** Works because it's the default route
- **Ingress traffic:** MetalLB L2 announcements work on all VLANs
- **Egress traffic:** All goes out VLAN 679 (default route)
- **Inter-pod:** Cilium tunnel handles perfectly

### Community Best Practices

From real-world implementations:

1. **Cilium Egress Gateway is the recommended solution** for this exact scenario
2. **Native routing mode is viable** but requires extensive testing
3. **MetalLB interface binding alone is insufficient** - must be combined with egress solution
4. **VRF (Virtual Routing and Forwarding)** is enterprise solution but complex to implement
5. **kube-router as alternative CNI** handles this better natively (uses BGP)

---

## Additional Considerations

### Security Implications

- **Egress Gateway:** Centralizes egress, easier to monitor/firewall
- **Native Routing:** More distributed, harder to track traffic
- **Current State:** All egress appears from prod VLAN

### High Availability

- **Egress Gateway:** Single gateway node per namespace = SPOF
  - Mitigation: Use multiple gateway nodes with policies
- **Native Routing:** Distributed across all nodes
- **Current:** Already have single worker node (pdx2-kworker0)

### Monitoring & Troubleshooting

**Cilium Egress Gateway:**
```bash
# Check egress gateway status
cilium bpf egress list
kubectl get ciliumegressgatewaypolicy -A

# View Cilium logs
kubectl logs -n kube-system -l k8s-app=cilium --tail=100 | grep egress

# Check pod egress routing
cilium endpoint list
```

**Native Routing:**
```bash
# Verify routing on nodes
ip route show table all
ip rule show

# Check Cilium routing mode
cilium status | grep -i routing
```

---

## Technical References

### Cilium Documentation
- Egress Gateway: https://docs.cilium.io/en/stable/network/egress-gateway/
- Routing Modes: https://docs.cilium.io/en/stable/network/concepts/routing/
- L2 Announcements: https://docs.cilium.io/en/stable/network/l2-announcements/

### MetalLB Documentation
- L2 Mode: https://metallb.universe.tf/concepts/layer2/
- Advanced L2 Config: https://metallb.universe.tf/configuration/_advanced_l2_configuration/

### Related Issues
- Cilium #32975: Egress Traffic Routing in Separate Networks
- MetalLB #610: Packets route through default gateway
- Kubernetes #101910: kube-proxy iptables asymmetric routing

---

## Next Steps

1. **Immediate:** Review this document with team
2. **This Week:** Decide on Option 1 (Egress Gateway) or Option 2 (Native Routing)
3. **Next Week:** Begin testing in dev cluster
4. **Within Month:** Roll out to QA, then prod

---

## Conclusion

**Cilium Egress Gateway (Option 1) is the recommended solution** because:
- It's designed for this exact use case
- Lower risk than native routing mode change
- Cilium-native, well-supported feature
- Can be tested incrementally per namespace
- Clean rollback if issues occur

The research shows this is a **known problem with known solutions**. The challenge is implementation and testing, not lack of viable approaches.

**Status:** Ready to proceed with testing plan.

---

**Document Owner:** Network Engineering Team
**Last Updated:** October 15, 2025
**Next Review:** After Phase 1 completion
