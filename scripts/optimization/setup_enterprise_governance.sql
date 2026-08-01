-- Enterprise governance tables for Adaptive Compute dashboard (BFSI production)
--
-- TABLES:
--   1. AUDIT_LOG — tracks all user interactions (simulations, views, exports)
--   2. MIGRATION_REQUESTS — change management workflow for WH migrations
--   3. WORKLOAD_SLA — SLA definitions per workload class
--   4. SLA_BREACHES — auto-detected SLA violations
--   5. REGULATORY_CALENDAR — firm-specific reporting windows
--   6. GL_CODE_MAPPING — cost allocation to General Ledger codes
--   7. REGION_ADAPTIVE_SUPPORT — data residency validation
--
-- PREREQUISITE: Run setup_materialized_tables.sql first for ADAPTIVE_METRICS schema
-- ============================================================

USE SCHEMA ADAPTIVE_METRICS;

-- ============================================================
-- 1. AUDIT LOG
-- ============================================================
CREATE TABLE IF NOT EXISTS AUDIT_LOG (
    event_id        VARCHAR(36) DEFAULT UUID_STRING(),
    event_timestamp TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    username        VARCHAR(256) DEFAULT CURRENT_USER(),
    role_name       VARCHAR(256) DEFAULT CURRENT_ROLE(),
    session_id      NUMBER DEFAULT CURRENT_SESSION(),
    event_type      VARCHAR(50) NOT NULL,  -- SIMULATION, VIEW, EXPORT, MIGRATION_REQUEST, APPROVAL
    event_detail    VARIANT,               -- JSON payload with context
    warehouse_name  VARCHAR(256),          -- target warehouse (if applicable)
    ip_address      VARCHAR(50)
)
COMMENT = 'Audit trail for all dashboard interactions — required for SOX/SOC2 compliance';

-- ============================================================
-- 2. MIGRATION REQUESTS (Change Management)
-- ============================================================
CREATE TABLE IF NOT EXISTS MIGRATION_REQUESTS (
    request_id        VARCHAR(36) DEFAULT UUID_STRING(),
    created_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    requested_by      VARCHAR(256) DEFAULT CURRENT_USER(),
    requested_role    VARCHAR(256) DEFAULT CURRENT_ROLE(),
    warehouse_name    VARCHAR(256) NOT NULL,
    current_type      VARCHAR(20) NOT NULL,    -- STANDARD
    target_type       VARCHAR(20) NOT NULL,    -- ADAPTIVE
    justification     VARCHAR(4000),
    assessment_score  FLOAT,
    estimated_savings FLOAT,                   -- projected annual $ savings
    status            VARCHAR(20) DEFAULT 'PENDING',  -- PENDING, APPROVED, REJECTED, EXECUTED, ROLLED_BACK
    reviewed_by       VARCHAR(256),
    reviewed_at       TIMESTAMP_NTZ,
    review_notes      VARCHAR(4000),
    executed_at       TIMESTAMP_NTZ,
    rollback_at       TIMESTAMP_NTZ
)
COMMENT = 'Migration change management workflow — enforces approval before production changes';

-- ============================================================
-- 3. WORKLOAD SLA DEFINITIONS
-- ============================================================
CREATE TABLE IF NOT EXISTS WORKLOAD_SLA (
    sla_id            VARCHAR(36) DEFAULT UUID_STRING(),
    workload_class    VARCHAR(100) NOT NULL,   -- e.g. 'REAL_TIME_TRADING', 'BATCH_RISK', 'REPORTING'
    warehouse_pattern VARCHAR(256) NOT NULL,   -- regex or LIKE pattern for warehouse names
    max_p95_latency_sec  FLOAT NOT NULL,       -- SLA threshold in seconds
    max_queue_sec        FLOAT DEFAULT 0,      -- max acceptable queue time
    max_error_rate_pct   FLOAT DEFAULT 1.0,    -- max acceptable failure rate
    priority             INTEGER DEFAULT 3,    -- 1=Critical, 2=High, 3=Medium, 4=Low
    escalation_contact   VARCHAR(256),         -- email/Slack for breach notification
    created_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    created_by           VARCHAR(256) DEFAULT CURRENT_USER(),
    is_active            BOOLEAN DEFAULT TRUE
)
COMMENT = 'SLA definitions per workload class — monitors post-migration performance';

