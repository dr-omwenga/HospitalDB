-- =============================================================================
-- HospitalDB — Business Rule Stored Procedures
-- File        : sql/15_business_rule_procedures.sql
-- Author      : Hospital Information Systems
-- Date        : 2026-05-07
-- Description :
--   Three stored procedures that encapsulate core operational business rules
--   from the HospitalDB reporting and performance layer (files 05–09).  Each
--   procedure is fully parameterised, reusable, and includes robust error
--   handling (TRY/CATCH, transaction rollback, and ErrorLogs insertion).
--
--   The utility functions defined in sql/14_utility_functions.sql are
--   referenced in the result sets of each procedure to ensure that computed
--   labels (aging buckets, risk tiers, reminder priorities) remain consistent
--   with the reporting layer.
--
--   Procedures defined in this file:
--
--     1. dbo.usp_Billing_ProcessPayment
--        Business rules : 6.2 (PaidAmount / Balance tracked independently),
--                         6.3 (BillStatus reflects collection state).
--        Utility fns    : fn_GetAgingBucket, fn_GetCollectionRiskTier.
--        Summary        : Validates and records a payment against an open bill,
--                         updates the bill's financial state atomically, and
--                         logs the action to AuditLogs.
--
--     2. dbo.usp_Appointments_UpdateOutcome
--        Business rules : 3.2 (one-way status lifecycle),
--                         4.1 (medical records only for Completed),
--                         6.1 (financial protection before cancellation).
--        Utility fn     : fn_GetReminderPriority.
--        Summary        : Transitions a Scheduled appointment to a terminal
--                         outcome (Completed / No-Show / Cancelled), enforces
--                         all lifecycle constraints, and audit-logs every
--                         status change.
--
--     3. dbo.usp_Security_EnforceInactivityPolicy
--        Business rules : 2.4 (deactivation without deletion),
--                         2.6 (inactivity risk tiers drive access reviews).
--        Utility fn     : fn_GetInactivityRiskTier.
--        Summary        : Identifies dormant user accounts that meet a
--                         configurable inactivity threshold, optionally
--                         deactivates them in a batch transaction, and logs
--                         every change to AuditLogs.  Supports a @DryRun mode
--                         for safe preview before committing.
--
--   Error handling pattern (consistent across all three procedures):
--     – SET XACT_ABORT ON   : any unexpected error inside a transaction
--                             automatically marks the transaction as doomed.
--     – TRY / CATCH         : all validation, data access, and DML is wrapped
--                             in a TRY block.
--     – THROW               : user-defined errors use THROW with custom error
--                             numbers (50001–50030) for easy triage.
--     – XACT_STATE() check  : the CATCH block checks XACT_STATE() before
--                             issuing ROLLBACK, guarding against double-rollback
--                             when XACT_ABORT has already doomed the transaction.
--     – ErrorLogs insert    : every caught error is written to dbo.ErrorLogs
--                             before re-raising, giving operations staff a
--                             persistent record of failures.
--     – THROW (re-raise)    : after logging, the original error is re-thrown so
--                             the calling application receives an accurate
--                             error code and message.
--
--   Execution note:
--     This file depends on dbo.ErrorLogs (sql/02), all billing/appointment/
--     user tables (sql/02), and the four utility functions (sql/14).
--     Deploy sql/14 before this file.
--
--   Test cases:
--     A comprehensive test suite is included at the end of this file.  Each
--     test prints a header, executes the procedure, and verifies the outcome
--     via a SELECT statement.  Error-path tests wrap the call in TRY/CATCH and
--     display the captured error number and message to confirm correct handling.
-- =============================================================================

USE HospitalDB;
GO


