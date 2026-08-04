# PDX1 Kubernetes Networking Architecture

## Overview

This document explains how external ingress routing works on the PDX1 K3s cluster, using QA namespace as the primary reference example. The architecture involves physical network VLANs, Cilium CNI, LoadBalancer services, and Traefik ingress controllers.

## Physical Network Architecture

### VLAN Layout

The PDX1 cluster spans **four isolated VLANs** carrying different workload namespaces:

| VLAN ID | IP Subnet | Purpose | Node Interface (workers) | Node Interface (control-plane) | Gateway |
|---------|-----------|---------|------------------------|-------------------------------|---------|
| 675 | 10.0.95.0/24 | Management (ArgoCD, Rancher, Jenkins) | bond0.675 | ens192 | 10.0.95.1 |
| 677 | 10.0.97.0/24 | Dev namespace | bond0.677 | ens161 | 10.0.97.1 |
| 678 | 10.0.98.0/24 | QA namespace | bond0.678 | ens224 | 10.0.98.1 |
| 679 | 10.0.99.0/24 | Prod namespace | bond0.679 | ens256 | 10.0.99.1 |

### Network Device Configuration

**Worker nodes (kworker0, kworker1):**
- Single physical NIC bonded to all four VLANs via subinterfaces: `bond0.675`, `bond0.677`, `bond0.678`, `bond0.679`
- Default route must point to the **management VLAN** (675): `default via 10.0.95.1 dev bond0.675`
  - This is critical: the management VLAN carries the Cilium control-plane traffic and API server access
  - Other VLANs are used only for namespace-specific ingress (Traefik LoadBalancers)

**Control-plane nodes (kserver0–4):**
- Four separate NICs carrying one VLAN each:
  - `ens161` → vlan677 (dev)
  - `ens192` → vlan675 (management, carries default route)
  - `ens224` → vlan678 (qa)
  - `ens256` → vlan679 (prod)

## Cilium Configuration

Cilium is responsible for:
1. Allocating LoadBalancer IPs from defined pools
2. Announcing those IPs on specific VLANs via L2 (ARP)
3. Managing inter-node routing using the correct interface (`direct-routing-device`)

### CiliumNodeConfig

Per-node Cilium overrides are defined in `networking/pdx1/cilium/`:

**Worker nodes** (`worker-node-config.yaml`):
```yaml
apiVersion: cilium.io/v2
kind: CiliumNodeConfig
metadata:
  namespace: kube-system
  name: pdx1-worker-config
spec:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: "true"
  defaults:
    devices: "bond0.650 bond0.675 bond0.677 bond0.678 bond0.679"
    direct-routing-device: "bond0.675"
```

- `devices`: List of interfaces Cilium should manage
- `direct-routing-device: "bond0.675"`: Inter-node traffic and L2 announcements use the management VLAN (bond0.675)
  - This ensures all nodes can reach each other and the API server on the management VLAN
  - This is also the interface where Cilium announces all LoadBalancer IPs

**Control-plane nodes** (`server-node-config.yaml`):
```yaml
apiVersion: cilium.io/v2
kind: CiliumNodeConfig
metadata:
  namespace: kube-system
  name: pdx1-server-config
spec:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/control-plane: "true"
  defaults:
    devices: "ens161 ens192 ens224 ens256"
    direct-routing-device: "ens192"
```

- Control-plane also uses the management VLAN (ens192) as the direct routing device

### CiliumLoadBalancerIPPool

Defines IP pools for each namespace's VLAN (`networking/pdx1/cilium/pdx1-l2-config.yaml`):

```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: qa-vlan-pool
spec:
  blocks:
  - cidr: 10.0.98.150/32
  - cidr: 10.0.98.151/32
  # ... up to 10.0.98.160/32
```

Each namespace (dev, qa, prod, management) has:
- A dedicated IP pool in its VLAN subnet
- IPs from 10.0.XX.150–160 reserved for LoadBalancer services

### CiliumL2AnnouncementPolicy

Configures **which nodes announce which IPs on which VLANs** (`networking/pdx1/cilium/pdx1-l2-config.yaml`):

```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: qa-vlan-policy
spec:
  serviceSelector:
    matchLabels:
      cilium.io/l2-pool: qa-vlan       # Only announce services tagged for QA VLAN
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker: "true"  # Only worker nodes announce (not control-plane)
  interfaces:
  - bond0.678                            # Announce on this VLAN interface
  loadBalancerIPs: true                  # Enable L2 announcements for LoadBalancer IPs
```

