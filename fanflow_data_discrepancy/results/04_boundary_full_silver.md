# Step 4 — Boundary check using full silver history

## Result

| found_in_silver_any_time | truly_missing |
|---|---|
| **65** | **599** |

## Drilldown — Step 4b: where did the 65 boundary events actually land?

| commerce_hour_utc | where_fes_landed | count | min_delay_sec | max_delay_sec | fes_earliest | fes_latest |
|---|---|---|---|---|---|---|
| 2026-05-27 23:00:00 | fes_after_window | **65** | 1 | 1 | 2026-05-28 00:00:00 | 2026-05-28 00:00:00 |

## Interpretation — Anna was right to push on boundary

- **All 65 boundary events come from the 23:00 UTC hour on 2026-05-27** — the exact hour we previously flagged as having 65 missing events.
- They land in FES at **exactly `2026-05-28 00:00:00`** — 1 second after the Commerce `event_ts`.
- Our original FES filter was `event_ts < '2026-05-28 00:00:00'` (strict less-than). Events landing at exactly that timestamp were excluded.
- **All 65 are boundary timing artifacts, not loss.** The 23:00 UTC gap hour was entirely false-positive.

## Revised gap distribution (truly missing = 599)

| commerce_hour_utc | originally_reported | true_missing | boundary_artifact |
|---|---|---|---|
| 2026-05-26 02:00 | 420 | 420 | 0 |
| 2026-05-26 12:00 | 15 | 15 | 0 |
| 2026-05-26 13:00 | 164 | 164 | 0 |
| 2026-05-27 23:00 | 65 | **0** | 65 |
| **Total** | **664** | **599** | **65** |

## Action

- The 23:00 UTC hour is no longer a gap hour — drop from the Confluence doc
- True missing count is **599**, not 664
- Recreate `LOYALTY_MISSING_EVENTS` table with no FES time filter so we work with only the 599 truly-missing events going forward
- Steps 5+ (dollar values, samples, CSV) operate on the corrected 599 set
