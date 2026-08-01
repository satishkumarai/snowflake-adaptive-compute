-- ETL pipeline migration to Adaptive Compute


--------------------------------------------------------------------------------
-- SCENARIO: ETL/ELT Pipeline Warehouse
--
-- ETL warehouses run heavy transforms on schedule (e.g., hourly/daily),
-- then sit idle. This creates a classic variable workload pattern that
-- Adaptive Compute handles efficiently.
--------------------------------------------------------------------------------

-- Step 1: Analyze the ETL schedule pattern
SELECT
    DATE_TRUNC('hour', start_time) AS hour_ts,
    COUNT(*) AS queries,
    SUM(total_elapsed_time)/1000/60 AS total_runtime_min,
    SUM(credits_used_cloud_services) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE warehouse_name = 'ETL_WH'
  AND start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY 1
ORDER BY 1;

-- Step 2: Calculate idle ratio (key indicator for Adaptive benefit)
WITH hourly AS (
    SELECT
        DATE_TRUNC('hour', start_time) AS hour_ts,
        1 AS active
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE warehouse_name = 'ETL_WH'
      AND start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
    GROUP BY 1
)
SELECT
    COUNT(*) AS active_hours,
    7 * 24 AS total_hours,
    ROUND((1 - COUNT(*) / (7.0 * 24)) * 100, 1) AS idle_pct
FROM hourly;

-- Step 3: Migrate with throughput optimization
ALTER WAREHOUSE ETL_WH SET WAREHOUSE_TYPE = 'ADAPTIVE';

-- For batch ETL, throughput matters more than single-query latency.
-- Use lower performance level + higher throughput multiplier.
-- 0 = unlimited throughput (no burst cap).
ALTER WAREHOUSE ETL_WH
    SET MAX_QUERY_PERFORMANCE_LEVEL = MEDIUM
        QUERY_THROUGHPUT_MULTIPLIER = 0;

-- Step 4: Validate pipeline SLAs still met
-- Compare pipeline completion times before and after
SELECT
    DATE(start_time) AS run_date,
    MIN(start_time) AS pipeline_start,
    MAX(end_time) AS pipeline_end,
    DATEDIFF('minute', MIN(start_time), MAX(end_time)) AS duration_min
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE warehouse_name = 'ETL_WH'
  AND query_tag LIKE '%etl_pipeline%'
  AND start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP())
GROUP BY 1
ORDER BY 1;

-- Step 5: Cost comparison by pipeline run
WITH daily_cost AS (
    SELECT
        DATE(start_time) AS run_date,
        SUM(credits_used) AS daily_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE warehouse_name = 'ETL_WH'
      AND start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP())
    GROUP BY 1
)
SELECT
    run_date,
    daily_credits,
    AVG(daily_credits) OVER (ORDER BY run_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS rolling_7d_avg
FROM daily_cost
ORDER BY run_date;
