-- =============================================================================
-- HospitalDB — Nested Stored Procedures
-- File        : sql/17_nested_procedures.sql
-- Author      : Hospital Information Systems
-- Date        : 2026-05-07
-- Description :
--   Two stored procedures that demonstrate the SQL Server nested-procedure
--   pattern: an inner (helper) procedure that returns a numeric status code
--   via RETURN, and an outer (caller) procedure that invokes the inner with
--   EXEC @StatusVar = dbo.inner_proc ... and explicitly evaluates every
--   possible return value before deciding how to proceed.
--
--   ─── INNER ───────────────────────────────────────────────────────────────
--   dbo.usp_Patient_CheckEligibility
--     Validates a patient against three eligibility rules:
--       Rule E-1  Patient must exist in dbo.Patients.
--       Rule E-2  Patient must have at least one non-expired insurance policy
--                 (PatientInsurancePolicies.ExpiryDate >= GETDATE() AS DATE).
--       Rule E-3  Patient's total outstanding balance across all unpaid /
--                 partially-paid bills must not exceed @MaxOutstandingBalance.
--
--     Returns a numeric status code to its caller:
--       0  — Eligible.  All three rules satisfied.
--       1  — Patient not found (PatientID absent from dbo.Patients).
--       2  — No valid insurance.  Patient has no policy with ExpiryDate in
--              the future (or today).
--       3  — Balance threshold exceeded.  Outstanding balance >=
--              @MaxOutstandingBalance.
--      -1  — Unexpected internal error (caught by TRY/CATCH).
--
--     Also sets an OUTPUT parameter @EligibilityMessage so the caller has a
--     human-readable explanation it can include in its own error message or
--     audit log without needing to re-derive the reason.
--
--   ─── OUTER ───────────────────────────────────────────────────────────────
--   dbo.usp_Appointment_ScheduleWithEligibilityCheck
--     Schedules a new appointment for a patient, but only after calling the
--     inner procedure and fully evaluating its return status:
--
--       @Status = 0  → All checks passed.  Continue to INSERT Appointment
--                       inside a transaction and write the AuditLog entry.
--       @Status = 1  → THROW error 52001 (patient not found).
--       @Status = 2  → If @OverrideInsurance = 1 (self-pay override), log a
--                       warning in ErrorLogs and continue.
--                       If @OverrideInsurance = 0, THROW error 52002.
--       @Status = 3  → THROW error 52003 (outstanding balance too high).
--       @Status = -1 → THROW error 52004 (eligibility check internal error).
--       Any other    → THROW error 52005 (unexpected status — defensive guard).
--
--     Parameters:
--       @PatientID             INT
--       @DoctorID              INT
--       @CreatedByUserID       INT
--       @AppointmentDate       DATETIME      — must be future
--       @Reason                VARCHAR(255)
--       @PerformedByUserID     INT
--       @MaxOutstandingBalance DECIMAL(10,2) = 1000.00   — passed to inner
--       @OverrideInsurance     BIT           = 0
--              Set to 1 to allow scheduling for patients without active
--              insurance (e.g., self-pay admissions).  The override is
--              recorded in ErrorLogs and AuditLogs.
--
--   Error codes reserved for this file: 52001–52010
--   Inner procedure error codes:         none (uses RETURN, not THROW)
-- =============================================================================

USE HospitalDB;
GO


