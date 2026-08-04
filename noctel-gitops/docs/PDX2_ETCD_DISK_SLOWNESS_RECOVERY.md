# PDX2 ETCD Disk Slowness Crisis & Recovery

## Executive Summary

The PDX2 Kubernetes cluster experienced cascading failures due to **HDD storage latency affecting the embedded ETCD database**. A single node restart exposed the underlying storage bottleneck, which triggered a split-brain scenario and ultimately forced a comprehensive recovery. This document explains the root cause, the cascade of failures, and how we recovered using ETCD tuning parameters.

---

## Part 1: The Root Cause

### The Problem: HDD Storage Latency

**Hardware Configuration:**
- Control planes (kserver0, kserver1, kserver2) use **HDD storage** (QEMU HARDDISK, ROTA=1)
- ETCD database is stored on local disk at `/var/lib/rancher/k3s/server/db/`
- No SSD cache or optimization layer

**Performance Impact:**
- **Expected latency with SSD:** 1-5ms per disk I/O operation
- **Actual latency with HDD:** 100-140ms per disk I/O operation
- **Amplification factor:** 20-140x slower

### Why ETCD is So Sensitive to Disk Latency

ETCD is a distributed consensus database that:
1. **Writes every API change to disk** (durability requirement)
2. **Syncs writes across cluster members** using the Raft consensus protocol
3. **Has strict timing requirements** for cluster stability:
   - **Election timeout:** Default 1000ms (time to detect a dead leader)
   - **Heartbeat interval:** Default 100ms (leader sends "I'm alive" messages)

With HDD latency at 100-140ms:
- Each disk write stalls the leader for 100-140ms
- Heartbeat messages get delayed
- Followers don't receive heartbeats on time
- Followers think the leader is dead → trigger new elections
- Elections fail → cluster becomes unstable

---

## Part 2: The Cascade of Failures

### Timeline of Failure

**Day 1 - Incident Trigger:**
- Restart one control plane (kserver0) for routine maintenance
- ETCD on that node struggles to reconnect due to disk latency
- Election timeout fires (leader unresponsive)
- Node drops out of cluster → 2-node ETCD cluster remaining

**Immediate Impact - API Slowdown (380ms → 4500ms):**
- API server querying ETCD for every request
- Single remaining ETCD leader overloaded
- All reads/writes go to one node
- Disk I/O bottleneck multiplies

**Secondary Failures:**
- CoreDNS can't list Namespaces → times out → restarts (2,346+ restarts)
- Traefik can't mount volumes → stuck in CrashLoopBackOff
- Controllers (rancher, elastic, fleet-agent) can't sync → high CPU, cascading restarts
- KubeAPIErrorBudgetBurn fired (API error rate exceeded threshold)

