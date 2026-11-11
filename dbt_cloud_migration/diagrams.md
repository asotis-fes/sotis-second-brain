# Migration Visualizations — Big-Bang Plan

Mermaid sources. Paste each into a Confluence **Mermaid Diagram** macro (or any Mermaid-rendering viewer — GitHub, Obsidian, VS Code, mermaid.live).

Start dates and durations are placeholders. Adjust once the team picks a Saturday.

---

## 1. Phase timeline (Gantt)

Best for: showing the calendar shape — 5-6 weeks foundation → Saturday cutover → 1 week stabilization → ongoing extraction.

```mermaid
gantt
    title dbt Core → Cloud Migration — Big-Bang Plan
    dateFormat YYYY-MM-DD
    axisFormat %b %d

    section A. Foundation
    Lock decisions (team review)                :done,    a1, 2026-07-01, 5d
    Provision Cloud account                     :         a2, after a1, 1d
    SVC_DBT_CLOUD_ROLE + grants audit           :         a3, after a1, 3d
    Create analytics_eng + analytics repos      :         a4, after a2, 1d
    Copy project, fix 1.10 syntax               :         a5, after a4, 3d
    Terraform foundation (project, creds, envs) :         a6, after a3 a4, 3d
    GitHub App install + env naming             :         a7, after a4, 1d

    section B. Job topology
    Create one Cloud job per dbt_* DAG (paused) :         b1, after a6, 5d
    Capture job IDs for export PR               :         b2, after b1, 1d
    Stand up Cloud CI (non-required)            :         b3, after a6, 2d
    Cloud merge job                             :         b4, after a6, 1d

    section C. Validation primitives
    Single-source freshness test                :         c1, after b1, 1d
    Two-dummy-model chain test                  :         c2, after b1, 1d
    Airflow DbtCloudJobRunSensor POC            :         c3, after b2, 2d
    FireHydrant + Slack alerting end-to-end     :         c4, after b1, 3d
    Admin API kill-switch script + dry-run      :         c5, after b1, 1d

    section D. Pre-cutover staging
    Pre-stage export-swap PR (approved)         :         d1, after b2 c3, 3d
    Pre-stage DAG rename script                 :         d2, after d1, 1d
    Source freshness Cloud jobs (4 domains)     :         d3, after c1, 2d
    Notification subscriptions for all jobs     :         d4, after c4, 3d
    Cutover runbook documented                  :         d5, after d4, 2d

    section E. Cutover
    Pre-cutover rehearsal                       :         e1, after d5, 1d
    Cutover (T-3h to T+6h)                      :crit,    e2, after e1, 1d

    section F. Stabilization
    First 24h watch                             :crit,    f1, after e2, 2d
    Spot-checks via Cloud Explorer              :         f2, after f1, 3d
    Team retrospective                          :         f3, after f1, 1d

    section G. Post-cutover (ongoing)
    Delete fes-airflow rollback safety net      :         g1, after f3, 1d
    analytics repo extraction begins            :         g2, after f3, 30d
    Per-export Cloud job split (D18 future)     :         g3, after f3, 30d
    Retire dbt GHA workflows                    :         g4, after f3, 1d
    Remove dbt-core from MWAA                   :         g5, after g4, 1d
    Delete fes-airflow/dags/dbt/                :         g6, after g5, 1d
```

---

## 1b. Phase timeline (Gantt) — contractor split view

Same Gantt as above, but color-coded by who could reasonably own each item if we bring in a dbt Labs consultant.

**Legend** (using Mermaid Gantt tag semantics as a proxy for color):
- `done` → 🟢 **Pure dbt** (contractor owns end-to-end, ~11 pts)
- `active` → 🔵 **Contractor reasonable with support** (contractor codes, we deploy, ~29 pts)
- `crit` → 🔴 **We do ourselves** (internal access / context / on-call ownership, ~30 pts)

