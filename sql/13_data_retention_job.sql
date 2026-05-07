-- =============================================================================
-- HospitalDB — Data Retention: SQL Server Agent Job
-- File        : sql/13_data_retention_job.sql
-- Author      : Hospital Information Systems
-- Date        : 2026-05-07
-- Description :
--   Creates a SQL Server Agent job that executes the data retention policy
--   automatically on the 1st day of every month at 02:00 AM.
--
--   The job calls dbo.usp_Retention_RunPolicy with default parameters:
--     • Cutoff = 5 years before the run date (computed inside the procedure)
--     • Batch size = 500 rows per table per phase
--
--   Job structure:
--     Job name  : HospitalDB Monthly Data Retention
--     Steps     : Step 1 — Dry-run check (returns counts, no changes)
--                 Step 2 — Live archive run
--     Schedule  : Monthly, 1st day of month, 02:00 AM
--     On failure: writes to Windows Application Event Log
--
--   Prerequisites:
--     • SQL Server Agent service must be running
--     • sql/11_data_retention_archive_tables.sql must have been executed
--     • sql/12_data_retention_procedures.sql must have been executed
--     • The account running the Agent job step must have:
--         SELECT, INSERT, DELETE on HospitalDB.dbo.* and HospitalDB.Archive.*
--         INSERT on HospitalDB.dbo.RetentionJobLog
--         INSERT on HospitalDB.dbo.ErrorLogs
--
--   Safe to re-run: the script drops the existing job and schedule
--   (if present) before recreating them.
-- =============================================================================

USE msdb;
GO

-- =============================================================================
-- Clean up existing job and schedule if they exist
-- =============================================================================
IF EXISTS (
    SELECT 1 FROM msdb.dbo.sysjobs
    WHERE  name = 'HospitalDB Monthly Data Retention'
)
BEGIN
    EXEC msdb.dbo.sp_delete_job
        @job_name              = 'HospitalDB Monthly Data Retention',
        @delete_unused_schedule = 1;
END
GO

-- =============================================================================
-- Create the job
-- =============================================================================
EXEC msdb.dbo.sp_add_job
    @job_name               = 'HospitalDB Monthly Data Retention',
    @description            = 'Moves records older than 5 years from active HospitalDB tables (Appointments, Bills, Payments, MedicalRecords, Prescriptions, LabOrders, AuditLogs, ErrorLogs) into Archive.* tables. Runs on the 1st of each month at 02:00 AM.',
    @category_name          = 'Database Maintenance',
    @enabled                = 1,
    -- Write to Windows Application Event Log on job failure
    @notify_level_eventlog  = 2,
    @owner_login_name       = N'sa';
GO

-- =============================================================================
-- Step 1 — Dry-run preview
-- Logs projected counts to the SQL Agent job output without making changes.
-- On success, proceeds to Step 2 automatically.
-- =============================================================================
EXEC msdb.dbo.sp_add_jobstep
    @job_name           = 'HospitalDB Monthly Data Retention',
    @step_name          = '1 - Dry-Run Preview',
    @subsystem          = 'TSQL',
    @database_name      = 'HospitalDB',
    @command            = N'
-- Preview rows eligible for archiving this month (no changes made).
-- Results are captured in the SQL Agent job output file.
EXEC dbo.usp_Retention_RunPolicy
    @DryRun    = 1,
    @BatchSize = 500;
',
    @on_success_action  = 3,   -- Go to next step on success
    @on_fail_action     = 2;   -- Quit with failure if dry-run errors
GO

-- =============================================================================
-- Step 2 — Live archive run
-- =============================================================================
EXEC msdb.dbo.sp_add_jobstep
    @job_name           = 'HospitalDB Monthly Data Retention',
    @step_name          = '2 - Archive Records',
    @subsystem          = 'TSQL',
    @database_name      = 'HospitalDB',
    @command            = N'
-- Execute the retention policy.
-- Default cutoff = 5 years ago; batch size = 500 rows per phase.
EXEC dbo.usp_Retention_RunPolicy
    @BatchSize = 500;
',
    @on_success_action  = 1,   -- Quit with success
    @on_fail_action     = 2;   -- Quit with failure (logged to ErrorLogs + EventLog)
GO

-- =============================================================================
-- Set the starting step to Step 1
-- =============================================================================
EXEC msdb.dbo.sp_update_job
    @job_name       = 'HospitalDB Monthly Data Retention',
    @start_step_id  = 1;
GO

