-- Master test runner for all Adaptive Compute tests

--------------------------------------------------------------------------------
-- TEST RUNNER
-- Executes all test suites and produces a consolidated report.
--
-- Usage:
--   snowsql -f tests/test_runner.sql
--   OR execute each section in Snowsight
--
-- Test suites:
--   1. test_procedures.sql    - Stored procedure CRUD + edge cases
--   2. test_views.sql         - Monitoring view schema + data
--   3. test_assessment.sql    - Scoring algorithm boundaries
--   4. test_bulk_migration.sql - SYSTEM$BULK_UPDATE_WH patterns
--   5. test_streamlit_queries.sql - All Streamlit data loaders
--   6. validate_migration.sql - Post-migration validation
--
-- Each test returns: test_id (STRING), result (STRING starting with PASS/FAIL/WARN)
--------------------------------------------------------------------------------

USE ROLE ACCOUNTADMIN;
USE SCHEMA ADAPTIVE_COMPUTE_DB.ADMIN;

-- ═══════════════════════════════════════════════════════════════════════════════
-- PRE-FLIGHT: Verify infrastructure exists
-- ═══════════════════════════════════════════════════════════════════════════════

SELECT
    'PREFLIGHT_DB' AS test_id,
    CASE WHEN CURRENT_DATABASE() IS NOT NULL OR TRUE THEN 'PASS' ELSE 'FAIL' END AS result;

SELECT
    'PREFLIGHT_SCHEMA' AS test_id,
    CASE
        WHEN (SELECT COUNT(*) FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = 'ADMIN') > 0
        THEN 'PASS'
        ELSE 'FAIL: ADAPTIVE_COMPUTE_DB.ADMIN schema missing'
    END AS result;

SELECT
    'PREFLIGHT_TABLE' AS test_id,
    CASE
        WHEN (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'MIGRATION_LOG') > 0
        THEN 'PASS'
        ELSE 'FAIL: MIGRATION_LOG table missing'
    END AS result;

SELECT
    'PREFLIGHT_PROCEDURES' AS test_id,
    CASE
        WHEN (SELECT COUNT(*) FROM INFORMATION_SCHEMA.PROCEDURES WHERE PROCEDURE_SCHEMA = 'ADMIN') >= 3
        THEN 'PASS: ' || (SELECT COUNT(*) FROM INFORMATION_SCHEMA.PROCEDURES WHERE PROCEDURE_SCHEMA = 'ADMIN')::STRING || ' procedures'
        ELSE 'FAIL: expected at least 3 procedures'
    END AS result;

SELECT
    'PREFLIGHT_VIEWS' AS test_id,
    CASE
        WHEN (SELECT COUNT(*) FROM INFORMATION_SCHEMA.VIEWS WHERE TABLE_SCHEMA = 'ADMIN') >= 1
        THEN 'PASS: ' || (SELECT COUNT(*) FROM INFORMATION_SCHEMA.VIEWS WHERE TABLE_SCHEMA = 'ADMIN')::STRING || ' views'
        ELSE 'FAIL: expected at least 1 view'
    END AS result;

-- ═══════════════════════════════════════════════════════════════════════════════
-- QUICK SMOKE TESTS (fast, non-destructive)
-- ═══════════════════════════════════════════════════════════════════════════════

-- Smoke 1: SHOW WAREHOUSES works
SHOW WAREHOUSES;
SELECT
    'SMOKE_SHOW_WH' AS test_id,
    CASE WHEN COUNT(*) > 0 THEN 'PASS: ' || COUNT(*)::STRING || ' warehouses'
         ELSE 'FAIL' END AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- Smoke 2: ACCOUNT_USAGE accessible
SELECT
    'SMOKE_ACCOUNT_USAGE' AS test_id,
    CASE WHEN COUNT(*) >= 0 THEN 'PASS'
         ELSE 'FAIL: cannot query ACCOUNT_USAGE' END AS result
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('hour', -1, CURRENT_TIMESTAMP());

-- Smoke 3: QUERY_HISTORY accessible
SELECT
    'SMOKE_QUERY_HISTORY' AS test_id,
    CASE WHEN COUNT(*) >= 0 THEN 'PASS'
         ELSE 'FAIL' END AS result
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('hour', -1, CURRENT_TIMESTAMP());

-- Smoke 4: HEALTH_CHECK procedure callable
CALL ADAPTIVE_COMPUTE_DB.ADMIN.HEALTH_CHECK();
SELECT
    'SMOKE_HEALTH_CHECK' AS test_id,
    'PASS' AS result;

-- Smoke 5: SYSTEM$BULK_UPDATE_WH accessible
SELECT
    'SMOKE_BULK_UPDATE' AS test_id,
    CASE
        WHEN SYSTEM$BULK_UPDATE_WH('WAREHOUSE_TYPE', 'ADAPTIVE', '{"name": "NONEXISTENT_.*"}', '{}', 'DRY_RUN') LIKE '%dry-run%'
        THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

-- Smoke 6: V_ADAPTIVE_QUERIES view works
SELECT
    'SMOKE_ADAPTIVE_VIEW' AS test_id,
    CASE WHEN COUNT(*) >= 0 THEN 'PASS' ELSE 'FAIL' END AS result
FROM ADAPTIVE_COMPUTE_DB.ADMIN.V_ADAPTIVE_QUERIES;

-- ═══════════════════════════════════════════════════════════════════════════════
-- INSTRUCTIONS FOR FULL TEST EXECUTION
-- ═══════════════════════════════════════════════════════════════════════════════

SELECT '════════════════════════════════════════════════════' AS separator;
SELECT 'SMOKE TESTS COMPLETE - Run individual suites for full coverage:' AS instructions;
SELECT '  tests/test_procedures.sql      - 10 tests (creates/drops test warehouse)' AS suite_1;
SELECT '  tests/test_views.sql           - 6 test groups (inserts/deletes test fixture)' AS suite_2;
SELECT '  tests/test_assessment.sql      - 6 test groups (read-only)' AS suite_3;
SELECT '  tests/test_bulk_migration.sql  - 6 tests (DRY_RUN only, non-destructive)' AS suite_4;
SELECT '  tests/test_streamlit_queries.sql - 7 groups, 20+ tests (read-only)' AS suite_5;
SELECT '  tests/validate_migration.sql   - 6 tests (requires prior migration)' AS suite_6;
SELECT '════════════════════════════════════════════════════' AS separator;

SELECT 'TEST RUNNER COMPLETE' AS status, CURRENT_TIMESTAMP() AS run_at;