```mermaid
gantt
    title dbt Core → Cloud Migration — Contractor Split View
    dateFormat YYYY-MM-DD
    axisFormat %b %d

    section A. Foundation
    Lock decisions (team review)                :crit,    a1, 2026-07-01, 5d
    Provision Cloud account                     :crit,    a2, after a1, 1d
    SVC_DBT_CLOUD_ROLE + grants audit           :crit,    a3, after a1, 3d
    Create analytics_eng + analytics repos      :crit,    a4, after a2, 1d
    Copy project, fix 1.10 syntax               :done,    a5, after a4, 3d
    Terraform foundation (project, creds, envs) :crit,    a6, after a3 a4, 3d
    GitHub App install + env naming             :crit,    a7, after a4, 1d

    section B. Job topology
    Create one Cloud job per dbt_* DAG (paused) :active,  b1, after a6, 5d
    Capture job IDs for export PR               :crit,    b2, after b1, 1d
    Stand up Cloud CI (non-required)            :done,    b3, after a6, 2d
    Cloud merge job                             :done,    b4, after a6, 1d

    section C. Validation primitives
    Single-source freshness test                :done,    c1, after b1, 1d
    Two-dummy-model chain test                  :done,    c2, after b1, 1d
    Airflow DbtCloudJobRunSensor POC            :active,  c3, after b2, 2d
    FireHydrant + Slack alerting end-to-end     :crit,    c4, after b1, 3d
    Admin API kill-switch script + dry-run      :done,    c5, after b1, 1d

    section D. Pre-cutover staging
    Pre-stage export-swap PR (approved)         :active,  d1, after b2 c3, 3d
    Pre-stage DAG rename script                 :crit,    d2, after d1, 1d
    Source freshness Cloud jobs (4 domains)     :done,    d3, after c1, 2d
    Notification subscriptions for all jobs     :crit,    d4, after c4, 3d
    Cutover runbook documented                  :crit,    d5, after d4, 2d

    section E. Cutover
    Pre-cutover rehearsal                       :crit,    e1, after d5, 1d
    Cutover (T-3h to T+6h)                      :crit,    e2, after e1, 1d

    section F. Stabilization
    First 24h watch                             :crit,    f1, after e2, 2d
    Spot-checks via Cloud Explorer              :active,  f2, after f1, 3d
    Team retrospective                          :crit,    f3, after f1, 1d

    section G. Post-cutover (ongoing)
    Delete fes-airflow rollback safety net      :crit,    g1, after f3, 1d
    analytics repo extraction begins            :active,  g2, after f3, 30d
    Per-export Cloud job split (D18 future)     :active,  g3, after f3, 30d
    Retire dbt GHA workflows                    :crit,    g4, after f3, 1d
    Remove dbt-core from MWAA                   :crit,    g5, after g4, 1d
    Delete fes-airflow/dags/dbt/                :crit,    g6, after g5, 1d
```

### Category breakdown

| Category | Items | Points | % of total |
|---|---|---|---|
| 🟢 Pure dbt (contractor owns) | 7 | 11 | 15% |
| 🔵 Contractor reasonable (paired) | 6 | 29 | 41% |
| 🔴 We do ourselves | 19 | 30 | 42% |
| **Total** | **32** | **70** | 100% |

### Pre-cutover only (Phases A–E)

If contractor engagement ends at cutover:

| Category | Points to cutover | % |
|---|---|---|
| 🟢 Pure dbt | 11 | 24% |
| 🔵 Contractor reasonable | 10 | 22% |
| 🔴 We do ourselves | 24 | 53% |
| **Total pre-cutover** | **45** | 100% |

**Read:** a dbt Labs consultant could take ~11 pts (24%) fully off our plate, and pair with us on ~10 pts (22%) more — up to 46% of pre-cutover work externalized. The remaining 53% requires internal access or org context.

### What falls where

