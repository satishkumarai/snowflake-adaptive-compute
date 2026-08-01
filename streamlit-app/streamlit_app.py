# Adaptive Compute real-time monitoring dashboard with enterprise-grade UI


import os

import altair as alt
import pandas as pd
import streamlit as st

st.set_page_config(
    page_title="Adaptive Compute",
    page_icon=":material/speed:",
    layout="wide",
)

conn = st.connection("snowflake", ttl=os.getenv("SNOWFLAKE_CONNECTION_TTL"))

# Warehouse names from SHOW WAREHOUSES form the allowlist for filters
VALID_WH_NAMES: set = set()

# --- Configuration ---
# Materialized table schema — if these exist, queries hit pre-aggregated tables instead
STAGING_SCHEMA = "ADAPTIVE_COMPUTE_DB.ADAPTIVE_METRICS"
# Fallback credit price used in tag attribution SQL (overridden in ROI tab from rate sheet)
FALLBACK_CREDIT_PRICE = 3.00


def _to_float_df(df):
    """Convert all Decimal/numeric-object columns to float64 for Pandas arithmetic."""
    import decimal
    for c in df.columns:
        if df[c].dtype == object:
            sample = df[c].dropna().iloc[0] if not df[c].dropna().empty else None
            if isinstance(sample, decimal.Decimal):
                df[c] = df[c].astype(float)
        elif hasattr(df[c].dtype, "name") and "int" not in df[c].dtype.name and "float" not in df[c].dtype.name:
            try:
                df[c] = df[c].astype(float)
            except (ValueError, TypeError):
                pass
    return df


def _wh_in_clause(warehouse_filter):
    """Build a safe IN clause using allowlisted warehouse names."""
    if not warehouse_filter:
        return ""
    safe = [w for w in warehouse_filter if w in VALID_WH_NAMES]
    if not safe:
        return ""
    escaped = ", ".join(f"'{w.replace(chr(39), chr(39)+chr(39))}'" for w in safe)
    return f"AND warehouse_name IN ({escaped})"


def _check_materialized_tables():
    """Check if pre-aggregated staging tables exist for faster queries."""
    try:
        result = conn.query("""
            SELECT table_name FROM ADAPTIVE_COMPUTE_DB.INFORMATION_SCHEMA.TABLES
            WHERE table_schema = 'ADAPTIVE_METRICS'
              AND table_name IN ('HOURLY_METERING', 'HOURLY_QUERIES', 'WAREHOUSE_EVENTS_AGG',
                                 'AUDIT_LOG', 'MIGRATION_REQUESTS', 'WORKLOAD_SLA',
                                 'SLA_BREACHES', 'REGULATORY_CALENDAR', 'GL_CODE_MAPPING',
                                 'REGION_ADAPTIVE_SUPPORT')
        """)
        return set(result["TABLE_NAME"].tolist()) if not result.empty else set()
    except Exception:
        return set()


@st.cache_data(ttl=600)
def _materialized_tables_available():
    return _check_materialized_tables()


# ============================================================
# STRATEGY A: Consolidated base queries (2 wide scans instead of 9)
# ============================================================
@st.cache_data(ttl=120)
def load_metering_base(days_back):
    """Single scan of WAREHOUSE_METERING_HISTORY — all metering views derive from this."""
    days_back = int(days_back)
    tables = _materialized_tables_available()

    if "HOURLY_METERING" in tables:
        return conn.query(f"""
            SELECT warehouse_name, hour_ts, credits, tag_cost_center
            FROM {STAGING_SCHEMA}.HOURLY_METERING
            WHERE hour_ts >= DATEADD('day', -{days_back}, CURRENT_TIMESTAMP())
        """)

    df = conn.query(f"""
        SELECT
            warehouse_name,
            DATE_TRUNC('hour', start_time) AS hour_ts,
            SUM(credits_used) AS credits
        FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
        WHERE start_time >= DATEADD('day', -{days_back}, CURRENT_TIMESTAMP())
        GROUP BY 1, 2
    """)
    return _to_float_df(df)


@st.cache_data(ttl=120)
def load_query_base(days_back):
    """Single scan of QUERY_HISTORY — all query views derive from this."""
    days_back = int(days_back)
    tables = _materialized_tables_available()

    if "HOURLY_QUERIES" in tables:
        return conn.query(f"""
            SELECT warehouse_name, hour_ts, query_count, avg_elapsed_ms,
                   p95_elapsed_ms, total_queue_ms, queued_queries,
                   failed_queries, total_elapsed_failed_ms,
                   complex_queries, latency_stddev
            FROM {STAGING_SCHEMA}.HOURLY_QUERIES
            WHERE hour_ts >= DATEADD('day', -{days_back}, CURRENT_TIMESTAMP())
        """)

    df = conn.query(f"""
        SELECT
            warehouse_name,
            DATE_TRUNC('hour', start_time) AS hour_ts,
            COUNT_IF(execution_status = 'SUCCESS') AS query_count,
            AVG(CASE WHEN execution_status = 'SUCCESS' THEN total_elapsed_time END) AS avg_elapsed_ms,
            PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY CASE WHEN execution_status = 'SUCCESS' THEN total_elapsed_time END) AS p95_elapsed_ms,
            SUM(CASE WHEN execution_status = 'SUCCESS' THEN queued_overload_time ELSE 0 END) AS total_queue_ms,
            COUNT_IF(queued_overload_time > 0 AND execution_status = 'SUCCESS') AS queued_queries,
            COUNT_IF(execution_status = 'FAIL') AS failed_queries,
            SUM(CASE WHEN execution_status = 'FAIL' THEN total_elapsed_time ELSE 0 END) AS total_elapsed_failed_ms,
            COUNT_IF(warehouse_size IN ('X-Large','2X-Large','3X-Large','4X-Large') AND execution_status = 'SUCCESS') AS complex_queries,
            STDDEV(CASE WHEN execution_status = 'SUCCESS' THEN total_elapsed_time END) AS latency_stddev
        FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
        WHERE start_time >= DATEADD('day', -{days_back}, CURRENT_TIMESTAMP())
          AND warehouse_name IS NOT NULL
        GROUP BY 1, 2
    """)
    return _to_float_df(df)


@st.cache_data(ttl=300)
def load_events_base(days_back):
    """Single scan of WAREHOUSE_EVENTS_HISTORY."""
    days_back = int(days_back)
    tables = _materialized_tables_available()

    if "WAREHOUSE_EVENTS_AGG" in tables:
        return conn.query(f"""
            SELECT warehouse_name, hour_ts, event_name, event_count
            FROM {STAGING_SCHEMA}.WAREHOUSE_EVENTS_AGG
            WHERE hour_ts >= DATEADD('day', -{days_back}, CURRENT_TIMESTAMP())
        """)

    try:
        return conn.query(f"""
            SELECT
                warehouse_name,
                DATE_TRUNC('hour', timestamp) AS hour_ts,
                event_name,
                COUNT(*) AS event_count
            FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY
            WHERE timestamp >= DATEADD('day', -{days_back}, CURRENT_TIMESTAMP())
            GROUP BY 1, 2, 3
        """)
    except Exception:
        return pd.DataFrame()


# ============================================================
# DERIVED VIEWS — computed in Pandas from base queries (no extra SQL)
# ============================================================
def derive_credit_usage(metering_df, warehouse_filter):
    """Hourly credits per warehouse — replaces load_credit_usage."""
    df = metering_df.copy()
    if warehouse_filter:
        df = df[df["WAREHOUSE_NAME"].isin(warehouse_filter)]
    return df.rename(columns={"HOUR_TS": "HOUR_TS", "CREDITS": "CREDITS"})


def derive_credit_totals(metering_df):
    """Total credits per warehouse — replaces load_credit_totals."""
    return (
        metering_df.groupby("WAREHOUSE_NAME")["CREDITS"]
        .sum()
        .reset_index()
        .rename(columns={"CREDITS": "TOTAL_CREDITS"})
        .sort_values("TOTAL_CREDITS", ascending=False)
    )


def derive_query_performance(query_df, warehouse_filter):
    """Hourly perf metrics — replaces load_query_performance."""
    df = query_df.copy()
    if warehouse_filter:
        df = df[df["WAREHOUSE_NAME"].isin(warehouse_filter)]
    df["AVG_LATENCY_SEC"] = df["AVG_ELAPSED_MS"] / 1000
    df["P95_LATENCY_SEC"] = df["P95_ELAPSED_MS"] / 1000
    df["TOTAL_QUEUE_SEC"] = df["TOTAL_QUEUE_MS"] / 1000
    return df


def derive_idle_waste(metering_df, query_df):
    """Credits burned when no queries ran — replaces load_idle_credit_waste."""
    m_hourly = metering_df.copy()
    q_hourly = query_df.groupby(["WAREHOUSE_NAME", "HOUR_TS"])["QUERY_COUNT"].sum().reset_index()

    merged = m_hourly.merge(q_hourly, on=["WAREHOUSE_NAME", "HOUR_TS"], how="left")
    merged["QUERY_COUNT"] = merged["QUERY_COUNT"].fillna(0)

    result = merged.groupby("WAREHOUSE_NAME").agg(
        TOTAL_CREDITS=("CREDITS", "sum"),
        IDLE_CREDITS=("CREDITS", lambda x: x[merged.loc[x.index, "QUERY_COUNT"] == 0].sum()),
        TOTAL_HOURS=("HOUR_TS", "nunique"),
        IDLE_HOURS=("HOUR_TS", lambda x: (merged.loc[x.index, "QUERY_COUNT"] == 0).sum()),
    ).reset_index()
    result = result[result["TOTAL_CREDITS"] > 0].sort_values("IDLE_CREDITS", ascending=False)
    return result


def derive_anomalies(metering_df):
    """Z-score anomaly detection with BFSI calendar awareness."""
    df = metering_df.copy()
    df["DAY_TS"] = pd.to_datetime(df["HOUR_TS"]).dt.normalize()
    daily = df.groupby(["WAREHOUSE_NAME", "DAY_TS"])["CREDITS"].sum().reset_index()
    daily = daily.rename(columns={"CREDITS": "DAILY_CREDITS"})
    daily = daily.sort_values(["WAREHOUSE_NAME", "DAY_TS"])

    daily["ROLLING_AVG"] = daily.groupby("WAREHOUSE_NAME")["DAILY_CREDITS"].transform(
        lambda x: x.rolling(7, min_periods=3).mean().shift(1)
    )
    daily["ROLLING_STD"] = daily.groupby("WAREHOUSE_NAME")["DAILY_CREDITS"].transform(
        lambda x: x.rolling(7, min_periods=3).std().shift(1)
    )
    daily = daily.dropna(subset=["ROLLING_AVG"])
    daily["Z_SCORE"] = ((daily["DAILY_CREDITS"] - daily["ROLLING_AVG"]) / daily["ROLLING_STD"].replace(0, float("inf"))).round(2)

    # BFSI calendar awareness: suppress expected spikes on month-end, quarter-end, year-end
    daily["DAY_OF_MONTH"] = daily["DAY_TS"].dt.day
    daily["DAYS_IN_MONTH"] = daily["DAY_TS"].dt.days_in_month
    daily["IS_MONTH_END"] = (daily["DAYS_IN_MONTH"] - daily["DAY_OF_MONTH"]) <= 1
    daily["IS_QUARTER_END"] = daily["IS_MONTH_END"] & daily["DAY_TS"].dt.month.isin([3, 6, 9, 12])
    daily["IS_WEEKEND"] = daily["DAY_TS"].dt.dayofweek >= 5

    daily["ANOMALY_TYPE"] = "NORMAL"
    # Spikes: only flag if NOT a known high-processing window
    spike_mask = daily["DAILY_CREDITS"] > daily["ROLLING_AVG"] * 2
    daily.loc[spike_mask & ~daily["IS_MONTH_END"], "ANOMALY_TYPE"] = "SPIKE"
    daily.loc[spike_mask & daily["IS_MONTH_END"], "ANOMALY_TYPE"] = "EXPECTED_BATCH"
    # Drops: only flag if NOT a weekend (BFSI batch jobs don't run weekends)
    drop_mask = (daily["DAILY_CREDITS"] < daily["ROLLING_AVG"] * 0.2) & (daily["ROLLING_AVG"] > 1)
    daily.loc[drop_mask & ~daily["IS_WEEKEND"], "ANOMALY_TYPE"] = "DROP"

    anomalies = daily[daily["ANOMALY_TYPE"].isin(["SPIKE", "DROP", "EXPECTED_BATCH"])].copy()
    anomalies = anomalies.rename(columns={"ROLLING_AVG": "EXPECTED_CREDITS"})
    anomalies["DAILY_CREDITS"] = anomalies["DAILY_CREDITS"].round(2)
    anomalies["EXPECTED_CREDITS"] = anomalies["EXPECTED_CREDITS"].round(2)
    return anomalies.sort_values("DAY_TS", ascending=False)


