-- =============================================================================
-- HospitalDB — Data Retention: Archive Stored Procedures
-- File        : sql/12_data_retention_procedures.sql
-- Author      : Hospital Information Systems
-- Date        : 2026-05-07
-- Description :
--   Four stored procedures that implement the 5-year data retention policy.
--   All procedures accept a @DryRun flag that projects counts without
--   making changes, and a @CutoffDate override for ad-hoc or catch-up runs.
--
--   Procedures:
--     1. dbo.usp_Retention_ArchiveAuditLogs       — standalone log archiving
--     2. dbo.usp_Retention_ArchiveErrorLogs        — standalone log archiving
--     3. dbo.usp_Retention_ArchiveAppointmentChain — main clinical/billing chain
--     4. dbo.usp_Retention_RunPolicy               — orchestrator; calls 1-3
--     5. dbo.usp_Retention_GetStats                — reporting view of counts
--
--   Referential integrity strategy:
--     • Only appointments that are fully settled (all bills Paid or no bills
--       at all, no Pending/In-Progress lab orders) are eligible.
--     • Records are archived in child-before-parent order to satisfy FK
--       constraints during the DELETE phase.
--     • The entire archive+delete cycle for each batch runs inside a single
--       SAVEPOINT-protected transaction so a failure rolls back both phases.
--     • Master/reference tables (Patients, Doctors, Departments, etc.) are
--       never deleted — archive tables retain the original FK values as data.
--
--   Run order: sql/11_data_retention_archive_tables.sql must be run first.
-- =============================================================================

USE HospitalDB;
GO

-- =============================================================================
-- 1. usp_Retention_ArchiveAuditLogs
-- =============================================================================
-- Moves AuditLog rows older than @CutoffDate into Archive.AuditLogs.
-- AuditLogs can accumulate very quickly; a @BatchSize limit prevents the
-- transaction from locking the table for too long on catch-up runs.
-- =============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Retention_ArchiveAuditLogs
    @CutoffDate  DATE             = NULL,  -- NULL = 5 years ago
    @BatchSize   INT              = 2000,  -- rows per execution
    @DryRun      BIT              = 0,
    @JobRunID    UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Cutoff    DATE     = ISNULL(@CutoffDate, CAST(DATEADD(YEAR, -5, GETDATE()) AS DATE));
    DECLARE @BatchID   UNIQUEIDENTIFIER = NEWID();
    DECLARE @StartTime DATETIME          = GETDATE();
    DECLARE @Now       DATETIME          = GETDATE();
    DECLARE @Archived  INT               = 0;

    -- -------------------------------------------------------------------------
    -- Dry run: return projected counts without any data movement
    -- -------------------------------------------------------------------------
    IF @DryRun = 1
    BEGIN
        SELECT
            COUNT(*)        AS EligibleAuditLogs,
            MIN(ActionDate) AS OldestEligible,
            MAX(ActionDate) AS NewestEligible,
            @Cutoff         AS CutoffDate,
            @BatchSize      AS BatchSize,
            'AuditLogs'     AS Phase
        FROM  dbo.AuditLogs
        WHERE ActionDate < @Cutoff
          AND AuditID NOT IN (SELECT AuditID FROM Archive.AuditLogs);
        RETURN 0;
    END

    -- -------------------------------------------------------------------------
    -- Live run: archive then delete within a single transaction
    -- -------------------------------------------------------------------------
    BEGIN TRANSACTION;
    BEGIN TRY

        INSERT INTO Archive.AuditLogs
               (AuditID, PerformedByUserID, TableName, ActionType,
                ActionDate, OldValue, NewValue, ArchivedDate, ArchiveBatchID)
        SELECT TOP (@BatchSize)
               al.AuditID, al.PerformedByUserID, al.TableName, al.ActionType,
               al.ActionDate, al.OldValue, al.NewValue, @Now, @BatchID
        FROM   dbo.AuditLogs al
        WHERE  al.ActionDate < @Cutoff
          AND  al.AuditID NOT IN (SELECT AuditID FROM Archive.AuditLogs)
        ORDER BY al.ActionDate ASC;

        SET @Archived = @@ROWCOUNT;

        -- Delete only the rows that were just archived (identified by BatchID)
        DELETE FROM dbo.AuditLogs
        WHERE  AuditID IN (
            SELECT AuditID FROM Archive.AuditLogs
            WHERE  ArchiveBatchID = @BatchID
        );

        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        INSERT INTO dbo.ErrorLogs (ProcedureName, ErrorMessage, ErrorDate)
        VALUES ('usp_Retention_ArchiveAuditLogs',
                CONCAT('BatchID=', CAST(@BatchID AS VARCHAR(36)), ' | ', ERROR_MESSAGE()),
                GETDATE());
        THROW;
    END CATCH

    -- Log to RetentionJobLog when called from the orchestrator
    IF @JobRunID IS NOT NULL
    BEGIN
        INSERT INTO dbo.RetentionJobLog
               (JobRunID, RunDate, CutoffDate, Phase,
                ArchiveInserted, ActiveDeleted, DurationMs, WasDryRun)
        VALUES (@JobRunID, GETDATE(), @Cutoff, 'AuditLogs',
                @Archived, @Archived,
                DATEDIFF(MILLISECOND, @StartTime, GETDATE()), 0);
    END

    SELECT @Archived AS ArchivedCount, 'AuditLogs' AS Phase;
