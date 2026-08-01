-- Comprehensive test suite for all Streamlit app SQL queries

--------------------------------------------------------------------------------
-- TEST SUITE: STREAMLIT APP QUERIES
-- Validates SQL queries used in the Streamlit dashboard data loaders.
-- Each test verifies: compilation, expected columns, data types, no errors.
--
-- Maps to Streamlit functions (consolidated base query architecture):
--   load_warehouse_inventory() → SHOW WAREHOUSES (via session.sql)
--   load_metering_base()       → WAREHOUSE_METERING_HISTORY (hourly)
--   load_query_base()          → QUERY_HISTORY (hourly aggregated)
--   load_events_base()         → WAREHOUSE_EVENTS_HISTORY (hourly)
--   load_credit_price()        → ORGANIZATION_USAGE.RATE_SHEET_DAILY
--   load_tag_attribution()     → METERING + TAG_REFERENCES
--   load_before_after_comparison() → EVENTS + METERING (pre/post)
--
-- Derived views (computed in Pandas, not SQL):
--   derive_credit_usage(), derive_credit_totals(), derive_idle_waste(),
--   derive_anomalies(), derive_assessment_scores(), derive_query_performance(),
--   derive_suspend_resume(), derive_events_summary()
--------------------------------------------------------------------------------

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST GROUP 1: load_warehouse_inventory()
-- Uses SHOW WAREHOUSES + RESULT_SCAN pattern
-- ═══════════════════════════════════════════════════════════════════════════════

SHOW WAREHOUSES;

-- T1.1: All expected columns exist
SELECT
    'T1.1_INVENTORY_COLUMNS' AS test_id,
    CASE
        WHEN COUNT(*) > 0 THEN 'PASS: ' || COUNT(*)::STRING || ' warehouses'
        ELSE 'FAIL: no warehouses returned'
    END AS result
FROM (
    SELECT
        "name" AS WAREHOUSE_NAME,
        "type" AS WAREHOUSE_TYPE,
        "state" AS STATE,
        "size" AS WAREHOUSE_SIZE,
        "generation" AS GENERATION,
        "max_query_performance_level" AS MAX_QUERY_PERF_LEVEL,
        "query_throughput_multiplier" AS THROUGHPUT_MULTIPLIER
    FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
);

-- T1.2: WAREHOUSE_TYPE values are valid
SHOW WAREHOUSES;
SELECT
    'T1.2_TYPE_VALUES' AS test_id,
    CASE
        WHEN COUNT_IF("type" NOT IN ('STANDARD', 'ADAPTIVE')) = 0 THEN 'PASS'
        ELSE 'FAIL: unexpected type values'
    END AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- T1.3: STATE values are valid for each type
SHOW WAREHOUSES;
SELECT
    'T1.3_STATE_VALUES' AS test_id,
    CASE
        WHEN COUNT_IF(
            ("type" = 'STANDARD' AND "state" NOT IN ('STARTED', 'SUSPENDED', 'RESIZING'))
            OR ("type" = 'ADAPTIVE' AND "state" NOT IN ('ENABLED', 'DISABLED'))
        ) = 0 THEN 'PASS'
        ELSE 'WARN: some states unexpected (may have new state values)'
    END AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- T1.4: Name is never NULL
SHOW WAREHOUSES;
SELECT
    'T1.4_NAME_NOT_NULL' AS test_id,
    CASE WHEN COUNT_IF("name" IS NULL) = 0 THEN 'PASS' ELSE 'FAIL' END AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST GROUP 2: load_credit_usage(days_back, warehouse_filter)
-- ═══════════════════════════════════════════════════════════════════════════════

-- T2.1: Basic query returns data
SELECT
    'T2.1_CREDITS_BASIC' AS test_id,
    CASE WHEN COUNT(*) > 0 THEN 'PASS: ' || COUNT(*)::STRING || ' rows'
         ELSE 'FAIL: no credit data' END AS result
FROM (
    SELECT DATE_TRUNC('hour', start_time) AS hour_ts, warehouse_name, SUM(credits_used) AS credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
    GROUP BY 1, 2
);

-- T2.2: With warehouse filter (parameterized pattern)
SELECT
    'T2.2_CREDITS_FILTERED' AS test_id,
    CASE WHEN COUNT(*) > 0 THEN 'PASS' ELSE 'FAIL: no data for DASH_WH_SI' END AS result
FROM (
    SELECT DATE_TRUNC('hour', start_time) AS hour_ts, warehouse_name, SUM(credits_used) AS credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
      AND warehouse_name IN ('DASH_WH_SI')
    GROUP BY 1, 2
);

-- T2.3: Credits are non-negative
SELECT
    'T2.3_CREDITS_POSITIVE' AS test_id,
    CASE WHEN COUNT_IF(credits < 0) = 0 THEN 'PASS' ELSE 'FAIL: negative credits' END AS result
