# Kanban Flow Analytics — SQL Validation Layer

SQL scripts to extract Kanban flow metrics directly from the OpenProject PostgreSQL database.
No plugin or UI changes required — pure data extraction for analysis and decision-making.

## Prerequisites

- Direct PostgreSQL access to the OpenProject database
- `psql`, DBeaver, DataGrip, or any SQL client

## Schema Relationships

```
work_packages
  └─ status_id ──────────────────────► statuses (id, name, is_closed, position, …)

journals
  ├─ journable_type = 'WorkPackage'
  ├─ journable_id   = work_packages.id
  ├─ data_type      = 'Journal::WorkPackageJournal'
  ├─ data_id        = work_package_journals.id
  └─ validity_period (tstzrange)
       ├─ lower(validity_period) = timestamp the WP entered this state
       └─ upper_inf(validity_period) = true → currently active journal

work_package_journals
  └─ status_id  (state snapshot at the time of the journal entry)
```

### How `validity_period` Works

Each journal entry has a `validity_period` (a PostgreSQL `tstzrange`).  
- The non-overlapping exclusion constraint guarantees exactly one active journal per work package at any point in time.  
- The **currently active** journal has `upper_inf(validity_period) = true` (no upper bound).  
- `lower(validity_period)` on the current journal = the moment the work package entered its current state (`entered_at`).

## Configuration

Every query now includes two variables in `WITH params AS (...)`:

- `project_name` → exact project name to analyze
- `since_date` → include only work packages with `created_at >= since_date`

Set either variable to `NULL` to disable that filter.

Example:

```sql
WITH params AS (
  SELECT
    'My Project'::text AS project_name,
    '2026-01-01'::timestamptz AS since_date
)
```

All queries that compute flow metrics filter out **boundary states** — states that are
not part of the active flow (e.g. New, Closed, Rejected).

Look for this comment in each query and adapt the list:

```sql
AND s.name NOT IN ('New', 'Closed', 'Rejected')   -- << adapt to your workflow
```

## Available Queries

| Query | Metric | Description |
|-------|--------|-------------|
| 1 | Time in State (Aging WIP) | Per-WP current status + how long it's been there |
| 2 | WIP Distribution | Count of WPs per status (all states) |
| 3 | Average Age per State | Bottleneck detection — states with high mean age |
| 4 | Max Age per State | Stuck-work detection — oldest single item per state |
| 5 | Flow Through States | All states with total vs. flow-only WIP side-by-side |
| 6 | WIP Excluding Boundary States | Aging WIP restricted to flow states only |
| 7 | Lead Time | Creation → closure duration for closed work packages |
| 8 | Combined Summary | WIP count + avg age + max age + oldest WP per state |
| 9 | Critical States Ranking | States ranked by bottleneck score (avg age desc) |

## Running the Scripts

```bash
# Run all queries at once
psql -d openproject -f kanban_flow_analytics.sql

# Run interactively (copy/paste individual queries)
psql -d openproject
```

## Interpreting Results

| Signal | Interpretation | Action |
|--------|----------------|--------|
| High `avg_age_days` on a state | Bottleneck — items stall here | Investigate WIP limits or process step |
| High `max_age_days` on a state | Single stuck item | Escalate / unblock |
| `wip_count` >> WIP limit | Limit breached | Pull-to-done or reject work |
| Lead time outliers | Complexity or blocking | Review history with Query 1 + journals |