END;
GO


-- =============================================================================
-- 2. usp_Retention_ArchiveErrorLogs
-- =============================================================================
-- Moves ErrorLog rows older than @CutoffDate into Archive.ErrorLogs.
-- =============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Retention_ArchiveErrorLogs
    @CutoffDate  DATE             = NULL,
    @BatchSize   INT              = 1000,
    @DryRun      BIT              = 0,
    @JobRunID    UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Cutoff    DATE             = ISNULL(@CutoffDate, CAST(DATEADD(YEAR, -5, GETDATE()) AS DATE));
    DECLARE @BatchID   UNIQUEIDENTIFIER = NEWID();
    DECLARE @StartTime DATETIME         = GETDATE();
    DECLARE @Now       DATETIME         = GETDATE();
    DECLARE @Archived  INT              = 0;

    IF @DryRun = 1
    BEGIN
        SELECT
            COUNT(*)       AS EligibleErrorLogs,
            MIN(ErrorDate) AS OldestEligible,
            MAX(ErrorDate) AS NewestEligible,
            @Cutoff        AS CutoffDate,
            @BatchSize     AS BatchSize,
            'ErrorLogs'    AS Phase
        FROM  dbo.ErrorLogs
        WHERE ErrorDate < @Cutoff
          AND ErrorID NOT IN (SELECT ErrorID FROM Archive.ErrorLogs);
        RETURN 0;
    END

    BEGIN TRANSACTION;
    BEGIN TRY

        INSERT INTO Archive.ErrorLogs
               (ErrorID, ProcedureName, ErrorMessage,
                ErrorDate, ArchivedDate, ArchiveBatchID)
        SELECT TOP (@BatchSize)
               el.ErrorID, el.ProcedureName, el.ErrorMessage,
               el.ErrorDate, @Now, @BatchID
        FROM   dbo.ErrorLogs el
        WHERE  el.ErrorDate < @Cutoff
          AND  el.ErrorID NOT IN (SELECT ErrorID FROM Archive.ErrorLogs)
        ORDER BY el.ErrorDate ASC;

        SET @Archived = @@ROWCOUNT;

        DELETE FROM dbo.ErrorLogs
        WHERE  ErrorID IN (
            SELECT ErrorID FROM Archive.ErrorLogs
            WHERE  ArchiveBatchID = @BatchID
        );

        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        INSERT INTO dbo.ErrorLogs (ProcedureName, ErrorMessage, ErrorDate)
        VALUES ('usp_Retention_ArchiveErrorLogs',
                CONCAT('BatchID=', CAST(@BatchID AS VARCHAR(36)), ' | ', ERROR_MESSAGE()),
                GETDATE());
        THROW;
    END CATCH

    IF @JobRunID IS NOT NULL
    BEGIN
        INSERT INTO dbo.RetentionJobLog
               (JobRunID, RunDate, CutoffDate, Phase,
                ArchiveInserted, ActiveDeleted, DurationMs, WasDryRun)
        VALUES (@JobRunID, GETDATE(), @Cutoff, 'ErrorLogs',
                @Archived, @Archived,
                DATEDIFF(MILLISECOND, @StartTime, GETDATE()), 0);
    END

    SELECT @Archived AS ArchivedCount, 'ErrorLogs' AS Phase;
END;
GO


