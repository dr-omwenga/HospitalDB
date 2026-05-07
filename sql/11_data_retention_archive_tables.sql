-- =============================================================================
-- HospitalDB — Data Retention: Archive Schema and Tables
-- File        : sql/11_data_retention_archive_tables.sql
-- Author      : Hospital Information Systems
-- Date        : 2026-05-07
-- Description :
--   Creates the Archive schema, the operational RetentionJobLog tracking
--   table, and one archive table for each active table that participates in
--   the 5-year data retention policy.
--
--   Design rules for all archive tables:
--     • Original PK values are preserved (no IDENTITY — IDs are inserted).
--     • No foreign-key constraints — archive tables are cold storage;
--       referential links are retained as data values only.
--     • Two metadata columns are added to every archive table:
--         ArchivedDate    DATETIME         — when the row was moved
--         ArchiveBatchID  UNIQUEIDENTIFIER — groups all rows moved in the
--                                           same stored-procedure invocation
--     • Each table has a PK on the original ID column for uniqueness and
--       targeted lookup.
--     • Each CREATE TABLE and CREATE INDEX is guarded so this script is
--       safe to re-run without error.
--
--   Tables participating in the retention policy:
--     Appointment chain  : Appointments, Bills, BillItems, Payments,
--                          MedicalRecords, Prescriptions, PrescriptionItems,
--                          LabOrders
--     Standalone logs    : AuditLogs, ErrorLogs
--
--   Tables NOT archived (master / reference data):
--     Patients, Doctors, Users, Roles, Departments, Addresses,
--     InsuranceProviders, PatientInsurancePolicies, EmergencyContacts,
--     ServiceCatalog, LabTestCatalog
--
--   Run order: must be executed BEFORE sql/12_data_retention_procedures.sql
-- =============================================================================

USE HospitalDB;
GO

-- =============================================================================
-- Archive Schema
-- =============================================================================
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'Archive')
    EXEC('CREATE SCHEMA Archive AUTHORIZATION dbo;');
GO

-- =============================================================================
-- RetentionJobLog
-- Tracks every execution of usp_Retention_RunPolicy.  One row is written per
-- phase (AppointmentChain, AuditLogs, ErrorLogs) per job run.
-- =============================================================================
IF OBJECT_ID('dbo.RetentionJobLog', 'U') IS NULL
CREATE TABLE dbo.RetentionJobLog (
    LogID            INT              NOT NULL IDENTITY(1,1),
    JobRunID         UNIQUEIDENTIFIER NOT NULL,
    RunDate          DATETIME         NOT NULL DEFAULT GETDATE(),
    CutoffDate       DATE             NOT NULL,
    Phase            VARCHAR(60)      NOT NULL,  -- 'AppointmentChain' | 'AuditLogs' | 'ErrorLogs'
    ArchiveInserted  INT              NOT NULL DEFAULT 0,
    ActiveDeleted    INT              NOT NULL DEFAULT 0,
    DurationMs       INT                  NULL,
    WasDryRun        BIT              NOT NULL DEFAULT 0,
    ErrorMessage     NVARCHAR(MAX)        NULL,
    CONSTRAINT PK_RetentionJobLog PRIMARY KEY (LogID)
);
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.RetentionJobLog')
      AND  name      = 'IX_RetentionJobLog_RunDate'
)
    CREATE NONCLUSTERED INDEX IX_RetentionJobLog_RunDate
        ON dbo.RetentionJobLog (RunDate DESC)
        INCLUDE (JobRunID, Phase, ArchiveInserted, WasDryRun);
GO

-- =============================================================================
-- Archive Tables — Appointment Chain
-- =============================================================================

-- Appointments
IF OBJECT_ID('Archive.Appointments', 'U') IS NULL
CREATE TABLE Archive.Appointments (
    AppointmentID   INT              NOT NULL,
    PatientID       INT              NOT NULL,
    DoctorID        INT              NOT NULL,
    CreatedByUserID INT              NOT NULL,
    AppointmentDate DATETIME         NOT NULL,
    Status          VARCHAR(30)      NOT NULL,
    Reason          VARCHAR(255)     NOT NULL,
    ArchivedDate    DATETIME         NOT NULL DEFAULT GETDATE(),
    ArchiveBatchID  UNIQUEIDENTIFIER NOT NULL,
    CONSTRAINT PK_Archive_Appointments PRIMARY KEY (AppointmentID)
);
GO

