# Assessment Guide

## Overview

The assessment phase determines which warehouses will benefit most from Adaptive Compute. Not every warehouse is a good candidate — steady, predictable workloads may see minimal benefit.

## Running the Assessment

```sql
-- Execute from Snowsight or SnowSQL
@scripts/migration/01_assess_warehouses.sql
```

### Configuring the Lookback Window

By default, the assessment examines 14 days of history. Adjust for your needs:

```sql
SET LOOKBACK_DAYS = 30;  -- Longer period for seasonal patterns
```

## Scoring Methodology

The assessment produces a score from 0-100 based on four components:

### 1. Workload Variability (0-40 points)

Measures the coefficient of variation (CV) of hourly credit consumption.

- **CV > 1.0** → 40 points (highly variable, strong candidate)
- **CV 0.5-1.0** → 20-40 points (moderately variable)
- **CV < 0.5** → 0-20 points (relatively steady)

**Why it matters:** Adaptive Compute shines when demand fluctuates. A warehouse that runs at 100% utilization 24/7 won't benefit from dynamic scaling.

### 2. Idle Time (0-30 points)

Percentage of hours with zero or minimal activity.

- **>70% idle** → 30 points (huge overprovisioning opportunity)
- **40-70% idle** → 15-30 points (moderate opportunity)
- **<40% idle** → 0-15 points (well-utilized)

**Why it matters:** Idle time under a standard warehouse still costs credits during auto-suspend delays. Adaptive Compute eliminates this waste.

### 3. Queue Time (0-20 points)

Frequency of queries entering the overload queue.

- **Regular queuing** → 20 points (resource-constrained)
- **Occasional queuing** → 5-15 points
- **No queuing** → 0 points

**Why it matters:** Queuing indicates the warehouse can't handle peak demand, suggesting Adaptive Compute's dynamic scaling will provide immediate performance gains.

### 4. Credit Volume (0-10 points)

Total credits consumed (higher spend = more absolute savings potential).

## Interpreting Results

| Score | Action | Expected Savings |
|-------|--------|-----------------|
| 80-100 | Migrate immediately | 20-30%+ credit reduction |
| 60-79 | Strong candidate, schedule migration | 10-20% credit reduction |
| 40-59 | Run an A/B comparison first | Variable |
| 0-39 | Keep on standard warehouse | Minimal or none |

## Edge Cases

### Warehouses to Always Migrate
- Development/sandbox warehouses (highly variable by nature)
- BI/dashboard refresh warehouses (bursty)
- Cortex Agent warehouses (unpredictable AI queries)

### Warehouses to Keep Standard
- Warehouses with single long-running queries (ETL that runs one massive query)
- Warehouses at minimum size (XS) already near 100% utilization
- Warehouses used exclusively for `COPY INTO` with predictable file counts

## Next Steps

After assessment, proceed to [Migration](MIGRATION.md) for the implementation plan.
