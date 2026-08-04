# NT7 Infrastructure Platform: Complete Systems Audit
**Date:** 2026-07-14  
**Scope:** PVE/Ceph/Patroni/K3s Platform Status & Production Readiness  
**Current Status:** OPERATIONAL for workloads, but NOT production-grade HA

---

## Executive Summary

| Component | Status | Score | Verdict |
|-----------|--------|-------|---------|
| **PVE Compute** | 🟢 Operational | 85% | Ready for production |
| **Ceph Storage** | 🟡 Degraded | 70% | Monitor, 1 mon down (pve1) |
| **Patroni PostgreSQL** | 🔴 At Risk | 40% | CRITICAL SPOF - all on pve3 |
| **K3s Control Plane** | 🟢 Healthy | 90% | Recovered, stable |
| **K3s Networking** | 🟢 Healthy | 90% | Cilium working, DNS fixed |
| **Disaster Recovery** | 🔴 Missing | 0% | No backups, untested restore |
| **Monitoring** | 🟡 Partial | 60% | Running but incomplete |
| **High Availability** | 🟡 Partial | 50% | Some systems HA, PostgreSQL SPOF |
| **OVERALL PLATFORM** | 🟡 OPERATIONAL | 62% | Working but not production-grade for HA workloads |

**Production Readiness:** 🔴 NOT READY FOR HA WORKLOADS  
**Timeline to Ready:** 5-8 weeks  
**Critical Blockers:** 4 (PostgreSQL SPOF, DR system, untested failover, backup system)

---

## TIER 0: CRITICAL BLOCKERS

### 1. 🔴 PostgreSQL SPOF (All on pve3)
**Risk:** All 6 PostgreSQL nodes on single PVE hypervisor  
**Impact:** pve3 failure → total database loss for Chirpstack (all gateways/devices) + provisioning  
**Current:** pdx-chirpdb1/2 nodes 0,1,2 all on pve3 shared storage  
**Fix:** Migrate to distributed nodes (pve1/pve2/pve4) - 4-6 hours  
**Requires:** Maintenance window (Patroni failover during migration)  
**Status:** ❌ NOT FIXED (same issue since June 2 audit)

---

### 2. 🔴 No Disaster Recovery System
**Risk:** No off-cluster backups for any critical system  
**Impact:** Cluster-wide failure = unrecoverable (catastrophic)  
**Missing:** 
- [ ] PostgreSQL PITR to S3 (8-10h to implement + test)
- [ ] Galera backup to S3 (6-8h)
- [ ] SeaweedFS backup to S3 (8-12h)
- [ ] K3s etcd snapshots to S3 (2-3h)
- [ ] TrueNAS snapshots to S3 (4-6h)
- [ ] Tested restore procedures for each (included above)
- [ ] RTO/RPO targets defined (2h)
- [ ] Disaster recovery runbook (4-8h)

**Current State:** ❌ No backup system exists  
**Fix Effort:** 25-35 hours total  
**Timeline:** 3-5 weeks (sequential testing)  
**Status:** ❌ NOT STARTED

### 3. 🟠 Ceph Monitor Down (pve1)
**Risk:** 1/4 monitors down, one failure away from quorum loss  
**Current State:** `HEALTH_WARN: 1/4 mons down, quorum pdx-pve2,pdx-pve3,pdx-pve4`  
**Impact:** Degraded performance, potential split-brain if another mon fails  
**Fix:** Restart/repair mon on pve1 - 1-2 hours  
**Status:** ⏳ NEEDS ATTENTION (do this week)

### 4. 🔴 Untested Failure Scenarios  
**Risk:** Can't predict system behavior during failures  
**Unknown:** RabbitMQ message persistence, SeaweedFS replication, PostgreSQL failover behavior, TrueNAS mirror status  
**Impact:** Changes might break hidden resilience mechanisms  
**Fix:** Audit + test each system (15-20 hours)  
**Status:** ❌ NOT TESTED

---

### 5. 🔴 SeaweedFS Stability Unknown
**Status:** CRITICAL — Similar to RabbitMQ  
**Impact:** 12TB+ file storage — data loss risk unknown
- **Problem:** 2,400+ crashes yet files aren't lost (how?)
- **Risk:** Don't know what to change without breaking failover

**Unknown Factors:**
- [ ] Replication strategy (RAID-like vs erasure coding)
- [ ] Crash recovery procedure
- [ ] Data loss scenarios + recovery from backup
- [ ] Master node failover behavior

**Fix Required:**
- Audit SeaweedFS configuration + storage topology
- Test failure scenarios (node down, volume failure)
- Verify backup/restore capability
- **Estimated effort:** 8-12 hours

