# PDX1 SPOF Assessment Framework

## Research-Based Kubernetes SPOF Categories

### 1. Control Plane Components

#### 1.1 Etcd Cluster
- **Risk**: Etcd is the source of truth for all cluster state. If quorum is lost, cluster becomes unavailable
- **Check Points**:
  - [ ] Number of etcd replicas (should be 3, 5, or 7 - odd numbers for quorum)
  - [ ] Etcd member health and voting status
  - [ ] Etcd disk space and I/O performance (critical for performance)
  - [ ] Etcd backup strategy and recovery procedures
  - [ ] Etcd distributed across failure domains (nodes/racks/AZs)
  - [ ] Etcd WAL and snapshot sizes
  - [ ] Etcd defragmentation schedule
  - [ ] Network connectivity between etcd members (cluster communication)

#### 1.2 API Server
- **Risk**: API server is the gateway to all cluster operations. Single instance failure = degraded service
- **Check Points**:
  - [ ] Number of API server replicas
  - [ ] API server distributed across worker nodes
  - [ ] API server resource requests/limits (CPU/memory exhaustion risk)
  - [ ] API server audit logging enabled
  - [ ] API server rate limiting configured
  - [ ] API server load balancing (internal service endpoints)
  - [ ] API server certificate/TLS validity and rotation

#### 1.3 Controller Manager
- **Risk**: Controllers drive cluster state reconciliation. If all instances down, cluster stops healing
- **Check Points**:
  - [ ] Number of controller manager replicas
  - [ ] Controller manager leader election working
  - [ ] Controller manager resource limits
  - [ ] Controller manager crash loops or restarts
  - [ ] Individual controller health (node controller, service controller, etc.)

#### 1.4 Scheduler
- **Risk**: If scheduler is down, new pods cannot be scheduled
- **Check Points**:
  - [ ] Number of scheduler replicas
  - [ ] Scheduler leader election working
  - [ ] Scheduler resource limits
  - [ ] Scheduler latency and throughput
  - [ ] Custom scheduler policies or plugins dependencies

### 2. Data Plane (Worker Nodes)

#### 2.1 Node Availability
- **Risk**: Node failure causes pod evictions; widespread node failures cascade
- **Check Points**:
  - [ ] Number of worker nodes (should have ≥3 for redundancy)
  - [ ] Nodes spread across physical infrastructure (different hypervisors/racks/AZs)
  - [ ] Node disk space (kubelet, container images, logs)
  - [ ] Node memory (cluster buffer, eviction thresholds)
  - [ ] Node CPU (reserved for system components)
  - [ ] Kubelet health and readiness
  - [ ] Container runtime health (CRI socket, disk space for overlays)
  - [ ] Node cordoning/draining procedures tested
  - [ ] Pod Disruption Budgets (PDBs) configured for critical workloads

#### 2.2 Pod Distribution
- **Risk**: All replicas of a critical service on one node = SPOF
- **Check Points**:
  - [ ] Pod anti-affinity rules enforced (pod topology spread constraints)
  - [ ] Critical services have PDB with minAvailable
  - [ ] Services have ≥2 replicas on different nodes
  - [ ] Deployment update strategy (RollingUpdate with maxUnavailable=0)
  - [ ] Stateful workloads distributed properly

### 3. Networking

#### 3.1 CNI (Container Network Interface)
- **Risk**: If CNI fails, pods cannot communicate
- **Check Points**:
  - [ ] CNI plugin health (Cilium, Calico, etc.)
  - [ ] CNI daemonset running on all nodes
  - [ ] CNI version/upgrade strategy
  - [ ] CNI IP address exhaustion (IPAM)
  - [ ] CNI network policies enforced or permissive
  - [ ] CNI backup network available

