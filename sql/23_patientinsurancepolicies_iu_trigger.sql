-- =============================================================================
-- HospitalDB — INSERT / UPDATE Trigger on dbo.PatientInsurancePolicies
-- File        : sql/23_patientinsurancepolicies_iu_trigger.sql
-- Author      : Hospital Information Systems
-- Date        : 2026-05-07
-- Description :
--   An AFTER INSERT, UPDATE trigger on dbo.PatientInsurancePolicies that
--   enforces three business rules at the database layer, independent of which
--   application path performs the write.
--
--   ─── RULES ───────────────────────────────────────────────────────────────
--
--   Rule 1 — PRIMARY POLICY UNIQUENESS (enforce on failure via cascade)
--     Each patient may have exactly one policy flagged IsPrimary = 1.
--     When a new or updated row sets IsPrimary = 1 for a patient, any other
--     existing policy rows for that patient that are currently marked as
--     primary are automatically demoted to IsPrimary = 0.
--     This ensures the invariant is maintained without rejecting valid inserts.
--
--   Rule 2 — COVERAGE PERCENT RANGE (reject on failure)
--     CoveragePercent must be in the range [0.00, 100.00].
--     Values outside this range represent data-entry errors and are rejected
--     atomically: the INSERT or UPDATE is rolled back and an error is raised.
--
--   Rule 3 — EXPIRY DATE MUST BE IN THE FUTURE (reject on failure)
--     ExpiryDate must be strictly greater than today's date.
--     Recording an already-expired policy at creation time indicates a data
--     error; the operation is rejected atomically.
--
--   ─── PATTERN ─────────────────────────────────────────────────────────────
--   AFTER INSERT, UPDATE is used (not INSTEAD OF) so that IDENTITY values are
--   assigned by the engine before the trigger fires.  This allows the cascade
--   UPDATE in Rule 1 to reference the newly inserted PatientInsuranceID and
--   exclude the row just written when demoting other primary policies.
--   Validation failures use ROLLBACK TRANSACTION + RAISERROR + RETURN.
--   Rules 2 and 3 are checked first (cheap, set-based) before the cascade
--   UPDATE fires (Rule 1), so the demotion never runs against invalid data.
--
--   ─── OBJECTS CREATED ─────────────────────────────────────────────────────
--   dbo.trg_PatientInsurancePolicies_AfterIU
--       AFTER INSERT, UPDATE trigger on dbo.PatientInsurancePolicies
--
--   ─── TEST CASES ──────────────────────────────────────────────────────────
--   TC-1  Valid INSERT — first policy for patient, IsPrimary = 1
--           → row inserted, no demotion needed
--   TC-2  Valid INSERT — second policy, IsPrimary = 1
--           → new row inserted, existing primary automatically demoted to 0
--   TC-3  Valid UPDATE — flip an existing non-primary to IsPrimary = 1
--           → row updated, old primary auto-demoted
--   TC-4  Rejected INSERT — CoveragePercent > 100
--           → rolled back, Error 50000 (Rule 2)
--   TC-5  Rejected INSERT — CoveragePercent < 0
--           → rolled back, Error 50000 (Rule 2)
--   TC-6  Rejected INSERT — ExpiryDate in the past
--           → rolled back, Error 50000 (Rule 3)
--   TC-7  Verify exactly one primary per patient after all successful writes
--           → IsPrimary = 1 count per patient is exactly 1
-- =============================================================================

USE HospitalDB;
GO

-- =============================================================================
-- SECTION 1: AFTER INSERT, UPDATE trigger
-- =============================================================================