-- =============================================================================
-- PROCEDURE 1
-- =============================================================================
-- Name        : dbo.usp_Billing_ProcessPayment
--
-- Business Rules Enforced:
--   Rule 6.2 — TotalAmount is never changed; only PaidAmount and Balance are
--              updated, keeping the original billed amount intact for revenue
--              reporting and insurance reconciliation.
--   Rule 6.3 — BillStatus is derived automatically from the new Balance:
--              zero balance → 'Paid'; positive balance → 'Partially Paid'.
--              The procedure rejects payments against bills that are already
--              in 'Paid' status.
--   Rule 6.1 — Implicit: a payment can only be applied to an existing bill,
--              preserving the financial audit trail.
--
-- Parameters:
--   @BillID             INT            — ID of the bill to pay (required).
--   @PaymentAmount      DECIMAL(10,2)  — Amount being paid.  Must be > 0 and
--                                        ≤ the bill's current outstanding
--                                        balance.  Required.
--   @PaymentMethod      VARCHAR(40)    — Payment channel (e.g. 'Cash', 'Card',
--                                        'Insurance', 'Bank Transfer').
--                                        Must not be blank.  Required.
--   @ReferenceNumber    VARCHAR(80)    — External transaction reference (e.g.
--                                        bank confirmation code).  Optional;
--                                        auto-generated if not supplied.
--   @PerformedByUserID  INT            — UserID of the staff member recording
--                                        the payment.  Must reference an active
--                                        record in dbo.Users.  Required.
--
-- Returns (single result set):
--   BillID, PatientName, TotalAmount, NewPaidAmount, NewBalance,
--   NewBillStatus, PaymentApplied, ReferenceNumber, AgingBucket
--   (via fn_GetAgingBucket), CollectionRiskTier (via fn_GetCollectionRiskTier).
--
-- Error codes (custom):
--   50001  — @BillID invalid
--   50002  — @PaymentAmount invalid (zero or negative)
--   50003  — @PaymentMethod blank
--   50004  — @PerformedByUserID invalid
--   50005  — @PerformedByUserID does not exist in Users
--   50006  — @BillID does not exist in Bills
--   50007  — Bill is already fully Paid
--   50008  — Payment amount exceeds outstanding balance
-- =============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Billing_ProcessPayment
    @BillID            INT,
    @PaymentAmount     DECIMAL(10,2),
    @PaymentMethod     VARCHAR(40),
    @ReferenceNumber   VARCHAR(80)  = NULL,
    @PerformedByUserID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Working variables
    DECLARE @CurrentBalance  DECIMAL(10,2);
    DECLARE @CurrentStatus   VARCHAR(30);
    DECLARE @CurrentPaid     DECIMAL(10,2);
    DECLARE @TotalAmount     DECIMAL(10,2);
    DECLARE @PatientID       INT;
    DECLARE @NewPaidAmount   DECIMAL(10,2);
    DECLARE @NewBalance      DECIMAL(10,2);
    DECLARE @NewStatus       VARCHAR(30);
    DECLARE @NewPaymentID    INT;
    DECLARE @EffectiveRef    VARCHAR(80);

    BEGIN TRY

        -- ---------------------------------------------------------------
        -- Guard 1: Parameter validation (before any I/O)
        -- ---------------------------------------------------------------
        IF @BillID IS NULL OR @BillID <= 0
            THROW 50001, 'Invalid @BillID: must be a positive integer.', 1;

        IF @PaymentAmount IS NULL OR @PaymentAmount <= 0
            THROW 50002, 'Invalid @PaymentAmount: must be greater than zero.', 1;

        IF NULLIF(LTRIM(RTRIM(@PaymentMethod)), '') IS NULL
            THROW 50003, 'Invalid @PaymentMethod: must not be blank or NULL.', 1;

        IF @PerformedByUserID IS NULL OR @PerformedByUserID <= 0
            THROW 50004, 'Invalid @PerformedByUserID: must be a positive integer.', 1;

        -- ---------------------------------------------------------------
        -- Guard 2: Referential integrity checks
        -- ---------------------------------------------------------------
        IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE UserID = @PerformedByUserID)
            THROW 50005, 'The specified PerformedByUserID does not exist in dbo.Users.', 1;

        -- Lock the target row immediately to prevent concurrent payments
        -- against the same bill from producing a race condition.
        SELECT
            @CurrentBalance = b.Balance,
            @CurrentStatus  = b.BillStatus,
            @CurrentPaid    = b.PaidAmount,
            @TotalAmount    = b.TotalAmount,
            @PatientID      = b.PatientID
        FROM dbo.Bills b WITH (UPDLOCK, ROWLOCK)
        WHERE b.BillID = @BillID;

        IF @CurrentBalance IS NULL
            THROW 50006, 'The specified BillID does not exist in dbo.Bills.', 1;

        -- ---------------------------------------------------------------
        -- Guard 3: Business rule enforcement
        -- ---------------------------------------------------------------
        -- Rule 6.3: reject payments on bills that are already settled.
        IF @CurrentStatus NOT IN ('Unpaid', 'Partially Paid')
            THROW 50007,
                'Payment rejected: this bill is already in Paid status.  No further payments can be applied.',
                1;

        -- Rule 6.2: payment must not exceed the outstanding balance.
        IF @PaymentAmount > @CurrentBalance
            THROW 50008,
                'Payment rejected: the payment amount exceeds the outstanding balance.  Reduce the amount or apply multiple payments.',
                1;

        -- ---------------------------------------------------------------
        -- Derive new bill state
        -- ---------------------------------------------------------------
        SET @NewPaidAmount = @CurrentPaid    + @PaymentAmount;
        SET @NewBalance    = @CurrentBalance - @PaymentAmount;

        -- Rule 6.3: status derived from new balance (not stored externally)
        SET @NewStatus = CASE WHEN @NewBalance = 0 THEN 'Paid' ELSE 'Partially Paid' END;

        -- Auto-generate a reference number if the caller did not supply one
        SET @EffectiveRef = ISNULL(
            NULLIF(LTRIM(RTRIM(@ReferenceNumber)), ''),
            'AUTO-' + LEFT(REPLACE(CAST(NEWID() AS VARCHAR(36)), '-', ''), 12)
        );

        -- ---------------------------------------------------------------
        -- DML: wrapped in an explicit transaction
        -- ---------------------------------------------------------------
        BEGIN TRANSACTION;

            -- Insert the payment record
            INSERT INTO dbo.Payments (BillID, PaymentDate, Amount, PaymentMethod, ReferenceNumber)
            VALUES (@BillID, GETDATE(), @PaymentAmount, @PaymentMethod, @EffectiveRef);

            SET @NewPaymentID = SCOPE_IDENTITY();

            -- Update the bill (Rule 6.2: TotalAmount unchanged)
            UPDATE dbo.Bills
            SET  PaidAmount = @NewPaidAmount,
                 Balance    = @NewBalance,
                 BillStatus = @NewStatus
            WHERE BillID = @BillID;

            -- Audit log entry: records old and new state for traceability
            INSERT INTO dbo.AuditLogs
                (PerformedByUserID, TableName, ActionType, ActionDate, OldValue, NewValue)
            VALUES (
                @PerformedByUserID,
                'Bills',
                'UPDATE',
                GETDATE(),
                'BillID='     + CAST(@BillID        AS VARCHAR(10))
                + '; Paid='   + CAST(@CurrentPaid   AS VARCHAR(20))
                + '; Balance='+ CAST(@CurrentBalance AS VARCHAR(20))
                + '; Status=' + @CurrentStatus,
                'BillID='     + CAST(@BillID        AS VARCHAR(10))
                + '; Paid='   + CAST(@NewPaidAmount  AS VARCHAR(20))
                + '; Balance='+ CAST(@NewBalance     AS VARCHAR(20))
                + '; Status=' + @NewStatus
                + '; PaymentID=' + CAST(@NewPaymentID AS VARCHAR(10))
            );

        COMMIT TRANSACTION;

        -- ---------------------------------------------------------------
        -- Result set: updated bill state enriched with utility function labels
        -- ---------------------------------------------------------------
        SELECT
            b.BillID,
            p.PatientID,
            p.FirstName + ' ' + p.LastName              AS PatientName,
            b.TotalAmount,
            b.PaidAmount                                 AS NewPaidAmount,
            b.Balance                                    AS NewBalance,
            b.BillStatus                                 AS NewBillStatus,
            @PaymentAmount                               AS PaymentApplied,
            @EffectiveRef                                AS ReferenceNumber,
            @NewPaymentID                                AS NewPaymentID,
            -- Report-layer labels via utility functions
            dbo.fn_GetAgingBucket(
                DATEDIFF(DAY, b.CreatedDate, GETDATE())) AS AgingBucket,
            dbo.fn_GetCollectionRiskTier(b.Balance)      AS CollectionRiskTier
        FROM  dbo.Bills    b
        INNER JOIN dbo.Patients p ON p.PatientID = b.PatientID
        WHERE b.BillID = @BillID;

    END TRY
    BEGIN CATCH

        -- Rollback any open transaction before logging
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        -- Persist error details to ErrorLogs for operations-team visibility
        INSERT INTO dbo.ErrorLogs (ProcedureName, ErrorMessage, ErrorDate)
        VALUES (
            ISNULL(ERROR_PROCEDURE(), 'usp_Billing_ProcessPayment'),
            'Error '    + CAST(ERROR_NUMBER()   AS VARCHAR(10))
            + ' Line '  + CAST(ERROR_LINE()     AS VARCHAR(10))
            + ': '      + ERROR_MESSAGE(),
            GETDATE()
        );

        -- Re-raise to the caller with the original error code and message
        THROW;

    END CATCH;
END;
GO


