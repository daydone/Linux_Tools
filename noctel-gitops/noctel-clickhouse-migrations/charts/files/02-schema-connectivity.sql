-- Connectivity statistics = device RTT, tiered in ClickHouse.
-- Applied within the noctel-api-trace database (USE <db> by the bootstrap).
-- Idempotent (CREATE ... IF NOT EXISTS).
--
-- Decisions (Cory, 2026-06-24):
--   * Connectivity IS RTT.
--   * Correct percentiles via MERGEABLE t-digest states (quantilesTDigest),
--     so p50/p95 are exact at every tier (you can't average pre-computed p95s).
--   * Tiers: 1m (start), 1d, 1w. NO 1h yet (add later under load).
--   * Scale: ~15k devices now, ~1M eventual.
--
-- Pipeline: the SBC RTT collector inserts ONE simple raw row per probe into
-- device_rtt_raw (no t-digest math in the collector). Materialized views build
-- the per-tier aggregate-state tables; t-digest states merge across insert
-- blocks, so day/week percentiles are computed over ALL of that period's
-- samples, not over pre-rolled numbers.
--
-- Read: p50/p95 = quantilesTDigestMerge(0.5,0.95)(rtt_q); min/max read directly
--       (SimpleAggregateFunction); uptime = reachable_sum / samples.

-- ─── raw probe samples (plumbing for the MVs; very short TTL) ─────────────
-- One row per RTT probe. rtt_us only meaningful when reachable=1.
CREATE TABLE IF NOT EXISTS device_rtt_raw (
    dt              DateTime,
    fk_account_uuid String,
    fk_tenant_uuid  String,
    device_uuid     String,
    node            LowCardinality(String),
    rtt_us          UInt32,
    reachable       UInt8
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(dt)
ORDER BY (fk_account_uuid, fk_tenant_uuid, device_uuid, dt)
TTL dt + INTERVAL 3 HOUR;        -- raise this knob if we want longer raw under load

-- ─── tier tables (AggregatingMergeTree, mergeable states) ───────────────
-- Shared column shape across 1m / 1d / 1w; only the bucket + partition + TTL
-- differ. quantilesTDigest levels (0.5, 0.95) are fixed in the column type.
CREATE TABLE IF NOT EXISTS device_rtt_1m (
    dt              DateTime,                                            -- toStartOfMinute
    fk_account_uuid String,
    fk_tenant_uuid  String,
    device_uuid     String,
    node            LowCardinality(String),
    rtt_q           AggregateFunction(quantilesTDigest(0.5, 0.95), UInt32),
    rtt_min_us      SimpleAggregateFunction(min, UInt32),
    rtt_max_us      SimpleAggregateFunction(max, UInt32),
    samples         SimpleAggregateFunction(sum, UInt64),
    reachable_sum   SimpleAggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMMDD(dt)
ORDER BY (fk_account_uuid, fk_tenant_uuid, device_uuid, node, dt)
TTL dt + INTERVAL 7 DAY;

CREATE TABLE IF NOT EXISTS device_rtt_1d (
    dt              DateTime,                                            -- toStartOfDay
    fk_account_uuid String,
    fk_tenant_uuid  String,
    device_uuid     String,
    node            LowCardinality(String),
    rtt_q           AggregateFunction(quantilesTDigest(0.5, 0.95), UInt32),
    rtt_min_us      SimpleAggregateFunction(min, UInt32),
    rtt_max_us      SimpleAggregateFunction(max, UInt32),
    samples         SimpleAggregateFunction(sum, UInt64),
    reachable_sum   SimpleAggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(dt)
ORDER BY (fk_account_uuid, fk_tenant_uuid, device_uuid, node, dt)
TTL dt + INTERVAL 1000 DAY;        -- ~2.7y of daily resolution

CREATE TABLE IF NOT EXISTS device_rtt_1w (
    dt              DateTime,                                            -- toStartOfWeek (Monday)
    fk_account_uuid String,
    fk_tenant_uuid  String,
    device_uuid     String,
    node            LowCardinality(String),
    rtt_q           AggregateFunction(quantilesTDigest(0.5, 0.95), UInt32),
    rtt_min_us      SimpleAggregateFunction(min, UInt32),
    rtt_max_us      SimpleAggregateFunction(max, UInt32),
    samples         SimpleAggregateFunction(sum, UInt64),
    reachable_sum   SimpleAggregateFunction(sum, UInt64)
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(dt)
ORDER BY (fk_account_uuid, fk_tenant_uuid, device_uuid, node, dt)
TTL dt + INTERVAL 3650 DAY;        -- ~10y of weekly resolution (true multi-year)

-- ─── rollup MVs: raw → each tier (no cascade) ────────────────────────────
-- Each MV buckets raw insert blocks to its resolution and emits mergeable
-- states. AggregatingMergeTree merges partial states across blocks, so even
-- though raw is dropped at 3h, the 1d/1w states are complete over the whole
-- period. Percentiles include only reachable probes (the -If combinator).
CREATE MATERIALIZED VIEW IF NOT EXISTS device_rtt_1m_mv TO device_rtt_1m AS
SELECT
    toStartOfMinute(dt) AS dt,
    fk_account_uuid, fk_tenant_uuid, device_uuid, node,
    quantilesTDigestStateIf(0.5, 0.95)(rtt_us, reachable = 1) AS rtt_q,
    minIf(rtt_us, reachable = 1) AS rtt_min_us,
    maxIf(rtt_us, reachable = 1) AS rtt_max_us,
    count()        AS samples,
    sum(reachable) AS reachable_sum
FROM device_rtt_raw
GROUP BY dt, fk_account_uuid, fk_tenant_uuid, device_uuid, node;

CREATE MATERIALIZED VIEW IF NOT EXISTS device_rtt_1d_mv TO device_rtt_1d AS
SELECT
    toStartOfDay(dt) AS dt,
    fk_account_uuid, fk_tenant_uuid, device_uuid, node,
    quantilesTDigestStateIf(0.5, 0.95)(rtt_us, reachable = 1) AS rtt_q,
    minIf(rtt_us, reachable = 1) AS rtt_min_us,
    maxIf(rtt_us, reachable = 1) AS rtt_max_us,
    count()        AS samples,
    sum(reachable) AS reachable_sum
FROM device_rtt_raw
GROUP BY dt, fk_account_uuid, fk_tenant_uuid, device_uuid, node;

CREATE MATERIALIZED VIEW IF NOT EXISTS device_rtt_1w_mv TO device_rtt_1w AS
SELECT
    toStartOfWeek(dt, 1) AS dt,
    fk_account_uuid, fk_tenant_uuid, device_uuid, node,
    quantilesTDigestStateIf(0.5, 0.95)(rtt_us, reachable = 1) AS rtt_q,
    minIf(rtt_us, reachable = 1) AS rtt_min_us,
    maxIf(rtt_us, reachable = 1) AS rtt_max_us,
    count()        AS samples,
    sum(reachable) AS reachable_sum
FROM device_rtt_raw
GROUP BY dt, fk_account_uuid, fk_tenant_uuid, device_uuid, node;