-- Insert example BFSI workload classes
INSERT INTO WORKLOAD_SLA (workload_class, warehouse_pattern, max_p95_latency_sec, max_queue_sec, max_error_rate_pct, priority, escalation_contact)
SELECT * FROM VALUES
    ('REAL_TIME_TRADING', '%TRADING%', 2.0, 0.5, 0.1, 1, 'trading-ops@firm.com'),
    ('RISK_CALCULATION', '%RISK%', 30.0, 10.0, 0.5, 1, 'risk-tech@firm.com'),
    ('REGULATORY_REPORTING', '%REG%', 120.0, 30.0, 0.5, 2, 'compliance-tech@firm.com'),
    ('CLIENT_REPORTING', '%CLIENT%', 60.0, 15.0, 1.0, 2, 'client-ops@firm.com'),
    ('BATCH_ETL', '%ETL%', 300.0, 60.0, 2.0, 3, 'data-eng@firm.com'),
    ('ANALYTICS', '%ANALYTICS%', 45.0, 20.0, 2.0, 3, 'analytics-team@firm.com'),
    ('AD_HOC', '%ADHOC%', 120.0, 30.0, 5.0, 4, NULL)
WHERE NOT EXISTS (SELECT 1 FROM WORKLOAD_SLA LIMIT 1);

-- ============================================================
-- 4. SLA BREACHES (Auto-populated by scheduled task)
-- ============================================================
CREATE TABLE IF NOT EXISTS SLA_BREACHES (
    breach_id         VARCHAR(36) DEFAULT UUID_STRING(),
    detected_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    warehouse_name    VARCHAR(256) NOT NULL,
    workload_class    VARCHAR(100) NOT NULL,
    breach_type       VARCHAR(50) NOT NULL,    -- LATENCY, QUEUE, ERROR_RATE
    sla_threshold     FLOAT NOT NULL,
    actual_value      FLOAT NOT NULL,
    breach_window     TIMESTAMP_NTZ NOT NULL,  -- the hour when breach occurred
    severity          VARCHAR(20),             -- CRITICAL, HIGH, MEDIUM, LOW
    acknowledged      BOOLEAN DEFAULT FALSE,
    acknowledged_by   VARCHAR(256),
    resolution_notes  VARCHAR(4000)
)
COMMENT = 'Auto-detected SLA violations for post-migration monitoring';

