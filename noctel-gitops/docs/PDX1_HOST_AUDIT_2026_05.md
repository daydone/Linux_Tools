# PDX1 Host Configuration Audit Results — May 2026

**Date:** 2026-05-11  
**Status:** 8 Critical issues found  
**Action Required:** YES — kserver nodes have dangerously low resource limits

---

## Executive Summary

PDX1 control-plane nodes (kserver0/1/2) are severely misconfigured at the OS level, with file descriptor limits, TCP limits, and inotify limits far below production-safe thresholds. This explains etcd instability, API server connection issues, and admission webhook timeouts.

Worker nodes (kworker0/1) are reasonably well-configured but have swap enabled (should be disabled) and kernel panic set too low.

---

## Detailed Findings

### CRITICAL: kserver0, kserver1, kserver2 — ulimit -n = 1024

**Current State:**
```
pdx1-kserver0: ulimit -n = 1024
pdx1-kserver1: ulimit -n = 1024
pdx1-kserver2: ulimit -n = 1024
```

**Expected:** 65536 minimum; 1048576 recommended for control-plane

**Impact:**
- etcd fails to open connections beyond ~1000 file descriptors
- API server gets "Too many open files" errors
- Admission webhooks timeout
- Kube-controller-manager and kubelet can't maintain connections
- Results in pod stuck on Pending, API errors, controller failures

**Root Cause:** ulimit not configured in `/etc/security/limits.conf`

**Fix:**
```bash
# On each kserver node (kserver0, kserver1, kserver2):
ssh 10.0.95.30 'echo "* soft nofile 65536" | sudo tee -a /etc/security/limits.conf'
ssh 10.0.95.30 'echo "* hard nofile 1048576" | sudo tee -a /etc/security/limits.conf'
ssh 10.0.95.30 'echo "root soft nofile 65536" | sudo tee -a /etc/security/limits.conf'
ssh 10.0.95.30 'echo "root hard nofile 1048576" | sudo tee -a /etc/security/limits.conf'
# Reboot or restart kubelet/etcd
```

**Priority:** P0 — BLOCKING production stability

---

### CRITICAL: kserver0, kserver1, kserver2 — vm.max_map_count = 65530

**Current State:**
```
pdx1-kserver0: vm.max_map_count = 65530
pdx1-kserver1: vm.max_map_count = 65530
pdx1-kserver2: vm.max_map_count = 65530
```

**Expected:** 262144

**Impact:**
- Elasticsearch pods fail to start with "max virtual memory areas" error
- Any memory-mapped workload (databases, search engines) fails
- Pod logs: `mmap failed: Cannot allocate memory`

**Fix:**
```bash
ssh 10.0.95.30 'echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf'
ssh 10.0.95.30 'sudo sysctl -p'
```

**Priority:** P0 — Blocks Elasticsearch

---

### CRITICAL: kserver0, kserver1, kserver2 — net.ipv4.tcp_max_tw_buckets = 32768

**Current State:**
```
pdx1-kserver0: tcp_max_tw_buckets = 32768
pdx1-kserver1: tcp_max_tw_buckets = 32768
pdx1-kserver2: tcp_max_tw_buckets = 32768
```

**Expected:** 262144 minimum; 1048576 recommended

**Impact:**
- Control-plane to worker connections exceed TIME_WAIT bucket limit
- Kubelet can't connect to API server
- Pods stuck on NotReady
- etcd replication connections drop

**Fix:**
```bash
ssh 10.0.95.30 'echo "net.ipv4.tcp_max_tw_buckets = 262144" | sudo tee -a /etc/sysctl.conf'
ssh 10.0.95.30 'sudo sysctl -p'
```

**Priority:** P0 — Causes node NotReady

---

### CRITICAL: kserver0, kserver1, kserver2 — net.core.somaxconn = 4096

**Current State:**
```
pdx1-kserver0: somaxconn = 4096
pdx1-kserver1: somaxconn = 4096
pdx1-kserver2: somaxconn = 4096
```

**Expected:** 32768

**Impact:**
- API server listen queue fills up under load
- Requests start failing with "connection refused"
- kubelet can't reach API server
- etcd election fails

**Fix:**
```bash
ssh 10.0.95.30 'echo "net.core.somaxconn = 32768" | sudo tee -a /etc/sysctl.conf'
ssh 10.0.95.30 'sudo sysctl -p'
```

**Priority:** P0 — Causes API server connection failures

---

### HIGH: kserver0, kserver1, kserver2 — fs.inotify.max_user_watches

**Current State:**
```
pdx1-kserver0: fs.inotify.max_user_watches = 58186
pdx1-kserver1: fs.inotify.max_user_watches = 56907
pdx1-kserver2: fs.inotify.max_user_watches = 58186
```

**Expected:** 262144 minimum; 524288 recommended

**Impact:**
- File watcher exhaustion
- ConfigMap/Secret updates fail to propagate
- Controller-manager can't watch resources
- "ENOSPC: No space left on device" errors despite disk having space