**🟢 Pure dbt (contractor owns):**
- Copy project + fix 1.10 syntax (a5)
- Stand up Cloud CI (b3)
- Cloud merge job (b4)
- Single-source freshness test (c1)
- Two-dummy-model chain test (c2)
- Admin API kill-switch script (c5)
- Source freshness Cloud jobs (d3)

**🔵 Contractor reasonable (needs some access / pairing):**
- Create Cloud jobs — needs Terraform access, but design is dbt pattern (b1)
- Airflow DbtCloudJobRunSensor POC — needs fes-airflow access (c3)
- Pre-stage export-swap PR — needs to understand our 6 export DAGs (d1)
- Post-cutover spot-checks — needs Snowflake read access (f2)
- analytics repo extraction — Mesh is a dbt Labs strength, but needs domain judgment (g2)
- Per-export Cloud job split — pure dbt pattern, needs our deploy access (g3)

**🔴 We do ourselves (internal only):**
- All decision-making (a1)
- Cloud account provisioning + billing (a2)
- Snowflake role + grants (a3)
- GitHub repo creation + CODEOWNERS (a4)
- Terraform authoring (a6)
- GitHub App install (a7)
- Capture job IDs from our TF (b2)
- FireHydrant + Slack integration — our internal systems (c4)
- DAG-rename PR in fes-airflow (d2)
- Priority mapping to FireHydrant P1/P2/P3 (d4)
- Cutover runbook — our on-call, our contacts (d5)
- Rehearsal + cutover + watch (e1, e2, f1)
- Team retrospective (f3)
- All fes-airflow cleanup (g1, g4, g5, g6)

---

## 2. Cutover sequence (T-3h to T+6h)

Best for: the cutover runbook itself — what happens, in what order, who does what, with explicit rollback branches.

```mermaid
sequenceDiagram
    autonumber
    actor Eng as Engineer (on-call)
    participant FA as fes-airflow / MWAA
    participant TF as Terraform / Job mgr
    participant DC as dbt Cloud
    participant SF as Snowflake
    participant FH as FireHydrant + Slack

    rect rgb(255, 244, 230)
        Note over Eng,FH: T-3h — Smoke test
        Eng->>DC: Trigger all jobs into shadow schema<br/>(DATABASE_OUTPUT_OVERRIDE)
        DC->>SF: Build models in shadow
        SF-->>DC: Build results
        DC-->>Eng: All green? ✅ proceed / ❌ abort + reschedule
    end

    rect rgb(230, 244, 255)
        Note over Eng,FH: T-30m — Final pre-checks
        Eng->>FA: Confirm last Airflow dbt_* runs completed
        FA-->>Eng: ✅ clean
        Eng->>FH: Page on-call coverage active
    end

    rect rgb(230, 255, 244)
        Note over Eng,FH: T0 — Cutover
        Eng->>FA: Merge rename PR<br/>(dbt_*.py → .disabled)
        FA->>FA: MWAA picks up rename<br/>(~15 min)
        FA-->>Eng: dbt_* DAGs no longer visible
    end

    rect rgb(230, 255, 244)
        Note over Eng,FH: T+30m — Enable Cloud
        Eng->>TF: Flip all Cloud jobs paused=false
        TF->>DC: Apply
        DC-->>Eng: Jobs active on their crons
    end

    rect rgb(230, 255, 244)
        Note over Eng,FH: T+45m — Wire exports
        Eng->>FA: Merge export-swap PR<br/>(DbtCloudJobRunSensor)
        FA->>FA: Export DAGs now poll Cloud
    end

    rect rgb(230, 255, 244)
        Note over Eng,FH: T+1h — Smoke test on prod
        Eng->>DC: Manually trigger one job
        DC->>SF: Build into real prod
        SF-->>DC: ✅
        DC->>FH: Notification subscriptions fire (none, since success)
    end

    Note over Eng,FH: T+1.5h to T+6h — Hands off, watch
    DC->>SF: Scheduled runs fire normally
    DC->>FH: Any failures route to FH/Slack
    Eng->>DC: Spot-check Cloud Explorer + Discovery API

    alt ❌ Critical failure detected
        Note over Eng,FH: ROLLBACK
        Eng->>Eng: Run kill-switch script<br/>(Admin API pauses all jobs ~10s)
        DC-->>Eng: All jobs paused
        Eng->>FA: Revert export-swap PR
        Eng->>FA: Rename .py.disabled → .py
        FA->>FA: MWAA picks up; dbt_* DAGs back live
        Note over Eng,FH: System back to pre-cutover within ~15 min
    else ✅ Stable
        Note over Eng,FH: Cloud is now the scheduler.<br/>Next: Phase F stabilization watch.
    end
```

