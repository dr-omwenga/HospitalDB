-- ============================================================
-- Script  : 02_create_tables.sql
-- Purpose : Create all 21 tables for HospitalDB
-- Date    : 2026-05-07
-- Order   : Dependency-safe (referenced tables created first)
-- ============================================================

USE HospitalDB;
GO

-- ============================================================
-- Lookup / Reference Tables (no foreign key dependencies)
-- ============================================================

CREATE TABLE dbo.Roles (
    RoleID   INT         NOT NULL IDENTITY(1,1),
    RoleName VARCHAR(50) NOT NULL,
    CONSTRAINT PK_Roles          PRIMARY KEY (RoleID),
    CONSTRAINT UQ_Roles_RoleName UNIQUE      (RoleName)
);
GO

CREATE TABLE dbo.Addresses (
    AddressID  INT          NOT NULL IDENTITY(1,1),
    Street     VARCHAR(120) NOT NULL,
    City       VARCHAR(60)  NOT NULL,
    State      VARCHAR(60)  NOT NULL,
    PostalCode VARCHAR(20)  NOT NULL,
    Country    VARCHAR(60)  NOT NULL,
    CONSTRAINT PK_Addresses PRIMARY KEY (AddressID)
);
GO

CREATE TABLE dbo.InsuranceProviders (
    InsuranceProviderID INT          NOT NULL IDENTITY(1,1),
    ProviderName        VARCHAR(100) NOT NULL,
    Phone               VARCHAR(25)  NOT NULL,
    Email               VARCHAR(120) NOT NULL,
    CONSTRAINT PK_InsuranceProviders PRIMARY KEY (InsuranceProviderID)
);
GO

CREATE TABLE dbo.LabTestCatalog (
    LabTestTypeID INT           NOT NULL IDENTITY(1,1),
    TestName      VARCHAR(120)  NOT NULL,
    StandardPrice DECIMAL(10,2) NOT NULL,
    CONSTRAINT PK_LabTestCatalog          PRIMARY KEY (LabTestTypeID),
    CONSTRAINT UQ_LabTestCatalog_TestName UNIQUE      (TestName)
);
GO

CREATE TABLE dbo.ServiceCatalog (
    ServiceID     INT           NOT NULL IDENTITY(1,1),
    ServiceName   VARCHAR(120)  NOT NULL,
    StandardPrice DECIMAL(10,2) NOT NULL,
    CONSTRAINT PK_ServiceCatalog PRIMARY KEY (ServiceID)
);
GO

CREATE TABLE dbo.Departments (
    DepartmentID   INT          NOT NULL IDENTITY(1,1),
    DepartmentName VARCHAR(100) NOT NULL,
    Location       VARCHAR(100) NOT NULL,
    CONSTRAINT PK_Departments PRIMARY KEY (DepartmentID)
);
GO

CREATE TABLE dbo.ErrorLogs (
    ErrorID       INT           NOT NULL IDENTITY(1,1),
    ProcedureName VARCHAR(120)  NOT NULL,
    ErrorMessage  NVARCHAR(MAX) NOT NULL,
    ErrorDate     DATETIME      NOT NULL,
    CONSTRAINT PK_ErrorLogs PRIMARY KEY (ErrorID)
);
GO

-- ============================================================
-- Core Entity Tables
-- ============================================================

CREATE TABLE dbo.Users (
    UserID       INT            NOT NULL IDENTITY(1,1),
    RoleID       INT            NOT NULL,
    Username     VARCHAR(80)    NOT NULL,
    PasswordHash VARBINARY(256) NOT NULL,
    LastLogin    DATETIME           NULL,
    IsActive     BIT            NOT NULL,
    CONSTRAINT PK_Users          PRIMARY KEY (UserID),
    CONSTRAINT UQ_Users_Username UNIQUE      (Username),
    CONSTRAINT FK_Users_Roles    FOREIGN KEY (RoleID)
        REFERENCES dbo.Roles (RoleID)
);
GO

CREATE TABLE dbo.Patients (
    PatientID   INT          NOT NULL IDENTITY(1,1),
    AddressID   INT          NOT NULL,
    FirstName   VARCHAR(60)  NOT NULL,
    LastName    VARCHAR(60)  NOT NULL,
    DOB         DATE         NOT NULL,
    Gender      VARCHAR(20)  NOT NULL,
    Phone       VARCHAR(25)  NOT NULL,
    Email       VARCHAR(120) NOT NULL,
    DateCreated DATETIME     NOT NULL,
    CONSTRAINT PK_Patients         PRIMARY KEY (PatientID),
    CONSTRAINT FK_Patients_Addresses FOREIGN KEY (AddressID)
        REFERENCES dbo.Addresses (AddressID)
);
GO