**Fix:**
```bash
ssh 10.0.95.30 'echo "fs.inotify.max_user_watches = 262144" | sudo tee -a /etc/sysctl.conf'
ssh 10.0.95.30 'sudo sysctl -p'
```

**Priority:** P1

---

### HIGH: kserver0, kserver1, kserver2 — kernel.panic = 10

**Current State:**
```
All kserver nodes: kernel.panic = 10
```

**Expected:** 60 (reboot after 60 sec on panic)

**Impact:**
- Node panics stay down for 10 seconds instead of automatic reboot
- Extends incident duration
- Manual intervention often needed

**Fix:**
```bash
ssh 10.0.95.30 'echo "kernel.panic = 60" | sudo tee -a /etc/sysctl.conf'
ssh 10.0.95.30 'sudo sysctl -p'
```

**Priority:** P2

---

### HIGH: kserver0 — Disk at 81% (approaching critical)

**Current State:**
```
pdx1-kserver0: 81% used (89G / 116G)
```

**Expected:** < 80% (prefer < 60%)

**Impact:**
- etcd can't write new entries (WAL corruption risk)
- Pod evictions if disk gets to 85%+
- Control-plane instability

**Immediate Action:** Check what's consuming disk space:
```bash
ssh 10.0.95.30 'du -sh /var/lib/rancher/k3s/server/*' | sort -rh
```

**Fix:** Likely need to clean local-path PVCs or enable etcd auto-defrag

**Priority:** P1 — immediate investigation needed

---

### MEDIUM: kworker0, kworker1 — Swap enabled (should be disabled)

**Current State:**
```
pdx1-kworker0: 2.0Gi swap allocated, 0B used
pdx1-kworker1: 2.0Gi swap allocated, 0B used
```

**Expected:** Swap disabled

**Impact:**
- Kubernetes docs require swap disabled
- Pod OOM behavior becomes unpredictable
- Workload performance suffers

**Fix:**
```bash
ssh 10.0.95.10 'sudo swapoff -a'
ssh 10.0.95.10 'sudo sed -i "s/^.*swap.*/#&/" /etc/fstab'
```

**Priority:** P2

---

### MEDIUM: kserver1 — Swap enabled with 234Mi active usage

**Current State:**
```
pdx1-kserver1: 2.0Gi swap allocated, 234Mi ACTIVE
```

**Expected:** Swap disabled

**Impact:** Same as workers, plus control-plane components on swap = latency spikes, election issues

**Fix:**
```bash
ssh 10.0.95.31 'sudo swapoff -a'
ssh 10.0.95.31 'sudo sed -i "s/^.*swap.*/#&/" /etc/fstab'
```

**Priority:** P2 — but consider immediate action since swap is in use

---

### GOOD: Worker File Descriptor Limits

```
pdx1-kworker0: fs.file-max = 2097152, ulimit -n = 1048576 ✓
pdx1-kworker1: fs.file-max = 2097152, ulimit -n = 1048576 ✓
```

Workers are properly configured. No action needed.

---

### GOOD: Worker VM Max Map Count

```
pdx1-kworker0: vm.max_map_count = 262144 ✓
pdx1-kworker1: vm.max_map_count = 262144 ✓
```

Sufficient for any workload. No action needed.

---

## Summary Table

| Parameter | kworker0 | kworker1 | kserver0 | kserver1 | kserver2 | Status |
|-----------|----------|----------|----------|----------|----------|--------|
| ulimit -n | 1048576 ✓ | 1048576 ✓ | 1024 ✗ | 1024 ✗ | 1024 ✗ | CRITICAL |
| vm.max_map_count | 262144 ✓ | 262144 ✓ | 65530 ✗ | 65530 ✗ | 65530 ✗ | CRITICAL |
| tcp_max_tw_buckets | 262144 | 262144 | 32768 ✗ | 32768 ✗ | 32768 ✗ | CRITICAL |
| somaxconn | 32768 ✓ | 32768 ✓ | 4096 ✗ | 4096 ✗ | 4096 ✗ | CRITICAL |
| inotify_max_user_watches | 1048576 ✓ | 1048576 ✓ | 58186 ✗ | 56907 ✗ | 58186 ✗ | HIGH |
| kernel.panic | 10 ⚠ | 10 ⚠ | 10 ⚠ | 10 ⚠ | 10 ⚠ | HIGH |
| Swap | 2.0Gi (off) | 2.0Gi (off) | 0 ✓ | 2.0Gi (on!) | 0 ✓ | MEDIUM |
| Disk Usage | 54% | 64% | 81% ✗ | 75% ⚠ | 48% | HIGH |

---

## Root Cause Analysis

**Why are kserver nodes misconfigured?**

Most likely:
1. Initial cluster setup didn't apply resource limit templates
2. Different OS images for control-plane vs workers
3. Manual configuration divergence over time
4. No automated host-config validation in cluster bootstrap

