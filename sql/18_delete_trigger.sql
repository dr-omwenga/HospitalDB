-- =============================================================================
-- HospitalDB — DELETE Trigger on dbo.Appointments
-- File        : sql/18_delete_trigger.sql
-- Author      : Hospital Information Systems
-- Date        : 2026-05-07
-- Description :
--   Implements an INSTEAD OF DELETE trigger on dbo.Appointments that enforces
--   three business rules before any physical delete is allowed:
--
--     Rule 1 — ACTIVE GUARD
--       Appointments with Status = 'Scheduled' or 'In Progress' represent
--       live patient care commitments.  They must be formally cancelled
--       through the scheduling workflow before they can be purged.
--
--     Rule 2 — CLINICAL INTEGRITY
--       Any appointment that has an associated MedicalRecord cannot be
--       deleted.  Clinical records are legal documents; removing the
--       appointment that anchors them would orphan that data.
--
--     Rule 3 — FINANCIAL INTEGRITY
--       Any appointment linked to a Bill cannot be deleted.  The billing
--       record and its line items depend on the appointment row for audit
--       trail traceability.
--
--   Only appointments that satisfy ALL THREE rules (i.e., 'Cancelled' status,
--   no medical record, no bills) may be physically deleted.  When a delete
--   is permitted, a full snapshot of the deleted row is archived to
--   dbo.DeletedAppointments before the physical DELETE executes.
--
--   ─── OBJECTS CREATED ─────────────────────────────────────────────────────
--   dbo.DeletedAppointments          Archive table (created if absent)
--   dbo.trg_Appointments_Delete      INSTEAD OF DELETE trigger
--
--   ─── TEST CASES ──────────────────────────────────────────────────────────
--   TC-1  Blocked  — Delete Scheduled appointment         → Error 50000
--   TC-2  Blocked  — Delete appointment with MedicalRecord → Error 50000
--   TC-3  Blocked  — Delete appointment with linked Bills  → Error 50000
--   TC-4  Allowed  — Delete Cancelled appointment (clean)  → Row archived,
--                    then physically removed
-- =============================================================================

USE HospitalDB;

-- =============================================================================
-- SECTION 1: Archive table — dbo.DeletedAppointments
-- Captures a full snapshot of every appointment row that passes all rules
-- and is physically deleted.  The table is permanent so that purged records
-- remain discoverable for audit and compliance purposes.
-- =============================================================================

