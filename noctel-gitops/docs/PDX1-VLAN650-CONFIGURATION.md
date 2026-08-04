# PDX1 VLAN 650 Configuration for SeaweedFS Access

**Date:** February 18, 2026
**Cluster:** pdx1-cluster (k3s)
**Purpose:** Enable worker nodes to access SeaweedFS control plane on VLAN 650

---

## Overview

The PDX1 Kubernetes cluster worker nodes need connectivity to the SeaweedFS control plane infrastructure on VLAN 650 (10.0.91.0/24 network). This requires adding a secondary VLAN interface to each worker node.

## Current State

**Worker Nodes:**
- `pdx1-kworker0`: Primary IP 10.0.95.10 (VLAN 695)
- `pdx1-kworker1`: Primary IP 10.0.95.11 (VLAN 695)

**SeaweedFS Control Plane (VLAN 650 - 10.0.91.0/24):**
- Volume Servers:
  - 10.0.91.19 (pdx-truenas0)
  - 10.0.91.20 (pdx-truenas1)
- Master Servers:
  - 10.0.91.21 (pdx-s3-cp1)
  - 10.0.91.22 (pdx-s3-cp2)
  - 10.0.91.23 (pdx-s3-cp3)
- Master VIP: **10.0.91.24** (s3 control plane)

## Required Configuration

### VLAN 650 IP Assignments

Add secondary VLAN 650 interfaces to worker nodes:

| Node | Primary VLAN | Primary IP | VLAN 650 IP | Network |
|------|-------------|------------|-------------|---------|
| pdx1-kworker0 | 695 | 10.0.95.10 | 10.0.91.25/24 | 10.0.91.0/24 |
| pdx1-kworker1 | 695 | 10.0.95.11 | 10.0.91.26/24 | 10.0.91.0/24 |

### Network Configuration

**On pdx1-kworker0:**
```bash
# Add VLAN 650 interface (manual configuration)
nmcli connection add type vlan \
  con-name vlan650 \
  ifname bond0.650 \
  dev bond0 \
  id 650 \
  ip4 10.0.91.25/24

# Bring up the interface
nmcli connection up vlan650
```

**On pdx1-kworker1:**
```bash
# Add VLAN 650 interface (manual configuration)
nmcli connection add type vlan \
  con-name vlan650 \
  ifname bond0.650 \
  dev bond0 \
  id 650 \
  ip4 10.0.91.26/24

# Bring up the interface
nmcli connection up vlan650
```

### Firewall Configuration

**On worker nodes (if firewalld is active):**
```bash
# Allow outbound connections to SeaweedFS ports
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" destination address="10.0.91.19" port port="8080" protocol="tcp" accept'
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" destination address="10.0.91.20" port port="8080" protocol="tcp" accept'
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" destination address="10.0.91.21-10.0.91.24" port port="9333" protocol="tcp" accept'
firewall-cmd --reload
```

**On network firewall/router:**
- Ensure traffic from 10.0.91.25-26 to 10.0.91.19-24 is permitted
- Required ports:
  - TCP 9333 (SeaweedFS Master)
  - TCP 8080 (SeaweedFS Volume)

## Verification Steps

After configuration, verify connectivity from worker nodes:

```bash
# Test from pdx1-kworker0
ping -c 3 -I 10.0.91.25 10.0.91.24
curl -I http://10.0.91.24:9333/cluster/status
curl -I http://10.0.91.19:8080/status
curl -I http://10.0.91.20:8080/status
curl -I http://10.0.91.21:9333/cluster/status
curl -I http://10.0.91.22:9333/cluster/status
curl -I http://10.0.91.23:9333/cluster/status

# Test from pdx1-kworker1
ping -c 3 -I 10.0.91.26 10.0.91.24
curl -I http://10.0.91.24:9333/cluster/status
curl -I http://10.0.91.19:8080/status
curl -I http://10.0.91.20:8080/status
```

## DNS Configuration

Ensure DNS entries are configured:

| Hostname | IP | Purpose |
|----------|-----|---------|
| pdx-truenas0 | 10.0.91.19 | Volume Server 1 |
| pdx-truenas1 | 10.0.91.20 | Volume Server 2 |
| pdx-s3-cp1 | 10.0.91.21 | Master Server 1 |
| pdx-s3-cp2 | 10.0.91.22 | Master Server 2 |
| pdx-s3-cp3 | 10.0.91.23 | Master Server 3 |
| pdx-s3-master.telnoc.com | 10.0.91.24 | Master VIP |

```bash
# Test DNS resolution from worker nodes
dig pdx-s3-master.telnoc.com +short
# Expected result: 10.0.91.24

nslookup pdx-s3-master.telnoc.com
```

