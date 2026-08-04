# K3s Host Configuration Checklist for Production

**Date:** 2026-05-11  
**Purpose:** Ensure K3s worker and control-plane nodes are properly configured at the OS level  
**Scope:** Linux kernel parameters, resource limits, filesystem, and container runtime settings

---

## Audit Data (2026-05-11)

**Current State (All Nodes):**
- PID Limits (kernel.pid_max): 4194304 ✓
- TCP Retransmit Settings: tcp_retries2=15, tcp_syn_retries=6 ✓
- Network MTU: 1500 ✓
- SELinux Status: Permissive ✓
- k3s Service: active (kserver), inactive (kworker) ✓
- AppArmor: Not blocking ✓
- **PENDING:** Disk usage breakdown (kserver0 at 81%)

---

## Overview

Many production failures stem not from Kubernetes configuration but from insufficient host OS settings. This checklist documents the critical host-level configurations that can cause pod failures, connection errors, resource exhaustion, and silent failures.

Common symptoms of misconfigured hosts:
- "Too many open files" errors in pod logs
- `unable to create pods — process limit reached`
- Connection timeouts on otherwise healthy services
- "Cannot allocate memory" during normal load
- Slow API server or etcd under moderate load
- Disk space unexpectedly fills (`/var/lib/rancher/k3s` grows to 100%)

---

## Critical Host Configurations (Verify on All Nodes)

### 1. File Descriptor Limits

**Why:** Kubernetes/kubelet maintains many open file handles. Low limits = connection refusals, pod startup failures.

**Verify on each node:**
```bash
ssh <node-ip> "cat /proc/sys/fs/file-max"
ssh <node-ip> "ulimit -n"
ssh <node-ip> "cat /etc/security/limits.conf | grep -E '^\*|^root' | head -5"
```

**Expected:**
- `fs.file-max` ≥ 2097152 (2M)
- `ulimit -n` (per-process) ≥ 65536
- System limits in `/etc/security/limits.conf`:
  ```
  * soft nofile 65536
  * hard nofile 1048576
  * soft nproc 65536
  * hard nproc 1048576
  ```

**PDX1 Status:** 
- [ ] Check all 3 worker nodes (kworker0, kworker1, kworker2)
- [ ] Check 2 control-plane nodes (kserver2, kserver3)

---

### 2. Process Limits

**Why:** Kubelet spawns processes for containers. Too low = `Cannot fork` errors.

**Verify:**
```bash
ssh <node-ip> "cat /proc/sys/kernel/pid_max"
ssh <node-ip> "sysctl kernel.pid_max"
```

**Expected:**
- `kernel.pid_max` ≥ 4194304 (4M) on large clusters
- Minimum: 65536 for small clusters

**PDX1 Status:**
- [ ] Verify on all nodes

---

### 3. Virtual Memory Limits (Elasticsearch-critical)

**Why:** Elasticsearch requires `vm.max_map_count` ≥ 262144. Without it, ES fails to start or crashes.

**Verify:**
```bash
ssh <node-ip> "sysctl vm.max_map_count"
```

**Expected:**
- `vm.max_map_count` ≥ 262144

**Fix if needed:**
```bash
ssh <node-ip> "sudo sysctl -w vm.max_map_count=262144"
# Persist in /etc/sysctl.conf:
ssh <node-ip> "echo 'vm.max_map_count=262144' | sudo tee -a /etc/sysctl.conf"
ssh <node-ip> "sudo sysctl -p"
```

**PDX1 Status:**
- [ ] Verify on all nodes (especially nodes running Elasticsearch)

---

### 4. TCP Connection Limits

**Why:** High concurrency services (APIs, gateways) need higher TCP connection limits.

**Verify:**
```bash
ssh <node-ip> "sysctl net.ipv4.tcp_max_tw_buckets"
ssh <node-ip> "sysctl net.core.somaxconn"
ssh <node-ip> "sysctl net.ipv4.ip_local_port_range"
```

**Expected:**
- `net.ipv4.tcp_max_tw_buckets` ≥ 1048576
- `net.core.somaxconn` ≥ 32768
- `net.ipv4.ip_local_port_range` = `1024 65535` (or similar wide range)