CREATE TABLE dbo.Doctors (
    DoctorID       INT          NOT NULL IDENTITY(1,1),
    DepartmentID   INT          NOT NULL,
    FirstName      VARCHAR(60)  NOT NULL,
    LastName       VARCHAR(60)  NOT NULL,
    Phone          VARCHAR(25)  NOT NULL,
    Email          VARCHAR(120) NOT NULL,
    Specialization VARCHAR(100) NOT NULL,
    LicenseNumber  VARCHAR(50)  NOT NULL,
    CONSTRAINT PK_Doctors               PRIMARY KEY (DoctorID),
    CONSTRAINT UQ_Doctors_LicenseNumber UNIQUE      (LicenseNumber),
    CONSTRAINT FK_Doctors_Departments   FOREIGN KEY (DepartmentID)
        REFERENCES dbo.Departments (DepartmentID)
);
GO

-- ============================================================
-- Patient-Related Tables
-- ============================================================

CREATE TABLE dbo.EmergencyContacts (
    EmergencyContactID INT          NOT NULL IDENTITY(1,1),
    PatientID          INT          NOT NULL,
    FullName           VARCHAR(120) NOT NULL,
    Relationship       VARCHAR(50)  NOT NULL,
    Phone              VARCHAR(25)  NOT NULL,
    Email              VARCHAR(120) NOT NULL,
    CONSTRAINT PK_EmergencyContacts          PRIMARY KEY (EmergencyContactID),
    CONSTRAINT FK_EmergencyContacts_Patients FOREIGN KEY (PatientID)
        REFERENCES dbo.Patients (PatientID)
);
GO

CREATE TABLE dbo.PatientInsurancePolicies (
    PatientInsuranceID  INT          NOT NULL IDENTITY(1,1),
    PatientID           INT          NOT NULL,
    InsuranceProviderID INT          NOT NULL,
    PolicyNumber        VARCHAR(50)  NOT NULL,
    CoveragePercent     DECIMAL(5,2) NOT NULL,
    ExpiryDate          DATE         NOT NULL,
    IsPrimary           BIT          NOT NULL,
    CONSTRAINT PK_PatientInsurancePolicies                       PRIMARY KEY (PatientInsuranceID),
    CONSTRAINT FK_PatientInsurancePolicies_Patients              FOREIGN KEY (PatientID)
        REFERENCES dbo.Patients (PatientID),
    CONSTRAINT FK_PatientInsurancePolicies_InsuranceProviders    FOREIGN KEY (InsuranceProviderID)
        REFERENCES dbo.InsuranceProviders (InsuranceProviderID)
);
GO

-- ============================================================
-- Scheduling Tables
-- ============================================================

CREATE TABLE dbo.Appointments (
    AppointmentID   INT          NOT NULL IDENTITY(1,1),
    PatientID       INT          NOT NULL,
    DoctorID        INT          NOT NULL,
    CreatedByUserID INT          NOT NULL,
    AppointmentDate DATETIME     NOT NULL,
    Status          VARCHAR(30)  NOT NULL,
    Reason          VARCHAR(255) NOT NULL,
    CONSTRAINT PK_Appointments         PRIMARY KEY (AppointmentID),
    CONSTRAINT FK_Appointments_Patients FOREIGN KEY (PatientID)
        REFERENCES dbo.Patients (PatientID),
    CONSTRAINT FK_Appointments_Doctors  FOREIGN KEY (DoctorID)
        REFERENCES dbo.Doctors (DoctorID),
    CONSTRAINT FK_Appointments_Users    FOREIGN KEY (CreatedByUserID)
        REFERENCES dbo.Users (UserID)
);
GO

CREATE TABLE dbo.AuditLogs (
    AuditID           INT           NOT NULL IDENTITY(1,1),
    PerformedByUserID INT           NOT NULL,
    TableName         VARCHAR(80)   NOT NULL,
    ActionType        VARCHAR(20)   NOT NULL,
    ActionDate        DATETIME      NOT NULL,
    OldValue          NVARCHAR(MAX) NOT NULL,
    NewValue          NVARCHAR(MAX) NOT NULL,
    CONSTRAINT PK_AuditLogs        PRIMARY KEY (AuditID),
    CONSTRAINT FK_AuditLogs_Users  FOREIGN KEY (PerformedByUserID)
        REFERENCES dbo.Users (UserID)
);
GO

-- ============================================================
-- Billing Tables
-- ============================================================

CREATE TABLE dbo.Bills (
    BillID        INT           NOT NULL IDENTITY(1,1),
    PatientID     INT           NOT NULL,
    AppointmentID INT           NOT NULL,
    TotalAmount   DECIMAL(10,2) NOT NULL,
    PaidAmount    DECIMAL(10,2) NOT NULL,
    Balance       DECIMAL(10,2) NOT NULL,
    BillStatus    VARCHAR(30)   NOT NULL,
    CreatedDate   DATETIME      NOT NULL,
    CONSTRAINT PK_Bills               PRIMARY KEY (BillID),
    CONSTRAINT FK_Bills_Patients      FOREIGN KEY (PatientID)
        REFERENCES dbo.Patients (PatientID),
    CONSTRAINT FK_Bills_Appointments  FOREIGN KEY (AppointmentID)
        REFERENCES dbo.Appointments (AppointmentID)
);
GO

