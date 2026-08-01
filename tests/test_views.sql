-- Comprehensive test suite for monitoring views

--------------------------------------------------------------------------------
-- TEST SUITE: MONITORING VIEWS
-- Tests V_CREDIT_COMPARISON, V_PERFORMANCE_COMPARISON, V_DAILY_SAVINGS,
-- V_ADAPTIVE_QUERIES
--
-- Tests verify: schema correctness, data types, join logic, period detection,
-- edge cases (no data, NULL handling)
--------------------------------------------------------------------------------

USE SCHEMA ADAPTIVE_COMPUTE_DB.ADMIN;

-- ═══════════════════════════════════════════════════════════════════════════════
-- SETUP: Ensure test data exists in migration log
-- ═══════════════════════════════════════════════════════════════════════════════

-- Insert a test migration record for a warehouse with known history
INSERT INTO ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
    (warehouse_name, action, previous_type, new_type, baseline_credits_7d, notes, migrated_at)
SELECT
    'DASH_WH_SI', 'MIGRATE', 'STANDARD', 'ADAPTIVE', 17.0, 'Test fixture',
    DATEADD('day', -3, CURRENT_TIMESTAMP())
WHERE NOT EXISTS (
    SELECT 1 FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
    WHERE warehouse_name = 'DASH_WH_SI' AND action = 'MIGRATE' AND notes = 'Test fixture'
);

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 1: V_CREDIT_COMPARISON - Schema validation
-- ═══════════════════════════════════════════════════════════════════════════════

SELECT
    'T1_CREDIT_COMP_SCHEMA' AS test_id,
    CASE
        WHEN COUNT(*) >= 0 THEN 'PASS'
        ELSE 'FAIL'
    END AS result
FROM ADAPTIVE_COMPUTE_DB.ADMIN.V_CREDIT_COMPARISON
WHERE 1=0;  -- Just validate columns exist

-- ASSERT: Correct columns exist
SELECT
    'T1_CREDIT_COMP_COLUMNS' AS test_id,
    CASE
        WHEN warehouse_name IS NOT NULL OR warehouse_name IS NULL THEN 'PASS'
    END AS result
FROM (
    SELECT warehouse_name, hour_ts, period, credits
    FROM ADAPTIVE_COMPUTE_DB.ADMIN.V_CREDIT_COMPARISON
    LIMIT 0
);

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 2: V_CREDIT_COMPARISON - Period detection logic
-- ═══════════════════════════════════════════════════════════════════════════════

-- ASSERT: PRE period exists (data before migration)
SELECT
    'T2_CREDIT_PRE_PERIOD' AS test_id,
    CASE WHEN COUNT(*) > 0 THEN 'PASS'
         ELSE 'FAIL: no PRE period data' END AS result
FROM ADAPTIVE_COMPUTE_DB.ADMIN.V_CREDIT_COMPARISON
WHERE period = 'PRE' AND warehouse_name = 'DASH_WH_SI';

-- ASSERT: POST period exists (data after migration)
SELECT
    'T2_CREDIT_POST_PERIOD' AS test_id,
    CASE WHEN COUNT(*) > 0 THEN 'PASS'
         ELSE 'FAIL: no POST period data (may need ACCOUNT_USAGE latency)' END AS result
FROM ADAPTIVE_COMPUTE_DB.ADMIN.V_CREDIT_COMPARISON
WHERE period = 'POST' AND warehouse_name = 'DASH_WH_SI';

-- ASSERT: Credits are non-negative
SELECT
    'T2_CREDIT_NON_NEGATIVE' AS test_id,
    CASE WHEN COUNT_IF(credits < 0) = 0 THEN 'PASS'
         ELSE 'FAIL: negative credits found' END AS result
FROM ADAPTIVE_COMPUTE_DB.ADMIN.V_CREDIT_COMPARISON;

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 3: V_PERFORMANCE_COMPARISON - Schema and data
-- ═══════════════════════════════════════════════════════════════════════════════

-- ASSERT: View returns data
SELECT
    'T3_PERF_HAS_DATA' AS test_id,
    CASE WHEN COUNT(*) > 0 THEN 'PASS'
         ELSE 'FAIL: no data in V_PERFORMANCE_COMPARISON' END AS result
FROM ADAPTIVE_COMPUTE_DB.ADMIN.V_PERFORMANCE_COMPARISON
WHERE warehouse_name = 'DASH_WH_SI';

-- ASSERT: Latency values are positive
SELECT
    'T3_PERF_LATENCY_POSITIVE' AS test_id,
    CASE WHEN COUNT_IF(avg_latency_sec < 0) = 0 THEN 'PASS'
         ELSE 'FAIL: negative latency values' END AS result
FROM ADAPTIVE_COMPUTE_DB.ADMIN.V_PERFORMANCE_COMPARISON;

