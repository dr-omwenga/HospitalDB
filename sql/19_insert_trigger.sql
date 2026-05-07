-- =============================================================================
-- HospitalDB — INSERT Trigger on dbo.Bills
-- File        : sql/19_insert_trigger.sql
-- Author      : Hospital Information Systems
-- Date        : 2026-05-07
-- Description :
--   An AFTER INSERT trigger on dbo.Bills that automatically enforces six
--   business rules at the database layer, independent of which application
--   path performs the insert (stored procedure, ad-hoc SQL, ETL, etc.).
--
--   ─── RULES ───────────────────────────────────────────────────────────────
--
--   Rule 1 — AMOUNT VALIDATION (reject on failure)
--     TotalAmount must be > 0.  Bills with a zero or negative total are
--     rejected atomically: the INSERT is rolled back and an error is raised
--     before any row is committed.
--
--   Rule 2 — PAYMENT RANGE VALIDATION (reject on failure)
--     PaidAmount must be in [0, TotalAmount].  An overpayment or a negative
--     paid amount is rejected atomically.
--
--   Rule 3 — BALANCE AUTO-CORRECTION (derived field)
--     Balance is always overwritten to (TotalAmount − PaidAmount), ignoring
--     whatever value the caller supplied.  This enforces a single source of
--     truth for the balance column regardless of the insertion path.
--
--   Rule 4 — STATUS AUTO-DERIVATION (derived field)
--     BillStatus is always derived from the monetary columns, overwriting any
--     caller-supplied value:
--       PaidAmount = 0                       → 'Unpaid'
--       0 < PaidAmount < TotalAmount         → 'Partially Paid'
--       PaidAmount = TotalAmount             → 'Paid'
--
--   Rule 5 — CREATEDDATE SERVER-TIMESTAMP ENFORCEMENT
--     CreatedDate is always overwritten to the server's current GETDATE(),
--     preventing client-side backdating of financial records.
--
--   Rule 6 — AUDIT LOGGING
--     Every successful bill insertion is recorded in dbo.AuditLogs with the
--     final corrected column values (not the raw caller input).
--
--   ─── PATTERN ─────────────────────────────────────────────────────────────
--   AFTER INSERT is used (not INSTEAD OF) so that IDENTITY values are
--   assigned by the engine before the trigger fires; this lets the trigger
--   reference inserted.BillID for the UPDATE and AuditLog INSERT.
--   Validation failures use ROLLBACK TRANSACTION + RAISERROR + RETURN,
--   which rolls back the inserted rows atomically before the error propagates.
--
--   ─── OBJECTS CREATED ─────────────────────────────────────────────────────
--   dbo.trg_Bills_AfterInsert   AFTER INSERT trigger on dbo.Bills
--
--   ─── TEST CASES ──────────────────────────────────────────────────────────
--   TC-1  Valid insert, all values correct          → bill created, audit logged
--   TC-2  Wrong Balance and BillStatus passed       → auto-corrected
--   TC-3  Fully paid with Status = 'Unpaid' passed  → Status auto-corrected to 'Paid'
--   TC-4  Backdated CreatedDate passed              → overwritten to server timestamp
--   TC-5  TotalAmount ≤ 0                           → rejected, rollback, Error 50000
--   TC-6  PaidAmount > TotalAmount                  → rejected, rollback, Error 50000
-- =============================================================================

USE HospitalDB;
GO

-- =============================================================================
-- SECTION 1: AFTER INSERT trigger
-- =============================================================================

