-- Comprehensive test suite for Adaptive Compute stored procedures

--------------------------------------------------------------------------------
-- TEST SUITE: STORED PROCEDURES
-- Tests MIGRATE_WAREHOUSE, ROLLBACK_WAREHOUSE, CONDITIONAL_ROLLBACK, HEALTH_CHECK
-- Each test follows: ARRANGE → ACT → ASSERT pattern
--
-- REQUIREMENTS:
--   - ACCOUNTADMIN role
--   - ADAPTIVE_COMPUTE_DB.ADMIN schema exists with all procedures deployed
--   - At least one standard warehouse available for testing
--
-- WARNING: These tests perform REAL migrations. Use a test warehouse only.
--------------------------------------------------------------------------------

USE SCHEMA ADAPTIVE_COMPUTE_DB.ADMIN;

-- ═══════════════════════════════════════════════════════════════════════════════
-- SETUP: Create a dedicated test warehouse
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE WAREHOUSE IF NOT EXISTS ADAPTIVE_TEST_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE;

-- Clean up any prior test data
DELETE FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
WHERE warehouse_name = 'ADAPTIVE_TEST_WH';

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 1: MIGRATE_WAREHOUSE - Happy path
-- ═══════════════════════════════════════════════════════════════════════════════

-- ACT
CALL ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATE_WAREHOUSE('ADAPTIVE_TEST_WH');

-- ASSERT: Warehouse is now ADAPTIVE
SHOW WAREHOUSES LIKE 'ADAPTIVE_TEST_WH';
SELECT
    'T1_MIGRATE_TYPE' AS test_id,
    CASE WHEN "type" = 'ADAPTIVE' THEN 'PASS' ELSE 'FAIL: type=' || "type" END AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = 'ADAPTIVE_TEST_WH';

-- ASSERT: State should be ENABLED (not STARTED/SUSPENDED)
SHOW WAREHOUSES LIKE 'ADAPTIVE_TEST_WH';
SELECT
    'T1_MIGRATE_STATE' AS test_id,
    CASE WHEN "state" IN ('ENABLED', 'DISABLED') THEN 'PASS'
         ELSE 'FAIL: state=' || "state" END AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = 'ADAPTIVE_TEST_WH';

-- ASSERT: Migration log entry created
SELECT
    'T1_MIGRATE_LOG' AS test_id,
    CASE WHEN COUNT(*) = 1 THEN 'PASS'
         ELSE 'FAIL: expected 1 row, got ' || COUNT(*)::STRING END AS result
FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
WHERE warehouse_name = 'ADAPTIVE_TEST_WH' AND action = 'MIGRATE';

-- ASSERT: Baseline credits captured (should be >= 0)
SELECT
    'T1_MIGRATE_BASELINE' AS test_id,
    CASE WHEN baseline_credits_7d >= 0 THEN 'PASS'
         ELSE 'FAIL: baseline_credits_7d is NULL or negative' END AS result
FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
WHERE warehouse_name = 'ADAPTIVE_TEST_WH' AND action = 'MIGRATE'
ORDER BY migrated_at DESC LIMIT 1;

-- ASSERT: MAX_QUERY_PERFORMANCE_LEVEL was auto-derived
SHOW WAREHOUSES LIKE 'ADAPTIVE_TEST_WH';
SELECT
    'T1_MIGRATE_PERF_LEVEL' AS test_id,
    CASE WHEN "max_query_performance_level" IS NOT NULL
              AND "max_query_performance_level" != 'None'
         THEN 'PASS: level=' || "max_query_performance_level"
         ELSE 'FAIL: perf level not set' END AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = 'ADAPTIVE_TEST_WH';

-- ASSERT: QUERY_THROUGHPUT_MULTIPLIER was auto-derived
SHOW WAREHOUSES LIKE 'ADAPTIVE_TEST_WH';
SELECT
    'T1_MIGRATE_THROUGHPUT' AS test_id,
    CASE WHEN "query_throughput_multiplier" IS NOT NULL
         THEN 'PASS: multiplier=' || "query_throughput_multiplier"
         ELSE 'FAIL: throughput multiplier not set' END AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = 'ADAPTIVE_TEST_WH';

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 2: MIGRATE_WAREHOUSE - Idempotency (already adaptive)
-- ═══════════════════════════════════════════════════════════════════════════════

-- ACT: Migrate again (should succeed - ALTER is idempotent)
CALL ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATE_WAREHOUSE('ADAPTIVE_TEST_WH');

-- ASSERT: Still ADAPTIVE
SHOW WAREHOUSES LIKE 'ADAPTIVE_TEST_WH';
SELECT
    'T2_IDEMPOTENT' AS test_id,
    CASE WHEN "type" = 'ADAPTIVE' THEN 'PASS' ELSE 'FAIL' END AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = 'ADAPTIVE_TEST_WH';

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 3: ROLLBACK_WAREHOUSE - Happy path
-- ═══════════════════════════════════════════════════════════════════════════════

