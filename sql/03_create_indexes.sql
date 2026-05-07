-- ============================================================
-- Script  : 03_create_indexes.sql
-- Purpose : Create non-PK performance indexes for HospitalDB
-- Date    : 2026-05-07
-- Note    : The following UNIQUE constraints are already defined
--           inline in 02_create_tables.sql and are not repeated:
--             UQ_Doctors_LicenseNumber
--             UQ_LabTestCatalog_TestName
--             UQ_MedicalRecords_AppointmentID
--             UQ_Roles_RoleName
--             UQ_Users_Username
-- ============================================================

USE HospitalDB;
GO

-- ------------------------------------------------------------
-- Patients
-- ------------------------------------------------------------
CREATE NONCLUSTERED INDEX IX_Patients_LastName
    ON dbo.Patients (LastName);
GO

CREATE NONCLUSTERED INDEX IX_Patients_Email
    ON dbo.Patients (Email);
GO

-- ------------------------------------------------------------
-- Appointments
-- ------------------------------------------------------------
CREATE NONCLUSTERED INDEX IX_Appointments_PatientID
    ON dbo.Appointments (PatientID);
GO

CREATE NONCLUSTERED INDEX IX_Appointments_DoctorID
    ON dbo.Appointments (DoctorID);
GO

CREATE NONCLUSTERED INDEX IX_Appointments_AppointmentDate
    ON dbo.Appointments (AppointmentDate);
GO

-- ------------------------------------------------------------
-- Bills
-- ------------------------------------------------------------
CREATE NONCLUSTERED INDEX IX_Bills_PatientID
    ON dbo.Bills (PatientID);
GO

CREATE NONCLUSTERED INDEX IX_Bills_AppointmentID
    ON dbo.Bills (AppointmentID);
GO

-- ------------------------------------------------------------
-- Payments
-- ------------------------------------------------------------
CREATE NONCLUSTERED INDEX IX_Payments_BillID
    ON dbo.Payments (BillID);
GO

-- ------------------------------------------------------------
-- Medical Records
-- ------------------------------------------------------------
CREATE NONCLUSTERED INDEX IX_MedicalRecords_CreatedDate
    ON dbo.MedicalRecords (CreatedDate);
GO

-- ------------------------------------------------------------
-- Prescriptions
-- ------------------------------------------------------------
CREATE NONCLUSTERED INDEX IX_Prescriptions_RecordID
    ON dbo.Prescriptions (RecordID);
GO

-- ------------------------------------------------------------
-- Lab Orders
-- ------------------------------------------------------------
CREATE NONCLUSTERED INDEX IX_LabOrders_AppointmentID
    ON dbo.LabOrders (AppointmentID);
GO

CREATE NONCLUSTERED INDEX IX_LabOrders_Status
    ON dbo.LabOrders (Status);
GO

-- ------------------------------------------------------------
-- Audit Logs
-- ------------------------------------------------------------
CREATE NONCLUSTERED INDEX IX_AuditLogs_ActionDate
    ON dbo.AuditLogs (ActionDate);
GO

CREATE NONCLUSTERED INDEX IX_AuditLogs_PerformedByUserID
    ON dbo.AuditLogs (PerformedByUserID);
GO