-- ============================================================
-- 5. REGULATORY CALENDAR
-- ============================================================
CREATE TABLE IF NOT EXISTS REGULATORY_CALENDAR (
    calendar_id      VARCHAR(36) DEFAULT UUID_STRING(),
    event_name       VARCHAR(256) NOT NULL,
    event_type       VARCHAR(50) NOT NULL,     -- MONTH_END, QUARTER_END, YEAR_END, REGULATORY_FILING, AUDIT_WINDOW, BLACKOUT
    start_date       DATE NOT NULL,
    end_date         DATE NOT NULL,
    affected_warehouses VARCHAR(4000),          -- comma-separated or 'ALL'
    expected_spike_factor FLOAT DEFAULT 2.0,   -- expected multiplier vs normal
    suppress_anomaly BOOLEAN DEFAULT TRUE,     -- suppress anomaly alerts during this window
    notes            VARCHAR(4000),
    created_by       VARCHAR(256) DEFAULT CURRENT_USER(),
    created_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Firm-specific regulatory reporting windows — suppresses false anomaly alerts';

-- Insert example BFSI regulatory windows for 2026
INSERT INTO REGULATORY_CALENDAR (event_name, event_type, start_date, end_date, affected_warehouses, expected_spike_factor, notes)
SELECT * FROM VALUES
    ('Q1 Close', 'QUARTER_END', '2026-03-29', '2026-04-02', 'ALL', 3.0, 'Quarter-end batch processing'),
    ('Q2 Close', 'QUARTER_END', '2026-06-28', '2026-07-02', 'ALL', 3.0, 'Quarter-end batch processing'),
    ('Q3 Close', 'QUARTER_END', '2026-09-28', '2026-10-02', 'ALL', 3.0, 'Quarter-end batch processing'),
    ('Year-End Close', 'YEAR_END', '2026-12-28', '2027-01-05', 'ALL', 5.0, 'Year-end close + regulatory filings'),
    ('CCAR Submission', 'REGULATORY_FILING', '2026-04-01', '2026-04-07', 'ALL', 4.0, 'Fed stress test submission'),
    ('Basel III Reporting', 'REGULATORY_FILING', '2026-01-10', '2026-01-15', 'ALL', 2.5, 'Capital adequacy reporting'),
    ('SOX Audit Window', 'AUDIT_WINDOW', '2026-02-01', '2026-02-28', 'ALL', 1.5, 'Annual SOX audit — elevated query volume'),
    ('Code Freeze', 'BLACKOUT', '2026-12-15', '2026-12-31', 'ALL', 1.0, 'No migrations during code freeze')
WHERE NOT EXISTS (SELECT 1 FROM REGULATORY_CALENDAR LIMIT 1);

-- ============================================================
-- 6. GL CODE MAPPING (Cost Allocation)
-- ============================================================
CREATE TABLE IF NOT EXISTS GL_CODE_MAPPING (
    mapping_id       VARCHAR(36) DEFAULT UUID_STRING(),
    warehouse_name   VARCHAR(256) NOT NULL,
    gl_code          VARCHAR(50) NOT NULL,     -- General Ledger code
    cost_center      VARCHAR(100),             -- Business unit cost center
    department       VARCHAR(100),             -- Department name
    business_line    VARCHAR(100),             -- LOB (e.g., 'Investment Banking', 'Wealth Management')
    allocation_pct   FLOAT DEFAULT 100.0,      -- % of warehouse costs to this GL (supports shared WHs)
    effective_from   DATE DEFAULT CURRENT_DATE(),
    effective_to     DATE DEFAULT '9999-12-31',
    approved_by      VARCHAR(256),
    created_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    created_by       VARCHAR(256) DEFAULT CURRENT_USER()
)
COMMENT = 'Maps warehouse costs to GL codes for financial chargeback — required for BFSI cost attribution';

-- ============================================================
-- 7. REGION ADAPTIVE SUPPORT (Data Residency)
-- ============================================================
CREATE TABLE IF NOT EXISTS REGION_ADAPTIVE_SUPPORT (
    cloud_provider   VARCHAR(10) NOT NULL,     -- AWS, AZURE, GCP
    region           VARCHAR(50) NOT NULL,
    region_display   VARCHAR(100),
    adaptive_ga      BOOLEAN DEFAULT FALSE,    -- Generally Available
    adaptive_preview BOOLEAN DEFAULT FALSE,    -- Preview/Beta
    last_verified    DATE DEFAULT CURRENT_DATE(),
    notes            VARCHAR(500)
)
COMMENT = 'Tracks which cloud/region combinations support Adaptive Compute — updated monthly';

-- Insert known supported regions (July 2026)
INSERT INTO REGION_ADAPTIVE_SUPPORT (cloud_provider, region, region_display, adaptive_ga, adaptive_preview)
SELECT * FROM VALUES
    ('AWS', 'us-west-2', 'US West (Oregon)', TRUE, FALSE),
    ('AWS', 'us-east-2', 'US East (Ohio)', TRUE, FALSE),
    ('AWS', 'eu-west-1', 'EU (Ireland)', TRUE, FALSE),
    ('AWS', 'eu-central-1', 'EU (Frankfurt)', TRUE, FALSE),
    ('AWS', 'ap-northeast-1', 'Asia Pacific (Tokyo)', TRUE, FALSE),
    ('AWS', 'ap-southeast-2', 'Asia Pacific (Sydney)', TRUE, FALSE),
    ('AZURE', 'centralus', 'Central US', TRUE, FALSE),
    ('AZURE', 'eastus2', 'East US 2', TRUE, FALSE),
    ('AZURE', 'westeurope', 'West Europe', TRUE, FALSE),
    ('AZURE', 'northeurope', 'North Europe', TRUE, FALSE),
    ('AZURE', 'uksouth', 'UK South', TRUE, FALSE),
    ('AZURE', 'switzerlandnorth', 'Switzerland North', TRUE, FALSE),
    ('AZURE', 'swedencentral', 'Sweden Central', TRUE, FALSE),
    ('GCP', 'us-east4', 'US East (Virginia)', TRUE, FALSE),
    ('GCP', 'europe-west2', 'Europe West (London)', TRUE, FALSE),
    ('GCP', 'europe-west3', 'Europe West (Frankfurt)', TRUE, FALSE),
    ('GCP', 'europe-west4', 'Europe West (Netherlands)', TRUE, FALSE),
    ('GCP', 'australia-southeast2', 'Australia (Melbourne)', TRUE, FALSE)
WHERE NOT EXISTS (SELECT 1 FROM REGION_ADAPTIVE_SUPPORT LIMIT 1);

-- ============================================================
-- SLA BREACH DETECTION TASK (runs every hour)
-- ============================================================
CREATE OR REPLACE PROCEDURE ADAPTIVE_METRICS.DETECT_SLA_BREACHES()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
BEGIN
    -- Detect latency breaches
    MERGE INTO ADAPTIVE_METRICS.SLA_BREACHES tgt
    USING (
        SELECT
            q.warehouse_name,
            s.workload_class,
            'LATENCY' AS breach_type,
            s.max_p95_latency_sec AS sla_threshold,
            PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY q.total_elapsed_time) / 1000.0 AS actual_value,
            DATE_TRUNC('hour', q.start_time) AS breach_window,
            CASE s.priority WHEN 1 THEN 'CRITICAL' WHEN 2 THEN 'HIGH' WHEN 3 THEN 'MEDIUM' ELSE 'LOW' END AS severity
        FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
        JOIN ADAPTIVE_METRICS.WORKLOAD_SLA s
          ON q.warehouse_name LIKE s.warehouse_pattern
          AND s.is_active = TRUE
        WHERE q.start_time >= DATEADD('hour', -2, CURRENT_TIMESTAMP())
          AND q.execution_status = 'SUCCESS'
        GROUP BY 1, 2, 3, 4, 6, 7
        HAVING actual_value > sla_threshold
    ) src
    ON tgt.warehouse_name = src.warehouse_name
       AND tgt.workload_class = src.workload_class
       AND tgt.breach_window = src.breach_window
       AND tgt.breach_type = src.breach_type
    WHEN NOT MATCHED THEN INSERT (warehouse_name, workload_class, breach_type, sla_threshold, actual_value, breach_window, severity)
        VALUES (src.warehouse_name, src.workload_class, src.breach_type, src.sla_threshold, src.actual_value, src.breach_window, src.severity);

    -- Detect queue breaches
    MERGE INTO ADAPTIVE_METRICS.SLA_BREACHES tgt
    USING (
        SELECT
            q.warehouse_name,
            s.workload_class,
            'QUEUE' AS breach_type,
            s.max_queue_sec AS sla_threshold,
            AVG(q.queued_overload_time) / 1000.0 AS actual_value,
            DATE_TRUNC('hour', q.start_time) AS breach_window,
            CASE s.priority WHEN 1 THEN 'CRITICAL' WHEN 2 THEN 'HIGH' WHEN 3 THEN 'MEDIUM' ELSE 'LOW' END AS severity
        FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
        JOIN ADAPTIVE_METRICS.WORKLOAD_SLA s
          ON q.warehouse_name LIKE s.warehouse_pattern
          AND s.is_active = TRUE
        WHERE q.start_time >= DATEADD('hour', -2, CURRENT_TIMESTAMP())
          AND q.queued_overload_time > 0
        GROUP BY 1, 2, 3, 4, 6, 7
        HAVING actual_value > sla_threshold
    ) src
    ON tgt.warehouse_name = src.warehouse_name
       AND tgt.workload_class = src.workload_class
       AND tgt.breach_window = src.breach_window
       AND tgt.breach_type = src.breach_type
    WHEN NOT MATCHED THEN INSERT (warehouse_name, workload_class, breach_type, sla_threshold, actual_value, breach_window, severity)
        VALUES (src.warehouse_name, src.workload_class, src.breach_type, src.sla_threshold, src.actual_value, src.breach_window, src.severity);

    RETURN 'SLA breach detection complete';
END;

-- Schedule SLA detection every hour
CREATE OR REPLACE TASK ADAPTIVE_METRICS.DETECT_SLA_BREACHES_TASK
    WAREHOUSE = DASH_WH_SI
    SCHEDULE = 'USING CRON 10 * * * * America/Los_Angeles'
    COMMENT = 'Hourly SLA breach detection for Adaptive Compute monitoring'
AS
    CALL ADAPTIVE_METRICS.DETECT_SLA_BREACHES();

ALTER TASK ADAPTIVE_METRICS.DETECT_SLA_BREACHES_TASK RESUME;

-- ============================================================
-- VERIFICATION
-- ============================================================
SELECT 'Tables created:' AS status;
SELECT table_name, comment
FROM INFORMATION_SCHEMA.TABLES
WHERE table_schema = 'ADAPTIVE_METRICS'
ORDER BY table_name;