def derive_assessment_scores(metering_df, query_df, days_back, warehouses_df=None):
    """Migration readiness score. Excludes already-Adaptive and unsupported warehouses."""
    total_possible_hours = int(days_back) * 24

    # Exclude already-Adaptive and unsupported sizes
    excluded_whs = set()
    if warehouses_df is not None and not warehouses_df.empty:
        already_adaptive = warehouses_df[warehouses_df["WAREHOUSE_TYPE"] == "ADAPTIVE"]["WAREHOUSE_NAME"].tolist()
        excluded_whs.update(already_adaptive)
        # 5XL/6XL and Snowpark-optimized are unsupported
        if "WAREHOUSE_SIZE" in warehouses_df.columns:
            unsupported = warehouses_df[warehouses_df["WAREHOUSE_SIZE"].isin(["5X-Large", "6X-Large"])]["WAREHOUSE_NAME"].tolist()
            excluded_whs.update(unsupported)

    working_metering = metering_df[~metering_df["WAREHOUSE_NAME"].isin(excluded_whs)] if excluded_whs else metering_df
    working_queries = query_df[~query_df["WAREHOUSE_NAME"].isin(excluded_whs)] if excluded_whs else query_df

    # Metering stats per warehouse
    m_stats = working_metering.groupby("WAREHOUSE_NAME").agg(
        active_hours=("HOUR_TS", "nunique"),
        avg_credits=("CREDITS", "mean"),
        std_credits=("CREDITS", "std"),
        total_credits=("CREDITS", "sum"),
    ).reset_index()
    m_stats["std_credits"] = m_stats["std_credits"].fillna(0)

    # Query stats per warehouse
    q_stats = working_queries.groupby("WAREHOUSE_NAME").agg(
        queued_queries=("QUEUED_QUERIES", "sum"),
        complex_queries=("COMPLEX_QUERIES", "sum"),
        total_queries=("QUERY_COUNT", "sum"),
        latency_stddev=("LATENCY_STDDEV", "mean"),
    ).reset_index()

    scores = m_stats.merge(q_stats, on="WAREHOUSE_NAME", how="left").fillna(0)
    scores["VARIABILITY"] = (scores["std_credits"] / scores["avg_credits"].replace(0, float("inf"))).round(3)
    scores["ADAPTIVE_SCORE"] = (
        (scores["VARIABILITY"] * 40).clip(upper=40)
        + ((1 - scores["active_hours"] / total_possible_hours) * 30).clip(upper=30)
        + (scores["queued_queries"] / scores["active_hours"].replace(0, 1) * 5).clip(upper=20)
        + (scores["total_credits"] / 100).clip(upper=10)
    ).round(1)

    scores = scores.rename(columns={
        "active_hours": "ACTIVE_HOURS",
        "total_credits": "TOTAL_CREDITS_14D",
        "queued_queries": "QUEUED_QUERIES",
        "complex_queries": "COMPLEX_QUERIES",
        "total_queries": "TOTAL_QUERIES",
        "latency_stddev": "LATENCY_STDDEV",
    })
    return scores.sort_values("ADAPTIVE_SCORE", ascending=False)


def derive_suspend_resume(events_df, warehouse_filter):
    """Suspend/resume frequency — replaces load_suspend_resume_frequency."""
    if events_df.empty:
        return pd.DataFrame()
    df = events_df.copy()
    if warehouse_filter:
        df = df[df["WAREHOUSE_NAME"].isin(warehouse_filter)]

    suspend_events = ["SUSPEND_WAREHOUSE", "SUSPEND_WAREHOUSE_SUCCEEDED"]
    resume_events = ["RESUME_WAREHOUSE", "RESUME_WAREHOUSE_SUCCEEDED"]

    summary = df.groupby("WAREHOUSE_NAME").apply(
        lambda g: pd.Series({
            "SUSPENDS": g[g["EVENT_NAME"].isin(suspend_events)]["EVENT_COUNT"].sum(),
            "RESUMES": g[g["EVENT_NAME"].isin(resume_events)]["EVENT_COUNT"].sum(),
            "SCALING_EVENTS": g[g["EVENT_NAME"].str.contains("SCALE", case=False, na=False)]["EVENT_COUNT"].sum(),
        })
    ).reset_index()
    return summary.sort_values("RESUMES", ascending=False)


def derive_events_summary(events_df, warehouse_filter):
    """Events summary — replaces load_warehouse_events."""
    if events_df.empty:
        return pd.DataFrame()
    df = events_df.copy()
    if warehouse_filter:
        df = df[df["WAREHOUSE_NAME"].isin(warehouse_filter)]
    summary = df.groupby(["WAREHOUSE_NAME", "EVENT_NAME"]).agg(
        EVENT_COUNT=("EVENT_COUNT", "sum"),
    ).reset_index().sort_values(["WAREHOUSE_NAME", "EVENT_COUNT"], ascending=[True, False])
    return summary


# --- Queries that cannot be easily derived from base scans ---
@st.cache_data(ttl=120)
def load_warehouse_inventory():
    """Uses SHOW WAREHOUSES."""
    session = conn.session()
    df = session.sql("SHOW WAREHOUSES").collect()
    pdf = pd.DataFrame(df)
    cols = {
        "name": "WAREHOUSE_NAME",
        "type": "WAREHOUSE_TYPE",
        "state": "STATE",
        "size": "WAREHOUSE_SIZE",
        "generation": "GENERATION",
        "max_query_performance_level": "MAX_QUERY_PERF_LEVEL",
        "query_throughput_multiplier": "THROUGHPUT_MULTIPLIER",
        "min_cluster_count": "MIN_CLUSTERS",
        "max_cluster_count": "MAX_CLUSTERS",
        "auto_suspend": "AUTO_SUSPEND",
        "resource_monitor": "RESOURCE_MONITOR",
    }
    available = {k: v for k, v in cols.items() if k in pdf.columns}
    return pdf[list(available.keys())].rename(columns=available)


@st.cache_data(ttl=600)
def load_session_context():
    return conn.query("SELECT CURRENT_ACCOUNT_NAME() AS ACCOUNT, CURRENT_ROLE() AS ROLE")


@st.cache_data(ttl=3600)
def load_credit_price():
    """Fetch actual credit price from Snowflake's rate/usage views.
    Tries multiple approaches with graceful fallback."""
    # Method 1: Organization usage rate sheet (requires ORGADMIN or imported privileges)
    try:
        rate_df = conn.query("""
            SELECT effective_rate
            FROM SNOWFLAKE.ORGANIZATION_USAGE.RATE_SHEET_DAILY
            WHERE service_type = 'WAREHOUSE_METERING'
              AND usage_type = 'compute'
              AND date >= DATEADD('day', -7, CURRENT_DATE())
              AND effective_rate > 0
            ORDER BY date DESC
            LIMIT 1
        """)
        if not rate_df.empty:
            return float(rate_df.iloc[0, 0])
    except Exception:
        pass

    # Method 2: Derive from currency usage (Organization-level)
    try:
        price_df = conn.query("""
            SELECT
                ROUND(SUM(usage_in_currency) / NULLIF(SUM(usage), 0), 2) AS effective_rate
            FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
            WHERE usage_type = 'compute'
              AND usage_date >= DATEADD('day', -7, CURRENT_DATE())
              AND usage > 0
        """)
        if not price_df.empty and price_df.iloc[0, 0] is not None:
            val = float(price_df.iloc[0, 0])
            if val > 0:
                return val
    except Exception:
        pass

    # Method 3: Fallback based on Snowflake edition pricing (July 2026)
    # Standard=$2.00, Enterprise=$3.00, Business Critical=$4.00
    return FALLBACK_CREDIT_PRICE


@st.cache_data(ttl=300)
def load_before_after_comparison():
    """Compare credit efficiency pre vs post Adaptive migration."""
    return conn.query("""
        WITH migrated AS (
            SELECT
                warehouse_name,
                MIN(timestamp) AS migration_date
            FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_EVENTS_HISTORY
            WHERE event_name = 'CONVERT_WAREHOUSE'
              AND event_reason = 'CONVERT_TO_ADAPTIVE'
            GROUP BY 1
        ),
        pre_migration AS (
            SELECT
                m.warehouse_name,
                SUM(h.credits_used) AS pre_credits,
                COUNT(DISTINCT DATE_TRUNC('day', h.start_time)) AS pre_days
            FROM migrated m
            JOIN SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY h
              ON m.warehouse_name = h.warehouse_name
              AND h.start_time BETWEEN DATEADD('day', -30, m.migration_date) AND m.migration_date
            GROUP BY 1
        ),
        post_migration AS (
            SELECT
                m.warehouse_name,
                SUM(h.credits_used) AS post_credits,
                COUNT(DISTINCT DATE_TRUNC('day', h.start_time)) AS post_days
            FROM migrated m
            JOIN SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY h
              ON m.warehouse_name = h.warehouse_name
              AND h.start_time BETWEEN m.migration_date AND DATEADD('day', 30, m.migration_date)
            GROUP BY 1
        )
        SELECT
            p.warehouse_name,
            ROUND(p.pre_credits, 2) AS pre_credits_30d,
            ROUND(COALESCE(a.post_credits, 0), 2) AS post_credits_30d,
            ROUND(p.pre_credits / NULLIF(p.pre_days, 0), 2) AS pre_daily_avg,
            ROUND(COALESCE(a.post_credits, 0) / NULLIF(a.post_days, 0), 2) AS post_daily_avg,
            ROUND((p.pre_credits - COALESCE(a.post_credits, 0)) / NULLIF(p.pre_credits, 0) * 100, 1) AS savings_pct
        FROM pre_migration p
        LEFT JOIN post_migration a ON p.warehouse_name = a.warehouse_name
        ORDER BY savings_pct DESC
    """)


@st.cache_data(ttl=300)
def load_tag_attribution(days_back):
    """Tag attribution requires JOIN with TAG_REFERENCES — kept as separate query."""
    days_back = int(days_back)
    return conn.query(f"""
        SELECT
            COALESCE(t.tag_value, 'Untagged') AS cost_center,
            h.warehouse_name,
            ROUND(SUM(h.credits_used), 2) AS total_credits,
            ROUND(SUM(h.credits_used) * {FALLBACK_CREDIT_PRICE}, 2) AS estimated_cost_usd
        FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY h
        LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES t
          ON t.object_name = h.warehouse_name
          AND t.domain = 'WAREHOUSE'
          AND t.tag_name = 'COST_CENTER'
        WHERE h.start_time >= DATEADD('day', -{days_back}, CURRENT_TIMESTAMP())
        GROUP BY 1, 2
        ORDER BY 3 DESC
    """)


@st.cache_data(ttl=300)
def load_query_failure_detail(days_back, warehouse_filter):
    """Top failed query errors — needs error_code/message not in base scan."""
    days_back = int(days_back)
    wh_clause = _wh_in_clause(warehouse_filter)
    return conn.query(f"""
        SELECT
            warehouse_name,
            error_code,
            error_message,
            COUNT(*) AS failed_queries,
            ROUND(SUM(total_elapsed_time) / 3600000.0, 4) AS wasted_hours
        FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
        WHERE start_time >= DATEADD('day', -{days_back}, CURRENT_TIMESTAMP())
          AND execution_status = 'FAIL'
          AND warehouse_name IS NOT NULL
          {wh_clause}
        GROUP BY 1, 2, 3
        ORDER BY 4 DESC
        LIMIT 20
    """)


# --- Sidebar ---
with st.sidebar:
    st.markdown("#### :material/speed: Adaptive Compute")
    st.caption("Real-time monitoring & migration")

    days_back = st.selectbox(
        "Time range",
        options=[1, 3, 7, 14, 30],
        index=2,
        format_func=lambda x: f"Last {x} day{'s' if x > 1 else ''}",
    )

    with st.spinner("Loading warehouses..."):
        warehouses_df = load_warehouse_inventory()

    all_warehouses = warehouses_df["WAREHOUSE_NAME"].tolist() if not warehouses_df.empty else []
    VALID_WH_NAMES.update(all_warehouses)

    adaptive_warehouses = (
        warehouses_df[warehouses_df["WAREHOUSE_TYPE"] == "ADAPTIVE"]["WAREHOUSE_NAME"].tolist()
        if not warehouses_df.empty
        else []
    )
    standard_warehouses = [w for w in all_warehouses if w not in adaptive_warehouses]

    multi_cluster_warehouses = []
    if not warehouses_df.empty and "MAX_CLUSTERS" in warehouses_df.columns:
        multi_cluster_warehouses = warehouses_df[
            warehouses_df["MAX_CLUSTERS"].astype(str).str.strip().apply(
                lambda x: int(x) > 1 if x.isdigit() else False
            )
        ]["WAREHOUSE_NAME"].tolist()

    warehouse_filter = st.multiselect(
        "Warehouses",
        options=all_warehouses,
        default=adaptive_warehouses[:5] if adaptive_warehouses else all_warehouses[:5],
        placeholder="Select warehouses",
    )

    st.space("medium")

    def _clear_all():
        load_metering_base.clear()
        load_query_base.clear()
        load_events_base.clear()
        load_warehouse_inventory.clear()
        load_session_context.clear()
        load_credit_price.clear()
        load_before_after_comparison.clear()
        load_tag_attribution.clear()
        load_query_failure_detail.clear()
        _materialized_tables_available.clear()

    st.button("Refresh", icon=":material/refresh:", on_click=_clear_all, type="tertiary")

    st.space("large")
    ctx_df = load_session_context()
    st.caption(f"Account: **{ctx_df.iloc[0, 0]}**")
    st.caption(f"Role: **{ctx_df.iloc[0, 1]}**")

    # Show optimization status
    mat_tables = _materialized_tables_available()
    if mat_tables:
        st.badge(f"Optimized ({len(mat_tables)} tables)", icon=":material/bolt:", color="green")
    else:
        st.badge("Direct query mode", icon=":material/database:", color="orange")


# --- Load base data (2-3 queries instead of 9+) ---
with st.spinner("Loading base data..."):
    metering_df = load_metering_base(days_back)
    query_df = load_query_base(days_back)
    events_df = load_events_base(days_back)

# --- Header ---
st.title("Adaptive Compute")
st.caption("Monitor performance, assess migration candidates, estimate savings, and track cost across your warehouse fleet")

# --- KPI row ---
total_wh = len(all_warehouses)
adaptive_count = len(adaptive_warehouses)
standard_count = len(standard_warehouses)
adoption_pct = round(adaptive_count / total_wh * 100, 1) if total_wh > 0 else 0

with st.container(horizontal=True):
    st.metric("Total warehouses", total_wh, border=True)
    st.metric("Adaptive", adaptive_count, help="Warehouses with type ADAPTIVE", border=True)
    st.metric("Standard", standard_count, border=True)
    st.metric("Multi-cluster", len(multi_cluster_warehouses), help="Standard WHs with max_clusters > 1 — strong Adaptive candidates", border=True)
    st.metric("Adoption rate", f"{adoption_pct}%", border=True)