CREATE TABLE dbo.BillItems (
    BillItemID INT           NOT NULL IDENTITY(1,1),
    BillID     INT           NOT NULL,
    ServiceID  INT           NOT NULL,
    Quantity   INT           NOT NULL,
    UnitPrice  DECIMAL(10,2) NOT NULL,
    LineTotal  DECIMAL(10,2) NOT NULL,
    CONSTRAINT PK_BillItems              PRIMARY KEY (BillItemID),
    CONSTRAINT FK_BillItems_Bills        FOREIGN KEY (BillID)
        REFERENCES dbo.Bills (BillID),
    CONSTRAINT FK_BillItems_ServiceCatalog FOREIGN KEY (ServiceID)
        REFERENCES dbo.ServiceCatalog (ServiceID)
);
GO

CREATE TABLE dbo.Payments (
    PaymentID       INT           NOT NULL IDENTITY(1,1),
    BillID          INT           NOT NULL,
    PaymentDate     DATETIME      NOT NULL,
    Amount          DECIMAL(10,2) NOT NULL,
    PaymentMethod   VARCHAR(40)   NOT NULL,
    ReferenceNumber VARCHAR(80)   NOT NULL,
    CONSTRAINT PK_Payments        PRIMARY KEY (PaymentID),
    CONSTRAINT FK_Payments_Bills  FOREIGN KEY (BillID)
        REFERENCES dbo.Bills (BillID)
);
GO

-- ============================================================
-- Clinical Records
-- ============================================================

CREATE TABLE dbo.MedicalRecords (
    RecordID      INT           NOT NULL IDENTITY(1,1),
    AppointmentID INT           NOT NULL,
    Diagnosis     VARCHAR(255)  NOT NULL,
    Notes         NVARCHAR(MAX) NOT NULL,
    TreatmentPlan NVARCHAR(MAX) NOT NULL,
    CreatedDate   DATETIME      NOT NULL,
    CONSTRAINT PK_MedicalRecords                    PRIMARY KEY (RecordID),
    CONSTRAINT UQ_MedicalRecords_AppointmentID      UNIQUE      (AppointmentID),
    CONSTRAINT FK_MedicalRecords_Appointments       FOREIGN KEY (AppointmentID)
        REFERENCES dbo.Appointments (AppointmentID)
);
GO

CREATE TABLE dbo.Prescriptions (
    PrescriptionID   INT  NOT NULL IDENTITY(1,1),
    RecordID         INT  NOT NULL,
    DoctorID         INT  NOT NULL,
    PrescriptionDate DATE NOT NULL,
    CONSTRAINT PK_Prescriptions                   PRIMARY KEY (PrescriptionID),
    CONSTRAINT FK_Prescriptions_MedicalRecords    FOREIGN KEY (RecordID)
        REFERENCES dbo.MedicalRecords (RecordID),
    CONSTRAINT FK_Prescriptions_Doctors           FOREIGN KEY (DoctorID)
        REFERENCES dbo.Doctors (DoctorID)
);
GO

CREATE TABLE dbo.PrescriptionItems (
    PrescriptionItemID INT          NOT NULL IDENTITY(1,1),
    PrescriptionID     INT          NOT NULL,
    MedicationName     VARCHAR(120) NOT NULL,
    Dosage             VARCHAR(60)  NOT NULL,
    Frequency          VARCHAR(60)  NOT NULL,
    Duration           VARCHAR(60)  NOT NULL,
    CONSTRAINT PK_PrescriptionItems               PRIMARY KEY (PrescriptionItemID),
    CONSTRAINT FK_PrescriptionItems_Prescriptions FOREIGN KEY (PrescriptionID)
        REFERENCES dbo.Prescriptions (PrescriptionID)
);
GO

CREATE TABLE dbo.LabOrders (
    LabOrderID    INT           NOT NULL IDENTITY(1,1),
    AppointmentID INT           NOT NULL,
    LabTestTypeID INT           NOT NULL,
    Result        NVARCHAR(MAX)     NULL,
    Status        VARCHAR(30)   NOT NULL,
    DateRequested DATETIME      NOT NULL,
    CONSTRAINT PK_LabOrders                 PRIMARY KEY (LabOrderID),
    CONSTRAINT FK_LabOrders_Appointments    FOREIGN KEY (AppointmentID)
        REFERENCES dbo.Appointments (AppointmentID),
    CONSTRAINT FK_LabOrders_LabTestCatalog  FOREIGN KEY (LabTestTypeID)
        REFERENCES dbo.LabTestCatalog (LabTestTypeID)
);
GO