---

## 3. System-level migration state machine

Best for: explaining "where are we in the migration?" — single state describes the whole system, not per-DAG.

```mermaid
stateDiagram-v2
    [*] --> Airflow_scheduled

    Airflow_scheduled : State 0 — Today
    Airflow_scheduled : MWAA runs dbt-core 1.8 from fes-airflow/dags/dbt/
    Airflow_scheduled : No Cloud account yet

    Airflow_scheduled --> Foundation : Begin Phase A

    Foundation : State 1 — Foundation work
    Foundation : Cloud account + repos + Terraform
    Foundation : Jobs created but paused
    Foundation : Engineers still develop in fes-airflow

    Foundation --> Smoke_test_ready : Phases A-D complete

    Smoke_test_ready : State 2 — Ready to cut over
    Smoke_test_ready : All Cloud jobs exist (paused)
    Smoke_test_ready : Export PR approved, rename script ready
    Smoke_test_ready : Alerting tested end-to-end

    Smoke_test_ready --> Cutover_window : Smoke test passes
    Smoke_test_ready --> Abort_reschedule : Smoke test fails

    Abort_reschedule : Smoke test failed
    Abort_reschedule : Investigate + fix
    Abort_reschedule --> Smoke_test_ready : Re-attempt on next chosen day

    Cutover_window : State 3 — Cutover window<br/>(see sequence diagram)
    Cutover_window : T-3h to T+6h
    Cutover_window : MWAA dbt DAGs disabled<br/>Cloud jobs enabled<br/>Exports re-wired

    Cutover_window --> Stabilization : T+6h, no critical issues
    Cutover_window --> Rollback : Critical failure during cutover

    Rollback : ROLLBACK
    Rollback : Kill-switch all Cloud jobs (~10s)
    Rollback : Revert export PR
    Rollback : Rename .disabled → .py
    Rollback --> Airflow_scheduled : System restored<br/>(within ~15 min)
    Rollback --> Smoke_test_ready : Fix root cause, try again

    Stabilization : State 4 — Stabilization watch
    Stabilization : Cloud is the scheduler
    Stabilization : .py.disabled files still exist (safety net)
    Stabilization : First 1-2 weeks of close monitoring

    Stabilization --> Stable_cloud : 2-3 weeks clean

    Stable_cloud : State 5 — Stable Cloud-native
    Stable_cloud : .py.disabled files deleted
    Stable_cloud : MWAA dbt-core removed
    Stable_cloud : Everything still in analytics_eng

    Stable_cloud --> Mesh_extraction : Begin Phase G extraction

    Mesh_extraction : State 6 — Mesh extraction (ongoing)
    Mesh_extraction : Gradually move analyst models<br/>analytics_eng → analytics
    Mesh_extraction : Establish access:public + contract:enforced<br/>on foundation boundary

    Mesh_extraction --> [*] : Mesh split complete<br/>(weeks/months)
```

---

## 4. Repo topology + data flow

Best for: explaining "where does dbt code live" before, during, and after the migration. Same shape as before, updated to reflect big-bang and analytics-empty-initially.