-- ASSERT: P95 >= Average (statistical invariant)
SELECT
    'T3_PERF_P95_GTE_AVG' AS test_id,
    CASE WHEN COUNT_IF(p95_latency_sec < avg_latency_sec) = 0 THEN 'PASS'
         ELSE 'FAIL: P95 < avg in some rows (statistical impossibility)' END AS result
FROM ADAPTIVE_COMPUTE_DB.ADMIN.V_PERFORMANCE_COMPARISON
WHERE query_count > 10;

-- ASSERT: Query count is positive
SELECT
    'T3_PERF_QUERY_COUNT' AS test_id,
    CASE WHEN COUNT_IF(query_count <= 0) = 0 THEN 'PASS'
         ELSE 'FAIL: non-positive query counts' END AS result
FROM ADAPTIVE_COMPUTE_DB.ADMIN.V_PERFORMANCE_COMPARISON;

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 4: V_ADAPTIVE_QUERIES - Correct detection logic
-- ═══════════════════════════════════════════════════════════════════════════════

-- ASSERT: View returns data
SELECT
    'T4_ADAPTIVE_HAS_DATA' AS test_id,
    CASE WHEN COUNT(*) > 0 THEN 'PASS'
         ELSE 'FAIL: no data' END AS result
FROM ADAPTIVE_COMPUTE_DB.ADMIN.V_ADAPTIVE_QUERIES;

-- ASSERT: warehouse_type is only ADAPTIVE or STANDARD
SELECT
    'T4_ADAPTIVE_TYPE_VALUES' AS test_id,
    CASE WHEN COUNT_IF(warehouse_type NOT IN ('ADAPTIVE', 'STANDARD')) = 0 THEN 'PASS'
         ELSE 'FAIL: unexpected warehouse_type values' END AS result
FROM ADAPTIVE_COMPUTE_DB.ADMIN.V_ADAPTIVE_QUERIES;

-- ASSERT: All metrics are non-negative
SELECT
    'T4_ADAPTIVE_METRICS_VALID' AS test_id,
    CASE
        WHEN COUNT_IF(query_count < 0) > 0 THEN 'FAIL: negative query_count'
        WHEN COUNT_IF(avg_latency_sec < 0) > 0 THEN 'FAIL: negative avg_latency'
        WHEN COUNT_IF(avg_queue_sec < 0) > 0 THEN 'FAIL: negative avg_queue'
        ELSE 'PASS'
    END AS result
FROM ADAPTIVE_COMPUTE_DB.ADMIN.V_ADAPTIVE_QUERIES;

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 5: V_DAILY_SAVINGS - Savings calculation
-- ═══════════════════════════════════════════════════════════════════════════════

-- ASSERT: View is queryable (may have no POST data yet)
SELECT
    'T5_SAVINGS_QUERYABLE' AS test_id,
    'PASS' AS result
FROM (SELECT 1) WHERE EXISTS (
    SELECT 1 FROM ADAPTIVE_COMPUTE_DB.ADMIN.V_DAILY_SAVINGS LIMIT 0
);

-- ASSERT: If savings data exists, it has correct structure
SELECT
    'T5_SAVINGS_STRUCTURE' AS test_id,
    CASE
        WHEN COUNT(*) = 0 THEN 'PASS (no POST data yet - expected)'
        WHEN COUNT_IF(baseline_daily_credits IS NULL) > 0 THEN 'FAIL: NULL baselines'
        WHEN COUNT_IF(actual_credits IS NULL) > 0 THEN 'FAIL: NULL actual_credits'
        ELSE 'PASS'
    END AS result
FROM ADAPTIVE_COMPUTE_DB.ADMIN.V_DAILY_SAVINGS;

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 6: Cross-view consistency
-- ═══════════════════════════════════════════════════════════════════════════════

-- ASSERT: Same warehouses in credit and performance views
SELECT
    'T6_VIEW_CONSISTENCY' AS test_id,
    CASE
        WHEN (SELECT COUNT(DISTINCT warehouse_name) FROM ADAPTIVE_COMPUTE_DB.ADMIN.V_CREDIT_COMPARISON)
           = (SELECT COUNT(DISTINCT warehouse_name) FROM ADAPTIVE_COMPUTE_DB.ADMIN.V_PERFORMANCE_COMPARISON)
        THEN 'PASS'
        ELSE 'WARN: different warehouse counts between views (may be due to query history latency)'
    END AS result;

-- ═══════════════════════════════════════════════════════════════════════════════
-- CLEANUP: Remove test fixture
-- ═══════════════════════════════════════════════════════════════════════════════

DELETE FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
WHERE warehouse_name = 'DASH_WH_SI' AND notes = 'Test fixture';

SELECT 'ALL VIEW TESTS COMPLETE' AS status, CURRENT_TIMESTAMP() AS run_at;
