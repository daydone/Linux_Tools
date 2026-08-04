# KeyDB Multi-Master Deployment

This document describes the KeyDB multi-master deployment for cross-cluster active-active replication.

## Overview

KeyDB is deployed as a multi-master distributed key-value store with active-active replication. Each cluster runs its own KeyDB StatefulSet, and nodes replicate bidirectionally across clusters for high availability and low-latency access.

### Architecture

```
┌─────────────────────────────────┐      ┌─────────────────────────────────┐
│        PDX1 Cluster             │      │        PDX2 Cluster             │
│        (10.0.95.x)              │      │        (10.0.96-99.x)           │
│                                 │      │                                 │
│  ┌──────────┐   ┌──────────┐   │      │  ┌──────────┐   ┌──────────┐   │
│  │ keydb-0  │   │ keydb-1  │   │      │  │ keydb-0  │   │ keydb-1  │   │
│  │ (master) │◄─▶│ (master) │   │      │  │ (master) │◄─▶│ (master) │   │
│  └────┬─────┘   └─────┬────┘   │      │  └────┬─────┘   └─────┬────┘   │
│       │               │         │      │       │               │         │
│       │   Headless    │         │      │       │   Headless    │         │
│       │   Service     │         │      │       │   Service     │         │
│       └───────┬───────┘         │      │       └───────┬───────┘         │
│               │                 │      │               │                 │
│       ┌───────▼───────┐         │      │       ┌───────▼───────┐         │
│       │  LoadBalancer │         │      │       │  LoadBalancer │         │
│       │  10.0.95.100  │◄────────┼──────┼──────▶│  10.0.97.100  │         │
│       └───────────────┘         │      │       └───────────────┘         │
│                                 │      │                                 │
│  Active-active replication      │      │  Active-active replication      │
│  across all nodes               │      │  across all nodes               │
└─────────────────────────────────┘      └─────────────────────────────────┘
             ▲                                         ▲
             │                                         │
             └─────────────┬───────────────────────────┘
                           │
                    Bidirectional
                    Replication
```

### Key Features

- **Multi-Master**: All nodes accept writes
- **Active-Active Replication**: Changes replicate bidirectionally
- **Cross-Cluster**: Nodes in different clusters replicate to each other
- **Persistent Storage**: Each node has its own PersistentVolume
- **High Availability**: Continue operating if nodes or clusters fail
- **Last-Write-Wins**: Conflict resolution for concurrent writes

## Deployment Structure

### Helm Chart

Location: `charts/keydb/`

```
keydb/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── statefulset.yaml
    ├── service-headless.yaml
    ├── service.yaml
    └── configmap.yaml
```

### Environment Configurations

- `environments/pdx1/pdx1-dev-keydb-config.yaml`
- `environments/pdx1/pdx1-qa-keydb-config.yaml`
- `environments/pdx1/pdx1-prod-keydb-config.yaml`
- (Similar for pdx2 and other clusters)

### ArgoCD Applications

- `argocd-applications/pdx1/dev/dev-keydb.yaml`
- `argocd-applications/pdx1/qa/qa-keydb.yaml`
- `argocd-applications/pdx1/prod/prod-keydb.yaml`

## Configuration

### Key Parameters

```yaml
keydb:
  enabled: true
  replicaCount: 2              # Number of nodes in this cluster

  # Multi-master settings
  activeReplica: true          # Enable active-active replication
  multiMaster: true            # All nodes are masters

  # External cluster nodes
  externalNodes:
    - "10.0.97.100:6379"       # LoadBalancer IP of other cluster

  # Service configuration
  service:
    type: LoadBalancer         # Expose externally for cross-cluster
    port: 6379

  # Persistence
  persistence:
    enabled: true
    size: 10Gi
    storageClass: longhorn
```

### Replication Behavior

Each KeyDB pod automatically replicates from:
1. **All pods in the same StatefulSet** (via headless service)
2. **All external nodes** (configured via `externalNodes`)

Example for pdx1 with 2 replicas:
- `keydb-0` replicates from:
  - `keydb-1.keydb-headless.dev.svc.cluster.local:6379`
  - `10.0.97.100:6379` (pdx2 cluster)

- `keydb-1` replicates from:
  - `keydb-0.keydb-headless.dev.svc.cluster.local:6379`
  - `10.0.97.100:6379` (pdx2 cluster)

## Deployment Procedure

### Step 1: Deploy to Primary Cluster (pdx1)

```bash
# Commit and push the KeyDB chart and config
git add charts/keydb environments/pdx1/pdx1-dev-keydb-config.yaml argocd-applications/pdx1/dev/dev-keydb.yaml
git commit -m "Add KeyDB multi-master deployment for pdx1-dev"
git push

# Apply ArgoCD application
kubectl apply -f argocd-applications/pdx1/dev/dev-keydb.yaml

# Wait for deployment
kubectl get pods -n dev -l app=keydb -w
```

### Step 2: Get LoadBalancer IP

```bash
kubectl get svc keydb -n dev
```

