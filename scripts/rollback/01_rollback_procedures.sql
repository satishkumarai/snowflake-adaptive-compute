-- Rollback procedures for Adaptive Compute

--------------------------------------------------------------------------------
-- ROLLBACK AUTOMATION
-- Provides safe rollback with logging. Uses ADAPTIVE_COMPUTE_DB.ADMIN schema.
--
-- NOTE: Adaptive Warehouses use ENABLE/DISABLE (not SUSPEND/RESUME).
-- Rollback converts back to STANDARD type. Running queries complete on
-- existing Adaptive resources while new queries use Standard resources.
--------------------------------------------------------------------------------

USE SCHEMA ADAPTIVE_COMPUTE_DB.ADMIN;

-- Procedure: Rollback with reason logging
CREATE OR REPLACE PROCEDURE ADAPTIVE_COMPUTE_DB.ADMIN.ROLLBACK_WAREHOUSE(
    P_WAREHOUSE_NAME STRING,
    P_REASON STRING DEFAULT 'Manual rollback requested'
)
RETURNS STRING
LANGUAGE SQL
AS
BEGIN
    -- Execute rollback (online operation - no downtime)
    EXECUTE IMMEDIATE 'ALTER WAREHOUSE ' || :P_WAREHOUSE_NAME || ' SET WAREHOUSE_TYPE = ''STANDARD''';

    -- Log the rollback
    INSERT INTO ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
        (warehouse_name, action, previous_type, new_type, notes)
    VALUES
        (:P_WAREHOUSE_NAME, 'ROLLBACK', 'ADAPTIVE', 'STANDARD', :P_REASON);

    RETURN 'ROLLBACK COMPLETE: ' || :P_WAREHOUSE_NAME || ' reverted to STANDARD. Reason: ' || :P_REASON;
END;

-- Procedure: Conditional rollback based on credit consumption
CREATE OR REPLACE PROCEDURE ADAPTIVE_COMPUTE_DB.ADMIN.CONDITIONAL_ROLLBACK(
    P_WAREHOUSE_NAME STRING,
    P_CREDIT_THRESHOLD_PCT FLOAT DEFAULT 50.0,
    P_LOOKBACK_HOURS INT DEFAULT 6
)
RETURNS STRING
LANGUAGE SQL
AS
BEGIN
    LET baseline_hourly FLOAT;
    LET current_hourly FLOAT;

    -- Get baseline from migration log
    SELECT baseline_credits_7d / 7 / 24 INTO :baseline_hourly
    FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG
    WHERE warehouse_name = :P_WAREHOUSE_NAME
      AND action = 'MIGRATE'
    ORDER BY migrated_at DESC
    LIMIT 1;

    -- Get current hourly consumption
    SELECT COALESCE(SUM(credits_used), 0) / :P_LOOKBACK_HOURS INTO :current_hourly
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE warehouse_name = :P_WAREHOUSE_NAME
      AND start_time >= DATEADD('hour', -:P_LOOKBACK_HOURS, CURRENT_TIMESTAMP());

    -- Check threshold
    LET credit_change_pct FLOAT := ((:current_hourly / NULLIF(:baseline_hourly, 0)) - 1) * 100;

    IF (:credit_change_pct > :P_CREDIT_THRESHOLD_PCT) THEN
        CALL ADAPTIVE_COMPUTE_DB.ADMIN.ROLLBACK_WAREHOUSE(
            :P_WAREHOUSE_NAME,
            'Auto-rollback: credits ' || ROUND(:credit_change_pct, 1) || '% above baseline'
        );
        RETURN 'ROLLED BACK: Credits were ' || ROUND(:credit_change_pct, 1) || '% above baseline';
    ELSE
        RETURN 'NO ACTION: Credits at ' || ROUND(:credit_change_pct, 1) || '% vs baseline (threshold: ' || :P_CREDIT_THRESHOLD_PCT || '%)';
    END IF;
END;
