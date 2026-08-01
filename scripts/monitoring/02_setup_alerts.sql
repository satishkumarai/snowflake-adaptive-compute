-- Alert configuration for Adaptive Compute monitoring

--------------------------------------------------------------------------------
-- ALERT SETUP
-- Configures Snowflake alerts to detect cost anomalies and performance
-- regressions on Adaptive Compute warehouses.
--
-- NOTE: Replace 'ALERT_WH' with your monitoring warehouse name.
-- Replace 'team@company.com' with your notification recipient.
-- You must also create a notification integration for SYSTEM$SEND_EMAIL.
--------------------------------------------------------------------------------

USE SCHEMA ADAPTIVE_COMPUTE_DB.ADMIN;

-- Alert: Credit consumption spike (>50% above baseline for 4+ hours)
CREATE OR REPLACE ALERT ADAPTIVE_COMPUTE_DB.ADMIN.ALERT_CREDIT_SPIKE
    WAREHOUSE = DASH_WH_SI
    SCHEDULE = 'USING CRON 0 * * * * UTC'
    IF (EXISTS (
        WITH recent AS (
            SELECT
                ml.warehouse_name,
                ml.baseline_credits_7d / 7 / 24 AS baseline_hourly,
                SUM(h.credits_used) AS recent_4h_credits
            FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG ml
            JOIN SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY h
                ON ml.warehouse_name = h.warehouse_name
            WHERE ml.action = 'MIGRATE'
              AND h.start_time >= DATEADD('hour', -4, CURRENT_TIMESTAMP())
            GROUP BY 1, 2
        )
        SELECT 1
        FROM recent
        WHERE recent_4h_credits > baseline_hourly * 4 * 1.5
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'adaptive_compute_alerts',
            'team@company.com',
            'ALERT: Adaptive Compute Credit Spike',
            'One or more Adaptive warehouses consuming >50% above baseline. Run: CALL ADAPTIVE_COMPUTE_DB.ADMIN.HEALTH_CHECK()'
        );

-- Alert: Critical threshold (>100% above baseline for 6+ hours)
CREATE OR REPLACE ALERT ADAPTIVE_COMPUTE_DB.ADMIN.ALERT_CRITICAL_SPIKE
    WAREHOUSE = DASH_WH_SI
    SCHEDULE = 'USING CRON 0 * * * * UTC'
    IF (EXISTS (
        WITH critical AS (
            SELECT ml.warehouse_name
            FROM ADAPTIVE_COMPUTE_DB.ADMIN.MIGRATION_LOG ml
            JOIN SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY h
                ON ml.warehouse_name = h.warehouse_name
            WHERE ml.action = 'MIGRATE'
              AND h.start_time >= DATEADD('hour', -6, CURRENT_TIMESTAMP())
            GROUP BY 1, ml.baseline_credits_7d
            HAVING SUM(h.credits_used) > (ml.baseline_credits_7d / 7 / 24) * 6 * 2.0
        )
        SELECT 1 FROM critical
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'adaptive_compute_alerts',
            'team@company.com',
            'CRITICAL: Adaptive Compute - Consider Rollback',
            'Credits 2x baseline for 6+ hours. Investigate immediately. Run: CALL ADAPTIVE_COMPUTE_DB.ADMIN.HEALTH_CHECK()'
        );

-- Resume alerts (they start in SUSPENDED state)
ALTER ALERT ADAPTIVE_COMPUTE_DB.ADMIN.ALERT_CREDIT_SPIKE RESUME;
ALTER ALERT ADAPTIVE_COMPUTE_DB.ADMIN.ALERT_CRITICAL_SPIKE RESUME;

-- Verify alert status
SHOW ALERTS IN SCHEMA ADAPTIVE_COMPUTE_DB.ADMIN;
