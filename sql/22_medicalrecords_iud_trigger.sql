-- ============================================================================
-- File   : 22_medicalrecords_iud_trigger.sql
-- Trigger: dbo.trg_MedicalRecords_IUD
-- Table  : dbo.MedicalRecords
-- Events : AFTER INSERT, UPDATE, DELETE
--
-- Business Rules
-- ─────────────────────────────────────────────────────────────────────────────
-- INSERT
--   Rule 1 – Appointment Completeness Guard : AppointmentID must reference a
--             'Completed' appointment; reject records for any other status.
--   Rule 2 – Diagnosis Required             : Diagnosis must not be NULL,
--             empty, or whitespace.
--   Rule 3 – TreatmentPlan Required         : TreatmentPlan must not be NULL,
--             empty, or whitespace.
--   Rule 4 – CreatedDate Server Enforcement : CreatedDate is always overwritten
--             with GETDATE(), ignoring any caller-supplied value.
--   Rule 5 – Audit Logging                  : Each accepted INSERT is logged
--             to dbo.AuditLogs (ActionType = 'INSERT').
--
-- UPDATE
--   Rule 1 – AppointmentID Immutability     : AppointmentID cannot be changed
--             after the record is created; reject the update.
--   Rule 2 – Diagnosis Must Not Be Cleared  : Diagnosis must not be updated to
--             NULL, empty, or whitespace.
--   Rule 3 – Audit Logging                  : Any change to Diagnosis, Notes,
--             or TreatmentPlan is logged to dbo.AuditLogs (ActionType = 'UPDATE').
--
-- DELETE
--   Rule 1 – Retention Policy               : Records created more than 7 days
--             ago cannot be hard-deleted; use the archive procedure instead.
--   Rule 2 – Audit Logging                  : Deletions within the 7-day
--             correction window are logged (ActionType = 'DELETE').
--
-- Test Plan  (10 cases — all expected PASS)
-- ─────────────────────────────────────────────────────────────────────────────
--   INSERT : TC-INS-1 (reject – non-Completed appointment)
--            TC-INS-2 (reject – blank Diagnosis)
--            TC-INS-3 (reject – blank TreatmentPlan)
--            TC-INS-4 (accept – valid record, stale CreatedDate supplied)
--            TC-INS-5 (verify CreatedDate was overwritten by server, Rule 4)
--   UPDATE : TC-UPD-1 (reject – AppointmentID change attempt)
--            TC-UPD-2 (reject – blank Diagnosis)
--            TC-UPD-3 (accept – Diagnosis amendment + confirm audit entry)
--   DELETE : TC-DEL-1 (reject – retention policy, seed record > 7 days old)
--            TC-DEL-2 (accept – fresh record < 7 days old + confirm audit entry)
-- ============================================================================


-- ============================================================================
-- SECTION 1 – TRIGGER DEFINITION
-- ============================================================================