# --- Tabs ---
tab_overview, tab_perf, tab_roi, tab_anomaly, tab_assess, tab_whatif, tab_govern, tab_migrate = st.tabs([
    ":material/analytics: Overview",
    ":material/query_stats: Performance",
    ":material/savings: ROI & Savings",
    ":material/warning: Anomalies",
    ":material/assessment: Assessment",
    ":material/compare: What-If",
    ":material/shield: Governance",
    ":material/swap_horiz: Migrate",
])


# ============================================================
# TAB: Overview
# ============================================================
with tab_overview:
    credits_df = derive_credit_usage(metering_df, warehouse_filter)

    if credits_df.empty:
        st.info("No credit data for the selected filters.", icon=":material/info:")
    else:
        with st.container(border=True):
            st.markdown("**Credit consumption over time**")
            chart = (
                alt.Chart(credits_df)
                .mark_area(opacity=0.6, interpolate="monotone")
                .encode(
                    x=alt.X("HOUR_TS:T", title=""),
                    y=alt.Y("CREDITS:Q", title="Credits", stack="zero"),
                    color=alt.Color(
                        "WAREHOUSE_NAME:N",
                        title="Warehouse",
                        legend=alt.Legend(orient="bottom", columns=4),
                    ),
                    tooltip=[
                        alt.Tooltip("HOUR_TS:T", title="Time"),
                        alt.Tooltip("WAREHOUSE_NAME:N", title="Warehouse"),
                        alt.Tooltip("CREDITS:Q", title="Credits", format=".2f"),
                    ],
                )
                .properties(height=320)
            )
            st.altair_chart(chart)

        col1, col2 = st.columns(2)
        with col1:
            with st.container(border=True):
                st.markdown("**:material/account_balance_wallet: Top consumers**")
                totals_df = derive_credit_totals(metering_df)
                if not totals_df.empty:
                    wh_types = dict(zip(warehouses_df["WAREHOUSE_NAME"], warehouses_df["WAREHOUSE_TYPE"]))
                    for _, row in totals_df.head(6).iterrows():
                        wh_name = row["WAREHOUSE_NAME"]
                        credits = row["TOTAL_CREDITS"]
                        wh_type = wh_types.get(wh_name, "STANDARD")
                        icon = ":material/bolt:" if wh_type == "ADAPTIVE" else ":material/warehouse:"
                        st.markdown(f"{icon} **{wh_name}** — {credits:,.1f} credits")
                else:
                    st.caption("No data available")

        with col2:
            with st.container(border=True):
                st.markdown("**:material/pie_chart: Credit distribution**")
                if not credits_df.empty:
                    dist = credits_df.groupby("WAREHOUSE_NAME")["CREDITS"].sum().reset_index()
                    dist = dist.sort_values("CREDITS", ascending=False).head(8)
                    pie = (
                        alt.Chart(dist)
                        .mark_arc(innerRadius=50)
                        .encode(
                            theta=alt.Theta("CREDITS:Q"),
                            color=alt.Color("WAREHOUSE_NAME:N", legend=None),
                            tooltip=[
                                alt.Tooltip("WAREHOUSE_NAME:N", title="Warehouse"),
                                alt.Tooltip("CREDITS:Q", title="Credits", format=".1f"),
                            ],
                        )
                        .properties(height=200)
                    )
                    st.altair_chart(pie)

    # Tag-based cost attribution
    st.space("medium")
    with st.container(border=True):
        st.markdown("**:material/label: Cost attribution by tag**")
        st.caption("Based on `COST_CENTER` tag on warehouses. [Set up tags](https://docs.snowflake.com/en/user-guide/object-tagging) to enable chargeback.")
        try:
            tag_df = load_tag_attribution(days_back)
            if not tag_df.empty:
                tag_summary = tag_df.groupby("COST_CENTER").agg(
                    {"TOTAL_CREDITS": "sum", "ESTIMATED_COST_USD": "sum"}
                ).reset_index().sort_values("TOTAL_CREDITS", ascending=False)

                col_t1, col_t2 = st.columns([1, 1])
                with col_t1:
                    st.dataframe(
                        tag_summary,
                        column_config={
                            "COST_CENTER": st.column_config.TextColumn("Cost Center"),
                            "TOTAL_CREDITS": st.column_config.NumberColumn("Credits", format="%.1f"),
                            "ESTIMATED_COST_USD": st.column_config.NumberColumn("Est. Cost ($)", format="$%.2f"),
                        },
                        hide_index=True,
                    )
                with col_t2:
                    tag_chart = (
                        alt.Chart(tag_summary.head(10))
                        .mark_bar(cornerRadiusTopLeft=4, cornerRadiusTopRight=4)
                        .encode(
                            x=alt.X("TOTAL_CREDITS:Q", title="Credits"),
                            y=alt.Y("COST_CENTER:N", title="", sort="-x"),
                            color=alt.Color("COST_CENTER:N", legend=None),
                        )
                        .properties(height=200)
                    )
                    st.altair_chart(tag_chart)
            else:
                st.caption("No tag data found. Apply `COST_CENTER` tags to warehouses for chargeback visibility.")
        except Exception:
            st.caption("Tag attribution requires access to `SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES`.")


# ============================================================
# TAB: Performance
# ============================================================
with tab_perf:
    perf_df = derive_query_performance(query_df, warehouse_filter)

    if perf_df.empty:
        st.info("No performance data for the selected filters.", icon=":material/info:")
    else:
        avg_latency = perf_df["AVG_LATENCY_SEC"].mean()
        p95_latency = perf_df["P95_LATENCY_SEC"].mean()
        total_queries = int(perf_df["QUERY_COUNT"].sum())
        total_queued = int(perf_df["QUEUED_QUERIES"].sum())

        with st.container(horizontal=True):
            st.metric("Avg latency", f"{avg_latency:.2f}s", border=True)
            st.metric("P95 latency", f"{p95_latency:.2f}s", border=True)
            st.metric("Total queries", f"{total_queries:,}", border=True)
            st.metric("Queued queries", f"{total_queued:,}", border=True)

        with st.container(border=True):
            st.markdown("**:material/timer: P95 query latency**")
            latency_chart = (
                alt.Chart(perf_df)
                .mark_line(interpolate="monotone", strokeWidth=2)
                .encode(
                    x=alt.X("HOUR_TS:T", title=""),
                    y=alt.Y("P95_LATENCY_SEC:Q", title="Seconds"),
                    color=alt.Color(
                        "WAREHOUSE_NAME:N",
                        title="Warehouse",
                        legend=alt.Legend(orient="bottom", columns=4),
                    ),
                    tooltip=[
                        alt.Tooltip("HOUR_TS:T", title="Time"),
                        alt.Tooltip("WAREHOUSE_NAME:N", title="Warehouse"),
                        alt.Tooltip("P95_LATENCY_SEC:Q", title="P95 (sec)", format=".2f"),
                    ],
                )
                .properties(height=280)
            )
            st.altair_chart(latency_chart)

        col1, col2 = st.columns(2)
        with col1:
            with st.container(border=True):
                st.markdown("**:material/hourglass_empty: Queue time**")
                queue_chart = (
                    alt.Chart(perf_df)
                    .mark_bar(opacity=0.7)
                    .encode(
                        x=alt.X("HOUR_TS:T", title=""),
                        y=alt.Y("TOTAL_QUEUE_SEC:Q", title="Seconds", stack="zero"),
                        color=alt.Color("WAREHOUSE_NAME:N", legend=None),
                        tooltip=[
                            alt.Tooltip("WAREHOUSE_NAME:N", title="Warehouse"),
                            alt.Tooltip("TOTAL_QUEUE_SEC:Q", title="Queue (sec)", format=".1f"),
                        ],
                    )
                    .properties(height=220)
                )
                st.altair_chart(queue_chart)

        with col2:
            with st.container(border=True):
                st.markdown("**:material/stacked_bar_chart: Query volume**")
                volume_chart = (
                    alt.Chart(perf_df)
                    .mark_bar(opacity=0.7)
                    .encode(
                        x=alt.X("HOUR_TS:T", title=""),
                        y=alt.Y("QUERY_COUNT:Q", title="Queries", stack="zero"),
                        color=alt.Color("WAREHOUSE_NAME:N", legend=None),
                        tooltip=[
                            alt.Tooltip("WAREHOUSE_NAME:N", title="Warehouse"),
                            alt.Tooltip("QUERY_COUNT:Q", title="Queries"),
                        ],
                    )
                    .properties(height=220)
                )
                st.altair_chart(volume_chart)

    # Warehouse events
    st.space("medium")
    with st.container(border=True):
        st.markdown("**:material/event: Warehouse scaling & lifecycle events**")
        st.caption("From `WAREHOUSE_EVENTS_HISTORY` — shows suspend/resume cycles, scaling events, and configuration changes.")
        events_summary = derive_events_summary(events_df, warehouse_filter)
        if not events_summary.empty:
            st.dataframe(events_summary, hide_index=True)
        else:
            st.caption("No events found for the selected period.")

    # Failed query cost
    st.space("medium")
    with st.container(border=True):
        st.markdown("**:material/error: Wasted compute — failed queries**")
        try:
            fail_df = load_query_failure_detail(days_back, warehouse_filter)
            if not fail_df.empty:
                st.dataframe(
                    fail_df,
                    column_config={
                        "WAREHOUSE_NAME": st.column_config.TextColumn("Warehouse"),
                        "ERROR_CODE": st.column_config.TextColumn("Error Code"),
                        "ERROR_MESSAGE": st.column_config.TextColumn("Error", width="large"),
                        "FAILED_QUERIES": st.column_config.NumberColumn("Failed Queries"),
                        "WASTED_HOURS": st.column_config.NumberColumn("Wasted Hours", format="%.4f"),
                    },
                    hide_index=True,
                )
            else:
                st.caption("No failed queries in the selected period.")
        except Exception:
            st.caption("Failed query data requires access to `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY`.")


# ============================================================
# TAB: ROI & Savings
# ============================================================
with tab_roi:
    st.markdown("**:material/savings: ROI Calculator & Savings Analysis**")
    st.caption("Estimate potential savings from migrating to Adaptive Compute")

    col_roi1, col_roi2 = st.columns([2, 1])
    with col_roi2:
        with st.container(border=True):
            st.markdown("**Assumptions**")
            detected_price = load_credit_price()
            credit_price = st.number_input(
                "Credit price ($/credit)",
                value=detected_price,
                step=0.25,
                format="%.2f",
                help=f"Auto-detected: ${detected_price:.2f}/credit from your account's rate sheet",
            )
            adaptive_savings_pct = st.slider("Estimated savings %", min_value=5, max_value=50, value=25, help="Typical Adaptive savings range: 15-35%")

    with col_roi1:
        with st.container(border=True):
            st.markdown("**:material/calculate: Projected savings**")
            idle_df = derive_idle_waste(metering_df, query_df)
            if not idle_df.empty:
                total_credits_all = float(idle_df["TOTAL_CREDITS"].sum())
                total_idle = float(idle_df["IDLE_CREDITS"].sum())
                idle_pct = round(total_idle / total_credits_all * 100, 1) if total_credits_all > 0 else 0

                std_idle = idle_df[idle_df["WAREHOUSE_NAME"].isin(standard_warehouses)]
                std_credits = float(std_idle["TOTAL_CREDITS"].sum()) if not std_idle.empty else 0.0
                projected_savings_credits = std_credits * (adaptive_savings_pct / 100)
                projected_savings_usd = projected_savings_credits * credit_price

                daily_factor = 365 / max(days_back, 1)
                annual_savings = projected_savings_usd * daily_factor

                with st.container(horizontal=True):
                    st.metric(f"Total credits ({days_back}d)", f"{total_credits_all:,.1f}", border=True)
                    st.metric("Idle credits (wasted)", f"{total_idle:,.1f}", help=f"{idle_pct}% of total", border=True)
                    st.metric("Projected savings", f"${projected_savings_usd:,.0f}", help=f"{days_back}-day period", border=True)
                    st.metric("Annual projection", f"${annual_savings:,.0f}", border=True)

                st.space("small")
                st.markdown("**Idle credit breakdown by warehouse**")
                idle_display = idle_df.copy()
                idle_display["IDLE_PCT"] = (idle_display["IDLE_CREDITS"].astype(float) / idle_display["TOTAL_CREDITS"].astype(float) * 100).round(1)
                idle_display["WASTED_USD"] = (idle_display["IDLE_CREDITS"].astype(float) * credit_price).round(2)
                st.dataframe(
                    idle_display,
                    column_config={
                        "WAREHOUSE_NAME": st.column_config.TextColumn("Warehouse"),
                        "TOTAL_CREDITS": st.column_config.NumberColumn("Total Credits", format="%.1f"),
                        "IDLE_CREDITS": st.column_config.NumberColumn("Idle Credits", format="%.1f"),
                        "IDLE_PCT": st.column_config.ProgressColumn("Idle %", min_value=0, max_value=100, format="%.0f%%"),
                        "TOTAL_HOURS": st.column_config.NumberColumn("Active Hours"),
                        "IDLE_HOURS": st.column_config.NumberColumn("Idle Hours"),
                        "WASTED_USD": st.column_config.NumberColumn("Wasted ($)", format="$%.2f"),
                    },
                    hide_index=True,
                )
            else:
                st.info("No idle credit data available.", icon=":material/info:")

    # Before/After comparison
    st.space("medium")
    with st.container(border=True):
        st.markdown("**:material/compare_arrows: Before vs After migration**")
        st.caption("Compares 30-day credit usage before and after warehouses were converted to Adaptive.")
        try:
            ba_df = load_before_after_comparison()
            if not ba_df.empty:
                with st.container(horizontal=True):
                    avg_savings = ba_df["SAVINGS_PCT"].mean()
                    st.metric("Avg savings", f"{avg_savings:.1f}%", border=True)
                    st.metric("Warehouses migrated", len(ba_df), border=True)

                st.dataframe(
                    ba_df,
                    column_config={
                        "WAREHOUSE_NAME": st.column_config.TextColumn("Warehouse"),
                        "PRE_CREDITS_30D": st.column_config.NumberColumn("Pre (30d credits)", format="%.1f"),
                        "POST_CREDITS_30D": st.column_config.NumberColumn("Post (30d credits)", format="%.1f"),
                        "PRE_DAILY_AVG": st.column_config.NumberColumn("Pre daily avg", format="%.2f"),
                        "POST_DAILY_AVG": st.column_config.NumberColumn("Post daily avg", format="%.2f"),
                        "SAVINGS_PCT": st.column_config.NumberColumn("Savings %", format="%.1f%%"),
                    },
                    hide_index=True,
                )

                ba_chart = (
                    alt.Chart(ba_df)
                    .transform_fold(["PRE_DAILY_AVG", "POST_DAILY_AVG"], as_=["Period", "Credits"])
                    .mark_bar(cornerRadiusTopLeft=3, cornerRadiusTopRight=3)
                    .encode(
                        x=alt.X("WAREHOUSE_NAME:N", title=""),
                        y=alt.Y("Credits:Q", title="Daily avg credits"),
                        color=alt.Color("Period:N", scale=alt.Scale(domain=["PRE_DAILY_AVG", "POST_DAILY_AVG"], range=["#FF7043", "#66BB6A"])),
                        xOffset="Period:N",
                        tooltip=[
                            alt.Tooltip("WAREHOUSE_NAME:N", title="Warehouse"),
                            alt.Tooltip("Period:N"),
                            alt.Tooltip("Credits:Q", format=".2f"),
                        ],
                    )
                    .properties(height=250)
                )
                st.altair_chart(ba_chart)
            else:
                st.info("No migration events detected. This view populates after warehouses are converted to Adaptive.", icon=":material/info:")
        except Exception:
            st.caption("Before/after comparison requires access to `WAREHOUSE_EVENTS_HISTORY` and `WAREHOUSE_METERING_HISTORY`.")

    # Suspend/resume frequency
    st.space("medium")
    with st.container(border=True):
        st.markdown("**:material/sync: Suspend/resume frequency**")
        st.caption("High suspend/resume cycling indicates workloads that benefit most from Adaptive's always-on, pay-per-query model.")
        sr_df = derive_suspend_resume(events_df, warehouse_filter)
        if not sr_df.empty:
            st.dataframe(
                sr_df,
                column_config={
                    "WAREHOUSE_NAME": st.column_config.TextColumn("Warehouse"),
                    "SUSPENDS": st.column_config.NumberColumn("Suspends"),
                    "RESUMES": st.column_config.NumberColumn("Resumes"),
                    "SCALING_EVENTS": st.column_config.NumberColumn("Scale events"),
                },
                hide_index=True,
            )
        else:
            st.caption("No suspend/resume events in the selected period.")


