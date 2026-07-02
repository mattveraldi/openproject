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
--   projects
--     id, name, identifier
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
-- COMMON FILTER VARIABLES (set inside every query in CTE `params`):
--
--   project_name  -> project to analyze by exact name
--   since_date    -> include only work_packages.created_at >= since_date
--
-- Set NULL to disable a filter.
-- =============================================================================


-- =============================================================================
-- CONFIGURATION: excluded states (adapt names to your workflow)
-- =============================================================================
-- States listed here are excluded from WIP flow metrics (queries 3,4,5,6,9).
-- Typical exclusions: 'New', 'Closed', 'Rejected', 'On Hold'
-- Adjust the list to match your actual status names.


-- =============================================================================
-- QUERY 1: TIME IN STATE (AGING WIP)
-- =============================================================================

WITH params AS (
    SELECT
        'My Project'::text       AS project_name,  -- set NULL to include all projects
        '2026-01-01'::timestamptz AS since_date    -- set NULL to include all dates
),
scoped_work_packages AS (
    SELECT wp.*
    FROM work_packages wp
    JOIN projects p ON p.id = wp.project_id
    CROSS JOIN params prm
    WHERE (prm.project_name IS NULL OR p.name = prm.project_name)
      AND (prm.since_date IS NULL OR wp.created_at >= prm.since_date)
)
SELECT
    wp.id                                              AS work_package_id,
    wp.subject,
    s.name                                             AS current_status,
    lower(j.validity_period)                           AS entered_at,
    NOW() - lower(j.validity_period)                   AS time_in_state,
    EXTRACT(EPOCH FROM (NOW() - lower(j.validity_period))) / 3600  AS hours_in_state,
    EXTRACT(EPOCH FROM (NOW() - lower(j.validity_period))) / 86400 AS days_in_state
FROM scoped_work_packages wp
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

WITH params AS (
    SELECT
        'My Project'::text       AS project_name,
        '2026-01-01'::timestamptz AS since_date
),
scoped_work_packages AS (
    SELECT wp.*
    FROM work_packages wp
    JOIN projects p ON p.id = wp.project_id
    CROSS JOIN params prm
    WHERE (prm.project_name IS NULL OR p.name = prm.project_name)
      AND (prm.since_date IS NULL OR wp.created_at >= prm.since_date)
)
SELECT
    s.name   AS status,
    s.position,
    COUNT(*) AS wip_count
FROM scoped_work_packages wp
JOIN statuses s ON s.id = wp.status_id
GROUP BY s.id, s.name, s.position
ORDER BY s.position;


-- =============================================================================
-- QUERY 3: AVERAGE AGE PER STATE (BOTTLENECK DETECTION)
-- =============================================================================

WITH params AS (
    SELECT
        'My Project'::text       AS project_name,
        '2026-01-01'::timestamptz AS since_date
),
scoped_work_packages AS (
    SELECT wp.*
    FROM work_packages wp
    JOIN projects p ON p.id = wp.project_id
    CROSS JOIN params prm
    WHERE (prm.project_name IS NULL OR p.name = prm.project_name)
      AND (prm.since_date IS NULL OR wp.created_at >= prm.since_date)
)
SELECT
    s.name                                                          AS status,
    s.position,
    COUNT(*)                                                        AS wip_count,
    ROUND(
        AVG(EXTRACT(EPOCH FROM (NOW() - lower(j.validity_period))) / 86400)::numeric,
    2)                                                              AS avg_age_days
FROM scoped_work_packages wp
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