FROM (
    SELECT SUM(credits_used) AS credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
    GROUP BY warehouse_name
);

-- T2.4: hour_ts is within expected range
SELECT
    'T2.4_CREDITS_TIME_RANGE' AS test_id,
    CASE
        WHEN MIN(hour_ts) >= DATEADD('day', -8, CURRENT_TIMESTAMP())
             AND MAX(hour_ts) <= CURRENT_TIMESTAMP()
        THEN 'PASS'
        ELSE 'FAIL: timestamps out of expected range'
    END AS result
FROM (
    SELECT DATE_TRUNC('hour', start_time) AS hour_ts
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
);

-- T2.5: Empty filter returns nothing (edge case)
SELECT
    'T2.5_CREDITS_EMPTY_FILTER' AS test_id,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL: should be empty' END AS result
FROM (
    SELECT 1
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
      AND warehouse_name IN ('NONEXISTENT_WH_XYZ_12345')
);

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST GROUP 3: load_query_performance(days_back, warehouse_filter)
-- ═══════════════════════════════════════════════════════════════════════════════

-- T3.1: Basic query returns data
SELECT
    'T3.1_PERF_BASIC' AS test_id,
    CASE WHEN COUNT(*) > 0 THEN 'PASS: ' || COUNT(*)::STRING || ' rows'
         ELSE 'FAIL: no performance data' END AS result
FROM (
    SELECT DATE_TRUNC('hour', start_time) AS hour_ts, warehouse_name,
        COUNT(*) AS query_count,
        AVG(total_elapsed_time) / 1000 AS avg_latency_sec,
        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY total_elapsed_time) / 1000 AS p95_latency_sec,
        SUM(queued_overload_time) / 1000 AS total_queue_sec,
        COUNT_IF(queued_overload_time > 0) AS queued_queries
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
      AND execution_status = 'SUCCESS' AND warehouse_name IS NOT NULL
    GROUP BY 1, 2
);

-- T3.2: P95 >= AVG (statistical invariant)
SELECT
    'T3.2_PERF_P95_GTE_AVG' AS test_id,
    CASE WHEN COUNT_IF(p95 < avg_lat) = 0 THEN 'PASS'
         ELSE 'FAIL: P95 < avg in some rows' END AS result
FROM (
    SELECT AVG(total_elapsed_time) / 1000 AS avg_lat,
        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY total_elapsed_time) / 1000 AS p95
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
      AND execution_status = 'SUCCESS' AND warehouse_name IS NOT NULL
    GROUP BY DATE_TRUNC('hour', start_time), warehouse_name
    HAVING COUNT(*) > 5
);

-- T3.3: Queue time is non-negative
SELECT
    'T3.3_PERF_QUEUE_POSITIVE' AS test_id,
    CASE WHEN COUNT_IF(queued_overload_time < 0) = 0 THEN 'PASS'
         ELSE 'FAIL: negative queue time' END AS result
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND warehouse_name IS NOT NULL;

-- T3.4: Filtered by warehouse
SELECT
    'T3.4_PERF_FILTERED' AS test_id,
    CASE WHEN COUNT(DISTINCT warehouse_name) = 1 THEN 'PASS'
         ELSE 'FAIL: filter not working' END AS result
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND execution_status = 'SUCCESS'
  AND warehouse_name IN ('DASH_WH_SI');

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST GROUP 4: load_assessment_scores()
-- ═══════════════════════════════════════════════════════════════════════════════

-- T4.1: Full assessment query returns valid scores
SELECT
    'T4.1_ASSESS_RETURNS_DATA' AS test_id,
    CASE WHEN COUNT(*) > 0 THEN 'PASS: ' || COUNT(*)::STRING || ' warehouses scored'
         ELSE 'FAIL: no scores returned' END AS result
FROM (
    WITH hourly_metrics AS (
        SELECT warehouse_name, DATE_TRUNC('hour', start_time) AS hour_ts, SUM(credits_used) AS credits
        FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
        WHERE start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP()) GROUP BY 1, 2
    ),
    query_metrics AS (
        SELECT warehouse_name, COUNT_IF(queued_overload_time > 0) AS queued_queries
        FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
        WHERE start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP()) AND warehouse_name IS NOT NULL GROUP BY 1
    ),
    stats AS (
        SELECT h.warehouse_name, COUNT(DISTINCT h.hour_ts) AS active_hours,
            AVG(h.credits) AS avg_credits, STDDEV(h.credits) AS std_credits,
            SUM(h.credits) AS total_credits, COALESCE(q.queued_queries, 0) AS queued_queries
        FROM hourly_metrics h LEFT JOIN query_metrics q ON h.warehouse_name = q.warehouse_name GROUP BY 1, 6
    )
    SELECT warehouse_name,
        ROUND(LEAST(CASE WHEN avg_credits > 0 THEN std_credits / avg_credits ELSE 0 END * 40, 40)
            + LEAST((1 - active_hours / (14.0 * 24)) * 30, 30)
            + LEAST(queued_queries / NULLIF(active_hours, 0) * 5, 20)
            + LEAST(total_credits / 100, 10), 1) AS adaptive_score
    FROM stats
);