# ============================================================
# TAB: Anomalies
# ============================================================
with tab_anomaly:
    st.markdown("**:material/warning: Cost anomaly detection**")
    st.caption("Flags days where credit usage deviated significantly from the 7-day rolling average (>2x spike or <20% drop).")

    anomaly_df = derive_anomalies(metering_df)
    if anomaly_df.empty:
        st.info("No anomalies detected in the selected period.", icon=":material/check_circle:")
    else:
        spike_count = len(anomaly_df[anomaly_df["ANOMALY_TYPE"] == "SPIKE"])
        drop_count = len(anomaly_df[anomaly_df["ANOMALY_TYPE"] == "DROP"])
        expected_batch_count = len(anomaly_df[anomaly_df["ANOMALY_TYPE"] == "EXPECTED_BATCH"])

        with st.container(horizontal=True):
            st.metric("Unexpected spikes", spike_count, help="Days with >2x expected (not month-end)", border=True)
            st.metric("Unexpected drops", drop_count, help="Days with <20% expected (not weekends)", border=True)
            st.metric("Expected batch spikes", expected_batch_count, help="Month-end/quarter-end — suppressed as expected", border=True)
            st.metric("Warehouses affected", anomaly_df["WAREHOUSE_NAME"].nunique(), border=True)

        with st.container(border=True):
            st.dataframe(
                anomaly_df[["WAREHOUSE_NAME", "DAY_TS", "DAILY_CREDITS", "EXPECTED_CREDITS", "Z_SCORE", "ANOMALY_TYPE"]],
                column_config={
                    "WAREHOUSE_NAME": st.column_config.TextColumn("Warehouse"),
                    "DAY_TS": st.column_config.DateColumn("Date", format="MMM D"),
                    "DAILY_CREDITS": st.column_config.NumberColumn("Actual credits", format="%.2f"),
                    "EXPECTED_CREDITS": st.column_config.NumberColumn("Expected (7d avg)", format="%.2f"),
                    "Z_SCORE": st.column_config.NumberColumn("Z-Score", format="%.1f"),
                    "ANOMALY_TYPE": st.column_config.TextColumn("Type"),
                },
                hide_index=True,
            )

        with st.container(border=True):
            st.markdown("**Anomaly timeline**")
            anom_chart = (
                alt.Chart(anomaly_df)
                .mark_circle(size=100)
                .encode(
                    x=alt.X("DAY_TS:T", title=""),
                    y=alt.Y("DAILY_CREDITS:Q", title="Credits"),
                    color=alt.Color("ANOMALY_TYPE:N", scale=alt.Scale(domain=["SPIKE", "DROP", "EXPECTED_BATCH"], range=["#FF5722", "#2196F3", "#FFA726"])),
                    size=alt.Size("Z_SCORE:Q", legend=None),
                    tooltip=[
                        alt.Tooltip("WAREHOUSE_NAME:N", title="Warehouse"),
                        alt.Tooltip("DAY_TS:T", title="Date"),
                        alt.Tooltip("DAILY_CREDITS:Q", title="Actual", format=".2f"),
                        alt.Tooltip("EXPECTED_CREDITS:Q", title="Expected", format=".2f"),
                        alt.Tooltip("Z_SCORE:Q", title="Z-Score", format=".1f"),
                    ],
                )
                .properties(height=250)
            )
            st.altair_chart(anom_chart)


# ============================================================
# TAB: Assessment
# ============================================================
with tab_assess:
    scores_df = derive_assessment_scores(metering_df, query_df, days_back, warehouses_df)

    if scores_df.empty:
        st.info("No warehouse data available for scoring.", icon=":material/info:")
    else:
        st.markdown("**:material/fact_check: Migration readiness scores**")
        st.caption(
            "Warehouses scored 0-100 on workload variability, idle time, queue pressure, and credit volume. "
            "Higher scores indicate stronger candidates for Adaptive Compute."
        )

        wh_type_map = dict(zip(warehouses_df["WAREHOUSE_NAME"], warehouses_df["WAREHOUSE_TYPE"]))
        wh_size_map = dict(zip(warehouses_df["WAREHOUSE_NAME"], warehouses_df["WAREHOUSE_SIZE"]))
        scores_df = scores_df.copy()
        scores_df["WAREHOUSE_TYPE"] = scores_df["WAREHOUSE_NAME"].map(wh_type_map).fillna("UNKNOWN")
        scores_df["WAREHOUSE_SIZE"] = scores_df["WAREHOUSE_NAME"].map(wh_size_map).fillna("")
        scores_df["MULTI_CLUSTER"] = scores_df["WAREHOUSE_NAME"].apply(
            lambda x: "Yes" if x in multi_cluster_warehouses else "No"
        )

        st.dataframe(
            scores_df,
            column_config={
                "WAREHOUSE_NAME": st.column_config.TextColumn("Warehouse", pinned=True),
                "WAREHOUSE_TYPE": st.column_config.TextColumn("Type"),
                "WAREHOUSE_SIZE": st.column_config.TextColumn("Size"),
                "MULTI_CLUSTER": st.column_config.TextColumn("Multi-cluster"),
                "ACTIVE_HOURS": st.column_config.NumberColumn("Active hours"),
                "TOTAL_CREDITS_14D": st.column_config.NumberColumn("Credits", format="%.1f"),
                "VARIABILITY": st.column_config.NumberColumn("Variability", format="%.3f"),
                "QUEUED_QUERIES": st.column_config.NumberColumn("Queued"),
                "COMPLEX_QUERIES": st.column_config.NumberColumn("Complex Q"),
                "LATENCY_STDDEV": st.column_config.NumberColumn("Latency σ", format="%.0f"),
                "ADAPTIVE_SCORE": st.column_config.ProgressColumn("Score", min_value=0, max_value=100, format="%.0f"),
            },
            hide_index=True,
        )

        st.space("medium")
        col1, col2, col3, col4 = st.columns(4)
        with col1:
            with st.container(border=True):
                st.markdown(":material/rocket_launch: **80-100**")
                st.badge("Migrate now", icon=":material/check_circle:", color="green")
                st.caption("High variability, significant idle time")
        with col2:
            with st.container(border=True):
                st.markdown(":material/thumb_up: **60-79**")
                st.badge("Strong candidate", icon=":material/trending_up:", color="blue")
                st.caption("Moderate variability, good savings")
        with col3:
            with st.container(border=True):
                st.markdown(":material/science: **40-59**")
                st.badge("Evaluate", icon=":material/science:", color="orange")
                st.caption("Run A/B comparison first")
        with col4:
            with st.container(border=True):
                st.markdown(":material/do_not_disturb: **0-39**")
                st.badge("Keep standard", color="red")
                st.caption("Steady, predictable workload")

        st.space("medium")
        with st.container(border=True):
            st.markdown("**:material/bar_chart: Score distribution**")
            bar = (
                alt.Chart(scores_df)
                .mark_bar(cornerRadiusTopLeft=4, cornerRadiusTopRight=4)
                .encode(
                    x=alt.X("WAREHOUSE_NAME:N", title="", sort="-y"),
                    y=alt.Y("ADAPTIVE_SCORE:Q", title="Score"),
                    color=alt.condition(
                        alt.datum.ADAPTIVE_SCORE >= 60,
                        alt.value("#2196F3"),
                        alt.value("#90A4AE"),
                    ),
                    tooltip=[
                        alt.Tooltip("WAREHOUSE_NAME:N", title="Warehouse"),
                        alt.Tooltip("ADAPTIVE_SCORE:Q", title="Score", format=".1f"),
                        alt.Tooltip("WAREHOUSE_TYPE:N", title="Current type"),
                        alt.Tooltip("MULTI_CLUSTER:N", title="Multi-cluster"),
                    ],
                )
                .properties(height=250)
            )
            rule = alt.Chart(scores_df).mark_rule(color="#FF5722", strokeDash=[4, 4]).encode(y=alt.datum(60))
            st.altair_chart(bar + rule)
            st.caption(":material/info: Dashed line = recommended migration threshold (60)")


