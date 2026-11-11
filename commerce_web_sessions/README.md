# Commerce Web Sessions — Project Context

Multi-week design and build of a data model on top of FanApp commerce webview page-view data. Goal: support funnel reporting at subsession grain (matching commerce team's reference) plus fan_click attribution for FanApp → Commerce journey analysis.

## Repo and branch

Model code lives in **`fes-airflow`** at `feature/commerce_web_sessions`. This brock-bot folder is engineering context — not stakeholder docs.

```
~/repos/fes-airflow/dags/dbt/models/
├── commerce/orders/
│   ├── commerce_web_page_views.sql              # page-view grain + visitor_subsession_index window
│   ├── commerce_web_session_visitor_day.sql     # subsession-grain rollup; matches commerce team
│   ├── fanapp_filtered_view_page.sql            # upstream — cart_summary, page_num passthrough
│   └── orders.yaml
├── fanapp/sessions/
│   ├── amplitude_sessions.sql
│   ├── amplitude_session_fraud_flags.sql
│   ├── fan_clicks.sql                           # fan_click_id grain; first- and last-touch attribution
│   └── _sessions.yaml
├── fanapp/reporting/
│   └── fanapp_commerce_journey.sql              # OBT at fan_click_id grain
└── fanapp/fanapp.yaml
```

## Status (as of 2026-06-19)

Subsession-grain refactor complete. All numbers validated against commerce team's `exp_prod.daily_visitor_activity_leading_indicators` reference table (eight columns × six cells). `commerce_web_sessions` deleted.

## Documents in this folder

- [architecture.md](architecture.md) — entity design, grains, OBT structure
- [data_quality.md](data_quality.md) — known issues with magnitudes and defensive SQL
- [attribution.md](attribution.md) — first-touch / last-touch semantics
- [validation.md](validation.md) — comparison to commerce team's reference
- [commerce_team_references/_index.md](commerce_team_references/_index.md) — summary of source reference files

## Quick run commands

```bash
# Build the full chain (order matters)
dbt run --select commerce_web_page_views commerce_web_session_visitor_day \
                 amplitude_session_fraud_flags amplitude_sessions \
                 fan_clicks fanapp_commerce_journey \
        --defer --state dags/dbt/state/
```

## Cross-validation

Run the two queries in `commerce_team_references/validation_query_cross_commerce_sessions_and_daily_visitor_activity_leading_indicators.sql` (one against our model, one against commerce team's reference). Output columns are shape-identical so diffs are eyeballable.