-- ACT
CALL ADAPTIVE_COMPUTE_DB.ADMIN.ROLLBACK_WAREHOUSE('ADAPTIVE_TEST_WH', 'Test rollback');

-- ASSERT: Warehouse is now STANDARD
SHOW WAREHOUSES LIKE 'ADAPTIVE_TEST_WH';
SELECT
    'T3_ROLLBACK_TYPE' AS test_id,
    CASE WHEN "type" = 'STANDARD' THEN 'PASS' ELSE 'FAIL: type=' || "type" END AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = 'ADAPTIVE_TEST_WH';

-- ASSERT: State should be STARTED or SUSPENDED (standard WH states)
SHOW WAREHOUSES LIKE 'ADAPTIVE_TEST_WH';
SELECT
    'T3_ROLLBACK_STATE' AS test_id,
    CASE WHEN "state" IN ('STARTED', 'SUSPENDED') THEN 'PASS'
         ELSE 'FAIL: state=' || "state" END AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = 'ADAPTIVE_TEST_WH';

-- ASSERT: Rollback log entry created with reason
SELECT
    'T3_ROLLBACK_LOG' AS test_id,
    CASE WHEN COUNT(*) >= 1 AND MAX(notes) = 'Test rollback' THEN 'PASS'
         ELSE 'FAIL' END AS result
FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
WHERE warehouse_name = 'ADAPTIVE_TEST_WH' AND action = 'ROLLBACK';

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 4: ROLLBACK_WAREHOUSE - Default reason
-- ═══════════════════════════════════════════════════════════════════════════════

-- ARRANGE: Migrate first
CALL ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATE_WAREHOUSE('ADAPTIVE_TEST_WH');

-- ACT: Rollback with default reason
CALL ADAPTIVE_COMPUTE_DB.ADMIN.ROLLBACK_WAREHOUSE('ADAPTIVE_TEST_WH');

-- ASSERT: Default reason captured
SELECT
    'T4_DEFAULT_REASON' AS test_id,
    CASE WHEN notes = 'Manual rollback requested' THEN 'PASS'
         ELSE 'FAIL: notes=' || COALESCE(notes, 'NULL') END AS result
FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
WHERE warehouse_name = 'ADAPTIVE_TEST_WH' AND action = 'ROLLBACK'
ORDER BY migrated_at DESC LIMIT 1;

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 5: CONDITIONAL_ROLLBACK - No action (within threshold)
-- ═══════════════════════════════════════════════════════════════════════════════

-- ARRANGE: Migrate first
CALL ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATE_WAREHOUSE('ADAPTIVE_TEST_WH');

-- ACT: Check with a very high threshold (should NOT rollback)
CALL ADAPTIVE_COMPUTE_DB.ADMIN.CONDITIONAL_ROLLBACK('ADAPTIVE_TEST_WH', 99999.0, 6);

-- ASSERT: Still ADAPTIVE (no rollback triggered)
SHOW WAREHOUSES LIKE 'ADAPTIVE_TEST_WH';
SELECT
    'T5_CONDITIONAL_NO_ACTION' AS test_id,
    CASE WHEN "type" = 'ADAPTIVE' THEN 'PASS' ELSE 'FAIL: rolled back unexpectedly' END AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = 'ADAPTIVE_TEST_WH';

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 6: CONDITIONAL_ROLLBACK - Trigger rollback (very low threshold)
-- ═══════════════════════════════════════════════════════════════════════════════

-- ACT: Use threshold of -100% (any usage triggers rollback)
CALL ADAPTIVE_COMPUTE_DB.ADMIN.CONDITIONAL_ROLLBACK('ADAPTIVE_TEST_WH', -100.0, 6);

-- ASSERT: Should be STANDARD now (rollback triggered)
SHOW WAREHOUSES LIKE 'ADAPTIVE_TEST_WH';
SELECT
    'T6_CONDITIONAL_TRIGGERED' AS test_id,
    CASE WHEN "type" = 'STANDARD' THEN 'PASS'
         ELSE 'FAIL: expected STANDARD after conditional rollback, got ' || "type" END AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = 'ADAPTIVE_TEST_WH';

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 7: HEALTH_CHECK - Returns data
-- ═══════════════════════════════════════════════════════════════════════════════

-- ACT
CALL ADAPTIVE_COMPUTE_DB.ADMIN.HEALTH_CHECK();

-- ASSERT: Returns non-empty string mentioning test warehouse
SELECT
    'T7_HEALTH_CHECK' AS test_id,
    CASE WHEN (SELECT ADAPTIVE_COMPUTE_DB.ADMIN.HEALTH_CHECK()) LIKE '%ADAPTIVE_TEST_WH%'
         THEN 'PASS' ELSE 'FAIL: ADAPTIVE_TEST_WH not in health check output' END AS result;

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 8: MIGRATION_LOG - Data integrity
-- ═══════════════════════════════════════════════════════════════════════════════