**Block Status:** ❌ NOT STARTED

---

## TIER 1: SEVERE ISSUES (Should Fix Before Production)

### 6. 🟠 CrashLoopBackOff Services in NT7
**Status:** ACTIVE — Blocking deployment in dev/qa

| Service | Namespace | Restarts | Status | Root Cause |
|---------|-----------|----------|--------|------------|
| chirpstack-core | dev, qa | 11,468 (dev) | CRASH | Unknown config/dependency |
| noctel-api-fma | dev, qa, prod | ⏳ TBD | ⏳ TO FIX | Task #13 |
| noctel-api-numbers | prod | ⏳ TBD | ⏳ TO FIX | Task #14 |
| noctel-api-wireguard | prod | 220+ | ⏳ TO FIX | Task #15 |

**Block Status:** 🔴 3-4 services undeployable

---

### 7. 🟠 RabbitMQ Extract-Credentials Jobs Failing
**Status:** ONGOING — Affects cert renewal
- **Impact:** RabbitMQ credentials might not refresh, auth might fail
- **Current:** Job crashes with exit code 1, no error logs captured
- **Fix:** Task #19 — investigate and fix job container

**Block Status:** ⏳ IN QUEUE

---

### 8. 🟠 Image Pull Failures
**Status:** 4+ services failing to pull images
- noctel-desk (dev): ImagePullBackOff
- otel-collector (monitoring): 6 replicas ImagePullBackOff
- rmq-dex-rabbitmq (dex): Init:ImagePullBackOff

**Impact:** Services not running = no monitoring, no dex auth

**Block Status:** ⏳ IN QUEUE

---

### 9. 🟠 Alert System Status Unknown
**Status:** UNVERIFIED — 5,000 restarts generated 0 pages
- **Risk:** Are alerts even working?
- **Testing needed:** Send test alert, verify page arrives

**Block Status:** ⏳ NOT TESTED

---

## TIER 2: OPERATIONAL ISSUES (Should Fix Early)

### 10. 🟡 Missing Resource Limits
**Status:** 15+ deployments without memory limits  
**Impact:** Single pod OOMKill → cascade failure
- **Scope:** Multiple noctel-api-* services
- **Task:** #30 — Add resource limits
- **Effort:** 2-3 hours

**Block Status:** ⏳ IN QUEUE

---

### 11. 🟡 Pod Distribution Imbalance
**Status:** 62/38 split across worker nodes (PDX1)  
**Impact:** Node failure = 62% workload lost
- **Task:** #4 — Fix via pod anti-affinity
- **Status:** Partially done (ArgoCD apps have ignoreDifferences set)

**Block Status:** ⏳ PARTIAL

---

### 12. 🟡 TrueNAS HA Status Unknown
**Status:** Not verified whether replicated or SPOF  
**Impact:** Storage loss if primary fails
- **Check needed:** Are pdx-truenas0/1 mirrored?
- **Effort:** 1 hour

**Block Status:** ❓ NOT CHECKED

---

### 13. 🟡 Monitoring Stack Not Fully HA
**Status:** Some components are single replica
- Prometheus: Need 2+ replicas (depends on Thanos setup)
- Grafana: 1 replica (should be ≥2)
- Alertmanager: 3 replicas (✅ OK)

**Block Status:** ⏳ PARTIAL

---

## TIER 3: INFRASTRUCTURE QUALITY (Nice to Have)

### 14. 🟢 Backups Not Documented
- [ ] RTO/RPO targets undefined
- [ ] Backup retention policy undefined
- [ ] Recovery procedure not documented

### 15. 🟢 IPMI/Console Access Not Verified
- [ ] Can access all PVE nodes via IPMI
- [ ] Tested rescue mode boot

### 16. 🟢 Security Hardening Incomplete
- [ ] RBAC audit (remove cluster-admin for individuals)
- [ ] Secret rotation procedure missing
- [ ] Network policies incomplete for all namespaces

### 17. 🟢 Capacity Planning Missing
- [ ] No load testing baseline
- [ ] Unknown system limits
- [ ] Storage growth trending not captured

---

## Infrastructure Components Status

### Kubernetes (PDX1 & PDX2)

| Component | PDX1 | PDX2 | Status |
|-----------|------|------|--------|
| **Control Plane** | 5 kservers Ready | 3 kservers Ready | ✅ Healthy |
| **Networking (Cilium)** | 6 pods Ready | 5 pods Ready | ✅ Healthy |
| **DNS (CoreDNS)** | 2 pods Ready | 1 pod Ready | ✅ Working (recently fixed) |
| **ETCD** | 5/5 healthy | 3/3 healthy | ✅ Recovered from crash |
| **Storage (Ceph)** | HEALTH_OK, 24 OSDs | Part of PDX1 | ✅ OK |
| **API Server** | /livez OK | /livez OK | ✅ Responsive |

