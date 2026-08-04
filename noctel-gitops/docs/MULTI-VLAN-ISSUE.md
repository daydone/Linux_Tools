# Multi-VLAN Ingress/Egress Issue - Technical Analysis

**Date:** October 15, 2025
**Cluster:** pdx2-kcluster (k3s)
**Issue:** QA and Dev ingresses not accessible externally, only Prod works

---

## Current Working State

- **Prod (VLAN 679 - 10.0.99.0/24)**: ✅ WORKING
  - MetalLB IPs: 10.0.99.20-30
  - Traefik LoadBalancer IP: 10.0.99.21
  - Default route: via 10.0.99.1 dev bond0.679

- **QA (VLAN 678 - 10.0.98.0/24)**: ❌ NOT WORKING
  - MetalLB IPs: 10.0.98.20-30
  - Traefik LoadBalancer IP: 10.0.98.21
  - Public DNS: mocktel.com domains → 192.69.31.158 (DNATed to 10.0.98.21)

- **Dev (VLAN 677 - 10.0.97.0/24)**: ❌ NOT WORKING
  - MetalLB IPs: 10.0.97.20-30
  - Traefik LoadBalancer IP: 10.0.97.21
  - Public DNS: pdx2-dev-*.telnoc.com → (various IPs)

---

## Root Cause Analysis

### The Core Problem: Asymmetric Routing

**What happens:**
1. External client sends request to 192.69.31.158 (QA public IP)
2. Juniper firewall DNATs to 10.0.98.21 (QA MetalLB IP)
3. Packet arrives at pdx2-kworker0 on **bond0.678** (QA VLAN)
4. MetalLB L2 announces 10.0.98.21, packet reaches traefik-qa pod
5. kube-proxy DNATs packet from 10.0.98.21 → 10.0.3.226 (pod IP)
6. Pod processes request and generates response
7. **Response packet routes via default route (bond0.679 - prod VLAN)**
8. Response goes out wrong VLAN, firewall/router drops it due to asymmetric path

**Why prod works:**
- Default route is via bond0.679 (prod VLAN)
- Prod traffic arrives on bond0.679 and responses go out bond0.679
- Same VLAN for ingress and egress = symmetric routing ✓

**Why QA/dev fail:**
- Traffic arrives on bond0.678 (QA) or bond0.677 (dev)
- Responses use default route (bond0.679 - prod VLAN)
- Different VLANs for ingress/egress = asymmetric routing ✗

---

## Technical Environment Details

### Network Stack
- **CNI:** Cilium 1.15+ in **tunnel mode (vxlan)**
- **Load Balancer:** MetalLB in **L2 mode**
- **Ingress:** Traefik (multiple instances per environment)
- **kube-proxy:** iptables mode (not replaced by Cilium)

### Key Configuration Details

**Cilium Config:**
```yaml
routing-mode: tunnel
enable-ipv4-masquerade: "true"
kube-proxy-replacement: "false"
ipam: cluster-pool
cluster-pool-ipv4-cidr: 10.244.0.0/16
```

**MetalLB L2 Advertisements:**
```yaml
# Each VLAN has specific interface advertisement
dev-vlan-pool: bond0.677 (10.0.97.20-30)
qa-vlan-pool: bond0.678 (10.0.98.20-30)
prod-vlan-pool: bond0.679 (10.0.99.20-30)
```

**Current Routing:**
```bash
# Main routing table
default via 10.0.99.1 dev bond0.679
10.0.97.0/24 dev bond0.677 proto kernel scope link src 10.0.97.7
10.0.98.0/24 dev bond0.678 proto kernel scope link src 10.0.98.7
10.0.99.0/24 dev bond0.679 proto kernel scope link src 10.0.99.7

# Policy routing tables configured but not working
Table 677: default via 10.0.97.1 dev bond0.677
Table 678: default via 10.0.98.1 dev bond0.678
Table 679: default via 10.0.99.1 dev bond0.679
```

---

## Solutions Attempted and Why They Failed

### 1. Source-Based Policy Routing
**Approach:**
```bash
ip rule add from 10.0.97.0/24 lookup 677 priority 95
ip rule add from 10.0.98.0/24 lookup 678 priority 95
ip rule add from 10.0.99.0/24 lookup 679 priority 100
```

**Why it failed:**
- Rules match on **source IP** of the packet
- After DNAT, source IP is the external client (e.g., 71.238.36.104)
- After kube-proxy processing, source becomes **pod IP** (10.0.3.x)
- Pod IPs are in 10.0.3.0/24 (cluster network), not VLAN networks
- Policy rules never match, default route used instead