-- =============================================================================
-- INNER PROCEDURE
-- =============================================================================
-- Name   : dbo.usp_Patient_CheckEligibility
-- Role   : Helper / validator.  Called exclusively by outer procedures.
--          Never called directly by the application layer.
--
-- How the caller receives the status:
--   DECLARE @Status INT;
--   EXEC @Status = dbo.usp_Patient_CheckEligibility
--       @PatientID             = <n>,
--       @MaxOutstandingBalance = <amount>,
--       @EligibilityMessage    = @Msg OUTPUT;
--   -- @Status now holds 0 / 1 / 2 / 3 / -1
--
-- RETURN code contract:
--    0  Eligible
--    1  Patient not found
--    2  No non-expired insurance policy
--    3  Outstanding balance >= @MaxOutstandingBalance
--   -1  Unexpected error in the eligibility check itself
-- =============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Patient_CheckEligibility
    @PatientID             INT,
    @MaxOutstandingBalance DECIMAL(10,2)   = 1000.00,
    @EligibilityMessage    NVARCHAR(300)   OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PatientExists       BIT          = 0;
    DECLARE @InsuranceValid      BIT          = 0;
    DECLARE @OutstandingBalance  DECIMAL(10,2)= 0.00;
    DECLARE @PatientName         NVARCHAR(120);

    BEGIN TRY

        -- ── Rule E-1: Patient must exist ────────────────────────────────────
        SELECT
            @PatientExists = 1,
            @PatientName   = FirstName + ' ' + LastName
        FROM dbo.Patients
        WHERE PatientID = @PatientID;

        IF @PatientExists = 0
        BEGIN
            SET @EligibilityMessage =
                'Patient ID ' + CAST(@PatientID AS VARCHAR) + ' was not found in dbo.Patients.';
            RETURN 1;
        END;

        -- ── Rule E-2: At least one non-expired insurance policy ─────────────
        -- A policy is valid when its ExpiryDate is today or in the future.
        SELECT @InsuranceValid = CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END
        FROM dbo.PatientInsurancePolicies
        WHERE PatientID  = @PatientID
          AND ExpiryDate >= CAST(GETDATE() AS DATE);

        IF @InsuranceValid = 0
        BEGIN
            SET @EligibilityMessage =
                'Patient ' + @PatientName
                + ' (ID ' + CAST(@PatientID AS VARCHAR) + ') has no active (non-expired) insurance policy.';
            RETURN 2;
        END;

        -- ── Rule E-3: Outstanding balance must be below threshold ────────────
        -- Outstanding = sum of Balance on all bills that are not fully Paid.
        SELECT @OutstandingBalance = ISNULL(SUM(b.Balance), 0.00)
        FROM dbo.Bills b
        WHERE b.PatientID  = @PatientID
          AND b.BillStatus <> 'Paid';

        IF @OutstandingBalance >= @MaxOutstandingBalance
        BEGIN
            SET @EligibilityMessage =
                'Patient ' + @PatientName
                + ' (ID ' + CAST(@PatientID AS VARCHAR) + ') has an outstanding balance of $'
                + CAST(@OutstandingBalance AS VARCHAR(20))
                + ', which meets or exceeds the eligibility threshold of $'
                + CAST(@MaxOutstandingBalance AS VARCHAR(20)) + '.';
            RETURN 3;
        END;

        -- ── All rules passed ─────────────────────────────────────────────────
        SET @EligibilityMessage =
            'Patient ' + @PatientName
            + ' (ID ' + CAST(@PatientID AS VARCHAR) + ') passed all eligibility checks.'
            + ' Outstanding balance: $' + CAST(@OutstandingBalance AS VARCHAR(20)) + '.';
        RETURN 0;

    END TRY
    BEGIN CATCH
        -- Log the internal failure so it can be investigated without crashing
        -- the caller entirely — the caller receives -1 and decides what to do.
        INSERT INTO dbo.ErrorLogs (ProcedureName, ErrorMessage, ErrorDate)
        VALUES (
            ISNULL(ERROR_PROCEDURE(), 'usp_Patient_CheckEligibility'),
            'Internal eligibility check failure.  '
            + 'Error ' + CAST(ERROR_NUMBER() AS VARCHAR(10))
            + ' Line ' + CAST(ERROR_LINE()   AS VARCHAR(10))
            + ': '     + ERROR_MESSAGE(),
            GETDATE()
        );

        SET @EligibilityMessage =
            'The eligibility check encountered an internal error and could not complete.';
        RETURN -1;
    END CATCH;
END;
GO