-- Bills
IF OBJECT_ID('Archive.Bills', 'U') IS NULL
CREATE TABLE Archive.Bills (
    BillID          INT              NOT NULL,
    PatientID       INT              NOT NULL,
    AppointmentID   INT              NOT NULL,
    TotalAmount     DECIMAL(10,2)    NOT NULL,
    PaidAmount      DECIMAL(10,2)    NOT NULL,
    Balance         DECIMAL(10,2)    NOT NULL,
    BillStatus      VARCHAR(30)      NOT NULL,
    CreatedDate     DATETIME         NOT NULL,
    ArchivedDate    DATETIME         NOT NULL DEFAULT GETDATE(),
    ArchiveBatchID  UNIQUEIDENTIFIER NOT NULL,
    CONSTRAINT PK_Archive_Bills PRIMARY KEY (BillID)
);
GO

-- BillItems
IF OBJECT_ID('Archive.BillItems', 'U') IS NULL
CREATE TABLE Archive.BillItems (
    BillItemID      INT              NOT NULL,
    BillID          INT              NOT NULL,
    ServiceID       INT              NOT NULL,
    Quantity        INT              NOT NULL,
    UnitPrice       DECIMAL(10,2)    NOT NULL,
    LineTotal       DECIMAL(10,2)    NOT NULL,
    ArchivedDate    DATETIME         NOT NULL DEFAULT GETDATE(),
    ArchiveBatchID  UNIQUEIDENTIFIER NOT NULL,
    CONSTRAINT PK_Archive_BillItems PRIMARY KEY (BillItemID)
);
GO

-- Payments
IF OBJECT_ID('Archive.Payments', 'U') IS NULL
CREATE TABLE Archive.Payments (
    PaymentID       INT              NOT NULL,
    BillID          INT              NOT NULL,
    PaymentDate     DATETIME         NOT NULL,
    Amount          DECIMAL(10,2)    NOT NULL,
    PaymentMethod   VARCHAR(40)      NOT NULL,
    ReferenceNumber VARCHAR(80)      NOT NULL,
    ArchivedDate    DATETIME         NOT NULL DEFAULT GETDATE(),
    ArchiveBatchID  UNIQUEIDENTIFIER NOT NULL,
    CONSTRAINT PK_Archive_Payments PRIMARY KEY (PaymentID)
);
GO

-- MedicalRecords
IF OBJECT_ID('Archive.MedicalRecords', 'U') IS NULL
CREATE TABLE Archive.MedicalRecords (
    RecordID        INT              NOT NULL,
    AppointmentID   INT              NOT NULL,
    Diagnosis       VARCHAR(255)     NOT NULL,
    Notes           NVARCHAR(MAX)    NOT NULL,
    TreatmentPlan   NVARCHAR(MAX)    NOT NULL,
    CreatedDate     DATETIME         NOT NULL,
    ArchivedDate    DATETIME         NOT NULL DEFAULT GETDATE(),
    ArchiveBatchID  UNIQUEIDENTIFIER NOT NULL,
    CONSTRAINT PK_Archive_MedicalRecords PRIMARY KEY (RecordID)
);
GO

-- Prescriptions
IF OBJECT_ID('Archive.Prescriptions', 'U') IS NULL
CREATE TABLE Archive.Prescriptions (
    PrescriptionID   INT              NOT NULL,
    RecordID         INT              NOT NULL,
    DoctorID         INT              NOT NULL,
    PrescriptionDate DATE             NOT NULL,
    ArchivedDate     DATETIME         NOT NULL DEFAULT GETDATE(),
    ArchiveBatchID   UNIQUEIDENTIFIER NOT NULL,
    CONSTRAINT PK_Archive_Prescriptions PRIMARY KEY (PrescriptionID)
);
GO

-- PrescriptionItems
IF OBJECT_ID('Archive.PrescriptionItems', 'U') IS NULL
CREATE TABLE Archive.PrescriptionItems (
    PrescriptionItemID INT              NOT NULL,
    PrescriptionID     INT              NOT NULL,
    MedicationName     VARCHAR(120)     NOT NULL,
    Dosage             VARCHAR(60)      NOT NULL,
    Frequency          VARCHAR(60)      NOT NULL,
    Duration           VARCHAR(60)      NOT NULL,
    ArchivedDate       DATETIME         NOT NULL DEFAULT GETDATE(),
    ArchiveBatchID     UNIQUEIDENTIFIER NOT NULL,
    CONSTRAINT PK_Archive_PrescriptionItems PRIMARY KEY (PrescriptionItemID)
);
GO

