# Findings

Facts gathered during discovery. Cite sources (URL, repo path, Confluence ID, Snowflake
query). Keep speculation out — that goes in `decisions.md` as an open question.

## dbt Labs "Lake Compute" (the product)

### Confirmed from dbt Summit (verbal, source: team attendance)
- **Cost target:** dbt Labs stated they are aiming for Lake Compute to cost **~50% of
  equivalent Snowflake compute**. (Verbal/aspirational — a vendor target, not a
  contract; our benchmark must verify it against *our* workloads.)
- **Access:** FBG Data **can be added to the private preview** of this feature.
  → Implies the product is **private preview**, not GA. Maturity/SLA risk is real and
  should frame the RFC as "evaluate in preview," not "adopt."

### Confirmed from official docs + announcement (research 2026-10-21, sourced below)

- **What it is:** a **hosted, serverless, single-node SQL engine built on DuckDB** that
  runs dbt models directly against **Apache Iceberg** tables in object storage — reads
  Iceberg, writes Iceberg, **no pushdown to Snowflake/Databricks**. Positioned as a
  **per-model "sidecar"**: tag some models `type: lakecompute`, rest stay on the
  warehouse, all in **one dbt project / one DAG / one `ref` graph**.
- **Built by dbt Labs + Fivetran (merged).** In beta it is **tightly coupled to
  Fivetran Managed Data Lake Storage (MDLS / Polaris catalog)**.
- **Maturity:** **Private beta** as of Oct 2026 (announced dbt Summit 2026, Sep 15–18).
  Breaking changes likely, no SLA, access via signup form. dbt says **not
  production-ready**. → RFC must be "evaluate in beta," not "adopt."
- **Pricing:** **Free during private beta**; no public GA numbers. The **~50%-of-
  Snowflake-compute target is NOT publicly corroborated** — treat as vendor-stated
  (verbal, Summit) only. dbt frames it as "priced for transformation and nothing else."
- **Iceberg catalog support (beta):** **Fivetran MDLS (Polaris) = primary**; **Snowflake
  Horizon = sidecar read/write**; **Databricks Unity = limited design-partner**.
  **AWS Glue / Nessie / Hive NOT listed as supported.** AWS-only (`us-east-1`,
  `us-west-2`), no GCP/Azure, no BigQuery.
- **SQL dialect:** **DuckDB, no automatic translation from Snowflake SQL.** Snowflake
  UDFs and warehouse AI/ML functions unavailable (DuckDB built-ins only).
- **Feature-parity gaps:** no `view` materialization, **no grants/RBAC**, no
  `persist_docs`, **no pre/post hooks**, no unit tests. **Incremental = `append` /
  `insert_overwrite` ONLY — no merge/upsert.** Large two-sided & cross-engine joins are
  explicit non-goals.
- **Integration:** requires **dbt v2** behind experimental flag
  `DBT_ENGINE_EXPERIMENTAL_MULTI_ADAPTER=true`; works with dbt Core **and** Cloud; Mesh/
  lineage preserved across mixed adapters.
- **Non-goals (dbt's own words):** not a warehouse replacement, not a general query
  engine, no BI/JDBC-ODBC connectivity, not multi-node/distributed, no RBAC on Iceberg.
- **Biggest external critique:** single-node DuckDB → **open question whether it scales
  to large datasets** ("a big big big open question" — DataOps analyst). Practitioner
  advice: pilot on non-critical/small-mid models, keep off near-term roadmap until GA.

### Sources
- https://docs.getdbt.com/docs/lake-compute — official docs (engine, status, catalogs,
  supported/unsupported features, non-goals, AWS regions)
- https://docs.getdbt.com/docs/lake-compute/compute-faq — FAQ (free-in-beta, DuckDB
  dialect, catalog list, dbt v2 flag)
- https://www.getdbt.com/blog/dbt-summit-2026-product-announcements — announcement
- https://cheesecakelabs.com/blog/dbt-summit-2026-recap/ — practitioner recap
- https://dataopsleadership.substack.com/p/fivetrans-lakecompute-presents-a — analyst
  take (Snowflake disintermediation + single-node scaling skepticism)

## Our current footprint (repo inventory 2026-10-21)