#### 3.2 DNS (CoreDNS)
- **Risk**: DNS failure breaks service discovery cluster-wide
- **Check Points**:
  - [ ] CoreDNS replicas (≥2, preferably ≥3)
  - [ ] CoreDNS pods on different nodes (pod anti-affinity)
  - [ ] CoreDNS zone file/configuration management
  - [ ] External DNS sync (if used)
  - [ ] DNS caching and TTL strategy
  - [ ] Stub domain or upstream DNS failover

#### 3.3 Ingress Controller
- **Risk**: Single ingress controller instance = no external traffic if it fails
- **Check Points**:
  - [ ] Number of ingress controller replicas
  - [ ] Ingress controller distributed across nodes
  - [ ] Ingress controller load balancer (MetalLB, cloud LB, etc.)
  - [ ] Ingress controller resource limits
  - [ ] Ingress certificate management (cert-manager)
  - [ ] Ingress backend health checks
  - [ ] Ingress TLS termination failover

#### 3.4 Load Balancer (if external)
- **Risk**: Single load balancer = traffic SPOF
- **Check Points**:
  - [ ] Load balancer high availability (HA pair/cluster)
  - [ ] Load balancer health checks to backend services
  - [ ] Load balancer failover mechanism
  - [ ] Load balancer certificate/TLS handling
  - [ ] Load balancer IP static/sticky
  - [ ] Load balancer session persistence vs. statefulness

#### 3.5 Service Mesh (if deployed)
- **Risk**: Mesh proxy/control plane failure breaks traffic
- **Check Points**:
  - [ ] Control plane (Istio, Linkerd) replica count
  - [ ] Data plane proxy sidecar injection health
  - [ ] Mesh certificate rotation
  - [ ] Mesh traffic policies (circuit breakers, timeouts)
  - [ ] Mesh observability (metrics, traces, logs)

### 4. Storage

#### 4.1 PersistentVolume (PV) Backing
- **Risk**: Single storage node/backend = data availability SPOF
- **Check Points**:
  - [ ] Storage backend type (local, NAS, SAN, cloud storage)
  - [ ] Storage replication (RAID, mirroring, cloud redundancy)
  - [ ] Storage snapshots and backup strategy
  - [ ] Storage disaster recovery procedure
  - [ ] Storage performance (IOPS, latency bottlenecks)
  - [ ] Storage capacity planning and monitoring
  - [ ] Storage encryption (at rest and in transit)

#### 4.2 StorageClass & Provisioners
- **Risk**: Single provisioner or storage driver failure breaks PV creation
- **Check Points**:
  - [ ] StorageClass reclaim policies (delete, retain, recycle)
  - [ ] Dynamic provisioner health (external provisioner pods)
  - [ ] Provisioner replica count and placement
  - [ ] Provisioner credentials/secrets management
  - [ ] PVC stuck in Pending state detection

#### 4.3 StatefulSet & StatefulWorkloads
- **Risk**: StatefulSet with replicas=1 or pod anti-affinity violations
- **Check Points**:
  - [ ] StatefulSet replica count (≥2 minimum)
  - [ ] Headless service for proper DNS
  - [ ] Pod stable identities and ordering
  - [ ] StatefulSet rolling update strategy
  - [ ] VolumeClaimTemplates proper sizing

### 5. Observability & Monitoring

#### 5.1 Monitoring Stack
- **Risk**: If monitoring is down, cluster issues go undetected
- **Check Points**:
  - [ ] Prometheus/metrics scraper replicas
  - [ ] Prometheus data retention and storage
  - [ ] AlertManager replicas and notification routing
  - [ ] Grafana dashboards availability
  - [ ] Metric collection from all components (nodes, pods, services)

#### 5.2 Logging Stack
- **Risk**: Log storage failure loses operational visibility
- **Check Points**:
  - [ ] Log aggregator (ELK, Loki, etc.) replicas
  - [ ] Log storage backend health
  - [ ] Log retention policies
  - [ ] Log parsing and indexing performance
  - [ ] Log forwarding from all nodes (DaemonSet health)

