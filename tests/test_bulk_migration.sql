-- Test suite for SYSTEM$BULK_UPDATE_WH function

--------------------------------------------------------------------------------
-- TEST SUITE: BULK MIGRATION
-- Tests SYSTEM$BULK_UPDATE_WH with various filter combinations.
-- All tests use DRY_RUN mode (no actual migrations).
--
-- Function signature (5 parameters):
--   SYSTEM$BULK_UPDATE_WH(property_name, new_value, property_filter, tag_filter, execution_mode)
--------------------------------------------------------------------------------

USE SCHEMA ADAPTIVE_COMPUTE_DB.ADMIN;

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 1: Basic dry run - all standard warehouses
-- ═══════════════════════════════════════════════════════════════════════════════

SELECT
    'T1_BASIC_DRY_RUN' AS test_id,
    CASE
        WHEN result LIKE '%dry-run%' AND result LIKE '%total_warehouses%'
        THEN 'PASS: ' || PARSE_JSON(result)[0]['total_warehouses']::STRING || ' warehouses found'
        ELSE 'FAIL: unexpected output format'
    END AS result
FROM (
    SELECT SYSTEM$BULK_UPDATE_WH(
        'WAREHOUSE_TYPE', 'ADAPTIVE',
        '{"WAREHOUSE_TYPE": "STANDARD"}',
        '{}',
        'DRY_RUN'
    ) AS result
);

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 2: Filter by name pattern
-- ═══════════════════════════════════════════════════════════════════════════════

SELECT
    'T2_NAME_FILTER' AS test_id,
    CASE
        WHEN result LIKE '%dry-run%' THEN 'PASS'
        ELSE 'FAIL'
    END AS result
FROM (
    SELECT SYSTEM$BULK_UPDATE_WH(
        'WAREHOUSE_TYPE', 'ADAPTIVE',
        '{"WAREHOUSE_TYPE": "STANDARD", "name": "COMPUTE_.*"}',
        '{}',
        'DRY_RUN'
    ) AS result
);

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 3: Filter that matches nothing
-- ═══════════════════════════════════════════════════════════════════════════════

SELECT
    'T3_NO_MATCH' AS test_id,
    CASE
        WHEN PARSE_JSON(result)[0]['total_warehouses']::INT = 0 THEN 'PASS: 0 warehouses (correct)'
        ELSE 'FAIL: expected 0 matches'
    END AS result
FROM (
    SELECT SYSTEM$BULK_UPDATE_WH(
        'WAREHOUSE_TYPE', 'ADAPTIVE',
        '{"WAREHOUSE_TYPE": "STANDARD", "name": "NONEXISTENT_WH_XYZ_.*"}',
        '{}',
        'DRY_RUN'
    ) AS result
);

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 4: Reverse direction - ADAPTIVE to STANDARD
-- ═══════════════════════════════════════════════════════════════════════════════

SELECT
    'T4_REVERSE_DIRECTION' AS test_id,
    CASE
        WHEN result LIKE '%dry-run%' THEN 'PASS'
        ELSE 'FAIL'
    END AS result
FROM (
    SELECT SYSTEM$BULK_UPDATE_WH(
        'WAREHOUSE_TYPE', 'STANDARD',
        '{"WAREHOUSE_TYPE": "ADAPTIVE"}',
        '{}',
        'DRY_RUN'
    ) AS result
);

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 5: Output structure validation
-- ═══════════════════════════════════════════════════════════════════════════════

SELECT
    'T5_OUTPUT_STRUCTURE' AS test_id,
    CASE
        WHEN PARSE_JSON(result)[0]['property_to_update']::STRING = 'WAREHOUSE_TYPE'
             AND PARSE_JSON(result)[0]['property_value_to_set']::STRING = 'ADAPTIVE'
             AND PARSE_JSON(result)[0]['mode']::STRING = 'dry-run'
        THEN 'PASS'
        ELSE 'FAIL: unexpected output structure'
    END AS result
FROM (
    SELECT SYSTEM$BULK_UPDATE_WH(
        'WAREHOUSE_TYPE', 'ADAPTIVE',
        '{"WAREHOUSE_TYPE": "STANDARD"}',
        '{}',
        'DRY_RUN'
    ) AS result
);

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 6: Each matched warehouse has expected fields
-- ═══════════════════════════════════════════════════════════════════════════════

SELECT
    'T6_WH_FIELDS' AS test_id,
    CASE
        WHEN PARSE_JSON(result)[1]['name'] IS NOT NULL
             AND PARSE_JSON(result)[1]['warehouse_size'] IS NOT NULL
             AND PARSE_JSON(result)[1]['max_query_performance_level'] IS NOT NULL
             AND PARSE_JSON(result)[1]['query_throughput_multiplier'] IS NOT NULL
        THEN 'PASS: name=' || PARSE_JSON(result)[1]['name']::STRING
             || ', perf=' || PARSE_JSON(result)[1]['max_query_performance_level']::STRING
             || ', throughput=' || PARSE_JSON(result)[1]['query_throughput_multiplier']::STRING
        ELSE 'FAIL: missing expected fields in warehouse details'
    END AS result
FROM (
    SELECT SYSTEM$BULK_UPDATE_WH(
        'WAREHOUSE_TYPE', 'ADAPTIVE',
        '{"WAREHOUSE_TYPE": "STANDARD"}',
        '{}',
        'DRY_RUN'
    ) AS result
);

SELECT 'ALL BULK MIGRATION TESTS COMPLETE' AS status, CURRENT_TIMESTAMP() AS run_at;
