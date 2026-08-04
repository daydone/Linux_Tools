# ClickHouse for CSR SIP Packet Logging

## Overview

This directory contains the complete ClickHouse deployment configuration for CSR SIP packet logging, a backend research infrastructure supporting troubleshooting and analysis.

**Service tier:** Non-critical research (downtime acceptable)  
**Initial scope:** PDX1 K3S cluster only (Phase 2: PDX2 replication via ZooKeeper)  
**Data retention:** 10 days (12-24hrs hot in Longhorn, rest in S3 cold storage)  
**Expected data volume:** 15-20GB/day raw → 1.5-2.5GB/day compressed

---

## Directory Structure

```
clickhouse/
├── README.md                          # This file
├── HARBOR-REPLICATION-SETUP.md        # How to configure Harbor image replication
├── DEPLOYMENT-CHECKLIST.md            # Step-by-step deployment and validation guide
├── Chart.lock                         # Helm chart lock file (auto-generated)

manifests/clickhouse/
├── Chart.yaml                         # Helm chart definition (wraps official ClickHouse chart)
├── Chart.lock                         # Dependency lock file
└── values.yaml                        # Base Helm values (image, resources, storage)

environments/
├── pdx1/pdx1-clickhouse-config.yaml  # PDX1-specific values (S3 tiering, resources)
└── pdx2/pdx2-clickhouse-config.yaml  # PDX2-specific values (for Phase 2 replication)

argocd-applications/
├── pdx1/infrastructure/
│   └── pdx1-clickhouse.yaml           # ArgoCD Application (active for Phase 1)
└── pdx2/infrastructure/
    └── pdx2-clickhouse.yaml           # ArgoCD Application (template for Phase 2)
```

---

## Quick Start

### 1. Configure Harbor Image Replication

**See:** `HARBOR-REPLICATION-SETUP.md`

Set up Harbor to replicate Docker Hub's `clickhouse/clickhouse-server` to `pdx-harbor.telnoc.com/noctel/clickhouse/clickhouse-server`

```
Harbor UI → Administration → Registries → Replication Rules
Rule Name: clickhouse-docker-to-noctel
Source: Docker Hub (clickhouse namespace)
Destination: Local (noctel/clickhouse)
Filter: clickhouse-server, latest + semantic versions
```

### 2. Prepare S3 Backend

- Identify S3 endpoint (MinIO, AWS, or other)
- Create bucket: `noctel-clickhouse-csrlog`
- Obtain access credentials (key, secret)

### 3. Deploy to PDX1

```bash
# Update S3 credentials in pdx1-clickhouse-config.yaml
# Then apply ArgoCD Application:
kubectl apply -f argocd-applications/pdx1/infrastructure/pdx1-clickhouse.yaml

# Monitor deployment
argocd app wait clickhouse-pdx1
kubectl -n clickhouse get all
```

**See:** `DEPLOYMENT-CHECKLIST.md` for detailed steps and validation

---

## Architecture

### Storage Tiering

```
SIP Logs Ingestion
       ↓
  ClickHouse Pod (K3S StatefulSet)
       ↓
   ┌───┴───┐
   ↓       ↓
Longhorn   S3
(hot)      (cold)
12-24hrs   9-10 days
```

**Hot tier (Longhorn):**
- 100GB PVC mounted at `/var/lib/clickhouse`
- Data kept for 12-24 hours
- Fast queries (<100ms)

**Cold tier (S3):**
- Automatic move via ClickHouse storage policy after 24 hours
- Remaining 9-10 days of 10-day retention
- Cost-effective long-term storage
- Slower queries (1-5s, S3 latency)

### Replication Topology

**Phase 1 (Current):**
- Single ClickHouse instance on pdx1
- No replication
- Disaster recovery via S3 immutable archive

**Phase 2 (Future):**
- ClickHouse replicas on pdx1 and pdx2
- ZooKeeper coordination (3 nodes)
- Both clusters share S3 cold storage
- Active-passive failover capability

---

## Key Files

| File | Purpose |
|------|---------|
| `HARBOR-REPLICATION-SETUP.md` | Instructions for Harbor image replication rule |
| `DEPLOYMENT-CHECKLIST.md` | Step-by-step deployment guide with validation |
| `manifests/clickhouse/Chart.yaml` | Helm chart wrapper (references official ClickHouse chart v5.1.0) |
| `environments/pdx1/pdx1-clickhouse-config.yaml` | PDX1 values (S3, resources, storage policy) |
| `environments/pdx2/pdx2-clickhouse-config.yaml` | PDX2 values (for Phase 2, includes ZooKeeper config) |
| `argocd-applications/pdx1/infrastructure/pdx1-clickhouse.yaml` | Active ArgoCD Application for Phase 1 |
| `argocd-applications/pdx2/infrastructure/pdx2-clickhouse.yaml` | Template for Phase 2 deployment |

---

## Configuration Details

### Image Configuration

