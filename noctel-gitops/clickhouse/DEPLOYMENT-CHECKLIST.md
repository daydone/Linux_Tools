# ClickHouse Deployment Checklist

## Pre-Deployment Setup (One-time)

### 1. Harbor Configuration
- [ ] Configure Harbor replication rule (see `HARBOR-REPLICATION-SETUP.md`)
  - [ ] Docker Hub → `pdx-harbor.telnoc.com/noctel/clickhouse`
  - [ ] Tag filter: `^(latest|[0-9]+\.[0-9]+\.[0-9]+)$`
  - [ ] Initial sync completes successfully
- [ ] Verify images are available: `pdx-harbor.telnoc.com/noctel/clickhouse/clickhouse-server:24.4.1`

### 2. S3 Backend Configuration
- [ ] S3 endpoint identified and accessible from K3S
  - [ ] MinIO cluster running? or AWS S3? or other?
  - [ ] Endpoint URL: `https://s3-endpoint`
  - [ ] Bucket created: `noctel-clickhouse-csrlog`
- [ ] S3 credentials obtained (access key, secret key)
- [ ] Test S3 connectivity from a K3S pod (if in doubt)

### 3. K3S Cluster Preparation
- [ ] Verify `harbor-pull` ImagePullSecret exists in cluster
  ```bash
  kubectl get secret harbor-pull -n default
  ```
- [ ] Longhorn storage class available
  ```bash
  kubectl get storageclass longhorn
  ```
- [ ] K3S cluster accessible and healthy
  ```bash
  kubectl cluster-info
  kubectl get nodes
  ```

### 4. Helm Chart Preparation
- [ ] Helm repositories added (if needed)
  ```bash
  helm repo add clickhouse https://charts.clickhouse.com
  helm repo update
  ```
- [ ] Validate Chart dependencies
  ```bash
  cd manifests/clickhouse
  helm dependency update
  ```

## Deployment Steps

### Phase 1: PDX1 Deployment

#### Step 1: Create S3 Credentials Secret
```bash
kubectl create namespace clickhouse

kubectl -n clickhouse create secret generic clickhouse-s3-credentials \
  --from-literal=access_key_id=<S3_ACCESS_KEY> \
  --from-literal=secret_access_key=<S3_SECRET_KEY>
```

**Verification:**
```bash
kubectl -n clickhouse get secret clickhouse-s3-credentials
```

#### Step 2: Apply ArgoCD Application
```bash
kubectl apply -f argocd-applications/pdx1/infrastructure/pdx1-clickhouse.yaml
```

**Verification:**
```bash
kubectl get application clickhouse-pdx1 -n argocd
argocd app wait clickhouse-pdx1  # Wait for sync to complete
```

#### Step 3: Verify Deployment
```bash
# Check StatefulSet
kubectl -n clickhouse get statefulset

# Check PVC (should show Longhorn)
kubectl -n clickhouse get pvc
kubectl -n clickhouse describe pvc clickhouse-clickhouse

# Check pod is running
kubectl -n clickhouse get pods
kubectl -n clickhouse logs clickhouse-clickhouse-0 -f  # Follow logs

# Check service
kubectl -n clickhouse get svc
```

#### Step 4: Verify ClickHouse Connectivity
```bash
# Access ClickHouse CLI
kubectl -n clickhouse exec -it clickhouse-clickhouse-0 -- clickhouse-client

# Or run query directly
kubectl -n clickhouse exec clickhouse-clickhouse-0 -- \
  clickhouse-client -q "SELECT 1"
```

### Phase 2: Data Ingestion Setup