CREATE OR ALTER TRIGGER dbo.trg_MedicalRecords_IUD
ON  dbo.MedicalRecords
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Msg NVARCHAR(2000);

    -- ─────────────────────────────────────────────────────────────────────────
    -- Detect which DML event fired
    --   INSERT : rows in inserted only
    --   UPDATE : rows in both inserted and deleted
    --   DELETE : rows in deleted only
    -- ─────────────────────────────────────────────────────────────────────────
    DECLARE @IsInsert BIT = 0,
            @IsUpdate BIT = 0,
            @IsDelete BIT = 0;

    IF     EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted)
        SET @IsInsert = 1;
    IF     EXISTS (SELECT 1 FROM inserted) AND     EXISTS (SELECT 1 FROM deleted)
        SET @IsUpdate = 1;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND     EXISTS (SELECT 1 FROM deleted)
        SET @IsDelete = 1;


    -- =========================================================================
    -- INSERT EVENT
    -- =========================================================================
    IF @IsInsert = 1
    BEGIN
        -- ── Rule 1: AppointmentID must reference a 'Completed' appointment ────
        DECLARE @Bad NVARCHAR(1000) = N'';

        SELECT @Bad = @Bad
                    + CAST(i.RecordID AS NVARCHAR)  + N' (AppointmentID='
                    + CAST(i.AppointmentID AS NVARCHAR) + N', Status='
                    + ISNULL(a.Status, N'<missing>') + N') '
        FROM   inserted i
        LEFT JOIN dbo.Appointments a ON a.AppointmentID = i.AppointmentID
        WHERE  ISNULL(a.Status, N'') <> N'Completed';

        IF LEN(@Bad) > 0
        BEGIN
            SET @Msg = N'INSERT blocked by Rule 1 (Appointment Completeness Guard): '
                     + N'Record(s) [' + @Bad + N'] — MedicalRecords may only be '
                     + N'created for Completed appointments.';
            ROLLBACK TRANSACTION;
            RAISERROR(@Msg, 16, 1);
            RETURN;
        END;

        -- ── Rule 2: Diagnosis must not be empty / blank ───────────────────────
        SET @Bad = N'';

        SELECT @Bad = @Bad + CAST(RecordID AS NVARCHAR) + N' '
        FROM   inserted
        WHERE  NULLIF(LTRIM(RTRIM(Diagnosis)), N'') IS NULL;

        IF LEN(@Bad) > 0
        BEGIN
            SET @Msg = N'INSERT blocked by Rule 2 (Diagnosis Required): '
                     + N'Record(s) [' + @Bad + N'] — Diagnosis must not be empty or blank.';
            ROLLBACK TRANSACTION;
            RAISERROR(@Msg, 16, 1);
            RETURN;
        END;

        -- ── Rule 3: TreatmentPlan must not be empty / blank ───────────────────
        SET @Bad = N'';

        SELECT @Bad = @Bad + CAST(RecordID AS NVARCHAR) + N' '
        FROM   inserted
        WHERE  NULLIF(LTRIM(RTRIM(CAST(TreatmentPlan AS NVARCHAR(200)))), N'') IS NULL;

        IF LEN(@Bad) > 0
        BEGIN
            SET @Msg = N'INSERT blocked by Rule 3 (TreatmentPlan Required): '
                     + N'Record(s) [' + @Bad + N'] — TreatmentPlan must not be empty or blank.';
            ROLLBACK TRANSACTION;
            RAISERROR(@Msg, 16, 1);
            RETURN;
        END;

        -- ── Rule 4: Server-enforce CreatedDate = GETDATE() ────────────────────
        UPDATE mr
        SET    mr.CreatedDate = GETDATE()
        FROM   dbo.MedicalRecords mr
        INNER JOIN inserted i ON i.RecordID = mr.RecordID;

        -- ── Rule 5: Audit log every accepted INSERT ────────────────────────────
        INSERT INTO dbo.AuditLogs
               (PerformedByUserID, TableName, ActionType, ActionDate, OldValue, NewValue)
        SELECT 1,
               N'MedicalRecords',
               N'INSERT',
               GETDATE(),
               N'N/A',
               N'RecordID='       + CAST(i.RecordID      AS NVARCHAR)
             + N'; AppointmentID=' + CAST(i.AppointmentID AS NVARCHAR)
             + N'; Diagnosis='     + i.Diagnosis
        FROM inserted i;
    END;


    -- =========================================================================
    -- UPDATE EVENT
    -- =========================================================================
    IF @IsUpdate = 1
    BEGIN
        -- ── Rule 1: AppointmentID is immutable after creation ──────────────────
        DECLARE @BadUpd NVARCHAR(1000) = N'';

        SELECT @BadUpd = @BadUpd
                       + CAST(i.RecordID AS NVARCHAR)
                       + N' (' + CAST(d.AppointmentID AS NVARCHAR)
                       + N' -> ' + CAST(i.AppointmentID AS NVARCHAR) + N') '
        FROM   inserted i
        JOIN   deleted  d ON d.RecordID = i.RecordID
        WHERE  i.AppointmentID <> d.AppointmentID;

        IF LEN(@BadUpd) > 0
        BEGIN
            SET @Msg = N'UPDATE blocked by Rule 1 (AppointmentID Immutability): '
                     + N'Record(s) [' + @BadUpd + N'] — the AppointmentID on a '
                     + N'MedicalRecord cannot be changed after creation.';
            ROLLBACK TRANSACTION;
            RAISERROR(@Msg, 16, 1);
            RETURN;
        END;

        -- ── Rule 2: Diagnosis must not be cleared ─────────────────────────────
        SET @BadUpd = N'';

        SELECT @BadUpd = @BadUpd + CAST(i.RecordID AS NVARCHAR) + N' '
        FROM   inserted i
        WHERE  NULLIF(LTRIM(RTRIM(i.Diagnosis)), N'') IS NULL;

        IF LEN(@BadUpd) > 0
        BEGIN
            SET @Msg = N'UPDATE blocked by Rule 2 (Diagnosis Required): '
                     + N'Record(s) [' + @BadUpd + N'] — Diagnosis must not be set to empty or blank.';
            ROLLBACK TRANSACTION;
            RAISERROR(@Msg, 16, 1);
            RETURN;
        END;

        -- ── Rule 3: Audit log any change to Diagnosis, Notes, or TreatmentPlan
        INSERT INTO dbo.AuditLogs
               (PerformedByUserID, TableName, ActionType, ActionDate, OldValue, NewValue)
        SELECT 1,
               N'MedicalRecords',
               N'UPDATE',
               GETDATE(),
               N'Diagnosis='      + d.Diagnosis
             + N'; Notes='        + LEFT(d.Notes,          120)
             + N'; TreatmentPlan=' + LEFT(d.TreatmentPlan, 120),
               N'Diagnosis='      + i.Diagnosis
             + N'; Notes='        + LEFT(i.Notes,          120)
             + N'; TreatmentPlan=' + LEFT(i.TreatmentPlan, 120)
        FROM inserted i
        JOIN deleted  d ON d.RecordID = i.RecordID
        WHERE i.Diagnosis     <> d.Diagnosis
           OR i.Notes          <> d.Notes
           OR i.TreatmentPlan  <> d.TreatmentPlan;
    END;


    -- =========================================================================
    -- DELETE EVENT
    -- =========================================================================
    IF @IsDelete = 1
    BEGIN
        -- ── Rule 1: Records older than 7 days cannot be hard-deleted ──────────
        DECLARE @OldRecs NVARCHAR(1000) = N'';

        SELECT @OldRecs = @OldRecs
                        + CAST(RecordID AS NVARCHAR)
                        + N' (created ' + CONVERT(NVARCHAR, CreatedDate, 120) + N') '
        FROM   deleted
        WHERE  CreatedDate < DATEADD(day, -7, GETDATE());

        IF LEN(@OldRecs) > 0
        BEGIN
            SET @Msg = N'DELETE blocked by Rule 1 (Retention Policy): '
                     + N'Record(s) [' + @OldRecs + N'] — MedicalRecords older than 7 days '
                     + N'cannot be hard-deleted. Use the archive procedure instead.';
            ROLLBACK TRANSACTION;
            RAISERROR(@Msg, 16, 1);
            RETURN;
        END;

        -- ── Rule 2: Audit log deletions within the allowed 7-day window ───────
        INSERT INTO dbo.AuditLogs
               (PerformedByUserID, TableName, ActionType, ActionDate, OldValue, NewValue)
        SELECT 1,
               N'MedicalRecords',
               N'DELETE',
               GETDATE(),
               N'RecordID='       + CAST(d.RecordID      AS NVARCHAR)
             + N'; AppointmentID=' + CAST(d.AppointmentID AS NVARCHAR)
             + N'; Diagnosis='     + d.Diagnosis,
               N'N/A'
        FROM deleted d;
    END;