# ============================================================
# TAB: What-If Simulator (Gen1/Standard vs Adaptive)
# ============================================================
with tab_whatif:
    st.markdown("**:material/compare: What-If Simulator — Gen1 Standard vs Adaptive**")
    st.caption("Model hypothetical scenarios comparing your current Gen1/Standard warehouse costs and performance against projected Adaptive Compute behavior.")
    st.warning("**Disclaimer:** Projections are directional estimates based on observed idle time and queue pressure. "
               "Adaptive Compute uses per-query billing — actual costs depend on query complexity, data volume, and concurrency. "
               "Snowflake does not publish fixed credit-per-query rates. Validate with a parallel A/B test before committing.", icon=":material/info:")

    # Let user pick a warehouse to simulate
    sim_warehouses = [w for w in standard_warehouses if w in VALID_WH_NAMES]
    if not sim_warehouses:
        sim_warehouses = all_warehouses

    col_sim_cfg, col_sim_results = st.columns([1, 2])

    with col_sim_cfg:
        with st.container(border=True):
            st.markdown("**Simulation parameters**")

            sim_wh = st.selectbox(
                "Warehouse to simulate",
                options=sim_warehouses,
                index=0,
                help="Select a Gen1/Standard warehouse to model as Adaptive",
            )

            st.space("small")
            st.markdown("**Current Gen1 configuration**")
            # Pull current config from inventory
            wh_row = warehouses_df[warehouses_df["WAREHOUSE_NAME"] == sim_wh]
            current_size = wh_row["WAREHOUSE_SIZE"].iloc[0] if not wh_row.empty and "WAREHOUSE_SIZE" in wh_row.columns else "Medium"
            current_clusters = wh_row["MAX_CLUSTERS"].iloc[0] if not wh_row.empty and "MAX_CLUSTERS" in wh_row.columns else "1"
            current_suspend = wh_row["AUTO_SUSPEND"].iloc[0] if not wh_row.empty and "AUTO_SUSPEND" in wh_row.columns else "300"

            # Size to credits-per-hour mapping (Gen1)
            SIZE_CREDITS = {
                "X-Small": 1, "Small": 2, "Medium": 4, "Large": 8,
                "X-Large": 16, "2X-Large": 32, "3X-Large": 64, "4X-Large": 128,
                "5X-Large": 256, "6X-Large": 512,
            }
            current_credits_hr = SIZE_CREDITS.get(str(current_size), 4)

            st.markdown(f"""
| Setting | Value |
|---------|-------|
| Size | {current_size} |
| Credits/hour | {current_credits_hr} |
| Max clusters | {current_clusters} |
| Auto-suspend | {current_suspend}s |
""")

            st.space("small")
            st.markdown("**Adaptive parameters**")
            adaptive_perf_level = st.selectbox(
                "MAX_QUERY_PERFORMANCE_LEVEL",
                options=["Small", "Medium", "Large", "X-Large", "2X-Large", "3X-Large", "4X-Large"],
                index=3,
                help="Caps the maximum compute per query. Higher = more expensive individual queries but faster.",
            )
            adaptive_throughput = st.number_input(
                "QUERY_THROUGHPUT_MULTIPLIER",
                min_value=0, max_value=10, value=2,
                help="Concurrency multiplier. 0 = unlimited. Higher = more parallel capacity.",
            )

    with col_sim_results:
        # Compute simulation from actual data
        wh_metering = metering_df[metering_df["WAREHOUSE_NAME"] == sim_wh].copy()
        wh_queries = query_df[query_df["WAREHOUSE_NAME"] == sim_wh].copy()

        if wh_metering.empty:
            st.info(f"No metering data for **{sim_wh}** in the selected time range.", icon=":material/info:")
        else:
            # --- Gen1 actual costs ---
            gen1_total_credits = float(wh_metering["CREDITS"].sum())
            gen1_active_hours = len(wh_metering)
            gen1_total_hours = int(days_back) * 24
            gen1_idle_hours = gen1_total_hours - gen1_active_hours
            gen1_utilization = gen1_active_hours / gen1_total_hours * 100 if gen1_total_hours > 0 else 0

            # Query metrics
            total_queries = int(wh_queries["QUERY_COUNT"].sum()) if not wh_queries.empty else 0
            avg_latency = float(wh_queries["AVG_ELAPSED_MS"].mean()) / 1000 if not wh_queries.empty else 0
            queued = int(wh_queries["QUEUED_QUERIES"].sum()) if not wh_queries.empty else 0

            # --- Adaptive modeled costs ---
            # Methodology: Adaptive eliminates idle credit burn entirely.
            # For active hours, we model a conservative efficiency range based on:
            # - Idle time elimination (guaranteed savings)
            # - Queue time elimination (Adaptive auto-scales)
            # - Per-query billing overhead vs fixed-size billing
            # NOTE: Actual Adaptive costs are per-query and NOT proportional to Gen1 sizes.
            # We use a user-adjustable efficiency factor (not a Snowflake-published number).

            # User-selectable savings model
            SAVINGS_MODEL = {
                "Conservative (15%)": 0.85,
                "Moderate (25%)": 0.75,
                "Optimistic (35%)": 0.65,
                "Aggressive (45%)": 0.55,
            }

            # Idle waste in Gen1
            if not wh_queries.empty:
                merged_sim = wh_metering.merge(
                    wh_queries[["HOUR_TS", "QUERY_COUNT"]], on="HOUR_TS", how="left"
                )
                merged_sim["QUERY_COUNT"] = merged_sim["QUERY_COUNT"].fillna(0)
                # Exclude last 2 hours (ACCOUNT_USAGE latency — data not yet reported)
                merged_sim["_hour_ts_utc"] = pd.to_datetime(merged_sim["HOUR_TS"], utc=True)
                cutoff = pd.Timestamp.now(tz="UTC") - pd.Timedelta(hours=2)
                merged_sim = merged_sim[merged_sim["_hour_ts_utc"] < cutoff]
                merged_sim = merged_sim.drop(columns=["_hour_ts_utc"])
                idle_credits = float(merged_sim[merged_sim["QUERY_COUNT"] == 0]["CREDITS"].sum())
                active_credits = gen1_total_credits - idle_credits
            else:
                idle_credits = gen1_total_credits * 0.3
                active_credits = gen1_total_credits - idle_credits

            # Adaptive model:
            # Guaranteed savings = idle credits (eliminated entirely)
            # Active hour savings = based on user-selected scenario
            # Conservative: only idle savings. Aggressive: idle + efficiency gains.
            idle_savings = idle_credits  # Always saved

            # Multi-cluster overhead
            max_clusters = int(current_clusters) if str(current_clusters).isdigit() else 1
            cluster_overhead = active_credits * 0.10 * (max_clusters - 1) if max_clusters > 1 else 0

            # Total adaptive credits by scenario
            adaptive_by_scenario = {}
            for label, factor in SAVINGS_MODEL.items():
                est = active_credits * factor - cluster_overhead
                adaptive_by_scenario[label] = max(est, 0)

            # Default scenario based on characteristics
            if gen1_utilization < 30:
                default_scenario = "Optimistic (35%)"
            elif gen1_utilization < 60:
                default_scenario = "Moderate (25%)"
            else:
                default_scenario = "Conservative (15%)"

            adaptive_credits = adaptive_by_scenario.get(default_scenario, active_credits * 0.75)

            # Latency: Adaptive eliminates queue time but per-query speed depends on workload
            # We don't model latency changes — only report queue elimination
            adaptive_queue = 0

            # Cost calculations
            detected_price = load_credit_price()
            gen1_cost = gen1_total_credits * detected_price
            adaptive_cost = adaptive_credits * detected_price
            savings = gen1_cost - adaptive_cost
            savings_pct = savings / gen1_cost * 100 if gen1_cost > 0 else 0

            # --- Display results ---
            with st.container(border=True):
                st.markdown("**:material/compare_arrows: Side-by-side comparison**")

                with st.container(horizontal=True):
                    delta_credits = f"{savings_pct:+.1f}%"
                    st.metric("Gen1 credits", f"{gen1_total_credits:,.1f}", border=True)
                    st.metric("Adaptive credits (est.)", f"{adaptive_credits:,.1f}", delta=delta_credits, delta_color="inverse", border=True)
                    st.metric(f"Savings ({days_back}d)", f"${savings:,.0f}", border=True)
                    st.metric("Annual projection", f"${savings * 365 / max(days_back, 1):,.0f}", border=True)

            col_g1, col_a1 = st.columns(2)
            with col_g1:
                with st.container(border=True):
                    st.markdown("**Gen1 Standard** (current)")
                    st.markdown(f"""
| Metric | Value |
|--------|-------|
| Total credits | {gen1_total_credits:,.1f} |
| Total cost | ${gen1_cost:,.2f} |
| Active hours | {gen1_active_hours} |
| Idle hours (wasted) | {gen1_idle_hours} |
| Utilization | {gen1_utilization:.0f}% |
| Avg latency | {avg_latency:.2f}s |
| Queued queries | {queued:,} |
| Queries executed | {total_queries:,} |
| Idle credit waste | {idle_credits:,.1f} |
""")

            with col_a1:
                with st.container(border=True):
                    st.markdown(f"**Adaptive** (projected — {default_scenario})")
                    st.markdown(f"""
| Metric | Value |
|--------|-------|
| Total credits | {adaptive_credits:,.1f} |
| Total cost | ${adaptive_cost:,.2f} |
| Billing model | Pay-per-query |
| Idle hours (wasted) | 0 |
| Utilization | On-demand |
| Avg latency | ~same (workload-dependent) |
| Queued queries | {adaptive_queue} (auto-scales) |
| Queries executed | {total_queries:,} |
| Idle credit waste | 0 |
""")

            # Hourly comparison chart
            with st.container(border=True):
                st.markdown("**:material/timeline: Hourly credit comparison**")
                st.caption("Blue = Gen1 actual credits. Green = Adaptive projected (no idle burn).")

                sim_chart_df = wh_metering[["HOUR_TS", "CREDITS"]].copy()
                sim_chart_df = sim_chart_df.rename(columns={"CREDITS": "Gen1"})

                if not wh_queries.empty:
                    q_hourly = wh_queries[["HOUR_TS", "QUERY_COUNT"]].copy()
                    sim_chart_df = sim_chart_df.merge(q_hourly, on="HOUR_TS", how="left")
                    sim_chart_df["QUERY_COUNT"] = sim_chart_df["QUERY_COUNT"].fillna(0)
                    # Adaptive: zero cost for idle hours, active hours reduced by scenario factor
                    scenario_factor = SAVINGS_MODEL[default_scenario]
                    sim_chart_df["Adaptive"] = sim_chart_df.apply(
                        lambda r: float(r["Gen1"]) * scenario_factor if r["QUERY_COUNT"] > 0 else 0, axis=1
                    )
                else:
                    scenario_factor = SAVINGS_MODEL[default_scenario]
                    sim_chart_df["Adaptive"] = sim_chart_df["Gen1"] * scenario_factor

                chart_melted = sim_chart_df.melt(
                    id_vars=["HOUR_TS"], value_vars=["Gen1", "Adaptive"],
                    var_name="Type", value_name="Credits"
                )

                comparison_chart = (
                    alt.Chart(chart_melted)
                    .mark_area(opacity=0.5, interpolate="monotone")
                    .encode(
                        x=alt.X("HOUR_TS:T", title=""),
                        y=alt.Y("Credits:Q", title="Credits/hour"),
                        color=alt.Color("Type:N", scale=alt.Scale(
                            domain=["Gen1", "Adaptive"],
                            range=["#1976D2", "#43A047"]
                        )),
                        tooltip=[
                            alt.Tooltip("HOUR_TS:T", title="Hour"),
                            alt.Tooltip("Type:N"),
                            alt.Tooltip("Credits:Q", format=".2f"),
                        ],
                    )
                    .properties(height=250)
                )
                st.altair_chart(comparison_chart)

            # Scenario comparison
            with st.container(border=True):
                st.markdown("**:material/tune: Scenario analysis — savings by assumption**")
                st.caption("All scenarios eliminate idle credits. The factor applies to active-hour credits only.")
                sensitivity_data = []
                for label, factor in SAVINGS_MODEL.items():
                    est_credits = active_credits * factor - cluster_overhead
                    est_credits = max(est_credits, 0)
                    total_est = est_credits
                    est_savings_pct = (gen1_total_credits - total_est) / gen1_total_credits * 100 if gen1_total_credits > 0 else 0
                    sensitivity_data.append({
                        "Scenario": label,
                        "Active Credits": round(est_credits, 1),
                        "Total Savings": round(gen1_total_credits - total_est, 1),
                        "Savings %": round(est_savings_pct, 1),
                        "Annual $ Saved": f"${(gen1_total_credits - total_est) * detected_price * 365 / max(days_back, 1):,.0f}",
                    })
                sens_df = pd.DataFrame(sensitivity_data)
                # Mark the selected scenario
                st.dataframe(
                    sens_df,
                    column_config={
                        "Scenario": st.column_config.TextColumn("Scenario"),
                        "Active Credits": st.column_config.NumberColumn("Projected Credits", format="%.1f"),
                        "Total Savings": st.column_config.NumberColumn("Credits Saved", format="%.1f"),
                        "Savings %": st.column_config.ProgressColumn("Savings %", min_value=0, max_value=100, format="%.0f%%"),
                        "Annual $ Saved": st.column_config.TextColumn("Annual Savings"),
                    },
                    hide_index=True,
                )
                st.caption(f"Selected scenario: **{default_scenario}** (auto-selected based on {gen1_utilization:.0f}% utilization)")

            # Key findings
            with st.container(border=True):
                st.markdown("**:material/lightbulb: Key findings**")
                findings = []
                if idle_credits > gen1_total_credits * 0.2:
                    findings.append(f":material/check_circle: **{idle_credits:,.0f} idle credits** ({idle_credits/gen1_total_credits*100:.0f}%) eliminated — Adaptive only charges when queries run")
                if queued > 0:
                    findings.append(f":material/check_circle: **{queued:,} queued queries** eliminated — Adaptive auto-scales concurrency without cluster provisioning delay")
                if max_clusters > 1:
                    findings.append(f":material/check_circle: **Multi-cluster overhead removed** — current {max_clusters}-cluster config replaced by native Adaptive scaling")
                if gen1_utilization < 50:
                    findings.append(f":material/check_circle: **Low utilization ({gen1_utilization:.0f}%)** — strong Adaptive candidate (pay-per-query eliminates over-provisioning)")
                if savings_pct > 20:
                    findings.append(f":material/savings: **Projected {savings_pct:.0f}% cost reduction** — ${savings:,.0f} savings over {days_back} days")
                if queued > 0 and avg_latency > 0:
                    findings.append(f":material/speed: **Queue elimination** — {queued:,} queued queries would no longer wait. Latency for queued workloads will improve.")

                # Unsupported warehouse checks
                unsupported_sizes = {"5X-Large", "6X-Large"}
                if str(current_size) in unsupported_sizes:
                    findings.append(f":material/block: **{current_size} is NOT supported** for Adaptive Compute. Must downsize first.")

                if not findings:
                    findings.append(":material/info: This warehouse has steady, well-utilized workloads — Adaptive savings may be modest.")

                for f in findings:
                    st.markdown(f)

            st.caption("*Projections are estimates based on historical patterns. Actual Adaptive performance depends on query complexity, concurrency, and data volume. Run a parallel A/B test for validation.*")