-- =============================================================================
-- OUTER PROCEDURE
-- =============================================================================
-- Name   : dbo.usp_Appointment_ScheduleWithEligibilityCheck
--
-- Nested-call pattern demonstrated:
--   1. EXEC @EligStatus = dbo.usp_Patient_CheckEligibility ...
--   2. IF / ELSE IF chain evaluates every possible RETURN value.
--   3. Only status 0 (and optionally status 2 with @OverrideInsurance=1)
--      allow the appointment INSERT transaction to proceed.
--
-- Transaction structure:
--   All eligibility checks happen BEFORE the transaction opens, so a failed
--   check never leaves a dangling open transaction.  The transaction covers
--   only the two DML statements that must be atomic: INSERT Appointments
--   and INSERT AuditLogs.
--
-- Custom error codes:
--   52001 — Patient failed eligibility: patient not found (inner returned 1)
--   52002 — Patient failed eligibility: no active insurance (inner returned 2)
--   52003 — Patient failed eligibility: balance too high  (inner returned 3)
--   52004 — Eligibility check itself encountered an internal error (inner -1)
--   52005 — Eligibility check returned an unrecognised status code (defensive)
--   52006 — @PatientID invalid
--   52007 — @DoctorID invalid
--   52008 — @AppointmentDate in the past
--   52009 — @Reason blank
--   52010 — @CreatedByUserID / @PerformedByUserID not found
-- =============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Appointment_ScheduleWithEligibilityCheck
    @PatientID             INT,
    @DoctorID              INT,
    @CreatedByUserID       INT,
    @AppointmentDate       DATETIME,
    @Reason                VARCHAR(255),
    @PerformedByUserID     INT,
    @MaxOutstandingBalance DECIMAL(10,2) = 1000.00,
    @OverrideInsurance     BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @NewAppointmentID  INT;
    DECLARE @EligStatus        INT;
    DECLARE @EligibilityMessage NVARCHAR(300);
    DECLARE @AuditNote         NVARCHAR(500);

    BEGIN TRY

        -- ── Guard: scalar parameter validation (before any DB read) ──────────
        IF @PatientID IS NULL OR @PatientID <= 0
            THROW 52006, 'Invalid @PatientID: must be a positive integer.', 1;

        IF @DoctorID IS NULL OR @DoctorID <= 0
            THROW 52006, 'Invalid @DoctorID: must be a positive integer.', 1;

        IF @AppointmentDate IS NULL OR @AppointmentDate <= GETDATE()
            THROW 52008,
                'Invalid @AppointmentDate: the appointment date must be in the future.', 1;

        IF NULLIF(LTRIM(RTRIM(@Reason)), '') IS NULL
            THROW 52009, 'Invalid @Reason: must not be blank or NULL.', 1;

        IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE UserID = @CreatedByUserID)
            THROW 52010, 'The specified CreatedByUserID does not exist in dbo.Users.', 1;

        IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE UserID = @PerformedByUserID)
            THROW 52010, 'The specified PerformedByUserID does not exist in dbo.Users.', 1;

        IF NOT EXISTS (SELECT 1 FROM dbo.Doctors WHERE DoctorID = @DoctorID)
            THROW 52007, 'The specified DoctorID does not exist in dbo.Doctors.', 1;

        -- ── NESTED CALL ──────────────────────────────────────────────────────
        -- Call the inner procedure and capture its RETURN status.
        -- @EligibilityMessage (OUTPUT) carries a human-readable explanation.
        EXEC @EligStatus = dbo.usp_Patient_CheckEligibility
            @PatientID             = @PatientID,
            @MaxOutstandingBalance = @MaxOutstandingBalance,
            @EligibilityMessage    = @EligibilityMessage OUTPUT;

        -- ── Evaluate return status (every code handled explicitly) ───────────
        IF @EligStatus = 0
        BEGIN
            -- Patient is fully eligible — proceed normally.
            SET @AuditNote = 'EligibilityStatus=Passed; ' + @EligibilityMessage;
        END
        ELSE IF @EligStatus = 1
        BEGIN
            -- Patient record does not exist.
            DECLARE @Err1 NVARCHAR(400) =
                'Appointment scheduling rejected.  Reason: ' + @EligibilityMessage;
            THROW 52001, @Err1, 1;
        END
        ELSE IF @EligStatus = 2
        BEGIN
            -- No valid insurance policy found.
            IF @OverrideInsurance = 1
            BEGIN
                -- Self-pay override authorised by caller — log warning and continue.
                INSERT INTO dbo.ErrorLogs (ProcedureName, ErrorMessage, ErrorDate)
                VALUES (
                    'usp_Appointment_ScheduleWithEligibilityCheck',
                    'INSURANCE OVERRIDE applied for PatientID ' + CAST(@PatientID AS VARCHAR)
                    + '.  ' + @EligibilityMessage,
                    GETDATE()
                );
                SET @AuditNote =
                    'EligibilityStatus=InsuranceOverride(self-pay); ' + @EligibilityMessage;
            END
            ELSE
            BEGIN
                DECLARE @Err2 NVARCHAR(400) =
                    'Appointment scheduling rejected.  Reason: ' + @EligibilityMessage
                    + '  To schedule as self-pay, set @OverrideInsurance = 1.';
                THROW 52002, @Err2, 1;
            END;
        END
        ELSE IF @EligStatus = 3
        BEGIN
            -- Outstanding balance exceeds the configured threshold.
            DECLARE @Err3 NVARCHAR(400) =
                'Appointment scheduling rejected.  Reason: ' + @EligibilityMessage
                + '  Payment or balance adjustment is required before new appointments can be booked.';
            THROW 52003, @Err3, 1;
        END
        ELSE IF @EligStatus = -1
        BEGIN
            -- The inner procedure itself failed unexpectedly.
            THROW 52004,
                'Appointment scheduling aborted: the eligibility check encountered an internal error.  Check ErrorLogs for details.', 1;
        END
        ELSE
        BEGIN
            -- Defensive: unknown return code — should never occur but handled
            -- explicitly so any future inner-procedure change is immediately visible.
            DECLARE @ErrUnknown NVARCHAR(200) =
                'Appointment scheduling aborted: usp_Patient_CheckEligibility returned an unrecognised status code ('
                + CAST(@EligStatus AS VARCHAR(10)) + ').';
            THROW 52005, @ErrUnknown, 1;
        END;

        -- ── TRANSACTION: Appointment + AuditLog (atomic) ────────────────────
        -- We only reach this point if @EligStatus = 0, or = 2 with override.
        BEGIN TRANSACTION;

            INSERT INTO dbo.Appointments
                (PatientID, DoctorID, CreatedByUserID, AppointmentDate, Status, Reason)
            VALUES
                (@PatientID, @DoctorID, @CreatedByUserID, @AppointmentDate,
                 'Scheduled', @Reason);

            SET @NewAppointmentID = SCOPE_IDENTITY();

            INSERT INTO dbo.AuditLogs
                (PerformedByUserID, TableName, ActionType, ActionDate, OldValue, NewValue)
            VALUES (
                @PerformedByUserID,
                'Appointments',
                'INSERT',
                GETDATE(),
                '',
                'AppointmentID=' + CAST(@NewAppointmentID AS VARCHAR(10))
                + '; PatientID='  + CAST(@PatientID        AS VARCHAR(10))
                + '; DoctorID='   + CAST(@DoctorID         AS VARCHAR(10))
                + '; EligibilityCheckStatus=' + CAST(@EligStatus AS VARCHAR(5))
                + '; ' + @AuditNote
            );

        COMMIT TRANSACTION;

        -- ── Result set: newly created appointment ────────────────────────────
        SELECT
            a.AppointmentID,
            p.PatientID,
            p.FirstName + ' ' + p.LastName    AS PatientName,
            d.DoctorID,
            d.FirstName + ' ' + d.LastName    AS DoctorName,
            dep.DepartmentName,
            a.AppointmentDate,
            a.Status,
            a.Reason,
            @EligStatus                        AS EligibilityCheckStatus,
            @EligibilityMessage                AS EligibilityDetail,
            CASE @EligStatus
                WHEN 0 THEN 'Passed'
                WHEN 2 THEN 'Insurance override (self-pay)'
                ELSE         'Unknown'
            END                                AS EligibilityOutcome
        FROM  dbo.Appointments a
        INNER JOIN dbo.Patients    p   ON p.PatientID     = a.PatientID
        INNER JOIN dbo.Doctors     d   ON d.DoctorID      = a.DoctorID
        INNER JOIN dbo.Departments dep ON dep.DepartmentID = d.DepartmentID
        WHERE a.AppointmentID = @NewAppointmentID;

    END TRY
    BEGIN CATCH

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        INSERT INTO dbo.ErrorLogs (ProcedureName, ErrorMessage, ErrorDate)
        VALUES (
            ISNULL(ERROR_PROCEDURE(), 'usp_Appointment_ScheduleWithEligibilityCheck'),
            'Error ' + CAST(ERROR_NUMBER() AS VARCHAR(10))
            + ' Line ' + CAST(ERROR_LINE()   AS VARCHAR(10))
            + ': '     + ERROR_MESSAGE(),
            GETDATE()
        );

        THROW;

    END CATCH;