**Critical details:**
- `serviceSelector.matchLabels.cilium.io/l2-pool`: Only services tagged with matching labels are announced
  - E.g., `cilium.io/l2-pool: qa-vlan` tag on a LoadBalancer service means Cilium will announce its IP on bond0.678
- `nodeSelector` restricts announcements to worker nodes only
  - Control-plane nodes do not announce (keeps the network clean, avoids conflicts)
- `interfaces`: The specific VLAN bond to use for ARP announcements
  - For QA: bond0.678 (vlan678)
  - This must match the worker node's device configuration and the gateway of that subnet

## LoadBalancer Service Setup (QA Example)

`networking/pdx1/qa/traefik-qa-service.yaml` demonstrates the correct configuration:

```yaml
apiVersion: v1
kind: Service
metadata:
  annotations:
    cilium.io/l2-pool: qa-vlan              # Tag: Cilium will announce this IP
    metallb.universe.tf/address-pool: qa-vlan-pool  # Old MetalLB config (ignored, Cilium takes priority)
  labels:
    app: traefik-qa
    cilium.io/l2-pool: qa-vlan              # Also label for service selector matching
  name: traefik-qa
  namespace: qa
spec:
  type: LoadBalancer
  loadBalancerIP: 10.0.98.151               # IP from qa-vlan-pool range
  allocateLoadBalancerNodePorts: true       # Enable nodePort fallback
  externalTrafficPolicy: Cluster            # Route to any node, Cilium handles reply
  internalTrafficPolicy: Cluster
  selector:
    app: traefik-qa                         # Selects traefik-qa pods
  ports:
  - name: web
    port: 80
    targetPort: 80
  - name: websecure
    port: 443
    targetPort: 443
  - name: metrics
    port: 9100
    targetPort: 9100
  - name: keydb-qa
    port: 6380
    targetPort: 6380
```

**Key annotations & labels:**
- `cilium.io/l2-pool: qa-vlan`: Tells Cilium which IP pool and VLAN to use, and enables L2 announcements
  - Without this, the LoadBalancer IP will not be announced on the VLAN
  - The L2AnnouncementPolicy must have a `serviceSelector` matching this label
- `allocateLoadBalancerNodePorts: true`: Allocates nodePort (e.g., 30333 for HTTPS) for traffic reaching any node
  - Cilium routes external traffic from that nodePort to the service

**How traffic flows:**
1. External client on VLAN 678 (10.0.98.x) queries ARP for 10.0.98.151
2. Cilium agents on worker nodes respond with their MAC address (all workers respond)
3. Traffic arrives at a worker node on bond0.678, destined for port 443
4. `iptables` rule on the node redirects to the nodePort (30333)
5. kube-proxy routes nodePort traffic to the service (ClusterIP 10.43.201.228)
6. Cilium L3 routes traffic to the actual traefik-qa pod

## Ingress Routing

Kubernetes Ingress objects define HTTP/HTTPS routing rules. Each namespace uses its own Traefik IngressClass:

### QA Namespace Example

**IngressClass (managed by Traefik Helm chart):**
```yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: traefik-qa
spec:
  controller: traefik.io/ingress-controller
```

**Ingress object** (`networking/pdx1/qa/qa-display-ingress.yaml`):
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: qa-display-ingress
  namespace: qa
spec:
  ingressClassName: traefik-qa        # Route through traefik-qa (LoadBalancer 10.0.98.151)
  tls:
  - hosts:
    - pdx1-qa-display.telnoc.com
  rules:
  - host: pdx1-qa-display.telnoc.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: noctel-display
            port:
              number: 3001
```

**How it works:**
1. Client requests `https://pdx1-qa-display.telnoc.com`
2. DNS resolves to 10.0.98.151 (traefik-qa LoadBalancer IP on VLAN 678)
3. Traefik receives the request and matches the hostname to this Ingress rule
4. Traefik routes to service `noctel-display:3001` in the `qa` namespace
5. Service proxy delivers to the actual pod

## Management Namespace (Isolated VLAN Example)

The management namespace (ArgoCD, Rancher, Jenkins) follows the same pattern but on VLAN 675:

**Service** (`networking/pdx1/management/traefik-management-service.yaml`):
```yaml
apiVersion: v1
kind: Service
metadata:
  annotations:
    cilium.io/l2-pool: management-vlan
  labels:
    app: traefik-management
    cilium.io/l2-pool: management-vlan
  name: traefik-management
  namespace: management
spec:
  type: LoadBalancer
  loadBalancerIP: 10.0.95.151
  selector:
    app: traefik-management
  ports:
  - name: web
    port: 80
  - name: websecure
    port: 443
```

**Ingress** (`jenkins/pdx1/ingress.yaml`):
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jenkins
  namespace: management
spec:
  ingressClassName: traefik-management
  tls:
  - hosts:
    - pdx1-jenkins.telnoc.com
  rules:
  - host: pdx1-jenkins.telnoc.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: jenkins
            port:
              number: 8080
```

Traffic flow: External client → 10.0.95.151 (Cilium announces on bond0.675 via management-vlan-policy) → traefik-management → Jenkins service → Jenkins pod.

## Complete Traffic Flow (QA Example)

```
┌─────────────────────────────────────────────────────────────────────┐
│ External Client (10.0.98.x)                                         │
│ Requests: curl https://pdx1-qa-display.telnoc.com                   │
└─────────────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ DNS Resolution (outside cluster)                                    │
│ pdx1-qa-display.telnoc.com → 10.0.98.151                            │
└─────────────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ ARP Request on VLAN 678 (10.0.98.x)                                │
│ "Who has 10.0.98.151?"                                             │
│                                                                     │
│ Cilium agents on kworker0 & kworker1 respond with their MAC        │
│ (qa-vlan-policy enables L2 announcement on bond0.678)              │
└─────────────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ TCP Connection to 10.0.98.151:443                                  │
│ Traffic reaches kworker0 or kworker1 on bond0.678                  │
└─────────────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ iptables Rule (allocated nodePort 30333)                           │
│ DNAT: 10.0.98.151:443 → 10.43.201.228:443 (service ClusterIP)     │
└─────────────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ Service Proxy (kube-proxy)                                         │
│ Routes to pod IP 10.42.0.214:443 (traefik-qa pod)                 │
│ Pod runs on kworker0 (wherever the pod is scheduled)               │
└─────────────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ Traefik Ingress Controller                                         │
│ Matches hostname "pdx1-qa-display.telnoc.com" to Ingress rule      │
│ Routes to service "noctel-display:3001"                            │
└─────────────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ Service "noctel-display" (ClusterIP)                               │
│ Routes to pod running noctel-display application                   │
│ Pod returns HTTP 200 with content                                  │
└─────────────────────────────────────────────────────────────────────┘
                                ↓
┌─────────────────────────────────────────────────────────────────────┐
│ Response flows back through same path (routed via bond0.678)        │
│ Client receives content over encrypted TLS connection              │
└─────────────────────────────────────────────────────────────────────┘
```

## Critical Configuration Points

### 1. Cilium `direct-routing-device` Must Be Management VLAN

- **What:** `direct-routing-device: "bond0.675"` in both worker-node-config and server-node-config
- **Why:** All inter-node Cilium traffic, API server communication, and L2 announcements use this interface
  - The management VLAN (675) is the only VLAN present on all nodes
  - Other VLANs are namespace-specific and not all nodes connect to them
- **Impact:** If set incorrectly, L2 announcements fail, LoadBalancer IPs become unreachable

### 2. Service Labels Must Match L2AnnouncementPolicy

- **What:** `cilium.io/l2-pool: qa-vlan` label on service metadata
- **Why:** L2AnnouncementPolicy has `serviceSelector.matchLabels.cilium.io/l2-pool: qa-vlan`
  - Without matching labels, Cilium won't know to announce the IP on the VLAN
- **Impact:** LoadBalancer IP allocated but not advertised → external traffic can't reach it

### 3. Worker Nodes Must Have Primary Default Route on Management VLAN

- **What:** `default via 10.0.95.1 dev bond0.675` (no secondary default routes)
- **Why:** Default route is used for return traffic when source IP doesn't match a specific route
  - External clients on VLAN 678 send traffic to 10.0.98.151 (node IP on bond0.678)
  - Response packets must be able to reach the network's default gateway
  - Must be management VLAN (the only one reaching all parts of the cluster)
- **Impact:** If default route points elsewhere (e.g., prod VLAN), return traffic is lost → asymmetric routing failure

### 4. IngressClass Must Match Service Namespace

- **What:** Ingress with `ingressClassName: traefik-qa` routes through traefik-qa LoadBalancer
- **Why:** Each namespace has its own Traefik deployment and IngressClass
  - Keeps ingress controllers isolated per namespace
  - Allows namespace-specific configuration (TLS certs, routing rules)
- **Impact:** Wrong IngressClass = traffic routes through wrong Traefik instance or wrong VLAN

## Adding a New Namespace Ingress

To add a new application to an existing VLAN (e.g., another QA service):

1. **Create a LoadBalancer service:**
   ```yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: my-app
     namespace: qa
     annotations:
       cilium.io/l2-pool: qa-vlan
     labels:
       app: my-app
       cilium.io/l2-pool: qa-vlan
   spec:
     type: LoadBalancer
     loadBalancerIP: 10.0.98.152  # Next available IP from qa-vlan-pool
     selector:
       app: my-app
     ports:
     - port: 80
       targetPort: 8080
   ```

2. **Create an Ingress rule:**
   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: my-app-ingress
     namespace: qa
   spec:
     ingressClassName: traefik-qa
     tls:
     - hosts:
       - pdx1-qa-my-app.telnoc.com
     rules:
     - host: pdx1-qa-my-app.telnoc.com
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: my-app
               port:
                 number: 80
   ```