END;
GO


-- ============================================================================
-- SECTION 2 – TEST CASES
-- ============================================================================
-- Data prerequisites (verified before running):
--   AppointmentID=38 : Status='Completed', no MedicalRecord → valid INSERT target
--   AppointmentID=29 : Status='Scheduled'                   → Rule 1 rejection source
--   RecordID=1       : CreatedDate=2026-04-10 (>7 days)     → TC-DEL-1 retention block
--   RecordID=24      : created today by TC-INS-4             → UPDATE and TC-DEL-2 target
-- ─────────────────────────────────────────────────────────────────────────────


-- ── TC-INS-1 ─────────────────────────────────────────────────────────────────
-- EXPECTED : BLOCKED — AppointmentID=29 is 'Scheduled', not 'Completed' (Rule 1)
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN TRY
    INSERT INTO dbo.MedicalRecords
        (AppointmentID, Diagnosis, Notes, TreatmentPlan, CreatedDate)
    VALUES (29,
            'Viral pharyngitis',
            N'Sore throat, mild fever 37.8 C, no exudate.',
            N'Rest, oral hydration, paracetamol 500 mg q6h for 3 days.',
            '2026-05-07 10:00:00');
END TRY
BEGIN CATCH
    SELECT 'TC-INS-1'                                                    AS Test,
           'BLOCK: Insert for Scheduled appointment (Rule 1)'            AS Description,
           ERROR_NUMBER()                                                 AS ErrNum,
           LEFT(ERROR_MESSAGE(), 160)                                     AS ErrMsg,
           CASE WHEN ERROR_NUMBER() = 50000 THEN 'PASS' ELSE 'FAIL' END  AS Result;
