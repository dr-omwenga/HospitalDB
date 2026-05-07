-- =============================================================================
-- HospitalDB — Transaction-Managed Stored Procedures
-- File        : sql/16_transaction_procedures.sql
-- Author      : Hospital Information Systems
-- Date        : 2026-05-07
-- Description :
--   Two stored procedures that demonstrate distinct transaction management
--   patterns supported by SQL Server.  Both procedures enforce business rules,
--   validate all inputs before entering a transaction, and log every failure
--   to dbo.ErrorLogs before re-raising to the caller.
--
--   Procedure 1 — dbo.usp_Appointment_BookAndBill
--   ───────────────────────────────────────────────
--   Pattern    : Single explicit transaction spanning FOUR tables.
--   Technique  : BEGIN TRANSACTION → multi-table INSERT → COMMIT /
--                ROLLBACK on any failure.
--   What it does:
--     Books a new appointment and atomically raises the matching bill with
--     one or more line items in the same transaction.  If any of the four
--     DML operations (Appointments, Bills, BillItems, AuditLogs) fails,
--     the entire unit of work is rolled back so the database never contains
--     a bill without an appointment, or an appointment without a bill.
--   Tables written: Appointments, Bills, BillItems, AuditLogs.
--   Parameters:
--     @PatientID         INT
--     @DoctorID          INT
--     @CreatedByUserID   INT          — staff member booking the slot
--     @AppointmentDate   DATETIME     — must be in the future
--     @Reason            VARCHAR(255) — clinical reason for the visit
--     @BillServicesJSON  NVARCHAR(MAX)— JSON array of services to bill
--                                      e.g. '[{"ServiceID":1,"Quantity":2},
--                                              {"ServiceID":4,"Quantity":1}]'
--     @PerformedByUserID INT          — user recorded in AuditLogs
--
--   Procedure 2 — dbo.usp_ClinicalRecord_CreateWithPrescription
--   ─────────────────────────────────────────────────────────────
--   Pattern    : SAVE TRANSACTION (savepoint) for optional nested work.
--   Technique  : Outer transaction wraps the mandatory medical record write;
--                a savepoint is set before the optional prescription block;
--                if the prescription block fails the inner CATCH rolls back
--                to the savepoint (preserving the medical record commit) and
--                logs a partial-failure warning before the outer transaction
--                commits the record alone.
--   What it does:
--     Creates a MedicalRecord for a Completed appointment, then optionally
--     adds a Prescription with medication items.  If the prescription block
--     fails (e.g., duplicate item, bad data) the medical record is still
--     committed — clinically more important — while the failure is recorded.
--     If the MedicalRecord insert itself fails, the entire transaction rolls
--     back.
--   Tables written: MedicalRecords, Prescriptions, PrescriptionItems,
--                   AuditLogs, ErrorLogs (on partial failure).
--   Parameters:
--     @AppointmentID         INT
--     @Diagnosis             VARCHAR(255)
--     @Notes                 NVARCHAR(MAX)
--     @TreatmentPlan         NVARCHAR(MAX)
--     @PrescriptionItemsJSON NVARCHAR(MAX) = NULL
--                                      JSON array of medication items, e.g.
--                                      '[{"MedicationName":"Amoxicillin",
--                                         "Dosage":"500mg",
--                                         "Frequency":"Three times daily",
--                                         "Duration":"7 days"}]'
--     @PerformedByUserID     INT
--
--   Error handling pattern (identical to sql/15):
--     SET XACT_ABORT ON  (Proc 1) : dooms transaction on unexpected errors.
--     SET XACT_ABORT OFF (Proc 2) : required to allow ROLLBACK TO SAVEPOINT.
--     THROW              : all validation errors use numbered codes 51001–51030.
--     XACT_STATE() check : CATCH block inspects state before rollback.
--     ErrorLogs insert   : every caught error persisted before re-raise.
-- =============================================================================

USE HospitalDB;
GO