### 2. Connection Marking (connmark)
**Approach:**
```bash
# Mark connections based on ingress interface
iptables -t mangle -A PREROUTING -i bond0.677 -j CONNMARK --set-mark 677
iptables -t mangle -A PREROUTING -i bond0.678 -j CONNMARK --set-mark 678
iptables -t mangle -A PREROUTING -i bond0.679 -j CONNMARK --set-mark 679

# Restore marks and route based on them
iptables -t mangle -A OUTPUT -j CONNMARK --restore-mark
ip rule add fwmark 677 table 677 priority 10
ip rule add fwmark 678 table 678 priority 10
ip rule add fwmark 679 table 679 priority 10
```

**Why it failed:**
- Cilium in **tunnel mode** bypasses kernel routing for pod traffic
- Cilium uses its own BPF programs that override iptables marks
- Marking happens in PREROUTING, but Cilium encapsulates before OUTPUT
- Marks don't survive through Cilium's vxlan tunnel processing
- Routing decision made by Cilium BPF, not kernel routing table

**Attempted fixes:**
- Tried marking in PREROUTING with ctdir REPLY - broke prod
- Tried marking in POSTROUTING - broke both prod and QA
- Tried marking in OUTPUT - didn't propagate to actual packet

### 3. Cilium Native Routing Configuration
**Approach:**
```bash
# Configure Cilium to treat VLANs as native routing CIDR
kubectl patch configmap cilium-config -p '{"data":{"ipv4-native-routing-cidr":"10.0.96.0/19"}}'
```

**Why it failed:**
- Cilium still in tunnel mode, native-routing-cidr only applies in native mode
- Would require changing `routing-mode: tunnel` → `routing-mode: native`
- This is a **major cluster-wide change** affecting all pod networking
- Risk: Could break all inter-pod communication if misconfigured
- Would require full cluster maintenance window and testing

### 4. externalTrafficPolicy: Local
**Approach:**
```bash
kubectl patch svc traefik-prod -p '{"spec":{"externalTrafficPolicy":"Local"}}'
kubectl patch svc traefik-qa -p '{"spec":{"externalTrafficPolicy":"Local"}}'
```

**Why it failed:**
- With Local policy, traffic only goes to pods on the node with MetalLB IP
- But kube-proxy still does DNAT internally
- Response routing still controlled by Cilium tunnel, not Linux routing
- Didn't solve the fundamental egress routing problem

---

## Why This Is a Complex Problem

### 1. Cilium Tunnel Mode Limitations
Cilium in tunnel mode:
- Uses vxlan encapsulation for all pod-to-pod traffic
- Bypasses Linux kernel routing tables
- Makes routing decisions in BPF programs, not kernel
- iptables rules and ip rules have limited effect on encapsulated traffic

### 2. Multiple Layers of NAT
The packet goes through multiple NAT operations:
```
External Client (71.238.x.x)
  ↓ [Juniper DNAT]
MetalLB IP (10.0.98.21)
  ↓ [kube-proxy DNAT]
Pod IP (10.0.3.226)
  ↓ [Response - where does it route?]
```

By the time the response is generated:
- Original VLAN context is lost
- Cilium sees it as pod traffic, not external traffic
- Linux routing rules don't apply

### 3. Single Physical Interface
- Not multiple physical interfaces (eth0, eth1, etc.)
- VLANs on same bond interface (bond0.677, bond0.678, bond0.679)
- Most documentation assumes multiple physical interfaces
- VLAN scenario less common in k8s setups

---

## Possible Solutions (For Future Implementation)

### Option 1: Switch Cilium to Native Routing Mode ⚠️ HIGH RISK
**Requirements:**
- Change Cilium config: `routing-mode: native`
- Set `auto-direct-node-routes: true`
- Configure `ipv4-native-routing-cidr` properly
- Restart all Cilium pods
- Test extensively

**Pros:**
- Uses Linux kernel routing, our ip rules would work
- More control over routing decisions
- Better integration with traditional networking

**Cons:**
- Major change affecting entire cluster
- Could break all networking if misconfigured
- Requires cluster maintenance window
- Need to test in dev cluster first
- May affect inter-node pod communication

**Risk:** VERY HIGH - could take down entire cluster

### Option 2: Use Cilium Egress Gateway Feature
**Requirements:**
- Enable Cilium egress gateway: `enable-ipv4-egress-gateway: true`
- Create CiliumEgressGatewayPolicy resources per namespace
- Configure egress nodes and IPs

**Pros:**
- Designed for this exact use case
- Cilium-native solution
- More stable than switching modes

**Cons:**
- Requires Cilium 1.13+
- Complex policy configuration
- Need to understand Cilium's egress gateway architecture
- May require specific node labeling