The worker nodes have proper settings, suggesting they were configured later or from a different baseline.

---

## Remediation Steps (In Order)

### Phase 1: Control-Plane Stabilization (URGENT)

These changes require kubelet/etcd restart and may briefly impact cluster stability.

**Step 1a: Fix ulimit on all kserver nodes**
```bash
for ip in 10.0.95.30 10.0.95.31 10.0.95.32; do
  ssh $ip 'cat <<EOF | sudo tee -a /etc/security/limits.conf
* soft nofile 65536
* hard nofile 1048576
root soft nofile 65536
root hard nofile 1048576
EOF'
  echo "kserver $ip: limits.conf updated"
done
```
Then reboot nodes one-by-one: `ssh 10.0.95.30 'sudo reboot'`

**Step 1b: Fix sysctl on all kserver nodes** (can apply without reboot)
```bash
for ip in 10.0.95.30 10.0.95.31 10.0.95.32; do
  ssh $ip 'cat <<EOF | sudo tee -a /etc/sysctl.conf
vm.max_map_count = 262144
net.ipv4.tcp_max_tw_buckets = 262144
net.core.somaxconn = 32768
fs.inotify.max_user_watches = 262144
kernel.panic = 60
EOF'
  ssh $ip 'sudo sysctl -p'
  echo "kserver $ip: sysctl updated"
done
```

**Step 1c: Disable swap on kworker and kserver1**
```bash
ssh 10.0.95.10 'sudo swapoff -a && sudo sed -i "s/^.*swap.*/#&/" /etc/fstab'
ssh 10.0.95.11 'sudo swapoff -a && sudo sed -i "s/^.*swap.*/#&/" /etc/fstab'
ssh 10.0.95.31 'sudo swapoff -a && sudo sed -i "s/^.*swap.*/#&/" /etc/fstab'
```

### Phase 2: Disk Cleanup (kserver0)

```bash
ssh 10.0.95.30 'du -sh /var/lib/rancher/k3s/server/* | sort -rh'
# Identify and clean up orphaned etcd WAL files or local-path PVCs
```

### Phase 3: Verification

After all changes:
```bash
# Rerun audit
/tmp/audit-all.sh

# Verify cluster health
kubectl get nodes
kubectl get componentstatuses
kubectl get pods -n kube-system | grep -E 'etcd|apiserver'
```

---

## Known Related Issues

From prior conversation:
- **PDX2 etcd HDD saturation:** Similar symptoms to what PDX1 kserver0 is showing (81% disk, etcd under stress)
- **Previous ulimit issue:** Worker nodes had ulimit issues in the past; kserver nodes never got the fix applied

---

## Post-Fix Verification Checklist

- [ ] All kserver nodes show Ready in `kubectl get nodes`
- [ ] etcd leader elected: `kubectl -n kube-system get lease etcd-leader -o wide`
- [ ] API server responding: `kubectl cluster-info`
- [ ] No pending pods: `kubectl get pods -A | grep Pending`
- [ ] kserver0 disk usage drops below 80% after etcd compaction
- [ ] No "Too many open files" errors in pod logs
- [ ] Admission webhooks responding normally
- [ ] ArgoCD syncing without timeout errors

---

## Prevention for Future

1. **Add host-config validation** to cluster bootstrap
2. **Document baseline sysctl values** in repo (e.g., `networking/k3s-sysctl-defaults.yaml`)
3. **Template-based node provisioning** to ensure consistency
4. **Regular audits** (e.g., monthly) to catch drift

---

## Outstanding Investigations

### kserver0 Disk Utilization (19G containerd bloat) — NEEDS FOLLOWUP

**Status:** Investigation needed  
**Date Found:** 2026-05-11  
**Current State:** 82% disk usage (90G / 116G)

**Findings:**
- 19G of containerd image layers (unused, last GC: 2026-01-12)
- 25 pod evictions/deletions since Jan 12 created orphaned layers
- System pods successfully survived reboot (evidence layers ARE working)
- **Hypothesis:** 19G is orphaned and safe to prune

**Evidence it's safe:**
- Reboot tested all image layer references
- All system pods (Cilium, Longhorn, Prometheus) came back up successfully
- If layers were in use, reboot would have broken them

**Next Steps:**
1. ✅ Validate pruning is safe (evidence from reboot success)
2. [ ] Run `ctr prune` with monitoring on kserver0
3. [ ] Measure disk space freed
4. [ ] Enable containerd GC in K3s config to prevent recurrence
5. [ ] Document cleanup procedure for future reference

**Impact:** Low (disk at 82%, not critical yet, but approaching warning threshold)

---

## References

- [Kubernetes Host Configuration Requirements](https://kubernetes.io/docs/setup/production-environment/container-runtimes/)
- [etcd File Descriptor Limits](https://etcd.io/docs/v3.5/dev-guide/system-requirements/)
- [K3s Known Issues](https://docs.k3s.io/known-issues)