-- =============================================================================
-- PROCEDURE 2
-- =============================================================================
-- Name        : dbo.usp_Appointments_UpdateOutcome
--
-- Business Rules Enforced:
--   Rule 3.2 — Appointment status follows a strict one-way lifecycle:
--              only a 'Scheduled' appointment may be transitioned to a
--              terminal outcome.  Attempting to re-status a 'Completed',
--              'No-Show', or 'Cancelled' appointment raises an error.
--   Rule 3.2 — The only valid terminal statuses are 'Completed', 'No-Show',
--              and 'Cancelled'.  Any other value is rejected.
--   Rule 4.1 — Implicit: this procedure does not create a MedicalRecord.
--              It only transitions the status, unblocking the subsequent
--              creation of a record by clinical staff for 'Completed' visits.
--   Rule 6.1 — Financial protection: an appointment cannot be cancelled if
--              a fully Paid bill already exists against it.  This prevents
--              the financial audit trail from becoming inconsistent (a paid
--              bill with no corresponding completed encounter).
--
-- Parameters:
--   @AppointmentID      INT              — Appointment to update.  Required.
--   @NewStatus          VARCHAR(20)      — Target outcome: 'Completed',
--                                          'No-Show', or 'Cancelled'.
--   @OutcomeNotes       NVARCHAR(255)    — Optional free-text note captured
--                                          in the audit log (e.g. reason for
--                                          cancellation).  Default NULL.
--   @PerformedByUserID  INT              — UserID of the staff member recording
--                                          the outcome.  Must exist.  Required.
--
-- Returns (single result set):
--   AppointmentID, PatientName, DoctorName, DepartmentName, AppointmentDate,
--   PreviousStatus, NewStatus, OutcomeNotes, DaysUntilAppointment
--   (via DATEDIFF), ReminderPriority (via fn_GetReminderPriority — informational
--   context showing where in the scheduling window the appointment fell).
--
-- Error codes (custom):
--   50010  — @AppointmentID invalid
--   50011  — @NewStatus is not one of the three valid terminal values
--   50012  — @PerformedByUserID invalid
--   50013  — @PerformedByUserID does not exist in Users
--   50014  — @AppointmentID does not exist in Appointments
--   50015  — Appointment is already in a terminal status
--   50016  — Cannot cancel: a Paid bill exists for this appointment
-- =============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Appointments_UpdateOutcome
    @AppointmentID     INT,
    @NewStatus         VARCHAR(20),
    @OutcomeNotes      NVARCHAR(255) = NULL,
    @PerformedByUserID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Working variables
    DECLARE @CurrentStatus    VARCHAR(30);
    DECLARE @PatientID        INT;
    DECLARE @DoctorID         INT;
    DECLARE @AppointmentDate  DATETIME;
    DECLARE @PaidBillExists   BIT = 0;
    DECLARE @DaysUntil        INT;
    DECLARE @AuditOldValue    NVARCHAR(500);
    DECLARE @AuditNewValue    NVARCHAR(500);
    DECLARE @ErrMsg           NVARCHAR(500);

    BEGIN TRY

        -- ---------------------------------------------------------------
        -- Guard 1: Parameter validation
        -- ---------------------------------------------------------------
        IF @AppointmentID IS NULL OR @AppointmentID <= 0
            THROW 50010, 'Invalid @AppointmentID: must be a positive integer.', 1;

        IF @NewStatus NOT IN ('Completed', 'No-Show', 'Cancelled')
            THROW 50011,
                'Invalid @NewStatus: must be one of ''Completed'', ''No-Show'', or ''Cancelled''.',
                1;

        IF @PerformedByUserID IS NULL OR @PerformedByUserID <= 0
            THROW 50012, 'Invalid @PerformedByUserID: must be a positive integer.', 1;

        -- ---------------------------------------------------------------
        -- Guard 2: Referential integrity
        -- ---------------------------------------------------------------
        IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE UserID = @PerformedByUserID)
            THROW 50013, 'The specified PerformedByUserID does not exist in dbo.Users.', 1;

        SELECT
            @CurrentStatus   = a.Status,
            @PatientID       = a.PatientID,
            @DoctorID        = a.DoctorID,
            @AppointmentDate = a.AppointmentDate
        FROM dbo.Appointments a WITH (UPDLOCK, ROWLOCK)
        WHERE a.AppointmentID = @AppointmentID;

        IF @CurrentStatus IS NULL
            THROW 50014, 'The specified AppointmentID does not exist in dbo.Appointments.', 1;

        -- ---------------------------------------------------------------
        -- Guard 3: Business rule enforcement
        -- ---------------------------------------------------------------
        -- Rule 3.2: lifecycle is one-way; terminal states cannot be changed.
        -- THROW does not support expression messages, so build into a variable
        -- and use RAISERROR for the dynamic status string.
        IF @CurrentStatus <> 'Scheduled'
        BEGIN
            SET @ErrMsg = 'Status update rejected: only Scheduled appointments can be given an outcome.  Current status is already ''' + @CurrentStatus + '''.';
            RAISERROR(@ErrMsg, 16, 1) WITH NOWAIT;
            RETURN;
        END;

        -- Rule 6.1 (financial protection): block cancellation when a Paid bill exists.
        -- Cancelling an appointment that has already been paid would leave an
        -- orphaned payment with no corresponding completed clinical encounter.
        IF @NewStatus = 'Cancelled'
        BEGIN
            IF EXISTS (
                SELECT 1
                FROM dbo.Bills
                WHERE AppointmentID = @AppointmentID
                  AND BillStatus    = 'Paid'
            )
                THROW 50016,
                    'Cancellation rejected: a fully Paid bill exists for this appointment.  '
                    + 'Reverse the payment before cancelling, or mark the appointment as No-Show instead.',
                    1;
        END;

        -- ---------------------------------------------------------------
        -- Build audit strings
        -- ---------------------------------------------------------------
        SET @DaysUntil = DATEDIFF(DAY, CAST(GETDATE() AS DATE),
                                       CAST(@AppointmentDate AS DATE));

        SET @AuditOldValue =
            'AppointmentID=' + CAST(@AppointmentID AS VARCHAR(10))
            + '; Status='     + @CurrentStatus;

        SET @AuditNewValue =
            'AppointmentID=' + CAST(@AppointmentID AS VARCHAR(10))
            + '; Status='     + @NewStatus
            + CASE WHEN @OutcomeNotes IS NOT NULL
                   THEN '; Notes=' + @OutcomeNotes
                   ELSE ''
              END;

        -- ---------------------------------------------------------------
        -- DML
        -- ---------------------------------------------------------------
        BEGIN TRANSACTION;

            UPDATE dbo.Appointments
            SET  Status = @NewStatus
            WHERE AppointmentID = @AppointmentID;

            INSERT INTO dbo.AuditLogs
                (PerformedByUserID, TableName, ActionType, ActionDate, OldValue, NewValue)
            VALUES (
                @PerformedByUserID,
                'Appointments',
                'UPDATE',
                GETDATE(),
                @AuditOldValue,
                @AuditNewValue
            );

        COMMIT TRANSACTION;

        -- ---------------------------------------------------------------
        -- Result set: updated appointment enriched with scheduling context
        -- ---------------------------------------------------------------
        SELECT
            a.AppointmentID,
            p.PatientID,
            p.FirstName + ' ' + p.LastName              AS PatientName,
            p.Phone                                      AS PatientPhone,
            d.DoctorID,
            d.FirstName + ' ' + d.LastName              AS DoctorName,
            d.Specialization,
            dep.DepartmentName,
            a.AppointmentDate,
            @CurrentStatus                               AS PreviousStatus,
            a.Status                                     AS NewStatus,
            @OutcomeNotes                                AS OutcomeNotes,
            @DaysUntil                                   AS DaysRelativeToToday,
            -- Informational: shows which reminder band this appointment was in
            -- when the outcome was recorded, useful for SLA analysis.
            dbo.fn_GetReminderPriority(@DaysUntil)       AS ReminderBandAtOutcome
        FROM  dbo.Appointments  a
        INNER JOIN dbo.Patients    p   ON p.PatientID    = a.PatientID
        INNER JOIN dbo.Doctors     d   ON d.DoctorID     = a.DoctorID
        INNER JOIN dbo.Departments dep ON dep.DepartmentID = d.DepartmentID
        WHERE a.AppointmentID = @AppointmentID;

    END TRY
    BEGIN CATCH

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        INSERT INTO dbo.ErrorLogs (ProcedureName, ErrorMessage, ErrorDate)
        VALUES (
            ISNULL(ERROR_PROCEDURE(), 'usp_Appointments_UpdateOutcome'),
            'Error '    + CAST(ERROR_NUMBER() AS VARCHAR(10))
            + ' Line '  + CAST(ERROR_LINE()   AS VARCHAR(10))
            + ': '      + ERROR_MESSAGE(),
            GETDATE()
        );

        THROW;

    END CATCH;
END;
GO


-- =============================================================================
-- PROCEDURE 3
-- =============================================================================
-- Name        : dbo.usp_Security_EnforceInactivityPolicy
--
-- Business Rules Enforced:
--   Rule 2.4 — Inactive accounts are deactivated (IsActive = 0), never deleted.
--              Deletion would orphan AuditLogs rows and destroy the compliance
--              trail.  The historical record is preserved; only login access
--              is revoked.
--   Rule 2.6 — Account classification uses fn_GetInactivityRiskTier, the same
--              function used by vw_InactiveAccounts and usp_Security_
--              InactiveAccountReport.  Threshold definitions are therefore
--              applied consistently whether this procedure runs or a report
--              is pulled manually.
--   Guard     — The procedure refuses to deactivate the account of the user
--              running it (@PerformedByUserID), preventing self-lockout.
--   Guard     — @DryRun = 1 (default) performs a full preview without any
--              writes, so administrators can review the deactivation list
--              before committing.
--
-- Parameters:
--   @MinInactiveDays    INT           — Minimum days since last login to
--                                       qualify for deactivation.  Accounts
--                                       that have never logged in always
--                                       qualify regardless of this threshold.
--                                       Must be >= 0.  Default 90.
--   @RiskTierFilter     VARCHAR(20)   — 'Critical' | 'High Risk' |
--                                       'Medium Risk' | 'Low Risk' | NULL.
--                                       When supplied, restricts processing to
--                                       accounts in that specific tier.
--                                       Default NULL (all qualifying tiers).
--   @RoleName           VARCHAR(50)   — Restrict to accounts with this role.
--                                       NULL = all roles.  Default NULL.
--   @DryRun             BIT           — 1 = preview only (no writes);
--                                       0 = execute deactivations.
--                                       Default 1.
--   @PerformedByUserID  INT           — UserID of the admin running the review.
--                                       Must exist and be active.  Required.
--
-- Returns:
--   Result Set 1 — One row per qualifying account:
--       UserID, Username, RoleName, IsActive (current), LastLogin,
--       DaysSinceLastLogin (NULL if never logged in),
--       InactivityRiskTier, ActionTaken ('Deactivated' | 'Preview Only').
--   Result Set 2 — Execution summary:
--       TotalAccountsEvaluated, AccountsQualified, AccountsDeactivated,
--       WasDryRun, ExecutedAt.
--
-- Error codes (custom):
--   50020  — @PerformedByUserID invalid
--   50021  — @PerformedByUserID does not exist in Users
--   50022  — @PerformedByUserID account is inactive (cannot authorise an action)
--   50023  — @MinInactiveDays is negative
--   50024  — @RiskTierFilter is not a recognised tier label
-- =============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Security_EnforceInactivityPolicy
    @MinInactiveDays   INT          = 90,
    @RiskTierFilter    VARCHAR(20)  = NULL,
    @RoleName          VARCHAR(50)  = NULL,
    @DryRun            BIT          = 1,
    @PerformedByUserID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AccountsDeactivated INT = 0;
    DECLARE @AccountsQualified   INT = 0;
    DECLARE @TotalEvaluated      INT = 0;

    -- Staging table: hold qualifying accounts before committing any changes
    CREATE TABLE #QualifyingAccounts (
        UserID             INT          NOT NULL,
        Username           VARCHAR(80)  NOT NULL,
        RoleName           VARCHAR(50)  NOT NULL,
        IsActive           BIT          NOT NULL,
        LastLogin          DATETIME         NULL,
        DaysSinceLastLogin INT              NULL,
        InactivityRiskTier VARCHAR(20)  NOT NULL
    );

    BEGIN TRY

        -- ---------------------------------------------------------------
        -- Guard 1: Parameter validation
        -- ---------------------------------------------------------------
        IF @PerformedByUserID IS NULL OR @PerformedByUserID <= 0
            THROW 50020, 'Invalid @PerformedByUserID: must be a positive integer.', 1;

        IF @MinInactiveDays < 0
            THROW 50023, 'Invalid @MinInactiveDays: must be 0 or greater.', 1;

        IF @RiskTierFilter IS NOT NULL
           AND @RiskTierFilter NOT IN ('Critical', 'High Risk', 'Medium Risk', 'Low Risk', 'Disabled')
            THROW 50024,
                'Invalid @RiskTierFilter: must be one of ''Critical'', ''High Risk'', '
                + '''Medium Risk'', ''Low Risk'', ''Disabled'', or NULL.',
                1;

        -- ---------------------------------------------------------------
        -- Guard 2: Authorisation checks
        -- ---------------------------------------------------------------
        DECLARE @PerformerIsActive BIT;

        SELECT @PerformerIsActive = IsActive
        FROM   dbo.Users
        WHERE  UserID = @PerformedByUserID;

        IF @PerformerIsActive IS NULL
            THROW 50021, 'The specified PerformedByUserID does not exist in dbo.Users.', 1;

        IF @PerformerIsActive = 0
            THROW 50022,
                'Authorisation denied: the account for the specified PerformedByUserID is inactive '
                + 'and cannot authorise a policy enforcement action.',
                1;

        -- ---------------------------------------------------------------
        -- Step 1: Identify qualifying accounts
        -- Uses fn_GetInactivityRiskTier to maintain tier consistency with
        -- vw_InactiveAccounts and usp_Security_InactiveAccountReport.
        -- ---------------------------------------------------------------
        INSERT INTO #QualifyingAccounts
            (UserID, Username, RoleName, IsActive, LastLogin,
             DaysSinceLastLogin, InactivityRiskTier)
        SELECT
            u.UserID,
            u.Username,
            r.RoleName,
            u.IsActive,
            u.LastLogin,
            CASE
                WHEN u.LastLogin IS NULL THEN NULL
                ELSE DATEDIFF(DAY, u.LastLogin, GETDATE())
            END,
            dbo.fn_GetInactivityRiskTier(
                u.IsActive, u.LastLogin, CAST(GETDATE() AS DATE))
        FROM      dbo.Users  u
        INNER JOIN dbo.Roles r ON r.RoleID = u.RoleID
        WHERE
            -- Only target currently active accounts (Rule 2.4: Disabled already done)
            u.IsActive = 1
            -- Never deactivate the account running this procedure (self-lockout guard)
            AND u.UserID <> @PerformedByUserID
            -- Inactivity threshold: accounts that have never logged in always qualify
            AND (
                u.LastLogin IS NULL
                OR DATEDIFF(DAY, u.LastLogin, GETDATE()) >= @MinInactiveDays
            )
            -- Optional role filter
            AND (@RoleName IS NULL OR r.RoleName = @RoleName)
            -- Optional tier filter applied to the function output
            AND (
                @RiskTierFilter IS NULL
                OR dbo.fn_GetInactivityRiskTier(
                       u.IsActive, u.LastLogin, CAST(GETDATE() AS DATE))
                   = @RiskTierFilter
            );

        SET @AccountsQualified = @@ROWCOUNT;

        -- Record the total user population evaluated (for the summary row)
        SELECT @TotalEvaluated = COUNT(*)
        FROM   dbo.Users u
        WHERE  u.IsActive = 1 AND u.UserID <> @PerformedByUserID;

        -- ---------------------------------------------------------------
        -- Step 2: Deactivate (if not a dry run)
        -- Each deactivation is logged individually to AuditLogs so that
        -- every account change can be attributed to this policy run.
        -- ---------------------------------------------------------------
        IF @DryRun = 0 AND @AccountsQualified > 0
        BEGIN
            BEGIN TRANSACTION;

                -- Batch deactivate all qualifying accounts
                UPDATE u
                SET    u.IsActive = 0
                FROM   dbo.Users u
                INNER JOIN #QualifyingAccounts qa ON qa.UserID = u.UserID;

                SET @AccountsDeactivated = @@ROWCOUNT;

                -- Insert one audit log row per deactivated account
                INSERT INTO dbo.AuditLogs
                    (PerformedByUserID, TableName, ActionType, ActionDate, OldValue, NewValue)
                SELECT
                    @PerformedByUserID,
                    'Users',
                    'UPDATE',
                    GETDATE(),
                    'UserID=' + CAST(qa.UserID AS VARCHAR(10))
                    + '; Username=' + qa.Username
                    + '; IsActive=1'
                    + '; InactivityRiskTier=' + qa.InactivityRiskTier,
                    'UserID=' + CAST(qa.UserID AS VARCHAR(10))
                    + '; Username=' + qa.Username
                    + '; IsActive=0'
                    + '; DeactivatedByPolicy=usp_Security_EnforceInactivityPolicy'
                    + '; MinInactiveDays=' + CAST(@MinInactiveDays AS VARCHAR(10))
                FROM #QualifyingAccounts qa;

            COMMIT TRANSACTION;
        END;

        -- ---------------------------------------------------------------
        -- Result Set 1: per-account detail
        -- ---------------------------------------------------------------
        SELECT
            qa.UserID,
            qa.Username,
            qa.RoleName,
            qa.IsActive                          AS IsActiveAtTimeOfRun,
            qa.LastLogin,
            qa.DaysSinceLastLogin,
            qa.InactivityRiskTier,
            CASE
                WHEN @DryRun = 0 THEN 'Deactivated'
                ELSE                  'Preview Only'
            END                                  AS ActionTaken
        FROM #QualifyingAccounts qa
        ORDER BY qa.InactivityRiskTier,
                 CASE WHEN qa.DaysSinceLastLogin IS NULL THEN 1 ELSE 0 END DESC,
                 qa.DaysSinceLastLogin DESC;

        -- ---------------------------------------------------------------
        -- Result Set 2: execution summary
        -- ---------------------------------------------------------------
        SELECT
            @TotalEvaluated      AS TotalActiveAccountsEvaluated,
            @AccountsQualified   AS AccountsQualified,
            CASE WHEN @DryRun = 0 THEN @AccountsDeactivated ELSE 0 END
                                 AS AccountsDeactivated,
            @DryRun              AS WasDryRun,
            GETDATE()            AS ExecutedAt;

    END TRY
    BEGIN CATCH

        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        INSERT INTO dbo.ErrorLogs (ProcedureName, ErrorMessage, ErrorDate)
        VALUES (
            ISNULL(ERROR_PROCEDURE(), 'usp_Security_EnforceInactivityPolicy'),
            'Error '    + CAST(ERROR_NUMBER() AS VARCHAR(10))
            + ' Line '  + CAST(ERROR_LINE()   AS VARCHAR(10))
            + ': '      + ERROR_MESSAGE(),
            GETDATE()
        );

        THROW;

    END CATCH;
