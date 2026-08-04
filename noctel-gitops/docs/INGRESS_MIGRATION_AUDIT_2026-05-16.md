# Ingress Migration Audit — 2026-05-16

Task #66. Inventory of every Ingress resource in the pdx1 cluster
plus its gitops status, so the hand-applied ones can be brought under
ArgoCD without breaking traffic.

## Method

```
kubectl get ingress -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}\t{.metadata.labels.app\.kubernetes\.io/instance}\n{end}'
```

The `app.kubernetes.io/instance` label is ArgoCD's tracking label.
Empty = hand-applied (or applied by a controller that doesn't tag).

## Result — 32 ingresses

### Already gitops-tracked (19)

| Ingress | ArgoCD instance |
|---|---|
| dev/dev-filer-ingress | seaweedfs-dev |
| dev/noctel-notify | noctel-notify-dev |
| monitoring/kube-prometheus-stack-pdx1-alertmanager | kube-prometheus-stack-pdx1 |
| monitoring/kube-prometheus-stack-pdx1-grafana | kube-prometheus-stack-pdx1 |
| monitoring/kube-prometheus-stack-pdx1-prometheus | kube-prometheus-stack-pdx1 |
| prod/noctel-desk-ingress | pdx1-prod-networking |
| prod/noctel-fax-in | noctel-fax-in-prod |
| prod/noctel-fax-out | noctel-fax-out-prod |
| prod/noctel-notify | noctel-notify-prod |
| prod/prod-api-ingress | pdx1-prod-networking |
| prod/prod-display-ingress | pdx1-prod-networking |
| prod/prod-filer-ingress | seaweedfs-prod |
| prod/prod-lns-ingress | pdx1-prod-networking |
| prod/prod-s3-ingress | pdx1-prod-networking |
| qa/noctel-notify | noctel-notify-qa |
| qa/qa-display-ingress | pdx1-qa-networking |
| qa/qa-filer-ingress | seaweedfs-qa |
| qa/qa-lns-ingress | pdx1-qa-networking |
| qa/qa-s3-ingress | pdx1-qa-networking |

### Hand-applied — needs action (13)

| Ingress | Recommended action | Notes |
|---|---|---|
| argocd/argocd-server-ingress | **Migrate** | Bootstraps Argo itself. Carve into a dedicated app or place under `networking/pdx1/management/`. Order matters: don't have Argo try to manage its own ingress without a safe adoption. |
| dev/dev-api-ingress | **Migrate** | Add to `pdx1-dev-networking` app, mirror prod-api shape. |
| dev/dev-display-ingress | **Migrate** | Same Argo app. |
| dev/dev-lns-ingress | **Delete OR migrate (LNS rename pending)** | Blocked on task #56 (drop LNS naming). If LNS service is being renamed, fix the name during migration. |
| dev/dev-s3-ingress | **Migrate** | Same Argo app. |
| jenkins/jenkins-ingress | **Migrate** | Jenkins lives outside the platform apps; consider a `jenkins-networking` app. |
| prod/acme-challenge-solver | **Skip (cert-manager managed)** | Created dynamically by cert-manager during HTTP-01 challenges, deleted after. Not a stable resource. |
| prod/api-noctel-ingress | **Delete (superseded)** | Old `-noctel-` naming. `prod/prod-api-ingress` is the current one. Verify host overlap then `kubectl delete`. |
| prod/display-noctel-ingress | **Delete (superseded)** | Same as above; `prod/prod-display-ingress` is current. |
| prod/portal-noctel-ingress | **Migrate or delete** | If `prod/prod-portal-ingress` covers the same hosts, delete. Otherwise migrate as a new file. |
| prod/prod-ape-ingress | **Migrate** | Add to `pdx1-prod-networking`. |
| prod/prod-portal-ingress | **Migrate** | Add to `pdx1-prod-networking`. |
| qa/pdx1-qa-api-gateway-ingress | **Migrate** | Add to `pdx1-qa-networking`. |

## Safe migration procedure (per ingress)

1. Dump live YAML, strip server-managed fields:

   ```
   kubectl get ingress -n <ns> <name> -o yaml \
     | yq 'del(.metadata.creationTimestamp,
                .metadata.resourceVersion,
                .metadata.uid,
                .metadata.generation,
                .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration",
                .status)' \
     > networking/pdx1/<env>/<name>.yaml
   ```

2. Add the file to the correct ArgoCD app's source path.
3. Sync the app with `--respect-ignore-differences=true` first — this
   makes Argo "adopt" the existing resource without diff-applying.
4. Once Argo reports Synced, switch back to normal sync.
5. Verify traffic stays up (TLS still valid, `curl -I https://<host>`
   returns the expected backend service version).

## Why not done in this audit

Adopting a live ingress into ArgoCD is normally safe, but if the
recorded gitops YAML drifts from the live spec by even one field
(class, TLS secret name, annotation), the next sync rewrites the
ingress and traffic flips. Each of these 13 deserves a one-at-a-time
review + `kubectl diff` before commit, not a batch script.

## Related tasks

- #56 — LNS naming sweep. Migrating `dev-lns-ingress` should land
  in the same PR as the service rename so the names match.
