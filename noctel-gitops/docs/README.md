# Noctel GitOps Repository

This repository contains the GitOps configuration for all Noctel services across multiple clusters (pdx1, pdx2) and environments (dev, qa, prod).

## Repository Structure

```
noctel-gitops/
├── argocd-applications/      # ArgoCD Application manifests (cluster-specific)
│   ├── pdx1/
│   │   ├── dev/              # pdx1 dev applications
│   │   ├── qa/               # pdx1 qa applications
│   │   └── prod/             # pdx1 prod applications
│   └── pdx2/
│       ├── dev/              # pdx2 dev applications
│       ├── qa/               # pdx2 qa applications
│       └── prod/             # pdx2 prod applications
├── environments/             # Cluster and environment-specific configuration values
│   ├── pdx1/
│   │   ├── pdx1-dev-config.yaml        # pdx1 dev configuration (513 lines)
│   │   ├── pdx1-qa-config.yaml         # pdx1 qa configuration (570 lines)
│   │   ├── pdx1-prod-config.yaml       # pdx1 prod configuration (84 lines - needs expansion)
│   │   └── pdx1-metallb-config.yaml    # pdx1 MetalLB IP pools (to be created)
│   └── pdx2/
│       ├── pdx2-dev-config.yaml        # pdx2 dev configuration (513 lines)
│       ├── pdx2-qa-config.yaml         # pdx2 qa configuration (570 lines)
│       ├── pdx2-prod-config.yaml       # pdx2 prod configuration (84 lines - needs expansion)
│       └── pdx2-metallb-config.yaml    # pdx2 MetalLB IP pools and VLANs
├── manifests/                # Helm charts for all services
│   ├── noctel-api/
│   ├── noctel-ui/
│   ├── noctel-lns/
│   ├── noctel-ape/
│   ├── noctel-display/
│   ├── noctel-migrate/
│   ├── chirpstack-core/
│   ├── chirpstack-gateway-bridge/
│   ├── chirpstack-mosquitto/
│   ├── traefik/
│   ├── redis/
│   ├── rabbitmq/
│   ├── elasticsearch/
│   ├── seaweedfs/
│   ├── nt-mq-mailer/
│   ├── noctel-aps/
│   └── metallb/              # MetalLB load balancer (infrastructure)
├── charts/                   # Copy of manifests/ (both exist for compatibility)
└── docs/                     # Additional documentation
    ├── README.md
    ├── ARCHITECTURE.md
    ├── ROLLBACK-PROCEDURE.md
    ├── KEYDB-MULTI-CLUSTER.md
    ├── MULTI-VLAN-ISSUE.md
    └── MULTI-VLAN-SOLUTION-OPTIONS.md
```

## Multi-Cluster Architecture

This repository supports multiple Kubernetes clusters with cluster-specific configurations:

### Clusters
- **pdx1**: Primary production cluster (10.0.95.x network)
  - 5 server nodes (pdx1-kserver0 through pdx1-kserver4)
  - 2 worker nodes (pdx1-kworker0, pdx1-kworker1)
  - K3S v1.28.5+k3s1
  - Cilium CNI v1.16.5

- **pdx2**: Secondary production cluster (10.0.96.x, 10.0.97.x, 10.0.98.x, 10.0.99.x networks)
  - Multiple VLANs for network segregation
  - MetalLB with L2 advertisement on bond0 interfaces

### Environments per Cluster
- **dev**: Development environment (namespace: dev)
- **qa**: Quality Assurance environment (namespace: qa)
- **prod**: Production environment (namespace: prod)

## How ArgoCD Applications Work

Each ArgoCD application manifest references:
1. A Helm chart in `charts/` or `manifests/`
2. A cluster-specific values file in `environments/{cluster}/`

Example (`argocd-applications/pdx1/dev/dev-noctel-api.yaml`):
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: noctel-api-dev
  namespace: argocd
spec:
  project: noctel-dev
  source:
    repoURL: git@bitbucket.org:noctel-bitbucket/noctel-gitops.git
    targetRevision: HEAD
    path: charts/noctel-api
    helm:
      valueFiles:
        - ../../environments/pdx1/pdx1-dev-config.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## Quick Start - Deploying to a New Cluster