# ============================================================
# TAB: Governance (Enterprise BFSI Features)
# ============================================================
with tab_govern:
    st.markdown("**:material/shield: Enterprise Governance**")
    st.caption("Audit logging, change management, SLA monitoring, regulatory calendar, cost allocation, and data residency")

    gov_sub = st.pills(
        "Section",
        options=["Audit Log", "Change Management", "SLA Monitor", "Regulatory Calendar", "Cost Allocation", "Data Residency"],
        default="Audit Log",
    )

    # --- Helper: Check if governance tables exist (no cache — always fresh) ---
    def _gov_tables_exist():
        try:
            result = conn.query("""
                SELECT table_name FROM ADAPTIVE_COMPUTE_DB.INFORMATION_SCHEMA.TABLES
                WHERE table_schema = 'ADAPTIVE_METRICS'
                  AND table_name IN ('AUDIT_LOG','MIGRATION_REQUESTS','WORKLOAD_SLA','SLA_BREACHES','REGULATORY_CALENDAR','GL_CODE_MAPPING','REGION_ADAPTIVE_SUPPORT')
            """)
            return set(result["TABLE_NAME"].tolist()) if not result.empty else set()
        except Exception:
            return set()

    gov_tables = _gov_tables_exist()

    def _execute_dml(sql):
        """Execute DML in the Streamlit container runtime.
        The INSERT succeeds but fetch_pandas_all() throws NotSupportedError on the result.
        We catch and suppress that specific error since the DML already committed."""
        try:
            conn.session().sql(sql).collect()
        except Exception as e:
            # If error contains 'NotSupported' or 'Unknown error', the DML likely succeeded
            err_str = str(e).lower()
            if "notsupported" in err_str or "unknown error" in err_str:
                pass  # DML committed before the fetch error
            else:
                raise  # Re-raise genuine errors

    def _send_notification(subject, body, recipients=""):
        """Send HTML email notification via Snowflake SYSTEM$SEND_EMAIL."""
        if not recipients:
            return
        try:
            escaped_subject = subject.replace("'", "''")
            # CXO-grade HTML email
            html_body = f"""
<html>
<body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background-color: #f8f9fa; padding: 40px 0;">
<table width="600" align="center" cellpadding="0" cellspacing="0" style="background: #ffffff; border-radius: 12px; box-shadow: 0 2px 8px rgba(0,0,0,0.08); overflow: hidden;">
  <tr>
    <td style="background: linear-gradient(135deg, #1a73e8 0%, #0d47a1 100%); padding: 32px 40px;">
      <h1 style="color: #ffffff; margin: 0; font-size: 22px; font-weight: 600;">Adaptive Compute Migration Request</h1>
      <p style="color: #bbdefb; margin: 8px 0 0 0; font-size: 14px;">Action Required &mdash; Approval Pending</p>
    </td>
  </tr>
  <tr>
    <td style="padding: 32px 40px;">
      <table width="100%" cellpadding="12" cellspacing="0" style="border: 1px solid #e0e0e0; border-radius: 8px; margin-bottom: 24px;">
        <tr style="background: #f5f7fa;">
          <td style="font-size: 13px; color: #616161; font-weight: 600; width: 160px;">Warehouse</td>
          <td style="font-size: 15px; color: #1a1a1a; font-weight: 700;">{body.split('Warehouse: ')[1].split(chr(10))[0] if 'Warehouse: ' in body else 'N/A'}</td>
        </tr>
        <tr>
          <td style="font-size: 13px; color: #616161; font-weight: 600;">Migration Type</td>
          <td style="font-size: 14px; color: #1a1a1a;">Standard &rarr; <span style="color: #1a73e8; font-weight: 600;">Adaptive Compute</span></td>
        </tr>
        <tr style="background: #f5f7fa;">
          <td style="font-size: 13px; color: #616161; font-weight: 600;">Justification</td>
          <td style="font-size: 14px; color: #1a1a1a;">{body.split('Justification: ')[1].split(chr(10))[0] if 'Justification: ' in body else 'N/A'}</td>
        </tr>
        <tr>
          <td style="font-size: 13px; color: #616161; font-weight: 600;">Est. Annual Savings</td>
          <td style="font-size: 16px; color: #2e7d32; font-weight: 700;">{body.split('savings: ')[1].split(chr(10))[0] if 'savings: ' in body else '$0'}</td>
        </tr>
        <tr style="background: #f5f7fa;">
          <td style="font-size: 13px; color: #616161; font-weight: 600;">Requested By</td>
          <td style="font-size: 14px; color: #1a1a1a;">SNOWFLAKE_INTELLIGENCE_ADMIN</td>
        </tr>
        <tr>
          <td style="font-size: 13px; color: #616161; font-weight: 600;">Status</td>
          <td><span style="background: #fff3e0; color: #e65100; padding: 4px 12px; border-radius: 12px; font-size: 12px; font-weight: 600;">PENDING APPROVAL</span></td>
        </tr>
      </table>
      <p style="font-size: 14px; color: #424242; line-height: 1.6; margin-bottom: 24px;">
        A migration request has been submitted for your review. Adaptive Compute eliminates idle credit waste and dynamically scales to match workload demand &mdash; reducing costs for variable workloads by up to 30%.
      </p>
      <table cellpadding="0" cellspacing="0">
        <tr>
          <td style="background: #1a73e8; border-radius: 6px;">
            <a href="https://app.snowflake.com/cz04821/sd47007/#/streamlit-apps/SNOWFLAKE_INTELLIGENCE.AGENTS.STREAMLIT_APP" style="display: inline-block; padding: 12px 28px; color: #ffffff; text-decoration: none; font-size: 14px; font-weight: 600;">Review in Dashboard</a>
          </td>
        </tr>
      </table>
    </td>
  </tr>
  <tr>
    <td style="background: #f5f7fa; padding: 20px 40px; border-top: 1px solid #e0e0e0;">
      <p style="font-size: 12px; color: #9e9e9e; margin: 0;">
        Snowflake Adaptive Compute Control Plane &bull; Enterprise Governance<br>
        This is an automated notification. Please review and approve/reject in the Governance tab.
      </p>
    </td>
  </tr>
</table>
</body>
</html>
""".replace("'", "''")
            _execute_dml(f"""
                CALL SYSTEM$SEND_EMAIL(
                    'adaptive_compute_notifications',
                    '{recipients}',
                    '{escaped_subject}',
                    '{html_body}',
                    'text/html'
                )
            """)
        except Exception:
            pass  # Notification integration may not be configured

    def _log_audit_event(event_type, event_detail, warehouse_name=None):
        """Write an audit event. Silently skips if table doesn't exist."""
        if "AUDIT_LOG" not in gov_tables:
            return
        try:
            detail_json = str(event_detail).replace("'", "''") if event_detail else "{}"
            wh_val = f"'{warehouse_name}'" if warehouse_name else "NULL"
            _execute_dml(f"""
                INSERT INTO {STAGING_SCHEMA}.AUDIT_LOG (event_type, event_detail, warehouse_name)
                VALUES ('{event_type}', PARSE_JSON('{detail_json}'), {wh_val})
            """)
        except Exception:
            pass

    # ---- SECTION: Audit Log ----
    if gov_sub == "Audit Log":
        st.markdown("**:material/history: Audit Trail**")
        st.caption("All dashboard interactions are logged for SOX/SOC2 compliance. Shows who viewed, simulated, or requested migrations.")

        if "AUDIT_LOG" not in gov_tables:
            st.info("Audit log table not deployed. Run `scripts/optimization/setup_enterprise_governance.sql` to enable.", icon=":material/info:")
        else:
            # Log this view
            _log_audit_event("VIEW", '{"section": "audit_log"}')

            audit_df = conn.query(f"""
                SELECT event_timestamp, username, role_name, event_type, warehouse_name,
                       event_detail:section::VARCHAR AS detail
                FROM {STAGING_SCHEMA}.AUDIT_LOG
                ORDER BY event_timestamp DESC
                LIMIT 100
            """)
            if not audit_df.empty:
                with st.container(horizontal=True):
                    st.metric("Total events", len(audit_df), border=True)
                    st.metric("Unique users", audit_df["USERNAME"].nunique(), border=True)
                    st.metric("Simulations", len(audit_df[audit_df["EVENT_TYPE"] == "SIMULATION"]), border=True)

                st.dataframe(
                    audit_df,
                    column_config={
                        "EVENT_TIMESTAMP": st.column_config.DatetimeColumn("Time", format="MMM D, HH:mm"),
                        "USERNAME": st.column_config.TextColumn("User"),
                        "ROLE_NAME": st.column_config.TextColumn("Role"),
                        "EVENT_TYPE": st.column_config.TextColumn("Event"),
                        "WAREHOUSE_NAME": st.column_config.TextColumn("Warehouse"),
                        "DETAIL": st.column_config.TextColumn("Detail"),
                    },
                    hide_index=True,
                )
            else:
                st.caption("No audit events recorded yet.")

    # ---- SECTION: Change Management ----
    elif gov_sub == "Change Management":
        st.markdown("**:material/approval: Migration Change Management**")
        st.caption("All warehouse migrations must go through approval. Submit requests, track status, and review pending changes.")

        if "MIGRATION_REQUESTS" not in gov_tables:
            st.info("Migration requests table not deployed. Run `scripts/optimization/setup_enterprise_governance.sql` to enable.", icon=":material/info:")
        else:
            col_req, col_status = st.columns([1, 1])

            with col_req:
                with st.container(border=True):
                    st.markdown("**Submit migration request**")
                    req_wh = st.selectbox("Warehouse", options=standard_warehouses, key="req_wh")
                    req_justification = st.text_area("Business justification", placeholder="Describe why this warehouse should be migrated to Adaptive...")
                    req_savings = st.number_input("Estimated annual savings ($)", min_value=0, value=1000, step=100, format="%d")
                    req_approver_email = st.text_input("Approver email", placeholder="user@account.com", help="Must be a verified Snowflake user email in this account")

                    if st.button("Submit request", type="primary", icon=":material/send:"):
                        if req_justification:
                            try:
                                justification_escaped = req_justification.replace(chr(39), chr(39)+chr(39))
                                _execute_dml(f"""
                                    INSERT INTO {STAGING_SCHEMA}.MIGRATION_REQUESTS
                                        (warehouse_name, current_type, target_type, justification, estimated_savings)
                                    VALUES ('{req_wh}', 'STANDARD', 'ADAPTIVE',
                                           '{justification_escaped}',
                                           {req_savings})
                                """)
                            except Exception as e:
                                st.error(f"Failed to submit: {e}")
                                req_justification = None  # prevent success message

                            if req_justification:
                                _log_audit_event("MIGRATION_REQUEST", f'{{"warehouse": "{req_wh}", "savings": {req_savings}}}', req_wh)
                                # Send email notification (non-blocking — failure won't affect the request)
                                if req_approver_email:
                                    _send_notification(
                                        subject=f"[Adaptive Compute] Migration Request: {req_wh}",
                                        body=f"Migration request submitted.\n\nWarehouse: {req_wh}\nJustification: {req_justification}\nEstimated annual savings: ${req_savings:,}\n\nPlease review in the Adaptive Compute dashboard.",
                                        recipients=req_approver_email,
                                    )
                                st.success(f"Request submitted for **{req_wh}**.", icon=":material/check_circle:")
                        else:
                            st.warning("Please provide a business justification.", icon=":material/warning:")

            with col_status:
                with st.container(border=True):
                    st.markdown("**All requests**")
                    requests_df = conn.query(f"""
                        SELECT request_id, created_at, requested_by, warehouse_name, status,
                               estimated_savings, justification, reviewed_by, review_notes
                        FROM {STAGING_SCHEMA}.MIGRATION_REQUESTS
                        ORDER BY created_at DESC
                        LIMIT 30
                    """, ttl=0)
                    if not requests_df.empty:
                        # Color-code status
                        st.dataframe(
                            requests_df,
                            column_config={
                                "REQUEST_ID": st.column_config.TextColumn("ID", width="small"),
                                "CREATED_AT": st.column_config.DatetimeColumn("Submitted", format="MMM D, HH:mm"),
                                "REQUESTED_BY": st.column_config.TextColumn("Requestor"),
                                "WAREHOUSE_NAME": st.column_config.TextColumn("Warehouse"),
                                "STATUS": st.column_config.TextColumn("Status"),
                                "ESTIMATED_SAVINGS": st.column_config.NumberColumn("Savings", format="$%.0f"),
                                "JUSTIFICATION": st.column_config.TextColumn("Justification", width="medium"),
                                "REVIEWED_BY": st.column_config.TextColumn("Reviewer"),
                                "REVIEW_NOTES": st.column_config.TextColumn("Notes"),
                            },
                            hide_index=True,
                        )

                        # Status summary
                        pending = len(requests_df[requests_df["STATUS"] == "PENDING"])
                        approved = len(requests_df[requests_df["STATUS"] == "APPROVED"])
                        executed = len(requests_df[requests_df["STATUS"] == "EXECUTED"])
                        rejected = len(requests_df[requests_df["STATUS"] == "REJECTED"])
                        st.caption(f"Pending: {pending} | Approved: {approved} | Executed: {executed} | Rejected: {rejected}")
                    else:
                        st.caption("No migration requests yet.")

            # --- Request Actions (Approve / Reject / Execute / Close) ---
            st.space("medium")
            with st.container(border=True):
                st.markdown("**:material/checklist: Manage requests**")
                st.caption("Update request status. Only PENDING requests can be approved/rejected. Only APPROVED requests can be executed.")

                if not requests_df.empty:
                    pending_ids = requests_df[requests_df["STATUS"] == "PENDING"]
                    approved_ids = requests_df[requests_df["STATUS"] == "APPROVED"]

                    col_act1, col_act2 = st.columns(2)

                    with col_act1:
                        st.markdown("**Approve / Reject**")
                        if not pending_ids.empty:
                            action_id = st.selectbox(
                                "Select pending request",
                                options=pending_ids["REQUEST_ID"].tolist(),
                                format_func=lambda x: f"{pending_ids[pending_ids['REQUEST_ID']==x]['WAREHOUSE_NAME'].iloc[0]} ({x[:8]}...)",
                                key="action_pending",
                            )
                            review_notes = st.text_input("Review notes", key="review_notes", placeholder="Reviewer comments (required)")
                            col_approve, col_reject = st.columns(2)
                            with col_approve:
                                if st.button("Approve", type="primary", icon=":material/check:", key="btn_approve"):
                                    notes_esc = review_notes.replace(chr(39), chr(39)+chr(39))
                                    _execute_dml(f"""
                                        UPDATE {STAGING_SCHEMA}.MIGRATION_REQUESTS
                                        SET status = 'APPROVED',
                                            reviewed_by = CURRENT_USER(),
                                            reviewed_at = CURRENT_TIMESTAMP(),
                                            review_notes = '{notes_esc}'
                                        WHERE request_id = '{action_id}'
                                    """)
                                    _log_audit_event("APPROVAL", f'{{"request_id": "{action_id}"}}')
                                    st.rerun()
                            with col_reject:
                                if st.button("Reject", type="secondary", icon=":material/close:", key="btn_reject"):
                                    notes_esc = review_notes.replace(chr(39), chr(39)+chr(39))
                                    _execute_dml(f"""
                                        UPDATE {STAGING_SCHEMA}.MIGRATION_REQUESTS
                                        SET status = 'REJECTED',
                                            reviewed_by = CURRENT_USER(),
                                            reviewed_at = CURRENT_TIMESTAMP(),
                                            review_notes = '{notes_esc}'
                                        WHERE request_id = '{action_id}'
                                    """)
                                    _log_audit_event("REJECTION", f'{{"request_id": "{action_id}"}}')
                                    st.rerun()
                        else:
                            st.caption("No pending requests to review.")

                    with col_act2:
                        st.markdown("**Execute / Rollback**")
                        if not approved_ids.empty:
                            exec_id = st.selectbox(
                                "Select approved request",
                                options=approved_ids["REQUEST_ID"].tolist(),
                                format_func=lambda x: f"{approved_ids[approved_ids['REQUEST_ID']==x]['WAREHOUSE_NAME'].iloc[0]} ({x[:8]}...)",
                                key="action_approved",
                            )
                            exec_wh = approved_ids[approved_ids["REQUEST_ID"] == exec_id]["WAREHOUSE_NAME"].iloc[0]
                            if st.button("Mark as Executed", type="primary", icon=":material/rocket_launch:", key="btn_execute"):
                                _execute_dml(f"""
                                    UPDATE {STAGING_SCHEMA}.MIGRATION_REQUESTS
                                    SET status = 'EXECUTED', executed_at = CURRENT_TIMESTAMP()
                                    WHERE request_id = '{exec_id}'
                                """)
                                _log_audit_event("EXECUTED", f'{{"request_id": "{exec_id}", "warehouse": "{exec_wh}"}}', exec_wh)
                                st.toast(f"**{exec_wh}** marked as executed. Run: `ALTER WAREHOUSE {exec_wh} SET WAREHOUSE_TYPE = 'ADAPTIVE';`")
                                st.rerun()
                        else:
                            st.caption("No approved requests to execute.")

                        # Rollback executed requests
                        executed_ids = requests_df[requests_df["STATUS"] == "EXECUTED"]
                        if not executed_ids.empty:
                            st.space("small")
                            rb_id = st.selectbox(
                                "Rollback executed request",
                                options=executed_ids["REQUEST_ID"].tolist(),
                                format_func=lambda x: f"{executed_ids[executed_ids['REQUEST_ID']==x]['WAREHOUSE_NAME'].iloc[0]} ({x[:8]}...)",
                                key="action_rollback",
                            )
                            rb_wh = executed_ids[executed_ids["REQUEST_ID"] == rb_id]["WAREHOUSE_NAME"].iloc[0]
                            if st.button("Mark as Rolled Back", icon=":material/undo:", key="btn_rollback"):
                                _execute_dml(f"""
                                    UPDATE {STAGING_SCHEMA}.MIGRATION_REQUESTS
                                    SET status = 'ROLLED_BACK', rollback_at = CURRENT_TIMESTAMP()
                                    WHERE request_id = '{rb_id}'
                                """)
                                _log_audit_event("ROLLBACK", f'{{"request_id": "{rb_id}", "warehouse": "{rb_wh}"}}', rb_wh)
                                st.toast(f"**{rb_wh}** rolled back. Run: `ALTER WAREHOUSE {rb_wh} SET WAREHOUSE_TYPE = 'STANDARD';`")
                                st.rerun()
                else:
                    st.caption("No requests to manage.")

            # Blackout window check
            st.space("medium")
            with st.container(border=True):
                st.markdown("**:material/block: Blackout windows**")
                if "REGULATORY_CALENDAR" in gov_tables:
                    blackouts = conn.query(f"""
                        SELECT event_name, start_date, end_date, notes
                        FROM {STAGING_SCHEMA}.REGULATORY_CALENDAR
                        WHERE event_type = 'BLACKOUT'
                          AND end_date >= CURRENT_DATE()
                        ORDER BY start_date
                    """)
                    if not blackouts.empty:
                        st.warning("Active/upcoming blackout windows — no migrations allowed:", icon=":material/block:")
                        st.dataframe(blackouts, hide_index=True)
                    else:
                        st.success("No active blackout windows. Migrations can proceed.", icon=":material/check_circle:")
                else:
                    st.caption("Regulatory calendar not deployed.")

    # ---- SECTION: SLA Monitor ----
    elif gov_sub == "SLA Monitor":
        st.markdown("**:material/monitoring: SLA Monitoring**")
        st.caption("Track latency and queue SLAs per workload class. Detects breaches automatically.")

        if "WORKLOAD_SLA" not in gov_tables:
            st.info("SLA tables not deployed. Run `scripts/optimization/setup_enterprise_governance.sql` to enable.", icon=":material/info:")
        else:
            # SLA definitions
            with st.container(border=True):
                st.markdown("**Workload SLA definitions**")
                sla_df = conn.query(f"""
                    SELECT workload_class, warehouse_pattern, max_p95_latency_sec,
                           max_queue_sec, max_error_rate_pct, priority, escalation_contact, is_active
                    FROM {STAGING_SCHEMA}.WORKLOAD_SLA
                    ORDER BY priority, workload_class
                """)
                if not sla_df.empty:
                    st.dataframe(
                        sla_df,
                        column_config={
                            "WORKLOAD_CLASS": st.column_config.TextColumn("Workload Class"),
                            "WAREHOUSE_PATTERN": st.column_config.TextColumn("Pattern"),
                            "MAX_P95_LATENCY_SEC": st.column_config.NumberColumn("P95 SLA (s)", format="%.1f"),
                            "MAX_QUEUE_SEC": st.column_config.NumberColumn("Queue SLA (s)", format="%.1f"),
                            "MAX_ERROR_RATE_PCT": st.column_config.NumberColumn("Error SLA %", format="%.1f"),
                            "PRIORITY": st.column_config.NumberColumn("Priority"),
                            "ESCALATION_CONTACT": st.column_config.TextColumn("Escalation"),
                            "IS_ACTIVE": st.column_config.CheckboxColumn("Active"),
                        },
                        hide_index=True,
                    )

            # SLA breaches
            if "SLA_BREACHES" in gov_tables:
                st.space("medium")
                with st.container(border=True):
                    st.markdown("**:material/error: Recent SLA breaches**")
                    breaches_df = conn.query(f"""
                        SELECT detected_at, warehouse_name, workload_class, breach_type,
                               sla_threshold, actual_value, severity, acknowledged
                        FROM {STAGING_SCHEMA}.SLA_BREACHES
                        WHERE detected_at >= DATEADD('day', -{days_back}, CURRENT_TIMESTAMP())
                        ORDER BY detected_at DESC
                        LIMIT 50
                    """)
                    if not breaches_df.empty:
                        critical = len(breaches_df[breaches_df["SEVERITY"] == "CRITICAL"])
                        high = len(breaches_df[breaches_df["SEVERITY"] == "HIGH"])
                        with st.container(horizontal=True):
                            st.metric("Critical breaches", critical, border=True)
                            st.metric("High breaches", high, border=True)
                            st.metric("Total breaches", len(breaches_df), border=True)
                            st.metric("Unacknowledged", len(breaches_df[breaches_df["ACKNOWLEDGED"] == False]), border=True)

                        st.dataframe(
                            breaches_df,
                            column_config={
                                "DETECTED_AT": st.column_config.DatetimeColumn("Detected", format="MMM D, HH:mm"),
                                "WAREHOUSE_NAME": st.column_config.TextColumn("Warehouse"),
                                "WORKLOAD_CLASS": st.column_config.TextColumn("Workload"),
                                "BREACH_TYPE": st.column_config.TextColumn("Type"),
                                "SLA_THRESHOLD": st.column_config.NumberColumn("SLA", format="%.1f"),
                                "ACTUAL_VALUE": st.column_config.NumberColumn("Actual", format="%.1f"),
                                "SEVERITY": st.column_config.TextColumn("Severity"),
                                "ACKNOWLEDGED": st.column_config.CheckboxColumn("Ack'd"),
                            },
                            hide_index=True,
                        )
                    else:
                        st.success("No SLA breaches detected in the selected period.", icon=":material/check_circle:")

            # Current performance vs SLA
            st.space("medium")
            with st.container(border=True):
                st.markdown("**:material/speed: Current performance vs SLA thresholds**")
                st.caption("Compares actual P95 latency against SLA for each matched workload class.")
                if not query_df.empty and not sla_df.empty:
                    # Simple comparison for warehouses matching SLA patterns
                    perf_summary = query_df.groupby("WAREHOUSE_NAME").agg(
                        P95_MS=("P95_ELAPSED_MS", "mean"),
                        QUEUE_MS=("TOTAL_QUEUE_MS", "mean"),
                    ).reset_index()
                    perf_summary["P95_SEC"] = perf_summary["P95_MS"] / 1000
                    perf_summary["QUEUE_SEC"] = perf_summary["QUEUE_MS"] / 1000

                    st.dataframe(
                        perf_summary[["WAREHOUSE_NAME", "P95_SEC", "QUEUE_SEC"]].head(15),
                        column_config={
                            "WAREHOUSE_NAME": st.column_config.TextColumn("Warehouse"),
                            "P95_SEC": st.column_config.NumberColumn("P95 Latency (s)", format="%.2f"),
                            "QUEUE_SEC": st.column_config.NumberColumn("Avg Queue (s)", format="%.2f"),
                        },
                        hide_index=True,
                    )

    # ---- SECTION: Regulatory Calendar ----
    elif gov_sub == "Regulatory Calendar":
        st.markdown("**:material/calendar_month: Regulatory Calendar**")
        st.caption("Firm-specific reporting windows, blackouts, and regulatory filing dates. Anomaly detection is suppressed during expected high-processing periods.")

        if "REGULATORY_CALENDAR" not in gov_tables:
            st.info("Regulatory calendar not deployed. Run `scripts/optimization/setup_enterprise_governance.sql` to enable.", icon=":material/info:")
        else:
            cal_df = conn.query(f"""
                SELECT event_name, event_type, start_date, end_date,
                       affected_warehouses, expected_spike_factor, suppress_anomaly, notes
                FROM {STAGING_SCHEMA}.REGULATORY_CALENDAR
                ORDER BY start_date
            """)
            if not cal_df.empty:
                # Upcoming events
                with st.container(border=True):
                    st.markdown("**Upcoming & active events**")
                    upcoming = conn.query(f"""
                        SELECT event_name, event_type, start_date, end_date, expected_spike_factor, notes
                        FROM {STAGING_SCHEMA}.REGULATORY_CALENDAR
                        WHERE end_date >= CURRENT_DATE()
                        ORDER BY start_date
                    """)
                    if not upcoming.empty:
                        st.dataframe(
                            upcoming,
                            column_config={
                                "EVENT_NAME": st.column_config.TextColumn("Event"),
                                "EVENT_TYPE": st.column_config.TextColumn("Type"),
                                "START_DATE": st.column_config.DateColumn("Start"),
                                "END_DATE": st.column_config.DateColumn("End"),
                                "EXPECTED_SPIKE_FACTOR": st.column_config.NumberColumn("Spike Factor", format="%.1fx"),
                                "NOTES": st.column_config.TextColumn("Notes", width="large"),
                            },
                            hide_index=True,
                        )

                # Full calendar
                with st.expander("Full regulatory calendar", icon=":material/list:"):
                    st.dataframe(cal_df, hide_index=True)

                # Add new event
                st.space("medium")
                with st.container(border=True):
                    st.markdown("**Add regulatory event**")
                    col_e1, col_e2, col_e3 = st.columns(3)
                    with col_e1:
                        new_event_name = st.text_input("Event name", placeholder="Q4 Regulatory Filing")
                        new_event_type = st.selectbox("Type", ["MONTH_END", "QUARTER_END", "YEAR_END", "REGULATORY_FILING", "AUDIT_WINDOW", "BLACKOUT"])
                    with col_e2:
                        new_start = st.date_input("Start date", key="reg_start")
                        new_end = st.date_input("End date", key="reg_end")
                    with col_e3:
                        new_spike = st.number_input("Expected spike factor", value=2.0, step=0.5, min_value=1.0)
                        new_notes = st.text_input("Notes", placeholder="Optional notes")

                    if st.button("Add event", icon=":material/add:", type="primary"):
                        if new_event_name:
                            try:
                                notes_escaped = new_notes.replace(chr(39), chr(39)+chr(39))
                                _execute_dml(f"""
                                    INSERT INTO {STAGING_SCHEMA}.REGULATORY_CALENDAR
                                        (event_name, event_type, start_date, end_date, affected_warehouses, expected_spike_factor, notes)
                                    VALUES ('{new_event_name}', '{new_event_type}', '{new_start}', '{new_end}', 'ALL', {new_spike}, '{notes_escaped}')
                                """)
                                _log_audit_event("REGULATORY_CALENDAR_ADD", f'{{"event": "{new_event_name}"}}')
                                st.rerun()
                            except Exception as e:
                                st.error(f"Failed: {e}")
                        else:
                            st.warning("Event name is required.")
            else:
                st.caption("No regulatory events configured.")

    # ---- SECTION: Cost Allocation ----
    elif gov_sub == "Cost Allocation":
        st.markdown("**:material/receipt_long: Cost Allocation (GL Codes)**")
        st.caption("Map warehouse costs to General Ledger codes for financial chargeback. Supports shared warehouses with % allocation.")

        if "GL_CODE_MAPPING" not in gov_tables:
            st.info("GL code mapping table not deployed. Run `scripts/optimization/setup_enterprise_governance.sql` to enable.", icon=":material/info:")
        else:
            col_gl1, col_gl2 = st.columns([2, 1])

            with col_gl1:
                with st.container(border=True):
                    st.markdown("**Current GL mappings**")
                    gl_df = conn.query(f"""
                        SELECT warehouse_name, gl_code, cost_center, department, business_line,
                               allocation_pct, effective_from, approved_by
                        FROM {STAGING_SCHEMA}.GL_CODE_MAPPING
                        WHERE effective_to >= CURRENT_DATE()
                        ORDER BY warehouse_name
                    """)
                    if not gl_df.empty:
                        st.dataframe(
                            gl_df,
                            column_config={
                                "WAREHOUSE_NAME": st.column_config.TextColumn("Warehouse"),
                                "GL_CODE": st.column_config.TextColumn("GL Code"),
                                "COST_CENTER": st.column_config.TextColumn("Cost Center"),
                                "DEPARTMENT": st.column_config.TextColumn("Department"),
                                "BUSINESS_LINE": st.column_config.TextColumn("Business Line"),
                                "ALLOCATION_PCT": st.column_config.ProgressColumn("Allocation %", min_value=0, max_value=100, format="%.0f%%"),
                                "EFFECTIVE_FROM": st.column_config.DateColumn("Effective"),
                                "APPROVED_BY": st.column_config.TextColumn("Approved By"),
                            },
                            hide_index=True,
                        )

                        # Chargeback summary
                        st.space("small")
                        st.markdown("**Chargeback by GL code**")
                        totals_df = derive_credit_totals(metering_df)
                        if not totals_df.empty:
                            merged_gl = totals_df.merge(
                                gl_df[["WAREHOUSE_NAME", "GL_CODE", "BUSINESS_LINE", "ALLOCATION_PCT"]],
                                on="WAREHOUSE_NAME", how="left"
                            )
                            merged_gl["GL_CODE"] = merged_gl["GL_CODE"].fillna("UNALLOCATED")
                            merged_gl["BUSINESS_LINE"] = merged_gl["BUSINESS_LINE"].fillna("Unassigned")
                            merged_gl["ALLOCATION_PCT"] = merged_gl["ALLOCATION_PCT"].fillna(100)
                            merged_gl["ALLOCATED_CREDITS"] = merged_gl["TOTAL_CREDITS"] * merged_gl["ALLOCATION_PCT"] / 100
                            detected_price = load_credit_price()
                            merged_gl["ALLOCATED_COST"] = merged_gl["ALLOCATED_CREDITS"] * detected_price

                            gl_summary = merged_gl.groupby(["GL_CODE", "BUSINESS_LINE"]).agg(
                                {"ALLOCATED_CREDITS": "sum", "ALLOCATED_COST": "sum"}
                            ).reset_index().sort_values("ALLOCATED_COST", ascending=False)

                            st.dataframe(
                                gl_summary,
                                column_config={
                                    "GL_CODE": st.column_config.TextColumn("GL Code"),
                                    "BUSINESS_LINE": st.column_config.TextColumn("Business Line"),
                                    "ALLOCATED_CREDITS": st.column_config.NumberColumn("Credits", format="%.1f"),
                                    "ALLOCATED_COST": st.column_config.NumberColumn("Cost ($)", format="$%.2f"),
                                },
                                hide_index=True,
                            )
                    else:
                        st.caption("No GL mappings configured. Add mappings below.")

            with col_gl2:
                with st.container(border=True):
                    st.markdown("**Add GL mapping**")
                    gl_wh = st.selectbox("Warehouse", options=all_warehouses, key="gl_wh")
                    gl_code = st.text_input("GL Code", placeholder="4100-2300")
                    gl_cc = st.text_input("Cost Center", placeholder="CC-1234")
                    gl_dept = st.text_input("Department", placeholder="Technology")
                    gl_biz = st.text_input("Business Line", placeholder="Investment Banking")
                    gl_pct = st.number_input("Allocation %", value=100, min_value=1, max_value=100)

                    if st.button("Add mapping", icon=":material/add:", type="primary", key="add_gl"):
                        if gl_code:
                            try:
                                _execute_dml(f"""
                                    INSERT INTO {STAGING_SCHEMA}.GL_CODE_MAPPING
                                        (warehouse_name, gl_code, cost_center, department, business_line, allocation_pct)
                                    VALUES ('{gl_wh}', '{gl_code}', '{gl_cc}', '{gl_dept}', '{gl_biz}', {gl_pct})
                                """)
                                _log_audit_event("GL_MAPPING_ADD", f'{{"warehouse": "{gl_wh}", "gl_code": "{gl_code}"}}', gl_wh)
                                st.rerun()
                            except Exception as e:
                                st.error(f"Failed: {e}")
                        else:
                            st.warning("GL Code is required.")

    # ---- SECTION: Data Residency ----
    elif gov_sub == "Data Residency":
        st.markdown("**:material/public: Data Residency & Region Validation**")
        st.caption("Validates that Adaptive Compute is available in your account's cloud region before recommending migration.")

        # Detect current account region
        try:
            region_df = conn.query("SELECT CURRENT_REGION() AS region, CURRENT_ACCOUNT_NAME() AS account")
            current_region = region_df.iloc[0]["REGION"] if not region_df.empty else "UNKNOWN"
            current_account = region_df.iloc[0]["ACCOUNT"] if not region_df.empty else "UNKNOWN"
        except Exception:
            current_region = "UNKNOWN"
            current_account = "UNKNOWN"

        # Parse cloud/region from Snowflake region string (e.g., "AWS_US_WEST_2")
        region_parts = current_region.split("_", 1) if current_region != "UNKNOWN" else ["UNKNOWN", ""]
        detected_cloud = region_parts[0] if region_parts else "UNKNOWN"
        detected_region_raw = "_".join(region_parts[1:]).lower().replace("_", "-") if len(region_parts) > 1 else ""

        with st.container(border=True):
            st.markdown("**Your account**")
            col_r1, col_r2, col_r3 = st.columns(3)
            with col_r1:
                st.metric("Account", current_account, border=True)
            with col_r2:
                st.metric("Region", current_region, border=True)
            with col_r3:
                st.metric("Cloud", detected_cloud, border=True)

        if "REGION_ADAPTIVE_SUPPORT" in gov_tables:
            with st.container(border=True):
                st.markdown("**Adaptive Compute availability**")
                support_df = conn.query(f"""
                    SELECT cloud_provider, region, region_display, adaptive_ga, adaptive_preview
                    FROM {STAGING_SCHEMA}.REGION_ADAPTIVE_SUPPORT
                    ORDER BY cloud_provider, region
                """)
                if not support_df.empty:
                    # Check if current region is supported
                    matching = support_df[
                        (support_df["CLOUD_PROVIDER"] == detected_cloud) &
                        (support_df["REGION"].apply(lambda r: r.replace("-", "") in detected_region_raw.replace("-", "") or detected_region_raw.replace("-", "") in r.replace("-", "")))
                    ]
                    if not matching.empty and matching.iloc[0]["ADAPTIVE_GA"]:
                        st.success(f"**Adaptive Compute is GA** in your region ({current_region}). Migration is fully supported.", icon=":material/check_circle:")
                    elif not matching.empty and matching.iloc[0]["ADAPTIVE_PREVIEW"]:
                        st.warning(f"**Adaptive Compute is in Preview** in your region ({current_region}). Contact your Snowflake account team for access.", icon=":material/science:")
                    else:
                        st.error(f"**Adaptive Compute may not be available** in your region ({current_region}). Verify with your Snowflake account team before planning migration.", icon=":material/block:")

                    # Full support matrix
                    st.space("small")
                    st.markdown("**Full region support matrix**")
                    st.dataframe(
                        support_df,
                        column_config={
                            "CLOUD_PROVIDER": st.column_config.TextColumn("Cloud"),
                            "REGION": st.column_config.TextColumn("Region"),
                            "REGION_DISPLAY": st.column_config.TextColumn("Display Name"),
                            "ADAPTIVE_GA": st.column_config.CheckboxColumn("GA"),
                            "ADAPTIVE_PREVIEW": st.column_config.CheckboxColumn("Preview"),
                        },
                        hide_index=True,
                    )
                else:
                    st.caption("Region support data not populated.")
        else:
            # Fallback without table — use hardcoded known regions
            st.info("Region support table not deployed. Showing hardcoded region list.", icon=":material/info:")
            supported_regions = {
                "AWS": ["us-west-2", "us-east-2", "eu-west-1", "eu-central-1", "ap-northeast-1", "ap-southeast-2"],
                "AZURE": ["centralus", "eastus2", "westeurope", "northeurope", "uksouth", "switzerlandnorth", "swedencentral"],
                "GCP": ["us-east4", "europe-west2", "europe-west3", "europe-west4", "australia-southeast2"],
            }
            with st.container(border=True):
                for cloud, regions in supported_regions.items():
                    st.markdown(f"**{cloud}:** {', '.join(regions)}")


