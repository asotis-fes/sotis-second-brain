# Data Quality Findings

Findings discovered during profiling and defensively handled in the models. Do NOT remove the QUALIFY / NOT IN guards — they exist for documented reasons.

## 1. Inheritor events propagate parent fanClickId

`poll_submission_success` / `poll_submission_failure` carry the fanClickId of the originating click event. Of 759K fanClickId-bearing events in the 4-day profile sample, 20,180 were inheritors. All had a corresponding originator.

**Handled**: `fan_clicks` filters `event_type NOT IN (poll_submission_success, poll_submission_failure)`. Exclusion (not inclusion) so new originator event_types pick up automatically.

## 2. fanClickId stamps multiple amp events

~2 fanClickIds per 4-day sample stamp multiple events across different amp `session_id`s.

**Handled**: `QUALIFY ROW_NUMBER() OVER (PARTITION BY fan_click_id ORDER BY event_time ASC) = 1` picks the earliest.

## 3. Sentinel fanClickIds touch many subsessions

Observed: one fanClickId stamping commerce-side activity across 432 sessions / 374 visitors / 164 user_accounts. Almost certainly a fallback/null-pattern ID from upstream tracking.

**Handled**: `fan_click_to_commerce` CTE picks the EARLIEST subsession per fan_click_id via QUALIFY. `last_touch_attribution` INNER JOINs on (`fan_click_id`, `pk_subsession`) so the sentinel only receives orders from its picked subsession. Under subsession grain the first-touch designation also benefits from this — sentinels don't generate fan_clicks rows in non-owned subsessions, so they can't be first-touch there.

## 4. amp ↔ commerce coverage

- **amp → commerce**: 20.7% (post-backfill window 2026-05-27+). ~79% of amp clicks never reach commerce (backed-out webview, in-app modal, or non-tracked site).
- **commerce → amp**: 98.7%. When commerce activity exists, it almost always has a matching amp click.
- **in_commerce_only**: ~1.3% (~7.2K fan_click_ids). On commerce but not amp — see finding #11 below.

The OBT INNER-JOINs on commerce subsession so the 79% funnel-leak is excluded. Query `fan_clicks` directly to measure click-to-commerce conversion.

## 5. Long-lived commerce sessions

Commerce SESSION_IDs persist for months due to cookie persistence. Under session-grain reporting, a 2026-06-01 ATC event living in a session that started in 2024 gets assigned the 2024 date and disappears from June filters.

**Handled**: Subsession grain. `commerce_web_session_visitor_day` keys on `(visitor_id, dt, site_id, visitor_subsession_index)`. `dt` is the source partition date, which is the actual day of the activity.

## 6. cart_summary vs product_ids_cart_flattened are not subsets

The two columns sound equivalent but differ. 6/2 site 515620 profile:
- 3,016 visitors have both non-empty
- 441 visitors have product_ids non-empty + cart_summary empty (our overcount if we used product_ids)
- 306 visitors have cart_summary non-empty + product_ids empty (we'd miss)

**Handled**: Use `cart_summary:final_cart_content` (matches commerce team's reference).

## 7. Bot/scraper traffic inflates counts on site 515620

~150-200 visitors/day of deep-paged scraper traffic on 515620; ~0 on 515621.

**Handled**: `WHERE page_num < 1000 OR (page_type = 'THKU' AND order_ref_num IS NOT NULL)`. The OR-clause preserves THKU+order rows so no purchase signal is lost.

## 8. THKU constraint too restrictive for did_make_a_purchase

Original logic required `page_type='THKU'`. Site 515620 specifically has unreliable THKU tagging — orders appear on non-THKU rows. Under-counted purchases by ~57%.

**Handled**: `did_make_a_purchase = (order_ref_num IS NOT NULL)`. Matches commerce team's `MAX(order_ref_num IS NOT NULL) AS converted`.

## 9. subsession → order_ref_num is effectively 1:1

15 of 75.7M subsessions have 2 distinct order_ref_nums (likely a tracking page surfacing an old order + a closing checkout); the rest have 0 or 1.

**Handled**: `commerce_web_session_visitor_day.order_ref_num = MAX(order_ref_num)`. Matches commerce team's `max(order_ref_num)`. The 15 cases lose one order_ref_num to MAX's lex pick, mirroring commerce team's behavior.

## 10. Search starter has 0% commerce match

Amplitude `native_search` events stamp fanClickId but the resulting page-view never lands in `fanapp_filtered_view_page` (different site_ids, in-app results, or propagation break).

**Status**: Tracking gap on FanApp side. Documented in `fan_clicks.sql` header.

## 11. in_commerce_only attribution gap

~1.14% of FanApp-touched purchase orders (329 / 28,719) have their most-recent fan_click_id be `in_commerce_only` — stamped on commerce page-views but with no amp event. The order is not attributed in `last_touch_order_ref_nums`.

**Handled**: documented. We accept this rather than re-route attribution to an earlier amp-sourced click — that would be a guess. The order remains visible at subsession grain via `did_make_a_purchase` / `order_ref_num`.

## 12. Within-subsession split-attribution

ATC under click X, purchase under later click Y in the same subsession. Last-touch credits Y; the cart-build was X. The cross-trip variants of this issue (4.5% at the old session grain) no longer apply since subsessions don't span trips.

**Status**: accepted limitation, smaller than the 4.5% session-grain figure.

## 13. fanapp_filtered_view_page backfill artifact

`fan_click_id` was added via `append_new_columns`. Historical partitions before ~2026-05-26 have NULL for that column, causing a sharp date step in fan_clicks coverage.

**Status**: documented. Full-refresh would backfill if older iceberg partitions have the column.

## Defensive SQL patterns

| Pattern | Use case |
|---|---|
| `QUALIFY ROW_NUMBER() = 1` with `ORDER BY ts ASC` | Enforce ≤1 row per key; pick the earliest deterministically. |
| `ARRAY_AGG(DISTINCT ...) + ARRAY_COMPACT` | Aggregate to an array, strip the single NULL DISTINCT keeps. |
| `NOT IN` exclusion lists | Safer than inclusion lists; new event_types pick up automatically. |
| `BOOLOR_AGG` over `LATERAL FLATTEN` | Multi-event pages — any flattened row matching → TRUE. |
| `ANY_VALUE` of a page-level expression | Page-level fields that don't vary across LATERAL FLATTEN rows. |