**Status:** ✅ Infrastructure layer is healthy post-recovery

---

### Databases

| Database | Status | Location | HA Setup | Tested |
|----------|--------|----------|----------|--------|
| **PostgreSQL (Patroni)** | 🔴 SPOF | pve3 only | ❌ No | ❌ No |
| **Galera (MySQL)** | ✅ HA | pve1,2,3,4 | ✅ Yes | ⏳ Partial |
| **RabbitMQ** | ⚠️ Untested | K3s (prod) | ❓ Unknown | ❌ No |
| **SeaweedFS** | ⚠️ Untested | K3s (prod) | ❓ Unknown | ❌ No |
| **TrueNAS** | ❓ Untested | pdx-truenas0/1 | ❓ Unknown | ❌ No |

**Status:** Databases exist but resilience unproven

---

### Network Infrastructure

| Network | VLAN | Status | Notes |
|---------|------|--------|-------|
| Proxmox (PVE) | 682 | ✅ OK | Ceph + PVE mgmt |
| Ceph Storage | 650 | ✅ OK | Backend network |
| Patroni/PostgreSQL | 675 | ✅ OK | Isolated (expected) |
| K3s Applications | 679 | ✅ OK | Pod network via Cilium |
| External egress | varies | ✅ OK | DNS fixed 2026-07-07 |

**Status:** ✅ Network connectivity restored

---

## Application Deployment Status

### Core NT7 Services

| Service | Dev | QA | Prod | Status |
|---------|-----|----|----|--------|
| **noctel-api-gateway** | ⏳ | ⏳ | ✅ 3/3 | Deployed |
| **noctel-api-realtime** | ⏳ | ⏳ | ✅ 3/3 | Deployed |
| **noctel-api-numbers** | 🔴 CRASH | 🔴 CRASH | 0/1 | Task #14 |
| **noctel-api-wireguard** | 🔴 CRASH | 🔴 CRASH | 0/3 | Task #15 |
| **noctel-api-fma** | 🔴 CRASH | 🔴 CRASH | 0/1 | Task #13 |
| **noctel-display** | ⏳ | ⏳ | ✅ 1/1 | Recently fixed |
| **noctel-desk** | 0/1 | ⏳ | 0/1 | ImagePullBackOff |

**Blocking:** 3 services can't run (task #13, #14, #15)

---

### Supporting Services

| Service | Dev | QA | Prod | Status |
|---------|-----|----|----|--------|
| **RabbitMQ** | ⏳ | ⏳ | ✅ HA | 4,341 restarts, untested |
| **Chirpstack** | 🔴 CRASH | 🔴 CRASH | ⏳ | 11,468 restarts (dev) |
| **Elasticsearch** | ⚠️ broken | ⏳ | ✅ | Dex ES missing |
| **Loki** | ⏳ | ⏳ | ⏳ | ContainerCreating |
| **Tempo** | ⏳ | ⏳ | ⏳ | Datasource issues |

**Blocking:** Observability incomplete, Chirpstack broken in dev/qa

---

## What Needs To Happen Before NT7 Production

### Phase A: Critical Infrastructure Fixes (Must Do)
**Estimated Effort:** 15-20 hours  
**Timeline:** 2-3 weeks

- [ ] **PostgreSQL SPOF** (4-6h) — Migrate to HA distribution
  - Move chirpdb1/2 from pve3 to pve2/pve4
  - Test Patroni failover
  
- [ ] **Backup System** (8-12h) — Implement off-cluster backups
  - S3 buckets for all databases + K3s
  - Tested restore procedures
  - RTO/RPO targets documented
  
- [ ] **RabbitMQ Audit** (3-4h) — Understand stability mechanism
  - ConfigMap review
  - Message loss risk assessment
  - Restart recovery testing

- [ ] **SeaweedFS Audit** (4-6h) — Understand failure behavior
  - Replication strategy verification
  - Crash recovery testing
  - Data loss scenario testing

### Phase B: Application Fixes (Must Do)
**Estimated Effort:** 8-12 hours  
**Timeline:** 1-2 weeks

