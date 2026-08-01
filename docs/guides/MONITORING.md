# Monitoring Best Practices

## Overview

Effective monitoring is the difference between a successful migration and a costly one. This guide covers what to watch, when to act, and how to automate responses.

## Key Metrics

| Metric | Where to Find | Alert Threshold |
|--------|--------------|-----------------|
| Credits/hour | `WAREHOUSE_METERING_HISTORY` | >50% above baseline |
| P95 latency | `QUERY_HISTORY` | >25% above baseline |
| Queue time | `QUERY_HISTORY.queued_overload_time` | Any sustained queuing |
| Error rate | `QUERY_HISTORY.execution_status` | >1% failure rate |
| Concurrency | `QUERY_HISTORY` (count by hour) | For context only |

## Monitoring Timeline

### First 24 Hours (Critical)
- Check every 2-4 hours
- Compare credits to same day-of-week baseline
- Watch for any query failures

### Days 2-7 (Stabilization)
- Daily review of savings dashboard
- Validate P95 latency is stable or improved
- Confirm queue times eliminated

### Week 2+ (Steady State)
- Weekly review via `HEALTH_CHECK()` procedure
- Monthly savings report to stakeholders
- Tune `MAX_QUERY_PERFORMANCE_LEVEL` if needed

## Setting Up Dashboards

Deploy the monitoring views:

```sql
@scripts/monitoring/01_deploy_monitoring.sql
```

Then create a Snowsight dashboard with these tiles:

1. **Credit Trend** — `V_DAILY_SAVINGS` (line chart, date vs savings_pct)
2. **Performance** — `V_PERFORMANCE_COMPARISON` (line chart, p95 latency by period)
3. **Health Status** — `HEALTH_CHECK()` result (table)
4. **ROI Summary** — Query 5 from dashboard_queries.sql (scorecard)

## Automated Responses

The alert framework (`02_setup_alerts.sql`) provides three tiers:

| Tier | Condition | Action |
|------|-----------|--------|
| Warning | Credits >50% above baseline for 4h | Email notification |
| Critical | Latency >25% regression for 4h | Email + investigation |
| Emergency | Credits >100% above baseline for 6h | Email + recommend rollback |

## Custom Alert Configuration

Adjust thresholds for your environment:

```sql
-- More aggressive monitoring for critical warehouses
ALTER ALERT ADAPTIVE_COMPUTE.ALERT_CREDIT_SPIKE
    MODIFY CONDITION EXISTS (
        -- Change 1.5x to 1.3x for tighter monitoring
        SELECT 1 FROM ... WHERE credits > baseline * 1.3
    );
```

## Reporting to Stakeholders

Monthly summary query:

```sql
SELECT
    warehouse_name,
    ROUND(SUM(baseline_daily_credits), 0) AS baseline_credits,
    ROUND(SUM(actual_credits), 0) AS actual_credits,
    ROUND(SUM(baseline_daily_credits) - SUM(actual_credits), 0) AS credits_saved,
    ROUND(AVG(savings_pct), 1) || '%' AS avg_savings
FROM ADAPTIVE_COMPUTE.V_DAILY_SAVINGS
WHERE day_ts >= DATE_TRUNC('month', CURRENT_DATE())
GROUP BY 1
ORDER BY credits_saved DESC;
```