### 1. Bootstrap Cluster with Ansible
```bash
# From AWX server or control node
ansible-playbook -i inventory/pdx1-hosts.yaml \
  0-configure-network.yaml \
  1-prepare-nodes.yaml \
  2-install-k3s-server.yaml \
  3-install-k3s-worker.yaml \
  4-install-cilium.yaml \
  5-install-argocd.yaml \
  6-bootstrap-gitops.yaml
```

### 2. Configure kubectl Context
```bash
# Copy kubeconfig from cluster
scp finbar.day@10.0.95.30:/etc/rancher/k3s/k3s.yaml ~/.kube/pdx1-config

# Merge into main config
KUBECONFIG=~/.kube/config:~/.kube/pdx1-config kubectl config view --flatten > ~/.kube/merged
mv ~/.kube/merged ~/.kube/config

# Test access
kubectl --context pdx1-cluster get nodes
```

### 3. Create Repository Authentication Secret
```bash
# ArgoCD needs SSH key to clone the GitOps repo
kubectl --context pdx1-cluster create secret generic noctel-gitops-repo \
  --from-literal=type=git \
  --from-literal=url='git@bitbucket.org:noctel-bitbucket/noctel-gitops.git' \
  --from-file=sshPrivateKey=/path/to/ssh-key \
  --from-literal=name=noctel-gitops \
  -n argocd

# Label it so ArgoCD recognizes it
kubectl --context pdx1-cluster label secret noctel-gitops-repo \
  argocd.argoproj.io/secret-type=repository -n argocd
```

### 4. Create Docker Registry Secrets
```bash
# Create dockerhub-secret in each namespace
for ns in dev qa prod; do
  kubectl --context pdx1-cluster create secret docker-registry dockerhub-secret \
    --docker-server=index.docker.io/v1/ \
    --docker-username=noctel \
    --docker-password=<password> \
    -n $ns
done
```

### 5. Deploy Applications via ArgoCD
```bash
# Deploy all dev applications
kubectl --context pdx1-cluster apply -f argocd-applications/pdx1/dev/

# Deploy all qa applications
kubectl --context pdx1-cluster apply -f argocd-applications/pdx1/qa/

# Deploy all prod applications
kubectl --context pdx1-cluster apply -f argocd-applications/pdx1/prod/
```

### 6. Access ArgoCD UI
```bash
# Port forward from cluster
ssh -L 8080:localhost:8080 finbar.day@10.0.95.30 \
  "sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl port-forward svc/argocd-server -n argocd 8080:443"

# Get admin password
kubectl --context pdx1-cluster get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d

# Access UI
open https://localhost:8080
```

## Common Operations

### Deploy New Version
1. Edit the appropriate config file (e.g., `environments/pdx1/pdx1-dev-config.yaml`)
2. Update the version:
   ```yaml
   noctel-api:
     version: "v2.7.55"  # Change this
   ```
3. Commit and push
4. ArgoCD auto-syncs within 3 minutes (or force sync via UI)

### Scale Service
1. Edit config file (e.g., `environments/pdx1/pdx1-prod-config.yaml`)
2. Update replica count:
   ```yaml
   noctel-api:
     replicaCount: 5  # Increase from 3 to 5
   ```
3. Commit and push
4. ArgoCD applies changes automatically

### Add New Service to Cluster
1. Create Helm chart in `manifests/new-service/`
2. Add configuration to environment values files
3. Create ArgoCD application manifest in `argocd-applications/{cluster}/{env}/`
4. Apply the ArgoCD application manifest

### Promote from Dev to Prod
1. Test thoroughly in dev environment
2. Copy version from dev config to prod config
3. Commit and push
4. Monitor deployment in ArgoCD UI

## Infrastructure Components

### Cilium CNI
- Installed via Ansible playbook `4-install-cilium.yaml`
- Version: 1.16.5
- Features: VXLAN tunneling, network policies
- Cluster name set dynamically based on hostname prefix

### ArgoCD
- Installed via Ansible playbook `5-install-argocd.yaml`
- Version: Latest stable
- Repository: https://argoproj.github.io/argo-helm
- Access: Port forward to 8080

### MetalLB
- Load balancer for bare metal Kubernetes
- Manages IP address pools per environment
- L2 advertisement on specific VLAN interfaces
- Configured per cluster in `environments/{cluster}/{cluster}-metallb-config.yaml`