CREATE OR ALTER TRIGGER dbo.trg_Bills_AfterInsert
ON dbo.Bills
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    -- Working variables declared at trigger scope
    DECLARE @R1IDs       NVARCHAR(400);
    DECLARE @R2IDs       NVARCHAR(400);
    DECLARE @Msg         NVARCHAR(500);
    DECLARE @AuditUserID INT;

    -- -------------------------------------------------------------------------
    -- Rule 1: TotalAmount must be > 0.
    -- If any row in the batch violates this, roll back the entire INSERT and
    -- raise a descriptive error listing the offending rows.
    -- -------------------------------------------------------------------------
    IF EXISTS (SELECT 1 FROM inserted WHERE TotalAmount <= 0)
    BEGIN
        SELECT @R1IDs = STUFF(
            (SELECT ', ' + CAST(BillID AS VARCHAR(10))
             FROM inserted
             WHERE TotalAmount <= 0
             FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(400)'),
            1, 2, '');

        SET @Msg =
            'INSERT blocked by Rule 1 (Amount Validation): Bill(s) ['
            + @R1IDs
            + '] — TotalAmount must be greater than zero.'
            + ' A bill cannot have a zero or negative total amount.';

        ROLLBACK TRANSACTION;
        RAISERROR(@Msg, 16, 1);
        RETURN;
    END;

    -- -------------------------------------------------------------------------
    -- Rule 2: PaidAmount must be in [0, TotalAmount].
    -- Negative payments and overpayments are rejected atomically.
    -- -------------------------------------------------------------------------
    IF EXISTS (SELECT 1 FROM inserted WHERE PaidAmount < 0 OR PaidAmount > TotalAmount)
    BEGIN
        SELECT @R2IDs = STUFF(
            (SELECT ', ' + CAST(BillID AS VARCHAR(10))
             FROM inserted
             WHERE PaidAmount < 0 OR PaidAmount > TotalAmount
             FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(400)'),
            1, 2, '');

        SET @Msg =
            'INSERT blocked by Rule 2 (Payment Range): Bill(s) ['
            + @R2IDs
            + '] — PaidAmount must be between 0 and TotalAmount (inclusive).'
            + ' Record the payment through dbo.Payments to update a bill balance.';

        ROLLBACK TRANSACTION;
        RAISERROR(@Msg, 16, 1);
        RETURN;
    END;

    -- -------------------------------------------------------------------------
    -- Rules 3, 4, 5: Auto-correct Balance, BillStatus, and CreatedDate.
    --
    --   Balance     = TotalAmount - PaidAmount   (overrides caller's value)
    --   BillStatus  = derived from amounts       (overrides caller's value)
    --   CreatedDate = GETDATE()                  (server time; prevents backdating)
    --
    -- Set-based UPDATE covers the entire batch in one pass.
    -- -------------------------------------------------------------------------
    UPDATE b
    SET
        b.Balance    = b.TotalAmount - b.PaidAmount,
        b.BillStatus = CASE
                           WHEN b.PaidAmount <= 0             THEN 'Unpaid'
                           WHEN b.PaidAmount >= b.TotalAmount THEN 'Paid'
                           ELSE                                    'Partially Paid'
                       END,
        b.CreatedDate = GETDATE()
    FROM dbo.Bills   b
    INNER JOIN inserted i ON i.BillID = b.BillID;

    -- -------------------------------------------------------------------------
    -- Rule 6: Audit every successful bill creation.
    -- Joins dbo.Bills (not inserted) to capture the final corrected values.
    -- PerformedByUserID resolves to the lowest active system user as the
    -- trigger actor.  In production, SESSION_CONTEXT(N'UserID') would supply
    -- the application user who originated the request.
    -- -------------------------------------------------------------------------
    SELECT @AuditUserID = MIN(UserID) FROM dbo.Users WHERE IsActive = 1;

    INSERT INTO dbo.AuditLogs
        (PerformedByUserID, TableName, ActionType, ActionDate, OldValue, NewValue)
    SELECT
        @AuditUserID,
        'Bills',
        'INSERT',
        GETDATE(),
        '',
        'BillID='          + CAST(b.BillID      AS VARCHAR(10))
        + '; PatientID='   + CAST(b.PatientID   AS VARCHAR(10))
        + '; TotalAmount=' + CAST(b.TotalAmount AS VARCHAR(20))
        + '; PaidAmount='  + CAST(b.PaidAmount  AS VARCHAR(20))
        + '; Balance='     + CAST(b.Balance     AS VARCHAR(20))
        + '; BillStatus='  + b.BillStatus
    FROM dbo.Bills   b
    INNER JOIN inserted i ON i.BillID = b.BillID;
END;
GO

-- =============================================================================
-- SECTION 2: Test Cases
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- TC-1 through TC-4: Success and auto-correction paths
-- All in a single batch to share BillID variables across verifications.
-- ─────────────────────────────────────────────────────────────────────────────

DECLARE @Pat  INT; SELECT @Pat  = MIN(PatientID)     FROM dbo.Patients;
DECLARE @Appt INT; SELECT @Appt = MIN(AppointmentID) FROM dbo.Appointments;

-- ── TC-1: VALID INSERT — all values correct as passed ────────────────────────
-- TotalAmount=300, PaidAmount=0, Balance=300, BillStatus='Unpaid', CreatedDate=now.
-- Expected: bill created with no corrections; AuditLog entry written.
INSERT INTO dbo.Bills
    (PatientID, AppointmentID, TotalAmount, PaidAmount, Balance, BillStatus, CreatedDate)
VALUES (@Pat, @Appt, 300.00, 0.00, 300.00, 'Unpaid', GETDATE());

DECLARE @B1 INT = SCOPE_IDENTITY();

SELECT
    'TC-1'                                                       AS Test,
    'Valid insert — values correct as passed'                    AS Description,
    BillID, TotalAmount, PaidAmount, Balance, BillStatus,
    CASE
        WHEN Balance = 300.00 AND BillStatus = 'Unpaid'
        THEN 'PASS'
        ELSE 'FAIL'
    END                                                          AS Result
FROM dbo.Bills WHERE BillID = @B1;

-- ── TC-2: AUTO-CORRECTION — wrong Balance and wrong BillStatus ───────────────
-- TotalAmount=500, PaidAmount=100 → correct: Balance=400, Status='Partially Paid'.
-- Caller passes: Balance=999.99 (wrong) and BillStatus='Unpaid' (wrong).
-- CreatedDate='1999-12-31' (backdated — should be overwritten by Rule 5).
-- Expected: trigger auto-corrects Balance, BillStatus, and CreatedDate.
INSERT INTO dbo.Bills
    (PatientID, AppointmentID, TotalAmount, PaidAmount, Balance, BillStatus, CreatedDate)
VALUES (@Pat, @Appt, 500.00, 100.00, 999.99, 'Unpaid', '1999-12-31 00:00:00');

DECLARE @B2 INT = SCOPE_IDENTITY();

SELECT
    'TC-2'                                                       AS Test,
    'Auto-correct: Balance + BillStatus + CreatedDate'           AS Description,
    BillID, TotalAmount, PaidAmount, Balance, BillStatus,
    CAST(CreatedDate AS DATE)                                    AS CreatedDateValue,
    CAST(GETDATE()   AS DATE)                                    AS TodayDate,
    CASE
        WHEN Balance     = 400.00
         AND BillStatus  = 'Partially Paid'
         AND CAST(CreatedDate AS DATE) = CAST(GETDATE() AS DATE)
        THEN 'PASS'
        ELSE 'FAIL'
    END                                                          AS Result
FROM dbo.Bills WHERE BillID = @B2;

-- ── TC-3: AUTO-CORRECTION — fully paid, BillStatus wrong ─────────────────────
-- TotalAmount=200, PaidAmount=200, Balance=0 → Status should be 'Paid'.
-- Caller passes BillStatus='Unpaid' (wrong).
-- Expected: trigger corrects BillStatus to 'Paid'.
INSERT INTO dbo.Bills
    (PatientID, AppointmentID, TotalAmount, PaidAmount, Balance, BillStatus, CreatedDate)
VALUES (@Pat, @Appt, 200.00, 200.00, 0.00, 'Unpaid', GETDATE());

DECLARE @B3 INT = SCOPE_IDENTITY();

SELECT
    'TC-3'                                                       AS Test,
    'Auto-correct: fully paid → BillStatus = ''Paid'''          AS Description,
    BillID, TotalAmount, PaidAmount, Balance, BillStatus,
    CASE
        WHEN Balance    = 0.00 AND BillStatus = 'Paid'
        THEN 'PASS'
        ELSE 'FAIL'
    END                                                          AS Result
FROM dbo.Bills WHERE BillID = @B3;

-- ── TC-4: AUTO-CORRECTION — Balance wrong on partially-paid bill ──────────────
-- TotalAmount=750, PaidAmount=250 → correct Balance=500, Status='Partially Paid'.
-- Caller passes Balance=0 (wrong) and BillStatus='Paid' (wrong).
-- Expected: both Balance and BillStatus auto-corrected.
INSERT INTO dbo.Bills
    (PatientID, AppointmentID, TotalAmount, PaidAmount, Balance, BillStatus, CreatedDate)
VALUES (@Pat, @Appt, 750.00, 250.00, 0.00, 'Paid', GETDATE());

DECLARE @B4 INT = SCOPE_IDENTITY();

SELECT
    'TC-4'                                                       AS Test,
    'Auto-correct: partial payment — Balance=0 and Status=Paid both wrong' AS Description,
    BillID, TotalAmount, PaidAmount, Balance, BillStatus,
    CASE
        WHEN Balance    = 500.00 AND BillStatus = 'Partially Paid'
        THEN 'PASS'
        ELSE 'FAIL'
    END                                                          AS Result
FROM dbo.Bills WHERE BillID = @B4;

-- ── Verify audit entries for TC-1 through TC-4 ───────────────────────────────
SELECT
    'TC-1 to TC-4 — AuditLog entries'                           AS [Check],
    COUNT(*)                                                     AS EntryCount,
    CASE WHEN COUNT(*) >= 4 THEN 'PASS' ELSE 'FAIL' END         AS Result
FROM dbo.AuditLogs
WHERE TableName  = 'Bills'
  AND ActionType = 'INSERT'
  AND NewValue LIKE 'BillID=' + CAST(@B1 AS VARCHAR(10)) + '%'
   OR (TableName='Bills' AND ActionType='INSERT'
       AND NewValue LIKE 'BillID=' + CAST(@B2 AS VARCHAR(10)) + '%')
   OR (TableName='Bills' AND ActionType='INSERT'
       AND NewValue LIKE 'BillID=' + CAST(@B3 AS VARCHAR(10)) + '%')
   OR (TableName='Bills' AND ActionType='INSERT'
       AND NewValue LIKE 'BillID=' + CAST(@B4 AS VARCHAR(10)) + '%');
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- TC-5: REJECTED — TotalAmount ≤ 0 (Rule 1 violation).
-- Expected: Rule 1 fires, INSERT rolled back, Error 50000, no row in Bills.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @Pat5  INT; SELECT @Pat5  = MIN(PatientID)     FROM dbo.Patients;
DECLARE @Appt5 INT; SELECT @Appt5 = MIN(AppointmentID) FROM dbo.Appointments;
BEGIN TRY
    INSERT INTO dbo.Bills
        (PatientID, AppointmentID, TotalAmount, PaidAmount, Balance, BillStatus, CreatedDate)
    VALUES (@Pat5, @Appt5, -50.00, 0.00, 0.00, 'Unpaid', GETDATE());
    SELECT 'TC-5' AS Test, 'FAIL — insert should have been rejected' AS Result;
END TRY
BEGIN CATCH
    SELECT
        'TC-5'                                                   AS Test,
        'Block: TotalAmount = -50 (Rule 1)'                      AS Description,
        ERROR_NUMBER()                                           AS ErrNum,
        LEFT(ERROR_MESSAGE(), 120)                               AS ErrMsg,
        CASE WHEN ERROR_NUMBER() = 50000 THEN 'PASS' ELSE 'FAIL' END AS Result;
END CATCH;

-- Confirm no row with TotalAmount=-50 survived
SELECT
    'TC-5 row check'                                             AS [Check],
    CASE WHEN COUNT(*) = 0 THEN 'PASS — no row committed'
         ELSE 'FAIL — row exists despite rollback' END           AS Result
FROM dbo.Bills WHERE TotalAmount = -50.00;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- TC-6: REJECTED — PaidAmount > TotalAmount (Rule 2 violation).
-- Expected: Rule 2 fires, INSERT rolled back, Error 50000, no row in Bills.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @Pat6  INT; SELECT @Pat6  = MIN(PatientID)     FROM dbo.Patients;
DECLARE @Appt6 INT; SELECT @Appt6 = MIN(AppointmentID) FROM dbo.Appointments;
BEGIN TRY
    INSERT INTO dbo.Bills
        (PatientID, AppointmentID, TotalAmount, PaidAmount, Balance, BillStatus, CreatedDate)
    VALUES (@Pat6, @Appt6, 100.00, 999.00, 0.00, 'Unpaid', GETDATE());
    SELECT 'TC-6' AS Test, 'FAIL — insert should have been rejected' AS Result;
END TRY
BEGIN CATCH
    SELECT
        'TC-6'                                                   AS Test,
        'Block: PaidAmount=999 > TotalAmount=100 (Rule 2)'       AS Description,
        ERROR_NUMBER()                                           AS ErrNum,
        LEFT(ERROR_MESSAGE(), 120)                               AS ErrMsg,
        CASE WHEN ERROR_NUMBER() = 50000 THEN 'PASS' ELSE 'FAIL' END AS Result;
END CATCH;

-- Confirm no row with TotalAmount=100 AND PaidAmount=999 survived
SELECT
    'TC-6 row check'                                             AS [Check],
    CASE WHEN COUNT(*) = 0 THEN 'PASS — no row committed'
         ELSE 'FAIL — row exists despite rollback' END           AS Result
FROM dbo.Bills WHERE TotalAmount = 100.00 AND PaidAmount = 999.00;
GO

-- =============================================================================
-- SECTION 3: Final integrity verification (scoped to today's inserts)
-- Pre-trigger seed data may have BillStatus abbreviations — checks are scoped
-- to rows inserted today (CreatedDate >= today) to isolate trigger results.
-- =============================================================================

-- No bill inserted today should have TotalAmount ≤ 0 (Rule 1 effectiveness)
SELECT
    'Integrity: TotalAmount > 0 (today''s bills)'               AS Summary,
    COUNT(*)                                                     AS ViolatingRows,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END          AS Result
FROM dbo.Bills
WHERE CreatedDate >= CAST(GETDATE() AS DATE)
  AND TotalAmount <= 0;

-- No bill inserted today should have PaidAmount > TotalAmount (Rule 2 effectiveness)
SELECT
    'Integrity: PaidAmount ≤ TotalAmount (today''s bills)'      AS Summary,
    COUNT(*)                                                     AS ViolatingRows,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END          AS Result
FROM dbo.Bills
WHERE CreatedDate >= CAST(GETDATE() AS DATE)
  AND PaidAmount > TotalAmount;

-- All bills inserted today should have correct Balance (Rule 3 effectiveness)
SELECT
    'Integrity: Balance = TotalAmount - PaidAmount (today)'      AS Summary,
    COUNT(*)                                                     AS ViolatingRows,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END          AS Result
FROM dbo.Bills
WHERE CreatedDate >= CAST(GETDATE() AS DATE)
  AND Balance <> TotalAmount - PaidAmount;

-- All bills inserted today should have correct BillStatus (Rule 4 effectiveness)
SELECT
    'Integrity: BillStatus consistent with amounts (today)'      AS Summary,
    COUNT(*)                                                     AS ViolatingRows,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END          AS Result
FROM dbo.Bills
WHERE CreatedDate >= CAST(GETDATE() AS DATE)
  AND BillStatus <> CASE
        WHEN PaidAmount <= 0            THEN 'Unpaid'
        WHEN PaidAmount >= TotalAmount  THEN 'Paid'
        ELSE 'Partially Paid'
      END;

-- Total AuditLog entries written for Bills INSERT today
SELECT
    'Audit: Bills INSERT entries today'                          AS Summary,
    COUNT(*)                                                     AS TotalEntries
FROM dbo.AuditLogs
WHERE TableName  = 'Bills'
  AND ActionType = 'INSERT'
  AND ActionDate >= CAST(GETDATE() AS DATE);
GO
