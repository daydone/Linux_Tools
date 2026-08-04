-- noctel_trace_local schema bootstrap.
--
-- Mirrors the per-region database layout from the plan
-- (/Users/corys/.claude/plans/cryptic-doodling-adleman.md §2):
--   - calls          one stitched call summary, mutable rows
--   - events         normalized timeline (INVITE / 180 / 200 / first_rtp / BYE / ...)
--   - messages       raw SIP per call (highest churn, shortest TTL)
--   - media_streams  per-stream RTP/RTCP stats from rtpengine
--
-- For local dev TTLs are tiny so the disk doesn't fill up; prod
-- defaults are 90d (messages) / 2y (calls + events + media_streams).
--
-- Idempotent — CREATE TABLE IF NOT EXISTS so you can re-run the
-- bootstrap script during schema iteration without dropping.

CREATE DATABASE IF NOT EXISTS noctel_trace_local;

-- Reader role for noctel-api-trace (CLICKHOUSE_USER=noctel_reader /
-- CLICKHOUSE_PASSWORD=readeronly per the dev README). Idempotent.
CREATE USER IF NOT EXISTS noctel_reader IDENTIFIED WITH plaintext_password BY 'readeronly';
GRANT SELECT ON noctel_trace_local.* TO noctel_reader;

USE noctel_trace_local;

-- ─── calls ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS calls (
    call_corr_uuid   String,
    call_id_a        String,
    call_id_b        String,
    account_uuid     String,
    from_e164        String,
    to_e164          String,
    direction        LowCardinality(String),       -- 'inbound' | 'outbound'
    ingress_carrier  LowCardinality(String),
    egress_carrier   LowCardinality(String),
    route_path       String,
    final_state      LowCardinality(String),       -- 'normal' | 'failed' | '' (live)
    dt_started       DateTime64(3),
    dt_answered      Nullable(DateTime64(3)),
    dt_ended         Nullable(DateTime64(3)),
    pdd_ms           Nullable(UInt32),
    duration_ms      Nullable(UInt32),
    media_health     LowCardinality(String),       -- ok|one_way|no_media|jitter|loss|''
    asterisk_host    LowCardinality(String),
    sbc_host         LowCardinality(String),
    csr_touched      UInt8 DEFAULT 0
)
ENGINE = ReplacingMergeTree(dt_started)
PARTITION BY toYYYYMM(dt_started)
ORDER BY (call_corr_uuid)
TTL toDateTime(dt_started) + INTERVAL 30 DAY;

-- ─── events ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS events (
    call_corr_uuid   String,
    dt_event         DateTime64(3),
    event_type       LowCardinality(String),
    host             LowCardinality(String),
    direction        LowCardinality(String),       -- 'in' | 'out'
    status_code      Nullable(UInt16),
    payload          String                        -- free-form JSON; the assembler stuffs per-event extras here
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(dt_event)
ORDER BY (call_corr_uuid, dt_event)
TTL toDateTime(dt_event) + INTERVAL 30 DAY;

-- ─── messages ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS messages (
    call_corr_uuid   String,
    dt_msg           DateTime64(3),
    src_ip           IPv4,
    dst_ip           IPv4,
    transport        LowCardinality(String),       -- udp|tcp|tls
    method_or_code   LowCardinality(String),       -- 'INVITE' | '200' | ...
    raw_msg          String CODEC(ZSTD(3))         -- big but very compressible
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(dt_msg)
ORDER BY (call_corr_uuid, dt_msg)
TTL toDateTime(dt_msg) + INTERVAL 7 DAY;

-- ─── media_streams ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS media_streams (
    call_corr_uuid   String,
    ssrc             String,
    codec            LowCardinality(String),
    direction        LowCardinality(String),       -- a_to_b | b_to_a
    dt_started       DateTime64(3),
    dt_ended         Nullable(DateTime64(3)),
    packets          UInt64,
    jitter_avg_ms    Float32,
    loss_pct         Float32,
    mos_avg          Float32
)
ENGINE = ReplacingMergeTree(dt_started)
PARTITION BY toYYYYMM(dt_started)
ORDER BY (call_corr_uuid, ssrc)
TTL toDateTime(dt_started) + INTERVAL 30 DAY;

-- Helpful indexes for the api-trace query shapes.
ALTER TABLE calls
    ADD INDEX IF NOT EXISTS idx_calls_account     account_uuid    TYPE bloom_filter GRANULARITY 4,
    ADD INDEX IF NOT EXISTS idx_calls_dt_started  dt_started      TYPE minmax       GRANULARITY 4,
    ADD INDEX IF NOT EXISTS idx_calls_final_state final_state     TYPE set(0)       GRANULARITY 4;

ALTER TABLE events
    ADD INDEX IF NOT EXISTS idx_events_account_time (call_corr_uuid, dt_event) TYPE minmax GRANULARITY 4;