**Fix if needed:**
```bash
cat <<EOF | ssh <node-ip> "sudo tee -a /etc/sysctl.conf"
net.ipv4.tcp_max_tw_buckets = 1048576
net.core.somaxconn = 32768
net.ipv4.ip_local_port_range = 1024 65535
EOF
ssh <node-ip> "sudo sysctl -p"
```

**PDX1 Status:**
- [ ] Verify on all nodes

---

### 5. Swap Disabled

**Why:** Kubernetes docs require swap disabled. Swap causes unpredictable pod OOM behavior.

**Verify:**
```bash
ssh <node-ip> "swapon -s"  # Should return empty (no swap enabled)
ssh <node-ip> "free -h | grep Swap"  # Should show 0B
```

**Fix if swap is enabled:**
```bash
ssh <node-ip> "sudo swapoff -a"
# Persist by commenting out swap line in /etc/fstab
ssh <node-ip> "sudo sed -i 's/^.*swap.*/#&/' /etc/fstab"
```

**PDX1 Status:**
- [ ] Verify on all nodes

---

### 6. Disk Space Monitoring

**Why:** K3s stores local PVCs in `/var/lib/rancher/k3s/storage/`. Disk full = pod crashes, etcd corruption risk.

**Verify on each node:**
```bash
ssh <node-ip> "df -h /var/lib/rancher/k3s/"
ssh <node-ip> "du -sh /var/lib/rancher/k3s/storage/"
```

**Expected:**
- Disk usage < 80%
- Storage/ directory should stay reasonable (most should be on longhorn/replicated volumes, not local-path)

**Cleanup if needed:**
```bash
ssh <node-ip> "ls -lah /var/lib/rancher/k3s/storage/ | head -20"
# Identify old/orphaned PVCs and delete them manually (kubernetes handles cleanup after pod deletion)
```

**PDX1 Status:**
- [ ] Check all nodes
- [ ] Note that Phase 10 (REMEDIATION_PLAN) migrates monitoring away from local-path, should reduce disk pressure

---

### 7. Inotify Limits (File Watcher Limit)

**Why:** Some applications (e.g., config management, tests) watch many files. Low inotify limits = "No space left on device" errors despite disk having space.

**Verify:**
```bash
ssh <node-ip> "sysctl fs.inotify.max_user_watches"
```

**Expected:**
- `fs.inotify.max_user_watches` ≥ 524288

**Fix if needed:**
```bash
ssh <node-ip> "echo 'fs.inotify.max_user_watches=524288' | sudo tee -a /etc/sysctl.conf"
ssh <node-ip> "sudo sysctl -p"
```

**PDX1 Status:**
- [ ] Verify on all nodes

---

### 8. Container Runtime (containerd) Settings

**Why:** Incorrect runtime limits can prevent pod creation or cause pod crashes.

**Verify:**
```bash
ssh <node-ip> "cat /etc/containerd/config.toml | grep -A 10 '\[containerd\]'"
ssh <node-ip> "systemctl status containerd | grep Active"
```

**Expected:**
- containerd is running and enabled
- Max open files for containerd ≥ 65536

**PDX1 Typical Config (K3s managed):**
K3s uses its own containerd config; verify at:
```bash
ssh <node-ip> "cat /var/lib/rancher/k3s/agent/etc/containerd/config.toml | head -20"
```

**PDX1 Status:**
- [ ] Verify on all nodes

---

### 9. CPU Frequency Scaling (Performance)

**Why:** If CPU scaling is too aggressive, kubelet may be throttled under load.

**Verify:**
```bash
ssh <node-ip> "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
ssh <node-ip> "cat /sys/devices/system/cpu/intel_pstate/no_turbo"  # Intel; AMD varies
```

**Expected (for high-performance clusters):**
- scaling_governor = `performance` (or `ondemand` at minimum, not `powersave`)
- Turbo boost enabled (no_turbo = 0)

**PDX1 Status:**
- [ ] Verify on high-traffic worker nodes

---

### 10. Kernel Panic / Watchdog Settings

**Why:** Node hangs can cause extended pod disruption. Watchdog can auto-reboot hung nodes.

**Verify:**
```bash
ssh <node-ip> "cat /proc/sys/kernel/panic"
ssh <node-ip> "cat /proc/sys/kernel/panic_on_oops"
```

**Expected (for production):**
- `kernel.panic` = 60 (reboot after 60 sec on panic)
- `kernel.panic_on_oops` = 1 (treat oops as panic)