-- LabOrders
IF OBJECT_ID('Archive.LabOrders', 'U') IS NULL
CREATE TABLE Archive.LabOrders (
    LabOrderID      INT              NOT NULL,
    AppointmentID   INT              NOT NULL,
    LabTestTypeID   INT              NOT NULL,
    Result          NVARCHAR(MAX)        NULL,
    Status          VARCHAR(30)      NOT NULL,
    DateRequested   DATETIME         NOT NULL,
    ArchivedDate    DATETIME         NOT NULL DEFAULT GETDATE(),
    ArchiveBatchID  UNIQUEIDENTIFIER NOT NULL,
    CONSTRAINT PK_Archive_LabOrders PRIMARY KEY (LabOrderID)
);
GO

-- =============================================================================
-- Archive Tables — Standalone Logs
-- =============================================================================

-- AuditLogs
IF OBJECT_ID('Archive.AuditLogs', 'U') IS NULL
CREATE TABLE Archive.AuditLogs (
    AuditID           INT              NOT NULL,
    PerformedByUserID INT              NOT NULL,
    TableName         VARCHAR(80)      NOT NULL,
    ActionType        VARCHAR(20)      NOT NULL,
    ActionDate        DATETIME         NOT NULL,
    OldValue          NVARCHAR(MAX)    NOT NULL,
    NewValue          NVARCHAR(MAX)    NOT NULL,
    ArchivedDate      DATETIME         NOT NULL DEFAULT GETDATE(),
    ArchiveBatchID    UNIQUEIDENTIFIER NOT NULL,
    CONSTRAINT PK_Archive_AuditLogs PRIMARY KEY (AuditID)
);
GO

-- ErrorLogs
IF OBJECT_ID('Archive.ErrorLogs', 'U') IS NULL
CREATE TABLE Archive.ErrorLogs (
    ErrorID        INT              NOT NULL,
    ProcedureName  VARCHAR(120)     NOT NULL,
    ErrorMessage   NVARCHAR(MAX)    NOT NULL,
    ErrorDate      DATETIME         NOT NULL,
    ArchivedDate   DATETIME         NOT NULL DEFAULT GETDATE(),
    ArchiveBatchID UNIQUEIDENTIFIER NOT NULL,
    CONSTRAINT PK_Archive_ErrorLogs PRIMARY KEY (ErrorID)
);
GO

-- =============================================================================
-- Indexes on Archive Tables
-- Support compliance queries and historical lookups against cold storage.
-- =============================================================================

-- Appointments: patient history lookup and date-range queries
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('Archive.Appointments') AND name = 'IX_ArchAppts_PatientID')
    CREATE NONCLUSTERED INDEX IX_ArchAppts_PatientID
        ON Archive.Appointments (PatientID)
        INCLUDE (AppointmentDate, Status);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('Archive.Appointments') AND name = 'IX_ArchAppts_AppointmentDate')
    CREATE NONCLUSTERED INDEX IX_ArchAppts_AppointmentDate
        ON Archive.Appointments (AppointmentDate);
GO

-- Bills: patient financial history lookup
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('Archive.Bills') AND name = 'IX_ArchBills_PatientID')
    CREATE NONCLUSTERED INDEX IX_ArchBills_PatientID
        ON Archive.Bills (PatientID)
        INCLUDE (TotalAmount, PaidAmount, BillStatus, CreatedDate);
GO

-- AuditLogs: compliance date-range and user queries
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('Archive.AuditLogs') AND name = 'IX_ArchAudit_ActionDate')
    CREATE NONCLUSTERED INDEX IX_ArchAudit_ActionDate
        ON Archive.AuditLogs (ActionDate)
        INCLUDE (PerformedByUserID, TableName, ActionType);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('Archive.AuditLogs') AND name = 'IX_ArchAudit_UserID')
    CREATE NONCLUSTERED INDEX IX_ArchAudit_UserID
        ON Archive.AuditLogs (PerformedByUserID)
        INCLUDE (ActionDate, TableName, ActionType);
GO

-- ArchiveBatchID: supports batch-level investigations and potential rollbacks
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('Archive.Appointments') AND name = 'IX_ArchAppts_BatchID')
    CREATE NONCLUSTERED INDEX IX_ArchAppts_BatchID
        ON Archive.Appointments (ArchiveBatchID);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('Archive.AuditLogs') AND name = 'IX_ArchAudit_BatchID')
    CREATE NONCLUSTERED INDEX IX_ArchAudit_BatchID
        ON Archive.AuditLogs (ArchiveBatchID);
GO