CREATE OR ALTER TRIGGER dbo.trg_PatientInsurancePolicies_AfterIU
ON dbo.PatientInsurancePolicies
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Guard: nested trigger calls originate from the cascade demotion UPDATE
    -- inside this same trigger.  Those rows have already been validated; skip.
    IF TRIGGER_NESTLEVEL(OBJECT_ID('dbo.trg_PatientInsurancePolicies_AfterIU'), 'AFTER', 'DML') > 1
        RETURN;

    DECLARE @Msg NVARCHAR(500);

    -- -------------------------------------------------------------------------
    -- Rule 2: CoveragePercent must be in [0.00, 100.00].
    -- Checked before Rule 1 to avoid running a cascade on invalid data.
    -- -------------------------------------------------------------------------
    IF EXISTS (
        SELECT 1
        FROM inserted
        WHERE CoveragePercent < 0 OR CoveragePercent > 100
    )
    BEGIN
        DECLARE @R2IDs NVARCHAR(400);
        SELECT @R2IDs = STUFF(
            (SELECT ', ' + CAST(PatientInsuranceID AS VARCHAR(10))
             FROM inserted
             WHERE CoveragePercent < 0 OR CoveragePercent > 100
             FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(400)'),
            1, 2, '');

        SET @Msg =
            'INSERT/UPDATE blocked by Rule 2 (Coverage Range): Policy row(s) ['
            + @R2IDs
            + '] — CoveragePercent must be between 0.00 and 100.00.'
            + ' Correct the coverage value and retry.';

        ROLLBACK TRANSACTION;
        RAISERROR(@Msg, 16, 1);
        RETURN;
    END;

    -- -------------------------------------------------------------------------
    -- Rule 3: ExpiryDate must be strictly in the future (> today).
    -- An already-expired policy at write time indicates a data error.
    -- -------------------------------------------------------------------------
    IF EXISTS (
        SELECT 1
        FROM inserted
        WHERE ExpiryDate <= CAST(GETDATE() AS DATE)
    )
    BEGIN
        DECLARE @R3IDs NVARCHAR(400);
        SELECT @R3IDs = STUFF(
            (SELECT ', ' + CAST(PatientInsuranceID AS VARCHAR(10))
             FROM inserted
             WHERE ExpiryDate <= CAST(GETDATE() AS DATE)
             FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(400)'),
            1, 2, '');

        SET @Msg =
            'INSERT/UPDATE blocked by Rule 3 (Expiry Date): Policy row(s) ['
            + @R3IDs
            + '] — ExpiryDate must be a future date (strictly after today).'
            + ' A policy cannot be recorded if it has already expired.';

        ROLLBACK TRANSACTION;
        RAISERROR(@Msg, 16, 1);
        RETURN;
    END;

    -- -------------------------------------------------------------------------
    -- Rule 1: Primary policy uniqueness — cascade demotion.
    --
    -- For every patient whose IsPrimary = 1 row appears in 'inserted',
    -- set IsPrimary = 0 on all OTHER existing policies for that patient.
    -- 'inserted' holds the new/updated row(s), so a self-join exclusion
    -- prevents the newly written row from being demoted.
    --
    -- Set-based: one UPDATE covers the entire affected patient set in a
    -- single pass, making the operation safe for batch inserts.
    -- -------------------------------------------------------------------------
    UPDATE pip
    SET    pip.IsPrimary = 0
    FROM   dbo.PatientInsurancePolicies pip
    INNER JOIN (
        -- Distinct list of PatientIDs that now have a new primary row
        SELECT DISTINCT PatientID, PatientInsuranceID AS NewPrimaryID
        FROM   inserted
        WHERE  IsPrimary = 1
    ) src ON src.PatientID = pip.PatientID
    WHERE  pip.IsPrimary = 1
      AND  pip.PatientInsuranceID <> src.NewPrimaryID;

END;
GO

-- =============================================================================
-- SECTION 2: Test Cases
-- =============================================================================

-- Resolve a patient and insurance provider from seeded data to keep tests
-- self-contained and runnable on any instance with the standard seed data.
DECLARE @PatID  INT;
DECLARE @Prov1  INT;
DECLARE @Prov2  INT;
DECLARE @Prov3  INT;

SELECT TOP 1 @PatID = PatientID           FROM dbo.Patients           ORDER BY PatientID;
SELECT TOP 1 @Prov1 = InsuranceProviderID FROM dbo.InsuranceProviders  ORDER BY InsuranceProviderID;
SELECT TOP 1 @Prov2 = InsuranceProviderID FROM dbo.InsuranceProviders  ORDER BY InsuranceProviderID DESC;
-- Use a third provider distinct from the first two where possible
SELECT TOP 1 @Prov3 = InsuranceProviderID
FROM dbo.InsuranceProviders
WHERE InsuranceProviderID NOT IN (@Prov1, @Prov2)
ORDER BY InsuranceProviderID;
-- Fall back to @Prov1 if fewer than three providers exist
IF @Prov3 IS NULL SET @Prov3 = @Prov1;

-- ── Clean up any existing policies for this patient to start from blank slate ─
DELETE FROM dbo.PatientInsurancePolicies WHERE PatientID = @PatID;

-- =============================================================================
-- TC-1: VALID INSERT — first policy for patient, IsPrimary = 1
-- Expected: row inserted; no other primary rows exist to demote.
-- =============================================================================
INSERT INTO dbo.PatientInsurancePolicies
    (PatientID, InsuranceProviderID, PolicyNumber, CoveragePercent, ExpiryDate, IsPrimary)
VALUES
    (@PatID, @Prov1, 'TC1-POL-001', 80.00, DATEADD(YEAR, 1, GETDATE()), 1);

DECLARE @TC1ID INT = SCOPE_IDENTITY();

SELECT
    'TC-1'                                                              AS Test,
    'First policy, IsPrimary=1 — no demotion needed'                   AS Description,
    PatientInsuranceID, PolicyNumber, CoveragePercent, IsPrimary,
    CASE WHEN IsPrimary = 1 THEN 'PASS' ELSE 'FAIL' END                AS Result
FROM dbo.PatientInsurancePolicies
WHERE PatientInsuranceID = @TC1ID;
GO

-- =============================================================================
-- TC-2: VALID INSERT — second policy for same patient, IsPrimary = 1
-- Expected: new row inserted; TC-1 row automatically demoted to IsPrimary = 0.
-- =============================================================================
DECLARE @PatID2 INT;
SELECT TOP 1 @PatID2 = PatientID FROM dbo.Patients ORDER BY PatientID;

DECLARE @Prov2b INT;
SELECT TOP 1 @Prov2b = InsuranceProviderID
FROM dbo.InsuranceProviders
WHERE InsuranceProviderID <>
      (SELECT TOP 1 InsuranceProviderID FROM dbo.InsuranceProviders ORDER BY InsuranceProviderID)
ORDER BY InsuranceProviderID;
IF @Prov2b IS NULL
    SELECT TOP 1 @Prov2b = InsuranceProviderID FROM dbo.InsuranceProviders ORDER BY InsuranceProviderID;

INSERT INTO dbo.PatientInsurancePolicies
    (PatientID, InsuranceProviderID, PolicyNumber, CoveragePercent, ExpiryDate, IsPrimary)
VALUES
    (@PatID2, @Prov2b, 'TC2-POL-002', 90.00, DATEADD(YEAR, 2, GETDATE()), 1);

DECLARE @TC2ID INT = SCOPE_IDENTITY();

-- TC-1 row should now be demoted; TC-2 row should be the sole primary.
SELECT
    'TC-2'                                                              AS Test,
    'Second policy, IsPrimary=1 — old primary auto-demoted'            AS Description,
    PatientInsuranceID,
    PolicyNumber,
    IsPrimary,
    CASE
        WHEN PatientInsuranceID = @TC2ID AND IsPrimary = 1 THEN 'PASS — new primary'
        WHEN PatientInsuranceID <> @TC2ID AND IsPrimary = 0 THEN 'PASS — old demoted'
        ELSE 'FAIL'
    END                                                                 AS Result
FROM dbo.PatientInsurancePolicies
WHERE PatientID = @PatID2
ORDER BY PatientInsuranceID;
GO

-- =============================================================================
-- TC-3: VALID UPDATE — flip a non-primary row to IsPrimary = 1
-- Expected: flipped row becomes primary; previously primary row auto-demoted.
-- =============================================================================
DECLARE @PatID3 INT;
SELECT TOP 1 @PatID3 = PatientID FROM dbo.Patients ORDER BY PatientID;

-- The second row (TC2) is the current primary. Get the ID of the first (TC1).
DECLARE @TC3DemoteTarget INT;  -- The row that should become 0 after the UPDATE
DECLARE @TC3FlipTarget   INT;  -- The row we will flip to IsPrimary = 1

SELECT @TC3DemoteTarget = MIN(PatientInsuranceID) FROM dbo.PatientInsurancePolicies WHERE PatientID = @PatID3;
SELECT @TC3FlipTarget   = MIN(PatientInsuranceID) FROM dbo.PatientInsurancePolicies WHERE PatientID = @PatID3 AND IsPrimary = 0;

-- Flip the non-primary row
UPDATE dbo.PatientInsurancePolicies
SET    IsPrimary = 1
WHERE  PatientInsuranceID = @TC3FlipTarget;

SELECT
    'TC-3'                                                              AS Test,
    'UPDATE flip non-primary to primary — old primary auto-demoted'    AS Description,
    PatientInsuranceID,
    PolicyNumber,
    IsPrimary,
    CASE
        WHEN PatientInsuranceID = @TC3FlipTarget   AND IsPrimary = 1 THEN 'PASS — flipped to primary'
        WHEN PatientInsuranceID <> @TC3FlipTarget  AND IsPrimary = 0 THEN 'PASS — old primary demoted'
        ELSE 'FAIL'
    END                                                                 AS Result
FROM dbo.PatientInsurancePolicies
WHERE PatientID = @PatID3
ORDER BY PatientInsuranceID;
GO

-- =============================================================================
-- TC-4: REJECTED INSERT — CoveragePercent > 100 (Rule 2 violation)
-- Expected: INSERT rolled back, Error 50000, no new row in the table.
-- =============================================================================
DECLARE @PatID4 INT;
DECLARE @ProvID4 INT;
SELECT TOP 1 @PatID4  = PatientID           FROM dbo.Patients          ORDER BY PatientID;
SELECT TOP 1 @ProvID4 = InsuranceProviderID FROM dbo.InsuranceProviders ORDER BY InsuranceProviderID;

DECLARE @RowsBefore4 INT;
SELECT @RowsBefore4 = COUNT(*) FROM dbo.PatientInsurancePolicies WHERE PatientID = @PatID4;

BEGIN TRY
    INSERT INTO dbo.PatientInsurancePolicies
        (PatientID, InsuranceProviderID, PolicyNumber, CoveragePercent, ExpiryDate, IsPrimary)
    VALUES
        (@PatID4, @ProvID4, 'TC4-POL-FAIL', 150.00, DATEADD(YEAR, 1, GETDATE()), 0);

    -- Should not reach here
    SELECT
        'TC-4'                                                          AS Test,
        'CoveragePercent=150 — should be rejected'                     AS Description,
        'FAIL — INSERT was not blocked'                                 AS Result;
END TRY
BEGIN CATCH
    DECLARE @RowsAfter4 INT;
    SELECT @RowsAfter4 = COUNT(*) FROM dbo.PatientInsurancePolicies WHERE PatientID = @PatID4;

    SELECT
        'TC-4'                                                          AS Test,
        'CoveragePercent=150 — rejected by Rule 2'                     AS Description,
        ERROR_NUMBER()                                                  AS ErrorNumber,
        LEFT(ERROR_MESSAGE(), 120)                                      AS ErrorMessage,
        CASE
            WHEN ERROR_NUMBER() = 50000 AND @RowsAfter4 = @RowsBefore4
            THEN 'PASS'
            ELSE 'FAIL'
        END                                                             AS Result;
END CATCH;
GO

-- =============================================================================
-- TC-5: REJECTED INSERT — CoveragePercent < 0 (Rule 2 violation)
-- Expected: INSERT rolled back, Error 50000, no new row in the table.
-- =============================================================================
DECLARE @PatID5 INT;
DECLARE @ProvID5 INT;
SELECT TOP 1 @PatID5  = PatientID           FROM dbo.Patients          ORDER BY PatientID;
SELECT TOP 1 @ProvID5 = InsuranceProviderID FROM dbo.InsuranceProviders ORDER BY InsuranceProviderID;

DECLARE @RowsBefore5 INT;
SELECT @RowsBefore5 = COUNT(*) FROM dbo.PatientInsurancePolicies WHERE PatientID = @PatID5;

BEGIN TRY
    INSERT INTO dbo.PatientInsurancePolicies
        (PatientID, InsuranceProviderID, PolicyNumber, CoveragePercent, ExpiryDate, IsPrimary)
    VALUES
        (@PatID5, @ProvID5, 'TC5-POL-FAIL', -10.00, DATEADD(YEAR, 1, GETDATE()), 0);

    SELECT
        'TC-5'                                                          AS Test,
        'CoveragePercent=-10 — should be rejected'                     AS Description,
        'FAIL — INSERT was not blocked'                                 AS Result;
END TRY
BEGIN CATCH
    DECLARE @RowsAfter5 INT;
    SELECT @RowsAfter5 = COUNT(*) FROM dbo.PatientInsurancePolicies WHERE PatientID = @PatID5;

    SELECT
        'TC-5'                                                          AS Test,
        'CoveragePercent=-10 — rejected by Rule 2'                     AS Description,
        ERROR_NUMBER()                                                  AS ErrorNumber,
        LEFT(ERROR_MESSAGE(), 120)                                      AS ErrorMessage,
        CASE
            WHEN ERROR_NUMBER() = 50000 AND @RowsAfter5 = @RowsBefore5
            THEN 'PASS'
            ELSE 'FAIL'
        END                                                             AS Result;
END CATCH;
GO

-- =============================================================================
-- TC-6: REJECTED INSERT — ExpiryDate in the past (Rule 3 violation)
-- Expected: INSERT rolled back, Error 50000, no new row in the table.
-- =============================================================================
DECLARE @PatID6 INT;
DECLARE @ProvID6 INT;
SELECT TOP 1 @PatID6  = PatientID           FROM dbo.Patients          ORDER BY PatientID;
SELECT TOP 1 @ProvID6 = InsuranceProviderID FROM dbo.InsuranceProviders ORDER BY InsuranceProviderID;

DECLARE @RowsBefore6 INT;
SELECT @RowsBefore6 = COUNT(*) FROM dbo.PatientInsurancePolicies WHERE PatientID = @PatID6;

BEGIN TRY
    INSERT INTO dbo.PatientInsurancePolicies
        (PatientID, InsuranceProviderID, PolicyNumber, CoveragePercent, ExpiryDate, IsPrimary)
    VALUES
        (@PatID6, @ProvID6, 'TC6-POL-FAIL', 75.00, '2020-01-01', 0);

    SELECT
        'TC-6'                                                          AS Test,
        'ExpiryDate=2020-01-01 — should be rejected'                   AS Description,
        'FAIL — INSERT was not blocked'                                 AS Result;
END TRY
BEGIN CATCH
    DECLARE @RowsAfter6 INT;
    SELECT @RowsAfter6 = COUNT(*) FROM dbo.PatientInsurancePolicies WHERE PatientID = @PatID6;

    SELECT
        'TC-6'                                                          AS Test,
        'ExpiryDate in past — rejected by Rule 3'                      AS Description,
        ERROR_NUMBER()                                                  AS ErrorNumber,
        LEFT(ERROR_MESSAGE(), 120)                                      AS ErrorMessage,
        CASE
            WHEN ERROR_NUMBER() = 50000 AND @RowsAfter6 = @RowsBefore6
            THEN 'PASS'
            ELSE 'FAIL'
        END                                                             AS Result;
END CATCH;
GO

-- =============================================================================
-- TC-7: VERIFY invariant — exactly one IsPrimary = 1 per patient
-- Checks the full table; all counts should be exactly 1.
-- Expected: every patient with at least one policy has exactly one primary.
-- =============================================================================
SELECT
    'TC-7'                                                              AS Test,
    'Exactly one primary per patient across all policies'               AS Description,
    PatientID,
    SUM(CAST(IsPrimary AS INT))                                         AS PrimaryCount,
    CASE
        WHEN SUM(CAST(IsPrimary AS INT)) = 1 THEN 'PASS'
        ELSE 'FAIL'
    END                                                                 AS Result
FROM dbo.PatientInsurancePolicies
GROUP BY PatientID
ORDER BY PatientID;
GO