**Fix if needed:**
```bash
cat <<EOF | ssh <node-ip> "sudo tee -a /etc/sysctl.conf"
kernel.panic = 60
kernel.panic_on_oops = 1
EOF
ssh <node-ip> "sudo sysctl -p"
```

**PDX1 Status:**
- [ ] Verify on all nodes

---

## Network Configuration

### 1. MTU Size (for overlay networks)

**Why:** Cilium VXLAN overlays have a smaller effective MTU. Mismatches cause packet fragmentation and slow performance.

**Verify:**
```bash
ssh <node-ip> "ip link show | grep -E 'eth|bond' | head -5"
ssh <node-ip> "ip link show cilium_vxlan | grep mtu"
```

**Expected:**
- Physical interfaces (eth/bond): MTU 1500
- Cilium VXLAN tunnel: MTU 1450 (or 1400 to be safe with VLAN headers)

**PDX1 Status:**
- [ ] Verify on all nodes

---

### 2. TCP Retransmit Settings (for reliability)

**Why:** Very low retransmit counts can cause transient connection failures; too high wastes bandwidth.

**Verify:**
```bash
ssh <node-ip> "sysctl net.ipv4.tcp_retries2"
ssh <node-ip> "sysctl net.ipv4.tcp_syn_retries"
```

**Expected:**
- `net.ipv4.tcp_retries2` = 15 (standard; ~13 min timeout)
- `net.ipv4.tcp_syn_retries` = 6 (standard)

**PDX1 Status:**
- [ ] Verify on all nodes

---

## Security & SELinux/AppArmor

### 1. SELinux Status (if applicable)

**Why:** Overly restrictive SELinux can prevent kubelet operations, mount failures, and volume access.

**Verify:**
```bash
ssh <node-ip> "getenforce"  # If command not found, SELinux is not installed (OK)
```

**Expected:**
- `Disabled` or `Permissive` (K3s/kubelet typically requires no mandatory enforcement)

**PDX1 Status (likely not applicable on Ubuntu):**
- [ ] Verify; if Disabled, no action needed

---

### 2. AppArmor Status (Ubuntu/Debian)

**Why:** AppArmor restrictions can break kubelet/container operations.

**Verify:**
```bash
ssh <node-ip> "systemctl status apparmor | grep Active"
ssh <node-ip> "aa-status 2>/dev/null | head -5"
```

**Expected:**
- AppArmor enabled is OK (K3s/kubelet have compatible profiles)

**PDX1 Status:**
- [ ] Verify; K3s usually works fine with AppArmor enabled

---

## Node Readiness & Status

### 1. Kubelet Status

**Verify:**
```bash
ssh <node-ip> "systemctl status kubelet"
ssh <node-ip> "journalctl -u kubelet -n 50 | tail -20"
```

**Expected:**
- kubelet is active and running
- No errors in recent logs

**PDX1 Status:**
- [ ] Check all nodes

---

### 2. Kubernetes Node Ready

**Verify from cluster:**
```bash
kubectl get nodes
```

**Expected:**
- All nodes show `Ready` (not `NotReady`, `Unknown`, `SchedulingDisabled`)
- All node conditions are `True` (Ready, MemoryPressure=False, DiskPressure=False, etc.)

**PDX1 Status:**
- [ ] Verify kserver2, kserver3, kworker0, kworker1, kworker2 are Ready

---

## PDX1 Specific Audit (Run These Commands)

Execute this script on all PDX1 nodes to collect current state:

```bash
#!/bin/bash
NODE=$1
echo "=== Host Config Audit for $NODE ==="
echo "File Descriptors:"
ssh $NODE "cat /proc/sys/fs/file-max && ulimit -n"
echo "PID Max:"
ssh $NODE "sysctl kernel.pid_max"
echo "VM Max Map Count:"
ssh $NODE "sysctl vm.max_map_count"
echo "TCP Limits:"
ssh $NODE "sysctl net.ipv4.tcp_max_tw_buckets && sysctl net.core.somaxconn"
echo "Swap:"
ssh $NODE "free -h | grep Swap"
echo "Disk Usage:"
ssh $NODE "df -h /var/lib/rancher/k3s/"
echo "Inotify Max Watches:"
ssh $NODE "sysctl fs.inotify.max_user_watches"
echo "Kernel Panic:"
ssh $NODE "sysctl kernel.panic"
echo "---"
```

