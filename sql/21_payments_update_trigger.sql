-- =============================================================================
-- HospitalDB — UPDATE Trigger on dbo.Payments
-- File        : sql/21_payments_update_trigger.sql
-- Author      : Hospital Information Systems
-- Date        : 2026-05-07
-- Description :
--   An AFTER UPDATE trigger on dbo.Payments that enforces three validation
--   rules and automatically propagates every approved payment correction to
--   its parent bill, keeping Bills.PaidAmount, Bills.Balance, and
--   Bills.BillStatus consistent with the actual sum of recorded payments.
--
--   ─── RULES ───────────────────────────────────────────────────────────────
--
--   Rule 1 — BILLID IMMUTABILITY (reject on failure)
--     A payment record is permanently bound to the bill it was made against.
--     Reassigning a payment to a different bill is rejected atomically: the
--     UPDATE is rolled back and an error is raised.  To correct the bill
--     association, delete the payment and re-insert it against the right bill.
--
--   Rule 2 — AMOUNT POSITIVITY (reject on failure)
--     Payment.Amount must remain strictly greater than zero after the UPDATE.
--     Zero or negative values represent accounting errors and are rejected
--     atomically.
--
--   Rule 3 — OVERPAYMENT GUARD (reject on failure)
--     After the amount change, the sum of ALL payments for the affected bill
--     must not exceed the bill's TotalAmount.  Overpayments are rejected
--     atomically.  To record a refund, a separate credit workflow must be
--     used rather than adjusting existing payment amounts upward.
--
--   Rule 4 — BILL BALANCE CASCADE (update dependent records)
--     Every approved UPDATE that changes Amount is automatically propagated to
--     dbo.Bills for all affected bills in the batch:
--       Bills.PaidAmount  = SUM of all dbo.Payments rows for that BillID
--       Bills.Balance     = Bills.TotalAmount − new PaidAmount
--       Bills.BillStatus  = derived from PaidAmount:
--                           0                      → 'Unpaid'
--                           0 < paid < TotalAmount → 'Partially Paid'
--                           paid = TotalAmount     → 'Paid'
--     This cascade ensures dbo.Bills is always consistent with the payments
--     ledger, regardless of which application path issues the UPDATE.
--
--   Rule 5 — AUDIT LOGGING (track changes)
--     Every UPDATE that changes at least one of Amount, PaymentMethod, or
--     PaymentDate is recorded in dbo.AuditLogs with both old and new values,
--     providing a full correction history for every payment record.
--
--   ─── PATTERN ─────────────────────────────────────────────────────────────
--   AFTER UPDATE is used so that both 'inserted' (new values) and 'deleted'
--   (old values) are populated for side-by-side comparison and audit capture.
--   Validation failures use ROLLBACK TRANSACTION + RAISERROR + RETURN.
--   The cascade UPDATE (Rule 4) uses a derived aggregation JOIN so the full
--   payment batch is recomputed in a single set-based statement.
--
--   ─── OBJECTS CREATED ─────────────────────────────────────────────────────
--   dbo.trg_Payments_AfterUpdate   AFTER UPDATE trigger on dbo.Payments
--
--   ─── TEST CASES ──────────────────────────────────────────────────────────
--   TC-1  Valid amount correction (decrease)   → Bill cascade: Balance up
--   TC-2  Valid amount correction (increase)   → Bill cascade: Balance=0, Status='Paid'
--   TC-3  BillID reassignment attempt          → rejected, Error 50000 (Rule 1)
--   TC-4  Amount set to zero                   → rejected, Error 50000 (Rule 2)
--   TC-5  Amount increase beyond TotalAmount   → rejected, Error 50000 (Rule 3)
-- =============================================================================

USE HospitalDB;
GO

-- =============================================================================
-- SECTION 1: AFTER UPDATE trigger
-- =============================================================================

