# noctel-clickhouse-migrations

Helm chart + ArgoCD-driven Job that creates / maintains the
`noctel_trace_<env>` ClickHouse schema (the database that
`noctel-worker-indexer/src/generic/clickhouse-sink.js` and
`noctel-api-trace` read/write).

## Layout

```
noctel-clickhouse-migrations/
  charts/
    Chart.yaml
    values.yaml
    files/
      01-schema.sql              # mirrors noctel-api-trace/dev/schema.sql
      02-schema-connectivity.sql # mirrors noctel-api-trace/dev/schema-connectivity.sql
    templates/
      _helpers.tpl
      configmap-schema.yaml      # mounts SQL + apply.sh into the Job
      job-migrate.yaml           # ArgoCD PreSync Job; runs clickhouse-client
  environments/
    pdx1-dev-values.yaml
    pdx1-qa-values.yaml
    pdx1-prod-values.yaml
    pdx2-dev-values.yaml
    pdx2-qa-values.yaml
    pdx2-prod-values.yaml
```

ArgoCD Applications wiring (one per env + cluster) live at:
`argocd-applications/{pdx1,pdx2}/{dev,qa,prod}/<env>-clickhouse-migrations.yaml`

## How it works

The Job mounts the SQL files as a ConfigMap and runs `apply.sh`, which
`sed`-rewrites the dev placeholder `noctel_trace_local` to the
env-target db (`noctel_trace_dev|qa|prod`) and pipes each file through
`clickhouse-client --multiquery`.

Every statement uses `CREATE … IF NOT EXISTS` (or `ADD INDEX IF NOT EXISTS`),
so the Job is idempotent — re-applying is a no-op.

The Job name embeds a SHA of `files/*.sql`, so any schema change spawns
a fresh Job (Kubernetes Jobs are immutable). Argo's `PreSync` hook +
`BeforeHookCreation` delete-policy keeps history clean.

## Manually re-applying (operator runbook)

```bash
# 1. From inside the env namespace (dev|qa|prod):
kubectl -n dev get job -l app.kubernetes.io/name=noctel-clickhouse-migrations

# 2. To re-run on demand without bumping a SHA, delete + Argo sync:
kubectl -n dev delete job -l app.kubernetes.io/name=noctel-clickhouse-migrations
argocd app sync noctel-clickhouse-migrations-dev

# 3. Verify post-sync (run from any pod with clickhouse-client OR via the operator pod):
clickhouse-client \
  --host clickhouse-clickstack-clickhouse.clickhouse.svc.cluster.local \
  --port 9000 --user default --password "$CLICKHOUSE_DEFAULT_PASSWORD" \
  --query "SELECT database, name FROM system.tables WHERE database LIKE 'noctel_trace%' ORDER BY database, name"
```

Expected tables per database (`messages`, `calls`, `events`,
`media_streams`, `device_rtt_raw`, `device_rtt_1m`, `device_rtt_1d`,
`device_rtt_1w`, `device_rtt_1m_mv`, `device_rtt_1d_mv`,
`device_rtt_1w_mv`).

## Adding a new table

1. Add the `CREATE TABLE IF NOT EXISTS …` statement to the appropriate
   `files/*.sql` file (or add a new `03-…sql` — `apply.sh` runs them in
   `ls | sort` order).
2. Mirror the same change into
   `noctel-api-trace/dev/schema.sql` (or `schema-connectivity.sql`) so
   `dev/bootstrap-schema.sh` stays in sync for local docker-compose.
3. Commit; ArgoCD picks up the change, the Job name SHA flips, and a
   fresh Job applies on next sync.

## Rolling a schema change

ClickHouse DDL is **not transactional** — half-applied changes do not
roll back. Order changes so the system is correct after each statement
in isolation:

1. **Adding a column / index / table:** safe — append a new
   `ALTER TABLE … ADD COLUMN IF NOT EXISTS …` or
   `CREATE TABLE IF NOT EXISTS …` statement.
2. **Renaming a column:** add the new column first, deploy a writer that
   double-writes, backfill, then drop the old column in a separate PR.
   Never rename in place.
3. **Changing a column type:** add a parallel column with the new type,
   migrate readers/writers, drop the old. In-place type changes can
   rewrite the entire table.
4. **Dropping a table:** put the `DROP TABLE IF EXISTS` in a separate
   numbered file (`99-drop-foo.sql`) **after** all readers/writers have
   been deployed without references.
5. **Materialized views:** drop + recreate the MV before changing its
   target table's schema; MVs do not auto-pick up target schema changes.

For any non-additive change, run the change against `dev` first, verify
sample inserts succeed, then promote to `qa` and `prod` via the same
chart.

## Relationship to `noctel-api-trace/dev/`

The chart's `files/*.sql` are intentional copies of
`noctel-api-trace/dev/schema*.sql`. The dev files remain the developer
ergonomics path (`dev/bootstrap-schema.sh` + docker-compose). Keep
them byte-equivalent on schema changes; the `sed` rewrite in
`apply.sh` is the only difference (dev hard-codes `noctel_trace_local`).