-- ASSERT: All required columns populated
SELECT
    'T8_LOG_INTEGRITY' AS test_id,
    CASE
        WHEN COUNT_IF(migration_id IS NULL) > 0 THEN 'FAIL: NULL migration_id'
        WHEN COUNT_IF(warehouse_name IS NULL) > 0 THEN 'FAIL: NULL warehouse_name'
        WHEN COUNT_IF(action IS NULL) > 0 THEN 'FAIL: NULL action'
        WHEN COUNT_IF(migrated_by IS NULL) > 0 THEN 'FAIL: NULL migrated_by'
        WHEN COUNT_IF(migrated_at IS NULL) > 0 THEN 'FAIL: NULL migrated_at'
        WHEN COUNT_IF(action NOT IN ('MIGRATE', 'ROLLBACK')) > 0 THEN 'FAIL: invalid action value'
        ELSE 'PASS'
    END AS result
FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
WHERE warehouse_name = 'ADAPTIVE_TEST_WH';

-- ASSERT: Timestamps are in correct order
SELECT
    'T8_LOG_ORDERING' AS test_id,
    CASE WHEN COUNT(*) = COUNT_IF(migrated_at <= CURRENT_TIMESTAMP()) THEN 'PASS'
         ELSE 'FAIL: future timestamps detected' END AS result
FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
WHERE warehouse_name = 'ADAPTIVE_TEST_WH';

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 9: ENABLE / DISABLE semantics
-- ═══════════════════════════════════════════════════════════════════════════════

-- ARRANGE: Migrate to adaptive
CALL ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATE_WAREHOUSE('ADAPTIVE_TEST_WH');

-- ACT: Disable
ALTER WAREHOUSE ADAPTIVE_TEST_WH DISABLE;

-- ASSERT: State is DISABLED
SHOW WAREHOUSES LIKE 'ADAPTIVE_TEST_WH';
SELECT
    'T9_DISABLE' AS test_id,
    CASE WHEN "state" = 'DISABLED' THEN 'PASS' ELSE 'FAIL: state=' || "state" END AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = 'ADAPTIVE_TEST_WH';

-- ACT: Enable
ALTER WAREHOUSE ADAPTIVE_TEST_WH ENABLE;

-- ASSERT: State is ENABLED
SHOW WAREHOUSES LIKE 'ADAPTIVE_TEST_WH';
SELECT
    'T9_ENABLE' AS test_id,
    CASE WHEN "state" = 'ENABLED' THEN 'PASS' ELSE 'FAIL: state=' || "state" END AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = 'ADAPTIVE_TEST_WH';

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 10: Parameter modification after migration
-- ═══════════════════════════════════════════════════════════════════════════════

-- ACT: Set custom parameters
ALTER WAREHOUSE ADAPTIVE_TEST_WH
    SET MAX_QUERY_PERFORMANCE_LEVEL = XLARGE
        QUERY_THROUGHPUT_MULTIPLIER = 4;

-- ASSERT: Parameters applied
SHOW WAREHOUSES LIKE 'ADAPTIVE_TEST_WH';
SELECT
    'T10_PARAMS_SET' AS test_id,
    CASE
        WHEN "max_query_performance_level" = 'X-Large'
             AND "query_throughput_multiplier" = '4'
        THEN 'PASS'
        ELSE 'FAIL: perf=' || COALESCE("max_query_performance_level", 'NULL')
             || ', throughput=' || COALESCE("query_throughput_multiplier", 'NULL')
    END AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = 'ADAPTIVE_TEST_WH';

-- ACT: Set unlimited throughput
ALTER WAREHOUSE ADAPTIVE_TEST_WH SET QUERY_THROUGHPUT_MULTIPLIER = 0;

-- ASSERT: Unlimited throughput
SHOW WAREHOUSES LIKE 'ADAPTIVE_TEST_WH';
SELECT
    'T10_UNLIMITED_THROUGHPUT' AS test_id,
    CASE WHEN "query_throughput_multiplier" = '0' THEN 'PASS'
         ELSE 'FAIL: expected 0, got ' || COALESCE("query_throughput_multiplier", 'NULL') END AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = 'ADAPTIVE_TEST_WH';

-- ═══════════════════════════════════════════════════════════════════════════════
-- CLEANUP
-- ═══════════════════════════════════════════════════════════════════════════════

-- Rollback test warehouse to standard before dropping
CALL ADAPTIVE_COMPUTE_DB.ADMIN.ROLLBACK_WAREHOUSE('ADAPTIVE_TEST_WH', 'Test cleanup');
DROP WAREHOUSE IF EXISTS ADAPTIVE_TEST_WH;

-- Clean up test log entries
DELETE FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
WHERE warehouse_name = 'ADAPTIVE_TEST_WH';

SELECT 'ALL PROCEDURE TESTS COMPLETE' AS status, CURRENT_TIMESTAMP() AS run_at;