Example output:
```
NAME    TYPE           CLUSTER-IP      EXTERNAL-IP    PORT(S)
keydb   LoadBalancer   10.43.100.50    10.0.95.100    6379:30379/TCP
```

Note the `EXTERNAL-IP` (e.g., `10.0.95.100`).

### Step 3: Deploy to Secondary Cluster (pdx2)

Create `environments/pdx2/pdx2-dev-keydb-config.yaml`:

```yaml
global:
  namespace: dev

keydb:
  enabled: true
  replicaCount: 2

  activeReplica: true
  multiMaster: true

  # Point to pdx1 cluster
  externalNodes:
    - "10.0.95.100:6379"  # pdx1 LoadBalancer IP

  service:
    type: LoadBalancer
    port: 6379

  persistence:
    enabled: true
    size: 10Gi
    storageClass: longhorn
```

```bash
# On pdx2 cluster
kubectl apply -f argocd-applications/pdx2/dev/dev-keydb.yaml
kubectl get svc keydb -n dev
```

### Step 4: Complete Bidirectional Replication

Update pdx1 config to point back to pdx2:

```yaml
# environments/pdx1/pdx1-dev-keydb-config.yaml
keydb:
  externalNodes:
    - "10.0.97.100:6379"  # pdx2 LoadBalancer IP (from Step 3)
```

```bash
git add environments/pdx1/pdx1-dev-keydb-config.yaml
git commit -m "Configure pdx1 KeyDB to replicate from pdx2"
git push

# ArgoCD will auto-sync and restart pods with new config
```

## Testing Multi-Cluster Replication

### Test 1: Write to pdx1, Read from pdx2

```bash
# Write to pdx1
kubectl exec -it keydb-0 -n dev -- keydb-cli SET test:cluster "hello from pdx1"

# Read from pdx2 (on pdx2 cluster context)
kubectl exec -it keydb-0 -n dev -- keydb-cli GET test:cluster
# Should return: "hello from pdx1"
```

### Test 2: Write to pdx2, Read from pdx1

```bash
# Write to pdx2 (on pdx2 cluster context)
kubectl exec -it keydb-0 -n dev -- keydb-cli SET test:reverse "hello from pdx2"

# Read from pdx1
kubectl exec -it keydb-0 -n dev -- keydb-cli GET test:reverse
# Should return: "hello from pdx2"
```

### Test 3: Verify Replication Lag

```bash
# On any KeyDB pod
kubectl exec -it keydb-0 -n dev -- keydb-cli INFO replication
```

Look for:
- `role:master` (all nodes are masters)
- `connected_slaves:N` (number of replicas)
- `masterN:ip=...` (replication connections)
- `master_repl_offset` (replication position)

## Testing with Minikube

For local testing of multi-cluster setup:

### Start Minikube

```bash
minikube start --driver=docker
```

### Deploy KeyDB to Minikube

Create `test-minikube-keydb-values.yaml`:

```yaml
global:
  namespace: default

keydb:
  enabled: true
  replicaCount: 1

  activeReplica: true
  multiMaster: true

  # Point to pdx1 dev cluster
  externalNodes:
    - "10.0.95.100:6379"

  service:
    type: NodePort  # Minikube doesn't support LoadBalancer by default
    port: 6379

  persistence:
    enabled: true
    size: 1Gi
    storageClass: standard  # Minikube default
```

```bash
helm install keydb ./charts/keydb -f test-minikube-keydb-values.yaml
```

### Get Minikube Service URL

```bash
minikube service keydb --url
# Example output: http://192.168.49.2:30379
```

### Update pdx1 to Replicate from Minikube

```yaml
# environments/pdx1/pdx1-dev-keydb-config.yaml
keydb:
  externalNodes:
    - "192.168.49.2:30379"  # Minikube NodePort
```

### Test Replication

```bash
# Write to minikube
kubectl exec -it keydb-0 -- keydb-cli SET test:minikube "from minikube"

# Read from pdx1
kubectl exec -it keydb-0 -n dev -- keydb-cli GET test:minikube
# Should return: "from minikube"
```

## Network Requirements

### Firewall Rules

For cross-cluster replication to work:

| Source | Destination | Port | Protocol | Purpose |
|--------|-------------|------|----------|---------|
| pdx1 nodes (10.0.95.x) | pdx2 LoadBalancer (10.0.97.x) | 6379 | TCP | Replication from pdx1 to pdx2 |
| pdx2 nodes (10.0.97.x) | pdx1 LoadBalancer (10.0.95.x) | 6379 | TCP | Replication from pdx2 to pdx1 |

**Important**: Both clusters' Kubernetes nodes must be able to reach the other cluster's LoadBalancer IP on port 6379.

### DNS Considerations

If using DNS instead of IPs:
- Create DNS records for each cluster's KeyDB LoadBalancer
- Update `externalNodes` to use hostnames instead of IPs
- Ensure DNS is resolvable from within Kubernetes pods

## Operational Tasks

### Scaling Within a Cluster

To add more nodes to pdx1:

```yaml
# environments/pdx1/pdx1-dev-keydb-config.yaml
keydb:
  replicaCount: 3  # Increase from 2 to 3
```

The new pod will automatically:
- Join the multi-master cluster
- Replicate from existing local pods
- Replicate from external clusters

### Adding a Third Cluster

To add pdx3:

1. Deploy KeyDB to pdx3 with `externalNodes` pointing to pdx1 and pdx2
2. Update pdx1 and pdx2 configs to include pdx3 LoadBalancer IP
3. Commit and let ArgoCD sync

### Monitoring Replication Health

```bash
# Check pod status
kubectl get pods -n dev -l app=keydb

# Check replication info
kubectl exec -it keydb-0 -n dev -- keydb-cli INFO replication

# Check connectivity to external nodes
kubectl exec -it keydb-0 -n dev -- keydb-cli -h 10.0.97.100 PING
```

### Troubleshooting

#### Pods Not Starting

```bash
# Check pod events
kubectl describe pod keydb-0 -n dev

# Check logs
kubectl logs keydb-0 -n dev
```

Common issues:
- PVC not binding (check StorageClass)
- ImagePullBackOff (check imagePullSecrets)
- CrashLoopBackOff (check container logs)

#### Replication Not Working

```bash
# Verify external node is reachable
kubectl exec -it keydb-0 -n dev -- ping -c 3 10.0.97.100

# Test connection to external KeyDB
kubectl exec -it keydb-0 -n dev -- keydb-cli -h 10.0.97.100 PING

# Check firewall rules
# Ensure source cluster nodes can reach destination LoadBalancer:6379
```

#### Data Not Syncing

Check replication lag:
```bash
kubectl exec -it keydb-0 -n dev -- keydb-cli INFO replication | grep master_repl_offset
```

If lag is high:
- Network latency between clusters
- High write volume
- Resource constraints (CPU/memory)

## Performance Considerations

### Resource Sizing

**Development**:
```yaml
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

**Production**:
```yaml
resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: 2000m
    memory: 4Gi
```

### Persistence

- Use fast storage (SSD) for `storageClass`
- Size based on expected data volume
- Monitor disk usage with `kubectl exec keydb-0 -- df -h /data`

### Threads

KeyDB uses threads for improved performance:
```yaml
keydb:
  threads: 2          # I/O threads
  serverThreads: 2    # Server threads
```

Adjust based on CPU availability.

## Data Persistence and Backup

### AOF (Append-Only File)

KeyDB is configured with AOF enabled for durability:
- All writes are logged to appendonly.aof
- Replayed on startup to rebuild state
- Stored in PersistentVolume

### Backup Strategy

1. **Snapshot PersistentVolumes**:
   ```bash
   # Create snapshot of PVC
   kubectl get pvc -n dev | grep keydb
   # Use storage provider's snapshot mechanism
   ```

2. **Export data**:
   ```bash
   kubectl exec -it keydb-0 -n dev -- keydb-cli --rdb /tmp/dump.rdb
   kubectl cp dev/keydb-0:/tmp/dump.rdb ./keydb-backup.rdb
   ```

3. **Restore**:
   ```bash
   kubectl cp ./keydb-backup.rdb dev/keydb-0:/data/dump.rdb
   kubectl delete pod keydb-0 -n dev  # Restart to load dump
   ```

## Security Considerations

### Authentication

Current deployment does not use authentication. For production:

```yaml
keydb:
  password: "your-secret-password"  # Store in Kubernetes secret
```

Update StatefulSet args:
```yaml
args:
  - --requirepass
  - $(KEYDB_PASSWORD)
```

### Network Policies

Restrict access to KeyDB:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: keydb-policy
  namespace: dev
spec:
  podSelector:
    matchLabels:
      app: keydb
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector: {}  # Allow from same namespace
    - namespaceSelector:
        matchLabels:
          name: prod  # Allow from prod namespace
    ports:
    - protocol: TCP
      port: 6379
```

### TLS Encryption

For encrypted replication (production):
- Generate TLS certificates
- Mount as volumes in pods
- Configure KeyDB with `--tls-port`, `--tls-cert-file`, `--tls-key-file`

## Migration from Redis

KeyDB is Redis-compatible, so migration is straightforward:

1. Deploy KeyDB alongside existing Redis
2. Update application configs to point to KeyDB
3. Replicate data from Redis to KeyDB (if needed)
4. Switch traffic to KeyDB
5. Decommission Redis

## References

- **KeyDB Documentation**: https://docs.keydb.dev/
- **Multi-Master Guide**: https://docs.keydb.dev/docs/multi-master/
- **Active-Replication**: https://docs.keydb.dev/docs/active-rep/
- **Helm Chart**: `charts/keydb/`
- **Environment Configs**: `environments/pdx1/pdx1-*-keydb-config.yaml`

## Support

For issues or questions:
- Check KeyDB pod logs: `kubectl logs keydb-0 -n dev`
- Review ArgoCD sync status
- Consult KeyDB documentation
- File issue in noctel-gitops repository