**Image source:** `pdx-harbor.telnoc.com/noctel/clickhouse/clickhouse-server:24.4.1`
- Harbor replicates from Docker Hub: `docker.io/clickhouse/clickhouse-server`
- ImagePullSecret: `harbor-pull` (already exists in K3S)
- Updates replicated automatically via Harbor rules

### Storage Configuration (PDX1)

```yaml
Longhorn:
  Size: 100Gi
  StorageClass: longhorn
  Mount: /var/lib/clickhouse

S3:
  Endpoint: https://s3-endpoint/noctel-clickhouse-csrlog/
  Credentials: clickhouse-s3-credentials (K3S Secret)
  Tiering: Auto-move to S3 after 24 hours via storage policy
```

### Resource Requests/Limits (PDX1)

```yaml
Requests:
  Memory: 4Gi
  CPU: 2000m

Limits:
  Memory: 12Gi
  CPU: 6000m
```

Can be adjusted based on actual SIP log volume after Phase 1 validation.

---

## Deployment Process

### Phase 1: PDX1 Single-Node Deployment

1. **Harbor Setup** (one-time)
   - Configure replication rule (see `HARBOR-REPLICATION-SETUP.md`)
   - Wait for initial sync to complete

2. **S3 Preparation** (one-time)
   - Identify/create S3 bucket
   - Obtain credentials

3. **Helm Chart Update** (one-time)
   ```bash
   cd manifests/clickhouse && helm dependency update
   ```

4. **K3S Deployment** (one-time)
   ```bash
   kubectl apply -f argocd-applications/pdx1/infrastructure/pdx1-clickhouse.yaml
   ```

5. **Validation** (recurring)
   - Follow `DEPLOYMENT-CHECKLIST.md`
   - Verify pod running, PVC bound, S3 connectivity
   - Insert test data, run queries

6. **Data Ingestion Setup**
   - Identify SIP log source
   - Create tables
   - Connect ingestion pipeline

### Phase 2: PDX2 Replication (Future)

See `environments/pdx2/pdx2-clickhouse-config.yaml` and `DEPLOYMENT-CHECKLIST.md` Phase 2 section for:
- ZooKeeper cluster deployment
- ReplicatedMergeTree table engine
- Failover testing
- Cross-cluster query setup

---

## Troubleshooting

**Pod won't start?**
```bash
kubectl -n clickhouse describe pod clickhouse-clickhouse-0
kubectl -n clickhouse logs clickhouse-clickhouse-0
```

**PVC not binding?**
```bash
kubectl get storageclass longhorn
kubectl -n clickhouse describe pvc clickhouse-clickhouse
```

**S3 issues?**
```bash
kubectl -n clickhouse get secret clickhouse-s3-credentials
kubectl -n clickhouse exec clickhouse-clickhouse-0 -- env | grep S3
```

See `DEPLOYMENT-CHECKLIST.md` troubleshooting section for more.

---

## Backup & Recovery

**Backup strategy (Tier 2):**
- **Hot data:** Longhorn snapshots (handled by K3S backup strategy)
- **Cold data:** Native to S3 (immutable once archived)
- **Schedule:** Daily (non-critical research data)
- **Retention:** 30 days hot, 3 months cold (per backup plan)

**Recovery:**
- Point-in-time from S3 snapshots
- Full database restore via Longhorn snapshot + S3 archive
- RTO: 1-2 hours, RPO: <24 hours

---

## Monitoring & Observability

**Prometheus metrics** (if enabled):
- Pod metrics via `ServiceMonitor`
- ClickHouse system tables (CPU, memory, queries)
- Storage usage (Longhorn + S3)

**Logs:**
- Pod logs: `kubectl -n clickhouse logs -f statefulset/clickhouse`
- ClickHouse logs: `/var/log/clickhouse-server/` (inside pod)

**Alerts** (to configure):
- Pod restart frequency
- Storage approaching limit
- Query errors
- Replication lag (Phase 2)

---

## Contacts & Resources

**ClickHouse Documentation:** https://clickhouse.com/docs  
**Helm Chart:** https://charts.clickhouse.com  
**Longhorn Storage:** https://longhorn.io/docs/  

**Project Documentation:**
- `/Users/finbar.day/claude/clickhouse/CLICKHOUSE-DEPLOYMENT.md` (architecture overview)
- `/Users/finbar.day/claude/clickhouse/CLAUDE.md` (quick reference for Claude Code)

---

## Timeline & Ownership

**Phase 1 (PDX1 single-node):** 1-2 weeks
- Harbor replication: 1 day
- Deployment & validation: 3-5 days
- Data ingestion setup: 2-3 days

**Phase 2 (PDX2 replication):** 2-3 weeks (after Phase 1 stable)
- ZooKeeper deployment: 2-3 days
- Replication setup: 3-5 days
- Failover testing: 2-3 days

---

**Last updated:** 2026-06-08  
**Created by:** Claude Code  
**Status:** Ready for Phase 1 deployment