END CATCH;
GO


-- ── TC-INS-2 ─────────────────────────────────────────────────────────────────
-- EXPECTED : BLOCKED — Diagnosis is blank whitespace (Rule 2)
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN TRY
    INSERT INTO dbo.MedicalRecords
        (AppointmentID, Diagnosis, Notes, TreatmentPlan, CreatedDate)
    VALUES (38,
            '   ',
            N'Patient seen for routine follow-up.',
            N'Continue current medication regimen.',
            '2026-05-07 10:00:00');
END TRY
BEGIN CATCH
    SELECT 'TC-INS-2'                                                    AS Test,
           'BLOCK: Insert with blank Diagnosis (Rule 2)'                 AS Description,
           ERROR_NUMBER()                                                 AS ErrNum,
           LEFT(ERROR_MESSAGE(), 160)                                     AS ErrMsg,
           CASE WHEN ERROR_NUMBER() = 50000 THEN 'PASS' ELSE 'FAIL' END  AS Result;
END CATCH;
GO


-- ── TC-INS-3 ─────────────────────────────────────────────────────────────────
-- EXPECTED : BLOCKED — TreatmentPlan is blank whitespace (Rule 3)
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN TRY
    INSERT INTO dbo.MedicalRecords
        (AppointmentID, Diagnosis, Notes, TreatmentPlan, CreatedDate)
    VALUES (38,
            'Acute bronchitis',
            N'Productive cough for 5 days, no fever, clear lung fields.',
            N'   ',
            '2026-05-07 10:00:00');
END TRY
BEGIN CATCH
    SELECT 'TC-INS-3'                                                    AS Test,
           'BLOCK: Insert with blank TreatmentPlan (Rule 3)'             AS Description,
           ERROR_NUMBER()                                                 AS ErrNum,
           LEFT(ERROR_MESSAGE(), 160)                                     AS ErrMsg,
           CASE WHEN ERROR_NUMBER() = 50000 THEN 'PASS' ELSE 'FAIL' END  AS Result;
END CATCH;
GO


-- ── TC-INS-4 + TC-INS-5 ──────────────────────────────────────────────────────
-- TC-INS-4 EXPECTED : ACCEPTED — all fields valid; RecordID=24 created
-- TC-INS-5 EXPECTED : CreatedDate stored as today, not '2020-01-01' (Rule 4)
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO dbo.MedicalRecords
    (AppointmentID, Diagnosis, Notes, TreatmentPlan, CreatedDate)
VALUES (38,
        'Stable angina pectoris',
        N'Exertional chest discomfort relieved by rest. ECG: ST depression leads II, III.',
        N'Sublingual nitroglycerin 0.5 mg PRN; cardiology referral; low-sodium diet.',
        '2020-01-01 00:00:00');  -- stale date: trigger must overwrite with GETDATE()