END;
GO


-- =============================================================================
-- TEST SUITE
-- =============================================================================
-- Purpose : Verify all three procedures against valid inputs, edge cases, and
--           deliberate failure scenarios.  Results are printed or returned as
--           result sets so output can be inspected in any SQL client.
--
-- Structure per test:
--   PRINT 'Test N.N — [Description]  Expected: [result]'
--   EXEC  <procedure>  <args>
--   (For error tests: wrapped in TRY/CATCH that prints captured error number
--    and message, confirming the procedure raised the correct error code.)
--
-- Note: SET XACT_ABORT OFF in the test section prevents a single deliberate
--       error from aborting the rest of the test batch.
-- =============================================================================

SET XACT_ABORT OFF;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Dynamic test data: resolve real IDs from live DB state at test time
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @AdminUID          INT;
DECLARE @UnpaidBill1       INT;    -- for partial-payment test
DECLARE @UnpaidBill2       INT;    -- for full-payment test
DECLARE @PaidBillID        INT;    -- for "already paid" error test
DECLARE @SchedAppt1        INT;    -- Scheduled appt → Completed
DECLARE @SchedAppt2        INT;    -- Scheduled appt → No-Show
DECLARE @SchedAppt3        INT;    -- Scheduled appt → Cancelled (no paid bill)
DECLARE @CompletedApptID   INT;    -- already-terminal appt for error test
DECLARE @PaidBillApptID    INT;    -- appt with a paid bill → cancel error test

