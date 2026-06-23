-- =============================================================================
-- KANBAN FLOW ANALYTICS - SQL Validation Layer
-- OpenProject Database (PostgreSQL)
-- =============================================================================
--
-- SCHEMA OVERVIEW (relevant tables):
--
--   work_packages
--     id, subject, status_id, project_id, created_at, updated_at
--
--   statuses
--     id, name, is_closed, is_default, is_readonly, excluded_from_totals, position
--
--   journals
--     id, journable_type ('WorkPackage'), journable_id (work_packages.id),
--     data_type ('Journal::WorkPackageJournal'), data_id (work_package_journals.id),
--     validity_period (tstzrange), created_at, version
--
--   work_package_journals
--     id, status_id, subject, project_id, ...
--
-- HOW TIMING WORKS:
--   Each journal entry has a `validity_period` (tstzrange).
--   The currently active journal has upper_inf(validity_period) = true.
--   lower(validity_period) = timestamp when the work package entered that state.
--
-- =============================================================================


-- =============================================================================
-- CONFIGURATION: excluded states (adapt names to your workflow)
-- =============================================================================
-- States listed here are excluded from WIP flow metrics (queries 2-6).
-- Typical exclusions: 'New', 'Closed', 'Rejected', 'On Hold'
-- Adjust the list to match your actual status names.

-- Used as an inline filter: s.name NOT IN (<excluded_states>)
-- See each query below for usage.


-- =============================================================================
-- QUERY 1: TIME IN STATE (AGING WIP)
-- =============================================================================
-- For each work package, shows the current status and how long it has been
-- in that status (entered_at = lower bound of the currently active journal).
-- =============================================================================

SELECT
    wp.id                                              AS work_package_id,
    wp.subject,
    s.name                                             AS current_status,
    lower(j.validity_period)                           AS entered_at,
    NOW() - lower(j.validity_period)                   AS time_in_state,
    EXTRACT(EPOCH FROM (NOW() - lower(j.validity_period))) / 3600 AS hours_in_state,
    EXTRACT(EPOCH FROM (NOW() - lower(j.validity_period))) / 86400 AS days_in_state
FROM work_packages wp
JOIN statuses s
    ON s.id = wp.status_id
JOIN journals j
    ON j.journable_type = 'WorkPackage'
   AND j.journable_id   = wp.id
   AND upper_inf(j.validity_period)
JOIN work_package_journals wpj
    ON wpj.id   = j.data_id
   AND j.data_type = 'Journal::WorkPackageJournal'
   AND wpj.status_id = wp.status_id
ORDER BY days_in_state DESC;


-- =============================================================================
-- QUERY 2: WIP DISTRIBUTION PER STATE
-- =============================================================================
-- Count of work packages currently in each status (all states).
-- Provides a snapshot of where work accumulates.
-- =============================================================================

SELECT
    s.name   AS status,
    s.position,
    COUNT(*) AS wip_count
FROM work_packages wp
JOIN statuses s ON s.id = wp.status_id
GROUP BY s.id, s.name, s.position
ORDER BY s.position;


-- =============================================================================
-- QUERY 3: AVERAGE AGE PER STATE (BOTTLENECK DETECTION)
-- =============================================================================
-- Average time (in days) work packages have spent in their current state,
-- grouped by status. States excluded from flow analysis are filtered out.
-- High average age signals a bottleneck.
-- =============================================================================

SELECT
    s.name                                                          AS status,
    s.position,
    COUNT(*)                                                        AS wip_count,
    ROUND(
        AVG(
            EXTRACT(EPOCH FROM (NOW() - lower(j.validity_period))) / 86400
        )::numeric,
    2)                                                              AS avg_age_days
FROM work_packages wp
JOIN statuses s
    ON s.id = wp.status_id
   AND s.name NOT IN ('New', 'Closed', 'Rejected')   -- << adapt to your workflow
JOIN journals j
    ON j.journable_type = 'WorkPackage'
   AND j.journable_id   = wp.id
   AND upper_inf(j.validity_period)
JOIN work_package_journals wpj
    ON wpj.id   = j.data_id
   AND j.data_type = 'Journal::WorkPackageJournal'
   AND wpj.status_id = wp.status_id
