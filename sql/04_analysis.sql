-- Core questions | Run after setup and data checks.
-- Money is in USD. Encounter and procedure costs are reported at their own grain.
USE hospital_analytics;

-- Q01 | What is the overall scale of the hospital activity in this extract?
SELECT
    COUNT(DISTINCT patient) AS patients_seen,
    COUNT(*) AS encounters,
    (SELECT COUNT(*) FROM procedures) AS procedure_records,
    MIN(DATE(`start`)) AS first_encounter_date,
    MAX(DATE(`start`)) AS last_encounter_date,
    SUM(total_claim_cost) AS total_claim_cost_usd,
    ROUND(AVG(total_claim_cost), 2) AS avg_claim_per_encounter_usd,
    SUM(payer_coverage) AS payer_coverage_usd,
    ROUND(100.0 * SUM(payer_coverage) / NULLIF(SUM(total_claim_cost), 0), 2) AS payer_coverage_pct
FROM encounters;

-- Q02 | How many encounters and distinct patients were recorded each year?
-- 2022 ends on February 5 in this snapshot.
SELECT
    YEAR(`start`) AS encounter_year,
    COUNT(*) AS encounters,
    COUNT(DISTINCT patient) AS patients_seen,
    SUM(total_claim_cost) AS total_claim_cost_usd,
    CASE WHEN YEAR(MIN(`start`)) = 2022 THEN 'Partial year' ELSE 'Full calendar year' END AS period_status
FROM encounters
GROUP BY YEAR(`start`)
ORDER BY encounter_year;

-- Q03 | How did the mix of encounter classes change each year?
SELECT
    YEAR(e.`start`) AS encounter_year,
    e.encounterclass,
    COUNT(*) AS encounters,
    ROUND(100.0 * COUNT(*) / yearly.total_encounters, 2) AS share_of_year_pct
FROM encounters e
JOIN (
    SELECT YEAR(`start`) AS encounter_year, COUNT(*) AS total_encounters
    FROM encounters
    GROUP BY YEAR(`start`)
) yearly ON YEAR(e.`start`) = yearly.encounter_year
GROUP BY YEAR(e.`start`), e.encounterclass, yearly.total_encounters
ORDER BY encounter_year, encounters DESC, e.encounterclass;

-- Q04 | What share of encounters lasted under, exactly, or over 24 hours?
-- Comparing timestamps keeps 24 hours and 1 second out of the exact-24 bucket.
WITH durations AS (
    SELECT CASE
        WHEN `stop` < DATE_ADD(`start`, INTERVAL 24 HOUR) THEN 'Under 24 hours'
        WHEN `stop` = DATE_ADD(`start`, INTERVAL 24 HOUR) THEN 'Exactly 24 hours'
        ELSE 'Over 24 hours'
    END AS duration_group
    FROM encounters
)
SELECT
    duration_group,
    COUNT(*) AS encounters,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM encounters), 2) AS encounter_share_pct
FROM durations
GROUP BY duration_group
ORDER BY FIELD(duration_group, 'Under 24 hours', 'Exactly 24 hours', 'Over 24 hours');

-- Q05 | Which encounter classes account for the most visits, time, and claims?
SELECT
    encounterclass,
    COUNT(*) AS encounters,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM encounters), 2) AS encounter_share_pct,
    ROUND(AVG(TIMESTAMPDIFF(SECOND, `start`, `stop`)) / 3600.0, 2) AS avg_duration_hours,
    SUM(total_claim_cost) AS total_claim_cost_usd,
    ROUND(100.0 * SUM(total_claim_cost) / (SELECT SUM(total_claim_cost) FROM encounters), 2) AS claim_share_pct,
    ROUND(AVG(total_claim_cost), 2) AS avg_claim_usd
FROM encounters
GROUP BY encounterclass
ORDER BY total_claim_cost_usd DESC, encounterclass;

-- Q06 | How common is zero payer coverage?
-- A zero-dollar claim can also have zero coverage, so show positive claims separately.
SELECT
    COUNT(*) AS total_encounters,
    SUM(CASE WHEN payer_coverage = 0 THEN 1 ELSE 0 END) AS zero_coverage_encounters,
    ROUND(100.0 * SUM(CASE WHEN payer_coverage = 0 THEN 1 ELSE 0 END) / COUNT(*), 2) AS zero_coverage_pct,
    SUM(CASE WHEN payer_coverage = 0 AND total_claim_cost > 0 THEN 1 ELSE 0 END) AS positive_claim_zero_coverage,
    SUM(total_claim_cost - payer_coverage) AS claim_amount_without_payer_coverage_usd