#### Step 1: Identify SIP Log Source
- [ ] Confirm SIP log source (Joey's system)
- [ ] Confirm data format (JSON/CSV/syslog/binary?)
- [ ] Confirm delivery method (HTTP API/Kafka/socket/direct insert?)

#### Step 2: Create ClickHouse Database & Tables
```bash
kubectl -n clickhouse exec clickhouse-clickhouse-0 -- clickhouse-client -q "
CREATE DATABASE IF NOT EXISTS sip_logs;

CREATE TABLE IF NOT EXISTS sip_logs.sip_packets (
  timestamp DateTime,
  source_ip String,
  dest_ip String,
  source_port UInt16,
  dest_port UInt16,
  sip_method String,
  call_id String,
  from_user String,
  to_user String,
  cseq String,
  user_agent String,
  raw_packet String,
  site_id String
) ENGINE = MergeTree()
ORDER BY (timestamp, source_ip, site_id)
PARTITION BY toYYYYMMDD(timestamp)
SETTINGS storage_policy = 'tiered';
"
```

#### Step 3: Test Data Insert
```bash
kubectl -n clickhouse exec clickhouse-clickhouse-0 -- clickhouse-client -q "
INSERT INTO sip_logs.sip_packets VALUES
(now(), '10.0.1.1', '10.0.1.2', 5060, 5060, 'INVITE', 'call-123@pdx', 'alice', 'bob', '1 INVITE', 'SIP/2.0', 'test', 'pdx22')
"

# Verify insert
kubectl -n clickhouse exec clickhouse-clickhouse-0 -- clickhouse-client -q "
SELECT COUNT(*) FROM sip_logs.sip_packets;
SELECT * FROM sip_logs.sip_packets;
"
```

### Phase 3: Storage Tiering Validation

#### Step 1: Monitor Storage (12-24 hours later)
```bash
# Check disk usage
kubectl -n clickhouse exec clickhouse-clickhouse-0 -- du -sh /var/lib/clickhouse/store/

# Check S3 objects (if S3 configured correctly, objects should appear after 24hrs)
# Use your S3 client to list: noctel-clickhouse-csrlog/sip_logs/
```

#### Step 2: Query Performance Testing
```bash
# Hot data query (should be <100ms)
kubectl -n clickhouse exec clickhouse-clickhouse-0 -- clickhouse-client -q "
SELECT timestamp, source_ip, dest_ip, sip_method 
FROM sip_logs.sip_packets 
WHERE timestamp > now() - INTERVAL 1 HOUR
LIMIT 10;
"

# Cold data query (after 24hrs, should be 1-5s depending on S3 latency)
kubectl -n clickhouse exec clickhouse-clickhouse-0 -- clickhouse-client -q "
SELECT timestamp, source_ip, dest_ip, sip_method 
FROM sip_logs.sip_packets 
WHERE timestamp < now() - INTERVAL 2 DAYS
LIMIT 10;
"
```

## Post-Deployment Validation Checklist

### Service Availability
- [ ] ClickHouse pod running: `kubectl -n clickhouse get pods`
- [ ] Longhorn PVC bound and mounted
- [ ] Service accessible internally: `kubectl -n clickhouse get svc`
- [ ] Basic queries work: `SELECT 1`

### Storage
- [ ] Database/table created successfully
- [ ] Sample data inserted without errors
- [ ] Longhorn disk usage reasonable (~50-80GB for 24hrs data)
- [ ] S3 replication configured and working (verify after 24hrs)

### Performance
- [ ] Hot queries <100ms
- [ ] No CPU/memory throttling
- [ ] Compression ratio achieved (check `system.tables`)

### Monitoring
- [ ] Prometheus scrape target configured (if ServiceMonitor enabled)
- [ ] Grafana dashboard showing metrics
- [ ] Alerts configured for:
  - [ ] Pod restarts
  - [ ] Storage approaching limit
  - [ ] Query errors

## Troubleshooting

### Pod won't start
```bash
# Check pod events
kubectl -n clickhouse describe pod clickhouse-clickhouse-0

# Check container logs
kubectl -n clickhouse logs clickhouse-clickhouse-0 -p  # Previous logs
kubectl -n clickhouse logs clickhouse-clickhouse-0      # Current logs
```

### PVC not binding
```bash
# Check PVC status
kubectl -n clickhouse describe pvc clickhouse-clickhouse

# Check Longhorn availability
kubectl get storageclass longhorn
```

### S3 connectivity issues
```bash
# Verify secret exists
kubectl -n clickhouse get secret clickhouse-s3-credentials

# Check environment variables in pod
kubectl -n clickhouse exec clickhouse-clickhouse-0 -- env | grep S3
```

### Performance issues
```bash
# Check system tables
kubectl -n clickhouse exec clickhouse-clickhouse-0 -- clickhouse-client -q "
SELECT table, bytes, part_count FROM system.tables WHERE database='sip_logs';
"

# Check parts
kubectl -n clickhouse exec clickhouse-clickhouse-0 -- clickhouse-client -q "
SELECT table, partition, sum(bytes) FROM system.parts WHERE database='sip_logs' GROUP BY table, partition;
"
```

## Rollback Plan

If deployment fails:

1. **Delete ArgoCD Application:**
   ```bash
   kubectl delete application clickhouse-pdx1 -n argocd
   ```

2. **Clean up namespace:**
   ```bash
   kubectl delete namespace clickhouse
   ```

3. **Investigate and fix:**
   - Review error logs
   - Update values files in `environments/pdx1/`
   - Verify S3 and Harbor configuration

4. **Re-deploy:**
   - Reapply ArgoCD Application
   - Follow deployment steps above

## Success Criteria for Phase 1 Completion

- [x] ClickHouse pod running in pdx1-clickhouse namespace
- [x] Longhorn PVC successfully bound (100GB)
- [x] S3 connectivity working (secrets configured)
- [x] Database and tables created
- [x] Sample data inserted and queryable
- [x] Storage tiering working (data moves to S3 after 24hrs)
- [x] Compression ratio verified (8-12x for logs)
- [x] Monitoring/alerting configured
- [x] Runbooks and documentation updated

Once all criteria met → Phase 2 (PDX2 replication + ZooKeeper)