-- =============================================================================
-- 3. usp_Retention_ArchiveAppointmentChain
-- =============================================================================
-- Archives a batch of old, fully-settled appointments and all their dependent
-- records in a single atomic transaction.
--
-- Eligibility criteria for an appointment:
--   • AppointmentDate is older than @CutoffDate
--   • Status is Completed, No-Show, or Cancelled
--   • All associated bills (if any) are fully Paid — no open balances
--   • No associated lab orders are Pending or In-Progress
--   • Not already present in Archive.Appointments
--
-- Archive order (children archived before their parents to allow clean DELETEs):
--   1. PrescriptionItems  → child of Prescriptions
--   2. Prescriptions      → child of MedicalRecords
--   3. MedicalRecords     → child of Appointments
--   4. BillItems          → child of Bills
--   5. Payments           → child of Bills
--   6. Bills              → child of Appointments
--   7. LabOrders          → child of Appointments
--   8. Appointments       → the root record
--
-- Delete order mirrors archive order (children first).
-- =============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Retention_ArchiveAppointmentChain
    @CutoffDate  DATE             = NULL,
    @BatchSize   INT              = 500,
    @DryRun      BIT              = 0,
    @JobRunID    UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Cutoff    DATE             = ISNULL(@CutoffDate, CAST(DATEADD(YEAR, -5, GETDATE()) AS DATE));
    DECLARE @BatchID   UNIQUEIDENTIFIER = NEWID();
    DECLARE @StartTime DATETIME         = GETDATE();
    DECLARE @Now       DATETIME         = GETDATE();

    -- Counters
    DECLARE @ApptsArchived     INT = 0;
    DECLARE @BillsArchived     INT = 0;
    DECLARE @BillItemsArchived INT = 0;
    DECLARE @PaymentsArchived  INT = 0;
    DECLARE @RecordsArchived   INT = 0;
    DECLARE @RxArchived        INT = 0;
    DECLARE @RxItemsArchived   INT = 0;
    DECLARE @LabsArchived      INT = 0;

    -- -------------------------------------------------------------------------
    -- Collect the batch of eligible appointment IDs
    -- -------------------------------------------------------------------------
    DECLARE @EligibleAppts TABLE (AppointmentID INT PRIMARY KEY);

    INSERT INTO @EligibleAppts (AppointmentID)
    SELECT TOP (@BatchSize) a.AppointmentID
    FROM   dbo.Appointments a
    WHERE  CAST(a.AppointmentDate AS DATE) < @Cutoff
      AND  a.Status IN ('Completed', 'No-Show', 'Cancelled')
      -- No unpaid or partially-paid bills may remain open
      AND  NOT EXISTS (
               SELECT 1
               FROM   dbo.Bills b
               WHERE  b.AppointmentID = a.AppointmentID
                 AND  b.BillStatus   != 'Paid'
           )
      -- No lab orders that are still awaiting results
      AND  NOT EXISTS (
               SELECT 1
               FROM   dbo.LabOrders lo
               WHERE  lo.AppointmentID = a.AppointmentID
                 AND  lo.Status IN ('Pending', 'In-Progress')
           )
      -- Skip appointments already in the archive
      AND  NOT EXISTS (
               SELECT 1
               FROM   Archive.Appointments aa
               WHERE  aa.AppointmentID = a.AppointmentID
           )
    ORDER BY a.AppointmentDate ASC;   -- oldest records first

    -- -------------------------------------------------------------------------
    -- Dry run: return projected counts without moving any data
    -- -------------------------------------------------------------------------
    IF @DryRun = 1
    BEGIN
        SELECT
            COUNT(DISTINCT ea.AppointmentID)       AS EligibleAppointments,
            COUNT(DISTINCT b.BillID)               AS AssociatedBills,
            COUNT(DISTINCT bi.BillItemID)          AS AssociatedBillItems,
            COUNT(DISTINCT py.PaymentID)           AS AssociatedPayments,
            COUNT(DISTINCT mr.RecordID)            AS AssociatedMedicalRecords,
            COUNT(DISTINCT rx.PrescriptionID)      AS AssociatedPrescriptions,
            COUNT(DISTINCT rxi.PrescriptionItemID) AS AssociatedPrescriptionItems,
            COUNT(DISTINCT lo.LabOrderID)          AS AssociatedLabOrders,
            @Cutoff                                AS CutoffDate,
            @BatchSize                             AS BatchSize,
            'AppointmentChain'                     AS Phase
        FROM      @EligibleAppts       ea
        LEFT JOIN dbo.Bills            b   ON b.AppointmentID     = ea.AppointmentID
        LEFT JOIN dbo.BillItems        bi  ON bi.BillID           = b.BillID
        LEFT JOIN dbo.Payments         py  ON py.BillID           = b.BillID
        LEFT JOIN dbo.MedicalRecords   mr  ON mr.AppointmentID    = ea.AppointmentID
        LEFT JOIN dbo.Prescriptions    rx  ON rx.RecordID         = mr.RecordID
        LEFT JOIN dbo.PrescriptionItems rxi ON rxi.PrescriptionID = rx.PrescriptionID
        LEFT JOIN dbo.LabOrders        lo  ON lo.AppointmentID    = ea.AppointmentID;
        RETURN 0;
    END

    -- -------------------------------------------------------------------------
    -- Pre-collect dependent IDs before entering the transaction
    -- (table variables survive ROLLBACK; collecting outside the transaction
    --  avoids holding locks while we scan for dependent records)
    -- -------------------------------------------------------------------------
    DECLARE @EligibleBills   TABLE (BillID         INT PRIMARY KEY);
    DECLARE @EligibleRecords TABLE (RecordID       INT PRIMARY KEY);
    DECLARE @EligibleRx      TABLE (PrescriptionID INT PRIMARY KEY);

    INSERT INTO @EligibleBills   (BillID)
    SELECT BillID   FROM dbo.Bills          WHERE AppointmentID IN (SELECT AppointmentID FROM @EligibleAppts);

    INSERT INTO @EligibleRecords (RecordID)
    SELECT RecordID FROM dbo.MedicalRecords WHERE AppointmentID IN (SELECT AppointmentID FROM @EligibleAppts);

    INSERT INTO @EligibleRx      (PrescriptionID)
    SELECT PrescriptionID        FROM dbo.Prescriptions WHERE RecordID IN (SELECT RecordID FROM @EligibleRecords);

    -- -------------------------------------------------------------------------
    -- Archive + Delete in a single transaction
    -- -------------------------------------------------------------------------
    BEGIN TRANSACTION;
    BEGIN TRY

        -- ==================================================================
        -- ARCHIVE PHASE — INSERT into Archive tables (children first)
        -- ==================================================================

        -- 1. PrescriptionItems
        INSERT INTO Archive.PrescriptionItems
               (PrescriptionItemID, PrescriptionID, MedicationName,
                Dosage, Frequency, Duration, ArchivedDate, ArchiveBatchID)
        SELECT  rxi.PrescriptionItemID, rxi.PrescriptionID, rxi.MedicationName,
                rxi.Dosage, rxi.Frequency, rxi.Duration, @Now, @BatchID
        FROM    dbo.PrescriptionItems rxi
        WHERE   rxi.PrescriptionID IN (SELECT PrescriptionID FROM @EligibleRx);
        SET @RxItemsArchived = @@ROWCOUNT;

        -- 2. Prescriptions
        INSERT INTO Archive.Prescriptions
               (PrescriptionID, RecordID, DoctorID, PrescriptionDate,
                ArchivedDate, ArchiveBatchID)
        SELECT  rx.PrescriptionID, rx.RecordID, rx.DoctorID, rx.PrescriptionDate,
                @Now, @BatchID
        FROM    dbo.Prescriptions rx
        WHERE   rx.RecordID IN (SELECT RecordID FROM @EligibleRecords);
        SET @RxArchived = @@ROWCOUNT;

        -- 3. MedicalRecords
        INSERT INTO Archive.MedicalRecords
               (RecordID, AppointmentID, Diagnosis, Notes, TreatmentPlan,
                CreatedDate, ArchivedDate, ArchiveBatchID)
        SELECT  mr.RecordID, mr.AppointmentID, mr.Diagnosis, mr.Notes,
                mr.TreatmentPlan, mr.CreatedDate, @Now, @BatchID
        FROM    dbo.MedicalRecords mr
        WHERE   mr.AppointmentID IN (SELECT AppointmentID FROM @EligibleAppts);
        SET @RecordsArchived = @@ROWCOUNT;

        -- 4. BillItems
        INSERT INTO Archive.BillItems
               (BillItemID, BillID, ServiceID, Quantity, UnitPrice,
                LineTotal, ArchivedDate, ArchiveBatchID)
        SELECT  bi.BillItemID, bi.BillID, bi.ServiceID, bi.Quantity, bi.UnitPrice,
                bi.LineTotal, @Now, @BatchID
        FROM    dbo.BillItems bi
        WHERE   bi.BillID IN (SELECT BillID FROM @EligibleBills);
        SET @BillItemsArchived = @@ROWCOUNT;

        -- 5. Payments
        INSERT INTO Archive.Payments
               (PaymentID, BillID, PaymentDate, Amount, PaymentMethod,
                ReferenceNumber, ArchivedDate, ArchiveBatchID)
        SELECT  py.PaymentID, py.BillID, py.PaymentDate, py.Amount,
                py.PaymentMethod, py.ReferenceNumber, @Now, @BatchID
        FROM    dbo.Payments py
        WHERE   py.BillID IN (SELECT BillID FROM @EligibleBills);
        SET @PaymentsArchived = @@ROWCOUNT;

        -- 6. Bills
        INSERT INTO Archive.Bills
               (BillID, PatientID, AppointmentID, TotalAmount, PaidAmount,
                Balance, BillStatus, CreatedDate, ArchivedDate, ArchiveBatchID)
        SELECT  b.BillID, b.PatientID, b.AppointmentID, b.TotalAmount,
                b.PaidAmount, b.Balance, b.BillStatus, b.CreatedDate, @Now, @BatchID
        FROM    dbo.Bills b
        WHERE   b.AppointmentID IN (SELECT AppointmentID FROM @EligibleAppts);
        SET @BillsArchived = @@ROWCOUNT;

        -- 7. LabOrders
        INSERT INTO Archive.LabOrders
               (LabOrderID, AppointmentID, LabTestTypeID, Result, Status,
                DateRequested, ArchivedDate, ArchiveBatchID)
        SELECT  lo.LabOrderID, lo.AppointmentID, lo.LabTestTypeID, lo.Result,
                lo.Status, lo.DateRequested, @Now, @BatchID
        FROM    dbo.LabOrders lo
        WHERE   lo.AppointmentID IN (SELECT AppointmentID FROM @EligibleAppts);
        SET @LabsArchived = @@ROWCOUNT;

        -- 8. Appointments
        INSERT INTO Archive.Appointments
               (AppointmentID, PatientID, DoctorID, CreatedByUserID,
                AppointmentDate, Status, Reason, ArchivedDate, ArchiveBatchID)
        SELECT  a.AppointmentID, a.PatientID, a.DoctorID, a.CreatedByUserID,
                a.AppointmentDate, a.Status, a.Reason, @Now, @BatchID
        FROM    dbo.Appointments a
        WHERE   a.AppointmentID IN (SELECT AppointmentID FROM @EligibleAppts);
        SET @ApptsArchived = @@ROWCOUNT;

        -- ==================================================================
        -- DELETE PHASE — remove from active tables (children first)
        -- ==================================================================

        DELETE FROM dbo.PrescriptionItems
        WHERE  PrescriptionID IN (SELECT PrescriptionID FROM @EligibleRx);

        DELETE FROM dbo.Prescriptions
        WHERE  RecordID IN (SELECT RecordID FROM @EligibleRecords);

        DELETE FROM dbo.MedicalRecords
        WHERE  AppointmentID IN (SELECT AppointmentID FROM @EligibleAppts);

        DELETE FROM dbo.BillItems
        WHERE  BillID IN (SELECT BillID FROM @EligibleBills);

        DELETE FROM dbo.Payments
        WHERE  BillID IN (SELECT BillID FROM @EligibleBills);

        DELETE FROM dbo.Bills
        WHERE  AppointmentID IN (SELECT AppointmentID FROM @EligibleAppts);

        DELETE FROM dbo.LabOrders
        WHERE  AppointmentID IN (SELECT AppointmentID FROM @EligibleAppts);

        DELETE FROM dbo.Appointments
        WHERE  AppointmentID IN (SELECT AppointmentID FROM @EligibleAppts);

        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        INSERT INTO dbo.ErrorLogs (ProcedureName, ErrorMessage, ErrorDate)
        VALUES ('usp_Retention_ArchiveAppointmentChain',
                CONCAT('BatchID=', CAST(@BatchID AS VARCHAR(36)), ' | ', ERROR_MESSAGE()),
                GETDATE());
        THROW;
    END CATCH

    -- Log to RetentionJobLog
    IF @JobRunID IS NOT NULL
    BEGIN
        INSERT INTO dbo.RetentionJobLog
               (JobRunID, RunDate, CutoffDate, Phase,
                ArchiveInserted, ActiveDeleted, DurationMs, WasDryRun)
        VALUES (@JobRunID, GETDATE(), @Cutoff, 'AppointmentChain',
                @ApptsArchived, @ApptsArchived,
                DATEDIFF(MILLISECOND, @StartTime, GETDATE()), 0);
    END

    -- Return per-table counts as a single result set
    SELECT 'AppointmentChain' AS Phase, 'Appointments'     AS TableName, @ApptsArchived     AS ArchivedCount UNION ALL
    SELECT 'AppointmentChain',          'Bills',                         @BillsArchived     UNION ALL
    SELECT 'AppointmentChain',          'BillItems',                     @BillItemsArchived UNION ALL
    SELECT 'AppointmentChain',          'Payments',                      @PaymentsArchived  UNION ALL
    SELECT 'AppointmentChain',          'MedicalRecords',                @RecordsArchived   UNION ALL
    SELECT 'AppointmentChain',          'Prescriptions',                 @RxArchived        UNION ALL
    SELECT 'AppointmentChain',          'PrescriptionItems',             @RxItemsArchived   UNION ALL
    SELECT 'AppointmentChain',          'LabOrders',                     @LabsArchived;
