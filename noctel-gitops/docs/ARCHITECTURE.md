# Noctel GitOps Architecture

This document describes the architecture and design decisions for the Noctel multi-cluster GitOps deployment.

## Table of Contents
1. [Overview](#overview)
2. [Multi-Cluster Design](#multi-cluster-design)
3. [Directory Structure](#directory-structure)
4. [Configuration Management](#configuration-management)
5. [Network Architecture](#network-architecture)
6. [Application Stack](#application-stack)
7. [Infrastructure Components](#infrastructure-components)
8. [Deployment Flow](#deployment-flow)
9. [Security Model](#security-model)
10. [Scaling Strategy](#scaling-strategy)

## Overview

The Noctel platform is deployed across multiple Kubernetes clusters using a GitOps approach with ArgoCD. Each cluster is independent but follows the same architectural patterns.

### Design Goals
- **Cluster Independence**: Each cluster operates autonomously
- **Configuration Consistency**: Same application stack across all clusters
- **Environment Separation**: dev, qa, prod isolated within each cluster
- **Easy Replication**: New clusters can be bootstrapped quickly
- **Disaster Recovery**: Clusters can be rebuilt from Git

## Multi-Cluster Design

### Cluster Topology

```
┌─────────────────────────────────────────────────────────────┐
│                    Git Repository                           │
│                noctel-bitbucket/noctel-gitops               │
│                                                              │
│  ┌────────────────────────┐  ┌────────────────────────┐    │
│  │   argocd-applications/ │  │    environments/       │    │
│  │   ├── pdx1/            │  │    ├── pdx1/           │    │
│  │   │   ├── dev/         │  │    │   ├── dev-config │    │
│  │   │   ├── qa/          │  │    │   ├── qa-config  │    │
│  │   │   └── prod/        │  │    │   └── prod-config│    │
│  │   └── pdx2/            │  │    └── pdx2/           │    │
│  │       ├── dev/         │  │        ├── dev-config │    │
│  │       ├── qa/          │  │        ├── qa-config  │    │
│  │       └── prod/        │  │        └── prod-config│    │
│  └────────────────────────┘  └────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
                       │                     │
                       ▼                     ▼
        ┌──────────────────────┐  ┌──────────────────────┐
        │   PDX1 Cluster       │  │   PDX2 Cluster       │
        │   (10.0.95.x)        │  │   (10.0.96-99.x)     │
        │                      │  │                      │
        │   ┌──────────────┐   │  │   ┌──────────────┐   │
        │   │   ArgoCD     │   │  │   │   ArgoCD     │   │
        │   │              │   │  │   │              │   │
        │   │  ┌────┬────┐ │   │  │   │  ┌────┬────┐ │   │
        │   │  │dev │qa  │ │   │  │   │  │dev │qa  │ │   │
        │   │  │    │    │ │   │  │   │  │    │    │ │   │
        │   │  │prod│    │ │   │  │   │  │prod│    │ │   │
        │   │  └────┴────┘ │   │  │   │  └────┴────┘ │   │
        │   └──────────────┘   │  │   └──────────────┘   │
        │                      │  │                      │
        │   5 servers          │  │   Multiple servers   │
        │   2 workers          │  │   Multi-VLAN         │
        └──────────────────────┘  └──────────────────────┘
```

### Cluster Details

#### PDX1 Cluster
- **Location**: Portland datacenter 1
- **Network**: 10.0.95.0/24
- **Nodes**:
  - 5 server nodes: pdx1-kserver0 through pdx1-kserver4 (10.0.95.30-34)
  - 2 worker nodes: pdx1-kworker0, pdx1-kworker1 (10.0.95.40-41)
- **Kubernetes**: K3S v1.28.5+k3s1
- **CNI**: Cilium v1.16.5 with VXLAN
- **Load Balancer**: MetalLB (to be configured)
- **Storage**: Local path provisioner

#### PDX2 Cluster
- **Location**: Portland datacenter 2
- **Network**: Multi-VLAN (10.0.96.x, 10.0.97.x, 10.0.98.x, 10.0.99.x)
  - Management VLAN: 10.0.96.x (VLAN 604)
  - Dev VLAN: 10.0.97.x (VLAN 677)
  - QA VLAN: 10.0.98.x (VLAN 678)
  - Prod VLAN: 10.0.99.x (VLAN 679)
- **Network Interfaces**: bond0 with VLAN tagging
- **Kubernetes**: K3S (version TBD)
- **CNI**: Cilium with VXLAN
- **Load Balancer**: MetalLB with L2 advertisement
- **Storage**: Local path provisioner

## Directory Structure

### ArgoCD Applications (Cluster-Specific)

```
argocd-applications/
├── pdx1/
│   ├── dev/
│   │   ├── dev-noctel-api.yaml          # ArgoCD Application for API
│   │   ├── dev-noctel-ui.yaml           # ArgoCD Application for UI
│   │   ├── dev-elasticsearch.yaml       # Infrastructure: Elasticsearch
│   │   ├── dev-redis.yaml               # Infrastructure: Redis
│   │   └── ... (13 more applications)
│   ├── qa/
│   │   └── ... (16 applications)
│   └── prod/
│       └── ... (16 applications)
└── pdx2/
    ├── dev/
    │   └── ... (17 applications)
    ├── qa/
    │   └── ... (17 applications)
    └── prod/
        └── ... (17 applications to be created)
```

**Key Design Decision**: Applications are organized by cluster first, then environment. This allows:
- Independent cluster management
- Easy identification of which apps run where
- Simple cluster addition (create new cluster directory)
- Clear separation preventing cross-cluster deployments

### Environment Configurations (Cluster-Specific Values)

```
environments/
├── pdx1/
│   ├── pdx1-dev-config.yaml      # Complete dev configuration (513 lines)
│   ├── pdx1-qa-config.yaml       # Complete qa configuration (570 lines)
│   ├── pdx1-prod-config.yaml     # Production config (incomplete, 84 lines)
│   └── pdx1-metallb-config.yaml  # MetalLB IP pools (to be created)
└── pdx2/
    ├── pdx2-dev-config.yaml      # Complete dev configuration (513 lines)
    ├── pdx2-qa-config.yaml       # Complete qa configuration (570 lines)
    ├── pdx2-prod-config.yaml     # Production config (incomplete, 84 lines)
    └── pdx2-metallb-config.yaml  # MetalLB IP pools (complete, 58 lines)
```

**Key Design Decision**: Each cluster has its own configuration files because:
- Different network configurations (IPs, VLANs, subnets)
- Different domain names (pdx1-dev.telnoc.com vs pdx2-dev.telnoc.com)
- Different resource allocations based on hardware
- Allows cluster-specific customization

### Helm Charts (Shared Across Clusters)

```
manifests/
├── noctel-api/              # Noctel REST API service
├── noctel-ui/               # Web user interface
├── noctel-lns/              # LoRaWAN Network Server
├── noctel-ape/              # Application Processing Engine
├── noctel-display/          # Display service
├── noctel-migrate/          # Database migration jobs
├── chirpstack-core/         # ChirpStack LoRaWAN core
├── chirpstack-gateway-bridge/
├── chirpstack-mosquitto/    # MQTT broker
├── traefik/                 # Ingress controller
├── redis/                   # In-memory data store
├── rabbitmq/                # Message queue
├── elasticsearch/           # Search and analytics
├── seaweedfs/               # Distributed file system
├── nt-mq-mailer/            # Email via RabbitMQ
├── noctel-aps/              # Apple Push Notifications
└── metallb/                 # Load balancer
```

**Key Design Decision**: Helm charts are shared across all clusters because:
- Application logic is the same everywhere
- Reduces duplication and maintenance
- Customization via values files, not chart modifications
- Easier to update all clusters simultaneously

## Configuration Management

### Configuration File Structure

Each environment config file follows this structure:

```yaml
# Global settings applied to all services
global:
  cluster: pdx1                # Cluster identifier
  namespace: dev               # Kubernetes namespace
  domain:
    prefix: pdx1-dev          # Domain prefix for ingress
    base: telnoc.com          # Base domain
  imagePullSecrets:
    - name: dockerhub-secret  # Docker registry credentials
  dockerRegistry:
    server: "index.docker.io/v1/"
    username: "noctel"
    password: "ENCRYPTED"

# Application services
noctel-api:
  version: "latest"           # Docker image tag
  replicaCount: 1             # Number of replicas
  service:
    type: ClusterIP
    port: 4000
  ingress:
    enabled: true
    host: "noctel-api.pdx1-dev.telnoc.com"
  config:
    database:
      host: "postgres-service"
      port: 5432
      name: "noctel_dev"
    redis:
      host: "redis-dev"
      port: 6379
    rabbitmq:
      host: "ha-rabbit-server"
      port: 5672
    elasticsearch:
      host: "elasticsearch"
      port: 9200

# Infrastructure services
elasticsearch:
  enabled: true
  replicas: 1
  persistence:
    enabled: true
    storageClass: "local-path"
    size: "50Gi"
  javaOpts: "-Xms2g -Xmx2g"

redis:
  enabled: true
  architecture: standalone
  auth:
    enabled: true
    password: "ENCRYPTED"
  persistence:
    enabled: true
    size: "10Gi"

rabbitmq:
  enabled: true
  replicaCount: 1
  persistence:
    enabled: true
    size: "10Gi"
  auth:
    username: "noctel"
    password: "ENCRYPTED"

# ... more services
```

### Configuration Inheritance

```
Chart Default Values (charts/service/values.yaml)
           ↓
Environment Config (environments/pdx1/pdx1-dev-config.yaml)
           ↓
ArgoCD Application Parameters (if any)
           ↓
Final Rendered Manifests
```

Values files completely override chart defaults. ArgoCD parameters (if used) override values files.

**Best Practice**: Always configure via values files in Git, never use ArgoCD parameter overrides.

## Network Architecture

### PDX1 Network Topology

```
┌──────────────────────────────────────────────────┐
│             10.0.95.0/24                         │
│                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐      │
│  │ kserver0 │  │ kserver1 │  │ kserver2 │      │
│  │.30       │  │.31       │  │.32       │      │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘      │
│       │             │             │              │
│  ┌────┴──────┬──────┴──────┬──────┴─────┐      │
│  │ kserver3 │  │ kserver4 │              │      │
│  │.33       │  │.34       │              │      │
│  └────┬─────┘  └────┬─────┘              │      │
│       │             │                     │      │
│  ┌────┴─────┐  ┌────┴─────┐              │      │
│  │ kworker0 │  │ kworker1 │              │      │
│  │.40       │  │.41       │              │      │
│  └──────────┘  └──────────┘              │      │
│                                           │      │
│  All nodes in same flat network          │      │
│  MetalLB IP pools (to be assigned)       │      │
└──────────────────────────────────────────────────┘
```

#### PDX1 Ingress Mapping

- Cluster-specific ingress manifests live under `networking/pdx1/<environment>/`.
- Each ingress uses the `traefik-<namespace>` IngressClass emitted by the Traefik Helm chart so routing remains namespace scoped.
- Hosts come directly from the pdx1 environment configs:
  - Dev: `pdx1-dev-api.telnoc.com`, `pdx1-dev-portal.telnoc.com`
  - QA: `pdx1-qa-api.mocktel.com`, `pdx1-qa-portal.mocktel.com`, `pdx1-qa-display.mocktel.com`
  - Prod:
    - Local validation: `pdx1-prod-api.telnoc.com`, `pdx1-prod-api-int.telnoc.com`, `pdx1-prod-portal.telnoc.com`, `pdx1-prod-display.telnoc.com`, `pdx1-prod-lns.telnoc.com`, `pdx1-prod-ape.telnoc.com`, `pdx1-prod-s3.telnoc.com`
    - Global cutover: `api.noctel.com`, `portal.noctel.com`, `d.noc.tel`, `api.mocktel.com`, `portal.mocktel.com`, `d.mocktel.com`, `lns.mocktel.com`
- TLS certificates:
  - Local (`pdx1-*`) ingresses use Traefik’s `dnsmadeeasy` resolver so they can be validated before DNS cutover.
  - Global domains use cert-manager (`letsencrypt-prod-http`) with HTTP-01 challenges. The manifests already point to `pdx1-kworker0` for the temporary solver pod; update your DNS provider to target the pdx1 prod LoadBalancer IP to complete issuance.

### PDX2 Network Topology (Multi-VLAN)

```
┌────────────────────────────────────────────────────────────┐
│                       Physical Network                      │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  bond0 (Bonded Interface)                            │  │
│  │                                                       │  │
│  │  ├── bond0.604  (Management)  10.0.96.x             │  │
│  │  │   MetalLB: 10.0.96.30-40, 10.0.96.140-145        │  │
│  │  │                                                    │  │
│  │  ├── bond0.677  (Dev VLAN)    10.0.97.x             │  │
│  │  │   MetalLB: 10.0.97.20-30                         │  │
│  │  │   Namespace: dev                                  │  │
│  │  │                                                    │  │
│  │  ├── bond0.678  (QA VLAN)     10.0.98.x             │  │
│  │  │   MetalLB: 10.0.98.20-30                         │  │
│  │  │   Namespace: qa                                   │  │
│  │  │                                                    │  │
│  │  └── bond0.679  (Prod VLAN)   10.0.99.x             │  │
│  │      MetalLB: 10.0.99.20-30                         │  │
│  │      Namespace: prod                                 │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  Each environment isolated to separate VLAN                 │
│  MetalLB L2 advertisement bound to specific interfaces      │
└────────────────────────────────────────────────────────────┘
```

### Network Policies

Cilium network policies control traffic between namespaces:
- **dev**: Open within namespace, external access allowed
- **qa**: Open within namespace, external access allowed
- **prod**: Restricted, only specific service-to-service communication

## Application Stack

### Service Categories

#### Core Application Services
- **noctel-api**: REST API backend (Node.js)
- **noctel-ui**: Web frontend (React)
- **noctel-lns**: LoRaWAN Network Server
- **noctel-ape**: Application Processing Engine
- **noctel-display**: Display service for kiosks
- **noctel-migrate**: Database migration jobs

#### LoRaWAN Services
- **chirpstack-core**: ChirpStack LoRaWAN server
- **chirpstack-gateway-bridge**: Bridge for LoRa gateways
- **chirpstack-mosquitto**: MQTT broker for ChirpStack

#### Infrastructure Services
- **traefik**: Ingress controller and reverse proxy
- **redis**: In-memory cache and session store
- **rabbitmq**: Message queue for async processing
- **elasticsearch**: Search engine and log aggregation
- **seaweedfs**: Distributed object storage
- **nt-mq-mailer**: Email service via RabbitMQ
- **noctel-aps**: Apple Push Notification service

### Service Dependencies

```
                    ┌─────────────┐
                    │  noctel-ui  │
                    └──────┬──────┘
                           │
                           ▼
┌──────────┐      ┌─────────────┐      ┌──────────────┐
│ traefik  │─────▶│ noctel-api  │─────▶│ redis        │
└──────────┘      └──────┬──────┘      └──────────────┘
                         │
                         ├──────────────▶┌──────────────┐
                         │               │ rabbitmq     │
                         │               └──────────────┘
                         │
                         ├──────────────▶┌──────────────┐
                         │               │elasticsearch │
                         │               └──────────────┘
                         │
                         └──────────────▶┌──────────────┐
                                         │ seaweedfs    │
                                         └──────────────┘
```

**Deployment Order**: Infrastructure services must be deployed before application services.

1. Storage and databases (elasticsearch, redis)
2. Message queues (rabbitmq)
3. Application services (noctel-api, noctel-ui)
4. Auxiliary services (nt-mq-mailer, noctel-aps)

## Infrastructure Components

### Cilium CNI

**Purpose**: Container Network Interface for pod networking and network policies

**Configuration**:
```yaml
cilium:
  version: 1.16.5
  tunnel: vxlan
  cluster-name: pdx1  # Dynamically set based on hostname
  ipam:
    mode: kubernetes
  hubble:
    enabled: true
```

**Features Used**:
- VXLAN tunneling for pod network
- Network policy enforcement
- Hubble observability (optional)
- Cross-node pod communication

### ArgoCD

**Purpose**: GitOps continuous delivery tool

**Installation**:
```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace
```

**Configuration**:
- Repository: SSH authentication with private key
- Sync policy: Automated with prune and self-heal
- Projects: noctel-dev, noctel-qa, noctel-prod
- Applications: Individual apps per service

### MetalLB

**Purpose**: Load balancer for bare metal Kubernetes

**Architecture**:
```
┌─────────────────────────────────────────────────────┐
│                  MetalLB System                     │
│                                                      │
│  ┌──────────────────┐       ┌──────────────────┐   │
│  │   Controller     │       │    Speakers      │   │
│  │   (1 replica)    │       │  (per node)      │   │
│  │                  │       │                  │   │
│  │  - IP allocation │       │  - ARP/NDP       │   │
│  │  - Pool mgmt     │       │  - L2 announce   │   │
│  └──────────────────┘       └──────────────────┘   │
│                                                      │
│  ┌──────────────────────────────────────────────┐  │
│  │         IP Address Pools                     │  │
│  │  - dev-vlan-pool:   10.0.97.20-30           │  │
│  │  - qa-vlan-pool:    10.0.98.20-30           │  │
│  │  - prod-vlan-pool:  10.0.99.20-30           │  │
│  │  - mgmt-vlan-pool:  10.0.96.30-40           │  │
│  └──────────────────────────────────────────────┘  │
│                                                      │
│  ┌──────────────────────────────────────────────┐  │
│  │         L2 Advertisements                    │  │
│  │  - dev  on bond0.677                         │  │
│  │  - qa   on bond0.678                         │  │
│  │  - prod on bond0.679                         │  │
│  │  - mgmt on bond0.604                         │  │
│  └──────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

**Configuration**: Managed via Helm chart in manifests/metallb/ with cluster-specific IP pools.

## Deployment Flow

### Bootstrap New Cluster

```
1. Hardware Setup
   - Provision servers
   - Configure network (IPs, VLANs, bond interfaces)
   - Set hostnames (clustername-kserverN pattern)

2. Ansible Playbook Execution (via AWX)
   ├── 0-configure-network.yaml       # Network config, SSH keys
   ├── 1-prepare-nodes.yaml           # System prep, K3S uninstall
   ├── 2-install-k3s-server.yaml      # Control plane
   ├── 3-install-k3s-worker.yaml      # Worker nodes
   ├── 4-install-cilium.yaml          # CNI setup
   ├── 5-install-argocd.yaml          # ArgoCD installation
   └── 6-bootstrap-gitops.yaml        # Initial app deployment

3. Manual Configuration
   ├── Create Git repository SSH secret
   ├── Create Docker registry secrets
   ├── Configure kubectl context locally
   └── Access ArgoCD UI

4. Deploy Applications
   ├── Apply ArgoCD application manifests
   ├── Wait for sync (auto or manual)
   └── Verify all services healthy
```

### Application Update Flow

```
Developer                Git Repo              ArgoCD              Kubernetes
    │                       │                     │                     │
    │  1. Edit config       │                     │                     │
    │  (change version)     │                     │                     │
    │──────────────────────▶│                     │                     │
    │                       │                     │                     │
    │  2. Commit & push     │                     │                     │
    │──────────────────────▶│                     │                     │
    │                       │  3. Poll for        │                     │
    │                       │     changes (3min)  │                     │
    │                       │◀────────────────────│                     │
    │                       │                     │                     │
    │                       │  4. Fetch new       │                     │
    │                       │     commit          │                     │
    │                       │─────────────────────▶                     │
    │                       │                     │                     │
    │                       │  5. Render Helm     │                     │
    │                       │     templates       │                     │
    │                       │     (git + values)  │                     │
    │                       │                     │                     │
    │                       │  6. Compare with    │                     │
    │                       │     cluster state   │                     │
    │                       │                     │                     │
    │                       │  7. Apply diff      │                     │
    │                       │     (kubectl apply) │                     │
    │                       │                     │─────────────────────▶
    │                       │                     │  8. Rolling update  │
    │                       │                     │     (new pods)      │
    │                       │                     │                     │
    │                       │                     │  9. Health checks   │
    │                       │                     │                     │
    │  10. Verify in UI     │                     │                     │
    │◀──────────────────────┴─────────────────────┴─────────────────────┘
```

## Security Model

### Authentication and Authorization

```
┌─────────────────────────────────────────────────────────┐
│                   Security Layers                        │
│                                                          │
│  1. Cluster Access (kubectl)                            │
│     - X.509 client certificates                         │
│     - Stored in kubeconfig                              │
│     - Separate contexts per cluster                     │
│                                                          │
│  2. ArgoCD Access                                       │
│     - Username/password (admin)                         │
│     - RBAC roles and permissions                        │
│     - Project-based isolation (dev/qa/prod)             │
│                                                          │
│  3. Git Repository Access                               │
│     - SSH key authentication                            │
│     - Read-only for ArgoCD                              │
│     - Write access for developers (Bitbucket)           │
│                                                          │
│  4. Docker Registry Access                              │
│     - imagePullSecrets in each namespace                │
│     - Username/password for Docker Hub                  │
│                                                          │
│  5. Application Secrets                                 │
│     - Kubernetes secrets (not in Git)                   │
│     - Mounted as environment variables or files         │
│     - Encrypted at rest (etcd encryption)               │
│                                                          │
│  6. Network Policies                                    │
│     - Cilium network policies                           │
│     - Namespace isolation                               │
│     - Service-to-service restrictions                   │
└─────────────────────────────────────────────────────────┘
```

### Secrets Management

**Current Approach**:
- Secrets created manually via kubectl
- Not stored in Git repository
- Referenced in values files by name only

**Example**:
```yaml
# In values file (pdx1-dev-config.yaml)
global:
  imagePullSecrets:
    - name: dockerhub-secret  # Reference only, not actual secret

noctel-api:
  config:
    database:
      passwordSecret: postgres-password  # Reference to secret
```

**Future Enhancement**: Consider HashiCorp Vault or Sealed Secrets for better secrets management.

## Scaling Strategy

### Horizontal Pod Autoscaling (HPA)

HPA can be configured per service in values files:

```yaml
noctel-api:
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 10
    targetCPUUtilizationPercentage: 70
    targetMemoryUtilizationPercentage: 80
```

### Vertical Scaling

Resource requests and limits configured per environment:

```yaml
# Development (lower resources)
noctel-api:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

# Production (higher resources)
noctel-api:
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 2000m
      memory: 4Gi
```

### Cluster Scaling

To add new nodes:

1. Provision hardware with matching network config
2. Set hostname following pattern: `{cluster}-kserver{N}` or `{cluster}-kworker{N}`
3. Add to Ansible inventory
4. Run playbooks 0-3 (network, prepare, k3s)
5. Node automatically joins cluster

### Adding New Clusters

To add a new cluster (e.g., man1):

1. **Create cluster directory structure**:
   ```
   argocd-applications/man1/
   ├── dev/
   ├── qa/
   └── prod/

   environments/man1/
   ├── man1-dev-config.yaml
   ├── man1-qa-config.yaml
   ├── man1-prod-config.yaml
   └── man1-metallb-config.yaml
   ```

2. **Copy and customize configs** from existing cluster (pdx1 or pdx2)

3. **Update network-specific values**:
   - IP addresses
   - Domain names (man1-dev.telnoc.com)
   - VLAN interfaces (if applicable)
   - MetalLB IP pools

4. **Bootstrap cluster** using Ansible playbooks

5. **Deploy applications** via ArgoCD

Time to add new cluster: ~4-8 hours (mostly Ansible execution)

## Design Patterns and Best Practices

### GitOps Principles Followed

1. **Declarative**: All configuration defined in YAML
2. **Versioned**: Everything in Git with full history
3. **Immutable**: Deployments via Git commits, not manual changes
4. **Automated**: ArgoCD handles reconciliation automatically
5. **Auditable**: Git log provides complete audit trail

### Separation of Concerns

```
┌─────────────────────────────────────────────────┐
│              What vs Where vs How               │
│                                                  │
│  WHAT to deploy:                                │
│  - manifests/ (Helm charts)                     │
│  - Defines service structure                    │
│  - Shared across all clusters                   │
│                                                  │
│  WHERE to deploy:                               │
│  - argocd-applications/ (per cluster/env)       │
│  - Defines which apps in which cluster          │
│  - References both what and how                 │
│                                                  │
│  HOW to configure:                              │
│  - environments/ (values files)                 │
│  - Cluster and environment-specific values      │
│  - Network config, scaling, versions            │
└─────────────────────────────────────────────────┘
```

### Configuration DRY Principle

**Good**: Configuration in values files
```yaml
# environments/pdx1/pdx1-dev-config.yaml
noctel-api:
  version: "v2.7.55"
  replicaCount: 3
```

**Bad**: Duplicating configuration in chart
```yaml
# manifests/noctel-api/values.yaml (avoid this)
version: "v2.7.55"  # Don't hardcode environment-specific values
replicaCount: 3     # in the chart
```

### Testing Strategy

1. **Local Helm rendering**:
   ```bash
   helm template ./manifests/noctel-api -f environments/pdx1/pdx1-dev-config.yaml
   ```

2. **Deploy to dev first**: Always test in dev environment

3. **Promote through environments**: dev → qa → prod

4. **Monitor each stage**: Check logs, metrics, health checks

5. **Rollback capability**: Keep previous version tags for quick rollback

## Monitoring and Observability

### Current State
- Application logs: kubectl logs
- Cilium Hubble: Network observability (optional)
- ArgoCD UI: Deployment status

### Future Enhancements
- Prometheus: Metrics collection
- Grafana: Metrics visualization
- Loki: Log aggregation
- Alertmanager: Alert routing

### Health Checks

Each service should implement:
- **Liveness probe**: Is the service alive?
- **Readiness probe**: Is the service ready for traffic?
- **Startup probe**: Has the service started successfully?

Example configuration:
```yaml
noctel-api:
  livenessProbe:
    httpGet:
      path: /health
      port: 4000
    initialDelaySeconds: 30
    periodSeconds: 10
  readinessProbe:
    httpGet:
      path: /ready
      port: 4000
    initialDelaySeconds: 10
    periodSeconds: 5
```

## Disaster Recovery

### Backup Strategy

**What to backup**:
1. Git repository (primary source of truth)
2. Persistent volumes (database data, file storage)
3. Kubernetes secrets
4. etcd snapshots (K3S control plane state)

**What NOT to backup**:
- Pod state (ephemeral, recreated from Git)
- Application deployment state (managed by ArgoCD)

### Recovery Procedure

To rebuild a cluster from scratch:

1. **Provision hardware** with same network configuration
2. **Run Ansible playbooks** to bootstrap cluster
3. **Restore secrets** from backup or create new
4. **Deploy applications** via ArgoCD (reads from Git)
5. **Restore persistent data** from backups

**Recovery Time Objective (RTO)**: 4-8 hours
**Recovery Point Objective (RPO)**: Depends on backup frequency

## Future Architecture Considerations

### Multi-Cluster Service Mesh
- Istio or Linkerd for service-to-service communication
- Cross-cluster service discovery
- Advanced traffic management

### External Secrets Management
- HashiCorp Vault integration
- Sealed Secrets for GitOps-friendly secrets
- Automatic secret rotation

### Progressive Delivery
- Argo Rollouts for canary and blue-green deployments
- Automated rollback based on metrics
- Traffic splitting and analysis

### Centralized Monitoring
- Prometheus Federation across clusters
- Thanos for long-term metrics storage
- Unified Grafana dashboards

### Backup Automation
- Velero for cluster-wide backups
- Automated snapshot schedules
- Cross-region backup replication

## Conclusion

This architecture provides:
- **Scalability**: Easy to add clusters and nodes
- **Reliability**: GitOps ensures consistent, recoverable state
- **Maintainability**: Clear separation of concerns
- **Security**: Multiple layers of authentication and authorization
- **Observability**: Comprehensive visibility into deployments

The multi-cluster design allows independent operation while maintaining consistency through shared Helm charts and GitOps practices.