#### 5.3 Tracing (if deployed)
- **Risk**: Distributed tracing failure loses request path visibility
- **Check Points**:
  - [ ] Tracing backend (Jaeger, Tempo) replicas
  - [ ] Tracing storage and retention
  - [ ] Instrumentation in services

### 6. External Dependencies

#### 6.1 External Databases
- **Risk**: Database downtime breaks application availability
- **Check Points**:
  - [ ] Database cluster high availability (HA failover)
  - [ ] Database replication (primary/secondary or multi-master)
  - [ ] Database connection pooling and timeouts
  - [ ] Database backup and recovery procedures
  - [ ] Database network connectivity and firewall rules
  - [ ] Database credential rotation
  - [ ] Database monitoring and alerting
  - [ ] Database read replicas for read-heavy workloads

#### 6.2 External Message Queues (RabbitMQ, Redis, etc.)
- **Risk**: Queue downtime stops async processing
- **Check Points**:
  - [ ] Queue cluster high availability
  - [ ] Queue replication/persistence
  - [ ] Queue consumer acknowledgment strategy
  - [ ] Queue dead-letter handling
  - [ ] Queue monitoring and lag tracking

#### 6.3 External Service Dependencies (SMTP, APIs, etc.)
- **Risk**: Dependency unavailability cascades to cluster
- **Check Points**:
  - [ ] Dependency SLA and uptime history
  - [ ] Dependency fallback/circuit breaker strategy
  - [ ] Dependency health checks from cluster
  - [ ] Dependency timeout and retry logic
  - [ ] Dependency rate limiting and quota management

#### 6.4 DNS (External)
- **Risk**: External DNS failure breaks domain resolution
- **Check Points**:
  - [ ] DNS provider redundancy (multiple nameservers)
  - [ ] DNS TTL strategy
  - [ ] DNS failover mechanism
  - [ ] DNS DNSSEC validation (if enabled)

### 7. Cluster Add-ons & Critical Services

#### 7.1 Kube-Proxy
- **Risk**: Kube-proxy failure breaks service networking
- **Check Points**:
  - [ ] Kube-proxy running on all nodes (DaemonSet)
  - [ ] Kube-proxy mode (iptables, ipvs, ebpf)
  - [ ] Kube-proxy resource usage
  - [ ] Kube-proxy rule update latency

#### 7.2 Kubelet
- **Risk**: Kubelet failure on node prevents pod execution
- **Check Points**:
  - [ ] Kubelet version consistency across nodes
  - [ ] Kubelet certificate rotation
  - [ ] Kubelet eviction thresholds and grace periods
  - [ ] Kubelet log rotation and disk usage
  - [ ] Kubelet CGroupV2 vs V1 compatibility

#### 7.3 Container Runtime
- **Risk**: Container runtime crash stops all pods on node
- **Check Points**:
  - [ ] Container runtime health (containerd, docker, cri-o)
  - [ ] Container runtime disk space (image/overlay storage)
  - [ ] Container runtime socket permissions and ownership
  - [ ] Container runtime version updates and compatibility
  - [ ] Container image pull failures and fallback registries

### 8. Configuration & Secrets Management

#### 8.1 Secrets
- **Risk**: Secret management failure exposes credentials
- **Check Points**:
  - [ ] Secret storage backend (etcd, external KMS)
  - [ ] Secret encryption at rest
  - [ ] Secret rotation procedures
  - [ ] Secret audit logging
  - [ ] Secret access RBAC

#### 8.2 ConfigMaps
- **Risk**: ConfigMap corruption breaks application configuration
- **Check Points**:
  - [ ] ConfigMap size limits (1MB max)
  - [ ] ConfigMap update strategy and rollout
  - [ ] ConfigMap versioning/rollback procedure

### 9. RBAC & Security

#### 9.1 RBAC
- **Risk**: Overly permissive RBAC enables privilege escalation
- **Check Points**:
  - [ ] Service account proliferation (least privilege)
  - [ ] ClusterRole/Role explosion and unused roles
  - [ ] RoleBinding/ClusterRoleBinding audit
  - [ ] RBAC policy testing and validation