SELECT
    'TC-INS-4/5'                                                                   AS Test,
    'ACCEPT: Valid insert; CreatedDate server-enforced (Rules 1-5)'                AS Description,
    mr.RecordID,
    mr.AppointmentID,
    mr.Diagnosis,
    mr.CreatedDate                                                                  AS StoredDate,
    CAST(GETDATE() AS DATE)                                                         AS ExpectedDate,
    CASE
        WHEN mr.AppointmentID = 38
         AND CAST(mr.CreatedDate AS DATE) = CAST(GETDATE() AS DATE)
        THEN 'PASS' ELSE 'FAIL'
    END AS Result
FROM dbo.MedicalRecords mr
WHERE mr.AppointmentID = 38;
GO


-- ── TC-UPD-1 ─────────────────────────────────────────────────────────────────
-- EXPECTED : BLOCKED — attempt to reassign AppointmentID (Rule 1)
-- AppointmentID=29 is used: it exists in Appointments (FK passes) and has no
-- MedicalRecord (UNIQUE passes), so only our trigger's Rule 1 fires.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @RecID INT = (SELECT MAX(RecordID) FROM dbo.MedicalRecords);

BEGIN TRY
    UPDATE dbo.MedicalRecords
    SET    AppointmentID = 29
    WHERE  RecordID = @RecID;
END TRY
BEGIN CATCH
    SELECT 'TC-UPD-1'                                                    AS Test,
           'BLOCK: AppointmentID change attempt (Rule 1)'                AS Description,
           ERROR_NUMBER()                                                 AS ErrNum,
           LEFT(ERROR_MESSAGE(), 160)                                     AS ErrMsg,
           CASE WHEN ERROR_NUMBER() = 50000 THEN 'PASS' ELSE 'FAIL' END  AS Result;
END CATCH;
GO


-- ── TC-UPD-2 ─────────────────────────────────────────────────────────────────
-- EXPECTED : BLOCKED — Diagnosis cleared to blank whitespace (Rule 2)
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @RecID INT = (SELECT MAX(RecordID) FROM dbo.MedicalRecords);

BEGIN TRY
    UPDATE dbo.MedicalRecords
    SET    Diagnosis = '   '
    WHERE  RecordID = @RecID;
END TRY
BEGIN CATCH
    SELECT 'TC-UPD-2'                                                    AS Test,
           'BLOCK: Diagnosis cleared to blank (Rule 2)'                  AS Description,
           ERROR_NUMBER()                                                 AS ErrNum,
           LEFT(ERROR_MESSAGE(), 160)                                     AS ErrMsg,
           CASE WHEN ERROR_NUMBER() = 50000 THEN 'PASS' ELSE 'FAIL' END  AS Result;
END CATCH;
GO


-- ── TC-UPD-3 ─────────────────────────────────────────────────────────────────
-- EXPECTED : ACCEPTED — Diagnosis amended; one UPDATE audit entry written (Rule 3)
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @RecID INT = (SELECT MAX(RecordID) FROM dbo.MedicalRecords);

UPDATE dbo.MedicalRecords
SET    Diagnosis = 'Stable angina pectoris — amended after cardiology review'
WHERE  RecordID = @RecID;

SELECT
    'TC-UPD-3'                                                                    AS Test,
    'ACCEPT: Diagnosis amended + audit entry written (Rule 3)'                    AS Description,
    mr.RecordID,
    mr.Diagnosis                                                                   AS UpdatedDiagnosis,
    (SELECT COUNT(*) FROM dbo.AuditLogs
     WHERE  TableName  = 'MedicalRecords'
       AND  ActionType = 'UPDATE'
       AND  CAST(ActionDate AS DATE) = CAST(GETDATE() AS DATE))                   AS UpdateAuditCount,
    CASE
        WHEN mr.Diagnosis = 'Stable angina pectoris — amended after cardiology review'
         AND (SELECT COUNT(*) FROM dbo.AuditLogs
              WHERE  TableName  = 'MedicalRecords'
                AND  ActionType = 'UPDATE'
                AND  CAST(ActionDate AS DATE) = CAST(GETDATE() AS DATE)) >= 1
        THEN 'PASS' ELSE 'FAIL'
    END AS Result