CREATE OR ALTER TRIGGER dbo.trg_Payments_AfterUpdate
ON dbo.Payments
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Working variables declared at trigger scope
    DECLARE @BlockedIDs  NVARCHAR(400);
    DECLARE @Msg         NVARCHAR(500);
    DECLARE @AuditUserID INT;

    -- -------------------------------------------------------------------------
    -- Rule 1: BillID immutability.
    -- 'deleted' holds pre-update values; 'inserted' holds post-update values.
    -- Reject if any row in the batch changed its BillID.
    -- -------------------------------------------------------------------------
    IF EXISTS (
        SELECT 1
        FROM inserted i
        JOIN deleted  d ON d.PaymentID = i.PaymentID
        WHERE i.BillID <> d.BillID
    )
    BEGIN
        SELECT @BlockedIDs = STUFF(
            (SELECT ', ' + CAST(i.PaymentID AS VARCHAR(10))
                   + ' (' + CAST(d.BillID AS VARCHAR(10))
                   + ' to ' + CAST(i.BillID AS VARCHAR(10)) + ')'
             FROM inserted i
             JOIN deleted  d ON d.PaymentID = i.PaymentID
             WHERE i.BillID <> d.BillID
             FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(400)'),
            1, 2, '');

        SET @Msg =
            'UPDATE blocked by Rule 1 (BillID Immutability): Payment(s) ['
            + @BlockedIDs
            + '] — a payment cannot be reassigned to a different bill.'
            + ' Delete the payment and re-insert it against the correct bill.';

        ROLLBACK TRANSACTION;
        RAISERROR(@Msg, 16, 1);
        RETURN;
    END;

    -- -------------------------------------------------------------------------
    -- Rule 2: Amount must remain > 0.
    -- -------------------------------------------------------------------------
    IF EXISTS (SELECT 1 FROM inserted WHERE Amount <= 0)
    BEGIN
        SELECT @BlockedIDs = STUFF(
            (SELECT ', ' + CAST(PaymentID AS VARCHAR(10))
                   + ' (Amount=' + CAST(Amount AS VARCHAR(20)) + ')'
             FROM inserted
             WHERE Amount <= 0
             FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(400)'),
            1, 2, '');

        SET @Msg =
            'UPDATE blocked by Rule 2 (Amount Positivity): Payment(s) ['
            + @BlockedIDs
            + '] — Payment.Amount must be greater than zero.'
            + ' A zero or negative amount is not a valid payment record.';

        ROLLBACK TRANSACTION;
        RAISERROR(@Msg, 16, 1);
        RETURN;
    END;

    -- -------------------------------------------------------------------------
    -- Rule 3: Overpayment guard.
    -- After the UPDATE, compute the new sum of all payments for each affected
    -- bill (including the modified rows already committed to Payments).
    -- Reject if any bill's total payments exceed its TotalAmount.
    -- -------------------------------------------------------------------------
    IF EXISTS (
        SELECT 1
        FROM (
            SELECT p.BillID, SUM(p.Amount) AS NewPaidTotal
            FROM   dbo.Payments p
            WHERE  p.BillID IN (SELECT DISTINCT BillID FROM inserted)
            GROUP  BY p.BillID
        ) agg
        JOIN dbo.Bills b ON b.BillID = agg.BillID
        WHERE agg.NewPaidTotal > b.TotalAmount
    )
    BEGIN
        SELECT @BlockedIDs = STUFF(
            (SELECT ', ' + 'BillID=' + CAST(b.BillID AS VARCHAR(10))
                   + ' (TotalAmount=' + CAST(b.TotalAmount AS VARCHAR(20))
                   + ', NewPaymentSum=' + CAST(agg.NewPaidTotal AS VARCHAR(20)) + ')'
             FROM (
                 SELECT p.BillID, SUM(p.Amount) AS NewPaidTotal
                 FROM   dbo.Payments p
                 WHERE  p.BillID IN (SELECT DISTINCT BillID FROM inserted)
                 GROUP  BY p.BillID
             ) agg
             JOIN dbo.Bills b ON b.BillID = agg.BillID
             WHERE agg.NewPaidTotal > b.TotalAmount
             FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(400)'),
            1, 2, '');

        SET @Msg =
            'UPDATE blocked by Rule 3 (Overpayment Guard): ['
            + @BlockedIDs
            + '] — the updated payment amount would cause total payments to exceed'
            + ' the bill''s TotalAmount. Use a credit note workflow for refunds.';

        ROLLBACK TRANSACTION;
        RAISERROR(@Msg, 16, 1);
        RETURN;
    END;

    -- -------------------------------------------------------------------------
    -- Rule 4: Bill balance cascade.
    -- Recompute PaidAmount, Balance, and BillStatus for every affected bill.
    -- Uses a single set-based aggregation JOIN covering the full batch.
    -- -------------------------------------------------------------------------
    UPDATE b
    SET
        b.PaidAmount = agg.NewPaid,
        b.Balance    = b.TotalAmount - agg.NewPaid,
        b.BillStatus = CASE
                           WHEN agg.NewPaid <= 0             THEN 'Unpaid'
                           WHEN agg.NewPaid >= b.TotalAmount THEN 'Paid'
                           ELSE                                   'Partially Paid'
                       END
    FROM dbo.Bills b
    JOIN (
        SELECT   p.BillID, SUM(p.Amount) AS NewPaid
        FROM     dbo.Payments p
        WHERE    p.BillID IN (SELECT DISTINCT BillID FROM inserted)
        GROUP BY p.BillID
    ) agg ON agg.BillID = b.BillID;

    -- -------------------------------------------------------------------------
    -- Rule 5: Audit logging.
    -- Capture every approved UPDATE where at least one financial or
    -- classification column changed.
    -- -------------------------------------------------------------------------
    SELECT @AuditUserID = MIN(UserID) FROM dbo.Users WHERE IsActive = 1;

    INSERT INTO dbo.AuditLogs
        (PerformedByUserID, TableName, ActionType, ActionDate, OldValue, NewValue)
    SELECT
        @AuditUserID,
        'Payments',
        'UPDATE',
        GETDATE(),
        'PaymentID='       + CAST(d.PaymentID      AS VARCHAR(10))
        + '; BillID='      + CAST(d.BillID         AS VARCHAR(10))
        + '; Amount='      + CAST(d.Amount         AS VARCHAR(20))
        + '; Method='      + d.PaymentMethod
        + '; PayDate='     + CONVERT(VARCHAR(20), d.PaymentDate, 120)
        + '; Ref='         + d.ReferenceNumber,
        'PaymentID='       + CAST(i.PaymentID      AS VARCHAR(10))
        + '; BillID='      + CAST(i.BillID         AS VARCHAR(10))
        + '; Amount='      + CAST(i.Amount         AS VARCHAR(20))
        + '; Method='      + i.PaymentMethod
        + '; PayDate='     + CONVERT(VARCHAR(20), i.PaymentDate, 120)
        + '; Ref='         + i.ReferenceNumber
    FROM inserted i
    JOIN deleted  d ON d.PaymentID = i.PaymentID
    WHERE i.Amount        <> d.Amount
       OR i.PaymentMethod <> d.PaymentMethod
       OR i.PaymentDate   <> d.PaymentDate;
END;
GO

-- =============================================================================
-- SECTION 2: Test Cases
-- =============================================================================
--
-- Seed data baseline (verified):
--   PaymentID=3  → BillID=2,  Amount=150.00
--   Bill 2       → TotalAmount=250.00, PaidAmount=150.00, Balance=100.00
--
--   PaymentID=8  → BillID=8,  Amount=150.00
--   Bill 8       → TotalAmount=300.00, PaidAmount=150.00, Balance=150.00
--
-- TC-1/TC-2 use PaymentID=3 (sequential state change).
-- TC-3/TC-4/TC-5 use PaymentID=8 (all rejections; no net state change).
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- SETUP VERIFICATION: confirm baseline state before tests run.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT 'Baseline' AS Phase,
    p.PaymentID, p.BillID, p.Amount AS PayAmt,
    b.TotalAmount, b.PaidAmount, b.Balance, b.BillStatus
FROM dbo.Payments p
JOIN dbo.Bills    b ON b.BillID = p.BillID
WHERE p.PaymentID IN (3, 8)
ORDER BY p.PaymentID;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- TC-1: VALID AMOUNT DECREASE — payment correction reduces the amount.
--
--   PaymentID=3 Amount: 150 → 100
--   Expected Bill 2 cascade:
--     PaidAmount = 100   (only payment for this bill)
--     Balance    = 150   (250 − 100)
--     BillStatus = 'Partially Paid'
-- ─────────────────────────────────────────────────────────────────────────────
UPDATE dbo.Payments SET Amount = 100.00 WHERE PaymentID = 3;

SELECT
    'TC-1'                                                              AS Test,
    'Valid decrease: PaymentID=3 Amount 150→100'                        AS Description,
    p.PaymentID, p.Amount AS NewPayAmt,
    b.TotalAmount, b.PaidAmount, b.Balance, b.BillStatus,
    CASE
        WHEN p.Amount      = 100.00
         AND b.PaidAmount  = 100.00
         AND b.Balance     = 150.00
         AND b.BillStatus  = 'Partially Paid'
        THEN 'PASS'
        ELSE 'FAIL'
    END                                                                 AS Result
FROM dbo.Payments p
JOIN dbo.Bills    b ON b.BillID = p.BillID
WHERE p.PaymentID = 3;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- TC-2: VALID AMOUNT INCREASE — payment correction fully pays the bill.
--
--   PaymentID=3 Amount: 100 → 250  (= TotalAmount of Bill 2)
--   Expected Bill 2 cascade:
--     PaidAmount = 250   (exactly matches TotalAmount)
--     Balance    = 0
--     BillStatus = 'Paid'
-- ─────────────────────────────────────────────────────────────────────────────
UPDATE dbo.Payments SET Amount = 250.00 WHERE PaymentID = 3;

SELECT
    'TC-2'                                                              AS Test,
    'Valid increase: PaymentID=3 Amount 100→250 (fully pays Bill 2)'    AS Description,
    p.PaymentID, p.Amount AS NewPayAmt,
    b.TotalAmount, b.PaidAmount, b.Balance, b.BillStatus,
    CASE
        WHEN p.Amount      = 250.00
         AND b.PaidAmount  = 250.00
         AND b.Balance     = 0.00
         AND b.BillStatus  = 'Paid'
        THEN 'PASS'
        ELSE 'FAIL'
    END                                                                 AS Result
FROM dbo.Payments p
JOIN dbo.Bills    b ON b.BillID = p.BillID
WHERE p.PaymentID = 3;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- TC-3: REJECTED — BillID reassignment (Rule 1).
--
--   Attempt to move PaymentID=8 from BillID=8 to BillID=1.
--   Expected: Rule 1 fires, UPDATE rolled back, Error 50000,
--             PaymentID=8 still on BillID=8.
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN TRY
    UPDATE dbo.Payments SET BillID = 1 WHERE PaymentID = 8;
    SELECT 'TC-3' AS Test, 'FAIL — update should have been rejected' AS Result;
END TRY
BEGIN CATCH
    SELECT
        'TC-3'                                                          AS Test,
        'Block: BillID reassignment on PaymentID=8 (Rule 1)'           AS Description,
        ERROR_NUMBER()                                                  AS ErrNum,
        LEFT(ERROR_MESSAGE(), 140)                                      AS ErrMsg,
        CASE WHEN ERROR_NUMBER() = 50000 THEN 'PASS' ELSE 'FAIL' END   AS Result;
END CATCH;

-- Rollback check: PaymentID=8 still on BillID=8
SELECT
    'TC-3 rollback'                                                     AS [Check],
    PaymentID, BillID,
    CASE WHEN BillID = 8 THEN 'PASS — BillID unchanged'
         ELSE 'FAIL — BillID was changed despite rollback' END          AS Result
FROM dbo.Payments WHERE PaymentID = 8;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- TC-4: REJECTED — Amount set to zero (Rule 2).
--
--   Attempt to set PaymentID=8 Amount to 0.00.
--   Expected: Rule 2 fires, UPDATE rolled back, Error 50000,
--             PaymentID=8 Amount still 150.00.
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN TRY
    UPDATE dbo.Payments SET Amount = 0.00 WHERE PaymentID = 8;
    SELECT 'TC-4' AS Test, 'FAIL — update should have been rejected' AS Result;
END TRY
BEGIN CATCH
    SELECT
        'TC-4'                                                          AS Test,
        'Block: Amount=0 on PaymentID=8 (Rule 2)'                       AS Description,
        ERROR_NUMBER()                                                  AS ErrNum,
        LEFT(ERROR_MESSAGE(), 140)                                      AS ErrMsg,
        CASE WHEN ERROR_NUMBER() = 50000 THEN 'PASS' ELSE 'FAIL' END   AS Result;
END CATCH;

-- Rollback check: PaymentID=8 Amount still 150.00
SELECT
    'TC-4 rollback'                                                     AS [Check],
    PaymentID, Amount,
    CASE WHEN Amount = 150.00 THEN 'PASS — Amount unchanged'
         ELSE 'FAIL — Amount was changed despite rollback' END          AS Result
FROM dbo.Payments WHERE PaymentID = 8;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- TC-5: REJECTED — Overpayment (Rule 3).
--
--   PaymentID=8 current Amount=150; BillID=8 TotalAmount=300.
--   Attempt to increase Amount to 500.00.
--   After update, SUM(Payments for Bill 8) = 500 > TotalAmount=300 → reject.
--   Expected: Rule 3 fires, UPDATE rolled back, Error 50000,
--             PaymentID=8 Amount still 150.00, Bill 8 unchanged.
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN TRY
    UPDATE dbo.Payments SET Amount = 500.00 WHERE PaymentID = 8;
    SELECT 'TC-5' AS Test, 'FAIL — update should have been rejected' AS Result;
END TRY
BEGIN CATCH
    SELECT
        'TC-5'                                                          AS Test,
        'Block: Amount=500 exceeds Bill 8 TotalAmount=300 (Rule 3)'     AS Description,
        ERROR_NUMBER()                                                  AS ErrNum,
        LEFT(ERROR_MESSAGE(), 140)                                      AS ErrMsg,
        CASE WHEN ERROR_NUMBER() = 50000 THEN 'PASS' ELSE 'FAIL' END   AS Result;
END CATCH;

-- Rollback check: Bill 8 totals unchanged (PaidAmount=150, Balance=150)
SELECT
    'TC-5 rollback'                                                     AS [Check],
    b.BillID, b.TotalAmount, b.PaidAmount, b.Balance, b.BillStatus,
    CASE
        WHEN b.PaidAmount = 150.00 AND b.Balance = 150.00
        THEN 'PASS — Bill 8 unchanged'
        ELSE 'FAIL — Bill 8 was modified despite rollback'
    END                                                                 AS Result
FROM dbo.Bills WHERE BillID = 8;
GO

-- =============================================================================
-- SECTION 3: Audit and integrity verification
-- =============================================================================

-- AuditLog entries written for Payments UPDATE today (TC-1 and TC-2)
SELECT
    'Audit: Payments UPDATE entries today'                              AS Summary,
    COUNT(*)                                                            AS TotalEntries,
    CASE WHEN COUNT(*) >= 2 THEN 'PASS' ELSE 'FAIL' END                AS Result
FROM dbo.AuditLogs
WHERE TableName  = 'Payments'
  AND ActionType = 'UPDATE'
  AND ActionDate >= CAST(GETDATE() AS DATE);

-- Audit trail detail for PaymentID=3 (TC-1 → TC-2 sequence)
SELECT
    AuditID,
    LEFT(OldValue, 70) AS OldValue,
    LEFT(NewValue, 70) AS NewValue,
    CAST(ActionDate AS TIME(0)) AS At
FROM dbo.AuditLogs
WHERE TableName  = 'Payments'
  AND ActionType = 'UPDATE'
  AND NewValue   LIKE 'PaymentID=3%'
ORDER BY AuditID;

-- Bills consistency check: all bills where PaidAmount matches SUM of payments
SELECT
    'Integrity: Bills PaidAmount matches SUM(Payments)'                 AS Summary,
    COUNT(*)                                                            AS MismatchedBills,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END                 AS Result
FROM dbo.Bills b
WHERE b.PaidAmount <> COALESCE(
    (SELECT SUM(p.Amount) FROM dbo.Payments p WHERE p.BillID = b.BillID), 0);

-- Bills consistency: Balance = TotalAmount - PaidAmount
SELECT
    'Integrity: Balance = TotalAmount - PaidAmount'                     AS Summary,
    COUNT(*)                                                            AS MismatchedBills,
    CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END                 AS Result
FROM dbo.Bills b
WHERE b.Balance <> b.TotalAmount - b.PaidAmount;
GO
