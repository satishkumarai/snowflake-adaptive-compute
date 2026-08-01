-- Mixed analytics workload migration to Adaptive Compute


--------------------------------------------------------------------------------
-- SCENARIO: Shared Analytics Warehouse
--
-- Multiple teams share a single warehouse for ad-hoc queries, scheduled
-- reports, and dashboard refreshes. Classic "noisy neighbor" problem.
-- Adaptive Compute handles this by dynamically allocating resources.
--------------------------------------------------------------------------------

-- Step 1: Identify the concurrency pattern
SELECT
    DATE_TRUNC('hour', start_time) AS hour_ts,
    HOUR(start_time) AS hour_of_day,
    COUNT(DISTINCT user_name) AS active_users,
    COUNT(*) AS queries,
    AVG(total_elapsed_time)/1000 AS avg_sec,
    MAX(queued_overload_time)/1000 AS max_queue_sec
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE warehouse_name = 'ANALYTICS_WH'
  AND start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY 1;

-- Step 2: Identify peak vs. off-peak (typical analytics pattern)
-- Peak: 9am-6pm weekdays, Off-peak: nights/weekends
SELECT
    CASE
        WHEN DAYOFWEEK(start_time) IN (0, 6) THEN 'WEEKEND'
        WHEN HOUR(start_time) BETWEEN 9 AND 17 THEN 'PEAK'
        ELSE 'OFF_PEAK'
    END AS period,
    COUNT(*) AS queries,
    SUM(credits_used_cloud_services) AS credits,
    AVG(queued_overload_time)/1000 AS avg_queue_sec
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE warehouse_name = 'ANALYTICS_WH'
  AND start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP())
GROUP BY 1;

-- Step 3: Capture baseline
SELECT
    SUM(credits_used) AS credits_7d,
    AVG(credits_used) AS avg_hourly,
    MAX(credits_used) AS peak_hourly,
    MIN(credits_used) AS min_hourly,
    STDDEV(credits_used) / AVG(credits_used) AS coefficient_of_variation
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE warehouse_name = 'ANALYTICS_WH'
  AND start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP());

-- Step 4: Migrate
ALTER WAREHOUSE ANALYTICS_WH SET WAREHOUSE_TYPE = 'ADAPTIVE';

-- Step 5: Post-migration comparison (run after 72 hours)
WITH pre AS (
    SELECT
        AVG(total_elapsed_time)/1000 AS avg_latency,
        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY total_elapsed_time)/1000 AS p95,
        AVG(queued_overload_time)/1000 AS avg_queue
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE warehouse_name = 'ANALYTICS_WH'
      AND start_time BETWEEN DATEADD('day', -10, CURRENT_TIMESTAMP())
                         AND DATEADD('day', -3, CURRENT_TIMESTAMP())
),
post AS (
    SELECT
        AVG(total_elapsed_time)/1000 AS avg_latency,
        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY total_elapsed_time)/1000 AS p95,
        AVG(queued_overload_time)/1000 AS avg_queue
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE warehouse_name = 'ANALYTICS_WH'
      AND start_time >= DATEADD('day', -3, CURRENT_TIMESTAMP())
)
SELECT
    ROUND(pre.avg_latency, 2) AS pre_avg_latency_sec,
    ROUND(post.avg_latency, 2) AS post_avg_latency_sec,
    ROUND((1 - post.avg_latency / pre.avg_latency) * 100, 1) AS latency_improvement_pct,
    ROUND(pre.avg_queue, 2) AS pre_avg_queue_sec,
    ROUND(post.avg_queue, 2) AS post_avg_queue_sec,
    ROUND((1 - post.avg_queue / NULLIF(pre.avg_queue, 0)) * 100, 1) AS queue_reduction_pct
FROM pre, post;
