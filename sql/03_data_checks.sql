USE hospital_analytics;

-- D01 | Does each table match the supplied CSV snapshot?
SELECT 'patients' AS table_name, COUNT(*) AS actual_rows, 974 AS expected_rows FROM patients
UNION ALL
SELECT 'payers', COUNT(*), 10 FROM payers
UNION ALL
SELECT 'organizations', COUNT(*), 1 FROM organizations
UNION ALL
SELECT 'encounters', COUNT(*), 27891 FROM encounters
UNION ALL
SELECT 'procedures', COUNT(*), 47701 FROM procedures;

-- D02 | These checks should return zero issues.
SELECT 'encounter_without_patient' AS check_name, COUNT(*) AS issue_count
FROM encounters e LEFT JOIN patients p ON e.patient = p.id
WHERE p.id IS NULL
UNION ALL
SELECT 'encounter_without_payer', COUNT(*)
FROM encounters e LEFT JOIN payers p ON e.payer = p.id
WHERE p.id IS NULL
UNION ALL
SELECT 'encounter_without_organization', COUNT(*)
FROM encounters e LEFT JOIN organizations o ON e.organization = o.id
WHERE o.id IS NULL
UNION ALL
SELECT 'procedure_without_encounter', COUNT(*)
FROM procedures p LEFT JOIN encounters e ON p.encounter = e.id
WHERE e.id IS NULL
UNION ALL
SELECT 'procedure_patient_mismatch', COUNT(*)
FROM procedures p JOIN encounters e ON p.encounter = e.id
WHERE p.patient <> e.patient
UNION ALL
SELECT 'encounter_stop_before_start', COUNT(*) FROM encounters WHERE `stop` < `start`
UNION ALL
SELECT 'procedure_stop_before_start', COUNT(*) FROM procedures WHERE `stop` < `start`
UNION ALL
SELECT 'negative_encounter_amount', COUNT(*) FROM encounters
WHERE base_encounter_cost < 0 OR total_claim_cost < 0 OR payer_coverage < 0
UNION ALL
SELECT 'negative_procedure_cost', COUNT(*) FROM procedures WHERE base_cost < 0
UNION ALL
SELECT 'payer_coverage_above_claim', COUNT(*) FROM encounters WHERE payer_coverage > total_claim_cost
UNION ALL
SELECT 'encounter_before_birth', COUNT(*)
FROM encounters e JOIN patients p ON e.patient = p.id
WHERE DATE(e.`start`) < p.birthdate
UNION ALL
SELECT 'duplicate_procedure_rows', COALESCE(SUM(row_count - 1), 0)
FROM (
    SELECT COUNT(*) AS row_count
    FROM procedures
    GROUP BY `start`, `stop`, patient, encounter, code, description,
             base_cost, reasoncode, reasondescription
    HAVING COUNT(*) > 1
) duplicates;

-- D03 | Source observations to document, with no automatic deletion.
-- Procedure timings and base costs do not consistently reconcile to their encounter.
SELECT 'procedure_outside_encounter_times' AS observation, COUNT(*) AS row_count
FROM procedures p JOIN encounters e ON p.encounter = e.id
WHERE p.`start` < e.`start` OR p.`stop` > e.`stop`
UNION ALL
SELECT 'encounter_with_zero_claim', COUNT(*) FROM encounters WHERE total_claim_cost = 0
UNION ALL
SELECT 'encounter_without_reason_code', COUNT(*) FROM encounters WHERE reasoncode IS NULL
UNION ALL
SELECT 'patient_without_zip', COUNT(*) FROM patients WHERE zip IS NULL
UNION ALL
SELECT 'encounter_starting_after_death_date', COUNT(*)
FROM encounters e JOIN patients p ON e.patient = p.id
WHERE DATE(e.`start`) > p.deathdate
UNION ALL
SELECT 'encounter_procedure_cost_above_claim', COUNT(*)
FROM encounters e
JOIN (
    SELECT encounter, SUM(base_cost) AS procedure_cost
    FROM procedures
    GROUP BY encounter
) p ON e.id = p.encounter
WHERE p.procedure_cost > e.total_claim_cost;

-- D04 | Snapshot totals used to verify the import.
SELECT
    MIN(`start`) AS first_encounter_utc,
    MAX(`start`) AS last_encounter_utc,
    SUM(total_claim_cost) AS total_claim_cost_usd,
    SUM(payer_coverage) AS payer_coverage_usd,
    (SELECT SUM(base_cost) FROM procedures) AS procedure_base_cost_usd
FROM encounters;

-- D05 | The monthly trend assumes one row for every month in the source window.
-- missing_months should be zero for this snapshot.
SELECT
    COUNT(DISTINCT DATE_FORMAT(`start`, '%Y-%m')) AS observed_months,
    TIMESTAMPDIFF(MONTH,
        CAST(DATE_FORMAT(MIN(`start`), '%Y-%m-01') AS DATE),
        CAST(DATE_FORMAT(MAX(`start`), '%Y-%m-01') AS DATE)
    ) + 1 - COUNT(DISTINCT DATE_FORMAT(`start`, '%Y-%m')) AS missing_months
FROM encounters;