WITH params AS (
    SELECT
        'My Project'::text       AS project_name,
        '2026-01-01'::timestamptz AS since_date
),
scoped_work_packages AS (
    SELECT wp.*
    FROM work_packages wp
    JOIN projects p ON p.id = wp.project_id
    CROSS JOIN params prm
    WHERE (prm.project_name IS NULL OR p.name = prm.project_name)
      AND (prm.since_date IS NULL OR wp.created_at >= prm.since_date)
),
aging AS (
    SELECT
        wp.id                                                           AS work_package_id,
        wp.subject,
        s.id                                                            AS status_id,
        s.name                                                          AS status,
        s.position,
        EXTRACT(EPOCH FROM (NOW() - lower(j.validity_period))) / 86400 AS age_days
    FROM scoped_work_packages wp
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
    work_package_id                  AS oldest_wp_id,
    subject                          AS oldest_wp_subject,
    ROUND(age_days::numeric, 2)      AS max_age_days
FROM aging
ORDER BY status_id, age_days DESC;


-- =============================================================================
-- QUERY 5: FLOW THROUGH STATES (GENERAL DISTRIBUTION)
-- =============================================================================

WITH params AS (
    SELECT
        'My Project'::text       AS project_name,
        '2026-01-01'::timestamptz AS since_date
),
scoped_work_packages AS (
    SELECT wp.*
    FROM work_packages wp
    JOIN projects p ON p.id = wp.project_id
    CROSS JOIN params prm
    WHERE (prm.project_name IS NULL OR p.name = prm.project_name)
      AND (prm.since_date IS NULL OR wp.created_at >= prm.since_date)
)
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
LEFT JOIN scoped_work_packages wp ON wp.status_id = s.id
GROUP BY s.id, s.name, s.position, s.is_closed, s.is_default
ORDER BY s.position;


-- =============================================================================
-- QUERY 6: WIP EXCLUDING BOUNDARY STATES (FOCUS FLOW STATES)
-- =============================================================================

WITH params AS (
    SELECT
        'My Project'::text       AS project_name,
        '2026-01-01'::timestamptz AS since_date
),
scoped_work_packages AS (
    SELECT wp.*
    FROM work_packages wp
    JOIN projects p ON p.id = wp.project_id
    CROSS JOIN params prm
    WHERE (prm.project_name IS NULL OR p.name = prm.project_name)
      AND (prm.since_date IS NULL OR wp.created_at >= prm.since_date)
)
SELECT
    wp.id                                              AS work_package_id,
    wp.subject,
    s.name                                             AS current_status,
    s.position,
    lower(j.validity_period)                           AS entered_at,
    ROUND(
        (EXTRACT(EPOCH FROM (NOW() - lower(j.validity_period))) / 86400)::numeric,
    2)                                                 AS days_in_state
FROM scoped_work_packages wp
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

WITH params AS (
    SELECT
        'My Project'::text       AS project_name,
        '2026-01-01'::timestamptz AS since_date
),
scoped_work_packages AS (
    SELECT wp.*
    FROM work_packages wp
    JOIN projects p ON p.id = wp.project_id
    CROSS JOIN params prm
    WHERE (prm.project_name IS NULL OR p.name = prm.project_name)
      AND (prm.since_date IS NULL OR wp.created_at >= prm.since_date)
)
SELECT
    wp.id                                              AS work_package_id,
    wp.subject,
    wp.created_at,
    lower(j.validity_period)                           AS closed_at,
    ROUND(
        (EXTRACT(EPOCH FROM (lower(j.validity_period) - wp.created_at)) / 86400)::numeric,
    2)                                                 AS lead_time_days
FROM scoped_work_packages wp
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

WITH params AS (
    SELECT
        'My Project'::text       AS project_name,
        '2026-01-01'::timestamptz AS since_date
),
scoped_work_packages AS (
    SELECT wp.*
    FROM work_packages wp
    JOIN projects p ON p.id = wp.project_id
    CROSS JOIN params prm
    WHERE (prm.project_name IS NULL OR p.name = prm.project_name)
      AND (prm.since_date IS NULL OR wp.created_at >= prm.since_date)
),
aging AS (
    SELECT
        wp.id                                                           AS work_package_id,
        wp.subject,
        s.id                                                            AS status_id,
        s.name                                                          AS status,
        s.position,
        s.is_closed,
        EXTRACT(EPOCH FROM (NOW() - lower(j.validity_period))) / 86400 AS age_days
    FROM scoped_work_packages wp
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
        work_package_id                             AS oldest_wp_id,
        subject                                     AS oldest_wp_subject,
        ROUND(age_days::numeric, 2)                AS oldest_wp_age_days
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

WITH params AS (
    SELECT
        'My Project'::text       AS project_name,
        '2026-01-01'::timestamptz AS since_date
),
scoped_work_packages AS (
    SELECT wp.*
    FROM work_packages wp
    JOIN projects p ON p.id = wp.project_id
    CROSS JOIN params prm
    WHERE (prm.project_name IS NULL OR p.name = prm.project_name)
      AND (prm.since_date IS NULL OR wp.created_at >= prm.since_date)
),
aging AS (
    SELECT
        s.id                                                            AS status_id,
        s.name                                                          AS status,
        s.position,
        EXTRACT(EPOCH FROM (NOW() - lower(j.validity_period))) / 86400 AS age_days
    FROM scoped_work_packages wp
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
    COUNT(*)                              AS wip_count,
    ROUND(AVG(age_days)::numeric, 2)      AS avg_age_days,
    ROUND(MAX(age_days)::numeric, 2)      AS max_age_days,
    RANK() OVER (ORDER BY AVG(age_days) DESC) AS bottleneck_rank
FROM aging
GROUP BY status_id, status, position
ORDER BY bottleneck_rank;
