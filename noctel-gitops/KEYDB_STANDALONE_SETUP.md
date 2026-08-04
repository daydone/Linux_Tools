# KeyDB Standalone Setup Guide
**Source:** PDX1 Production Cluster (prod namespace)
**Date:** 2026-07-21

## Quick Summary
- **Image:** eqalpha/keydb:x86_64_v6.3.3
- **Cluster Type:** 3-node Active-Replica mesh (multi-master)
- **Memory:** 6144MB (maxmemory), 8GB pod limit
- **Storage:** 20GB per node (not needed for standalone replica)
- **Threads:** 4 server threads
- **Port:** 6379 (KeyDB)

## Installation & Configuration

### 1. Download KeyDB Binary
```bash
# Option A: Docker (recommended for testing)
docker pull eqalpha/keydb:x86_64_v6.3.3

# Option B: Download binary directly
wget https://download.keydb.dev/keydb-x86_64_v6.3.3
chmod +x keydb-x86_64_v6.3.3
```

### 2. KeyDB Configuration File (`keydb.conf`)

**Critical Settings:**
```conf
# Protection & Networking
protected-mode no
tcp-backlog 511
timeout 0
tcp-keepalive 300
daemonize no
loglevel notice
databases 16

# Memory Management (CRITICAL: must use volatile-lru)
# DO NOT use allkeys-lru — it evicts live-state keys
maxmemory 6144mb
maxmemory-policy volatile-lru
maxmemory-samples 10

# Persistence (AOF enabled, RDB disabled due to KeyDB bug)
save ""
stop-writes-on-bgsave-error no
rdbcompression yes
rdbchecksum yes
dbfilename dump.rdb
appendfilename "appendonly.aof"
appendfsync everysec
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 512mb
aof-load-truncated yes
aof-use-rdb-preamble yes

# Replication
replica-serve-stale-data yes
replica-read-only no
repl-diskless-sync yes
repl-diskless-sync-delay 0
repl-disable-tcp-nodelay yes
repl-timeout 300
replica-priority 100
repl-backlog-size 512mb
repl-backlog-ttl 3600

# Active Defragmentation (handles TTL churn)
activedefrag yes
active-defrag-threshold-lower 10
active-defrag-threshold-upper 100
active-defrag-cycle-min 5
active-defrag-cycle-max 25
active-defrag-ignore-bytes 100mb

# Other Settings
lazyfree-lazy-eviction no
lazyfree-lazy-expire no
lazyfree-lazy-server-del no
replica-lazy-flush no
lua-time-limit 5000
slowlog-log-slower-than 10000
slowlog-max-len 128
latency-monitor-threshold 0
notify-keyspace-events ""
hash-max-ziplist-entries 512
hash-max-ziplist-value 64
list-max-ziplist-size -2
list-compress-depth 0
set-max-intset-entries 512
zset-max-ziplist-entries 128
zset-max-ziplist-value 64
hll-sparse-max-bytes 3000
stream-node-max-bytes 4096
stream-node-max-entries 100
activerehashing yes
client-output-buffer-limit normal 0 0 0
client-output-buffer-limit replica 256mb 64mb 60
client-output-buffer-limit pubsub 32mb 8mb 60
hz 0
dynamic-hz no
aof-rewrite-incremental-fsync yes
rdb-save-incremental-fsync yes

# ACL & Authentication
aclfile /etc/keydb/acl.conf
masterauth SmzPS2QL1YLBWqKjd0u8
masteruser keydb-prod
```

### 3. ACL Configuration (`acl.conf`)

```conf
user default on nopass ~* &* +@all
user keydb-prod on >SmzPS2QL1YLBWqKjd0u8 ~* &* +@all
```

**Credentials:**
- Username: `keydb-prod`
- Password: `SmzPS2QL1YLBWqKjd0u8`

### 4. Startup Command (Single Node)

```bash
keydb-server /etc/keydb/keydb.conf \
  --active-replica yes \
  --multi-master yes \
  --server-threads 4 \
  --server-thread-affinity false \
  --appendonly yes \
  --dir /var/lib/keydb \
  --bind 0.0.0.0 \
  --port 6379
```

### 5. For Multi-Node Cluster (3 nodes)

**Node 1 Startup:**
```bash
keydb-server /etc/keydb/keydb.conf \
  --active-replica yes \
  --multi-master yes \
  --server-threads 4 \
  --server-thread-affinity false \
  --appendonly yes \
  --dir /var/lib/keydb \
  --bind 0.0.0.0 \
  --port 6379
```

**Node 2 Startup:**
```bash
keydb-server /etc/keydb/keydb.conf \
  --active-replica yes \
  --multi-master yes \
  --server-threads 4 \
  --server-thread-affinity false \
  --appendonly yes \
  --dir /var/lib/keydb \
  --bind 0.0.0.0 \
  --port 6379 \
  --replicaof node1.example.com 6379
```

