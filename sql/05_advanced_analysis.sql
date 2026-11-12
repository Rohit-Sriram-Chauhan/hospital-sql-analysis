-- Four extensions using CTEs and window functions.
USE hospital_analytics;

-- A01 | How did monthly volume change, and what was its three-month average?
-- Exclude February 2022 because the extract ends during that month.
-- Data check D05 confirms there are no missing months before applying LAG.
WITH monthly AS (
    SELECT
        CAST(DATE_FORMAT(`start`, '%Y-%m-01') AS DATE) AS month_start,
        COUNT(*) AS encounters
    FROM encounters
    WHERE `start` < (SELECT CAST(DATE_FORMAT(MAX(`start`), '%Y-%m-01') AS DATE) FROM encounters)
    GROUP BY CAST(DATE_FORMAT(`start`, '%Y-%m-01') AS DATE)
), trends AS (
    SELECT
        month_start,
        encounters,
        LAG(encounters) OVER (ORDER BY month_start) AS previous_month_encounters,
        CASE WHEN COUNT(*) OVER three_months = 3
             THEN AVG(encounters) OVER three_months END AS three_month_avg
    FROM monthly
    WINDOW three_months AS (ORDER BY month_start ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
)
SELECT
    month_start,
    encounters,
    previous_month_encounters,
    ROUND(100.0 * (encounters - previous_month_encounters) / NULLIF(previous_month_encounters, 0), 2) AS month_over_month_pct,
    ROUND(three_month_avg, 2) AS three_month_avg_encounters
FROM trends
ORDER BY month_start;

-- A02 | What are the three most frequent procedure ranks within each encounter class?
-- DENSE_RANK includes ties. A class can therefore return more than three procedures.
WITH procedure_frequency AS (
    SELECT
        e.encounterclass,
        p.code AS procedure_code,
        MIN(p.description) AS procedure_description,
        COUNT(*) AS procedure_records
    FROM procedures p
    JOIN encounters e ON p.encounter = e.id
    GROUP BY e.encounterclass, p.code
), ranked AS (
    SELECT
        encounterclass,
        procedure_code,
        procedure_description,
        procedure_records,
        DENSE_RANK() OVER (PARTITION BY encounterclass ORDER BY procedure_records DESC) AS frequency_rank
    FROM procedure_frequency
)
SELECT encounterclass, procedure_code, procedure_description, procedure_records, frequency_rank
FROM ranked
WHERE frequency_rank <= 3
ORDER BY encounterclass, frequency_rank, procedure_code;

-- Reuse one definition for the A03 summary and patient ranking.
-- A repeat visit starts >0 and <=30 days after the immediately preceding encounter ends.
-- Follow-up appointments and planned visits are included in this measure.
CREATE OR REPLACE VIEW vw_encounter_returns AS
WITH ordered_visits AS (
    SELECT
        id AS encounter_id,
        patient,
        `start` AS visit_start,
        `stop` AS visit_stop,
        LAG(`stop`) OVER (PARTITION BY patient ORDER BY `start`, id) AS previous_visit_stop
    FROM encounters
)
SELECT encounter_id, patient, visit_start, visit_stop, previous_visit_stop
FROM ordered_visits
WHERE visit_start > previous_visit_stop
  AND visit_start <= DATE_ADD(previous_visit_stop, INTERVAL 30 DAY);

-- A03a | How many patients had a repeat visit within 30 days?
SELECT
    COUNT(*) AS repeat_visits,
    COUNT(DISTINCT patient) AS patients_with_repeat_visits,
    ROUND(100.0 * COUNT(DISTINCT patient) / (SELECT COUNT(*) FROM patients), 2) AS share_of_patients_pct
FROM vw_encounter_returns;

-- A03b | Which patients had the most such repeat visits?
SELECT
    patient AS patient_id,
    COUNT(*) AS repeat_visits,
    MIN(DATE(visit_start)) AS first_repeat_visit_date,
    MAX(DATE(visit_start)) AS last_repeat_visit_date
FROM vw_encounter_returns
GROUP BY patient
ORDER BY repeat_visits DESC, patient
LIMIT 10;

-- A04 uses inpatient stays. Combine overlapping or touching encounter records first.
-- A running maximum handles a long stay that overlaps several shorter records.
CREATE OR REPLACE VIEW vw_inpatient_followup AS
WITH previous_ends AS (
    SELECT
        id,
        patient,
        `start`,
        `stop`,
        MAX(`stop`) OVER (
            PARTITION BY patient ORDER BY `start`, `stop`, id
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS previous_latest_stop
    FROM encounters
    WHERE encounterclass = 'inpatient'
), boundaries AS (
    SELECT *,
        CASE WHEN previous_latest_stop IS NULL OR `start` > previous_latest_stop
             THEN 1 ELSE 0 END AS new_stay
    FROM previous_ends
), numbered_stays AS (
    SELECT *,
        SUM(new_stay) OVER (
            PARTITION BY patient ORDER BY `start`, `stop`, id
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS stay_number
    FROM boundaries
), stays AS (
    SELECT
        patient,
        stay_number,
        MIN(`start`) AS admission_time,
        MAX(`stop`) AS discharge_time,
        COUNT(*) AS source_encounters
    FROM numbered_stays
    GROUP BY patient, stay_number
), followup AS (
    SELECT *,
        LEAD(admission_time) OVER (PARTITION BY patient ORDER BY stay_number) AS next_admission_time
    FROM stays
)
SELECT
    f.patient,
    f.stay_number,
    f.admission_time,
    f.discharge_time,
    f.source_encounters,
    f.next_admission_time,
    CASE WHEN f.discharge_time <= DATE_SUB((SELECT MAX(`stop`) FROM encounters), INTERVAL 30 DAY)
              AND (p.deathdate IS NULL OR p.deathdate > DATE(DATE_ADD(f.discharge_time, INTERVAL 30 DAY)))
         THEN 1 ELSE 0 END AS eligible_for_followup,
    CASE WHEN f.next_admission_time > f.discharge_time
              AND f.next_admission_time <= DATE_ADD(f.discharge_time, INTERVAL 30 DAY)
         THEN 1 ELSE 0 END AS inpatient_return_30d
FROM followup f
JOIN patients p ON f.patient = p.id;

-- A04a | What share of eligible inpatient stays had an observed return within 30 days?
-- Eligibility requires 30 days before the extract cutoff and survival through that window.
-- This is a descriptive all-cause return measure for this synthetic extract.
SELECT
    COUNT(*) AS merged_inpatient_stays,
    SUM(source_encounters) AS source_inpatient_encounters,
    COUNT(DISTINCT patient) AS inpatient_patients,
    SUM(eligible_for_followup) AS eligible_discharges,
    SUM(CASE WHEN eligible_for_followup = 1 THEN inpatient_return_30d ELSE 0 END) AS discharges_with_return,
    COUNT(DISTINCT CASE WHEN eligible_for_followup = 1 AND inpatient_return_30d = 1 THEN patient END) AS patients_with_return,
    ROUND(100.0 * SUM(CASE WHEN eligible_for_followup = 1 THEN inpatient_return_30d ELSE 0 END)
        / NULLIF(SUM(eligible_for_followup), 0), 2) AS observed_return_pct,
    ROUND(AVG(TIMESTAMPDIFF(SECOND, admission_time, discharge_time)) / 3600.0, 2) AS avg_merged_stay_hours
FROM vw_inpatient_followup;

-- A04b | Which patients had the most returns after eligible inpatient discharges?
SELECT
    patient AS patient_id,
    COUNT(*) AS eligible_discharges,
    SUM(inpatient_return_30d) AS discharges_with_return
FROM vw_inpatient_followup
WHERE eligible_for_followup = 1
GROUP BY patient
HAVING SUM(inpatient_return_30d) > 0
ORDER BY discharges_with_return DESC, patient
LIMIT 10;