#### 9.2 Pod Security
- **Risk**: Insecure pod configuration allows container escape
- **Check Points**:
  - [ ] Pod Security Policy or Pod Security Standard enforcement
  - [ ] Privileged pod usage audit
  - [ ] Host path mount audit
  - [ ] Host network usage audit
  - [ ] Security context (uid, gid, capabilities)

#### 9.3 Network Policies
- **Risk**: Misconfigured or missing network policies enable lateral movement
- **Check Points**:
  - [ ] Network policy enforcement mode (permissive vs. restrictive)
  - [ ] Egress policies to external services
  - [ ] Ingress policies from clients
  - [ ] Network policy selector accuracy

### 10. Disaster Recovery & Resilience

#### 10.1 Backup & Recovery
- **Risk**: No backup = data loss in disaster
- **Check Points**:
  - [ ] Cluster state backup (etcd backups)
  - [ ] Application data backup (PVC backups)
  - [ ] Backup testing and restore procedures
  - [ ] Backup retention and archival
  - [ ] Recovery time objective (RTO) and recovery point objective (RPO)

#### 10.2 Cluster Upgrade Path
- **Risk**: Upgrade failures or rollback issues
- **Check Points**:
  - [ ] Kubernetes version upgrade strategy
  - [ ] Add-on upgrade sequence
  - [ ] Node upgrade order and rollback
  - [ ] Drain and eviction procedures

#### 10.3 Failure Domains
- **Risk**: Shared infrastructure = multiple components fail together
- **Check Points**:
  - [ ] Nodes on different hypervisors/physical servers
  - [ ] Nodes on different network switches
  - [ ] Nodes on different power supplies
  - [ ] Nodes on different network uplinks
  - [ ] Persistent storage on different storage arrays/shelves

### 11. Performance & Scalability

#### 11.1 API Server Performance
- **Risk**: API server bottleneck or slowdown
- **Check Points**:
  - [ ] API latency percentiles (p50, p95, p99)
  - [ ] API request rate and throughput
  - [ ] Etcd latency and database size
  - [ ] API server connection pool exhaustion

#### 11.2 Scheduler Performance
- **Risk**: Scheduler lag prevents timely pod scheduling
- **Check Points**:
  - [ ] Scheduling latency percentiles
  - [ ] Pending pod queue size
  - [ ] Scheduler throughput (pods/sec)
  - [ ] Node/pod count scale testing

#### 11.3 Network Performance
- **Risk**: Network congestion or packet loss
- **Check Points**:
  - [ ] Network bandwidth utilization
  - [ ] Packet loss and latency
  - [ ] Network MTU and fragmentation
  - [ ] DNS query latency and cache hit rate

### 12. Operational Procedures

#### 12.1 Runbooks & Alerting
- **Risk**: No clear escalation procedure for failures
- **Check Points**:
  - [ ] Runbook existence for critical failures
  - [ ] Alert severity and routing
  - [ ] On-call schedule and escalation
  - [ ] Training and drill procedures

#### 12.2 Change Management
- **Risk**: Uncontrolled changes break cluster
- **Check Points**:
  - [ ] Change control process (peer review, testing)
  - [ ] Change rollback procedures
  - [ ] Blue-green or canary deployment strategy
  - [ ] Cluster state drift detection (GitOps)

---

## Assessment Severity Levels

| Level | Impact | Response Time |
|-------|--------|---|
| **Critical** | Cluster unavailable or data loss risk | <5 min investigation |
| **High** | Service degradation or SPOF exists | <30 min investigation |
| **Medium** | Operational issue or partial SPOF | <4 hours |
| **Low** | Best practice gap | Plan for next sprint |

---

## Next: PDX1-Specific Audit

We will use this framework to audit PDX1 and identify:
1. Confirmed SPOFs
2. Hidden dependencies
3. Resilience gaps
4. Recovery time estimates
5. Remediation priorities