-- T4.2: All scores in valid range [0, 100]
SELECT
    'T4.2_ASSESS_SCORE_RANGE' AS test_id,
    CASE
        WHEN MIN(adaptive_score) >= 0 AND MAX(adaptive_score) <= 100 THEN 'PASS: range [' || MIN(adaptive_score)::STRING || ', ' || MAX(adaptive_score)::STRING || ']'
        ELSE 'FAIL: scores outside [0, 100]'
    END AS result
FROM (
    WITH hourly_metrics AS (
        SELECT warehouse_name, DATE_TRUNC('hour', start_time) AS hour_ts, SUM(credits_used) AS credits
        FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
        WHERE start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP()) GROUP BY 1, 2
    ),
    query_metrics AS (
        SELECT warehouse_name, COUNT_IF(queued_overload_time > 0) AS queued_queries
        FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
        WHERE start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP()) AND warehouse_name IS NOT NULL GROUP BY 1
    ),
    stats AS (
        SELECT h.warehouse_name, COUNT(DISTINCT h.hour_ts) AS active_hours,
            AVG(h.credits) AS avg_credits, STDDEV(h.credits) AS std_credits,
            SUM(h.credits) AS total_credits, COALESCE(q.queued_queries, 0) AS queued_queries
        FROM hourly_metrics h LEFT JOIN query_metrics q ON h.warehouse_name = q.warehouse_name GROUP BY 1, 6
    )
    SELECT ROUND(LEAST(CASE WHEN avg_credits > 0 THEN std_credits / avg_credits ELSE 0 END * 40, 40)
        + LEAST((1 - active_hours / (14.0 * 24)) * 30, 30)
        + LEAST(queued_queries / NULLIF(active_hours, 0) * 5, 20)
        + LEAST(total_credits / 100, 10), 1) AS adaptive_score
    FROM stats
);

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST GROUP 5: load_credit_totals(days_back)
-- ═══════════════════════════════════════════════════════════════════════════════

-- T5.1: Returns aggregated totals
SELECT
    'T5.1_TOTALS_BASIC' AS test_id,
    CASE WHEN COUNT(*) > 0 THEN 'PASS: ' || COUNT(*)::STRING || ' warehouses'
         ELSE 'FAIL' END AS result
FROM (
    SELECT warehouse_name, SUM(credits_used) AS total_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
    GROUP BY 1 ORDER BY 2 DESC
);

-- T5.2: Totals are non-negative
SELECT
    'T5.2_TOTALS_POSITIVE' AS test_id,
    CASE WHEN COUNT_IF(total_credits < 0) = 0 THEN 'PASS' ELSE 'FAIL' END AS result
FROM (
    SELECT SUM(credits_used) AS total_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
    GROUP BY warehouse_name
);

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST GROUP 6: Sidebar queries
-- ═══════════════════════════════════════════════════════════════════════════════

-- T6.1: CURRENT_ACCOUNT_NAME() works
SELECT
    'T6.1_ACCOUNT_NAME' AS test_id,
    CASE WHEN CURRENT_ACCOUNT_NAME() IS NOT NULL THEN 'PASS: ' || CURRENT_ACCOUNT_NAME()
         ELSE 'FAIL' END AS result;

-- T6.2: CURRENT_ROLE() works
SELECT
    'T6.2_CURRENT_ROLE' AS test_id,
    CASE WHEN CURRENT_ROLE() IS NOT NULL THEN 'PASS: ' || CURRENT_ROLE()
         ELSE 'FAIL' END AS result;

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST GROUP 7: Edge cases for Streamlit rendering
-- ═══════════════════════════════════════════════════════════════════════════════

-- T7.1: Empty date range returns no rows (not an error)
SELECT
    'T7.1_EMPTY_RANGE' AS test_id,
    CASE WHEN COUNT(*) = 0 THEN 'PASS: graceful empty' ELSE 'FAIL' END AS result
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('second', -1, CURRENT_TIMESTAMP())
  AND start_time < DATEADD('second', -1, CURRENT_TIMESTAMP());

-- T7.2: Very long lookback (30 days) doesn't timeout
SELECT
    'T7.2_30DAY_LOOKBACK' AS test_id,
    CASE WHEN COUNT(*) >= 0 THEN 'PASS: ' || COUNT(*)::STRING || ' rows'
         ELSE 'FAIL' END AS result
FROM (
    SELECT DATE_TRUNC('day', start_time) AS day_ts, SUM(credits_used) AS credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
    GROUP BY 1
);

SELECT 'ALL STREAMLIT QUERY TESTS COMPLETE' AS status, CURRENT_TIMESTAMP() AS run_at;