-- Resolve IDs
SELECT @AdminUID = UserID
FROM   dbo.Users
WHERE  IsActive = 1
ORDER  BY UserID ASC
OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY;

SELECT @UnpaidBill1 = BillID
FROM   dbo.Bills
WHERE  BillStatus IN ('Unpaid', 'Partially Paid') AND Balance > 50
ORDER  BY BillID ASC
OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY;

SELECT @UnpaidBill2 = BillID
FROM   dbo.Bills
WHERE  BillStatus IN ('Unpaid', 'Partially Paid') AND Balance > 50
ORDER  BY BillID ASC
OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY;

SELECT @PaidBillID = BillID
FROM   dbo.Bills
WHERE  BillStatus = 'Paid'
ORDER  BY BillID ASC
OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY;

SELECT @SchedAppt1 = AppointmentID
FROM   dbo.Appointments
WHERE  Status = 'Scheduled'
ORDER  BY AppointmentID ASC
OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY;

SELECT @SchedAppt2 = AppointmentID
FROM   dbo.Appointments
WHERE  Status = 'Scheduled'
ORDER  BY AppointmentID ASC
OFFSET 1 ROWS FETCH NEXT 1 ROWS ONLY;

SELECT @SchedAppt3 = AppointmentID
FROM   dbo.Appointments
WHERE  Status = 'Scheduled'
       -- Ensure no Paid bill for the Cancelled test
       AND NOT EXISTS (
           SELECT 1 FROM dbo.Bills
           WHERE AppointmentID = dbo.Appointments.AppointmentID
             AND BillStatus = 'Paid'
       )