END;
GO


-- =============================================================================
-- 4. usp_Retention_RunPolicy
-- =============================================================================
-- Orchestrator.  Calls all three archive procedures in sequence under a single
-- JobRunID so every log entry for a given execution shares the same GUID.
-- On dry run (@DryRun = 1) each sub-procedure returns a projected-count result
-- set and nothing is written to RetentionJobLog.
-- =============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Retention_RunPolicy
    @CutoffDate  DATE = NULL,   -- NULL = exactly 5 years ago
    @BatchSize   INT  = 500,    -- maximum rows per table per phase
    @DryRun      BIT  = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Cutoff   DATE             = ISNULL(@CutoffDate, CAST(DATEADD(YEAR, -5, GETDATE()) AS DATE));
    DECLARE @JobRunID UNIQUEIDENTIFIER = NEWID();

    -- When dry-running, pass NULL JobRunID so sub-procedures skip the log insert
    DECLARE @LogID    UNIQUEIDENTIFIER = CASE WHEN @DryRun = 0 THEN @JobRunID ELSE NULL END;

    -- Phase 1: Appointment chain (clinical + billing records)
    EXEC dbo.usp_Retention_ArchiveAppointmentChain
        @CutoffDate = @Cutoff,
        @BatchSize  = @BatchSize,
        @DryRun     = @DryRun,
        @JobRunID   = @LogID;

    -- Phase 2: Audit logs
    EXEC dbo.usp_Retention_ArchiveAuditLogs
        @CutoffDate = @Cutoff,
        @BatchSize  = @BatchSize,
        @DryRun     = @DryRun,
        @JobRunID   = @LogID;

    -- Phase 3: Error logs
    EXEC dbo.usp_Retention_ArchiveErrorLogs
        @CutoffDate = @Cutoff,
        @BatchSize  = @BatchSize,
        @DryRun     = @DryRun,
        @JobRunID   = @LogID;

    -- Return job log summary (live runs only)
    IF @DryRun = 0
    BEGIN
        SELECT
            JobRunID,
            Phase,
            ArchiveInserted,
            ActiveDeleted,
            DurationMs,
            CutoffDate,
            RunDate
        FROM  dbo.RetentionJobLog
        WHERE JobRunID = @JobRunID
        ORDER BY LogID ASC;
    END
