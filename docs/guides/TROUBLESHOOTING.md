# Troubleshooting Guide

## Common Issues

### Credits Increased After Migration

**Symptom:** Credit consumption is higher post-migration than the baseline.

**Possible causes:**
1. **Learning period** — First 24-48 hours may show slight increases as the system calibrates
2. **Workload change** — Query volume increased coincidentally with migration
3. **Eliminated queuing** — Previously queued queries now execute immediately, consuming more compute

**Resolution:**
```sql
-- Compare query counts (are you running more queries?)
SELECT
    CASE WHEN start_time < (SELECT MIN(migrated_at) FROM ADAPTIVE_COMPUTE.MIGRATION_LOG WHERE warehouse_name = 'MY_WH') 
         THEN 'PRE' ELSE 'POST' END AS period,
    COUNT(*) AS query_count,
    SUM(credits_used_cloud_services) AS cloud_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE warehouse_name = 'MY_WH'
  AND start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP())
GROUP BY 1;
```

If query count increased, normalize by cost-per-query rather than total cost.

---

### Latency Regression

**Symptom:** P95 or P99 latency increased after migration.

**Possible causes:**
1. Workload pattern shift during transition
2. Large queries competing with small queries (scheduling difference)

**Resolution:**
```sql
-- Identify slow queries post-migration
SELECT
    query_id,
    SUBSTR(query_text, 1, 100) AS query_preview,
    total_elapsed_time / 1000 AS elapsed_sec,
    compilation_time / 1000 AS compile_sec,
    execution_time / 1000 AS exec_sec
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE warehouse_name = 'MY_WH'
  AND start_time >= DATEADD('day', -3, CURRENT_TIMESTAMP())
ORDER BY total_elapsed_time DESC
LIMIT 20;
```

If specific query patterns regressed, consider `MAX_QUERY_PERFORMANCE_LEVEL = 'HIGH'`.

---

### ALTER Command Fails

**Symptom:** `ALTER WAREHOUSE ... SET WAREHOUSE_TYPE = 'ADAPTIVE'` returns an error.

| Error | Cause | Fix |
|-------|-------|-----|
| `Feature not available` | Region not supported | Migrate to supported region |
| `Insufficient privileges` | Role lacks MODIFY | `GRANT MODIFY ON WAREHOUSE wh TO ROLE my_role;` |
| `Invalid warehouse type` | Edition not Enterprise+ | Upgrade account edition |

---

### Alerts Firing Unexpectedly

**Symptom:** Credit spike alerts trigger but performance looks fine.

**Common causes:**
1. Baseline was captured during a low-activity period
2. Business seasonality (end of month, quarter-end)
3. New workloads added to the warehouse post-migration

**Resolution:**
```sql
-- Update baseline after confirming new normal
UPDATE ADAPTIVE_COMPUTE.MIGRATION_LOG
SET baseline_credits_7d = (
    SELECT SUM(credits_used)
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE warehouse_name = 'MY_WH'
      AND start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
)
WHERE warehouse_name = 'MY_WH'
  AND action = 'MIGRATE';
```

---

### Health Check Shows All NULL

**Symptom:** `CALL ADAPTIVE_COMPUTE.HEALTH_CHECK()` returns NULL for metrics.

**Cause:** ACCOUNT_USAGE views have up to 45-minute latency.

**Resolution:** Wait at least 1 hour after migration, or use INFORMATION_SCHEMA for real-time data:
```sql
SELECT *
FROM TABLE(INFORMATION_SCHEMA.WAREHOUSE_METERING_HISTORY(
    DATE_RANGE_START => DATEADD('hour', -1, CURRENT_TIMESTAMP()),
    WAREHOUSE_NAME => 'MY_WH'
));
```

---

## Escalation Path

1. **Self-service:** Run `CALL ADAPTIVE_COMPUTE.HEALTH_CHECK()` and review recommendations
2. **Investigate:** Check `scripts/monitoring/03_dashboard_queries.sql` for deeper analysis
3. **Rollback:** If metrics are degraded for 4+ hours, execute rollback
4. **Support:** If rollback doesn't resolve, open a Snowflake support case with your migration log

```sql
-- Export migration history for support
SELECT * FROM ADAPTIVE_COMPUTE.MIGRATION_LOG ORDER BY migrated_at DESC;
```
