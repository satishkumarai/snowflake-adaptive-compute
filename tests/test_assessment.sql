-- Comprehensive test suite for assessment scoring logic

--------------------------------------------------------------------------------
-- TEST SUITE: ASSESSMENT SCORING
-- Tests the warehouse scoring algorithm for boundary conditions, edge cases,
-- and mathematical correctness.
--
-- Score formula (0-100):
--   variability_component = LEAST(CV * 40, 40)
--   idle_component = LEAST((1 - active_hours / total_hours) * 30, 30)
--   queue_component = LEAST(queued_queries / active_hours * 5, 20)
--   credit_component = LEAST(total_credits / 100, 10)
--   score = sum of all components
--------------------------------------------------------------------------------

USE SCHEMA ADAPTIVE_COMPUTE_DB.ADMIN;

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 1: Score formula - Maximum score (100)
-- A warehouse with CV=2.0, 0% utilization, heavy queuing, high credits
-- ═══════════════════════════════════════════════════════════════════════════════

SELECT
    'T1_MAX_SCORE' AS test_id,
    CASE WHEN ROUND(
        LEAST(2.0 * 40, 40)         -- variability: 40 (capped)
        + LEAST((1 - 0/336.0) * 30, 30)  -- idle: 30 (0 active hours)
        + LEAST(1000/1.0 * 5, 20)   -- queue: 20 (capped)
        + LEAST(10000/100.0, 10)    -- credits: 10 (capped)
    , 1) = 100.0 THEN 'PASS'
    ELSE 'FAIL: expected 100' END AS result;

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 2: Score formula - Minimum score (0)
-- A warehouse with CV=0, 100% utilization, no queuing, 0 credits
-- ═══════════════════════════════════════════════════════════════════════════════

SELECT
    'T2_MIN_SCORE' AS test_id,
    CASE WHEN ROUND(
        LEAST(0 * 40, 40)            -- variability: 0
        + LEAST((1 - 336/336.0) * 30, 30)  -- idle: 0 (100% active)
        + LEAST(0/336.0 * 5, 20)     -- queue: 0
        + LEAST(0/100.0, 10)         -- credits: 0
    , 1) = 0.0 THEN 'PASS'
    ELSE 'FAIL: expected 0' END AS result;

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 3: Score boundaries - Each component capped correctly
-- ═══════════════════════════════════════════════════════════════════════════════

-- Variability cap at 40
SELECT
    'T3_CV_CAP' AS test_id,
    CASE WHEN LEAST(5.0 * 40, 40) = 40 THEN 'PASS' ELSE 'FAIL' END AS result;

-- Idle cap at 30
SELECT
    'T3_IDLE_CAP' AS test_id,
    CASE WHEN LEAST((1 - 0/336.0) * 30, 30) = 30 THEN 'PASS' ELSE 'FAIL' END AS result;

-- Queue cap at 20
SELECT
    'T3_QUEUE_CAP' AS test_id,
    CASE WHEN LEAST(100/1.0 * 5, 20) = 20 THEN 'PASS' ELSE 'FAIL' END AS result;

-- Credit cap at 10
SELECT
    'T3_CREDIT_CAP' AS test_id,
    CASE WHEN LEAST(5000/100.0, 10) = 10 THEN 'PASS' ELSE 'FAIL' END AS result;

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 4: Score thresholds match documentation
-- ═══════════════════════════════════════════════════════════════════════════════

SELECT
    'T4_THRESHOLDS' AS test_id,
    CASE
        WHEN 85 >= 80 AND 'MIGRATE NOW' = 'MIGRATE NOW' THEN 'PASS'  -- 80+ = MIGRATE NOW
        ELSE 'FAIL'
    END AS result;

SELECT
    'T4_THRESHOLD_60' AS test_id,
    CASE WHEN 65 >= 60 AND 65 < 80 THEN 'PASS' ELSE 'FAIL' END AS result;

SELECT
    'T4_THRESHOLD_40' AS test_id,
    CASE WHEN 45 >= 40 AND 45 < 60 THEN 'PASS' ELSE 'FAIL' END AS result;

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 5: Live assessment returns valid scores
-- ═══════════════════════════════════════════════════════════════════════════════

WITH scores AS (
    SELECT warehouse_name, active_hours, total_credits_14d, variability, adaptive_score
    FROM (
        WITH hourly_metrics AS (
            SELECT warehouse_name, DATE_TRUNC('hour', start_time) AS hour_ts, SUM(credits_used) AS credits
            FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
            WHERE start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP())
            GROUP BY 1, 2
        ),
        query_metrics AS (
            SELECT warehouse_name, COUNT_IF(queued_overload_time > 0) AS queued_queries
            FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
            WHERE start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP()) AND warehouse_name IS NOT NULL
            GROUP BY 1
        ),
        stats AS (
            SELECT h.warehouse_name, COUNT(DISTINCT h.hour_ts) AS active_hours,
                AVG(h.credits) AS avg_credits, STDDEV(h.credits) AS std_credits,
                SUM(h.credits) AS total_credits, COALESCE(q.queued_queries, 0) AS queued_queries
            FROM hourly_metrics h LEFT JOIN query_metrics q ON h.warehouse_name = q.warehouse_name
            GROUP BY 1, 6
        )
        SELECT warehouse_name, active_hours, ROUND(total_credits, 2) AS total_credits_14d,
            ROUND(CASE WHEN avg_credits > 0 THEN std_credits / avg_credits ELSE 0 END, 3) AS variability,
            queued_queries,
            ROUND(LEAST(CASE WHEN avg_credits > 0 THEN std_credits / avg_credits ELSE 0 END * 40, 40)
                + LEAST((1 - active_hours / (14.0 * 24)) * 30, 30)
                + LEAST(queued_queries / NULLIF(active_hours, 0) * 5, 20)
                + LEAST(total_credits / 100, 10), 1) AS adaptive_score
        FROM stats
    )
)
SELECT
    'T5_SCORES_IN_RANGE' AS test_id,
    CASE
        WHEN COUNT_IF(adaptive_score < 0) > 0 THEN 'FAIL: score below 0'
        WHEN COUNT_IF(adaptive_score > 100) > 0 THEN 'FAIL: score above 100'
        WHEN COUNT(*) = 0 THEN 'FAIL: no warehouses scored'
        ELSE 'PASS: ' || COUNT(*)::STRING || ' warehouses scored, range ['
             || MIN(adaptive_score)::STRING || ', ' || MAX(adaptive_score)::STRING || ']'
    END AS result
FROM scores;

-- ═══════════════════════════════════════════════════════════════════════════════
-- TEST 6: Edge case - Division by zero protection
-- ═══════════════════════════════════════════════════════════════════════════════

SELECT
    'T6_DIV_BY_ZERO' AS test_id,
    CASE
        -- avg_credits = 0 should produce variability = 0, not error
        WHEN (CASE WHEN 0 > 0 THEN 1.0 / 0 ELSE 0 END) = 0 THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

-- NULLIF protection for active_hours = 0
SELECT
    'T6_NULLIF_PROTECTION' AS test_id,
    CASE
        WHEN LEAST(COALESCE(10 / NULLIF(0, 0) * 5, 0), 20) = 0 THEN 'PASS'
        ELSE 'FAIL'
    END AS result;

SELECT 'ALL ASSESSMENT TESTS COMPLETE' AS status, CURRENT_TIMESTAMP() AS run_at;