## SeaweedFS Configuration Update

After VLAN 650 is configured and connectivity is verified, update SeaweedFS environment configs to use external masters:

### Update Chart Values

Update `environments/pdx1/pdx1-dev-config.yaml`:
```yaml
seaweedfs:
  version: "3.57"
  externalMaster:
    enabled: true
    endpoint: "pdx-s3-master.telnoc.com:9333"  # Points to 10.0.91.24
  deployMaster: false    # Don't deploy master in k8s
  deployVolume: false    # Don't deploy volume in k8s
  deployFiler: true      # Deploy filer to access external cluster
  deployS3: true         # Deploy S3 gateway
  persistence:
    enabled: true
    size: 50Gi
    storageClass: longhorn
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
```

Apply same configuration to:
- `environments/pdx1/pdx1-qa-config.yaml`
- `environments/pdx1/pdx1-prod-config.yaml`

## Implementation Checklist

- [ ] Configure VLAN 650 on pdx1-kworker0 (10.0.91.25/24) - **MANUAL**
- [ ] Configure VLAN 650 on pdx1-kworker1 (10.0.91.26/24) - **MANUAL**
- [ ] Configure firewall rules on worker nodes
- [ ] Verify firewall rules on network infrastructure
- [ ] Test connectivity to master VIP (10.0.91.24:9333)
- [ ] Test connectivity to volume servers (10.0.91.19:8080, 10.0.91.20:8080)
- [ ] Test connectivity to individual masters (10.0.91.21-23:9333)
- [ ] Verify DNS resolution for pdx-s3-master.telnoc.com
- [ ] Update SeaweedFS environment configurations (dev/qa/prod)
- [ ] Commit and push configuration changes
- [ ] Sync ArgoCD applications
- [ ] Verify S3 gateway pods are running
- [ ] Test S3 functionality (bucket creation, file upload)

## Network Diagram

```
┌─────────────────────────────────────────────────────────────┐
│ PDX1 Kubernetes Cluster (VLAN 695 - 10.0.95.0/24)          │
│                                                             │
│  ┌─────────────┐              ┌─────────────┐             │
│  │pdx1-kworker0│              │pdx1-kworker1│             │
│  ├─────────────┤              ├─────────────┤             │
│  │10.0.95.10   │◄────VLAN 695 ────►10.0.95.11   │         │
│  │10.0.91.125  │◄────VLAN 650 ────►10.0.91.126  │         │
│  └──────┬──────┘              └──────┬──────┘             │
│         │                            │                     │
│         │    ┌────────────────┐      │                     │
│         └────┤ S3 Gateway Pod ├──────┘                     │
│              │  (Filer Pod)   │                            │
│              └────────┬───────┘                            │
└────────────────────┬──┴───────────────────────────────────┘
                     │
                 VLAN 650
                10.0.91.0/24
                     │
        ┌────────────┴────────────────────┐
        │                                 │
        ▼                                 ▼
┌─────────────────────┐         ┌──────────────────┐
│   Master Cluster    │         │  Volume Servers  │
├─────────────────────┤         ├──────────────────┤
│10.0.91.21 (cp1)     │         │10.0.91.19 (t0)   │
│10.0.91.22 (cp2)     │         │10.0.91.20 (t1)   │
│10.0.91.23 (cp3)     │         └──────────────────┘
│                     │
│VIP: 10.0.91.24:9333 │
│(pdx-s3-master)      │
└─────────────────────┘
```

## Troubleshooting

### Cannot reach SeaweedFS masters

```bash
# Check VLAN interface status
ip link show bond0.650
ip addr show bond0.650

# Check connectivity
ping 10.0.91.24
ping 10.0.91.19
ping 10.0.91.20

# Test port connectivity
telnet 10.0.91.24 9333
nc -zv 10.0.91.24 9333
nc -zv 10.0.91.19 8080
nc -zv 10.0.91.20 8080
```

### S3 gateway pods failing to connect

```bash
# Check pod logs
kubectl logs -n dev -l app=seaweedfs-s3 --tail=100

# Check filer logs
kubectl logs -n dev -l component=filer --tail=100

# Check if external master is configured correctly
kubectl get configmap -n dev seaweedfs-filer-config -o yaml
```

## References

- SeaweedFS Architecture: https://github.com/seaweedfs/seaweedfs/wiki/Architecture
- SeaweedFS S3 Gateway: https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API
- Chart: `charts/seaweedfs/`

---

**Document Owner:** Infrastructure Team
**Status:** PENDING IMPLEMENTATION
**Priority:** HIGH (blocking S3 functionality)
**Next Action:** Configure VLAN 650 on worker nodes
