# Jenkins Configuration

## PDX2 Jenkins

Jenkins is deployed on pdx2 cluster for CI/CD pipelines.

### Issue: IPv4 DNS Resolution

Jenkins fails to build because pdx2 CoreDNS returns IPv6-only for bitbucket.org, but Jenkins git can't connect over IPv6.

**Fix**: Added init container to StatefulSet that creates `.gitconfig` with HTTP/1.1 preference and git url rewrite.

### Files
- `pdx2/statefulset.yaml` - Jenkins StatefulSet with git IPv4 config init container

### To deploy
```bash
kubectl apply -f pdx2/
```

### Known Issues
- CoreDNS in pdx2 returns IPv6-only for external hosts
- Git fails on IPv6 connections
- Workaround: Force IPv4 via git config