- [ ] **Fix CrashLoopBackOff Services** (6-8h)
  - noctel-api-fma (Task #13)
  - noctel-api-numbers (Task #14)
  - noctel-api-wireguard (Task #15)
  - chirpstack-core (dev/qa only)

- [ ] **Fix Image Pull Issues** (2-3h)
  - noctel-desk (dev)
  - otel-collector monitoring
  - rmq-dex-rabbitmq

- [ ] **Verify Alert System** (1h)
  - Send test alert
  - Confirm notification reaches on-call

### Phase C: Production Readiness (Should Do)
**Estimated Effort:** 10-15 hours  
**Timeline:** 1-2 weeks

- [ ] **Add Resource Limits** (Task #30, 2-3h)
- [ ] **Verify Pod Distribution** (1-2h)
- [ ] **Monitoring Stack HA** (2-3h)
- [ ] **TrueNAS HA Verification** (1h)
- [ ] **Runbook Documentation** (2-4h)

---

## Sequencing & Blockers

```
BLOCKED UNTIL:
  ├─ Phase A Tasks (Critical)
  │  ├─ PostgreSQL SPOF fixed (4-6h)
  │  │  └─ Database failover tested
  │  ├─ Backups operational (8-12h)
  │  │  └─ Restore tested for each system
  │  ├─ RabbitMQ behavior understood (3-4h)
  │  └─ SeaweedFS behavior understood (4-6h)
  │
  └─ Phase B Tasks (Application)
     ├─ All CrashLoopBackOff fixed (6-8h)
     ├─ All ImagePullBackOff fixed (2-3h)
     └─ Alert system verified (1h)

THEN: NT7 Production Ready ✅
```

---

## Deployment Readiness Checklist

- [ ] All control plane components healthy
- [ ] All worker nodes healthy
- [ ] All databases HA with tested failover
- [ ] All backups operational with tested restore
- [ ] No CrashLoopBackOff services in prod
- [ ] No ImagePullBackOff services in prod
- [ ] Alert system verified working
- [ ] DNS resolution working (internal + external)
- [ ] Resource limits applied to all services
- [ ] Pod distribution balanced
- [ ] RTO/RPO targets documented
- [ ] Disaster recovery runbook written
- [ ] On-call team trained on runbook
- [ ] Baseline metrics captured for comparison
- [ ] Load testing completed (optional but recommended)

**Current Score:** 6/15 (40%)  
**Estimated Completion:** 4-6 weeks of work

---

## Risk Matrix

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|-----------|
| PostgreSQL data loss | HIGH (SPOF) | CATASTROPHIC | Fix SPOF now (Phase A) |
| Message loss via RabbitMQ | MEDIUM (unknown) | SEVERE | Audit + testing (Phase A) |
| File loss via SeaweedFS | MEDIUM (unknown) | SEVERE | Audit + testing (Phase A) |
| Unrecoverable failure | HIGH (no DR) | CATASTROPHIC | Implement backups (Phase A) |
| Services crash on deploy | HIGH (known issues) | SEVERE | Fix CrashLoopBackOff (Phase B) |
| Silent alert failures | MEDIUM (untested) | SEVERE | Verify + test (Phase B) |
| Pod cascade failure | MEDIUM (imbalance) | SEVERE | Fix distribution (Phase C) |

---

## Recommendations

### 1. DO NOT deploy NT7 to production until TIER 0 items fixed
- PostgreSQL HA migration (4-6h)
- Backup system operational (8-12h)
- CrashLoopBackOff services fixed (6-8h)
- Alert system verified (1h)

### 2. Sequence work as Phase A → Phase B → Phase C
- A fixes infrastructure (most critical)
- B fixes applications (blocks deployment)
- C makes production-grade (operational excellence)

### 3. Testing strategy
- Phase A: Test in staging before production
- Phase B: Fix dev/qa first, then prod
- Phase C: Can do in parallel with A/B

### 4. Timeline estimate
- Phase A: 2-3 weeks (infrastructure changes are slow, need testing)
- Phase B: 1-2 weeks (application fixes are quick)
- Phase C: 1-2 weeks (can overlap with A/B)
- **Total: 4-6 weeks before production-ready**

### 5. Immediate next steps
1. Schedule PostgreSQL migration (requires maintenance window)
2. Start backup system implementation
3. Begin CrashLoopBackOff debugging (parallel with infrastructure work)
4. Set up staging environment for testing (Phase A items)

---

## Audit Trail

- **2026-06-02:** Infrastructure project status created (50-60% complete)
- **2026-07-07:** CoreDNS external DNS fixed
- **2026-07-07:** PDX2 ETCD cluster recovered from vCenter crash
- **2026-07-14:** This audit created — NT7 production readiness assessment

**Status:** Platform requires 4-6 weeks of infrastructure + application fixes before NT7 can be deployed to production.