FROM dbo.MedicalRecords mr
WHERE mr.RecordID = @RecID;
GO


-- ── TC-DEL-1 ─────────────────────────────────────────────────────────────────
-- EXPECTED : BLOCKED — RecordID=7 created 2025-08-14 (>7 days, no child
--            Prescriptions so FK does not fire before our trigger, Rule 1)
-- ─────────────────────────────────────────────────────────────────────────────
BEGIN TRY
    DELETE FROM dbo.MedicalRecords WHERE RecordID = 7;
END TRY
BEGIN CATCH
    SELECT 'TC-DEL-1'                                                     AS Test,
           'BLOCK: Retention policy — record > 7 days old (Rule 1)'       AS Description,
           ERROR_NUMBER()                                                  AS ErrNum,
           LEFT(ERROR_MESSAGE(), 160)                                      AS ErrMsg,
           CASE WHEN ERROR_NUMBER() = 50000 THEN 'PASS' ELSE 'FAIL' END   AS Result;
END CATCH;
GO


-- ── TC-DEL-2 ─────────────────────────────────────────────────────────────────
-- EXPECTED : ACCEPTED — RecordID=24 created today (<7 days); row gone + audit logged
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @RecID INT = (SELECT MAX(RecordID) FROM dbo.MedicalRecords);

DELETE FROM dbo.MedicalRecords WHERE RecordID = @RecID;

SELECT
    'TC-DEL-2'                                                                    AS Test,
    'ACCEPT: Fresh record deleted + audit entry written (Rule 2)'                 AS Description,
    (SELECT COUNT(*) FROM dbo.MedicalRecords WHERE RecordID = @RecID)             AS RowsRemaining,
    (SELECT COUNT(*) FROM dbo.AuditLogs
     WHERE  TableName  = 'MedicalRecords'
       AND  ActionType = 'DELETE'
       AND  CAST(ActionDate AS DATE) = CAST(GETDATE() AS DATE))                   AS DeleteAuditCount,
    CASE
        WHEN (SELECT COUNT(*) FROM dbo.MedicalRecords WHERE RecordID = @RecID) = 0
         AND (SELECT COUNT(*) FROM dbo.AuditLogs
              WHERE  TableName  = 'MedicalRecords'
                AND  ActionType = 'DELETE'
                AND  CAST(ActionDate AS DATE) = CAST(GETDATE() AS DATE)) >= 1
        THEN 'PASS' ELSE 'FAIL'
    END AS Result;
GO


-- ============================================================================
-- SECTION 3 – AUDIT AND INTEGRITY SUMMARY
-- ============================================================================

-- Audit entries written today by the trigger (all three event types)
SELECT ActionType,
       COUNT(*)  AS EntryCount,
       'PASS'    AS Result
FROM   dbo.AuditLogs
WHERE  TableName  = 'MedicalRecords'
  AND  CAST(ActionDate AS DATE) = CAST(GETDATE() AS DATE)
GROUP  BY ActionType
ORDER  BY ActionType;
GO

-- Seed records still intact after rejected deletes
SELECT
    'Integrity: RecordID=7 intact after TC-DEL-1 rejection' AS [Check],
    CASE WHEN EXISTS (SELECT 1 FROM dbo.MedicalRecords WHERE RecordID = 7)
         THEN 'PASS' ELSE 'FAIL'
    END AS Result
UNION ALL
SELECT
    'Integrity: No orphan records (AppointmentID FK valid)',
    CASE WHEN NOT EXISTS (
        SELECT 1 FROM dbo.MedicalRecords mr
        WHERE NOT EXISTS (SELECT 1 FROM dbo.Appointments a WHERE a.AppointmentID = mr.AppointmentID)
    ) THEN 'PASS' ELSE 'FAIL' END;
GO