**Run:**
```bash
chmod +x audit-host-config.sh
./audit-host-config.sh 10.0.96.25  # kworker0
./audit-host-config.sh 10.0.96.26  # kworker1
./audit-host-config.sh 10.0.96.27  # kworker2
./audit-host-config.sh 10.0.96.28  # kserver2
./audit-host-config.sh 10.0.96.29  # kserver3
```

---

## Known PDX1 Issues & History

From prior incidents:

### ulimit Issue (Previous Fix)
**Issue:** File descriptor limits were set too low (default ~1024), causing "Too many open files" errors under load.  
**Impact:** Connection rejections, pod startup failures during scaling.  
**Fix:** Increased to 65536 system-wide.  
**Status:** [  ] Verify fix is still in place on all nodes.

### Elasticsearch vm.max_map_count
**Issue:** Elasticsearch pods OOMKilled because vm.max_map_count was too low.  
**Impact:** Monitoring and logging unavailable.  
**Status:** [  ] Verify on all nodes where Elasticsearch could run.

### etcd Disk Saturation (PDX2)
**Issue:** `/var/lib/rancher/k3s/` filled up due to etcd WAL explosion.  
**Impact:** 600+ pod restarts cluster-wide.  
**Prevention:** Monitor disk usage, enable defrag on etcd.  
**Status:** [  ] Check disk usage trends on PDX1.

---

## Remediation & Persistence

### Temporary Fix (until node reboot)
```bash
ssh <node-ip> "sysctl -w <param>=<value>"
```

### Permanent Fix (survives reboot)
```bash
ssh <node-ip> "echo '<param>=<value>' | sudo tee -a /etc/sysctl.conf"
ssh <node-ip> "sudo sysctl -p"
```

### For /etc/security/limits.conf
```bash
ssh <node-ip> "sudo tee -a /etc/security/limits.conf" <<'EOF'
* soft nofile 65536
* hard nofile 1048576
* soft nproc 65536
* hard nproc 1048576
root soft nofile 65536
root hard nofile 1048576
root soft nproc 65536
root hard nproc 1048576
EOF
```

(New limits apply on next login)

---

## Recommended Checklist (Monthly)

- [ ] Disk usage < 80% on all nodes
- [ ] No kernel panics or OOM kills in last 30 days: `ssh <node> "dmesg | grep -i 'panic\|killed' | tail -5"`
- [ ] All nodes Ready: `kubectl get nodes`
- [ ] No NotReady or SchedulingDisabled nodes
- [ ] Kubelet not restarting frequently: `ssh <node> "journalctl -u kubelet --since='1 hour ago' | grep Restart"`
- [ ] No sysctl warnings in kernel log: `ssh <node> "dmesg | grep sysctl | tail -5"`

---

## Summary Table

| Parameter | Minimum | Recommended | PDX1 Current | Status |
|-----------|---------|-------------|--------------|--------|
| fs.file-max | 2097152 | 4194304 | ? | [ ] |
| ulimit nofile | 65536 | 1048576 | ? | [ ] |
| kernel.pid_max | 65536 | 4194304 | ? | [ ] |
| vm.max_map_count | 262144 | 262144 | ? | [ ] |
| net.ipv4.tcp_max_tw_buckets | 524288 | 1048576 | ? | [ ] |
| net.core.somaxconn | 4096 | 32768 | ? | [ ] |
| Swap | 0 (disabled) | 0 (disabled) | ? | [ ] |
| Disk (/var/lib/rancher/k3s/) | < 80% | < 60% | ? | [ ] |
| fs.inotify.max_user_watches | 8192 | 524288 | ? | [ ] |
| kernel.panic | 0 | 60 | ? | [ ] |

Fill in this table after running audit commands on all PDX1 nodes.

---

## References

- [Kubernetes Host Configuration Docs](https://kubernetes.io/docs/setup/production-environment/container-runtimes/)
- [K3s Known Issues](https://docs.k3s.io/known-issues)
- [Linux kernel sysctl tuning for networking](https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt)
- [Elasticsearch system requirements](https://www.elastic.co/guide/en/elasticsearch/reference/current/system-requirements.html)