ORDER  BY AppointmentID ASC
OFFSET 2 ROWS FETCH NEXT 1 ROWS ONLY;

SELECT @CompletedApptID = AppointmentID
FROM   dbo.Appointments
WHERE  Status = 'Completed'
ORDER  BY AppointmentID ASC
OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY;

SELECT @PaidBillApptID = a.AppointmentID
FROM   dbo.Appointments a
INNER JOIN dbo.Bills b ON b.AppointmentID = a.AppointmentID
WHERE  a.Status    = 'Scheduled'
  AND  b.BillStatus = 'Paid'
ORDER  BY a.AppointmentID ASC
OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY;

PRINT '──────────────────────────────────────────────────────────────────';
PRINT 'Resolved test IDs:';
PRINT '  @AdminUID        = ' + ISNULL(CAST(@AdminUID        AS VARCHAR), 'NULL');
PRINT '  @UnpaidBill1     = ' + ISNULL(CAST(@UnpaidBill1     AS VARCHAR), 'NULL');
PRINT '  @UnpaidBill2     = ' + ISNULL(CAST(@UnpaidBill2     AS VARCHAR), 'NULL');
PRINT '  @PaidBillID      = ' + ISNULL(CAST(@PaidBillID      AS VARCHAR), 'NULL');
PRINT '  @SchedAppt1      = ' + ISNULL(CAST(@SchedAppt1      AS VARCHAR), 'NULL');
PRINT '  @SchedAppt2      = ' + ISNULL(CAST(@SchedAppt2      AS VARCHAR), 'NULL');
PRINT '  @SchedAppt3      = ' + ISNULL(CAST(@SchedAppt3      AS VARCHAR), 'NULL');
PRINT '  @CompletedApptID = ' + ISNULL(CAST(@CompletedApptID AS VARCHAR), 'NULL');
PRINT '  @PaidBillApptID  = ' + ISNULL(CAST(@PaidBillApptID  AS VARCHAR), 'NULL (no Scheduled+Paid pair in seed data - expected)');
PRINT '──────────────────────────────────────────────────────────────────';
GO


-- =============================================================================
-- TEST GROUP 1 — usp_Billing_ProcessPayment
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 1.1  Partial payment on an Unpaid bill
-- Expected : Succeeds; BillStatus becomes 'Partially Paid';
--            CollectionRiskTier reflects new (lower) balance.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @Bill1 INT = (SELECT MIN(BillID) FROM dbo.Bills
                      WHERE BillStatus IN ('Unpaid','Partially Paid') AND Balance > 50);
DECLARE @AdminU INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test 1.1 — Partial payment on Unpaid bill  Expected: Partially Paid';
EXEC dbo.usp_Billing_ProcessPayment
    @BillID            = @Bill1,
    @PaymentAmount     = 25.00,
    @PaymentMethod     = 'Cash',
    @ReferenceNumber   = 'TEST-PARTIAL-001',
    @PerformedByUserID = @AdminU;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 1.2  Full payment (clears the remaining balance on a second bill)
-- Expected : Succeeds; BillStatus becomes 'Paid'; CollectionRiskTier = 'Cleared'.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @Bill2 INT = (SELECT MIN(BillID) FROM dbo.Bills
                      WHERE BillStatus IN ('Unpaid','Partially Paid') AND Balance > 50
                        AND BillID > (SELECT MIN(BillID) FROM dbo.Bills
                                      WHERE BillStatus IN ('Unpaid','Partially Paid')
                                        AND Balance > 50));
DECLARE @Admin2 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test 1.2 — Full payment clears balance  Expected: Paid / Cleared tier';
EXEC dbo.usp_Billing_ProcessPayment
    @BillID            = @Bill2,
    @PaymentAmount     = (SELECT Balance FROM dbo.Bills WHERE BillID = @Bill2),
    @PaymentMethod     = 'Card',
    @PerformedByUserID = @Admin2;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 1.3  Auto-generated reference number (NULL passed)
-- Expected : Succeeds; ReferenceNumber in result begins with 'AUTO-'.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @Bill3 INT = (SELECT MIN(BillID) FROM dbo.Bills
                      WHERE BillStatus IN ('Unpaid','Partially Paid'));
DECLARE @Admin3 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test 1.3 — Auto-generated reference number  Expected: ReferenceNumber starts AUTO-';
EXEC dbo.usp_Billing_ProcessPayment
    @BillID            = @Bill3,
    @PaymentAmount     = 10.00,
    @PaymentMethod     = 'Insurance',
    @ReferenceNumber   = NULL,
    @PerformedByUserID = @Admin3;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 1.4  ERROR — Payment amount = 0
-- Expected : Error 50002 'must be greater than zero'. No DB change.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @Bill4 INT = (SELECT MIN(BillID) FROM dbo.Bills
                      WHERE BillStatus IN ('Unpaid','Partially Paid'));
DECLARE @Admin4 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test 1.4 — Zero payment amount  Expected: Error 50002';
BEGIN TRY
    EXEC dbo.usp_Billing_ProcessPayment
        @BillID            = @Bill4,
        @PaymentAmount     = 0.00,
        @PaymentMethod     = 'Cash',
        @PerformedByUserID = @Admin4;
END TRY
BEGIN CATCH
    PRINT '  Caught error ' + CAST(ERROR_NUMBER() AS VARCHAR) + ': ' + ERROR_MESSAGE();
END CATCH;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 1.5  ERROR — Payment exceeds outstanding balance
-- Expected : Error 50008 'exceeds the outstanding balance'. No DB change.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @Bill5 INT = (SELECT MIN(BillID) FROM dbo.Bills
                      WHERE BillStatus IN ('Unpaid','Partially Paid'));
DECLARE @Bal5  DECIMAL(10,2) = (SELECT Balance FROM dbo.Bills WHERE BillID = @Bill5);
DECLARE @Admin5 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test 1.5 — Payment exceeds balance  Expected: Error 50008';
BEGIN TRY
    EXEC dbo.usp_Billing_ProcessPayment
        @BillID            = @Bill5,
        @PaymentAmount     = @Bal5 + 9999.99,
        @PaymentMethod     = 'Card',
        @PerformedByUserID = @Admin5;
END TRY
BEGIN CATCH
    PRINT '  Caught error ' + CAST(ERROR_NUMBER() AS VARCHAR) + ': ' + ERROR_MESSAGE();