### Application Stack
- **noctel-api**: Main REST API service
- **noctel-ui**: Web user interface
- **noctel-lns**: LoRaWAN Network Server
- **noctel-ape**: Application Processing Engine
- **noctel-display**: Display service
- **noctel-migrate**: Database migration service
- **chirpstack-core**: ChirpStack LoRaWAN server
- **chirpstack-gateway-bridge**: Gateway bridge
- **chirpstack-mosquitto**: MQTT broker

### Infrastructure Services
- **traefik**: Ingress controller and reverse proxy
- **redis**: In-memory data store
- **keydb**: Multi-master distributed key-value store (see [KEYDB-MULTI-CLUSTER.md](KEYDB-MULTI-CLUSTER.md))
- **rabbitmq**: Message queue (ha-rabbit-server)
- **elasticsearch**: Search and analytics engine
- **seaweedfs**: Distributed file system
- **nt-mq-mailer**: Email service via RabbitMQ
- **noctel-aps**: Apple Push Notification service

## Current Status

### pdx1 Cluster
- **Dev**: 16 applications deployed (some degraded, needs investigation)
- **QA**: 16 applications deployed (some degraded, needs investigation)
- **Prod**: 16 applications deployed (many showing "Unknown" - incomplete config)

### pdx2 Cluster
- **Dev**: 17 applications (fully configured)
- **QA**: 17 applications (fully configured)
- **Prod**: 15 applications deployed via Helm (not yet migrated to ArgoCD)

## Known Issues

1. **Incomplete Prod Configurations**: pdx1-prod-config.yaml and pdx2-prod-config.yaml are only 84 lines (should be 513+ like dev/qa)
2. **Infrastructure Dependencies**: Some apps fail because infrastructure services (elasticsearch, redis, rabbitmq) aren't fully deployed
3. **Image Tags**: Some services using "latest" tag which may not exist or pull correctly
4. **QA Template Errors**: Some QA apps have nil pointer errors due to missing `global.namespace` in config

## Repository Authentication

This repository uses SSH authentication with Bitbucket:
- Repository URL: `git@bitbucket.org:noctel-bitbucket/noctel-gitops.git`
- SSH key required in ArgoCD repository secret
- Do not use HTTPS authentication

## GitOps Principles

1. **Git is the Source of Truth**: All changes must go through Git
2. **No Manual kubectl**: Never modify resources directly with kubectl in production
3. **No ArgoCD UI Parameter Overrides**: Don't use parameter overrides - update Git instead
4. **Test Before Prod**: Always test in dev, then qa, then prod
5. **Never Use 'latest' in Prod**: Always use specific version tags
6. **Commit Messages**: Clear messages explaining what changed and why

## Rollback Procedure

See `docs/ROLLBACK-PROCEDURE.md` for detailed rollback procedures.

Quick rollback:
```bash
# Revert the commit
git revert <commit-hash>
git push

# ArgoCD will auto-sync to previous state
# Or force sync via UI: SYNC > SYNCHRONIZE
```

## Related Repositories

- **noctel-ansible-playbooks**: Ansible playbooks for cluster bootstrap and management
  - Located at: `/root/noctel-ansible-playbooks/`
  - Contains K3S cluster setup playbooks

- **k3s-config**: Legacy Helm configuration (deprecated, migrated to noctel-gitops)
  - Contains original Helm charts and values files
  - Being phased out in favor of GitOps approach

## Troubleshooting

### Applications Stuck in "Unknown" Status
- Check if values file has complete configuration for the service
- Verify all required infrastructure services are running
- Check ArgoCD application logs

### ImagePullBackOff Errors
- Ensure dockerhub-secret exists in the namespace
- Verify image tag exists in Docker registry
- Check imagePullSecrets in pod spec

### Repository Authentication Failed
- Verify SSH key is correctly configured in ArgoCD secret
- Test SSH connection: `ssh -T git@bitbucket.org`
- Check repository URL is using SSH format (git@bitbucket.org:...)

### Sync Failures
- Check ArgoCD application events
- Verify Helm chart renders correctly: `helm template ./charts/service-name -f environments/pdx1/pdx1-dev-config.yaml`
- Review ArgoCD controller logs

## Contributing

1. Create feature branch from main
2. Make changes and test in dev environment
3. Create pull request with clear description
4. Wait for review and approval
5. Merge to main (triggers auto-deployment)

## Contact

For questions or issues, contact the infrastructure team or file an issue in this repository.