GROUP BY s.id, s.name, s.position
ORDER BY avg_age_days DESC;


-- =============================================================================
-- QUERY 4: MAX AGE PER STATE (STUCK WORK DETECTION)
-- =============================================================================
-- Maximum time (in days) any single work package has been stuck in a state.
-- Also returns the specific work package id and subject for investigation.
-- =============================================================================

WITH aging AS (
    SELECT
        wp.id                                                           AS work_package_id,
        wp.subject,
        s.id                                                            AS status_id,
        s.name                                                          AS status,
        s.position,
        EXTRACT(EPOCH FROM (NOW() - lower(j.validity_period))) / 86400 AS age_days
    FROM work_packages wp
    JOIN statuses s
        ON s.id = wp.status_id
       AND s.name NOT IN ('New', 'Closed', 'Rejected')   -- << adapt to your workflow
    JOIN journals j
        ON j.journable_type = 'WorkPackage'
       AND j.journable_id   = wp.id
       AND upper_inf(j.validity_period)
    JOIN work_package_journals wpj
        ON wpj.id   = j.data_id
       AND j.data_type = 'Journal::WorkPackageJournal'
       AND wpj.status_id = wp.status_id
)
SELECT DISTINCT ON (status_id)
    status,
    position,
    work_package_id     AS oldest_wp_id,
    subject             AS oldest_wp_subject,
    ROUND(age_days::numeric, 2) AS max_age_days
FROM aging
ORDER BY status_id, age_days DESC;


-- =============================================================================
-- QUERY 5: FLOW THROUGH STATES (GENERAL DISTRIBUTION)
-- =============================================================================
-- Full picture of all states including total and active-flow counts side by side.
-- Useful for understanding proportion of WIP in flow vs. boundary states.
-- =============================================================================

SELECT
    s.name                                        AS status,
    s.position,
    s.is_closed,
    s.is_default,
    COUNT(wp.id)                                  AS total_wip,
    COUNT(wp.id) FILTER (
        WHERE s.name NOT IN ('New', 'Closed', 'Rejected')  -- << adapt to your workflow
    )                                             AS flow_wip
FROM statuses s
LEFT JOIN work_packages wp ON wp.status_id = s.id
GROUP BY s.id, s.name, s.position, s.is_closed, s.is_default
ORDER BY s.position;


-- =============================================================================
-- QUERY 6: WIP EXCLUDING BOUNDARY STATES (FOCUS FLOW STATES)
-- =============================================================================
-- Like Query 1 but restricted to active flow states only.
-- Shows aging only for the work packages that are "in flight".
-- =============================================================================

SELECT
    wp.id                                              AS work_package_id,
    wp.subject,
    s.name                                             AS current_status,
    s.position,
    lower(j.validity_period)                           AS entered_at,
    ROUND(
        (EXTRACT(EPOCH FROM (NOW() - lower(j.validity_period))) / 86400)::numeric,
    2)                                                 AS days_in_state
FROM work_packages wp
JOIN statuses s
    ON s.id = wp.status_id
   AND s.name NOT IN ('New', 'Closed', 'Rejected')   -- << adapt to your workflow
JOIN journals j
    ON j.journable_type = 'WorkPackage'
   AND j.journable_id   = wp.id
   AND upper_inf(j.validity_period)
JOIN work_package_journals wpj
    ON wpj.id   = j.data_id
   AND j.data_type = 'Journal::WorkPackageJournal'
   AND wpj.status_id = wp.status_id
ORDER BY days_in_state DESC;


-- =============================================================================
-- QUERY 7: LEAD TIME (CREATION → CLOSURE)
-- =============================================================================
-- Applicable only to work packages in a closed status (is_closed = true).
-- lead_time = timestamp when closed - created_at
-- "closed_at" is derived from lower(validity_period) of the current journal,
-- which is the moment the work package entered the closed status.
-- =============================================================================

SELECT
    wp.id                                              AS work_package_id,
    wp.subject,
    wp.created_at,
    lower(j.validity_period)                           AS closed_at,
    ROUND(
        (EXTRACT(EPOCH FROM (lower(j.validity_period) - wp.created_at)) / 86400)::numeric,
    2)                                                 AS lead_time_days