END;
GO


-- =============================================================================
-- TEST SUITE
-- =============================================================================

SET XACT_ABORT OFF;
GO

-- Resolve live IDs used across all tests
SELECT TOP 3 PatientID, FirstName + ' ' + LastName AS PatientName FROM dbo.Patients ORDER BY PatientID;
SELECT TOP 2 DoctorID,  FirstName + ' ' + LastName AS DoctorName  FROM dbo.Doctors  ORDER BY DoctorID;
SELECT TOP 1 UserID                                                FROM dbo.Users WHERE IsActive = 1 ORDER BY UserID;
-- Check insurance coverage for the first two patients
SELECT PatientID, PolicyNumber, ExpiryDate,
       CASE WHEN ExpiryDate >= CAST(GETDATE() AS DATE) THEN 'Valid' ELSE 'Expired' END AS PolicyStatus
FROM dbo.PatientInsurancePolicies
WHERE PatientID IN (SELECT TOP 2 PatientID FROM dbo.Patients ORDER BY PatientID)
ORDER BY PatientID;
GO


-- =============================================================================
-- TEST GROUP T1 — Call inner procedure directly to confirm return codes
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- T1.1  Inner — eligible patient
-- Expected: RETURN 0, @EligibilityMessage contains 'passed all eligibility checks'
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @Msg1 NVARCHAR(300);
DECLARE @S1   INT;
DECLARE @P1   INT; SELECT @P1 = MIN(PatientID) FROM dbo.Patients;

