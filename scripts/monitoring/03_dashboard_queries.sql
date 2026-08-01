-- Dashboard queries for Adaptive Compute monitoring

--------------------------------------------------------------------------------
-- DASHBOARD QUERIES
-- Based on Snowflake's recommended monitoring patterns from official docs.
-- Uses: WAREHOUSE_METERING_HISTORY, QUERY_HISTORY, WAREHOUSE_LOAD_HISTORY
--
-- Key: warehouse_size = 'ADAPTIVE' in QUERY_HISTORY identifies queries
-- that ran on an Adaptive Warehouse.
--------------------------------------------------------------------------------

-- Query 1: Credit Savings Over Time (line chart)
-- Compare credit consumption by warehouse over time
SELECT
    DATE_TRUNC('day', start_time) AS day_ts,
    warehouse_name,
    SUM(credits_used) AS daily_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY 1, 2;

-- Query 2: Adaptive vs Standard Performance Comparison
-- (From Snowflake official docs)
WITH adaptive_whs AS (
    SELECT DISTINCT warehouse_name
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE warehouse_size = 'ADAPTIVE'
      AND start_time >= DATEADD('day', -7, CURRENT_DATE())
)
SELECT
    q.end_time::DATE AS ds,
    q.warehouse_name,
    IFF(q.warehouse_size = 'ADAPTIVE', 'ADAPTIVE', 'STANDARD') AS warehouse_type,
    AVG(q.total_elapsed_time) AS avg_query_time_ms,
    AVG(q.execution_time) AS avg_exec_time_ms,
    AVG(q.queued_overload_time) AS avg_queued_overload_time_ms,
    AVG(q.queued_provisioning_time) AS avg_queued_provisioning_time_ms,
    COUNT(*) AS query_count
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
WHERE q.start_time >= DATEADD('day', -7, CURRENT_DATE())
  AND q.warehouse_name IN (SELECT warehouse_name FROM adaptive_whs)
GROUP BY ALL
ORDER BY 1, 2;

-- Query 3: Per-Query Credit Usage (Adaptive Warehouses)
-- Uses QUERY_METERING_HISTORY for granular cost tracking
SELECT
    DATE_TRUNC('hour', start_time) AS hour_ts,
    warehouse_name,
    COUNT(*) AS metering_events,
    SUM(credits_used) AS total_credits,
    AVG(credits_used) AS avg_credits_per_entry
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY 1;

-- Query 4: Queue Time Analysis (WAREHOUSE_LOAD_HISTORY)
-- Monitor queuing to decide if QUERY_THROUGHPUT_MULTIPLIER needs adjustment
SELECT
    DATE_TRUNC('hour', start_time) AS hour_ts,
    warehouse_name,
    AVG(avg_running) AS avg_running_queries,
    AVG(avg_queued_load) AS avg_queued_queries,
    AVG(avg_blocked) AS avg_blocked_queries
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY 1, 2
HAVING avg_queued_queries > 0
ORDER BY avg_queued_queries DESC;

-- Query 5: Migration ROI Summary (scorecard)
-- Compare periods before and after migration
WITH weekly_costs AS (
    SELECT
        warehouse_name,
        DATE_TRUNC('week', start_time) AS week_ts,
        SUM(credits_used) AS weekly_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD('day', -28, CURRENT_TIMESTAMP())
    GROUP BY 1, 2
)
SELECT
    warehouse_name,
    MIN(weekly_credits) AS min_weekly_credits,
    MAX(weekly_credits) AS max_weekly_credits,
    AVG(weekly_credits) AS avg_weekly_credits
FROM weekly_costs
GROUP BY 1
ORDER BY avg_weekly_credits DESC;

-- Query 6: Latency by Warehouse Type
SELECT
    IFF(warehouse_size = 'ADAPTIVE', 'ADAPTIVE', 'STANDARD') AS wh_type,
    COUNT(*) AS total_queries,
    ROUND(AVG(total_elapsed_time) / 1000, 2) AS avg_latency_sec,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY total_elapsed_time) / 1000, 2) AS p95_latency_sec,
    ROUND(AVG(queued_overload_time) / 1000, 2) AS avg_queue_sec
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND execution_status = 'SUCCESS'
  AND warehouse_name IS NOT NULL
GROUP BY 1;