# ============================================================
# TAB: Migrate
# ============================================================
with tab_migrate:
    st.markdown("**:material/swap_horiz: Warehouse migration**")
    st.caption("Convert standard warehouses to Adaptive Compute with zero downtime")

    col1, col2 = st.columns([2, 1])
    with col1:
        with st.container(border=True):
            st.markdown("**:material/inventory: Current fleet**")
            if not warehouses_df.empty:
                display_cols = ["WAREHOUSE_NAME", "WAREHOUSE_TYPE", "STATE", "WAREHOUSE_SIZE"]
                if "MAX_CLUSTERS" in warehouses_df.columns:
                    display_cols.append("MAX_CLUSTERS")
                if "AUTO_SUSPEND" in warehouses_df.columns:
                    display_cols.append("AUTO_SUSPEND")
                if "RESOURCE_MONITOR" in warehouses_df.columns:
                    display_cols.append("RESOURCE_MONITOR")
                display_cols += [c for c in ["GENERATION", "MAX_QUERY_PERF_LEVEL", "THROUGHPUT_MULTIPLIER"] if c in warehouses_df.columns]

                fleet_df = warehouses_df[[c for c in display_cols if c in warehouses_df.columns]]
                st.dataframe(fleet_df, hide_index=True)

    with col2:
        with st.container(border=True):
            st.markdown("**:material/terminal: Quick commands**")
            st.code("-- Convert existing warehouse\nALTER WAREHOUSE <name>\n  SET WAREHOUSE_TYPE = 'ADAPTIVE';", language="sql")
            st.code("-- Rollback to standard\nALTER WAREHOUSE <name>\n  SET WAREHOUSE_TYPE = 'STANDARD';", language="sql")
            st.code("-- Create new adaptive warehouse\nCREATE ADAPTIVE WAREHOUSE <name>\n  WITH MAX_QUERY_PERFORMANCE_LEVEL = XLARGE\n       QUERY_THROUGHPUT_MULTIPLIER = 2;", language="sql")

        with st.container(border=True):
            st.markdown("**:material/tune: Parameters**")
            st.markdown("""
| Parameter | Default |
|-----------|---------|
| `MAX_QUERY_PERFORMANCE_LEVEL` | XLARGE |
| `QUERY_THROUGHPUT_MULTIPLIER` | 2 |
""")

    # Governance & guardrails
    st.space("medium")
    with st.container(border=True):
        st.markdown("**:material/shield: Governance & guardrails**")
        if not warehouses_df.empty:
            col_g1, col_g2, col_g3 = st.columns(3)
            with col_g1:
                has_monitor = warehouses_df[warehouses_df.get("RESOURCE_MONITOR", pd.Series(dtype=str)).astype(str).str.strip() != ""].shape[0] if "RESOURCE_MONITOR" in warehouses_df.columns else 0
                st.metric("With resource monitor", has_monitor)
            with col_g2:
                tuned = warehouses_df[warehouses_df["MAX_QUERY_PERF_LEVEL"].astype(str).str.strip() != ""].shape[0] if "MAX_QUERY_PERF_LEVEL" in warehouses_df.columns else 0
                st.metric("Perf level tuned", tuned)
            with col_g3:
                st.metric("Multi-cluster (standard)", len(multi_cluster_warehouses))

            st.caption("""
**Recommendations:** Attach resource monitors to all production warehouses. Set `MAX_QUERY_PERFORMANCE_LEVEL` to cap per-query resources. Use `QUERY_THROUGHPUT_MULTIPLIER` to balance cost vs concurrency. Apply `COST_CENTER` tags for chargeback.
""")

    st.space("medium")
    with st.container(border=True):
        st.markdown("**:material/checklist: Migration checklist**")
        col_a, col_b = st.columns(2)
        with col_a:
            st.markdown("""
- :material/check_circle: Enterprise Edition or higher
- :material/check_circle: Warehouse in supported region
- :material/check_circle: Assessment score >= 60
- :material/check_circle: 7+ days baseline captured
""")
        with col_b:
            st.markdown("""
- :material/check_circle: Stakeholders notified
- :material/check_circle: Monitoring alerts configured
- :material/check_circle: Rollback plan documented
- :material/check_circle: Not X5Large/X6Large/Snowpark-opt
""")

    with st.expander("Bulk migration with SYSTEM$BULK_UPDATE_WH", icon=":material/dynamic_feed:"):
        st.code("""-- Dry run: see what would be migrated (4 params: property, value, filter, mode)
SELECT SYSTEM$BULK_UPDATE_WH(
  'WAREHOUSE_TYPE',
  'ADAPTIVE',
  '{"WAREHOUSE_TYPE": "STANDARD"}',
  'DRY_RUN'
);

-- Execute migration
SELECT SYSTEM$BULK_UPDATE_WH(
  'WAREHOUSE_TYPE',
  'ADAPTIVE',
  '{"WAREHOUSE_TYPE": "STANDARD"}',
  'ACTIVE'
);

-- With tag filter (5 params: property, value, property_filter, tag_filter, mode)
SELECT SYSTEM$BULK_UPDATE_WH(
  'WAREHOUSE_TYPE',
  'ADAPTIVE',
  '{"WAREHOUSE_TYPE": "STANDARD"}',
  '{"cost-centre": "sales"}',
  'DRY_RUN'
);""", language="sql")