**Tertiary Failures:**
- Pod scheduling blocked (can't reach API)
- Worker nodes can't register (API timeouts)
- Kubelet can't post node status
- Cluster appears to be dying

### Why It Cascaded

```
HDD Latency (100-140ms)
    ↓
ETCD leader can't write fast enough
    ↓
Followers miss heartbeats
    ↓
Leader election triggered
    ↓
Election timeout fires
    ↓
Split-brain: cluster membership conflict
    ↓
Remaining nodes isolated or inconsistent
    ↓
API server can't reach ETCD reliably
    ↓
API becomes unreliable (500 errors, timeouts)
    ↓
Controllers start crashing
    ↓
Pods can't be scheduled
    ↓
Worker nodes isolated
    ↓
Cascading restarts across entire cluster
```

---

## Part 3: The Failed First Attempt

### What We Tried (and Why It Didn't Work)

**Attempt 1: ETCD Tuning with election-timeout=5000ms**

Initial approach: Increase the election timeout to tolerate disk latency longer.

**Configuration Applied:**
```yaml
etcd-arg:
  - "election-timeout=5000"    # 5 seconds - FAILED
  - "heartbeat-interval=500"   # 500ms
```

**Why This Failed:**
- ETCD has a constraint: `election-timeout must be ≥ 5 × heartbeat-interval`
- 5000ms / 500ms = 10x ✓ (valid ratio)
- **BUT:** When nodes restarted, one node (kserver0) elected itself as a 1-node cluster
- The timeout was so long that kserver0 removed kserver1 and kserver2 from membership
- Result: **Split-brain scenario with kserver0 isolated as a single-node cluster**

**Lesson:** Increasing election timeout too aggressively can cause cluster fragmentation.

---

## Part 4: The Real Fix

### Solution: Balanced ETCD Tuning

After fixing the split-brain by wiping kserver0's corrupted ETCD database and restarting the cluster, we applied **calibrated tuning** to match HDD latency characteristics:

**Final Configuration (Applied to all three control planes):**
```yaml
etcd-arg:
  - "auto-compaction-mode=periodic"
  - "auto-compaction-retention=5m"       # 3x more aggressive (15m → 5m)
  - "listen-metrics-urls=http://0.0.0.0:2381"
  - "election-timeout=2500"              # 2.5 seconds (5x heartbeat)
  - "heartbeat-interval=500"             # 500ms
  - "snapshot-count=10000"               # Trigger snapshots more frequently
```

### Why This Works

**1. Balanced Ratio (2500ms / 500ms = 5x)**
- Meets ETCD's minimum requirement (≥ 5x)
- Not so large that it causes cluster isolation
- Allows ~2.5 seconds of disk stalls before triggering election

**2. Aggressive Compaction (5m vs 15m)**
- WAL (write-ahead log) grows slower
- Reduces total data to persist
- Fewer disk I/O operations needed

**3. Frequent Snapshots (10k ops vs 100k)**
- Forces compaction cycles more often
- Keeps ETCD database size manageable
- Reduces disk I/O burst intensity

**4. Metrics Endpoint**
- Real-time visibility into ETCD performance
- Can monitor commit latency and catch issues early

### Results After Fix

**ETCD Performance:**
- **Disk commit latency distribution:**
  - < 64ms: 531,726 operations
  - < 128ms: 661,346 operations (98% of ops)
  - < 512ms: 701,419 operations (100% complete)

**API Performance:**
- **Before tuning:** 4500ms (cascading failures)
- **After tuning:** 395-475ms (stable)
- **Improvement:** 10x faster

**Cluster Stability:**
- No more cascading restarts
- Controllers stable
- Pods scheduling normally
- ETCD leader election stable

---

## Part 5: What the Fix Actually Does

### The Mechanism: Tolerating Disk Latency

```
Old (Broken) Timeline:
- Time 0ms: Leader wants to write data
- Time 100-140ms: Disk I/O completes
- Time 1000ms: Heartbeat deadline missed → Election fires

New (Working) Timeline:
- Time 0ms: Leader wants to write data
- Time 100-140ms: Disk I/O completes (≤ 500ms heartbeat interval ✓)
- Time 500ms: Send heartbeat (on time)
- Time 500ms: Receive heartbeat (on time)
- Time 2500ms: Election timeout (plenty of buffer)
```

**Key Insight:** The tuning parameters create breathing room for disk I/O without compromising cluster stability.

---

## Part 6: Architectural Limitations

### What This Fix Does NOT Do

This tuning is a **mitigation**, not a cure:

| Issue | Before | After | Status |
|-------|--------|-------|--------|
| Disk I/O latency | 100-140ms | 100-140ms | ❌ Unchanged |
| API responsiveness | 4500ms | 395ms | ✅ Mitigated |
| Cluster stability | Cascading failures | Stable | ✅ Mitigated |
| Pod scheduling | Blocked | Working | ✅ Mitigated |
| **Hardware limit** | HDD | HDD | ❌ **Not fixed** |

### The Real Solution: SSD Upgrade

The permanent fix requires:
1. **Replace HDD with NVMe SSD** on control plane nodes
2. Expected improvement: 1-5ms latency (vs current 100-140ms)
3. Would eliminate need for aggressive tuning
4. Would allow standard ETCD configurations (1000ms election timeout)

**Deadline:** This was targeted for 2026-03-29 (now passed)

---

## Part 7: Lessons Learned

### What We Learned

1. **ETCD tuning is a band-aid, not a solution**
   - Works in emergencies
   - But doesn't address root cause
   - Eventually hits hardware limits

2. **Disk latency cascades harder than network latency**
   - Network: affects individual requests
   - Disk: affects cluster consensus mechanism
   - Can destabilize entire cluster

3. **Split-brain is worse than downtime**
   - A dead cluster is obvious
   - A split-brain cluster silently corrupts state
   - Recovery requires data wipe and rebuild

4. **Monitoring is critical**
   - ETCD metrics endpoint (`:2381/metrics`) showed the problem early
   - Could have triggered SSD upgrade earlier
   - Visibility prevents cascades

### Monitoring to Add

For future protection, monitor:
```
- etcd_disk_backend_commit_duration_seconds (should be < 50ms)
- etcd_server_has_leader (should always be 1)
- etcd_mvcc_db_total_size_in_bytes (should be < 1GB)
- apiserver_request_duration_seconds (should be < 500ms p99)
```

---

## Part 8: Recovery Checklist

This is what we did to recover from the crisis:

- ✅ **Diagnosed:** Identified HDD latency as root cause
- ✅ **Isolated:** Removed kserver0's corrupted ETCD database
- ✅ **Tuned:** Applied balanced ETCD parameters (2500ms election, 500ms heartbeat, 5m compaction, 10k snapshots)
- ✅ **Restarted:** Rolled restart of kserver1, kserver2 with corrected config
- ✅ **Rejoined:** kserver0 synced fresh ETCD state from other nodes
- ✅ **Verified:** Workers re-registered, API responsive, prod stable
- ✅ **Monitored:** ETCD metrics show excellent performance under tuning

---

## Conclusion

The PDX2 cluster's crisis was not a software bug or misconfiguration—it was a **hardware limitation** (HDD latency) exposed by **increased load**. By tuning ETCD's timing parameters to accommodate the disk characteristics, we recovered stability and restored the cluster to production-ready state.

However, this is a **temporary solution**. The permanent fix is to upgrade to SSD storage, which would:
- Reduce disk latency from 100-140ms to 1-5ms
- Eliminate the need for aggressive tuning
- Allow standard Kubernetes configurations
- Improve API performance by another 10x

**Recommendation:** Schedule SSD upgrade for all control plane nodes as soon as possible to eliminate this architectural bottleneck.

---

## Appendix: ETCD Parameter Meanings

| Parameter | Default | Our Value | Purpose |
|-----------|---------|-----------|---------|
| `election-timeout` | 1000ms | 2500ms | Time before node assumes leader is dead |
| `heartbeat-interval` | 100ms | 500ms | Time between leader health checks |
| `auto-compaction-retention` | 15m | 5m | Keep only last 5 minutes of history |
| `snapshot-count` | 100000 | 10000 | Trigger compaction after this many ops |
| `listen-metrics-urls` | None | :2381 | Expose ETCD metrics for monitoring |

---

**Document created:** 2026-05-19  
**Cluster status:** Recovered, Stable, Production-Ready  
**Next action:** Plan SSD upgrade for permanent fix
