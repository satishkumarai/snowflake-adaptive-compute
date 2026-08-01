-- Execute migration for target warehouses

--------------------------------------------------------------------------------
-- MIGRATION EXECUTION TEMPLATE
-- Each migration is an online operation (zero downtime).
-- Running queries complete on existing resources; new queries use Adaptive.
--
-- LIMITATIONS (per Snowflake docs):
--   - Cannot convert X5Large or X6Large warehouses
--   - Cannot convert Snowpark-optimized or interactive warehouses
--   - Enterprise Edition or higher required
--------------------------------------------------------------------------------

USE SCHEMA ADAPTIVE_COMPUTE_DB.ADMIN;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Option A: Migrate specific warehouses using our logged procedure
-- ═══════════════════════════════════════════════════════════════════════════════

-- CALL ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATE_WAREHOUSE('DEV_WH');
-- CALL ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATE_WAREHOUSE('ANALYTICS_WH');
-- CALL ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATE_WAREHOUSE('ETL_WH');

-- ═══════════════════════════════════════════════════════════════════════════════
-- Option B: Direct ALTER (simplest, no logging)
-- ═══════════════════════════════════════════════════════════════════════════════

-- ALTER WAREHOUSE MY_WAREHOUSE SET WAREHOUSE_TYPE = 'ADAPTIVE';

-- ═══════════════════════════════════════════════════════════════════════════════
-- Option C: Bulk migration using SYSTEM$BULK_UPDATE_WH (built-in)
-- Recommended for migrating many warehouses at once.
-- ═══════════════════════════════════════════════════════════════════════════════

-- Step 1: DRY RUN (review what would be migrated)
-- Parameters: property_name, new_value, property_filter, tag_filter, execution_mode
SELECT SYSTEM$BULK_UPDATE_WH(
    'WAREHOUSE_TYPE',
    'ADAPTIVE',
    '{"WAREHOUSE_TYPE": "STANDARD"}',
    '{}',
    'DRY_RUN'
);

-- Step 2: Review output, then execute for real
-- SELECT SYSTEM$BULK_UPDATE_WH(
--     'WAREHOUSE_TYPE',
--     'ADAPTIVE',
--     '{"WAREHOUSE_TYPE": "STANDARD"}',
--     '{}',
--     'ACTIVE'
-- );

-- Filter by name pattern:
-- SELECT SYSTEM$BULK_UPDATE_WH(
--     'WAREHOUSE_TYPE',
--     'ADAPTIVE',
--     '{"WAREHOUSE_TYPE": "STANDARD", "name": "ANALYTICS_.*"}',
--     '{}',
--     'DRY_RUN'
-- );

-- ═══════════════════════════════════════════════════════════════════════════════
-- Option D: Create new Adaptive Warehouse from scratch
-- ═══════════════════════════════════════════════════════════════════════════════

-- CREATE ADAPTIVE WAREHOUSE my_new_wh
--     WITH MAX_QUERY_PERFORMANCE_LEVEL = XLARGE
--          QUERY_THROUGHPUT_MULTIPLIER = 2;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Verify migrations
-- ═══════════════════════════════════════════════════════════════════════════════

-- Check warehouse types via SHOW WAREHOUSES
SHOW WAREHOUSES;
SELECT "name", "type", "state", "max_query_performance_level", "query_throughput_multiplier"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "type" DESC, "name";

-- Check migration log
SELECT * FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG ORDER BY migrated_at DESC;
