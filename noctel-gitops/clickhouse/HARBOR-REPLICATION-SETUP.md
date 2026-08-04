# Harbor Replication Setup for ClickHouse

## Harbor Replication Rule Configuration

**Configure this rule in Harbor UI** (`pdx-harbor.telnoc.com` → Administration → Registries → Replication Rules)

### Rule Details

| Setting | Value |
|---------|-------|
| **Rule Name** | `clickhouse-docker-to-noctel` |
| **Source Registry** | `Docker Hub` (or create if not exists: `https://registry-1.docker.io`) |
| **Source Namespace** | `clickhouse` |
| **Destination Registry** | `Local` |
| **Destination Namespace** | `noctel/clickhouse` |
| **Resource Filter (Artifact type)** | `Image` |
| **Name Filter** | `clickhouse-server` |
| **Tag Filter** | `^(latest\|[0-9]+\.[0-9]+\.[0-9]+)$` (replicate latest + semantic versions) |
| **Deletion** | Unchecked (keep old images) |
| **Overwrite** | Checked (allow re-sync if upstream updates) |
| **Enable** | ✓ Checked |
| **Trigger** | `Manual` or `Scheduled` (recommend scheduled daily) |

### Expected Result

After replication completes, you'll have images at:
```
pdx-harbor.telnoc.com/noctel/clickhouse/clickhouse-server:24.3.1
pdx-harbor.telnoc.com/noctel/clickhouse/clickhouse-server:24.4.1
pdx-harbor.telnoc.com/noctel/clickhouse/clickhouse-server:latest
```

### In K3S Manifests

Reference the replicated image as:
```yaml
image: pdx-harbor.telnoc.com/noctel/clickhouse/clickhouse-server:24.4.1
imagePullSecrets:
  - name: harbor-pull
```

---

## Alternative: If Docker Hub Source Registry Not Available

If Harbor doesn't have Docker Hub configured yet:

1. Go to Harbor → Administration → Registries
2. Click "+ New Endpoint"
3. Configure:
   - **Provider:** `Docker Hub`
   - **Name:** `Docker Hub` (or `docker-hub`)
   - **URL:** `https://registry-1.docker.io`
   - **Username/Password:** Leave blank (public access)
4. Click "Test Connection" → should succeed
5. Then create the replication rule above