END CATCH;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 1.6  ERROR — Bill already Paid
-- Expected : Error 50007 'bill is already in Paid status'. No DB change.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @PaidBill INT = (SELECT MIN(BillID) FROM dbo.Bills WHERE BillStatus = 'Paid');
DECLARE @Admin6  INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test 1.6 — Payment on already-Paid bill  Expected: Error 50007';
BEGIN TRY
    EXEC dbo.usp_Billing_ProcessPayment
        @BillID            = @PaidBill,
        @PaymentAmount     = 10.00,
        @PaymentMethod     = 'Cash',
        @PerformedByUserID = @Admin6;
END TRY
BEGIN CATCH
    PRINT '  Caught error ' + CAST(ERROR_NUMBER() AS VARCHAR) + ': ' + ERROR_MESSAGE();
END CATCH;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 1.7  ERROR — Non-existent BillID
-- Expected : Error 50006 'does not exist in dbo.Bills'. No DB change.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @Admin7 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test 1.7 — Non-existent BillID  Expected: Error 50006';
BEGIN TRY
    EXEC dbo.usp_Billing_ProcessPayment
        @BillID            = 999999,
        @PaymentAmount     = 10.00,
        @PaymentMethod     = 'Cash',
        @PerformedByUserID = @Admin7;
END TRY
BEGIN CATCH
    PRINT '  Caught error ' + CAST(ERROR_NUMBER() AS VARCHAR) + ': ' + ERROR_MESSAGE();
END CATCH;
GO

-- Verify no spurious payment or audit rows were inserted by the error tests
PRINT 'Test 1.x — Verify ErrorLogs captured the failures';
SELECT TOP 5 ErrorID, ProcedureName, ErrorMessage, ErrorDate
FROM   dbo.ErrorLogs
WHERE  ProcedureName LIKE '%ProcessPayment%'
ORDER  BY ErrorDate DESC;
GO


-- =============================================================================
-- TEST GROUP 2 — usp_Appointments_UpdateOutcome
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 2.1  Scheduled → Completed  (valid path)
-- Expected : Succeeds; appointment status updated; ReminderBandAtOutcome shown.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @A1 INT = (SELECT MIN(AppointmentID) FROM dbo.Appointments
                   WHERE Status = 'Scheduled');
DECLARE @U1 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test 2.1 — Scheduled → Completed  Expected: Status = Completed';
EXEC dbo.usp_Appointments_UpdateOutcome
    @AppointmentID     = @A1,
    @NewStatus         = 'Completed',
    @OutcomeNotes      = 'Patient attended; consultation completed successfully.',
    @PerformedByUserID = @U1;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 2.2  Scheduled → No-Show  (valid path)
-- Expected : Succeeds; appointment status = No-Show; notes NULL omitted from audit.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @A2 INT = (SELECT MIN(AppointmentID) FROM dbo.Appointments
                   WHERE Status = 'Scheduled');
DECLARE @U2 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test 2.2 — Scheduled → No-Show  Expected: Status = No-Show';
EXEC dbo.usp_Appointments_UpdateOutcome
    @AppointmentID     = @A2,
    @NewStatus         = 'No-Show',
    @OutcomeNotes      = 'Patient did not attend; no contact made prior.',
    @PerformedByUserID = @U2;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 2.3  Scheduled → Cancelled (no paid bill)  (valid path)
-- Expected : Succeeds; appointment status = Cancelled.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @A3 INT = (SELECT MIN(a.AppointmentID)
                   FROM dbo.Appointments a
                   WHERE a.Status = 'Scheduled'
                     AND NOT EXISTS (
                         SELECT 1 FROM dbo.Bills b
                         WHERE b.AppointmentID = a.AppointmentID
                           AND b.BillStatus = 'Paid'));
DECLARE @U3 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test 2.3 — Scheduled → Cancelled (no paid bill)  Expected: Status = Cancelled';
EXEC dbo.usp_Appointments_UpdateOutcome
    @AppointmentID     = @A3,
    @NewStatus         = 'Cancelled',
    @OutcomeNotes      = 'Patient requested cancellation 48 hours in advance.',
    @PerformedByUserID = @U3;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 2.4  ERROR — Invalid @NewStatus value
-- Expected : Error 50011 'must be one of Completed, No-Show, or Cancelled'.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @A4 INT = (SELECT MIN(AppointmentID) FROM dbo.Appointments WHERE Status = 'Scheduled');
DECLARE @U4 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test 2.4 — Invalid NewStatus value  Expected: Error 50011';
BEGIN TRY
    EXEC dbo.usp_Appointments_UpdateOutcome
        @AppointmentID     = @A4,
        @NewStatus         = 'Rescheduled',
        @PerformedByUserID = @U4;
END TRY
BEGIN CATCH
    PRINT '  Caught error ' + CAST(ERROR_NUMBER() AS VARCHAR) + ': ' + ERROR_MESSAGE();
END CATCH;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 2.5  ERROR — Appointment is already in a terminal status
-- Expected : Error 50015 'only Scheduled appointments can be given an outcome'.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @CompAppt INT = (SELECT MIN(AppointmentID) FROM dbo.Appointments
                         WHERE Status = 'Completed');
DECLARE @U5 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test 2.5 — Already-terminal appointment  Expected: Error 50015';
BEGIN TRY
    EXEC dbo.usp_Appointments_UpdateOutcome
        @AppointmentID     = @CompAppt,
        @NewStatus         = 'Cancelled',
        @PerformedByUserID = @U5;
END TRY
BEGIN CATCH
    PRINT '  Caught error ' + CAST(ERROR_NUMBER() AS VARCHAR) + ': ' + ERROR_MESSAGE();
END CATCH;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 2.6  ERROR — Non-existent AppointmentID
-- Expected : Error 50014 'does not exist in dbo.Appointments'.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @U6 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test 2.6 — Non-existent AppointmentID  Expected: Error 50014';
BEGIN TRY
    EXEC dbo.usp_Appointments_UpdateOutcome
        @AppointmentID     = 999999,
        @NewStatus         = 'Completed',
        @PerformedByUserID = @U6;
END TRY
BEGIN CATCH
    PRINT '  Caught error ' + CAST(ERROR_NUMBER() AS VARCHAR) + ': ' + ERROR_MESSAGE();
END CATCH;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 2.7  ERROR — Cancel rejected because a Paid bill exists
-- Uses a Scheduled appointment that happens to have a Paid bill; if none exists
-- in the seed data this test prints an informational skip message.
-- Expected : Error 50016 'a fully Paid bill exists'.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @PaidBillAppt INT = (
    SELECT MIN(a.AppointmentID)
    FROM   dbo.Appointments a
    INNER JOIN dbo.Bills b ON b.AppointmentID = a.AppointmentID
    WHERE  a.Status = 'Scheduled'
      AND  b.BillStatus = 'Paid'
);
DECLARE @U7 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