**Node 3 Startup:**
```bash
keydb-server /etc/keydb/keydb.conf \
  --active-replica yes \
  --multi-master yes \
  --server-threads 4 \
  --server-thread-affinity false \
  --appendonly yes \
  --dir /var/lib/keydb \
  --bind 0.0.0.0 \
  --port 6379 \
  --replicaof node1.example.com 6379
```

## Resource Requirements

| Setting | Value |
|---------|-------|
| **CPU Requests** | 500m (0.5 cores) |
| **CPU Limits** | 2000m (2 cores) |
| **Memory Requests** | 4GB |
| **Memory Limits** | 8GB |
| **Storage** | 20GB (for AOF persistence) |

## Network Endpoints

**Kubernetes Services:**
- **Internal:** `keydb.prod.svc.cluster.local:6379`
- **Internal Headless:** `keydb-headless.prod.svc.cluster.local:6379`
- **External LoadBalancer:** `10.0.99.160:6379`
- **External NodePort:** `<any-node-ip>:32427`

**For Standalone:** Use direct IP:port or hostname

## Key Configuration Notes

### Why volatile-lru?
- KeyDB stores **live-state keys without TTL** (presence, API services, HA1 routing)
- Stores **TTL'd cache keys** (metrics, temporary data)
- `allkeys-lru` would evict live-state, breaking desk propagation
- `volatile-lru` only evicts TTL'd keys, preserving live-state

### Why AOF but no RDB?
- KeyDB v6.3.3 has a bug in RDB fork process (rdb.cpp:1372)
- Causes assertion failures during `BGSAVE`
- `save ""` disables RDB snapshots
- AOF alone provides reliable persistence

### Why repl-backlog-size 512mb?
- Supports ~1 hour of writes at steady state (~33 KB/s)
- Full resyncs only needed if disconnect > ~1.5 hours (rare)
- Prevents RSS drift from oversized buffers

### Why hz 0?
- Disables automatic key expiration
- KeyDB v6.3.3 crashes in `activeExpireCycleCore` during expiration
- Manual or client-side expiration is safer

### Why auto-aof-rewrite-min-size 512mb?
- Prevents frequent AOF rewrites under high write load
- Balances rewrite overhead vs. log size
- At ~33 KB/s writes: rewrites every ~4-5 hours

## Verification

```bash
# Connect and test
keydb-cli -h localhost -p 6379 -a SmzPS2QL1YLBWqKjd0u8

# Check status
> INFO server
> INFO memory
> INFO persistence
> INFO replication

# Test persistence
> SET test-key "test-value"
> BGSAVE
> ACL LIST
```

## Docker Compose Example (3-node cluster)

```yaml
version: '3.8'
services:
  keydb-0:
    image: eqalpha/keydb:x86_64_v6.3.3
    ports:
      - "6379:6379"
    volumes:
      - ./keydb.conf:/etc/keydb/keydb.conf
      - ./acl.conf:/etc/keydb/acl.conf
      - keydb0:/var/lib/keydb
    command: keydb-server /etc/keydb/keydb.conf --active-replica yes --multi-master yes --server-threads 4 --server-thread-affinity false --appendonly yes --dir /var/lib/keydb
    networks:
      - keydb-mesh

  keydb-1:
    image: eqalpha/keydb:x86_64_v6.3.3
    ports:
      - "6380:6379"
    volumes:
      - ./keydb.conf:/etc/keydb/keydb.conf
      - ./acl.conf:/etc/keydb/acl.conf
      - keydb1:/var/lib/keydb
    command: keydb-server /etc/keydb/keydb.conf --active-replica yes --multi-master yes --server-threads 4 --server-thread-affinity false --appendonly yes --dir /var/lib/keydb --replicaof keydb-0 6379
    depends_on:
      - keydb-0
    networks:
      - keydb-mesh

  keydb-2:
    image: eqalpha/keydb:x86_64_v6.3.3
    ports:
      - "6381:6379"
    volumes:
      - ./keydb.conf:/etc/keydb/keydb.conf
      - ./acl.conf:/etc/keydb/acl.conf
      - keydb2:/var/lib/keydb
    command: keydb-server /etc/keydb/keydb.conf --active-replica yes --multi-master yes --server-threads 4 --server-thread-affinity false --appendonly yes --dir /var/lib/keydb --replicaof keydb-0 6379
    depends_on:
      - keydb-0
    networks:
      - keydb-mesh

volumes:
  keydb0:
  keydb1:
  keydb2:

networks:
  keydb-mesh:
```

## Critical Warnings

⚠️ **DO NOT:**
- Use `--maxmemory-policy allkeys-lru` (breaks live-state)
- Enable RDB snapshots (KeyDB bug causes crashes)
- Disable active-defrag (RSS will bloat)
- Set `hz` above 0 (causes crashes)
- Use `requirepass` without ACL (legacy, less secure)

✅ **DO:**
- Monitor maxmemory usage and ensure TTL'd keys are being evicted
- Set up monitoring on memory, evictions, and AOF rewrite frequency
- Test failover and recovery procedures
- Backup ACL credentials
