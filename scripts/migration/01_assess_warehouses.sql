-- Assess warehouses for Adaptive Compute migration candidacy

--------------------------------------------------------------------------------
-- WAREHOUSE ASSESSMENT FOR ADAPTIVE COMPUTE MIGRATION
-- Analyzes utilization patterns, variability, and cost efficiency to score
-- each warehouse's suitability for Adaptive Compute.
--
-- Requirements: ACCOUNTADMIN or role with access to ACCOUNT_USAGE views
-- Lookback: 14 days (configurable via $LOOKBACK_DAYS)
--------------------------------------------------------------------------------

SET LOOKBACK_DAYS = 14;

-- Step 1: Capture current warehouse inventory
SHOW WAREHOUSES;

CREATE OR REPLACE TEMPORARY TABLE _adaptive_warehouse_list AS
SELECT
    "name" AS warehouse_name,
    "type" AS warehouse_type,
    "size" AS warehouse_size,
    "generation" AS generation
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- Step 2: Compute hourly utilization patterns per warehouse
CREATE OR REPLACE TEMPORARY TABLE _adaptive_hourly_metrics AS
SELECT
    warehouse_name,
    DATE_TRUNC('hour', start_time) AS hour_ts,
    SUM(credits_used) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -$LOOKBACK_DAYS, CURRENT_TIMESTAMP())
GROUP BY 1, 2;

-- Step 3: Compute query concurrency and queuing per warehouse
CREATE OR REPLACE TEMPORARY TABLE _adaptive_query_metrics AS
SELECT
    warehouse_name,
    DATE_TRUNC('hour', start_time) AS hour_ts,
    COUNT(*) AS query_count,
    AVG(total_elapsed_time) / 1000 AS avg_duration_sec,
    MAX(total_elapsed_time) / 1000 AS max_duration_sec,
    SUM(queued_overload_time) / 1000 AS total_queue_sec,
    COUNT_IF(queued_overload_time > 0) AS queued_queries
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -$LOOKBACK_DAYS, CURRENT_TIMESTAMP())
  AND warehouse_name IS NOT NULL
  AND execution_status = 'SUCCESS'
GROUP BY 1, 2;

-- Step 4: Score each warehouse
SELECT
    w.warehouse_name,
    w.warehouse_type,
    w.warehouse_size,
    stats.active_hours,
    ($LOOKBACK_DAYS * 24) AS total_hours,
    ROUND(stats.active_hours / ($LOOKBACK_DAYS * 24.0) * 100, 1) AS utilization_pct,
    ROUND(stats.total_credits, 2) AS total_credits,
    ROUND(stats.credit_cv, 3) AS variability_score,
    COALESCE(stats.total_queued_queries, 0) AS total_queued_queries,
    -- Scoring logic (0-100)
    ROUND(
        LEAST(stats.credit_cv * 40, 40)
        + LEAST((1 - stats.active_hours / ($LOOKBACK_DAYS * 24.0)) * 30, 30)
        + LEAST(COALESCE(stats.total_queued_queries, 0) / NULLIF(stats.active_hours, 0) * 5, 20)
        + LEAST(stats.total_credits / 100, 10)
    , 1) AS adaptive_score,
    CASE
        WHEN LEAST(stats.credit_cv * 40, 40)
             + LEAST((1 - stats.active_hours / ($LOOKBACK_DAYS * 24.0)) * 30, 30)
             + LEAST(COALESCE(stats.total_queued_queries, 0) / NULLIF(stats.active_hours, 0) * 5, 20)
             + LEAST(stats.total_credits / 100, 10) >= 80 THEN 'MIGRATE NOW'
        WHEN LEAST(stats.credit_cv * 40, 40)
             + LEAST((1 - stats.active_hours / ($LOOKBACK_DAYS * 24.0)) * 30, 30)
             + LEAST(COALESCE(stats.total_queued_queries, 0) / NULLIF(stats.active_hours, 0) * 5, 20)
             + LEAST(stats.total_credits / 100, 10) >= 60 THEN 'STRONG CANDIDATE'
        WHEN LEAST(stats.credit_cv * 40, 40)
             + LEAST((1 - stats.active_hours / ($LOOKBACK_DAYS * 24.0)) * 30, 30)
             + LEAST(COALESCE(stats.total_queued_queries, 0) / NULLIF(stats.active_hours, 0) * 5, 20)
             + LEAST(stats.total_credits / 100, 10) >= 40 THEN 'EVALUATE'
        ELSE 'KEEP STANDARD'
    END AS recommendation
FROM _adaptive_warehouse_list w
LEFT JOIN (
    SELECT
        h.warehouse_name,
        COUNT(DISTINCT h.hour_ts) AS active_hours,
        SUM(h.credits) AS total_credits,
        AVG(h.credits) AS avg_hourly_credits,
        CASE WHEN AVG(h.credits) > 0 THEN STDDEV(h.credits) / AVG(h.credits) ELSE 0 END AS credit_cv,
        SUM(q.queued_queries) AS total_queued_queries
    FROM _adaptive_hourly_metrics h
    LEFT JOIN _adaptive_query_metrics q
        ON h.warehouse_name = q.warehouse_name AND h.hour_ts = q.hour_ts
    GROUP BY 1
) stats ON w.warehouse_name = stats.warehouse_name
WHERE w.warehouse_type = 'STANDARD'
ORDER BY adaptive_score DESC;
