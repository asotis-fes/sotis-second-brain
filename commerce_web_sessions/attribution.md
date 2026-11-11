# Attribution — First-Touch / Last-Touch

Both lenses live at subsession grain now. `pk_subsession` (= `MD5(visitor_id, dt, site_id, visitor_subsession_index)`) is the canonical scope key.

## Last-touch — lives on `fan_clicks`

**Column**: `last_touch_order_ref_nums` (ARRAY)

Forward-fill `fan_click_id` across page-events ordered by `event_ts`, PARTITIONed by `pk_subsession`. Each `order_ref_num` is attributed to the most-recent fan_click_id before it.

Sentinel guard: INNER JOIN to `fan_click_to_commerce` on `(fan_click_id, pk_subsession)` so a sentinel ID only receives orders from the one subsession it "owns" via QUALIFY ROW_NUMBER.

### Example

```
pk_subsession = S (one trip)
12:00  fan_click abcdef
12:03  fan_click lmnioena
12:04  order ORD-1
12:07  fan_click ioqhdnea
12:30  THKU order ORD-2  (closes subsession)
```

- `abcdef` → `[]`
- `lmnioena` → `['ORD-1']`
- `ioqhdnea` → `['ORD-2']`

## First-touch — lives on `fan_clicks`

**Columns**: `first_touch_fan_click_id`, `first_touch_fan_click_event_ts`, `is_first_touch_click`

Per subsession, the earliest fan_click by `click_event_time` is first-touch. Broadcast across all fan_clicks rows in that subsession via a window function. `is_first_touch_click` is the boolean — exactly one TRUE per subsession.

The sentinel guard is implicit: only fan_clicks owned by the subsession (per `fan_click_to_commerce` QUALIFY) generate rows, so sentinels can't appear as first-touch in subsessions they don't own.

Subsessions naturally end at the closing checkout — so the "order before fan_click" case from the old session-grain design is no longer a class of error (orders close subsessions, fan_clicks within a subsession always precede the close).

## In the OBT

`fanapp_commerce_journey` carries both:

| Column | Source | Semantic |
|---|---|---|
| `last_touch_order_ref_nums` | fan_clicks | Orders attributed to THIS click |
| `last_touch_did_make_a_purchase` | derived | `ARRAY_SIZE(last_touch_order_ref_nums) > 0` |
| `first_touch_fan_click_id` | fan_clicks | Earliest fan_click in this subsession |
| `is_first_touch_click` | fan_clicks | This row is the first-touch of its subsession |
| `did_add_to_cart` | cwsvd | Subsession-grain; broadcast to all clicks |
| `did_make_a_purchase` | cwsvd | Subsession-grain; broadcast to all clicks |
| `order_ref_num` | cwsvd | Closing order_ref_num of the subsession (NULL if no purchase) |

## Reporting patterns

**Click-grain funnel**: `SELECT * FROM fanapp_commerce_journey`

**First-touch funnel** (one row per subsession): `WHERE is_first_touch_click`

**Last-touch revenue**:
```sql
SELECT fan_click_id, commerce_web_session_starter, SUM(wt.net_demand) AS revenue
FROM fanapp_commerce_journey AS j,
     LATERAL FLATTEN(input => j.last_touch_order_ref_nums) AS f
LEFT JOIN commerce.orders.weekly_trading AS wt ON wt.order_ref_num = f.value::STRING
GROUP BY 1, 2;
```

**Subsession-grain rollup**:
```sql
SELECT pk_subsession,
       BOOLOR_AGG(did_make_a_purchase) AS purchased,
       ARRAY_AGG(DISTINCT commerce_web_session_starter) AS starters_seen
FROM fanapp_commerce_journey
GROUP BY 1;
```

## Known attribution limitations

See `fan_clicks.sql` header for full text. Summary:

1. **Within-subsession split-attribution** (smaller than the 4.5% session-grain figure now — cross-trip variants no longer apply): ATC under click X, purchase under later click Y in the same subsession. Last-touch credits Y.
2. **`in_commerce_only` gap (~1.14% of FanApp-touched orders)**: when the most-recent fan_click_id before an order has no amp event match, no attribution surfaces in `last_touch_order_ref_nums`. The orders are still visible at subsession grain via `did_make_a_purchase` / `order_ref_num`. Conservative posture: no claim unless amp+commerce both confirm.
