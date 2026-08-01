-- Stored procedures for Adaptive Compute migration

--------------------------------------------------------------------------------
-- MIGRATION PROCEDURES
-- Provides safe, auditable warehouse migration with baseline capture and
-- rollback capability.
--
-- NOTE: Uses CREATE ADAPTIVE WAREHOUSE for new warehouses, and
-- ALTER WAREHOUSE SET WAREHOUSE_TYPE = 'ADAPTIVE' for conversions.
-- Both are zero-downtime operations per Snowflake docs.
--------------------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS ADAPTIVE_COMPUTE_DB;
CREATE SCHEMA IF NOT EXISTS ADAPTIVE_COMPUTE_DB.ADMIN;
USE SCHEMA ADAPTIVE_COMPUTE_DB.ADMIN;

-- Migration audit table
CREATE TABLE IF NOT EXISTS ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG (
    migration_id STRING DEFAULT UUID_STRING(),
    warehouse_name STRING NOT NULL,
    action STRING NOT NULL,
    previous_type STRING,
    new_type STRING,
    previous_size STRING,
    migrated_by STRING DEFAULT CURRENT_USER(),
    migrated_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    baseline_credits_7d FLOAT,
    notes STRING
);

-- Single warehouse migration procedure
CREATE OR REPLACE PROCEDURE ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATE_WAREHOUSE(
    P_WAREHOUSE_NAME STRING
)
RETURNS STRING
LANGUAGE SQL
AS
BEGIN
    -- Capture baseline credits
    LET baseline_credits FLOAT := 0;

    SELECT COALESCE(SUM(credits_used), 0)
    INTO :baseline_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE warehouse_name = :P_WAREHOUSE_NAME
      AND start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP());

    -- Execute migration (zero downtime)
    EXECUTE IMMEDIATE 'ALTER WAREHOUSE ' || :P_WAREHOUSE_NAME || ' SET WAREHOUSE_TYPE = ''ADAPTIVE''';

    -- Log migration
    INSERT INTO ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
        (warehouse_name, action, previous_type, new_type, baseline_credits_7d, notes)
    VALUES
        (:P_WAREHOUSE_NAME, 'MIGRATE', 'STANDARD', 'ADAPTIVE', :baseline_credits,
         'Baseline: ' || :baseline_credits || ' credits over 7 days');

    RETURN 'SUCCESS: ' || :P_WAREHOUSE_NAME || ' migrated to ADAPTIVE. Baseline: ' || :baseline_credits || ' credits/7d';
END;

-- Rollback procedure
CREATE OR REPLACE PROCEDURE ADAPTIVE_COMPUTE_DB.ADMIN.ROLLBACK_WAREHOUSE(
    P_WAREHOUSE_NAME STRING,
    P_REASON STRING DEFAULT 'Manual rollback'
)
RETURNS STRING
LANGUAGE SQL
AS
BEGIN
    EXECUTE IMMEDIATE 'ALTER WAREHOUSE ' || :P_WAREHOUSE_NAME || ' SET WAREHOUSE_TYPE = ''STANDARD''';

    INSERT INTO ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
        (warehouse_name, action, previous_type, new_type, notes)
    VALUES
        (:P_WAREHOUSE_NAME, 'ROLLBACK', 'ADAPTIVE', 'STANDARD', :P_REASON);

    RETURN 'ROLLED BACK: ' || :P_WAREHOUSE_NAME || ' reverted to STANDARD. Reason: ' || :P_REASON;
END;

-- Health check procedure
CREATE OR REPLACE PROCEDURE ADAPTIVE_COMPUTE_DB.ADMIN.HEALTH_CHECK()
RETURNS TABLE(
    warehouse_name STRING,
    days_since_migration FLOAT,
    baseline_credits_7d FLOAT,
    current_credits_7d FLOAT,
    credit_change_pct FLOAT,
    status STRING
)
LANGUAGE SQL
AS
BEGIN
    LET results RESULTSET := (
        WITH migrations AS (
            SELECT
                warehouse_name,
                baseline_credits_7d,
                migrated_at,
                DATEDIFF('day', migrated_at, CURRENT_TIMESTAMP()) AS days_since
            FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
            WHERE action = 'MIGRATE'
            QUALIFY ROW_NUMBER() OVER (PARTITION BY warehouse_name ORDER BY migrated_at DESC) = 1
        ),
        current_usage AS (
            SELECT
                warehouse_name,
                SUM(credits_used) AS current_credits_7d
            FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
            WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
            GROUP BY 1
        )
        SELECT
            m.warehouse_name,
            m.days_since::FLOAT AS days_since_migration,
            m.baseline_credits_7d,
            COALESCE(c.current_credits_7d, 0) AS current_credits_7d,
            ROUND((COALESCE(c.current_credits_7d, 0) / NULLIF(m.baseline_credits_7d, 0) - 1) * 100, 1) AS credit_change_pct,
            CASE
                WHEN COALESCE(c.current_credits_7d, 0) / NULLIF(m.baseline_credits_7d, 0) > 1.5 THEN 'WARNING'
                WHEN COALESCE(c.current_credits_7d, 0) / NULLIF(m.baseline_credits_7d, 0) > 1.2 THEN 'REVIEW'
                ELSE 'HEALTHY'
            END AS status
        FROM migrations m
        LEFT JOIN current_usage c ON m.warehouse_name = c.warehouse_name
    );
    RETURN TABLE(results);
END;
