-- Hospital operations analysis | MySQL 8.0.16 or later
-- Run this file first. All source CSV columns are retained.

CREATE DATABASE IF NOT EXISTS hospital_analytics
    CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE hospital_analytics;

CREATE TABLE IF NOT EXISTS patients (
    id CHAR(36) PRIMARY KEY,
    birthdate DATE NOT NULL,
    deathdate DATE,
    prefix VARCHAR(10),
    first VARCHAR(100),
    last VARCHAR(100),
    suffix VARCHAR(10),
    maiden VARCHAR(100),
    marital CHAR(1),
    race VARCHAR(50),
    ethnicity VARCHAR(50),
    gender CHAR(1),
    birthplace VARCHAR(255),
    address VARCHAR(255),
    city VARCHAR(100),
    state VARCHAR(100),
    county VARCHAR(100),
    zip VARCHAR(10),
    lat DOUBLE,
    lon DOUBLE
) ENGINE = InnoDB;

CREATE TABLE IF NOT EXISTS payers (
    id CHAR(36) PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    address VARCHAR(255),
    city VARCHAR(100),
    state_headquartered VARCHAR(50),
    zip VARCHAR(10),
    phone VARCHAR(30)
) ENGINE = InnoDB;

CREATE TABLE IF NOT EXISTS organizations (
    id CHAR(36) PRIMARY KEY,
    name VARCHAR(150) NOT NULL,
    address VARCHAR(255),
    city VARCHAR(100),
    state VARCHAR(50),
    zip VARCHAR(10),
    lat DOUBLE,
    lon DOUBLE
) ENGINE = InnoDB;

CREATE TABLE IF NOT EXISTS encounters (
    id CHAR(36) PRIMARY KEY,
    `start` DATETIME NOT NULL,
    `stop` DATETIME NOT NULL,
    patient CHAR(36) NOT NULL,
    organization CHAR(36) NOT NULL,
    payer CHAR(36) NOT NULL,
    encounterclass VARCHAR(50) NOT NULL,
    code VARCHAR(20),
    description VARCHAR(255),
    base_encounter_cost DECIMAL(12,2) NOT NULL,
    total_claim_cost DECIMAL(12,2) NOT NULL,
    payer_coverage DECIMAL(12,2) NOT NULL,
    reasoncode VARCHAR(20),
    reasondescription VARCHAR(255),
    CONSTRAINT fk_encounter_patient FOREIGN KEY (patient) REFERENCES patients(id),
    CONSTRAINT fk_encounter_payer FOREIGN KEY (payer) REFERENCES payers(id),
    CONSTRAINT fk_encounter_organization FOREIGN KEY (organization) REFERENCES organizations(id),
    CONSTRAINT chk_encounter_dates CHECK (`stop` >= `start`),
    CONSTRAINT chk_encounter_costs CHECK (
        base_encounter_cost >= 0 AND total_claim_cost >= 0 AND payer_coverage >= 0
    ),
    INDEX idx_encounter_patient_start (patient, `start`),
    INDEX idx_encounter_class_start (encounterclass, `start`)
) ENGINE = InnoDB;

CREATE TABLE IF NOT EXISTS procedures (
    -- The source has no procedure ID. This ID is its 1-based CSV data-row number.
    procedure_id INT UNSIGNED PRIMARY KEY,
    `start` DATETIME NOT NULL,
    `stop` DATETIME NOT NULL,
    patient CHAR(36) NOT NULL,
    encounter CHAR(36) NOT NULL,
    code VARCHAR(20) NOT NULL,
    description VARCHAR(255),
    base_cost DECIMAL(12,2) NOT NULL,
    reasoncode VARCHAR(20),
    reasondescription VARCHAR(255),
    CONSTRAINT fk_procedure_patient FOREIGN KEY (patient) REFERENCES patients(id),
    CONSTRAINT fk_procedure_encounter FOREIGN KEY (encounter) REFERENCES encounters(id),
    CONSTRAINT chk_procedure_dates CHECK (`stop` >= `start`),
    CONSTRAINT chk_procedure_cost CHECK (base_cost >= 0),
    INDEX idx_procedure_code (code)
) ENGINE = InnoDB;
