-- =============================================================================
-- HospitalDB — UPDATE Trigger on dbo.Appointments
-- File        : sql/20_update_trigger.sql
-- Author      : Hospital Information Systems
-- Date        : 2026-05-07
-- Description :
--   An AFTER UPDATE trigger on dbo.Appointments that enforces four business
--   rules at the database layer and produces a full audit trail for every
--   approved change, regardless of which application path issues the UPDATE.
--
--   ─── RULES ───────────────────────────────────────────────────────────────
--
--   Rule 1 — TERMINAL STATE GUARD (reject on failure)
--     Once an appointment's Status reaches 'Completed', 'Cancelled', or
--     'No-Show', the record is frozen.  Any further UPDATE is rejected
--     atomically: the statement is rolled back and an error is raised.
--     To make amendments, staff must cancel and create a new appointment.
--
--   Rule 2 — PATIENT / DOCTOR IMMUTABILITY (reject on failure)
--     PatientID and DoctorID are set at creation time and cannot be changed.
--     An appointment is a contract between a specific patient and a specific
--     doctor.  Reassigning either party requires cancelling and rebooking.
--
--   Rule 3 — STATUS TRANSITION VALIDATION (reject on failure)
--     Status changes must follow the appointment lifecycle finite state machine:
--
--       Scheduled  ──► In Progress   (appointment has started)
--       Scheduled  ──► Cancelled     (appointment cancelled before start)
--       Scheduled  ──► No-Show       (patient did not attend)
--       In Progress──► Completed     (appointment concluded successfully)
--       In Progress──► Cancelled     (appointment interrupted and cancelled)
--       In Progress──► No-Show       (patient left before completion)
--
--     Any other transition (e.g. Scheduled→Completed, Completed→Scheduled,
--     In Progress→Scheduled) is invalid and rejected atomically.
--
--   Rule 4 — APPOINTMENT DATE ANTI-BACKDATING (reject on failure)
--     A Scheduled appointment cannot be rescheduled to a date in the past.
--     AppointmentDate must remain today or in the future for all rows whose
--     resulting Status is 'Scheduled'.
--
--   Rule 5 — AUDIT LOGGING (track changes)
--     Every UPDATE that passes all four guards and actually changes at least
--     one tracked column (Status, AppointmentDate, or Reason) is recorded in
--     dbo.AuditLogs.  Old and new values are captured in a structured string
--     so the full change history of any appointment can be queried.
--
--   ─── PATTERN ─────────────────────────────────────────────────────────────
--   AFTER UPDATE is used so that both 'inserted' (new values) and 'deleted'
--   (old values) are populated, enabling side-by-side comparison.
--   Validation failures use ROLLBACK TRANSACTION + RAISERROR + RETURN,
--   rolling back the UPDATE atomically before the error propagates to the
--   caller's CATCH block.
--   Rules are evaluated in priority order: terminal guard first (cheap EXISTS
--   on deleted), then immutability, then FSM, then date range.
--
--   ─── OBJECTS CREATED ─────────────────────────────────────────────────────
--   dbo.trg_Appointments_AfterUpdate   AFTER UPDATE trigger on dbo.Appointments
--
--   ─── TEST CASES ──────────────────────────────────────────────────────────
--   TC-1  Valid reschedule (future date, Status stays Scheduled)   → approved, audit logged
--   TC-2  Valid transition  Scheduled → In Progress                → approved, audit logged
--   TC-3  Valid transition  In Progress → Completed                → approved, audit logged
--   TC-4  Update a Completed appointment (terminal state)          → rejected, Error 50000
--   TC-5  Change DoctorID on Scheduled appointment                 → rejected, Error 50000
--   TC-6  Invalid transition Scheduled → Completed (skip FSM step) → rejected, Error 50000
--   TC-7  Reschedule to past date on Scheduled appointment         → rejected, Error 50000
-- =============================================================================

USE HospitalDB;
GO

-- =============================================================================
-- SECTION 1: AFTER UPDATE trigger
-- =============================================================================