FROM work_packages wp
JOIN statuses s
    ON s.id = wp.status_id
   AND s.is_closed = true
JOIN journals j
    ON j.journable_type = 'WorkPackage'
   AND j.journable_id   = wp.id
   AND upper_inf(j.validity_period)
JOIN work_package_journals wpj
    ON wpj.id   = j.data_id
   AND j.data_type = 'Journal::WorkPackageJournal'
   AND wpj.status_id = wp.status_id
ORDER BY lead_time_days DESC;


-- =============================================================================
-- QUERY 8: COMBINED SUMMARY (AGGREGATE VIEW PER STATE)
-- =============================================================================
-- Single output combining WIP count, average age, and max age per state.
-- Also identifies the "most blocked" work package per state.
-- =============================================================================

WITH aging AS (
    SELECT
        wp.id                                                           AS work_package_id,
        wp.subject,
        s.id                                                            AS status_id,
        s.name                                                          AS status,
        s.position,
        s.is_closed,
        EXTRACT(EPOCH FROM (NOW() - lower(j.validity_period))) / 86400 AS age_days
    FROM work_packages wp
    JOIN statuses s
        ON s.id = wp.status_id
    JOIN journals j
        ON j.journable_type = 'WorkPackage'
       AND j.journable_id   = wp.id
       AND upper_inf(j.validity_period)
    JOIN work_package_journals wpj
        ON wpj.id   = j.data_id
       AND j.data_type = 'Journal::WorkPackageJournal'
       AND wpj.status_id = wp.status_id
),
summary AS (
    SELECT
        status_id,
        status,
        position,
        is_closed,
        COUNT(*)                                    AS wip_count,
        ROUND(AVG(age_days)::numeric, 2)            AS avg_age_days,
        ROUND(MAX(age_days)::numeric, 2)            AS max_age_days
    FROM aging
    GROUP BY status_id, status, position, is_closed
),
oldest_per_state AS (
    SELECT DISTINCT ON (status_id)
        status_id,
        work_package_id AS oldest_wp_id,
        subject         AS oldest_wp_subject,
        ROUND(age_days::numeric, 2) AS oldest_wp_age_days
    FROM aging
    ORDER BY status_id, age_days DESC
)
SELECT
    sm.status,
    sm.position,
    sm.is_closed,
    sm.wip_count,
    sm.avg_age_days,
    sm.max_age_days,
    op.oldest_wp_id,
    op.oldest_wp_subject,
    op.oldest_wp_age_days
FROM summary sm
JOIN oldest_per_state op ON op.status_id = sm.status_id
ORDER BY sm.position;


-- =============================================================================
-- QUERY 9: CRITICAL STATES (RANKED BY AVERAGE + MAX AGE)
-- =============================================================================
-- Identifies the states that are most likely bottlenecks or have stagnant items.
-- Excludes boundary states (New, Closed, Rejected).
-- Ranks states by average age descending.
-- =============================================================================

WITH aging AS (
    SELECT
        s.id                                                            AS status_id,
        s.name                                                          AS status,
        s.position,
        EXTRACT(EPOCH FROM (NOW() - lower(j.validity_period))) / 86400 AS age_days
    FROM work_packages wp
    JOIN statuses s
        ON s.id = wp.status_id
       AND s.name NOT IN ('New', 'Closed', 'Rejected')   -- << adapt to your workflow
    JOIN journals j
        ON j.journable_type = 'WorkPackage'
       AND j.journable_id   = wp.id
       AND upper_inf(j.validity_period)
    JOIN work_package_journals wpj
        ON wpj.id   = j.data_id
       AND j.data_type = 'Journal::WorkPackageJournal'
       AND wpj.status_id = wp.status_id
)
SELECT
    status,
    position,
    COUNT(*)                          AS wip_count,
    ROUND(AVG(age_days)::numeric, 2)  AS avg_age_days,
    ROUND(MAX(age_days)::numeric, 2)  AS max_age_days,
    RANK() OVER (ORDER BY AVG(age_days) DESC) AS bottleneck_rank
FROM aging
GROUP BY status_id, status, position
ORDER BY bottleneck_rank;
