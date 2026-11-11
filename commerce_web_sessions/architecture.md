# Architecture — Entities, OBT, Grains

## Conceptual model

```
                  amplitude_session  (FanApp session entity)
                          │
                          │ 1:N — one amp session can have many clicks
                          ▼
                     fan_click  (atomic — ONE click from FanApp → commerce)
                          │
                          │ N:1 — many clicks land in one commerce subsession
                          ▼
              commerce subsession  (one shopping "trip" — a slice of a
                                     visitor's site-day, bounded by
                                     completed checkouts)
```

A subsession is the visitor's shopping arc within (`visitor_id`, `dt`, `site_id`), sliced at each completed checkout (THKU+order). The THKU+order page stays in the subsession it closes; the next page starts a new one. This matches the commerce team's `daily_visitor_activity_leading_indicators` grain.

## Models

| Model | Grain | Purpose |
|---|---|---|
| `amplitude_sessions` | `(amplitude_id_final, session_id)` | Amp session aggregates. |
| `amplitude_session_fraud_flags` | `(amplitude_id_final, session_id)` | Sparse — flagged sessions only. |
| `commerce_web_page_views` | `request_correlation_id` | Page-view enrichment of `fanapp_filtered_view_page`: per-page event flags + the `visitor_subsession_index` window + `pk_subsession` surrogate. Single source of truth for subsession boundaries. |
| `commerce_web_session_visitor_day` | `(visitor_id, dt, site_id, visitor_subsession_index)` | Subsession-grain rollup. The `pk` column is `MD5(visitor_id, dt, site_id, visitor_subsession_index)`. Matches commerce team's reference exactly. |
| `fan_clicks` | `fan_click_id` | One row per amp-sourced click. Carries `pk_subsession` (FK), commerce_session_ids (debug ARRAY), first-touch columns, `last_touch_order_ref_nums`. |
| `fanapp_commerce_journey` (OBT) | `fan_click_id` | INNER JOIN of `fan_clicks` + `amplitude_sessions` + `commerce_web_session_visitor_day`. Each row = one click that reached commerce. |

## Grain rationale

**Subsession grain on the commerce side** rather than `session_id` grain: commerce cookies persist for months, so `session_id` doesn't represent a shopping trip. Subsessioning slices at completed checkouts, which is what the commerce team does. This also resolves the "PDP in session ABC, ATC in session DEF" cross-cookie issue that under-counted has_pdp_to_cart_activity by ~1.3-1.8% on site 515621 under session grain.

**`fan_click_id` grain on the OBT** rather than subsession grain: each fan_click is a distinct user action. Multiple clicks can land in one subsession; we want per-click attribution flexibility on the OBT.

**Why a separate `commerce_web_page_views` model**: both `commerce_web_session_visitor_day` (aggregator) and `fan_clicks` (forward-fill attribution) need the `visitor_subsession_index` window. Centralizing it in one model removes drift risk.

## Source dependencies

- `amplitude_events_correction` — upstream identity-stitched amp events
- `fanapp_filtered_view_page` — commerce webview page-views. This PR added `cart_summary`, `product_ids_cart_flattened`, `page_num` columns and cleaned up the type casts.
- `site_id_tenant_map` — for `grouped_nm` / `site_nm` decoration

## Materialization

All models are `materialized: table`. `commerce_web_page_views` is the biggest (404M rows on the current window) and is read by two downstreams, so table-materialization beats view here.