-- =============================================================================
-- Create the monthly schedule
--   @freq_type        = 16   Monthly
--   @freq_interval    = 1    1st day of the month
--   @freq_subday_type = 1    At a specific time (no sub-day repetition)
--   @active_start_time= 20000  02:00:00 AM  (HHMMSS as integer: 020000 = 20000)
-- =============================================================================
EXEC msdb.dbo.sp_add_schedule
    @schedule_name          = 'HospitalDB Retention Monthly 1st 0200',
    @enabled                = 1,
    @freq_type              = 16,
    @freq_interval          = 1,
    @freq_subday_type       = 1,
    @freq_subday_interval   = 0,
    @active_start_time      = 20000;
GO

-- Attach the schedule to the job
EXEC msdb.dbo.sp_attach_schedule
    @job_name      = 'HospitalDB Monthly Data Retention',
    @schedule_name = 'HospitalDB Retention Monthly 1st 0200';
GO

-- Register the job on the local server so the Agent can execute it
EXEC msdb.dbo.sp_add_jobserver
    @job_name    = 'HospitalDB Monthly Data Retention',
    @server_name = N'(local)';
GO

-- =============================================================================
-- Verification Queries
-- Run these after creating the job to confirm correct configuration.
-- =============================================================================

-- Confirm the job exists and is enabled
SELECT
    j.name                              AS JobName,
    j.enabled                           AS IsEnabled,
    j.description                       AS Description,
    SUSER_SNAME(j.owner_sid)            AS Owner,
    j.notify_level_eventlog             AS EventLogNotifyLevel
FROM msdb.dbo.sysjobs j
WHERE j.name = 'HospitalDB Monthly Data Retention';
GO

-- List all steps for the job
SELECT
    js.step_id                          AS StepNumber,
    js.step_name                        AS StepName,
    js.subsystem                        AS Subsystem,
    js.database_name                    AS Database_,
    js.on_success_action                AS OnSuccess,
    js.on_fail_action                   AS OnFail
FROM msdb.dbo.sysjobs     j
JOIN msdb.dbo.sysjobsteps js ON js.job_id = j.job_id
WHERE j.name = 'HospitalDB Monthly Data Retention'
ORDER BY js.step_id;
GO

-- Confirm the schedule
SELECT
    s.name                              AS ScheduleName,
    s.enabled                           AS IsEnabled,
    s.freq_type                         AS FreqType,       -- 16 = Monthly
    s.freq_interval                     AS FreqInterval,   -- 1 = 1st of month
    s.active_start_time                 AS StartTime       -- 20000 = 02:00:00 AM
FROM msdb.dbo.sysschedules         s
JOIN msdb.dbo.sysjobschedules      js ON js.schedule_id = s.schedule_id
JOIN msdb.dbo.sysjobs               j ON j.job_id       = js.job_id
WHERE j.name = 'HospitalDB Monthly Data Retention';
GO

-- =============================================================================
-- Manual Execution Options
-- Use these in SSMS to test the job or run it outside the schedule.
-- =============================================================================

-- Option A: Preview only — no data movement
-- USE HospitalDB;
-- EXEC dbo.usp_Retention_RunPolicy @DryRun = 1;
-- GO

-- Option B: Run the full policy immediately (live)
-- USE HospitalDB;
-- EXEC dbo.usp_Retention_RunPolicy;
-- GO

-- Option C: Start the Agent job immediately via msdb
-- EXEC msdb.dbo.sp_start_job @job_name = 'HospitalDB Monthly Data Retention';
-- GO

-- Option D: View the last 10 job executions
-- SELECT TOP 10
--     j.name                          AS JobName,
--     h.run_date,
--     h.run_time,
--     h.run_duration,
--     CASE h.run_status
--         WHEN 0 THEN 'Failed'
--         WHEN 1 THEN 'Succeeded'
--         WHEN 2 THEN 'Retry'
--         WHEN 3 THEN 'Cancelled'
--         WHEN 4 THEN 'In Progress'
--     END                             AS RunStatus,
--     h.message
-- FROM msdb.dbo.sysjobs         j
-- JOIN msdb.dbo.sysjobhistory   h ON h.job_id = j.job_id
-- WHERE j.name = 'HospitalDB Monthly Data Retention'
--   AND h.step_id > 0    -- exclude the header row (step_id = 0)
-- ORDER BY h.run_date DESC, h.run_time DESC;
-- GO

-- Option E: View the application-level retention log
-- USE HospitalDB;
-- SELECT TOP 50 * FROM dbo.RetentionJobLog ORDER BY LogID DESC;
-- GO

-- Option F: Verify active vs. archived counts after a run
-- USE HospitalDB;
-- EXEC dbo.usp_Retention_GetStats;
-- GO