FROM encounters;

-- Q07 | Which ten procedures are performed most often, and what do they cost?
-- Group by code because descriptions can vary for the same procedure.
SELECT
    code AS procedure_code,
    MIN(description) AS procedure_description,
    COUNT(*) AS procedure_records,
    ROUND(AVG(base_cost), 2) AS avg_base_cost_usd
FROM procedures
GROUP BY code
ORDER BY procedure_records DESC, code
LIMIT 10;

-- Q08 | Which ten procedures have the highest average base cost?
-- Frequency helps put rare procedures in context.
SELECT
    code AS procedure_code,
    MIN(description) AS procedure_description,
    COUNT(*) AS procedure_records,
    ROUND(AVG(base_cost), 2) AS avg_base_cost_usd
FROM procedures
GROUP BY code
ORDER BY AVG(base_cost) DESC, code
LIMIT 10;

-- Q09 | How do average claims and covered amounts differ by payer?
-- LEFT JOIN retains payers that have no encounters in the extract.
SELECT
    p.name AS payer,
    COUNT(e.id) AS encounters,
    ROUND(AVG(e.total_claim_cost), 2) AS avg_claim_usd,
    COALESCE(SUM(e.total_claim_cost), 0) AS total_claim_cost_usd,
    COALESCE(SUM(e.payer_coverage), 0) AS payer_coverage_usd,
    ROUND(100.0 * SUM(e.payer_coverage) / NULLIF(SUM(e.total_claim_cost), 0), 2) AS payer_coverage_pct
FROM payers p
LEFT JOIN encounters e ON p.id = e.payer
GROUP BY p.id, p.name
ORDER BY total_claim_cost_usd DESC, p.name;

-- Q10 | How many distinct patients had any visit or an inpatient encounter each quarter?
-- Inpatient counts use encounter records. Advanced query A04 combines overlapping stays.
SELECT
    YEAR(`start`) AS encounter_year,
    QUARTER(`start`) AS encounter_quarter,
    COUNT(DISTINCT patient) AS patients_seen,
    COUNT(DISTINCT CASE WHEN encounterclass = 'inpatient' THEN patient END) AS inpatient_patients,
    SUM(CASE WHEN encounterclass = 'inpatient' THEN 1 ELSE 0 END) AS inpatient_encounters,
    CASE WHEN YEAR(MIN(`start`)) = 2022 THEN 'Partial quarter' ELSE 'Full calendar quarter' END AS period_status
FROM encounters
GROUP BY YEAR(`start`), QUARTER(`start`)
ORDER BY encounter_year, encounter_quarter;

-- Q11 | Which age groups account for encounter volume and claim costs?
-- Age is calculated at the visit date so older records retain the correct age.
WITH age_groups AS (
    SELECT
        e.total_claim_cost,
        CASE
            WHEN TIMESTAMPDIFF(YEAR, p.birthdate, e.`start`) < 18 THEN 'Under 18'
            WHEN TIMESTAMPDIFF(YEAR, p.birthdate, e.`start`) < 40 THEN '18-39'
            WHEN TIMESTAMPDIFF(YEAR, p.birthdate, e.`start`) < 65 THEN '40-64'
            ELSE '65+'
        END AS age_group
    FROM encounters e
    JOIN patients p ON e.patient = p.id
)
SELECT
    age_group,
    COUNT(*) AS encounters,
    SUM(total_claim_cost) AS total_claim_cost_usd,
    ROUND(AVG(total_claim_cost), 2) AS avg_claim_usd
FROM age_groups
GROUP BY age_group
ORDER BY FIELD(age_group, 'Under 18', '18-39', '40-64', '65+');

-- Q12 | How does procedure volume relate to claims by encounter class?
-- Aggregate procedures to one row per encounter before joining to encounter claims.
WITH procedure_counts AS (
    SELECT encounter, COUNT(*) AS procedure_records
    FROM procedures
    GROUP BY encounter
)
SELECT
    e.encounterclass,
    COUNT(*) AS encounters,
    SUM(CASE WHEN p.encounter IS NOT NULL THEN 1 ELSE 0 END) AS encounters_with_procedures,
    COALESCE(SUM(p.procedure_records), 0) AS procedure_records,
    ROUND(AVG(COALESCE(p.procedure_records, 0)), 2) AS avg_procedures_per_encounter,
    SUM(e.total_claim_cost) AS total_claim_cost_usd
FROM encounters e
LEFT JOIN procedure_counts p ON e.id = p.encounter
GROUP BY e.encounterclass
ORDER BY procedure_records DESC, e.encounterclass;