IF OBJECT_ID('dbo.DeletedAppointments', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.DeletedAppointments (
        DeletedAppointmentID  INT           NOT NULL IDENTITY(1,1),
        OriginalAppointmentID INT           NOT NULL,
        PatientID             INT           NOT NULL,
        DoctorID              INT           NOT NULL,
        CreatedByUserID       INT           NOT NULL,
        AppointmentDate       DATETIME      NOT NULL,
        Status                VARCHAR(30)   NOT NULL,
        Reason                VARCHAR(255)  NOT NULL,
        DeletedAt             DATETIME      NOT NULL
            CONSTRAINT DF_DeletedAppointments_DeletedAt DEFAULT (GETDATE()),
        DeletedBySessionUser  NVARCHAR(128) NOT NULL
            CONSTRAINT DF_DeletedAppointments_SessionUser DEFAULT (SYSTEM_USER),
        CONSTRAINT PK_DeletedAppointments PRIMARY KEY (DeletedAppointmentID)
    );
END;

-- =============================================================================
-- SECTION 2: INSTEAD OF DELETE trigger
--
-- INSTEAD OF fires in place of the DML statement, before foreign-key
-- constraints are checked.  The trigger either raises an error and exits
-- (leaving dbo.Appointments untouched) or archives the row(s) and issues
-- an explicit DELETE itself.
--
-- Multi-row safety: all three guards use EXISTS + JOIN against the logical
-- 'deleted' table, so they cover batch deletes where only some rows violate
-- a rule — the entire batch is rejected atomically.
-- =============================================================================
GO

CREATE OR ALTER TRIGGER dbo.trg_Appointments_Delete
ON dbo.Appointments
INSTEAD OF DELETE
AS
BEGIN
    SET NOCOUNT ON;

    -- -------------------------------------------------------------------------
    -- Rule 1: Active appointments cannot be deleted.
    -- -------------------------------------------------------------------------
    IF EXISTS (
        SELECT 1 FROM deleted
        WHERE Status IN ('Scheduled', 'In Progress')
    )
    BEGIN
        -- Build a comma-separated list of the violating IDs for the message.
        DECLARE @ActiveIDs NVARCHAR(400);
        SELECT @ActiveIDs = STUFF(
            (SELECT ', ' + CAST(AppointmentID AS VARCHAR(10))
             FROM deleted
             WHERE Status IN ('Scheduled', 'In Progress')
             FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(400)'),
            1, 2, '');

        DECLARE @Rule1Msg NVARCHAR(500);
        SET @Rule1Msg =
            'DELETE blocked by Rule 1 (Active Guard): appointment(s) '
            + @ActiveIDs
            + ' cannot be deleted because their Status is Scheduled or In Progress.'
            + ' Cancel the appointment(s) through the scheduling workflow first.';

        RAISERROR(@Rule1Msg, 16, 1);
        RETURN;
    END;

    -- -------------------------------------------------------------------------
    -- Rule 2: Appointments with an associated MedicalRecord cannot be deleted.
    -- -------------------------------------------------------------------------
    DECLARE @MedRecIDs NVARCHAR(400);
    SELECT @MedRecIDs = STUFF(
        (SELECT DISTINCT ', ' + CAST(d.AppointmentID AS VARCHAR(10))
         FROM deleted d
         INNER JOIN dbo.MedicalRecords mr ON mr.AppointmentID = d.AppointmentID
         FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(400)'),
        1, 2, '');

    IF @MedRecIDs IS NOT NULL
    BEGIN
        DECLARE @Rule2Msg NVARCHAR(500);
        SET @Rule2Msg =
            'DELETE blocked by Rule 2 (Clinical Integrity): appointment(s) '
            + @MedRecIDs
            + ' have one or more associated MedicalRecords.'
            + ' Clinical records must not be orphaned; remove the medical records before deleting the appointment.';

        RAISERROR(@Rule2Msg, 16, 1);
        RETURN;
    END;

    -- -------------------------------------------------------------------------
    -- Rule 3: Appointments linked to a Bill cannot be deleted.
    -- -------------------------------------------------------------------------
    DECLARE @BillIDs NVARCHAR(400);
    SELECT @BillIDs = STUFF(
        (SELECT DISTINCT ', ' + CAST(d.AppointmentID AS VARCHAR(10))
         FROM deleted d
         INNER JOIN dbo.Bills b ON b.AppointmentID = d.AppointmentID
         FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(400)'),
        1, 2, '');

    IF @BillIDs IS NOT NULL
    BEGIN
        DECLARE @Rule3Msg NVARCHAR(500);
        SET @Rule3Msg =
            'DELETE blocked by Rule 3 (Financial Integrity): appointment(s) '
            + @BillIDs
            + ' have one or more associated Bills.'
            + ' Void or reassign the bills before deleting the appointment.';

        RAISERROR(@Rule3Msg, 16, 1);
        RETURN;
    END;

    -- -------------------------------------------------------------------------
    -- All rules satisfied: archive snapshot, then physically delete.
    -- Both operations share the same implicit transaction so they succeed or
    -- fail together.
    -- -------------------------------------------------------------------------
    INSERT INTO dbo.DeletedAppointments
        (OriginalAppointmentID, PatientID, DoctorID, CreatedByUserID,
         AppointmentDate, Status, Reason, DeletedAt, DeletedBySessionUser)
    SELECT
        AppointmentID, PatientID, DoctorID, CreatedByUserID,
        AppointmentDate, Status, Reason, GETDATE(), SYSTEM_USER
    FROM deleted;

    DELETE FROM dbo.Appointments
    WHERE AppointmentID IN (SELECT AppointmentID FROM deleted);
END;
GO

-- =============================================================================
-- SECTION 3: Test Cases
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- TC-1: BLOCKED — attempt to delete a Scheduled appointment.
--       AppointmentID=29 has Status='Scheduled'.
--       Expected: Rule 1 fires, Error 50000, row still present in Appointments.
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN TRY
    DELETE FROM dbo.Appointments WHERE AppointmentID = 29;
    SELECT 'TC-1' AS Test, 'FAIL — delete succeeded; should have been blocked.' AS Result;
END TRY
BEGIN CATCH
    SELECT
        'TC-1'                                            AS Test,
        'Block: Scheduled appointment'                    AS Description,
        ERROR_NUMBER()                                    AS ErrNum,
        LEFT(ERROR_MESSAGE(), 120)                        AS ErrMsg,
        CASE WHEN ERROR_NUMBER() = 50000 THEN 'PASS'
             ELSE 'FAIL' END                              AS Result;
END CATCH;

-- Confirm row was NOT deleted
SELECT
    'TC-1 row check'        AS [Check],
    AppointmentID,
    Status,
    CASE WHEN AppointmentID = 29 THEN 'PASS — row still exists'
         ELSE 'FAIL' END    AS Result
FROM dbo.Appointments
WHERE AppointmentID = 29;

-- ─────────────────────────────────────────────────────────────────────────────
-- TC-2: BLOCKED — attempt to delete an appointment that has a MedicalRecord.
--       AppointmentID=1 is Completed and has a linked MedicalRecord.
--       Expected: Rule 2 fires, Error 50000, row still present.
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN TRY
    DELETE FROM dbo.Appointments WHERE AppointmentID = 1;
    SELECT 'TC-2' AS Test, 'FAIL — delete succeeded; should have been blocked.' AS Result;
END TRY
BEGIN CATCH
    SELECT
        'TC-2'                                            AS Test,
        'Block: appointment has MedicalRecord'            AS Description,
        ERROR_NUMBER()                                    AS ErrNum,
        LEFT(ERROR_MESSAGE(), 120)                        AS ErrMsg,
        CASE WHEN ERROR_NUMBER() = 50000 THEN 'PASS'
             ELSE 'FAIL' END                              AS Result;
END CATCH;

-- Confirm row was NOT deleted
SELECT
    'TC-2 row check'        AS [Check],
    AppointmentID,
    Status,
    CASE WHEN AppointmentID = 1 THEN 'PASS — row still exists'
         ELSE 'FAIL' END    AS Result
FROM dbo.Appointments
WHERE AppointmentID = 1;

-- ─────────────────────────────────────────────────────────────────────────────
-- TC-3: BLOCKED — attempt to delete a Cancelled appointment that has a Bill.
--       AppointmentID=9 is Cancelled but linked to at least one Bill.
--       Expected: Rule 3 fires, Error 50000, row still present.
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN TRY
    DELETE FROM dbo.Appointments WHERE AppointmentID = 9;
    SELECT 'TC-3' AS Test, 'FAIL — delete succeeded; should have been blocked.' AS Result;
END TRY
BEGIN CATCH
    SELECT
        'TC-3'                                            AS Test,
        'Block: Cancelled appointment has linked Bill'    AS Description,
        ERROR_NUMBER()                                    AS ErrNum,
        LEFT(ERROR_MESSAGE(), 120)                        AS ErrMsg,
        CASE WHEN ERROR_NUMBER() = 50000 THEN 'PASS'
             ELSE 'FAIL' END                              AS Result;
END CATCH;

-- Confirm row was NOT deleted
SELECT
    'TC-3 row check'        AS [Check],
    AppointmentID,
    Status,
    CASE WHEN AppointmentID = 9 THEN 'PASS — row still exists'
         ELSE 'FAIL' END    AS Result
FROM dbo.Appointments
WHERE AppointmentID = 9;

-- ─────────────────────────────────────────────────────────────────────────────
-- TC-4: ALLOWED — delete a Cancelled appointment with no MedicalRecord and
--       no Bills.
--
--       Setup: insert a minimal Cancelled appointment using existing FKs.
--       Then delete it.  Expected: row archived to dbo.DeletedAppointments,
--       no longer present in dbo.Appointments.
-- ─────────────────────────────────────────────────────────────────────────────

-- Setup: insert a clean Cancelled appointment for TC-4
DECLARE @TC4PatID INT; SELECT @TC4PatID = MIN(PatientID) FROM dbo.Patients;
DECLARE @TC4DocID INT; SELECT @TC4DocID = MIN(DoctorID)  FROM dbo.Doctors;
DECLARE @TC4UsrID INT; SELECT @TC4UsrID = MIN(UserID)    FROM dbo.Users WHERE IsActive = 1;
DECLARE @TC4PastDt DATETIME; SET @TC4PastDt = DATEADD(DAY, -3, GETDATE());

INSERT INTO dbo.Appointments
    (PatientID, DoctorID, CreatedByUserID, AppointmentDate, Status, Reason)
VALUES
    (@TC4PatID, @TC4DocID, @TC4UsrID, @TC4PastDt,
     'Cancelled', 'Trigger delete test — clean Cancelled, no children.');

DECLARE @TC4ID INT; SET @TC4ID = SCOPE_IDENTITY();
SELECT 'TC-4 setup' AS Step, @TC4ID AS NewAppointmentID, Status FROM dbo.Appointments WHERE AppointmentID = @TC4ID;

-- Execute the delete — trigger should allow it
BEGIN TRY
    DELETE FROM dbo.Appointments WHERE AppointmentID = @TC4ID;
    SELECT
        'TC-4'                                              AS Test,
        'Allow: Cancelled, no children'                     AS Description,
        @TC4ID                                              AS DeletedAppointmentID,
        'Delete statement completed without error'          AS Outcome,
        'PASS (pending archive verification below)'         AS Result;
END TRY
BEGIN CATCH
    SELECT
        'TC-4'                                              AS Test,
        'Allow: Cancelled, no children'                     AS Description,
        ERROR_NUMBER()                                      AS ErrNum,
        LEFT(ERROR_MESSAGE(), 120)                          AS ErrMsg,
        'FAIL — delete was blocked unexpectedly'            AS Result;
END CATCH;

-- Verify 1: row is gone from Appointments
SELECT
    'TC-4 still-in-Appointments'                                                AS [Check],
    CASE WHEN COUNT(*) = 0 THEN 'PASS — row removed from dbo.Appointments'
         ELSE 'FAIL — row still present' END                                    AS Result
FROM dbo.Appointments WHERE AppointmentID = @TC4ID;

-- Verify 2: snapshot exists in DeletedAppointments
SELECT
    'TC-4 archive check'            AS [Check],
    da.DeletedAppointmentID,
    da.OriginalAppointmentID,
    da.Status,
    LEFT(da.Reason, 60)             AS Reason,
    da.DeletedAt,
    da.DeletedBySessionUser,
    CASE WHEN da.OriginalAppointmentID = @TC4ID THEN 'PASS — row archived'
         ELSE 'FAIL' END            AS Result
FROM dbo.DeletedAppointments da
WHERE da.OriginalAppointmentID = @TC4ID;

-- =============================================================================
-- SECTION 4: Final state summary
-- =============================================================================
SELECT
    'Blocked tests still in Appointments'   AS Summary,
    COUNT(*)                                AS [RowCount]
FROM dbo.Appointments
WHERE AppointmentID IN (29, 1, 9);

SELECT
    'Total rows archived so far'            AS Summary,
    COUNT(*)                                AS [RowCount]
FROM dbo.DeletedAppointments;
