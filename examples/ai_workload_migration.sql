-- AI/Agent workload migration to Adaptive Compute

--------------------------------------------------------------------------------
-- SCENARIO: Cortex Agent + AI/ML Pipeline Warehouse
--
-- AI workloads are the ideal candidate for Adaptive Compute because:
-- 1. Cortex Agents generate dynamic SQL with unpredictable complexity
-- 2. Agent traffic is user-driven and inherently bursty
-- 3. ML inference jobs spike during batch scoring windows
-- 4. Interactive + batch workloads compete on the same warehouse
--------------------------------------------------------------------------------

-- Step 1: Assess the AI warehouse
SET AI_WAREHOUSE = 'AI_AGENTS_WH';

SELECT
    warehouse_name,
    DATE_TRUNC('hour', start_time) AS hour_ts,
    COUNT(*) AS queries,
    AVG(total_elapsed_time)/1000 AS avg_sec,
    STDDEV(total_elapsed_time)/1000 AS stddev_sec,
    COUNT_IF(queued_overload_time > 0) AS queued
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE warehouse_name = $AI_WAREHOUSE
  AND start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY 2;

-- Step 2: Check for Cortex-generated queries (high variability indicator)
SELECT
    COUNT(*) AS total_queries,
    COUNT_IF(query_tag LIKE '%cortex%' OR query_tag LIKE '%agent%') AS agent_queries,
    ROUND(agent_queries / total_queries * 100, 1) AS agent_pct
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE warehouse_name = $AI_WAREHOUSE
  AND start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP());

-- Step 3: Migrate
ALTER WAREHOUSE IDENTIFIER($AI_WAREHOUSE) SET WAREHOUSE_TYPE = 'ADAPTIVE';

-- Step 4: Configure for mixed AI workloads
-- Agent queries need low latency; use higher performance level
ALTER WAREHOUSE IDENTIFIER($AI_WAREHOUSE)
    SET MAX_QUERY_PERFORMANCE_LEVEL = XXLARGE
        QUERY_THROUGHPUT_MULTIPLIER = 4;

-- Step 5: Monitor agent-specific performance
SELECT
    CASE
        WHEN query_tag LIKE '%cortex%' OR query_tag LIKE '%agent%' THEN 'AGENT'
        WHEN query_tag LIKE '%ml%' OR query_tag LIKE '%scoring%' THEN 'ML_BATCH'
        ELSE 'OTHER'
    END AS workload_type,
    COUNT(*) AS queries,
    AVG(total_elapsed_time)/1000 AS avg_latency_sec,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY total_elapsed_time)/1000 AS p95_sec,
    SUM(queued_overload_time)/1000 AS total_queue_sec
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE warehouse_name = $AI_WAREHOUSE
  AND start_time >= DATEADD('day', -1, CURRENT_TIMESTAMP())
GROUP BY 1;