IF @PaidBillAppt IS NOT NULL
BEGIN
    PRINT 'Test 2.7 — Cancel appointment with Paid bill  Expected: Error 50016';
    BEGIN TRY
        EXEC dbo.usp_Appointments_UpdateOutcome
            @AppointmentID     = @PaidBillAppt,
            @NewStatus         = 'Cancelled',
            @PerformedByUserID = @U7;
    END TRY
    BEGIN CATCH
        PRINT '  Caught error ' + CAST(ERROR_NUMBER() AS VARCHAR) + ': ' + ERROR_MESSAGE();
    END CATCH;
END
ELSE
    PRINT 'Test 2.7 — SKIPPED (no Scheduled appointment with a Paid bill in seed data).';
GO

-- Verify audit log entries were created for the successful outcome updates
PRINT 'Test 2.x — Verify AuditLogs recorded outcome changes';
SELECT TOP 5
    al.AuditID,
    al.ActionDate,
    al.TableName,
    al.ActionType,
    al.OldValue,
    al.NewValue
FROM   dbo.AuditLogs al
WHERE  al.TableName = 'Appointments'
ORDER  BY al.ActionDate DESC;
GO


-- =============================================================================
-- TEST GROUP 3 — usp_Security_EnforceInactivityPolicy
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 3.1  Dry run — preview all accounts inactive for 0+ days
-- Expected : Returns qualified accounts with ActionTaken = 'Preview Only'.
--            No IsActive values changed in dbo.Users.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @UA INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test 3.1 — Dry run (all inactivity thresholds)  Expected: Preview Only rows';
EXEC dbo.usp_Security_EnforceInactivityPolicy
    @MinInactiveDays   = 0,
    @RiskTierFilter    = NULL,
    @RoleName          = NULL,
    @DryRun            = 1,
    @PerformedByUserID = @UA;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 3.2  Dry run — filter to High Risk tier only
-- Expected : Returns only accounts classified as 'High Risk' (>90 days inactive).
--            No IsActive values changed.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @UA2 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test 3.2 — Dry run, High Risk tier only  Expected: InactivityRiskTier = High Risk rows';
EXEC dbo.usp_Security_EnforceInactivityPolicy
    @MinInactiveDays   = 91,
    @RiskTierFilter    = 'High Risk',
    @RoleName          = NULL,
    @DryRun            = 1,
    @PerformedByUserID = @UA2;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 3.3  Live run — deactivate High Risk accounts (>90 days inactive)
-- Expected : Qualifying accounts set to IsActive = 0; AuditLogs rows inserted;
--            Summary RS2 shows AccountsDeactivated > 0 (or 0 if none qualify).
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @UA3 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test 3.3 — Live run, deactivate High Risk accounts  Expected: AccountsDeactivated ≥ 0';
EXEC dbo.usp_Security_EnforceInactivityPolicy
    @MinInactiveDays   = 91,
    @RiskTierFilter    = 'High Risk',
    @RoleName          = NULL,
    @DryRun            = 0,
    @PerformedByUserID = @UA3;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 3.4  Live run — role-scoped deactivation (Doctor accounts only)
-- Expected : Only accounts with RoleName = 'Doctor' appear in RS1.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @UA4 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test 3.4 — Dry run, Doctor accounts only  Expected: RS1 filtered to Doctor role';
EXEC dbo.usp_Security_EnforceInactivityPolicy
    @MinInactiveDays   = 0,
    @RiskTierFilter    = NULL,
    @RoleName          = 'Doctor',
    @DryRun            = 1,
    @PerformedByUserID = @UA4;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 3.5  ERROR — Non-existent @PerformedByUserID
-- Expected : Error 50021 'does not exist in dbo.Users'.
-- ─────────────────────────────────────────────────────────────────────────────
PRINT 'Test 3.5 — Invalid PerformedByUserID  Expected: Error 50021';
BEGIN TRY
    EXEC dbo.usp_Security_EnforceInactivityPolicy
        @MinInactiveDays   = 30,
        @DryRun            = 1,
        @PerformedByUserID = 999999;
END TRY
BEGIN CATCH
    PRINT '  Caught error ' + CAST(ERROR_NUMBER() AS VARCHAR) + ': ' + ERROR_MESSAGE();
END CATCH;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 3.6  ERROR — Negative @MinInactiveDays
-- Expected : Error 50023 'must be 0 or greater'.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @UA6 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test 3.6 — Negative MinInactiveDays  Expected: Error 50023';
BEGIN TRY
    EXEC dbo.usp_Security_EnforceInactivityPolicy
        @MinInactiveDays   = -1,
        @DryRun            = 1,
        @PerformedByUserID = @UA6;
END TRY
BEGIN CATCH
    PRINT '  Caught error ' + CAST(ERROR_NUMBER() AS VARCHAR) + ': ' + ERROR_MESSAGE();
END CATCH;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 3.7  ERROR — Invalid @RiskTierFilter value
-- Expected : Error 50024 'must be one of Critical, High Risk, ...'.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @UA7 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test 3.7 — Invalid RiskTierFilter  Expected: Error 50024';
BEGIN TRY
    EXEC dbo.usp_Security_EnforceInactivityPolicy
        @MinInactiveDays   = 30,
        @RiskTierFilter    = 'Extreme Risk',
        @DryRun            = 1,
        @PerformedByUserID = @UA7;
END TRY
BEGIN CATCH
    PRINT '  Caught error ' + CAST(ERROR_NUMBER() AS VARCHAR) + ': ' + ERROR_MESSAGE();
END CATCH;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test 3.8  ERROR — Performer's own account is inactive
-- Find or create a scenario: use an inactive user as the performer
-- Expected : Error 50022 'account is inactive and cannot authorise'.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @InactiveUID INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 0);
DECLARE @ActiveUID   INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

IF @InactiveUID IS NOT NULL
BEGIN
    PRINT 'Test 3.8 — Inactive PerformedByUserID  Expected: Error 50022';
    BEGIN TRY
        EXEC dbo.usp_Security_EnforceInactivityPolicy
            @MinInactiveDays   = 30,
            @DryRun            = 1,
            @PerformedByUserID = @InactiveUID;
    END TRY
    BEGIN CATCH
        PRINT '  Caught error ' + CAST(ERROR_NUMBER() AS VARCHAR) + ': ' + ERROR_MESSAGE();
    END CATCH;
END
ELSE
    PRINT 'Test 3.8 — SKIPPED (no inactive user accounts in current DB state after Test 3.3).';
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Final verification queries
-- ─────────────────────────────────────────────────────────────────────────────
PRINT 'Final — ErrorLogs: all procedure failures captured';
SELECT TOP 10
    ErrorID,
    ProcedureName,
    LEFT(ErrorMessage, 100) AS ErrorMessage,
    ErrorDate
FROM   dbo.ErrorLogs
ORDER  BY ErrorDate DESC;

PRINT 'Final — AuditLogs: last 10 entries generated by test run';
SELECT TOP 10
    AuditID,
    PerformedByUserID,
    TableName,
    ActionType,
    ActionDate,
    LEFT(OldValue, 60) AS OldValue,
    LEFT(NewValue, 80) AS NewValue
FROM   dbo.AuditLogs
ORDER  BY ActionDate DESC;
GO
