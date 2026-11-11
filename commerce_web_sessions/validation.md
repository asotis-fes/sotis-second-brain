# Validation — Matching Commerce Team's Reference

## Reference model

`exp_prod.daily_visitor_activity_leading_indicators` — owned by the commerce team. Grain: `(dt, site_id, visitor_id, visitor_subsession_index)`. Their `has_cart_activity` is the canonical FanApp cross-team metric.

Their definition:
```sql
has_atc          = array_contains(event_list_arr, '2')
has_nonempty_cart = page_type = 'CART' AND cardinality(...cart_summary.final_cart_content product_ids...) > 0
has_cart_activity = has_atc OR has_nonempty_cart
```

Their filter: `page_num < 1000 OR (page_type = 'THKU' AND order_ref_num IS NOT NULL)` (bot exclusion).

## The journey to exact match

### Starting state (session_id grain commerce_web_sessions, with THKU constraint, no page_num filter, ATC-only cart)

Numbers were WAY off — site 515620 was at 33% of source-level visitors, 43% of orders.

### Fix 1 — drop THKU constraint
Orders went from `had_thku_page AND non-null order_ref_num` → just `non-null order_ref_num`. Orders aligned exactly.

### Fix 2 — re-grain to visitor-day (then to subsession)
First pass: `commerce_web_session_visitor_day` at `(commerce_session_id, visitor_id, dt)`. Cart went from 33% to ~108% (still over-counting because cart logic wasn't fixed yet). Final pass: `(visitor_id, dt, site_id, visitor_subsession_index)` — matches commerce team's grain exactly. Subsession_index slices at completed checkouts so each shopping trip is a clean row.

### Fix 3 — broaden cart_activity beyond ATC event
Added `has_nonempty_cart_view` signal. Combined `has_cart_activity = did_add_to_cart OR has_nonempty_cart_view`. Got to within +2-7% of commerce team.

### Fix 4 — page_num filter
Excluded bot/scraper rows. Closed ~half of the remaining gap on site 515620; no effect on 515621 (no bot traffic there).

### Fix 5 — switch product_ids_cart_flattened to cart_summary:final_cart_content
**This was the final fix.** The two columns aren't subsets of each other (per the side-by-side profile). Commerce team uses cart_summary. Using cart_summary brought site 515621 to **exact match** and site 515620 to within ~1%.

### Combined: cart_summary + page_num filter + subsession grain = EXACT MATCH

Final numbers verified 2026-06-19 on `feature/commerce_web_sessions` branch, in dev. All eight validated columns (`has_cart_activity`, `visitors_that_ordered`, `hp_viewed`, `grid_viewed`, `pdp_viewed`, `product_page_viewed`, `has_pdp_to_cart_activity`, `has_product_page_to_cart_activity`) match commerce team's CSV cell-for-cell across the 6/1-6/3 × 515620+515621 grid. See `commerce_team_references/sqllab_untitled_query_6_*.csv` for the anchors.

## The actionable lessons

1. **Don't trust column-name similarity.** `product_ids_cart_flattened` and `cart_summary.final_cart_content` SOUND equivalent but aren't. 441 visitors had one but not the other and 306 had the other but not the first — neither is a subset.

2. **Asymmetric site behavior is informative.** Site 515620 was hit by every gap (bot traffic, long-lived sessions, THKU under-reporting); site 515621 was only hit by some. The per-site delta pattern pointed us at the right fixes one at a time.

3. **The `page_num < 1000` filter is canonical.** Commerce team's reference uses it; should be a default in any FanApp commerce model. The OR-clause preserves THKU+order rows so no purchases are dropped.

4. **session_start_ts is the wrong date for date-based reporting** when sessions persist across days. Use the source partition `dt`.

5. **Verify against a reference, not just self-consistency.** The session_id-grain model passed all our internal sanity checks but was off by 77% from the commerce team. Cross-validation surfaced the cookie-persistence issue.

## Validation procedure

The full cross-validation query lives at `commerce_team_references/validation_query_cross_commerce_sessions_and_daily_visitor_activity_leading_indicators.sql` — two queries (ours and theirs) with matching column shape. Run both and diff cell-for-cell. Any drift is a regression.
