-- Materialized staging tables for Adaptive Compute dashboard query optimization
--
-- PURPOSE: Pre-aggregate ACCOUNT_USAGE data hourly so the Streamlit app queries
-- local tables (sub-second) instead of scanning shared ACCOUNT_USAGE views (5-30s).
--
-- DEPLOYMENT: Run this script once. The TASK refreshes data every hour.
-- The Streamlit app auto-detects these tables and uses them when available.
--
-- REQUIREMENTS:
--   - ACCOUNTADMIN or role with IMPORTED PRIVILEGES on SNOWFLAKE database
--   - A warehouse for the refresh task (uses ~2-5 credits/day on XS)
--   - CREATE SCHEMA, CREATE TABLE, CREATE TASK privileges
-- ============================================================

-- 1. Create the staging schema
CREATE SCHEMA IF NOT EXISTS ADAPTIVE_METRICS
  COMMENT = 'Pre-aggregated metrics for the Adaptive Compute Streamlit dashboard';

USE SCHEMA ADAPTIVE_METRICS;

-- 2. Hourly metering (replaces repeated scans of WAREHOUSE_METERING_HISTORY)
CREATE OR REPLACE TABLE HOURLY_METERING (
    warehouse_name     VARCHAR(256) NOT NULL,
    hour_ts            TIMESTAMP_NTZ NOT NULL,
    credits            FLOAT NOT NULL,
    tag_cost_center    VARCHAR(256),
    _loaded_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
CLUSTER BY (hour_ts, warehouse_name)
COMMENT = 'Hourly credit aggregation per warehouse with optional cost center tag';

-- 3. Hourly query stats (replaces repeated scans of QUERY_HISTORY)
CREATE OR REPLACE TABLE HOURLY_QUERIES (
    warehouse_name         VARCHAR(256) NOT NULL,
    hour_ts                TIMESTAMP_NTZ NOT NULL,
    query_count            INTEGER NOT NULL,
    avg_elapsed_ms         FLOAT,
    p95_elapsed_ms         FLOAT,
    total_queue_ms         FLOAT,
    queued_queries         INTEGER,
    failed_queries         INTEGER,
    total_elapsed_failed_ms FLOAT,
    complex_queries        INTEGER,
    latency_stddev         FLOAT,
    _loaded_at             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
CLUSTER BY (hour_ts, warehouse_name)
COMMENT = 'Hourly query performance aggregation per warehouse';

-- 4. Warehouse events aggregation
CREATE OR REPLACE TABLE WAREHOUSE_EVENTS_AGG (
    warehouse_name     VARCHAR(256) NOT NULL,
    hour_ts            TIMESTAMP_NTZ NOT NULL,
    event_name         VARCHAR(256) NOT NULL,
    event_count        INTEGER NOT NULL,
    _loaded_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
CLUSTER BY (hour_ts, warehouse_name)
COMMENT = 'Hourly event count aggregation from WAREHOUSE_EVENTS_HISTORY';

-- 5. Refresh procedure — incremental merge (only loads new hours)
CREATE OR REPLACE PROCEDURE ADAPTIVE_METRICS.REFRESH_METRICS()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
BEGIN
    -- Determine watermark for incremental load
    LET metering_watermark TIMESTAMP_NTZ := (
        SELECT COALESCE(MAX(hour_ts), '2020-01-01'::TIMESTAMP_NTZ)
        FROM ADAPTIVE_METRICS.HOURLY_METERING
    );
    LET query_watermark TIMESTAMP_NTZ := (
        SELECT COALESCE(MAX(hour_ts), '2020-01-01'::TIMESTAMP_NTZ)
        FROM ADAPTIVE_METRICS.HOURLY_QUERIES
    );
    LET events_watermark TIMESTAMP_NTZ := (
        SELECT COALESCE(MAX(hour_ts), '2020-01-01'::TIMESTAMP_NTZ)
        FROM ADAPTIVE_METRICS.WAREHOUSE_EVENTS_AGG
    );

    -- Metering: merge new hours (go back 2 hours for late-arriving data)
    MERGE INTO ADAPTIVE_METRICS.HOURLY_METERING tgt
    USING (
        SELECT
            h.warehouse_name,
            DATE_TRUNC('hour', h.start_time) AS hour_ts,
            SUM(h.credits_used) AS credits,
            MAX(t.tag_value) AS tag_cost_center
        FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY h
        LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES t
          ON t.object_name = h.warehouse_name
          AND t.object_type = 'WAREHOUSE'
          AND t.tag_name = 'COST_CENTER'
        WHERE DATE_TRUNC('hour', h.start_time) >= DATEADD('hour', -2, :metering_watermark)
          AND h.start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
        GROUP BY 1, 2
    ) src
    ON tgt.warehouse_name = src.warehouse_name AND tgt.hour_ts = src.hour_ts
    WHEN MATCHED THEN UPDATE SET
        tgt.credits = src.credits,
        tgt.tag_cost_center = src.tag_cost_center,
        tgt._loaded_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (warehouse_name, hour_ts, credits, tag_cost_center)
        VALUES (src.warehouse_name, src.hour_ts, src.credits, src.tag_cost_center);

    -- Queries: merge new hours
    MERGE INTO ADAPTIVE_METRICS.HOURLY_QUERIES tgt
    USING (
        SELECT
            warehouse_name,
            DATE_TRUNC('hour', start_time) AS hour_ts,
            COUNT_IF(execution_status = 'SUCCESS') AS query_count,
            AVG(CASE WHEN execution_status = 'SUCCESS' THEN total_elapsed_time END) AS avg_elapsed_ms,
            PERCENTILE_CONT(0.95) WITHIN GROUP (
                ORDER BY CASE WHEN execution_status = 'SUCCESS' THEN total_elapsed_time END
            ) AS p95_elapsed_ms,
            SUM(CASE WHEN execution_status = 'SUCCESS' THEN queued_overload_time ELSE 0 END) AS total_queue_ms,
            COUNT_IF(queued_overload_time > 0 AND execution_status = 'SUCCESS') AS queued_queries,
            COUNT_IF(execution_status = 'FAIL') AS failed_queries,
            SUM(CASE WHEN execution_status = 'FAIL' THEN total_elapsed_time ELSE 0 END) AS total_elapsed_failed_ms,
            COUNT_IF(warehouse_size IN ('X-Large','2X-Large','3X-Large','4X-Large') AND execution_status = 'SUCCESS') AS complex_queries,
            STDDEV(CASE WHEN execution_status = 'SUCCESS' THEN total_elapsed_time END) AS latency_stddev
        FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
        WHERE DATE_TRUNC('hour', start_time) >= DATEADD('hour', -2, :query_watermark)
          AND start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
          AND warehouse_name IS NOT NULL
        GROUP BY 1, 2
    ) src
    ON tgt.warehouse_name = src.warehouse_name AND tgt.hour_ts = src.hour_ts
    WHEN MATCHED THEN UPDATE SET
        tgt.query_count = src.query_count,
        tgt.avg_elapsed_ms = src.avg_elapsed_ms,
        tgt.p95_elapsed_ms = src.p95_elapsed_ms,
        tgt.total_queue_ms = src.total_queue_ms,
        tgt.queued_queries = src.queued_queries,
        tgt.failed_queries = src.failed_queries,
        tgt.total_elapsed_failed_ms = src.total_elapsed_failed_ms,
        tgt.complex_queries = src.complex_queries,
        tgt.latency_stddev = src.latency_stddev,
        tgt._loaded_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (
        warehouse_name, hour_ts, query_count, avg_elapsed_ms, p95_elapsed_ms,
        total_queue_ms, queued_queries, failed_queries, total_elapsed_failed_ms,
        complex_queries, latency_stddev
    ) VALUES (
        src.warehouse_name, src.hour_ts, src.query_count, src.avg_elapsed_ms, src.p95_elapsed_ms,
        src.total_queue_ms, src.queued_queries, src.failed_queries, src.total_elapsed_failed_ms,
        src.complex_queries, src.latency_stddev
    );

    -- Events: merge new hours
    MERGE INTO ADAPTIVE_METRICS.WAREHOUSE_EVENTS_AGG tgt
    USING (
        SELECT
            warehouse_name,
            DATE_TRUNC('hour', timestamp) AS hour_ts,
            event_name,
            COUNT(*) AS event_count
        FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY
        WHERE DATE_TRUNC('hour', timestamp) >= DATEADD('hour', -2, :events_watermark)
          AND timestamp >= DATEADD('day', -30, CURRENT_TIMESTAMP())
        GROUP BY 1, 2, 3
    ) src
    ON tgt.warehouse_name = src.warehouse_name
       AND tgt.hour_ts = src.hour_ts
       AND tgt.event_name = src.event_name
    WHEN MATCHED THEN UPDATE SET
        tgt.event_count = src.event_count,
        tgt._loaded_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (warehouse_name, hour_ts, event_name, event_count)
        VALUES (src.warehouse_name, src.hour_ts, src.event_name, src.event_count);

    -- Prune data older than 30 days
    DELETE FROM ADAPTIVE_METRICS.HOURLY_METERING WHERE hour_ts < DATEADD('day', -31, CURRENT_TIMESTAMP());
    DELETE FROM ADAPTIVE_METRICS.HOURLY_QUERIES WHERE hour_ts < DATEADD('day', -31, CURRENT_TIMESTAMP());
    DELETE FROM ADAPTIVE_METRICS.WAREHOUSE_EVENTS_AGG WHERE hour_ts < DATEADD('day', -31, CURRENT_TIMESTAMP());

    RETURN 'Refresh complete';
END;

-- 6. Initial backfill (run once)
CALL ADAPTIVE_METRICS.REFRESH_METRICS();

-- 7. Scheduled task — runs every hour on the hour
CREATE OR REPLACE TASK ADAPTIVE_METRICS.REFRESH_METRICS_TASK
    WAREHOUSE = DASH_WH_SI
    SCHEDULE = 'USING CRON 5 * * * * America/Los_Angeles'
    COMMENT = 'Hourly refresh of pre-aggregated metrics for Adaptive Compute dashboard'
AS
    CALL ADAPTIVE_METRICS.REFRESH_METRICS();

-- Enable the task (requires ACCOUNTADMIN or task owner)
ALTER TASK ADAPTIVE_METRICS.REFRESH_METRICS_TASK RESUME;

-- ============================================================
-- VERIFICATION
-- ============================================================
-- Check row counts after initial load:
SELECT 'HOURLY_METERING' AS table_name, COUNT(*) AS rows FROM ADAPTIVE_METRICS.HOURLY_METERING
UNION ALL
SELECT 'HOURLY_QUERIES', COUNT(*) FROM ADAPTIVE_METRICS.HOURLY_QUERIES
UNION ALL
SELECT 'WAREHOUSE_EVENTS_AGG', COUNT(*) FROM ADAPTIVE_METRICS.WAREHOUSE_EVENTS_AGG;

-- Check task status:
SHOW TASKS IN SCHEMA ADAPTIVE_METRICS;