-- =============================================================================
-- PROCEDURE 1
-- =============================================================================
-- Name        : dbo.usp_Appointment_BookAndBill
--
-- Transaction pattern:
--   A single explicit BEGIN TRANSACTION covers four sequential INSERT
--   statements across four tables.  All four succeed or none do:
--
--     Step 1  INSERT dbo.Appointments           → @NewAppointmentID
--     Step 2  Compute @TotalAmount from ServiceCatalog + JSON input
--     Step 3  INSERT dbo.Bills                  → @NewBillID
--     Step 4  INSERT dbo.BillItems (one row per service in @BillServicesJSON)
--     Step 5  INSERT dbo.AuditLogs
--     Step 6  COMMIT TRANSACTION
--
--   Any error in steps 1–5 causes the CATCH block to ROLLBACK TRANSACTION,
--   write to ErrorLogs, and re-throw to the caller.  The caller will never
--   observe a partial state (e.g. an Appointment without a Bill, or a Bill
--   with no items).
--
-- @BillServicesJSON format:
--   '[{"ServiceID": <int>, "Quantity": <int>}, ...]'
--   Each ServiceID must exist in dbo.ServiceCatalog.
--   Quantity must be >= 1 for each item.
--   At least one item is required.
--
-- Custom error codes:
--   51001 — @PatientID invalid
--   51002 — @DoctorID invalid
--   51003 — @CreatedByUserID invalid
--   51004 — @AppointmentDate in the past
--   51005 — @Reason blank
--   51006 — @BillServicesJSON blank or NULL
--   51007 — @PerformedByUserID invalid
--   51008 — PatientID not found in dbo.Patients
--   51009 — DoctorID not found in dbo.Doctors
--   51010 — CreatedByUserID not found in dbo.Users
--   51011 — PerformedByUserID not found in dbo.Users
--   51012 — One or more ServiceIDs not found in dbo.ServiceCatalog
--   51013 — JSON parse produced no rows (empty array or malformed)
--   51014 — One or more Quantity values are zero or negative
-- =============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Appointment_BookAndBill
    @PatientID         INT,
    @DoctorID          INT,
    @CreatedByUserID   INT,
    @AppointmentDate   DATETIME,
    @Reason            VARCHAR(255),
    @BillServicesJSON  NVARCHAR(MAX),
    @PerformedByUserID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Working variables
    DECLARE @NewAppointmentID INT;
    DECLARE @NewBillID        INT;
    DECLARE @TotalAmount      DECIMAL(10,2);
    DECLARE @ItemCount        INT;
    DECLARE @BadServices      INT;
    DECLARE @BadQuantities    INT;

    -- Temp table holds the parsed and enriched bill items
    CREATE TABLE #ParsedItems (
        ServiceID  INT           NOT NULL,
        Quantity   INT           NOT NULL,
        UnitPrice  DECIMAL(10,2) NOT NULL,
        LineTotal  DECIMAL(10,2) NOT NULL
    );

    BEGIN TRY

        -- ---------------------------------------------------------------
        -- Guard 1: Scalar parameter validation
        -- ---------------------------------------------------------------
        IF @PatientID IS NULL OR @PatientID <= 0
            THROW 51001, 'Invalid @PatientID: must be a positive integer.', 1;

        IF @DoctorID IS NULL OR @DoctorID <= 0
            THROW 51002, 'Invalid @DoctorID: must be a positive integer.', 1;

        IF @CreatedByUserID IS NULL OR @CreatedByUserID <= 0
            THROW 51003, 'Invalid @CreatedByUserID: must be a positive integer.', 1;

        IF @AppointmentDate IS NULL OR @AppointmentDate <= GETDATE()
            THROW 51004,
                'Invalid @AppointmentDate: the appointment date must be in the future.', 1;

        IF NULLIF(LTRIM(RTRIM(@Reason)), '') IS NULL
            THROW 51005, 'Invalid @Reason: must not be blank or NULL.', 1;

        IF NULLIF(LTRIM(RTRIM(@BillServicesJSON)), '') IS NULL
            THROW 51006,
                'Invalid @BillServicesJSON: must be a non-empty JSON array of service objects.', 1;

        IF @PerformedByUserID IS NULL OR @PerformedByUserID <= 0
            THROW 51007, 'Invalid @PerformedByUserID: must be a positive integer.', 1;

        -- ---------------------------------------------------------------
        -- Guard 2: Referential integrity checks (FK targets must exist)
        -- ---------------------------------------------------------------
        IF NOT EXISTS (SELECT 1 FROM dbo.Patients WHERE PatientID = @PatientID)
            THROW 51008, 'The specified PatientID does not exist in dbo.Patients.', 1;

        IF NOT EXISTS (SELECT 1 FROM dbo.Doctors WHERE DoctorID = @DoctorID)
            THROW 51009, 'The specified DoctorID does not exist in dbo.Doctors.', 1;

        IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE UserID = @CreatedByUserID)
            THROW 51010, 'The specified CreatedByUserID does not exist in dbo.Users.', 1;

        IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE UserID = @PerformedByUserID)
            THROW 51011, 'The specified PerformedByUserID does not exist in dbo.Users.', 1;

        -- ---------------------------------------------------------------
        -- Guard 3: Parse JSON and join to ServiceCatalog to get prices
        -- ---------------------------------------------------------------
        -- OPENJSON reads the array; the JOIN enriches each row with UnitPrice.
        -- Rows where ServiceID has no match in ServiceCatalog are excluded,
        -- which we detect below via @BadServices.
        INSERT INTO #ParsedItems (ServiceID, Quantity, UnitPrice, LineTotal)
        SELECT
            j.ServiceID,
            j.Quantity,
            s.StandardPrice                  AS UnitPrice,
            j.Quantity * s.StandardPrice      AS LineTotal
        FROM OPENJSON(@BillServicesJSON)
        WITH (
            ServiceID  INT '$.ServiceID',
            Quantity   INT '$.Quantity'
        ) AS j
        INNER JOIN dbo.ServiceCatalog s ON s.ServiceID = j.ServiceID;

        SET @ItemCount = @@ROWCOUNT;

        IF @ItemCount = 0
            THROW 51013,
                'The @BillServicesJSON array produced no valid rows.  Verify the JSON format and that at least one ServiceID exists.', 1;

        -- Detect any ServiceIDs that were in the JSON but not in the catalog
        SELECT @BadServices = COUNT(*)
        FROM OPENJSON(@BillServicesJSON)
        WITH (ServiceID INT '$.ServiceID') AS j
        WHERE NOT EXISTS (SELECT 1 FROM dbo.ServiceCatalog s WHERE s.ServiceID = j.ServiceID);

        IF @BadServices > 0
            THROW 51012,
                'One or more ServiceIDs in @BillServicesJSON were not found in dbo.ServiceCatalog.  All ServiceIDs must be valid before the booking can proceed.', 1;

        -- Detect non-positive quantities
        SELECT @BadQuantities = COUNT(*) FROM #ParsedItems WHERE Quantity <= 0;

        IF @BadQuantities > 0
            THROW 51014,
                'One or more Quantity values in @BillServicesJSON are zero or negative.  All quantities must be at least 1.', 1;

        -- Compute the bill total now, before entering the transaction
        SELECT @TotalAmount = SUM(LineTotal) FROM #ParsedItems;

        -- ---------------------------------------------------------------
        -- TRANSACTION: All four writes succeed or none do
        -- ---------------------------------------------------------------
        BEGIN TRANSACTION;

            -- Step 1: Create the appointment
            INSERT INTO dbo.Appointments
                (PatientID, DoctorID, CreatedByUserID, AppointmentDate, Status, Reason)
            VALUES
                (@PatientID, @DoctorID, @CreatedByUserID, @AppointmentDate,
                 'Scheduled',    -- Initial status per Rule 3.2 lifecycle
                 @Reason);

            SET @NewAppointmentID = SCOPE_IDENTITY();

            -- Step 2: Create the bill for the appointment
            -- PaidAmount = 0.00 and Balance = TotalAmount on creation (Rule 6.2)
            INSERT INTO dbo.Bills
                (PatientID, AppointmentID, TotalAmount, PaidAmount, Balance,
                 BillStatus, CreatedDate)
            VALUES
                (@PatientID, @NewAppointmentID, @TotalAmount, 0.00, @TotalAmount,
                 'Unpaid',       -- Initial status per Rule 6.3
                 GETDATE());

            SET @NewBillID = SCOPE_IDENTITY();

            -- Step 3: Insert one BillItem row per service in the JSON array
            INSERT INTO dbo.BillItems (BillID, ServiceID, Quantity, UnitPrice, LineTotal)
            SELECT
                @NewBillID,
                pi.ServiceID,
                pi.Quantity,
                pi.UnitPrice,
                pi.LineTotal
            FROM #ParsedItems pi;

            -- Step 4: Audit trail — records appointment + bill creation in one entry
            INSERT INTO dbo.AuditLogs
                (PerformedByUserID, TableName, ActionType, ActionDate, OldValue, NewValue)
            VALUES (
                @PerformedByUserID,
                'Appointments,Bills,BillItems',
                'INSERT',
                GETDATE(),
                '',   -- no previous state (new records)
                'AppointmentID=' + CAST(@NewAppointmentID AS VARCHAR(10))
                + '; BillID='    + CAST(@NewBillID        AS VARCHAR(10))
                + '; TotalAmount='+ CAST(@TotalAmount     AS VARCHAR(20))
                + '; ItemCount=' + CAST(@ItemCount        AS VARCHAR(10))
            );

        -- All four steps succeeded — commit atomically
        COMMIT TRANSACTION;

        -- ---------------------------------------------------------------
        -- Result set 1: appointment and bill summary
        -- ---------------------------------------------------------------
        SELECT
            a.AppointmentID,
            p.PatientID,
            p.FirstName + ' ' + p.LastName   AS PatientName,
            d.DoctorID,
            d.FirstName + ' ' + d.LastName   AS DoctorName,
            dep.DepartmentName,
            a.AppointmentDate,
            a.Status                         AS AppointmentStatus,
            a.Reason,
            b.BillID,
            b.TotalAmount,
            b.PaidAmount,
            b.Balance,
            b.BillStatus
        FROM  dbo.Appointments a
        INNER JOIN dbo.Patients    p   ON p.PatientID    = a.PatientID
        INNER JOIN dbo.Doctors     d   ON d.DoctorID     = a.DoctorID
        INNER JOIN dbo.Departments dep ON dep.DepartmentID = d.DepartmentID
        INNER JOIN dbo.Bills       b   ON b.AppointmentID = a.AppointmentID
        WHERE a.AppointmentID = @NewAppointmentID;

        -- Result set 2: itemised bill
        SELECT
            bi.BillItemID,
            sc.ServiceName,
            bi.Quantity,
            bi.UnitPrice,
            bi.LineTotal
        FROM  dbo.BillItems    bi
        INNER JOIN dbo.ServiceCatalog sc ON sc.ServiceID = bi.ServiceID
        WHERE bi.BillID = @NewBillID
        ORDER BY bi.BillItemID;

    END TRY
    BEGIN CATCH

        -- Rollback all four steps atomically if anything failed
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        INSERT INTO dbo.ErrorLogs (ProcedureName, ErrorMessage, ErrorDate)
        VALUES (
            ISNULL(ERROR_PROCEDURE(), 'usp_Appointment_BookAndBill'),
            'Error '   + CAST(ERROR_NUMBER() AS VARCHAR(10))
            + ' Line ' + CAST(ERROR_LINE()   AS VARCHAR(10))
            + ': '     + ERROR_MESSAGE(),
            GETDATE()
        );

        THROW;

    END CATCH;