```mermaid
flowchart LR
    subgraph FA["fes-airflow (existing)"]
        FA_DAGS["dags/*.py<br/>(non-dbt DAGs — unchanged)"]
        FA_DBT_DISABLED["dags/dbt/dbt_*.py.disabled<br/>(rollback safety, post-Saturday)<br/><i>deleted after stabilization</i>"]
        FA_EXPORT["dags/exports/*.py<br/>uses DbtCloudJobRunSensor<br/>to wait on Cloud jobs"]
    end

    subgraph AE["analytics_eng repo (post-Saturday)"]
        direction TB
        AE_AE_SUB["analytics_eng/<br/>(AE-owned models)"]
        AE_AN_SUB["analytics/<br/>(analyst-owned models<br/>— pending extraction)"]
    end

    subgraph AN["analytics repo"]
        AN_FILLING["empty initially<br/><i>fills gradually post-cutover</i><br/>(see D2 + Phase G)"]
    end

    subgraph CLOUD["dbt Cloud"]
        CLOUD_PROJ_AE["Project: analytics_eng"]
        CLOUD_PROJ_AN["Project: analytics<br/>(empty initially)"]
        CLOUD_JOBS["~22 deploy jobs<br/>+ 4 freshness jobs<br/>+ CI + merge jobs"]
    end

    subgraph SNOW["Snowflake (prod)"]
        SNOW_TABLES["Prod tables"]
    end

    subgraph EXT["External Systems"]
        FH["FireHydrant<br/>P1/P2/P3 email signals"]
        SLACK["Slack<br/>account-level OAuth"]
    end

    MWAA["MWAA<br/>Airflow scheduler"]

    MWAA -->|runs| FA_DAGS
    MWAA -->|runs| FA_EXPORT
    MWAA -.->|ignores .disabled files| FA_DBT_DISABLED

    AE_AE_SUB --> CLOUD_PROJ_AE
    AE_AN_SUB --> CLOUD_PROJ_AE
    AN_FILLING -.->|future| CLOUD_PROJ_AN
    CLOUD_PROJ_AE -.->|future Mesh ref<br/>after extraction| CLOUD_PROJ_AN
    CLOUD_PROJ_AE --> CLOUD_JOBS
    CLOUD_PROJ_AN --> CLOUD_JOBS

    CLOUD_JOBS -->|builds on schedule| SNOW_TABLES

    FA_EXPORT -.->|polls API:<br/>has job finished?| CLOUD_JOBS

    CLOUD_JOBS -->|webhook on failure| FH
    CLOUD_JOBS -->|notification| SLACK

    classDef disabled fill:#fff4e6,stroke:#ff9933,stroke-width:2px,stroke-dasharray: 5 5
    classDef active fill:#e6f9ec,stroke:#33cc66,stroke-width:2px
    classDef future fill:#f4ecff,stroke:#9966cc,stroke-width:2px,stroke-dasharray: 5 5
    classDef external fill:#f0f0f0,stroke:#999

    class FA_DBT_DISABLED disabled
    class AE_AE_SUB,AE_AN_SUB,CLOUD_PROJ_AE active
    class AN_FILLING,CLOUD_PROJ_AN future
    class FH,SLACK,SNOW_TABLES external
```

---

## How to embed in Confluence

1. Edit the target page.
2. Type `/mermaid` and select the **Mermaid Diagram** macro (or the **Mermaid Chart for Confluence** app if installed).
3. Paste one of the code blocks above (content between the ` ```mermaid ` and ` ``` ` markers — not the markers themselves).
4. Save.

If your space doesn't have a Mermaid macro, use the **draw.io / Diagrams** macro and import via "Edit Diagram → Insert from Text → Mermaid".

## How to evolve

When the plan changes (e.g., D18 split lands, D19 mechanism locks):
- Update the relevant Mermaid block in this file
- Re-paste into Confluence
- Or — if your Mermaid Confluence app supports it — point the macro at this Git file for live rendering

For executive presentations, use these as the structural sketch and let a designer style them in Lucid.