EXEC @S1 = dbo.usp_Patient_CheckEligibility
    @PatientID             = @P1,
    @MaxOutstandingBalance = 9999.00,   -- high threshold so balance check passes
    @EligibilityMessage    = @Msg1 OUTPUT;

SELECT 'T1.1' AS Test, @S1 AS ReturnStatus, @Msg1 AS Message,
       CASE WHEN @S1 = 0 THEN 'PASS' ELSE 'FAIL — expected 0' END AS Result;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- T1.2  Inner — non-existent patient
-- Expected: RETURN 1
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @Msg2 NVARCHAR(300);
DECLARE @S2   INT;

EXEC @S2 = dbo.usp_Patient_CheckEligibility
    @PatientID             = 999999,
    @MaxOutstandingBalance = 1000.00,
    @EligibilityMessage    = @Msg2 OUTPUT;

SELECT 'T1.2' AS Test, @S2 AS ReturnStatus, @Msg2 AS Message,
       CASE WHEN @S2 = 1 THEN 'PASS' ELSE 'FAIL — expected 1' END AS Result;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- T1.3  Inner — patient with expired insurance only
-- Set up: temporarily insert an expired-only policy for a test patient.
-- Expected: RETURN 2
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @TestPatient INT; SELECT @TestPatient = MAX(PatientID) FROM dbo.Patients;

-- Remove any current valid policies temporarily by using a patient who has only
-- expired policies — we create a fresh patient with only an expired policy.
DECLARE @NewPatientID INT;
DECLARE @AddrID INT; SELECT @AddrID = MIN(AddressID) FROM dbo.Addresses;
DECLARE @InsID  INT; SELECT @InsID  = MIN(InsuranceProviderID) FROM dbo.InsuranceProviders;