END;
GO


-- =============================================================================
-- PROCEDURE 2
-- =============================================================================
-- Name        : dbo.usp_ClinicalRecord_CreateWithPrescription
--
-- Transaction pattern:
--   SAVE TRANSACTION (savepoint) enables graduated rollback.  The clinical
--   record is the primary, mandatory write; the prescription is secondary
--   and optional.  The two phases are:
--
--     Outer transaction (mandatory phase):
--       BEGIN TRANSACTION
--         Step 1  INSERT dbo.MedicalRecords        → @RecordID
--         SAVE TRANSACTION PrescriptionSavepoint   ← savepoint marker
--
--     Inner TRY/CATCH (optional phase):
--         Step 2  INSERT dbo.Prescriptions         → @PrescriptionID
--         Step 3  INSERT dbo.PrescriptionItems     (one per medication in JSON)
--       ON FAILURE → ROLLBACK TRANSACTION PrescriptionSavepoint
--                    (rolls back Steps 2–3, leaving Step 1 intact)
--
--     Continue outer transaction:
--         Step 4  INSERT dbo.AuditLogs
--       COMMIT TRANSACTION  (Step 1 + Step 4 always committed if no outer error)
--
--   If Step 1 itself fails, the outer CATCH issues a full ROLLBACK and no
--   rows are written.
--
--   Why SET XACT_ABORT OFF here?
--     SET XACT_ABORT ON would doom the transaction on any error, preventing
--     ROLLBACK TRANSACTION PrescriptionSavepoint from working.  By setting it
--     OFF, we retain full control: the outer CATCH explicitly rolls back if
--     needed, and the inner CATCH can roll back to the savepoint safely.
--
-- @PrescriptionItemsJSON format:
--   '[{"MedicationName":"<string>","Dosage":"<string>",
--      "Frequency":"<string>","Duration":"<string>"}, ...]'
--   NULL = no prescription (medical record still created).
--
-- Custom error codes:
--   51020 — @AppointmentID invalid
--   51021 — @PerformedByUserID invalid
--   51022 — @Diagnosis blank
--   51023 — @Notes blank
--   51024 — @TreatmentPlan blank
--   51025 — AppointmentID not found in dbo.Appointments
--   51026 — Appointment is not in Completed status
--   51027 — Medical record already exists for this appointment
--   51028 — PerformedByUserID not found in dbo.Users
-- =============================================================================
CREATE OR ALTER PROCEDURE dbo.usp_ClinicalRecord_CreateWithPrescription
    @AppointmentID         INT,
    @Diagnosis             VARCHAR(255),
    @Notes                 NVARCHAR(MAX),
    @TreatmentPlan         NVARCHAR(MAX),
    @PrescriptionItemsJSON NVARCHAR(MAX) = NULL,
    @PerformedByUserID     INT
