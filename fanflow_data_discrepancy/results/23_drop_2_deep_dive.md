# Drop_2 deep dive — 1,863 missing events characterized

## Partial-lifecycle split (Step 23)

| Category | Distinct transactions | % |
|---|---|---|
| Completely missing (no trace in FES) | 1,832 | 98.7% |
| Partial lifecycle (FES has same txn with different status) | 24 | 1.3% |
| **Total distinct transactions** | **1,856** | |

Note: 1,856 distinct transactions vs 1,863 missing rows → 7 transactions have ≥2 status events missing. Same ratio as drop_1 (99%/1%), so the pattern is consistent: the vast majority of losses are entire transactions that never reached FES.

## The 5/08 burst — 5 minutes, not a day (Step 24)

The "1,763 events on 2026-05-08" headline is misleading. Actual structure:

| Time | Missing events | Notes |
|---|---|---|
| 2026-05-08 04:39 UTC | 1 | First event |
| 2026-05-08 04:40 UTC | 53 | |
| 2026-05-08 04:41 UTC | 41 | |
| **2026-05-08 04:42 UTC** | **1,282** | **Peak minute** |
| 2026-05-08 04:43 UTC | 385 | |
| 2026-05-08 16:31 UTC | 1 | Lone straggler |

**1,762 of 1,763 events lost in a single 5-minute window: 04:39–04:43 UTC**. This is the smoking gun for the platform team — extremely tight timestamp range to correlate against connector health, MirrorMaker2, or enrichment service logs/alerts for that exact window.

## 5/12 also a short burst (Step 26)

| Time | Missing events |
|---|---|
| 2026-05-12 00:27–00:32 UTC | 17 (ramp-up) |
| **2026-05-12 00:33 UTC** | **79 (peak)** |
| 2026-05-13 22:30 + 23:28 UTC | 4 stragglers |

96 events lost in 7 minutes (00:27–00:33 UTC on 5/12) + 4 stragglers on 5/13.

## All burst windows summarized

| Window | Duration | Events lost | Peak minute |
|---|---|---|---|
| **2026-05-08 04:39–04:43 UTC** | 5 min | 1,762 | 04:42 (1,282) |
| 2026-05-08 16:31 UTC | 1 min | 1 | — |
| **2026-05-12 00:27–00:33 UTC** | 7 min | 96 | 00:33 (79) |
| 2026-05-13 22:30 + 23:28 UTC | 2 stragglers | 4 | — |
| **2026-05-26 02:00 + 12:00 + 13:00 UTC (gap hours)** | ~3 hours | 599 | — |
| **TOTAL across both UNLOADs (27 days)** | | **2,462** | |

The 5/26 pattern is different from 5/08/5/12 — broader smear across hours instead of tight burst. Could be a different mechanism, or the same mechanism under lighter load.

## Profile of the 5/08 burst

### State distribution

| sub_div (US state) | missing count | % |
|---|---|---|
| MI | 744 | 42.2% |
| PA | 577 | 32.7% |
| NJ | 250 | 14.2% |
| WV | 160 | 9.1% |
| CO | 6 | |
| IN, LA, NY | 4 each | |
| NC, TN, VA | 2–3 each | |
| Other (AZ, OH, MA, MO, KY, MD, blank) | 1 each | |

All FBG sportsbook-legal states. Volume distribution roughly matches actual FBG casino activity — no single state appears disproportionately affected.

### Account distribution

- **691 distinct accounts** affected
- 2.55 missing events per account on average
- Broadly distributed — not a tiny set of accounts with thousands of losses each

### Transaction type

- **1,724 ADD** (earns from CASINO_BETTING and BONUS_SETTLEMENT) at $51.86
- **20 AUTH** (authorization-for-payment) at $171.24
- **18 CAPTURE_1** (capture-payment) at $154.56
- **1 VOID_1** at $0.10

Mostly real casino/bonus earn transactions (1,724 of 1,762 = 97.8%). The 20 AUTH and 18 CAPTURE_1 events are the higher-$ redemption side of the lifecycle.

### Status mix vs 5/26

| | 5/08 burst | 5/26 burst |
|---|---|---|
| ADD events | 1,724 ($51.86) | 587 ($13.12) |
| CAPTURE_1 events | 18 ($154.56) | 7 ($33.58) |
| AUTH events | 20 ($171.24) | 4 ($105.22) |
| VOID_1 events | 1 ($0.10) | 1 ($18.00) |

Same status mix proportions — ADD-dominated with small redemption-side numbers. Suggests both bursts hit the same upstream stream (FBG casino loyalty events) for the same population of users.

## What's most useful for the platform team

Single most actionable finding: **2026-05-08 04:39–04:43 UTC** — a 5-minute window where ~1,762 events were lost. They should correlate that against:

- S3 sink connector health
- MirrorMaker2 logs
- Enrichment service error logs
- Datadog monitor 274365347 (Kafka Connect S3 Sink health, per runbook 2322170081)

If they see any infrastructure alert/anomaly in that 5-minute window, that's almost certainly the source. The 5/12 and 5/26 events likely share the same root cause as smaller versions.

## OpenSearch / Kafka UI trace — not viable for these dates

FES Kafka retention is ~7-10 days. As of 2026-06-05:
- 5/08 events: way past retention, gone
- 5/12 events: way past retention, gone
- 5/26 events: borderline — 10 days old, may be aged out
- 5/27 events: probably still in retention

So Kafka UI inspection is only viable for the most recent gap events (5/26 if you move fast). For 5/08 and 5/12, this Snowflake-side data lineage analysis is the strongest evidence we can provide.