INSERT INTO dbo.Patients (AddressID, FirstName, LastName, DOB, Gender, Phone, Email, DateCreated)
VALUES (@AddrID, 'TestInsurance', 'ExpiredOnly', '1980-01-01', 'Male', '000-000-0001', 'ins_test@test.com', GETDATE());
SET @NewPatientID = SCOPE_IDENTITY();

-- Insert only an expired policy for this patient
INSERT INTO dbo.PatientInsurancePolicies (PatientID, InsuranceProviderID, PolicyNumber, CoveragePercent, ExpiryDate, IsPrimary)
VALUES (@NewPatientID, @InsID, 'EXPIRED-TEST-001', 80.00, DATEADD(YEAR, -1, GETDATE()), 1);

DECLARE @Msg3 NVARCHAR(300);
DECLARE @S3   INT;

EXEC @S3 = dbo.usp_Patient_CheckEligibility
    @PatientID             = @NewPatientID,
    @MaxOutstandingBalance = 1000.00,
    @EligibilityMessage    = @Msg3 OUTPUT;

SELECT 'T1.3' AS Test, @S3 AS ReturnStatus, @Msg3 AS Message,
       CASE WHEN @S3 = 2 THEN 'PASS' ELSE 'FAIL — expected 2' END AS Result;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- T1.4  Inner — outstanding balance exceeds threshold
-- Expected: RETURN 3
-- ─────────────────────────────────────────────────────────────────────────────
-- Find a patient who has at least one unpaid bill (seed data should have some)
DECLARE @HighBalPatient INT;
SELECT TOP 1 @HighBalPatient = PatientID FROM dbo.Bills WHERE BillStatus <> 'Paid' ORDER BY Balance DESC;

DECLARE @Msg4 NVARCHAR(300);
DECLARE @S4   INT;

EXEC @S4 = dbo.usp_Patient_CheckEligibility
    @PatientID             = @HighBalPatient,
    @MaxOutstandingBalance = 0.01,      -- very low threshold to force Rule E-3 failure
    @EligibilityMessage    = @Msg4 OUTPUT;

SELECT 'T1.4' AS Test, @S4 AS ReturnStatus, @Msg4 AS Message,
       CASE WHEN @S4 = 3 THEN 'PASS' ELSE 'FAIL — expected 3' END AS Result;
GO


-- =============================================================================
-- TEST GROUP T2 — Outer procedure: return-status evaluation by the caller
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- T2.1  Outer — fully eligible patient, normal scheduling
-- Expected: appointment created; EligibilityOutcome = 'Passed'
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @Pat   INT; SELECT @Pat = MIN(PatientID) FROM dbo.Patients;
DECLARE @Doc   INT; SELECT @Doc = MIN(DoctorID)  FROM dbo.Doctors;
DECLARE @Usr   INT; SELECT @Usr = MIN(UserID)    FROM dbo.Users WHERE IsActive = 1;
DECLARE @Dt21  DATETIME; SET @Dt21 = DATEADD(DAY, 10, GETDATE());

PRINT 'Test T2.1 — Eligible patient  Expected: AppointmentID created, EligibilityOutcome=Passed';
EXEC dbo.usp_Appointment_ScheduleWithEligibilityCheck
    @PatientID             = @Pat,
    @DoctorID              = @Doc,
    @CreatedByUserID       = @Usr,
    @AppointmentDate       = @Dt21,
    @Reason                = 'Annual physical examination with full blood panel.',
    @PerformedByUserID     = @Usr,
    @MaxOutstandingBalance = 9999.00,
    @OverrideInsurance     = 0;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- T2.2  Outer — patient without valid insurance, @OverrideInsurance = 1 (self-pay)
