create database if not exists CLINICAL_OPS;
create schema if not exists CLINICAL_OPS.RAW;
USE DATABASE CLINICAL_OPS;
USE SCHEMA RAW;

use database clinical_ops;

create schema if not exists raw;
use schema RAW;

create or replace table patients (
    patient_id STRING,
    first_name STRING,
    last_name STRING,
    dob STRING,
    gender STRING,
    city STRING,
    state STRING,
    zip STRING,
    insurance_type STRING,
    registration_date STRING
);

CREATE OR REPLACE TABLE departments (
    department_id STRING,
    department_name STRING,
    location STRING,
    cost_center STRING
);

CREATE OR REPLACE TABLE providers (
    provider_id STRING,
    provider_name STRING,
    specialty STRING,
    department_id STRING,
    hire_date STRING
);

CREATE OR REPLACE TABLE appointments (
    appointment_id STRING,
    patient_id STRING,
    provider_id STRING,
    department_id STRING,
    scheduled_date STRING,
    scheduled_time STRING,
    appointment_type STRING,
    status STRING,
    check_in_time STRING,
    check_out_time STRING,
    wait_time_minutes STRING
);

CREATE OR REPLACE STAGE CLINICAL_STAGE;

LIST @CLINICAL_OPS.RAW.CLINICAL_STAGE;

copy into clinical_ops.raw.patients
from @clinical_ops.raw.clinical_stage/patients.csv
file_format = (
    type = csv
    field_delimiter = ','
    skip_header = 1
);

copy into clinical_ops.raw.departments
from @clinical_ops.raw.clinical_stage/departments.csv
file_format = (
    type = csv
    field_delimiter = ','
    skip_header = 1
);

copy into clinical_ops.raw.providers
from @clinical_ops.raw.clinical_stage/providers.csv
file_format = (
    type = csv
    field_delimiter = ','
    skip_header = 1
);

copy into clinical_ops.raw.appointments
from @clinical_ops.raw.clinical_stage/appointments.csv
file_format = (
    type = csv
    field_delimiter = ','
    skip_header = 1
);

-- Verify load
SELECT 'departments' AS tbl, COUNT(*) FROM departments
UNION ALL SELECT 'providers', COUNT(*) FROM providers
UNION ALL SELECT 'patients', COUNT(*) FROM patients
UNION ALL SELECT 'appointments', COUNT(*) FROM appointments;

select * from patients;
select * from departments;
select * from providers;
select * from appointments;

-- Data Quality Issues
-- Same patients names and dob
select trim(lower(FIRST_NAME)) as fn, trim(lower(last_name)) as ln, dob, count(*) as total_count
from patients
group by fn, ln, dob
having total_count > 1;

-- Inconsistent gender values
SELECT DISTINCT gender FROM patients;

-- Duplicate appointment ids
SELECT appointment_id, COUNT(*) 
FROM appointments 
GROUP BY appointment_id 
HAVING COUNT(*) > 1;

-- Orphaned appointments (patient_id doesn't exist in patients table
SELECT *
FROM appointments a
LEFT JOIN patients p ON a.patient_id = p.patient_id
WHERE p.patient_id IS NULL;

-- Negative wait times
SELECT * FROM appointments WHERE wait_time_minutes < '0' LIMIT 10;

-- Missing checkin/checkout times
select * from appointments 
where status = 'Completed' and (check_in_time = '' or check_out_time = '');

-- Inconsistent date formats in registration_date
SELECT registration_date FROM patients
WHERE registration_date NOT LIKE '____-__-__';


-- Create new stage
CREATE SCHEMA IF NOT EXISTS CLINICAL_OPS.STAGING;
USE SCHEMA CLINICAL_OPS.STAGING;

-- New Patient table
CREATE OR REPLACE TABLE STAGING.patients AS
with cleaned as (
    select
        patient_id :: INT as patient_id, 
        initcap(trim(first_name)) as first_name,
        initcap(trim(last_name)) as last_name,
        try_cast(dob as date) as dob,
        case 
            when upper(trim(gender)) in ('M', 'Male') then 'Male'
            when upper(trim(gender)) in ('F', 'Female') then 'Female'
            else 'Unknown'
        end as gender,
        TRIM(city) AS city,
        TRIM(state) AS state,
        zip,
        insurance_type,
        coalesce(
            try_cast(registration_date as date),
            try_to_date(registration_date, 'MM/DD/YYYY')
        ) as registration_date,
        row_number() over(
            PARTITION BY TRIM(LOWER(first_name)), TRIM(LOWER(last_name)), dob
            ORDER BY patient_id
        ) AS dup_rank
    from raw.patients
)
SELECT patient_id, first_name, last_name, dob, gender, city, state, zip,
       insurance_type, registration_date
FROM cleaned
WHERE dup_rank = 1;


select * from staging.appointments;

-- New Providers table
create or replace table staging.providers as
select 
    provider_id :: int as provider_id,
    provider_name, specialty,
    department_id::INT AS department_id, 
    TRY_CAST(hire_date AS DATE) AS hire_date
FROM RAW.providers;

-- New Departments Table
create or replace table staging.departments as
select 
    department_id :: int as department_id,
    department_name, 
    location,
    cost_center
from RAW.departments;


-- build a mapping from every patient_id to its "canonical" (surviving) patient_id
CREATE OR REPLACE TABLE STAGING.patient_id_map AS
SELECT
    patient_id AS original_patient_id,
    MIN(patient_id) OVER (
        PARTITION BY TRIM(LOWER(first_name)), TRIM(LOWER(last_name)), dob
    ) AS canonical_patient_id
FROM RAW.patients;

-- New Appointments Table
CREATE OR REPLACE TABLE STAGING.appointments AS
WITH deduped AS (
    SELECT DISTINCT * FROM RAW.appointments
),
casted AS (
    SELECT
        appointment_id::INT AS appointment_id,
        patient_id::INT AS raw_patient_id,
        provider_id::INT AS provider_id,
        department_id::INT AS department_id,
        TRY_CAST(scheduled_date AS DATE) AS scheduled_date,
        scheduled_time,
        appointment_type,
        status,
        NULLIF(check_in_time, '') AS check_in_time,
        NULLIF(check_out_time, '') AS check_out_time,
        TRY_CAST(wait_time_minutes AS INT) AS wait_time_minutes
    FROM deduped
),
remapped AS (
    SELECT
        c.* EXCLUDE (raw_patient_id),
        COALESCE(m.canonical_patient_id, c.raw_patient_id) AS patient_id
    FROM casted c
    LEFT JOIN STAGING.patient_id_map m ON c.raw_patient_id = m.original_patient_id
)
SELECT
    r.*,
    CASE WHEN p.patient_id IS NULL THEN TRUE ELSE FALSE END AS is_orphaned_patient,
    CASE WHEN wait_time_minutes < 0 THEN NULL ELSE wait_time_minutes END AS wait_time_minutes_clean
FROM remapped r
LEFT JOIN STAGING.patients p ON r.patient_id = p.patient_id;
    

SELECT COUNT(*) FROM STAGING.patients;    
SELECT COUNT(*) FROM STAGING.appointments;     
SELECT COUNT(*) FROM STAGING.appointments WHERE is_orphaned_patient = TRUE;  
  