CREATE OR ALTER TRIGGER dbo.trg_Appointments_AfterUpdate
ON dbo.Appointments
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Working variables declared at trigger scope
    DECLARE @BlockedIDs  NVARCHAR(400);
    DECLARE @Msg         NVARCHAR(500);
    DECLARE @AuditUserID INT;

    -- -------------------------------------------------------------------------
    -- Rule 1: Terminal state guard.
    -- 'deleted' holds the row values BEFORE the UPDATE.
    -- If any pre-update Status was terminal, the record was frozen — reject.
    -- -------------------------------------------------------------------------
    IF EXISTS (
        SELECT 1 FROM deleted
        WHERE Status IN ('Completed', 'Cancelled', 'No-Show')
    )
    BEGIN
        SELECT @BlockedIDs = STUFF(
            (SELECT ', ' + CAST(AppointmentID AS VARCHAR(10))
             FROM deleted
             WHERE Status IN ('Completed', 'Cancelled', 'No-Show')
             FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(400)'),
            1, 2, '');

        SET @Msg =
            'UPDATE blocked by Rule 1 (Terminal State Guard): Appointment(s) ['
            + @BlockedIDs
            + '] are in a terminal state (Completed, Cancelled, or No-Show) and cannot be modified.'
            + ' Cancel and re-book to make changes.';

        ROLLBACK TRANSACTION;
        RAISERROR(@Msg, 16, 1);
        RETURN;
    END;

    -- -------------------------------------------------------------------------
    -- Rule 2: PatientID and DoctorID immutability.
    -- Compare inserted (new) vs deleted (old) values for both FK columns.
    -- -------------------------------------------------------------------------
    IF EXISTS (
        SELECT 1
        FROM inserted i
        JOIN deleted  d ON d.AppointmentID = i.AppointmentID
        WHERE i.PatientID <> d.PatientID
           OR i.DoctorID  <> d.DoctorID
    )
    BEGIN
        SELECT @BlockedIDs = STUFF(
            (SELECT ', ' + CAST(i.AppointmentID AS VARCHAR(10))
             FROM inserted i
             JOIN deleted  d ON d.AppointmentID = i.AppointmentID
             WHERE i.PatientID <> d.PatientID
                OR i.DoctorID  <> d.DoctorID
             FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(400)'),
            1, 2, '');

        SET @Msg =
            'UPDATE blocked by Rule 2 (Patient/Doctor Immutability): Appointment(s) ['
            + @BlockedIDs
            + '] — PatientID and DoctorID cannot be changed after the appointment is created.'
            + ' Cancel this appointment and create a new one to assign a different patient or doctor.';

        ROLLBACK TRANSACTION;
        RAISERROR(@Msg, 16, 1);
        RETURN;
    END;

    -- -------------------------------------------------------------------------
    -- Rule 3: Status transition finite state machine.
    -- Valid transitions (from → to):
    --   Scheduled   → In Progress | Cancelled | No-Show
    --   In Progress → Completed   | Cancelled | No-Show
    -- Rows where Status did not change (i.Status = d.Status) are excluded from
    -- this check — no-op status updates are allowed.
    -- -------------------------------------------------------------------------
    IF EXISTS (
        SELECT 1
        FROM inserted i
        JOIN deleted  d ON d.AppointmentID = i.AppointmentID
        WHERE i.Status <> d.Status
          AND NOT (
                  (d.Status = 'Scheduled'   AND i.Status IN ('In Progress', 'Cancelled', 'No-Show'))
               OR (d.Status = 'In Progress' AND i.Status IN ('Completed',   'Cancelled', 'No-Show'))
              )
    )
    BEGIN
        SELECT @BlockedIDs = STUFF(
            (SELECT ', ' + CAST(i.AppointmentID AS VARCHAR(10))
                   + ' (' + d.Status + ' → ' + i.Status + ')'
             FROM inserted i
             JOIN deleted  d ON d.AppointmentID = i.AppointmentID
             WHERE i.Status <> d.Status
               AND NOT (
                       (d.Status = 'Scheduled'   AND i.Status IN ('In Progress', 'Cancelled', 'No-Show'))
                    OR (d.Status = 'In Progress' AND i.Status IN ('Completed',   'Cancelled', 'No-Show'))
                   )
             FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(400)'),
            1, 2, '');

        SET @Msg =
            'UPDATE blocked by Rule 3 (Status Transition): Appointment(s) ['
            + @BlockedIDs
            + '] — invalid status transition. Valid paths: '
            + 'Scheduled → In Progress / Cancelled / No-Show; '
            + 'In Progress → Completed / Cancelled / No-Show.';

        ROLLBACK TRANSACTION;
        RAISERROR(@Msg, 16, 1);
        RETURN;
    END;

    -- -------------------------------------------------------------------------
    -- Rule 4: Anti-backdating for Scheduled appointments.
    -- After the UPDATE, any row still in 'Scheduled' status must have an
    -- AppointmentDate on or after today.
    -- -------------------------------------------------------------------------
    IF EXISTS (
        SELECT 1
        FROM inserted i
        JOIN deleted  d ON d.AppointmentID = i.AppointmentID
        WHERE i.Status = 'Scheduled'
          AND CAST(i.AppointmentDate AS DATE) < CAST(GETDATE() AS DATE)
    )
    BEGIN
        SELECT @BlockedIDs = STUFF(
            (SELECT ', ' + CAST(i.AppointmentID AS VARCHAR(10))
             FROM inserted i
             JOIN deleted  d ON d.AppointmentID = i.AppointmentID
             WHERE i.Status = 'Scheduled'
               AND CAST(i.AppointmentDate AS DATE) < CAST(GETDATE() AS DATE)
             FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(400)'),
            1, 2, '');

        SET @Msg =
            'UPDATE blocked by Rule 4 (Anti-Backdating): Appointment(s) ['
            + @BlockedIDs
            + '] — a Scheduled appointment cannot be rescheduled to a past date.'
            + ' AppointmentDate must be today or in the future.';

        ROLLBACK TRANSACTION;
        RAISERROR(@Msg, 16, 1);
        RETURN;
    END;

    -- -------------------------------------------------------------------------
    -- Rule 5: Audit logging.
    -- Record every approved UPDATE where at least one tracked column changed.
    -- Joins inserted (new) and deleted (old) to capture both sides of the diff.
    -- Resolves PerformedByUserID to the lowest active system user.
    -- In production, SESSION_CONTEXT(N'UserID') would carry the app user.
    -- -------------------------------------------------------------------------
    SELECT @AuditUserID = MIN(UserID) FROM dbo.Users WHERE IsActive = 1;

    INSERT INTO dbo.AuditLogs
        (PerformedByUserID, TableName, ActionType, ActionDate, OldValue, NewValue)
    SELECT
        @AuditUserID,
        'Appointments',
        'UPDATE',
        GETDATE(),
        'AppointmentID='    + CAST(d.AppointmentID AS VARCHAR(10))
        + '; PatientID='    + CAST(d.PatientID     AS VARCHAR(10))
        + '; DoctorID='     + CAST(d.DoctorID      AS VARCHAR(10))
        + '; Status='       + d.Status
        + '; ApptDate='     + CONVERT(VARCHAR(20), d.AppointmentDate, 120)
        + '; Reason='       + d.Reason,
        'AppointmentID='    + CAST(i.AppointmentID AS VARCHAR(10))
        + '; PatientID='    + CAST(i.PatientID     AS VARCHAR(10))
        + '; DoctorID='     + CAST(i.DoctorID      AS VARCHAR(10))
        + '; Status='       + i.Status
        + '; ApptDate='     + CONVERT(VARCHAR(20), i.AppointmentDate, 120)
        + '; Reason='       + i.Reason
    FROM inserted i
    JOIN deleted  d ON d.AppointmentID = i.AppointmentID
    WHERE i.Status          <> d.Status
       OR i.AppointmentDate <> d.AppointmentDate
       OR i.Reason          <> d.Reason;
END;
GO

-- =============================================================================
-- SECTION 2: Test Cases
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- SETUP: Insert a fresh test appointment for the TC-1/TC-2/TC-3 progression.
-- Persist its AppointmentID in a session-scoped temp table so subsequent
-- batches can refer to the same row without knowing the IDENTITY value.
-- ─────────────────────────────────────────────────────────────────────────────
IF OBJECT_ID('tempdb..#UpdateTriggerTest') IS NOT NULL DROP TABLE #UpdateTriggerTest;
CREATE TABLE #UpdateTriggerTest (TestApptID INT);

INSERT INTO dbo.Appointments
    (PatientID, DoctorID, CreatedByUserID, AppointmentDate, Status, Reason)
VALUES
    (1, 1, 1,
     DATEADD(DAY, 7, CAST(GETDATE() AS DATE)),
     'Scheduled',
     'UPDATE trigger test appointment — TC-1 through TC-3.');

DECLARE @TA INT = SCOPE_IDENTITY();
INSERT INTO #UpdateTriggerTest VALUES (@TA);

-- Confirm setup
SELECT 'Setup' AS Phase, AppointmentID, Status, CAST(AppointmentDate AS DATE) AS ApptDate
FROM dbo.Appointments WHERE AppointmentID = @TA;
GO

-- ── TC-1: VALID RESCHEDULE ────────────────────────────────────────────────────
-- Move AppointmentDate forward from +7 to +14 days.
-- Status stays 'Scheduled'. Rule 4 (anti-backdating) must NOT fire.
-- Expected: UPDATE succeeds; date is updated; AuditLog entry written.
DECLARE @TA INT; SELECT @TA = TestApptID FROM #UpdateTriggerTest;

UPDATE dbo.Appointments
SET
    AppointmentDate = DATEADD(DAY, 14, CAST(GETDATE() AS DATE)),
    Reason          = 'Rescheduled for patient convenience — moved from T+7 to T+14.'
WHERE AppointmentID = @TA;

SELECT
    'TC-1'                                                              AS Test,
    'Valid reschedule to future date (Status stays Scheduled)'          AS Description,
    AppointmentID,
    Status,
    CAST(AppointmentDate AS DATE)                                       AS NewDate,
    CAST(DATEADD(DAY, 14, CAST(GETDATE() AS DATE)) AS DATE)            AS ExpectedDate,
    CASE
        WHEN Status = 'Scheduled'
         AND CAST(AppointmentDate AS DATE) = CAST(DATEADD(DAY, 14, CAST(GETDATE() AS DATE)) AS DATE)
        THEN 'PASS'
        ELSE 'FAIL'
    END                                                                 AS Result
FROM dbo.Appointments WHERE AppointmentID = @TA;
GO

-- ── TC-2: VALID TRANSITION — Scheduled → In Progress ─────────────────────────
-- The appointment has started; advance Status through the FSM.
-- Expected: UPDATE succeeds; Status = 'In Progress'; AuditLog entry written.
DECLARE @TA INT; SELECT @TA = TestApptID FROM #UpdateTriggerTest;

UPDATE dbo.Appointments
SET
    Status = 'In Progress',
    Reason = 'Patient arrived; appointment in progress.'
WHERE AppointmentID = @TA;

SELECT
    'TC-2'                                                              AS Test,
    'Valid transition: Scheduled → In Progress'                         AS Description,
    AppointmentID,
    Status,
    CASE WHEN Status = 'In Progress' THEN 'PASS' ELSE 'FAIL' END       AS Result
FROM dbo.Appointments WHERE AppointmentID = @TA;
GO

-- ── TC-3: VALID TRANSITION — In Progress → Completed ─────────────────────────
-- The appointment has concluded; advance to the terminal Completed state.
-- Expected: UPDATE succeeds; Status = 'Completed'; verify 3 AuditLog entries
-- have been written for the test appointment (TC-1 + TC-2 + TC-3).
DECLARE @TA INT; SELECT @TA = TestApptID FROM #UpdateTriggerTest;

UPDATE dbo.Appointments
SET
    Status = 'Completed',
    Reason = 'Appointment completed successfully. Follow-up in 6 weeks.'
WHERE AppointmentID = @TA;

SELECT
    'TC-3'                                                              AS Test,
    'Valid transition: In Progress → Completed'                         AS Description,
    CASE WHEN Status = 'Completed' THEN 'PASS' ELSE 'FAIL' END         AS FsmResult,
    'AuditLog entries for test appointment'                             AS AuditCheck,
    (SELECT COUNT(*) FROM dbo.AuditLogs
     WHERE TableName  = 'Appointments'
       AND ActionType = 'UPDATE'
       AND ActionDate >= CAST(GETDATE() AS DATE)
       AND NewValue LIKE 'AppointmentID=' + CAST(@TA AS VARCHAR(10)) + '%') AS AuditCount,
    CASE WHEN (SELECT COUNT(*) FROM dbo.AuditLogs
               WHERE TableName = 'Appointments' AND ActionType = 'UPDATE'
                 AND ActionDate >= CAST(GETDATE() AS DATE)
                 AND NewValue LIKE 'AppointmentID=' + CAST(@TA AS VARCHAR(10)) + '%') >= 3
         THEN 'PASS' ELSE 'FAIL' END                                   AS AuditResult
FROM dbo.Appointments WHERE AppointmentID = @TA;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- TC-4: REJECTED — Terminal state guard (Rule 1).
-- Attempt to change the Reason on AppointmentID=1 (Status='Completed').
-- Expected: Rule 1 fires, UPDATE rolled back, Error 50000.
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN TRY
    UPDATE dbo.Appointments
    SET    Reason = 'Attempting to amend a completed record — should be blocked.'
    WHERE  AppointmentID = 1;   -- Completed in seed data

    SELECT 'TC-4' AS Test, 'FAIL — update should have been rejected' AS Result;
END TRY
BEGIN CATCH
    SELECT
        'TC-4'                                                          AS Test,
        'Block: update Completed appointment (Rule 1)'                  AS Description,
        ERROR_NUMBER()                                                  AS ErrNum,
        LEFT(ERROR_MESSAGE(), 130)                                      AS ErrMsg,
        CASE WHEN ERROR_NUMBER() = 50000 THEN 'PASS' ELSE 'FAIL' END   AS Result;
END CATCH;

-- Confirm the Reason on AppointmentID=1 was NOT changed (rollback verified)
SELECT
    'TC-4 rollback check'                                               AS [Check],
    CASE WHEN Reason NOT LIKE '%attempting to amend%'
         THEN 'PASS — record unchanged'
         ELSE 'FAIL — reason was modified despite rollback' END         AS Result
FROM dbo.Appointments WHERE AppointmentID = 1;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- TC-5: REJECTED — Patient/Doctor immutability (Rule 2).
-- Attempt to reassign AppointmentID=29 (Scheduled, DoctorID=27) to DoctorID=1.
-- Expected: Rule 2 fires, UPDATE rolled back, Error 50000.
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN TRY
    UPDATE dbo.Appointments
    SET    DoctorID = 1   -- original is 27
    WHERE  AppointmentID = 29;  -- Scheduled

    SELECT 'TC-5' AS Test, 'FAIL — update should have been rejected' AS Result;
END TRY
BEGIN CATCH
    SELECT
        'TC-5'                                                          AS Test,
        'Block: DoctorID change on Scheduled appointment (Rule 2)'      AS Description,
        ERROR_NUMBER()                                                  AS ErrNum,
        LEFT(ERROR_MESSAGE(), 130)                                      AS ErrMsg,
        CASE WHEN ERROR_NUMBER() = 50000 THEN 'PASS' ELSE 'FAIL' END   AS Result;
END CATCH;

-- Confirm DoctorID=27 still on AppointmentID=29 (rollback verified)
SELECT
    'TC-5 rollback check'                                               AS [Check],
    DoctorID,
    CASE WHEN DoctorID = 27 THEN 'PASS — DoctorID unchanged'
         ELSE 'FAIL — DoctorID was modified despite rollback' END       AS Result
FROM dbo.Appointments WHERE AppointmentID = 29;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- TC-6: REJECTED — Invalid FSM transition (Rule 3).
-- Attempt to jump AppointmentID=30 (Scheduled) directly to 'Completed',
-- skipping the required 'In Progress' intermediate state.
-- Expected: Rule 3 fires, UPDATE rolled back, Error 50000.
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN TRY
    UPDATE dbo.Appointments
    SET    Status = 'Completed'   -- invalid: Scheduled → Completed
    WHERE  AppointmentID = 30;   -- Scheduled in seed data

    SELECT 'TC-6' AS Test, 'FAIL — update should have been rejected' AS Result;
END TRY
BEGIN CATCH
    SELECT
        'TC-6'                                                          AS Test,
        'Block: Scheduled → Completed (invalid FSM skip, Rule 3)'       AS Description,
        ERROR_NUMBER()                                                  AS ErrNum,
        LEFT(ERROR_MESSAGE(), 130)                                      AS ErrMsg,
        CASE WHEN ERROR_NUMBER() = 50000 THEN 'PASS' ELSE 'FAIL' END   AS Result;
END CATCH;

-- Confirm Status is still 'Scheduled' on AppointmentID=30
SELECT
    'TC-6 rollback check'                                               AS [Check],
    Status,
    CASE WHEN Status = 'Scheduled' THEN 'PASS — Status unchanged'
         ELSE 'FAIL — Status was changed despite rollback' END          AS Result
FROM dbo.Appointments WHERE AppointmentID = 30;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- TC-7: REJECTED — Anti-backdating (Rule 4).
-- Attempt to reschedule AppointmentID=29 (Scheduled) to year 2000.
-- Expected: Rule 4 fires, UPDATE rolled back, Error 50000.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @OrigDate DATETIME;
SELECT @OrigDate = AppointmentDate FROM dbo.Appointments WHERE AppointmentID = 29;

BEGIN TRY
    UPDATE dbo.Appointments
    SET    AppointmentDate = '2000-01-01 09:00:00'   -- far in the past
    WHERE  AppointmentID  = 29;  -- Scheduled

    SELECT 'TC-7' AS Test, 'FAIL — update should have been rejected' AS Result;
END TRY
BEGIN CATCH
    SELECT
        'TC-7'                                                          AS Test,
        'Block: reschedule Scheduled appointment to past date (Rule 4)'  AS Description,
        ERROR_NUMBER()                                                  AS ErrNum,
        LEFT(ERROR_MESSAGE(), 130)                                      AS ErrMsg,
        CASE WHEN ERROR_NUMBER() = 50000 THEN 'PASS' ELSE 'FAIL' END   AS Result;
END CATCH;

-- Confirm AppointmentDate was not changed (rollback verified)
SELECT
    'TC-7 rollback check'                                               AS [Check],
    CAST(AppointmentDate AS DATE)                                       AS CurrentDate,
    CAST(@OrigDate       AS DATE)                                       AS OriginalDate,
    CASE WHEN CAST(AppointmentDate AS DATE) = CAST(@OrigDate AS DATE)
         THEN 'PASS — date unchanged'
         ELSE 'FAIL — date was modified despite rollback' END           AS Result
FROM dbo.Appointments WHERE AppointmentID = 29;
GO

-- =============================================================================
-- SECTION 3: Final audit and integrity verification
-- =============================================================================

-- Count AuditLog UPDATE entries for Appointments written today
SELECT
    'Audit: Appointments UPDATE entries today'                          AS Summary,
    COUNT(*)                                                            AS TotalEntries,
    'INFO'                                                              AS Result
FROM dbo.AuditLogs
WHERE TableName  = 'Appointments'
  AND ActionType = 'UPDATE'
  AND ActionDate >= CAST(GETDATE() AS DATE);

-- Verify all Scheduled appointments still have future dates (Rule 4 integrity)
SELECT
    'Integrity: No Scheduled appt backdated today'                      AS Summary,
    COUNT(*)                                                            AS ViolatingRows,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END                 AS Result
FROM dbo.Appointments
WHERE Status = 'Scheduled'
  AND CAST(AppointmentDate AS DATE) < CAST(GETDATE() AS DATE);

-- Confirm TC-4 through TC-7 left no unintended state changes
SELECT
    'Integrity: Terminal-state appointments unmodified'                 AS Summary,
    AppointmentID,
    Status,
    CASE WHEN Status IN ('Completed', 'Cancelled', 'No-Show')
         THEN 'OK (terminal — unchanged)' ELSE 'CHECK' END             AS [State]
FROM dbo.Appointments
WHERE AppointmentID IN (1, 29, 30)
ORDER BY AppointmentID;
GO