-- Expected: appointment created; ErrorLogs contains INSURANCE OVERRIDE entry;
--           EligibilityOutcome = 'Insurance override (self-pay)'
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @OverridePatient INT;
SELECT @OverridePatient = MAX(PatientID) - 1 FROM dbo.Patients; -- use the expired-policy patient added in T1.3
DECLARE @Doc22 INT; SELECT @Doc22 = MIN(DoctorID) FROM dbo.Doctors;
DECLARE @Usr22 INT; SELECT @Usr22 = MIN(UserID)   FROM dbo.Users WHERE IsActive = 1;
DECLARE @Dt22  DATETIME; SET @Dt22 = DATEADD(DAY, 8, GETDATE());

PRINT 'Test T2.2 — No insurance + OverrideInsurance=1  Expected: appointment created, INSURANCE OVERRIDE in ErrorLogs';
EXEC dbo.usp_Appointment_ScheduleWithEligibilityCheck
    @PatientID             = @OverridePatient,
    @DoctorID              = @Doc22,
    @CreatedByUserID       = @Usr22,
    @AppointmentDate       = @Dt22,
    @Reason                = 'Self-pay consultation — cardiology referral.',
    @PerformedByUserID     = @Usr22,
    @MaxOutstandingBalance = 9999.00,
    @OverrideInsurance     = 1;
GO

-- Verify the override was logged
SELECT TOP 1 ErrorID, LEFT(ErrorMessage, 120) AS ErrorMessage, ErrorDate
FROM dbo.ErrorLogs WHERE ErrorMessage LIKE '%INSURANCE OVERRIDE%'
ORDER BY ErrorDate DESC;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- T2.3  Outer — non-existent patient → inner returns 1 → outer raises 52001
-- Expected: Error 52001 caught by test harness; NO appointment row written.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @Doc23 INT; SELECT @Doc23 = MIN(DoctorID) FROM dbo.Doctors;
DECLARE @Usr23 INT; SELECT @Usr23 = MIN(UserID)   FROM dbo.Users WHERE IsActive = 1;
DECLARE @Dt23  DATETIME; SET @Dt23 = DATEADD(DAY, 4, GETDATE());

PRINT 'Test T2.3 — Non-existent patient  Expected: Error 52001';
BEGIN TRY
    EXEC dbo.usp_Appointment_ScheduleWithEligibilityCheck
        @PatientID             = 999999,
        @DoctorID              = @Doc23,
        @CreatedByUserID       = @Usr23,
        @AppointmentDate       = @Dt23,
        @Reason                = 'Should not be created.',
        @PerformedByUserID     = @Usr23,
        @MaxOutstandingBalance = 1000.00,
        @OverrideInsurance     = 0;
END TRY
BEGIN CATCH
    SELECT 'T2.3' AS Test, ERROR_NUMBER() AS ErrNum, LEFT(ERROR_MESSAGE(), 120) AS ErrMsg,
           CASE WHEN ERROR_NUMBER() = 52001 THEN 'PASS' ELSE 'FAIL' END AS Result;
END CATCH;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- T2.4  Outer — no insurance, @OverrideInsurance = 0 → inner returns 2 → 52002
-- Expected: Error 52002 caught; NO appointment row written.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @NoInsPatient INT;
SELECT @NoInsPatient = MAX(PatientID) - 1 FROM dbo.Patients; -- expired-policy patient from T1.3
DECLARE @Doc24 INT; SELECT @Doc24 = MIN(DoctorID) FROM dbo.Doctors;
DECLARE @Usr24 INT; SELECT @Usr24 = MIN(UserID)   FROM dbo.Users WHERE IsActive = 1;
DECLARE @Dt24  DATETIME; SET @Dt24 = DATEADD(DAY, 6, GETDATE());

PRINT 'Test T2.4 — No insurance, no override  Expected: Error 52002';
BEGIN TRY
    EXEC dbo.usp_Appointment_ScheduleWithEligibilityCheck
        @PatientID             = @NoInsPatient,
        @DoctorID              = @Doc24,
        @CreatedByUserID       = @Usr24,
        @AppointmentDate       = @Dt24,
        @Reason                = 'Insurance validation failure test.',
        @PerformedByUserID     = @Usr24,
        @MaxOutstandingBalance = 9999.00,
        @OverrideInsurance     = 0;