AS
BEGIN
    SET NOCOUNT ON;
    -- XACT_ABORT must be OFF to allow ROLLBACK TRANSACTION <savepoint>
    -- after a prescription-level failure without dooming the outer transaction.
    SET XACT_ABORT OFF;

    -- Working variables
    DECLARE @RecordID              INT;
    DECLARE @PrescriptionID        INT;
    DECLARE @AppointmentStatus     VARCHAR(30);
    DECLARE @AppointmentDoctorID   INT;
    DECLARE @PrescriptionCreated   BIT = 0;
    DECLARE @PrescriptionRolledBack BIT = 0;
    DECLARE @PrescItemCount        INT = 0;

    BEGIN TRY

        -- ---------------------------------------------------------------
        -- Guard 1: Scalar parameter validation (before any transaction)
        -- ---------------------------------------------------------------
        IF @AppointmentID IS NULL OR @AppointmentID <= 0
            THROW 51020, 'Invalid @AppointmentID: must be a positive integer.', 1;

        IF @PerformedByUserID IS NULL OR @PerformedByUserID <= 0
            THROW 51021, 'Invalid @PerformedByUserID: must be a positive integer.', 1;

        IF NULLIF(LTRIM(RTRIM(@Diagnosis)), '') IS NULL
            THROW 51022, 'Invalid @Diagnosis: must not be blank or NULL.', 1;

        IF NULLIF(LTRIM(RTRIM(@Notes)), '') IS NULL
            THROW 51023, 'Invalid @Notes: must not be blank or NULL.', 1;

        IF NULLIF(LTRIM(RTRIM(@TreatmentPlan)), '') IS NULL
            THROW 51024, 'Invalid @TreatmentPlan: must not be blank or NULL.', 1;

        -- ---------------------------------------------------------------
        -- Guard 2: Business rule and referential integrity checks
        -- ---------------------------------------------------------------
        SELECT
            @AppointmentStatus   = a.Status,
            @AppointmentDoctorID = a.DoctorID
        FROM dbo.Appointments a
        WHERE a.AppointmentID = @AppointmentID;

        IF @AppointmentStatus IS NULL
            THROW 51025,
                'The specified AppointmentID does not exist in dbo.Appointments.', 1;

        -- Rule 4.1: medical records may only be created for Completed appointments
        IF @AppointmentStatus <> 'Completed'
        BEGIN
            DECLARE @StatusErr NVARCHAR(300) =
                'A medical record can only be created for a Completed appointment.  '
                + 'Current status is ''' + @AppointmentStatus + '''.';
            RAISERROR(@StatusErr, 16, 1) WITH NOWAIT;
            RETURN;
        END;

        -- UQ_MedicalRecords_AppointmentID: pre-check to give a meaningful error
        IF EXISTS (SELECT 1 FROM dbo.MedicalRecords WHERE AppointmentID = @AppointmentID)
            THROW 51027,
                'A medical record already exists for this appointment.  Each appointment may have at most one medical record.', 1;

        IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE UserID = @PerformedByUserID)
            THROW 51028,
                'The specified PerformedByUserID does not exist in dbo.Users.', 1;

        -- ---------------------------------------------------------------
        -- OUTER TRANSACTION — mandatory phase
        -- ---------------------------------------------------------------
        BEGIN TRANSACTION;

            -- Step 1: Insert the medical record (mandatory — must succeed)
            INSERT INTO dbo.MedicalRecords
                (AppointmentID, Diagnosis, Notes, TreatmentPlan, CreatedDate)
            VALUES
                (@AppointmentID, @Diagnosis, @Notes, @TreatmentPlan, GETDATE());

            SET @RecordID = SCOPE_IDENTITY();

            -- ── SAVEPOINT ── separates the mandatory record from the optional
            --                 prescription.  Any failure inside the prescription
            --                 block will roll back only to this point.
            SAVE TRANSACTION PrescriptionSavepoint;

            -- ---------------------------------------------------------------
            -- OPTIONAL PRESCRIPTION PHASE (inner TRY/CATCH)
            -- ---------------------------------------------------------------
            IF @PrescriptionItemsJSON IS NOT NULL
               AND NULLIF(LTRIM(RTRIM(@PrescriptionItemsJSON)), '') IS NOT NULL
            BEGIN
                BEGIN TRY
                    -- Validate JSON format BEFORE starting any prescription DML.
                    -- ISJSON() raises a user THROW (error 51029, not a system error),
                    -- so XACT_STATE stays 1 and the savepoint rollback can proceed.
                    -- System errors from OPENJSON (e.g. 13609) doom the transaction
                    -- (XACT_STATE = -1) and cannot be rolled back to a savepoint,
                    -- so we intercept malformed JSON here before any DML.
                    IF ISJSON(@PrescriptionItemsJSON) = 0
                        THROW 51029,
                            'Prescription items JSON is not valid JSON.  The prescription phase has been rolled back to the savepoint; the medical record will still be committed.', 1;

                    -- Step 2: Prescription header
                    INSERT INTO dbo.Prescriptions
                        (RecordID, DoctorID, PrescriptionDate)
                    VALUES
                        (@RecordID, @AppointmentDoctorID, CAST(GETDATE() AS DATE));

                    SET @PrescriptionID = SCOPE_IDENTITY();

                    -- Step 3: Medication items (one row per element in JSON)
                    INSERT INTO dbo.PrescriptionItems
                        (PrescriptionID, MedicationName, Dosage, Frequency, Duration)
                    SELECT
                        @PrescriptionID,
                        j.MedicationName,
                        j.Dosage,
                        j.Frequency,
                        j.Duration
                    FROM OPENJSON(@PrescriptionItemsJSON)
                    WITH (
                        MedicationName VARCHAR(120) '$.MedicationName',
                        Dosage         VARCHAR(60)  '$.Dosage',
                        Frequency      VARCHAR(60)  '$.Frequency',
                        Duration       VARCHAR(60)  '$.Duration'
                    ) AS j
                    WHERE NULLIF(j.MedicationName, '') IS NOT NULL;  -- skip blank rows

                    SET @PrescItemCount    = @@ROWCOUNT;
                    SET @PrescriptionCreated = 1;

                END TRY
                BEGIN CATCH
                    -- ── ROLLBACK TO SAVEPOINT ── undoes Steps 2–3 only.
                    --    @@TRANCOUNT stays at 1; Step 1 (MedicalRecord) is intact.
                    ROLLBACK TRANSACTION PrescriptionSavepoint;

                    SET @PrescriptionRolledBack = 1;

                    -- Log the partial failure so operations staff can reissue the prescription separately
                    INSERT INTO dbo.ErrorLogs (ProcedureName, ErrorMessage, ErrorDate)
                    VALUES (
                        ISNULL(ERROR_PROCEDURE(), 'usp_ClinicalRecord_CreateWithPrescription'),
                        'PARTIAL FAILURE — Prescription rolled back to savepoint.  '
                        + 'MedicalRecord (RecordID will be committed) was unaffected.  '
                        + 'Error '   + CAST(ERROR_NUMBER() AS VARCHAR(10))
                        + ' Line '   + CAST(ERROR_LINE()   AS VARCHAR(10))
                        + ': '       + ERROR_MESSAGE(),
                        GETDATE()
                    );
                END CATCH;
            END;

            -- ---------------------------------------------------------------
            -- AUDIT LOG — always written regardless of prescription outcome
            -- ---------------------------------------------------------------
            INSERT INTO dbo.AuditLogs
                (PerformedByUserID, TableName, ActionType, ActionDate, OldValue, NewValue)
            VALUES (
                @PerformedByUserID,
                CASE WHEN @PrescriptionCreated = 1
                     THEN 'MedicalRecords,Prescriptions,PrescriptionItems'
                     ELSE 'MedicalRecords'
                END,
                'INSERT',
                GETDATE(),
                '',
                'AppointmentID='  + CAST(@AppointmentID AS VARCHAR(10))
                + '; RecordID='   + CAST(@RecordID      AS VARCHAR(10))
                + '; Diagnosis='  + @Diagnosis
                + CASE WHEN @PrescriptionCreated  = 1
                       THEN '; PrescriptionID=' + CAST(@PrescriptionID AS VARCHAR(10))
                            + '; MedItems='    + CAST(@PrescItemCount  AS VARCHAR(10))
                       WHEN @PrescriptionRolledBack = 1
                       THEN '; PrescriptionRolledBack=1'
                       ELSE ''
                  END
            );

        -- Commit Step 1 (+ Step 2/3 if prescription succeeded) + Step 4 atomically
        COMMIT TRANSACTION;

        -- ---------------------------------------------------------------
        -- Result set 1: medical record
        -- ---------------------------------------------------------------
        SELECT
            mr.RecordID,
            a.AppointmentID,
            p.PatientID,
            p.FirstName + ' ' + p.LastName       AS PatientName,
            d.DoctorID,
            d.FirstName + ' ' + d.LastName       AS DoctorName,
            mr.Diagnosis,
            LEFT(mr.Notes, 120)                  AS Notes,
            LEFT(mr.TreatmentPlan, 120)          AS TreatmentPlan,
            mr.CreatedDate
        FROM  dbo.MedicalRecords mr
        INNER JOIN dbo.Appointments a   ON a.AppointmentID = mr.AppointmentID
        INNER JOIN dbo.Patients     p   ON p.PatientID     = a.PatientID
        INNER JOIN dbo.Doctors      d   ON d.DoctorID      = a.DoctorID
        WHERE mr.RecordID = @RecordID;

        -- Result set 2: prescription and items (empty if not created or rolled back)
        SELECT
            pr.PrescriptionID,
            pr.PrescriptionDate,
            pi.PrescriptionItemID,
            pi.MedicationName,
            pi.Dosage,
            pi.Frequency,
            pi.Duration
        FROM  dbo.Prescriptions     pr
        INNER JOIN dbo.PrescriptionItems pi ON pi.PrescriptionID = pr.PrescriptionID
        WHERE pr.RecordID = @RecordID
        ORDER BY pi.PrescriptionItemID;

        -- Result set 3: transaction summary
        SELECT
            @RecordID                                   AS RecordID,
            CASE WHEN @PrescriptionCreated   = 1 THEN @PrescriptionID ELSE NULL END
                                                        AS PrescriptionID,
            @PrescItemCount                             AS PrescriptionItemsInserted,
            CASE WHEN @PrescriptionCreated   = 1 THEN 'Committed'
                 WHEN @PrescriptionRolledBack = 1 THEN 'Rolled back to savepoint'
                 ELSE                                  'Not requested (NULL input)'
            END                                        AS PrescriptionOutcome,
            GETDATE()                                   AS CommittedAt;

    END TRY
    BEGIN CATCH

        -- Full rollback if the outer (mandatory) block failed
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        INSERT INTO dbo.ErrorLogs (ProcedureName, ErrorMessage, ErrorDate)
        VALUES (
            ISNULL(ERROR_PROCEDURE(), 'usp_ClinicalRecord_CreateWithPrescription'),
            'FULL ROLLBACK.  Error '
            + CAST(ERROR_NUMBER() AS VARCHAR(10))
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

SET XACT_ABORT OFF;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Resolve live IDs for use across tests
-- ─────────────────────────────────────────────────────────────────────────────
SELECT TOP 1 PatientID      AS SamplePatientID   FROM dbo.Patients ORDER BY PatientID;
SELECT TOP 1 DoctorID       AS SampleDoctorID    FROM dbo.Doctors  ORDER BY DoctorID;
SELECT TOP 1 UserID         AS SampleUserID      FROM dbo.Users    WHERE IsActive = 1 ORDER BY UserID;
SELECT TOP 3 ServiceID, ServiceName, StandardPrice FROM dbo.ServiceCatalog ORDER BY ServiceID;
SELECT TOP 5 AppointmentID, Status FROM dbo.Appointments WHERE Status = 'Completed' ORDER BY AppointmentID;
GO


-- =============================================================================
-- TEST GROUP A — usp_Appointment_BookAndBill
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- Test A.1  Valid booking: 2 services in JSON array
-- Expected : Appointment and Bill created atomically; RS1 shows new AppointmentID
--            and BillID; RS2 shows two BillItem rows; Bills.BillStatus = 'Unpaid'.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @Pat  INT = (SELECT MIN(PatientID) FROM dbo.Patients);
DECLARE @Doc  INT = (SELECT MIN(DoctorID)  FROM dbo.Doctors);
DECLARE @Usr  INT = (SELECT MIN(UserID)    FROM dbo.Users WHERE IsActive = 1);
DECLARE @Svc1 INT = (SELECT MIN(ServiceID) FROM dbo.ServiceCatalog);
DECLARE @Svc2 INT = (SELECT MIN(ServiceID) FROM dbo.ServiceCatalog WHERE ServiceID > @Svc1);

DECLARE @ServicesJSON NVARCHAR(MAX) =
    '[{"ServiceID":' + CAST(@Svc1 AS VARCHAR) + ',"Quantity":1},'
    + '{"ServiceID":'+ CAST(@Svc2 AS VARCHAR) + ',"Quantity":2}]';

PRINT 'Test A.1 — Valid booking with 2 services  Expected: Appointment + Bill created';
EXEC dbo.usp_Appointment_BookAndBill
    @PatientID         = @Pat,
    @DoctorID          = @Doc,
    @CreatedByUserID   = @Usr,
    @AppointmentDate   = DATEADD(DAY, 7, GETDATE()),
    @Reason            = 'Routine annual check-up and blood work review.',
    @BillServicesJSON  = @ServicesJSON,
    @PerformedByUserID = @Usr;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test A.2  Valid booking: 1 service, 3 units
-- Expected : Single BillItem row; TotalAmount = StandardPrice * 3.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @Pat2 INT = (SELECT MIN(PatientID) + 1 FROM dbo.Patients);
DECLARE @Doc2 INT = (SELECT MIN(DoctorID)  FROM dbo.Doctors);
DECLARE @Usr2 INT = (SELECT MIN(UserID)    FROM dbo.Users WHERE IsActive = 1);
DECLARE @SvcA INT = (SELECT MIN(ServiceID) FROM dbo.ServiceCatalog);

PRINT 'Test A.2 — Single service, 3 units  Expected: BillItems = 1 row, TotalAmount = Price*3';
EXEC dbo.usp_Appointment_BookAndBill
    @PatientID         = @Pat2,
    @DoctorID          = @Doc2,
    @CreatedByUserID   = @Usr2,
    @AppointmentDate   = DATEADD(DAY, 14, GETDATE()),
    @Reason            = 'Follow-up consultation post-discharge.',
    @BillServicesJSON  = '[{"ServiceID":' + CAST(@SvcA AS VARCHAR) + ',"Quantity":3}]',
    @PerformedByUserID = @Usr2;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test A.3  ERROR — Appointment date in the past
-- Expected  : Error 51004 'appointment date must be in the future'.
--             No rows written to any table (full rollback not needed — error
--             fires before transaction opens).
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @Pat3 INT = (SELECT MIN(PatientID) FROM dbo.Patients);
DECLARE @Doc3 INT = (SELECT MIN(DoctorID)  FROM dbo.Doctors);
DECLARE @Usr3 INT = (SELECT MIN(UserID)    FROM dbo.Users WHERE IsActive = 1);
DECLARE @Svc3 INT = (SELECT MIN(ServiceID) FROM dbo.ServiceCatalog);

PRINT 'Test A.3 — Past appointment date  Expected: Error 51004';
BEGIN TRY
    EXEC dbo.usp_Appointment_BookAndBill
        @PatientID         = @Pat3,
        @DoctorID          = @Doc3,
        @CreatedByUserID   = @Usr3,
        @AppointmentDate   = DATEADD(DAY, -1, GETDATE()),  -- yesterday
        @Reason            = 'Should not be booked.',
        @BillServicesJSON  = '[{"ServiceID":' + CAST(@Svc3 AS VARCHAR) + ',"Quantity":1}]',
        @PerformedByUserID = @Usr3;
END TRY
BEGIN CATCH
    SELECT 'Test A.3' AS Test, ERROR_NUMBER() AS ErrNum, LEFT(ERROR_MESSAGE(),100) AS ErrMsg;
END CATCH;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test A.4  ERROR — Non-existent ServiceID in JSON (transaction rollback path)
-- Expected  : Error 51012 'ServiceIDs not found in dbo.ServiceCatalog'.
--             Appointment and Bill must NOT exist in the DB.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @Pat4 INT = (SELECT MIN(PatientID) FROM dbo.Patients);
DECLARE @Doc4 INT = (SELECT MIN(DoctorID)  FROM dbo.Doctors);
DECLARE @Usr4 INT = (SELECT MIN(UserID)    FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test A.4 — Invalid ServiceID in JSON  Expected: Error 51012';
BEGIN TRY
    EXEC dbo.usp_Appointment_BookAndBill
        @PatientID         = @Pat4,
        @DoctorID          = @Doc4,
        @CreatedByUserID   = @Usr4,
        @AppointmentDate   = DATEADD(DAY, 5, GETDATE()),
        @Reason            = 'Test bad service ID.',
        @BillServicesJSON  = '[{"ServiceID":999999,"Quantity":1}]',
        @PerformedByUserID = @Usr4;
END TRY
BEGIN CATCH
    SELECT 'Test A.4' AS Test, ERROR_NUMBER() AS ErrNum, LEFT(ERROR_MESSAGE(),120) AS ErrMsg;
END CATCH;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test A.5  ERROR — Non-existent PatientID
-- Expected  : Error 51008 'PatientID does not exist'.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @Doc5 INT = (SELECT MIN(DoctorID)  FROM dbo.Doctors);
DECLARE @Usr5 INT = (SELECT MIN(UserID)    FROM dbo.Users WHERE IsActive = 1);
DECLARE @Svc5 INT = (SELECT MIN(ServiceID) FROM dbo.ServiceCatalog);

PRINT 'Test A.5 — Non-existent PatientID  Expected: Error 51008';
BEGIN TRY
    EXEC dbo.usp_Appointment_BookAndBill
        @PatientID         = 999999,
        @DoctorID          = @Doc5,
        @CreatedByUserID   = @Usr5,
        @AppointmentDate   = DATEADD(DAY, 3, GETDATE()),
        @Reason            = 'Test bad patient.',
        @BillServicesJSON  = '[{"ServiceID":' + CAST(@Svc5 AS VARCHAR) + ',"Quantity":1}]',
        @PerformedByUserID = @Usr5;
END TRY
BEGIN CATCH
    SELECT 'Test A.5' AS Test, ERROR_NUMBER() AS ErrNum, LEFT(ERROR_MESSAGE(),100) AS ErrMsg;
END CATCH;
GO

-- Confirm Tests A.3–A.5 wrote nothing to Appointments or Bills
PRINT 'Test A.x — Verify no orphaned rows from failed tests';
SELECT COUNT(*) AS NewAppointmentsFromErrorTests
FROM dbo.Appointments
WHERE Reason IN ('Should not be booked.', 'Test bad service ID.', 'Test bad patient.');
GO


-- =============================================================================
-- TEST GROUP B — usp_ClinicalRecord_CreateWithPrescription
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- Test B.1  Valid: medical record + prescription committed together
-- Expected  : RS1 shows RecordID; RS2 shows prescription items;
--             RS3 PrescriptionOutcome = 'Committed'.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @CompAppt INT = (
    SELECT MIN(a.AppointmentID)
    FROM   dbo.Appointments a
    WHERE  a.Status = 'Completed'
      AND  NOT EXISTS (SELECT 1 FROM dbo.MedicalRecords mr WHERE mr.AppointmentID = a.AppointmentID)
);
DECLARE @UB1 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

IF @CompAppt IS NULL
    SELECT 'Test B.1 SKIPPED' AS Note, 'No Completed appointment without a medical record' AS Reason;
ELSE
BEGIN
    PRINT 'Test B.1 — Medical record + prescription  Expected: both committed; PrescriptionOutcome=Committed';
    EXEC dbo.usp_ClinicalRecord_CreateWithPrescription
        @AppointmentID         = @CompAppt,
        @Diagnosis             = 'Seasonal allergic rhinitis; mild to moderate severity.',
        @Notes                 = 'Patient presents with nasal congestion, sneezing and watery eyes for 2 weeks.  No fever.  Lungs clear.',
        @TreatmentPlan         = 'Prescribe antihistamine.  Follow-up in 4 weeks if no improvement.  Avoid identified allergens.',
        @PrescriptionItemsJSON = '[{"MedicationName":"Cetirizine","Dosage":"10mg","Frequency":"Once daily","Duration":"30 days"},
                                    {"MedicationName":"Fluticasone Nasal Spray","Dosage":"50mcg per nostril","Frequency":"Once daily","Duration":"30 days"}]',
        @PerformedByUserID     = @UB1;
END;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test B.2  Savepoint rollback: medical record committed, prescription rolled back
-- Triggers  : prescription JSON contains a MedicationName that is intentionally
--             too long (>120 chars) to force a string truncation error inside
--             the prescription phase, exercising the ROLLBACK TO SAVEPOINT path.
-- Expected  : RS1 shows RecordID; RS2 empty (no prescription items);
--             RS3 PrescriptionOutcome = 'Rolled back to savepoint';
--             ErrorLogs contains a PARTIAL FAILURE row for this procedure.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @CompAppt2 INT = (
    SELECT MIN(a.AppointmentID)
    FROM   dbo.Appointments a
    WHERE  a.Status = 'Completed'
      AND  NOT EXISTS (SELECT 1 FROM dbo.MedicalRecords mr WHERE mr.AppointmentID = a.AppointmentID)
);
DECLARE @UB2 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

IF @CompAppt2 IS NULL
    SELECT 'Test B.2 SKIPPED' AS Note, 'No remaining Completed appointment without a record' AS Reason;
ELSE
BEGIN
    PRINT 'Test B.2 — Savepoint rollback: MedRecord committed, prescription fails  Expected: PrescriptionOutcome=Rolled back to savepoint';
    EXEC dbo.usp_ClinicalRecord_CreateWithPrescription
        @AppointmentID         = @CompAppt2,
        @Diagnosis             = 'Upper respiratory tract infection — viral aetiology.',
        @Notes                 = 'Patient has persistent cough, mild fever (38.1 C), and sore throat for 5 days.  Throat swab negative for Group A Streptococcus.',
        @TreatmentPlan         = 'Supportive care: rest, fluids, paracetamol for fever.  Review in 7 days if not improving.',
        -- Deliberately provide a MedicationName that exceeds the 120-char column limit
        -- to force an error inside the prescription block → savepoint rollback
        @PrescriptionItemsJSON = '[{"MedicationName":"' + REPLICATE('X',130) + '","Dosage":"500mg","Frequency":"Twice daily","Duration":"5 days"}]',
        @PerformedByUserID     = @UB2;
END;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test B.3  Valid: medical record only (NULL prescription) — no savepoint needed
-- Expected  : RS1 shows RecordID; RS2 empty; RS3 PrescriptionOutcome = 'Not requested'.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @CompAppt3 INT = (
    SELECT MIN(a.AppointmentID)
    FROM   dbo.Appointments a
    WHERE  a.Status = 'Completed'
      AND  NOT EXISTS (SELECT 1 FROM dbo.MedicalRecords mr WHERE mr.AppointmentID = a.AppointmentID)
);
DECLARE @UB3 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

IF @CompAppt3 IS NULL
    SELECT 'Test B.3 SKIPPED' AS Note, 'No remaining Completed appointment without a record' AS Reason;
ELSE
BEGIN
    PRINT 'Test B.3 — Medical record only (no prescription)  Expected: RS2 empty, PrescriptionOutcome=Not requested';
    EXEC dbo.usp_ClinicalRecord_CreateWithPrescription
        @AppointmentID         = @CompAppt3,
        @Diagnosis             = 'Hypertension — under control with current medication.',
        @Notes                 = 'Blood pressure 132/84 mmHg.  Medication review satisfactory.  Patient reports no side effects.',
        @TreatmentPlan         = 'Continue current antihypertensive regimen.  Dietary advice given.  Annual review scheduled.',
        @PrescriptionItemsJSON = NULL,
        @PerformedByUserID     = @UB3;
END;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test B.4  ERROR — Appointment not Completed (full rollback path)
-- Expected  : Error raised before transaction opens; DB unchanged.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @SchedAppt INT = (SELECT MIN(AppointmentID) FROM dbo.Appointments WHERE Status = 'Scheduled');
DECLARE @UB4 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test B.4 — Non-Completed appointment  Expected: RAISERROR before transaction';
BEGIN TRY
    EXEC dbo.usp_ClinicalRecord_CreateWithPrescription
        @AppointmentID         = @SchedAppt,
        @Diagnosis             = 'Should not be created.',
        @Notes                 = 'N/A',
        @TreatmentPlan         = 'N/A',
        @PerformedByUserID     = @UB4;
END TRY
BEGIN CATCH
    SELECT 'Test B.4' AS Test, ERROR_NUMBER() AS ErrNum, LEFT(ERROR_MESSAGE(),100) AS ErrMsg;
END CATCH;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Test B.5  ERROR — Duplicate medical record (full rollback path)
-- Expected  : Error 51027 'medical record already exists'.
-- ─────────────────────────────────────────────────────────────────────────────
DECLARE @ApptWithRecord INT = (SELECT MIN(AppointmentID) FROM dbo.MedicalRecords);
DECLARE @UB5 INT = (SELECT MIN(UserID) FROM dbo.Users WHERE IsActive = 1);

PRINT 'Test B.5 — Duplicate medical record attempt  Expected: Error 51027';
BEGIN TRY
    EXEC dbo.usp_ClinicalRecord_CreateWithPrescription
        @AppointmentID         = @ApptWithRecord,
        @Diagnosis             = 'Duplicate test.',
        @Notes                 = 'Should fail.',
        @TreatmentPlan         = 'N/A',
        @PerformedByUserID     = @UB5;
END TRY
BEGIN CATCH
    SELECT 'Test B.5' AS Test, ERROR_NUMBER() AS ErrNum, LEFT(ERROR_MESSAGE(),100) AS ErrMsg;
END CATCH;
GO

-- ─────────────────────────────────────────────────────────────────────────────
-- Final verification queries
-- ─────────────────────────────────────────────────────────────────────────────
-- Confirm savepoint test wrote the medical record but not the prescription
PRINT 'Final — Verify savepoint test: MedicalRecord rows with/without Prescription';
SELECT
    mr.RecordID,
    mr.AppointmentID,
    LEFT(mr.Diagnosis, 60) AS Diagnosis,
    CASE WHEN pr.PrescriptionID IS NULL THEN 'No prescription' ELSE 'Has prescription' END AS PrescriptionPresent
FROM dbo.MedicalRecords mr
LEFT JOIN dbo.Prescriptions pr ON pr.RecordID = mr.RecordID
ORDER BY mr.RecordID DESC;

PRINT 'Final — ErrorLogs: PARTIAL FAILURE entries from savepoint rollback';
SELECT TOP 5 ErrorID, ProcedureName, LEFT(ErrorMessage, 120) AS ErrorMessage, ErrorDate
FROM dbo.ErrorLogs
WHERE ErrorMessage LIKE '%PARTIAL FAILURE%'
ORDER BY ErrorDate DESC;

PRINT 'Final — AuditLogs: last 8 entries from both procedure groups';
SELECT TOP 8
    AuditID, TableName, ActionType, ActionDate,
    LEFT(NewValue, 80) AS NewValue
FROM dbo.AuditLogs
ORDER BY ActionDate DESC;
GO