END;
GO


-- =============================================================================
-- 5. usp_Retention_GetStats
-- =============================================================================
-- Diagnostic read-only procedure.  Returns:
--   Result Set 1 — Active vs. archived row counts for all participating tables
--   Result Set 2 — The 20 most recent RetentionJobLog entries
-- =============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Retention_GetStats
AS
BEGIN
    SET NOCOUNT ON;

    -- Result Set 1: Active vs. archived counts
    SELECT SchemaName, TableName, ActiveCount, ArchivedCount, OldestActive, OldestArchived
    FROM (
        SELECT 'dbo'     AS SchemaName, 'Appointments' AS TableName,
               (SELECT COUNT(*) FROM dbo.Appointments)     AS ActiveCount,
               (SELECT COUNT(*) FROM Archive.Appointments) AS ArchivedCount,
               (SELECT MIN(AppointmentDate) FROM dbo.Appointments)     AS OldestActive,
               (SELECT MIN(AppointmentDate) FROM Archive.Appointments) AS OldestArchived
        UNION ALL
        SELECT 'dbo', 'Bills',
               (SELECT COUNT(*) FROM dbo.Bills),
               (SELECT COUNT(*) FROM Archive.Bills),
               (SELECT MIN(CreatedDate) FROM dbo.Bills),
               (SELECT MIN(CreatedDate) FROM Archive.Bills)
        UNION ALL
        SELECT 'dbo', 'BillItems',
               (SELECT COUNT(*) FROM dbo.BillItems),
               (SELECT COUNT(*) FROM Archive.BillItems),
               NULL, NULL
        UNION ALL
        SELECT 'dbo', 'Payments',
               (SELECT COUNT(*) FROM dbo.Payments),
               (SELECT COUNT(*) FROM Archive.Payments),
               (SELECT MIN(PaymentDate) FROM dbo.Payments),
               (SELECT MIN(PaymentDate) FROM Archive.Payments)
        UNION ALL
        SELECT 'dbo', 'MedicalRecords',
               (SELECT COUNT(*) FROM dbo.MedicalRecords),
               (SELECT COUNT(*) FROM Archive.MedicalRecords),
               (SELECT MIN(CreatedDate) FROM dbo.MedicalRecords),
               (SELECT MIN(CreatedDate) FROM Archive.MedicalRecords)
        UNION ALL
        SELECT 'dbo', 'Prescriptions',
               (SELECT COUNT(*) FROM dbo.Prescriptions),
               (SELECT COUNT(*) FROM Archive.Prescriptions),
               NULL, NULL
        UNION ALL
        SELECT 'dbo', 'PrescriptionItems',
               (SELECT COUNT(*) FROM dbo.PrescriptionItems),
               (SELECT COUNT(*) FROM Archive.PrescriptionItems),
               NULL, NULL
        UNION ALL
        SELECT 'dbo', 'LabOrders',
               (SELECT COUNT(*) FROM dbo.LabOrders),
               (SELECT COUNT(*) FROM Archive.LabOrders),
               (SELECT MIN(DateRequested) FROM dbo.LabOrders),
               (SELECT MIN(DateRequested) FROM Archive.LabOrders)
        UNION ALL
        SELECT 'dbo', 'AuditLogs',
               (SELECT COUNT(*) FROM dbo.AuditLogs),
               (SELECT COUNT(*) FROM Archive.AuditLogs),
               (SELECT MIN(ActionDate) FROM dbo.AuditLogs),
               (SELECT MIN(ActionDate) FROM Archive.AuditLogs)
        UNION ALL
        SELECT 'dbo', 'ErrorLogs',
               (SELECT COUNT(*) FROM dbo.ErrorLogs),
               (SELECT COUNT(*) FROM Archive.ErrorLogs),
               (SELECT MIN(ErrorDate) FROM dbo.ErrorLogs),
               (SELECT MIN(ErrorDate) FROM Archive.ErrorLogs)
    ) t
    ORDER BY TableName;

    -- Result Set 2: Recent job log entries
    SELECT TOP 20
        LogID,
        JobRunID,
        RunDate,
        CutoffDate,
        Phase,
        ArchiveInserted,
        ActiveDeleted,
        DurationMs,
        WasDryRun,
        CASE WHEN ErrorMessage IS NOT NULL THEN 'FAILED' ELSE 'OK' END AS Result,
        ErrorMessage
    FROM  dbo.RetentionJobLog
    ORDER BY LogID DESC;
END;
GO


-- =============================================================================
-- Sample Executions
-- =============================================================================

-- Preview what the policy would move (no changes made):
-- EXEC dbo.usp_Retention_RunPolicy @DryRun = 1;

-- Run the full policy with default settings (5 years, batch = 500):
-- EXEC dbo.usp_Retention_RunPolicy;

-- Run with a custom cutoff date (e.g. clear data older than 7 years):
-- EXEC dbo.usp_Retention_RunPolicy @CutoffDate = '2019-01-01';

-- Archive only audit logs, larger batch:
-- EXEC dbo.usp_Retention_ArchiveAuditLogs @BatchSize = 5000;

-- Check current active vs. archived counts:
-- EXEC dbo.usp_Retention_GetStats;
GO