END TRY
BEGIN CATCH
    SELECT 'T2.4' AS Test, ERROR_NUMBER() AS ErrNum, LEFT(ERROR_MESSAGE(), 120) AS ErrMsg,
           CASE WHEN ERROR_NUMBER() = 52002 THEN 'PASS' ELSE 'FAIL' END AS Result;
END CATCH;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- T2.5  Outer — balance threshold exceeded → inner returns 3 → outer raises 52003
-- Expected: Error 52003 caught; NO appointment row written.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @HighBalPat2 INT;
SELECT TOP 1 @HighBalPat2 = PatientID FROM dbo.Bills WHERE BillStatus <> 'Paid' ORDER BY Balance DESC;
DECLARE @Doc25 INT; SELECT @Doc25 = MIN(DoctorID) FROM dbo.Doctors;
DECLARE @Usr25 INT; SELECT @Usr25 = MIN(UserID)   FROM dbo.Users WHERE IsActive = 1;
DECLARE @Dt25  DATETIME; SET @Dt25 = DATEADD(DAY, 5, GETDATE());

PRINT 'Test T2.5 — Balance too high  Expected: Error 52003';
BEGIN TRY
    EXEC dbo.usp_Appointment_ScheduleWithEligibilityCheck
        @PatientID             = @HighBalPat2,
        @DoctorID              = @Doc25,
        @CreatedByUserID       = @Usr25,
        @AppointmentDate       = @Dt25,
        @Reason                = 'Balance check failure test.',
        @PerformedByUserID     = @Usr25,
        @MaxOutstandingBalance = 0.01,
        @OverrideInsurance     = 0;
END TRY
BEGIN CATCH
    SELECT 'T2.5' AS Test, ERROR_NUMBER() AS ErrNum, LEFT(ERROR_MESSAGE(), 120) AS ErrMsg,
           CASE WHEN ERROR_NUMBER() = 52003 THEN 'PASS' ELSE 'FAIL' END AS Result;
END CATCH;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- T2.6  Outer — past appointment date → validation guard fires before inner call
-- Expected: Error 52008; inner procedure is NEVER invoked.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @Pat26 INT; SELECT @Pat26 = MIN(PatientID) FROM dbo.Patients;
DECLARE @Doc26 INT; SELECT @Doc26 = MIN(DoctorID)  FROM dbo.Doctors;
DECLARE @Usr26 INT; SELECT @Usr26 = MIN(UserID)    FROM dbo.Users WHERE IsActive = 1;
DECLARE @PastDt DATETIME; SET @PastDt = DATEADD(DAY, -1, GETDATE());

PRINT 'Test T2.6 — Past date (guard fires before inner call)  Expected: Error 52008';
BEGIN TRY
    EXEC dbo.usp_Appointment_ScheduleWithEligibilityCheck
        @PatientID             = @Pat26,
        @DoctorID              = @Doc26,
        @CreatedByUserID       = @Usr26,
        @AppointmentDate       = @PastDt,
        @Reason                = 'Date guard test.',
        @PerformedByUserID     = @Usr26;
END TRY
BEGIN CATCH
    SELECT 'T2.6' AS Test, ERROR_NUMBER() AS ErrNum, LEFT(ERROR_MESSAGE(), 80) AS ErrMsg,
           CASE WHEN ERROR_NUMBER() = 52008 THEN 'PASS' ELSE 'FAIL' END AS Result;
END CATCH;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Final summary: verify no orphaned appointments from error tests
-- ─────────────────────────────────────────────────────────────────────────────
SELECT COUNT(*) AS OrphanCheck
FROM dbo.Appointments
WHERE Reason IN ('Should not be created.', 'Insurance validation failure test.',
                 'Balance check failure test.', 'Date guard test.');

-- Confirm the two successful appointments were written (T2.1 and T2.2)
SELECT TOP 5 AppointmentID, PatientID, Reason, Status
FROM dbo.Appointments
ORDER BY AppointmentID DESC;
GO