**Risk:** MEDIUM - additive change, shouldn't break existing

### Option 3: Deploy Separate Traefik Instances on Specific Nodes
**Requirements:**
- Use nodeSelector to pin each Traefik to specific nodes
- Configure different nodes with different default routes
- Node affinity: qa-node → default via 10.0.98.1, prod-node → default via 10.0.99.1

**Pros:**
- No CNI changes required
- Uses existing Kubernetes scheduling

**Cons:**
- Requires multiple worker nodes dedicated per environment
- Wasteful of resources
- Single point of failure per environment
- Doesn't scale

**Risk:** LOW - but resource intensive

### Option 4: Use Different CNI (Calico, kube-router)
**Requirements:**
- Completely replace Cilium with different CNI
- kube-router supports source-based routing natively with BGP
- Calico has better documented multi-interface support

**Pros:**
- Some CNIs handle this scenario better
- kube-router uses "real" routing, not overlays

**Cons:**
- **MASSIVE CHANGE** - complete CNI replacement
- Requires full cluster rebuild/migration
- Loss of Cilium features (Hubble, network policies, etc.)
- Extensive testing required

**Risk:** EXTREME - equivalent to rebuilding cluster

### Option 5: Use iptables SNAT per VLAN
**Requirements:**
```bash
# SNAT responses to use correct source IP
iptables -t nat -A POSTROUTING -o bond0.678 -s 10.0.3.0/24 -j SNAT --to-source 10.0.98.7
iptables -t nat -A POSTROUTING -o bond0.679 -s 10.0.3.0/24 -j SNAT --to-source 10.0.99.7
```

**Pros:**
- Relatively simple
- No CNI changes

**Cons:**
- Loses original client IP (even with externalTrafficPolicy: Local)
- May conflict with Cilium's masquerading
- Doesn't solve the routing problem, just masks it

**Risk:** MEDIUM - could conflict with Cilium

---

## Recommended Path Forward

### Short Term (Current State)
✅ **Keep prod working** with default route via bond0.679
✅ **Document the issue** (this document)
✅ **QA and Dev remain non-functional** for external access
⚠️ **Internal k8s access still works** (ClusterIP services)

### Medium Term (Next Steps)
1. **Research Cilium Egress Gateway** thoroughly
   - Review official docs: https://docs.cilium.io/en/stable/network/egress-gateway/
   - Find examples of multi-VLAN setups
   - Test in dev cluster first

2. **Test in Isolated Environment**
   - Create test cluster or use dev cluster
   - Try Option 1 (native routing) with full backup
   - Try Option 2 (egress gateway) as safer alternative

3. **Engage Cilium Community**
   - Post to Cilium Slack/GitHub discussions
   - This exact scenario: "MetalLB L2 + Cilium tunnel mode + multiple VLANs"
   - Ask for recommended configuration

### Long Term (Architectural)
- Consider if multi-VLAN setup is necessary
- Evaluate alternative architectures:
  - Single VLAN for all environments (security implications)
  - Separate clusters per environment (resource implications)
  - Using namespace network policies instead of VLANs

---

## Key Takeaways

1. **Cilium tunnel mode fundamentally incompatible** with our multi-VLAN requirement
2. **Connection marking approach doesn't work** because Cilium bypasses iptables for encapsulated traffic
3. **Source-based routing doesn't work** because source IPs are pod IPs, not VLAN IPs
4. **This is not a simple routing problem** - it's a CNI architecture mismatch
5. **Production is working** and stable - we successfully restored it
6. **Solution requires significant research** and cannot be implemented during a maintenance window without testing

---

## References

### Attempted Solutions
- MetalLB L2 mode docs: https://metallb.universe.tf/concepts/layer2/
- Cilium routing concepts: https://docs.cilium.io/en/stable/network/concepts/routing/
- Policy-based routing guide: https://blog.aenix.io/configuring-routing-for-metallb-in-l2-mode-7ea26e19219e
- Red Hat multi-interface solution: https://access.redhat.com/solutions/7117243 (paywall)

### Community Resources
- Cilium GitHub issue #31640: CFP: Source routing for L2 Announced addresses
- Similar scenarios documented in kube-router/Calico communities

### Our Backup Files
- Location: `/root/backup-*-pdx2-k*-20251014.txt` on each node
- Rollback procedure: `/Users/finbar.day/Documents/BitBucket/noctel-gitops/ROLLBACK-PROCEDURE.md`

---

**Document Owner:** Network Engineering Team
**Last Updated:** October 15, 2025
**Status:** UNRESOLVED - Requires further research and testing
