-- Post-migration validation tests

--------------------------------------------------------------------------------
-- VALIDATION SUITE
-- Run after migration to confirm everything is working correctly.
-- All tests return PASS/FAIL with context.
--
-- Key: Uses SHOW WAREHOUSES for type detection (not ACCOUNT_USAGE.WAREHOUSES).
-- Uses warehouse_size = 'ADAPTIVE' in QUERY_HISTORY per Snowflake docs.
--------------------------------------------------------------------------------

-- Step 0: Capture warehouse state
SHOW WAREHOUSES;
CREATE OR REPLACE TEMPORARY TABLE _validation_warehouses AS
SELECT "name" AS warehouse_name, "type" AS warehouse_type, "state" AS state
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- Test 1: Warehouse type is ADAPTIVE
SELECT
    'T1_WAREHOUSE_TYPE' AS test,
    v.warehouse_name,
    CASE WHEN v.warehouse_type = 'ADAPTIVE' THEN 'PASS' ELSE 'FAIL' END AS result,
    v.warehouse_type || ' (state: ' || v.state || ')' AS detail
FROM _validation_warehouses v
WHERE v.warehouse_name IN (
    SELECT DISTINCT warehouse_name
    FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
    WHERE action = 'MIGRATE'
);

-- Test 2: Queries executing successfully (no new error patterns)
SELECT
    'T2_ERROR_RATE' AS test,
    warehouse_name,
    CASE
        WHEN COUNT_IF(execution_status != 'SUCCESS') / NULLIF(COUNT(*), 0) < 0.01 THEN 'PASS'
        ELSE 'FAIL'
    END AS result,
    ROUND(COUNT_IF(execution_status != 'SUCCESS') / NULLIF(COUNT(*), 0) * 100, 2) || '% error rate' AS detail
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE warehouse_name IN (
    SELECT DISTINCT warehouse_name
    FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
    WHERE action = 'MIGRATE'
)
AND start_time >= DATEADD('hour', -6, CURRENT_TIMESTAMP())
GROUP BY 1, 2;

-- Test 3: No excessive queuing post-migration
-- If seeing queuing, increase QUERY_THROUGHPUT_MULTIPLIER
SELECT
    'T3_QUEUE_TIME' AS test,
    warehouse_name,
    CASE
        WHEN MAX(queued_overload_time) < 30000 THEN 'PASS'
        ELSE 'WARN - consider increasing QUERY_THROUGHPUT_MULTIPLIER'
    END AS result,
    ROUND(MAX(queued_overload_time)/1000, 1) || 's max queue' AS detail
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE warehouse_name IN (
    SELECT DISTINCT warehouse_name
    FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
    WHERE action = 'MIGRATE'
)
AND start_time >= DATEADD('hour', -6, CURRENT_TIMESTAMP())
GROUP BY 1, 2;

-- Test 4: Credit consumption within acceptable range
SELECT
    'T4_CREDIT_RANGE' AS test,
    ml.warehouse_name,
    CASE
        WHEN COALESCE(SUM(h.credits_used), 0) <= ml.baseline_credits_7d / 7 / 24 * 6 * 1.5
            THEN 'PASS'
        ELSE 'WARN'
    END AS result,
    ROUND(COALESCE(SUM(h.credits_used), 0), 2) || ' credits (6h) vs ' ||
    ROUND(ml.baseline_credits_7d / 7 / 24 * 6, 2) || ' baseline' AS detail
FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG ml
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY h
    ON ml.warehouse_name = h.warehouse_name
    AND h.start_time >= DATEADD('hour', -6, CURRENT_TIMESTAMP())
WHERE ml.action = 'MIGRATE'
GROUP BY 1, 2, ml.baseline_credits_7d
QUALIFY ROW_NUMBER() OVER (PARTITION BY ml.warehouse_name ORDER BY ml.migrated_at DESC) = 1;

-- Test 5: Queries are running as ADAPTIVE type
-- Per docs: warehouse_size = 'ADAPTIVE' in QUERY_HISTORY
SELECT
    'T5_ADAPTIVE_QUERIES' AS test,
    warehouse_name,
    CASE
        WHEN COUNT_IF(warehouse_size = 'ADAPTIVE') > 0 THEN 'PASS'
        ELSE 'WAITING - no adaptive queries recorded yet (latency up to 45 min)'
    END AS result,
    COUNT_IF(warehouse_size = 'ADAPTIVE') || ' adaptive queries / ' || COUNT(*) || ' total' AS detail
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE warehouse_name IN (
    SELECT DISTINCT warehouse_name
    FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
    WHERE action = 'MIGRATE'
)
AND start_time >= DATEADD('hour', -6, CURRENT_TIMESTAMP())
GROUP BY 1, 2;

-- Test 6: Migration log integrity
SELECT
    'T6_MIGRATION_LOG' AS test,
    CASE
        WHEN COUNT(*) > 0 THEN 'PASS'
        ELSE 'FAIL - no migrations recorded'
    END AS result,
    COUNT(*) || ' migration(s) recorded' AS detail
FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
WHERE action = 'MIGRATE';

-- Summary
SELECT 'VALIDATION COMPLETE' AS status, CURRENT_TIMESTAMP() AS run_at;