### Iceberg on S3 today
- **11 Iceberg tables in prod, all Commerce domain, managed via Airflow — NOT dbt.**
  Created in `fes-airflow/dags/create_tables/sql/commerce/*_iceberg.sql`.
- **Catalog = AWS Glue** (`ECOMM_ANALYTICS_GLUE_CRM_ICEBERG_DB_PROD` + external volumes
  on S3). ⚠️ **This is the catalog Lake Compute's beta does NOT list as supported** —
  beta wants Fivetran MDLS/Polaris or Snowflake Horizon. **Key gap.**
- Examples: `adobe_clicks/opens_iceberg`, `ses_clicks/opens_iceberg` (CRM email),
  `*_fankey/fanid_pii_iceberg` (identity), `fanapp_daily_products_iceberg`,
  `weekly_trading_iceberg`, `order_payment_iceberg`.
- Fanflow Iceberg zone exists on S3
  (`fanatics-prod-internal-confidential/fanflow/data/iceberg/…`), read via external
  tables. No standalone Iceberg-native source lake otherwise — canonical S3 is
  Parquet/CSV stages read as **external tables**, not managed Iceberg.

### External tables on S3 (the broader "lake read" surface)
- Commerce: 9 `_ext` tables; Loyalty: 12+ `_ext` (entry/journal/balance/etc. in
  `dbt-fes-ae/models/sources/loyalty.yml`); CDE: `LOYALTY_ACCOUNT_EXT` + V_RAW mappers.
- Pattern: S3 → Snowflake external table → dbt `SOURCE` views. (Our recent work has been
  moving several of these to native deduped incrementals — e.g. loyalty/identity CDC.)

### dbt transform layer shape
- **Canonical project = `dbt-fes-ae`, ~1,022 SQL models**, ~25 domain folders, dbt Mesh
  (`analytics_engineering` group, models `public`). Medallion = SOURCE / PROCESSED(STAGE)
  / CONSUMPTION / REPORTING (+ CORTEX for ML features).
- **Warehouse tiers:** default FDE_MWAA_WH; MD for observability/Impact; **XL** for
  Salesforce/Meta/Xtremepush; **3XL (FDE_DEVELOPER_3XL_WH) for fanflow silver events** —
  the high-volume event transform. Fangraph ID/LTV also heavy (identity joins,
  full-refresh).
- ⚠️ **Tension:** the heaviest-cost models (fanflow silver 3XL, fangraph identity joins,
  big two-sided joins) are exactly where a **single-node DuckDB** engine is riskiest and
  where dbt lists large/cross joins as **non-goals**. The cost-saving sweet spot and the
  technical ceiling point in opposite directions.

### Candidate workloads for Lake Compute (first cut)
- **Best fit:** small/mid, append-style models that are already (or easily) Iceberg —
  e.g. CRM email-engagement Iceberg tables (adobe/ses clicks/opens); simple
  staging/consumption transforms with no merge, no Snowflake UDFs, no grants dependency.
- **Poor fit (for now):** fanflow silver (3XL, volume), fangraph identity joins (large
  joins), anything using **merge/upsert incremental**, Snowflake UDFs, secure views /
  RBAC-sensitive PII, or outputs consumed by BI/shares needing Snowflake RBAC.

### Access / account constraints
- Team operates **FES (vyb11067) + FBG (NODXDTL) Snowflake only**; Commerce etc. are
  external providers. Snowflake connection available locally: `FAN_DATA_EXCHANGE_PROD`
  (role FES_DATA_DEVELOPER). → **Snowflake Horizon** (our own account) is the realistic
  catalog bridge for a beta eval, vs. standing up Fivetran MDLS.

### Snowflake transform spend (cost baseline)
_TODO — run `snowflake.account_usage.query_history` / `warehouse_metering_history` to
quantify dbt transform credits by warehouse (esp. 3XL/XL) over ~30-90d. This is the
RFC's motivation evidence. Connection is configured; pending go-ahead to query._

## Prior art / comparables
- We already run Iceberg-on-Glue in Commerce (via Airflow), and have external-table lake
  reads throughout — so Iceberg itself is not new to us; the **new** things are
  dbt-driven compute on Iceberg and the Polaris/Horizon catalog requirement.
