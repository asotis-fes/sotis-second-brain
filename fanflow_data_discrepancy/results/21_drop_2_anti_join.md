# Step 21 — drop_2 anti-join: 1,863 missing events over 23 days

## Setup

- External table: `FES_USERS.ALEX_SOTIS.INCIDENT_COMMERCE_LOYALTY_EVENTS_DROP_2_EXT`
- Source path: `s3://fanatics-prod-internal-confidential-fes-fds/alex_sotis/incident_2026_05_26_drop_2_loyalty_keys/`
- Time covered: 2026-05-01 20:00 → 2026-05-24 19:59 UTC (23 days)
- Commerce-side total rows: 229,813,121 (~229.4M distinct loyTranId+status)

## Result

| Window | Days | Missing events | Daily rate |
|---|---|---|---|
| Original (2026-05-24 → 2026-05-28) | 3.5 | 599 | ~171/day |
| **drop_2 wider (2026-05-01 → 2026-05-24)** | **23** | **1,863** | **~81/day** |
| **Combined coverage** | **27** | **2,462** | **~91/day** |

## Distribution by day — the big finding

| event_date | missing_count | % of drop_2 |
|---|---|---|
| **2026-05-08** | **1,763** | **94.6%** |
| 2026-05-12 | 96 | 5.2% |
| 2026-05-13 | 4 | 0.2% |
| All other days (~20 days) | 0 | 0% |

**Almost everything missed in the 23-day window happened on a single day: 2026-05-08.** This looks like a specific incident/outage day, not a steady drip.

## By site_id / tenant_id — same as before

| site_id | tenant_id | count | % |
|---|---|---|---|
| **608111** | **100002** | **1,861** | **99.9%** |
| 610753 | 100004 | 1 | 0.05% |
| 610649 | 100004 | 1 | 0.05% |

Same FBG sportsbook casino site (608111 / 100002) dominates again — matches the original 3.5-day window pattern.

## By status

| txn_status | event_count | total_amount |
|---|---|---|
| ADD (earns) | 1,824 | $52.38 |
| AUTH | 20 | $171.24 |
| CAPTURE_1 (captures) | 18 | $154.56 |
| VOID_1 | 1 | $0.10 |
| **TOTAL** | **1,863** | **$378.28** |

## Combined picture across all 27 days

| Field | Combined value |
|---|---|
| Total missing events | 2,462 |
| Total $ amount | $548.20 |
| Events on 2026-05-08 alone | 1,763 (71.6% of all losses) |
| Events on 2026-05-26 (original gap hours) | 599 |
| Events on other days | 100 (across 5/12, 5/13, sporadic) |

## What this means for the investigation

Two distinct loss patterns visible now:

1. **2026-05-08 burst** — 1,763 events in one day, almost all site 608111. Looks like a specific outage of some upstream component.
2. **2026-05-26 cluster** — 599 events across 3 hours (02:00, 12:00, 13:00 UTC), all site 608111 except 7 stragglers. Looks like another burst pattern.

The 2026-05-08 spike is now the strongest signal for the platform team — if they can identify what happened in their infrastructure on that date, it likely explains 95% of the drop_2 losses and may localize the same drop mechanism that hit 2026-05-26.
