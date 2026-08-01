-- Deploy monitoring infrastructure for Adaptive Compute warehouses

--------------------------------------------------------------------------------
-- MONITORING DEPLOYMENT
-- Creates views for ongoing Adaptive Compute health tracking.
-- Uses ADAPTIVE_COMPUTE_DB.ADMIN schema and ACCOUNT_USAGE views.
--
-- Key insight from Snowflake docs: warehouse_size = 'ADAPTIVE' in
-- QUERY_HISTORY identifies queries that ran on an Adaptive Warehouse.
--------------------------------------------------------------------------------

USE SCHEMA ADAPTIVE_COMPUTE_DB.ADMIN;

-- View: Hourly credit consumption comparison (pre vs post migration)
CREATE OR REPLACE VIEW ADAPTIVE_COMPUTE_DB.ADMIN.V_CREDIT_COMPARISON AS
WITH migration_dates AS (
    SELECT
        warehouse_name,
        MIN(migrated_at) AS migration_ts
    FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
    WHERE action = 'MIGRATE'
    GROUP BY 1
)
SELECT
    h.warehouse_name,
    DATE_TRUNC('hour', h.start_time) AS hour_ts,
    CASE WHEN h.start_time >= md.migration_ts THEN 'POST' ELSE 'PRE' END AS period,
    SUM(h.credits_used) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY h
JOIN migration_dates md ON h.warehouse_name = md.warehouse_name
WHERE h.start_time >= DATEADD('day', -14, md.migration_ts)
GROUP BY 1, 2, 3;

-- View: Query performance comparison (pre vs post migration)
CREATE OR REPLACE VIEW ADAPTIVE_COMPUTE_DB.ADMIN.V_PERFORMANCE_COMPARISON AS
WITH migration_dates AS (
    SELECT
        warehouse_name,
        MIN(migrated_at) AS migration_ts
    FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
    WHERE action = 'MIGRATE'
    GROUP BY 1
)
SELECT
    q.warehouse_name,
    CASE WHEN q.start_time >= md.migration_ts THEN 'POST' ELSE 'PRE' END AS period,
    DATE_TRUNC('hour', q.start_time) AS hour_ts,
    COUNT(*) AS query_count,
    AVG(q.total_elapsed_time) / 1000 AS avg_latency_sec,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY q.total_elapsed_time) / 1000 AS p95_latency_sec,
    AVG(q.queued_overload_time) / 1000 AS avg_queue_sec,
    COUNT_IF(q.queued_overload_time > 0) AS queued_count
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
JOIN migration_dates md ON q.warehouse_name = md.warehouse_name
WHERE q.start_time >= DATEADD('day', -14, md.migration_ts)
  AND q.execution_status = 'SUCCESS'
GROUP BY 1, 2, 3;

-- View: Daily savings summary
CREATE OR REPLACE VIEW ADAPTIVE_COMPUTE_DB.ADMIN.V_DAILY_SAVINGS AS
WITH daily_credits AS (
    SELECT
        warehouse_name,
        period,
        DATE_TRUNC('day', hour_ts) AS day_ts,
        SUM(credits) AS daily_credits
    FROM ADAPTIVE_COMPUTE_DB.ADMIN.V_CREDIT_COMPARISON
    GROUP BY 1, 2, 3
),
pre_avg AS (
    SELECT
        warehouse_name,
        AVG(daily_credits) AS avg_daily_pre
    FROM daily_credits
    WHERE period = 'PRE'
    GROUP BY 1
)
SELECT
    dc.warehouse_name,
    dc.day_ts,
    dc.daily_credits AS actual_credits,
    pa.avg_daily_pre AS baseline_daily_credits,
    ROUND((1 - dc.daily_credits / NULLIF(pa.avg_daily_pre, 0)) * 100, 1) AS savings_pct
FROM daily_credits dc
JOIN pre_avg pa ON dc.warehouse_name = pa.warehouse_name
WHERE dc.period = 'POST'
ORDER BY dc.warehouse_name, dc.day_ts;

-- View: Adaptive warehouse query detection
-- Per Snowflake docs, warehouse_size = 'ADAPTIVE' in QUERY_HISTORY
CREATE OR REPLACE VIEW ADAPTIVE_COMPUTE_DB.ADMIN.V_ADAPTIVE_QUERIES AS
SELECT
    end_time::DATE AS query_date,
    warehouse_name,
    IFF(warehouse_size = 'ADAPTIVE', 'ADAPTIVE', 'STANDARD') AS warehouse_type,
    COUNT(*) AS query_count,
    AVG(total_elapsed_time) / 1000 AS avg_latency_sec,
    AVG(execution_time) / 1000 AS avg_exec_sec,
    AVG(queued_overload_time) / 1000 AS avg_queue_sec,
    AVG(queued_provisioning_time) / 1000 AS avg_provisioning_sec
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -14, CURRENT_DATE())
  AND warehouse_name IS NOT NULL
GROUP BY 1, 2, 3;
