# Migration Guide

## Overview

Migrating a warehouse to Adaptive Compute is an **online operation** with zero downtime. Running queries complete on existing resources while new queries use Adaptive resources. Both charge simultaneously until existing queries finish.

## Limitations

Before migration, verify your warehouse is eligible:

- **Edition**: Enterprise Edition or higher required
- **Cannot convert**: X5Large, X6Large, Snowpark-optimized, or interactive warehouses
- **Region**: Must be in a supported region (see README)

## Pre-Migration Checklist

- [ ] Enterprise Edition confirmed
- [ ] Warehouse is NOT X5Large/X6Large/Snowpark-opt/Interactive
- [ ] Warehouse in supported region
- [ ] Baseline metrics captured (7+ days)
- [ ] Stakeholder notification sent
- [ ] Rollback plan documented
- [ ] Monitoring alerts configured

## How Conversion Works

When you convert a standard warehouse to Adaptive:

1. The only property you change is `WAREHOUSE_TYPE`
2. Snowflake **automatically computes** appropriate `MAX_QUERY_PERFORMANCE_LEVEL` and `QUERY_THROUGHPUT_MULTIPLIER` from:
   - Warehouse size
   - MAX_CLUSTER_COUNT (for multi-cluster warehouses)
   - QAS scale factor
   - Warehouse generation
3. The goal is to preserve or improve performance vs. the original
4. Standard properties (WAREHOUSE_SIZE, MAX_CLUSTER_COUNT) no longer apply after conversion

**During conversion:**
- Running queries continue on old compute resources
- New queries run on Adaptive resources
- You are charged for **both** sets while queries overlap
- Once old queries complete, everything shifts to Adaptive

## Migration Phases

### Phase 1: Dev/Test (Low Risk)

```sql
-- Migrate development warehouses first
CALL ADAPTIVE_COMPUTE.MIGRATE_WAREHOUSE('DEV_WH');
CALL ADAPTIVE_COMPUTE.MIGRATE_WAREHOUSE('TEST_WH');
CALL ADAPTIVE_COMPUTE.MIGRATE_WAREHOUSE('SANDBOX_WH');
```

Monitor for 48-72 hours before proceeding.

### Phase 2: Reporting/Dashboards (Medium Risk)

```sql
-- Dashboard and BI warehouses benefit significantly
CALL ADAPTIVE_COMPUTE.MIGRATE_WAREHOUSE('DASHBOARD_WH');
CALL ADAPTIVE_COMPUTE.MIGRATE_WAREHOUSE('REPORTING_WH');
```

These typically show immediate queue time reduction.

### Phase 3: Analytics (Medium Risk)

```sql
-- Ad-hoc analytics and data science workloads
CALL ADAPTIVE_COMPUTE.MIGRATE_WAREHOUSE('ANALYTICS_WH');
CALL ADAPTIVE_COMPUTE.MIGRATE_WAREHOUSE('DS_WH');
```

### Phase 4: ETL/Production (Higher Risk)

```sql
-- Production pipelines — ensure monitoring is solid first
CALL ADAPTIVE_COMPUTE.MIGRATE_WAREHOUSE('ETL_WH');
CALL ADAPTIVE_COMPUTE.MIGRATE_WAREHOUSE('TRANSFORM_WH');
```

## Direct Migration (Without Procedures)

If you prefer not to use the stored procedures:

```sql
-- 1. Record baseline (manual)
SELECT SUM(credits_used) AS baseline_7d
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE warehouse_name = 'MY_WH'
  AND start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP());

-- 2. Migrate
ALTER WAREHOUSE MY_WH SET WAREHOUSE_TYPE = 'ADAPTIVE';

-- 3. Verify
SHOW WAREHOUSES LIKE 'MY_WH';
-- Check WAREHOUSE_TYPE column shows 'ADAPTIVE'
```

## Post-Migration Validation

Run immediately after migration:

```sql
-- Verify warehouse type changed
SHOW WAREHOUSES LIKE 'MY_WH';

-- Run a representative workload (or wait for natural traffic)
-- Then check performance:
SELECT
    warehouse_name,
    COUNT(*) AS queries,
    AVG(total_elapsed_time)/1000 AS avg_sec,
    MAX(queued_overload_time)/1000 AS max_queue_sec
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
    DATE_RANGE_START => DATEADD('hour', -1, CURRENT_TIMESTAMP()),
    WAREHOUSE_NAME => 'MY_WH'
))
GROUP BY 1;
```

## Configuration After Migration

### Performance Level (Latency-Sensitive Workloads)

```sql
-- For dashboards where sub-second response matters
ALTER WAREHOUSE DASHBOARD_WH
    SET MAX_QUERY_PERFORMANCE_LEVEL = 'HIGH';
```

### Throughput Multiplier (Batch Workloads)

```sql
-- For ETL where throughput > latency
ALTER WAREHOUSE ETL_WH
    SET QUERY_THROUGHPUT_MULTIPLIER = 2;
```

## Common Migration Issues

| Issue | Cause | Resolution |
|-------|-------|-----------|
| `WAREHOUSE_TYPE not recognized` | Region not supported | Check supported regions list |
| `Insufficient privileges` | Missing MODIFY grant | Grant via ACCOUNTADMIN |
| No visible change in credits | Too early to measure | Wait 48-72 hours for meaningful data |
| Credits increased slightly | Ramp-up learning period | Normal for first 24-48 hours |

## Next Steps

After migration, set up [Monitoring](MONITORING.md) to track performance and cost.
