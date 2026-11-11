# Commerce Team Reference Files — Index

Source files dropped here by the commerce team. Used to align our `commerce_web_session_visitor_day` model with their `exp_prod.daily_visitor_activity_leading_indicators` reference table.

## Files

### `daily_visitor_activity_leading_indicators.sql` ⭐ **PRIMARY**
The commerce team's dbt model that produces their visitor-day reference table. ~900 lines of Spark SQL. Grain: `(dt, site_id, visitor_id, visitor_subsession_index)`. Source: `filtered_page_view_ice`.

**Key derivations for our task** (lines below reference this file):
- **`pages_grouped`** (lines 314–340): chronological string of single-letter page-type codes (`H`=HP, `G`=grid, `P`=PDP, `F`=FPP, `1`=CART, `S`=search, etc.), with a `T` suffix when `is_typeahead` and an `A` suffix when `has_atc OR has_nonempty_cart`. Built via `array_join(transform(array_sort(COLLECT_LIST(struct(timestamp_est, …)))))`.
- **`has_pdp_to_cart_activity`** (line 869): `pages_grouped RLIKE 'P.*A'` — TRUE iff a PDP page-view occurs at or before any cart-activity page (`PA` matches because `.*` allows zero chars between P and A, covering the case where ATC happens on the PDP itself).
- **`has_product_page_to_cart_activity`** (line 868): `pages_grouped RLIKE '(P|F).*A'` — same semantic but PDP OR FPP.
- **`has_cart_activity`** (line 855): `pages_grouped RLIKE 'A'` — already matched by our model.
- **Page-type flags** (lines 163–172): `is_pdp = page_type = 'PDP'`, `is_fpp = page_type = 'FPP'`, `is_product_page = page_type IN ('PDP','FPP')`, `has_atc = array_contains(event_list_arr, '2')`, `has_nonempty_cart = page_type = 'CART' AND non-empty final_cart_content`.
- **Bot filter** (line 216): `page_num < 1000 OR (page_type = 'THKU' AND order_ref_num IS NOT NULL)` — identical to ours.

Note: lines 271 / 856-862 use a *different* cart-activity definition (`min(case when has_atc then ts)`) — ATC-only, not ATC+nonempty-cart — for the timestamp-based `has_filter_to_cart_activity` family. The regex-based `has_*_to_cart_activity` columns use the more inclusive ATC+nonempty-cart definition. We follow the inclusive definition since `has_cart_activity` already uses it in our model.

### `validation_query_cross_commerce_sessions_and_daily_visitor_activity_leading_indicators.sql`
Aggregation query the commerce team ran against their reference table to produce the comparison CSV. Counts distinct visitors per `(dt, site_id)` cell for each funnel flag. Mirror this against our model — substituting `commerce_dev.orders.commerce_web_session_visitor_day` for the source table — to validate the new columns.

### `sqllab_untitled_query_6_20260605T170123 (1).csv` ⭐ **GROUND TRUTH**
Result rows from the validation query above, run on commerce's reference table. Six cells (3 days × 2 sites) over 2026-06-01..2026-06-03 for sites 515620 + 515621. Target numbers for our new columns:

| dt | site_id | has_pdp_to_cart_activity | has_product_page_to_cart_activity |
|---|---|---|---|
| 2026-06-01 | 515620 | 2,178 | 2,265 |
| 2026-06-02 | 515620 | 2,606 | 2,679 |
| 2026-06-03 | 515620 | 2,555 | 2,635 |
| 2026-06-01 | 515621 | 9,699 | 9,980 |
| 2026-06-02 | 515621 | 12,074 | 12,367 |
| 2026-06-03 | 515621 | 11,883 | 12,166 |

`has_cart_activity` and `visitors_that_ordered` numbers in this CSV match what we already produce — confirming the baseline before adding the two new columns.

### `FANSTREAMS-Page View Columns-010626-155856.pdf`
Page-view column data dictionary for `exp_prod.filtered_page_view_ice` (the upstream source). General column glossary — useful background reference for what's available on each page-view, but no new information needed for this task.

### `WA-FF_ Event List Value Definitions (eTags)-010626-155820.pdf`
Glossary mapping `event_list_arr` numeric values (eTags) to event semantics. Confirms `'2' = ADD_ITEM_TO_CART` — which is what our `is_atc_page` already uses. Useful for future event-list work but not new information for this task.

### `VI-POD level primary metrics & leading indicators (2026, visitor level)-010626-160127.pdf`
Downstream consumption docs: shows how POD-level metrics like "HP to Cart %", "Global Nav to Cart %", etc. are computed *from* `daily_visitor_activity_leading_indicators`. Not relevant for implementing the two new columns, but useful context for understanding which fields downstream consumers depend on.

### `VI-daily_products-010626-155722.pdf`
Documentation for the commerce team's `daily_products` table — a separate downstream model at (subsession × product) grain. **Not relevant** for this task.
