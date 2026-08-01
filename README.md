# Snowflake Adaptive Compute: Enterprise FinOps Control Plane

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Snowflake](https://img.shields.io/badge/Snowflake-Enterprise-29B5E8)](https://www.snowflake.com)
[![Status](https://img.shields.io/badge/Status-Production--Ready-green.svg)]()
[![Dashboard](https://img.shields.io/badge/Dashboard-8%20Tabs-blueviolet.svg)]()

---

> **A production-grade implementation for migrating to Snowflake Adaptive Compute — from automated assessment through real-time monitoring, What-If simulation, enterprise governance, and cost optimization.**

---

## TL;DR

Snowflake Adaptive Compute dynamically adjusts compute resources to match workload demand without manual tuning. This repo provides:

- **2000+ line Streamlit dashboard** with 8 tabs for monitoring, assessment, simulation, and governance
- **Consolidated query architecture** — 2-3 SQL queries instead of 9+, with optional materialized tables for sub-second response
- **Enterprise governance** — audit logging, change management, SLA monitoring, regulatory calendar, GL code allocation, data residency validation
- **Battle-tested migration scripts** with automated assessment, safe rollback, and bulk migration support

```sql
-- The migration itself is one line. The production readiness around it is this entire repo.
ALTER WAREHOUSE my_warehouse SET WAREHOUSE_TYPE = 'ADAPTIVE';
```

---

## Table of Contents

- [Why Adaptive Compute](#why-adaptive-compute)
- [Architecture](#architecture)
- [Dashboard Features](#dashboard-features)
- [Quick Start](#quick-start)
- [Assessment & Scoring](#assessment--scoring)
- [What-If Simulator](#what-if-simulator)
- [Enterprise Governance](#enterprise-governance)
- [Query Optimization](#query-optimization)
- [Migration Workflow](#migration-workflow)
- [Rollback Strategy](#rollback-strategy)
- [Repository Structure](#repository-structure)
- [FAQ](#faq)

---

## Why Adaptive Compute

| Dimension | Standard Warehouse | Adaptive Compute |
|-----------|-------------------|------------------|
| Scaling | Manual resize or multi-cluster policies | Automatic, workload-aware |
| Tuning | Requires ongoing DBA effort | Self-optimizing |
| Price-performance | Fixed cost/hour regardless of utilization | Query-based billing; up to 1.2x better than Gen2 |
| Burst handling | Queuing or timeout on spikes | Dynamic resource allocation |
| Variable workloads | Over/under-provisioned | Up to 30% cost reduction |
| Idle time | Charged until auto-suspend | Zero cost when idle |

**Ideal workloads:** AI/ML pipelines, Cortex Agent workloads, mixed analytics + ETL, dashboard refresh spikes, development environments.

### Key Parameters

| Parameter | Purpose | Default | Values |
|-----------|---------|---------|--------|
| `MAX_QUERY_PERFORMANCE_LEVEL` | Upper bound on per-query compute | XLARGE | XSMALL → X4LARGE |
| `QUERY_THROUGHPUT_MULTIPLIER` | Scale factor for concurrency | 2 | 0 (unlimited) or positive integer |

### Supported Regions (July 2026)

| Cloud | Regions |
|-------|---------|
| **AWS** | us-west-2, us-east-2, eu-west-1, eu-central-1, ap-northeast-1, ap-southeast-2 |
| **Azure** | centralus, eastus2, westeurope, northeurope, uksouth, switzerlandnorth, swedencentral |
| **GCP** | us-east4, europe-west2, europe-west3, europe-west4, australia-southeast2 |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                  Streamlit Dashboard (8 tabs)                         │
├─────────────┬──────────────┬──────────────┬─────────────────────────┤
│  Overview   │  Performance │  ROI/Savings │  Anomalies              │
│  Assessment │  What-If     │  Governance  │  Migrate                │
└──────┬──────┴───────┬──────┴──────┬───────┴─────────────────────────┘
       │              │             │
       ▼              ▼             ▼
┌─────────────┐ ┌──────────┐ ┌──────────────────────────────────┐
│ Base Queries│ │ Events   │ │ ADAPTIVE_METRICS Schema          │
│ (2-3 SQL)   │ │ Base     │ │ ├─ HOURLY_METERING (clustered)  │
│             │ │          │ │ ├─ HOURLY_QUERIES (clustered)    │
│ Metering    │ │ Events   │ │ ├─ WAREHOUSE_EVENTS_AGG          │
│ + Query     │ │ History  │ │ ├─ AUDIT_LOG                     │
│ History     │ │          │ │ ├─ MIGRATION_REQUESTS             │
└──────┬──────┘ └────┬─────┘ │ ├─ WORKLOAD_SLA + SLA_BREACHES   │
       │             │        │ ├─ REGULATORY_CALENDAR            │
       ▼             ▼        │ ├─ GL_CODE_MAPPING                │
┌────────────────────────┐    │ └─ REGION_ADAPTIVE_SUPPORT        │
│ SNOWFLAKE.ACCOUNT_USAGE│    └──────────────────────────────────┘
│  • WAREHOUSE_METERING  │              ▲
│  • QUERY_HISTORY       │              │ Hourly TASK
│  • WAREHOUSE_EVENTS    │──────────────┘ (incremental MERGE)
│  • TAG_REFERENCES      │
└────────────────────────┘
```

**Design principles:**
- **2-3 consolidated queries** replace 9+ independent SQL calls
- **Pandas-derived views** — filtering, anomaly detection, and scoring computed client-side (zero additional SQL)
- **Hybrid mode** — auto-detects materialized tables; uses them when available, falls back to ACCOUNT_USAGE
- **Decimal→float conversion** — handles Snowflake's `decimal.Decimal` return type transparently
- **Timezone-aware** — UTC normalization for all timestamp comparisons

---

## Dashboard Features

| Tab | Features |
|-----|----------|
| **Overview** | Credit consumption over time (stacked area), top consumers, credit distribution (donut), tag-based cost attribution by COST_CENTER |
| **Performance** | P95 latency trends, queue time analysis, query volume, warehouse lifecycle events, failed query waste analysis |
| **ROI & Savings** | Idle credit waste calculator, auto-detected credit price (from RATE_SHEET_DAILY), projected annual savings, before/after migration comparison, suspend/resume frequency |
| **Anomalies** | Z-score anomaly detection with BFSI calendar awareness — suppresses month-end/quarter-end as EXPECTED_BATCH, weekend drops suppressed |
| **Assessment** | Migration readiness scores (0-100), excludes already-Adaptive and unsupported (5XL/6XL) warehouses, multi-cluster detection, query complexity mix |
| **What-If** | Gen1 vs Adaptive scenario simulator — Conservative/Moderate/Optimistic/Aggressive models, hourly comparison chart, idle elimination visualization |
| **Governance** | Audit log (SOX/SOC2), change management workflow, SLA monitoring with breach detection, regulatory calendar, GL code chargeback, data residency validation |
| **Migrate** | Fleet inventory, quick commands, bulk migration (SYSTEM$BULK_UPDATE_WH), governance guardrails, migration checklist |

---

## Quick Start

### 1. Dashboard Only (Immediate — no setup required)

Open `streamlit-app/` in Snowsight Workspaces and click **Run**. Requires:
- `IMPORTED PRIVILEGES` on `SNOWFLAKE` database (for ACCOUNT_USAGE)
- A warehouse for query execution

### 2. Query Optimization (Recommended)

Execute in a worksheet to create pre-aggregated tables with hourly refresh:

```sql
-- Creates ADAPTIVE_METRICS schema with clustered staging tables + hourly TASK
-- Cuts dashboard load time from 5-30s to <1s
@scripts/optimization/setup_materialized_tables.sql
```

### 3. Enterprise Governance (BFSI Production)

```sql
-- Creates 7 governance tables + SLA breach detection task
-- Enables: audit log, change management, SLA monitoring, regulatory calendar,
--          GL code mapping, region validation
@scripts/optimization/setup_enterprise_governance.sql
```

### 4. Migration Scripts

```sql
-- Read-only assessment (safe for production)
@scripts/migration/01_assess_warehouses.sql

-- Deploy migration + rollback procedures
@scripts/migration/02_create_procedures.sql

-- Execute migrations
@scripts/migration/03_execute_migration.sql
```

---

## Assessment & Scoring

The scoring algorithm evaluates four signals (0-100):

| Component | Max Points | What It Measures |
|-----------|-----------|------------------|
| Variability (CV) | 40 | Coefficient of variation in hourly credit consumption |
| Idle time | 30 | % of hours with zero query activity |
| Queue pressure | 20 | Queued queries per active hour |
| Credit volume | 10 | Total spend (higher = more absolute savings potential) |

**Exclusions** (auto-filtered):
- Already-Adaptive warehouses
- 5X-Large / 6X-Large (unsupported)
- Snowpark-optimized warehouses

| Score | Recommendation |
|-------|---------------|
| 80-100 | Migrate immediately |
| 60-79 | Strong candidate |
| 40-59 | Evaluate further (run A/B test) |
| 0-39 | Keep standard |

---

## What-If Simulator

The What-If tab provides a **fact-checked, honest** simulation model:

**What it models (verifiable):**
- Idle credit elimination (Adaptive has zero cost during idle hours) — guaranteed savings
- Multi-cluster overhead removal (Adaptive handles concurrency natively)
- Queue time elimination (Adaptive auto-scales without provisioning delay)

**What it does NOT model (because Snowflake doesn't publish the data):**
- Per-query credit cost (varies by query complexity, data volume, concurrency)
- Exact latency improvement (depends on workload characteristics)

The simulator uses **scenario-based analysis** (Conservative 15% → Aggressive 45%) rather than fake precision numbers.

---

## Enterprise Governance

### Audit Logging
Every dashboard interaction is logged with username, role, session ID, timestamp, and event type. Required for SOX/SOC2 compliance.

### Change Management
Full lifecycle workflow with email notifications:

```
Submit Request (justification + savings estimate + approver email)
    → PENDING (HTML email sent to approver with "Review in Dashboard" link)
    → APPROVED / REJECTED (reviewer + notes recorded)
    → EXECUTED (shows ALTER WAREHOUSE SQL)
    → (optional) ROLLED_BACK (shows rollback SQL)
```

- **HTML CXO-grade email** — professional formatted notification with warehouse details, justification, savings, and direct link to the Streamlit app
- **In-app actions** — Approve/Reject/Execute/Rollback buttons with instant page refresh
- **Blackout enforcement** — blocks migrations during regulatory filing periods and code freezes
- **Audit trail** — every action logged with user, role, and timestamp

### SLA Monitoring
Define SLA thresholds per workload class:
- Real-time Trading: P95 < 2s, Queue < 0.5s
- Risk Calculation: P95 < 30s, Queue < 10s
- Regulatory Reporting: P95 < 120s
- Batch ETL: P95 < 300s

Breaches are auto-detected hourly and categorized by severity (CRITICAL/HIGH/MEDIUM/LOW).

### Regulatory Calendar
BFSI-specific reporting windows (CCAR, Basel III, SOX audit, quarter-end) suppress false anomaly alerts. Blackout events prevent migrations during sensitive periods. Add events directly through the UI with instant refresh.

### Cost Allocation (GL Codes)
Map warehouses to General Ledger codes with percentage-based allocation (supports shared warehouses). Generates chargeback reports by business line. Add mappings through the UI with instant refresh.

### Data Residency
Auto-detects your account's cloud/region via `CURRENT_REGION()` and cross-references against the Adaptive Compute availability matrix.

---

## Query Optimization

### Strategy A: Consolidated Base Queries
- `load_metering_base()` — single scan of `WAREHOUSE_METERING_HISTORY`
- `load_query_base()` — single scan of `QUERY_HISTORY`
- `load_events_base()` — single scan of `WAREHOUSE_EVENTS_HISTORY`

All other views (credit totals, anomalies, idle waste, assessment scores) are derived in Pandas — zero additional SQL.

### Strategy B: Materialized Staging Tables
Pre-aggregated hourly tables with clustering on `(hour_ts, warehouse_name)`. Incremental MERGE via scheduled TASK (only processes new hours). Prunes >30 days automatically.

### Strategy C: Cache Alignment
All base loaders share 120s TTL. Filter changes recompute in Pandas (instant) without re-querying SQL.

---

## Migration Workflow

```
1. Assess     → scripts/migration/01_assess_warehouses.sql
2. Procedures → scripts/migration/02_create_procedures.sql
3. Test       → DRY_RUN with SYSTEM$BULK_UPDATE_WH
4. Execute    → ALTER WAREHOUSE ... SET WAREHOUSE_TYPE = 'ADAPTIVE'
5. Monitor    → Streamlit dashboard (72-hour watch window)
6. Rollback   → ALTER WAREHOUSE ... SET WAREHOUSE_TYPE = 'STANDARD' (instant)
```

**Critical facts:**
- Migration is an **online operation** — zero downtime
- Running queries finish on old resources; new queries use Adaptive immediately
- You're charged for **both** simultaneously until old queries complete
- Adaptive Warehouses use `ENABLE`/`DISABLE` (not `SUSPEND`/`RESUME`)
- Snowflake **auto-derives** parameters from your existing warehouse configuration

---

## Rollback Strategy

```sql
-- Instant rollback (online, non-disruptive)
ALTER WAREHOUSE my_warehouse SET WAREHOUSE_TYPE = 'STANDARD';
```

Automated rollback triggers:
- Credit consumption > 150% of baseline for 4+ consecutive hours
- P95 latency degradation > 25%
- Error rate exceeds SLA threshold

---

## Repository Structure

```
snowflake-adaptive-compute/
├── README.md                                # This file
├── BLOG.md                                  # Medium/technical article
├── CONTRIBUTING.md
├── LICENSE
├── streamlit-app/
│   ├── streamlit_app.py                     # Main dashboard (2000+ lines, 8 tabs)
│   ├── snowflake.yml                        # Snowflake deployment config
│   ├── pyproject.toml                       # Python dependencies
│   └── .streamlit/config.toml               # Streamlit theme
├── scripts/
│   ├── migration/
│   │   ├── 01_assess_warehouses.sql         # Assessment scoring algorithm
│   │   ├── 02_create_procedures.sql         # MIGRATE + ROLLBACK procedures
│   │   └── 03_execute_migration.sql         # Execution templates
│   ├── monitoring/
│   │   ├── 01_deploy_monitoring.sql         # Pre/post comparison views
│   │   ├── 02_setup_alerts.sql              # Credit spike alerts
│   │   └── 03_dashboard_queries.sql         # Reference SQL patterns
│   ├── optimization/
│   │   ├── setup_materialized_tables.sql    # Pre-aggregated tables + hourly TASK
│   │   └── setup_enterprise_governance.sql  # 7 governance tables + SLA task
│   └── rollback/
│       └── 01_rollback_procedures.sql       # Conditional auto-rollback
├── docs/guides/
│   ├── ASSESSMENT.md                        # Detailed scoring guide
│   ├── MIGRATION.md                         # Step-by-step migration
│   ├── MONITORING.md                        # Monitoring best practices
│   └── TROUBLESHOOTING.md                   # Common issues & fixes
├── examples/
│   ├── ai_workload_migration.sql            # AI/ML workload pattern
│   ├── etl_pipeline_migration.sql           # ETL pipeline pattern
│   └── mixed_analytics_migration.sql        # Mixed analytics pattern
└── tests/
    ├── test_runner.sql                      # Test orchestrator
    ├── test_assessment.sql                  # Score boundary tests
    ├── test_bulk_migration.sql              # Bulk migration validation
    ├── test_procedures.sql                  # Procedure unit tests
    ├── test_streamlit_queries.sql           # Dashboard query validation
    ├── test_views.sql                       # View schema tests
    └── validate_migration.sql               # Post-migration checks
```

---

## FAQ

**Q: Is there downtime during migration?**
A: No. Converting to/from Adaptive is an online operation — running queries complete on existing resources while new queries use the new compute type.

**Q: Can I migrate back to Standard?**
A: Yes. `ALTER WAREHOUSE ... SET WAREHOUSE_TYPE = 'STANDARD'` is instant and online.

**Q: Does this work with multi-cluster warehouses?**
A: Multi-cluster warehouses are excellent Adaptive candidates. Adaptive replaces complex scaling policies with native auto-scaling. The conversion preserves your workload routing.

**Q: What sizes are NOT supported?**
A: X5Large, X6Large, Snowpark-optimized, and Interactive warehouses cannot be converted.

**Q: How does billing work?**
A: Adaptive uses query-based billing — you pay for compute each query actually consumes. No charges during idle periods (unlike Gen1 which charges until auto-suspend fires).

**Q: How do I suspend/resume an Adaptive Warehouse?**
A: Use `ALTER WAREHOUSE ... DISABLE` (rejects new queries) and `ALTER WAREHOUSE ... ENABLE` (accepts queries). Not `SUSPEND`/`RESUME`.

**Q: Is the shared pool shared with other accounts?**
A: No. The shared compute pool is dedicated to your account.

**Q: What about the dashboard credit price?**
A: The app auto-detects your rate from `ORGANIZATION_USAGE.RATE_SHEET_DAILY` or `USAGE_IN_CURRENCY_DAILY`. Falls back to $3.00/credit (Enterprise default) if unavailable.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). We welcome:
- Additional monitoring queries
- Workload-specific migration patterns
- Cost analysis improvements
- Governance enhancements
- Bug fixes and documentation

---

## License

MIT License. See [LICENSE](LICENSE) for details.

---

*Built with insights from Snowflake's Adaptive Compute GA (June 16, 2026 on AWS; Azure and GCP regions added subsequently). Based on production implementations across all three clouds. References Snowflake documentation at [docs.snowflake.com/en/user-guide/warehouses-adaptive](https://docs.snowflake.com/en/user-guide/warehouses-adaptive).*