3. **Add DNS record:**
   - Register `pdx1-qa-my-app.telnoc.com` → `10.0.98.152` in DNS

4. **Verify:**
   - Check Cilium announced the IP: `cilium bpf lb list | grep 10.0.98.152`
   - Check service has LoadBalancer IP: `kubectl get svc my-app -n qa`
   - Test externally: `curl https://pdx1-qa-my-app.telnoc.com`

## Troubleshooting

### LoadBalancer IP allocated but unreachable externally

**Symptoms:** `kubectl get svc` shows `EXTERNAL-IP: 10.0.98.151` but `ping 10.0.98.151` fails.

**Check:**
1. Service has `cilium.io/l2-pool` label matching the VLAN pool name
2. L2AnnouncementPolicy exists with matching `serviceSelector.matchLabels`
3. L2AnnouncementPolicy lists correct interface (e.g., `bond0.678` for QA)
4. Worker nodes have correct `direct-routing-device` in their CiliumNodeConfig
5. Worker node default route points to management VLAN: `ip route | grep default`

### Ingress returns 404 or timeout

**Symptoms:** DNS resolves, TCP connects, but no response or wrong service.

**Check:**
1. Ingress uses correct `ingressClassName` (e.g., `traefik-qa`)
2. Hostname in Ingress rule matches DNS name used by client
3. Backend service name and port are correct
4. Service selector matches pod labels
5. Pod is running and healthy: `kubectl get pods -n qa`

### Asymmetric routing (requests arrive, responses don't)

**Symptoms:** One-way communication, timeouts on downloads, curl hangs on responses.

**Check:**
1. Worker node default route: `ssh 10.0.97.10 'ip route | grep default'`
   - Should be: `default via 10.0.95.1 dev bond0.675` (management VLAN)
   - If it points elsewhere, return traffic is routed incorrectly
2. No stray routes: `ip route show | grep 10.0.` should show expected subnets + management default
3. Cilium direct-routing-device matches the default route interface

## Configuration Files

All networking configuration files are in `networking/pdx1/`:

- `cilium/pdx1-l2-config.yaml` — CiliumLoadBalancerIPPool + CiliumL2AnnouncementPolicy definitions
- `cilium/server-node-config.yaml` — Control-plane node Cilium overrides
- `cilium/worker-node-config.yaml` — Worker node Cilium overrides
- `qa/` — QA namespace service and ingress definitions
- `management/` — Management namespace services (traefik, etc.)
- `prod/` — Prod namespace services (similar structure)
- `dev/` — Dev namespace services (similar structure)

When modifying network configuration:
1. Update the YAML files
2. `kubectl apply -f networking/pdx1/`
3. Watch Cilium agent logs for errors: `kubectl logs -l k8s-app=cilium -n kube-system -f`
4. Wait for LoadBalancer IP status to show `EXTERNAL-IP`: `kubectl get svc -n qa`
5. Verify L2 announcements: `cilium bpf lb list` on a worker node

