-- ============================================================
-- Script  : 04_seed_data.sql
-- Purpose : Insert sample data into HospitalDB
-- Date    : 2026-05-07
-- Prereq  : Run 02_create_tables.sql first
-- Note    : PasswordHash values are placeholder bytes for
--           demonstration only. Use a proper bcrypt / PBKDF2
--           hash in any real deployment.
-- ============================================================

USE HospitalDB;
GO

-- ------------------------------------------------------------
-- Reference / Lookup Tables
-- ------------------------------------------------------------

SET IDENTITY_INSERT dbo.Roles ON;
INSERT INTO dbo.Roles (RoleID, RoleName) VALUES
    (1, 'Admin'),
    (2, 'Doctor'),
    (3, 'Receptionist');
SET IDENTITY_INSERT dbo.Roles OFF;
GO

SET IDENTITY_INSERT dbo.Departments ON;
INSERT INTO dbo.Departments (DepartmentID, DepartmentName, Location) VALUES
    (1, 'Cardiology',   'Building A - Floor 2'),
    (2, 'Orthopedics',  'Building B - Floor 1'),
    (3, 'Neurology',    'Building A - Floor 3'),
    (4, 'Pediatrics',   'Building C - Floor 1'),
    (5, 'Emergency',    'Building A - Ground');
SET IDENTITY_INSERT dbo.Departments OFF;
GO

SET IDENTITY_INSERT dbo.InsuranceProviders ON;
INSERT INTO dbo.InsuranceProviders (InsuranceProviderID, ProviderName, Phone, Email) VALUES
    (1, 'BlueCross Health',    '+1-800-555-0101', 'contact@bluecrosshealth.com'),
    (2, 'National MediCare',   '+1-800-555-0202', 'info@nationalmedicare.com'),
    (3, 'Unity Health Shield', '+1-800-555-0303', 'support@unityhealthshield.com');
SET IDENTITY_INSERT dbo.InsuranceProviders OFF;
GO

SET IDENTITY_INSERT dbo.LabTestCatalog ON;
INSERT INTO dbo.LabTestCatalog (LabTestTypeID, TestName, StandardPrice) VALUES
    (1, 'Complete Blood Count (CBC)',    45.00),
    (2, 'Basic Metabolic Panel (BMP)',   55.00),
    (3, 'Lipid Panel',                   60.00),
    (4, 'Thyroid Stimulating Hormone',   75.00),
    (5, 'Urinalysis',                    30.00);
SET IDENTITY_INSERT dbo.LabTestCatalog OFF;
GO

SET IDENTITY_INSERT dbo.ServiceCatalog ON;
INSERT INTO dbo.ServiceCatalog (ServiceID, ServiceName, StandardPrice) VALUES
    (1, 'General Consultation',   150.00),
    (2, 'ECG / EKG',              200.00),
    (3, 'X-Ray (Single View)',    120.00),
    (4, 'MRI Scan',              1200.00),
    (5, 'Emergency Room Visit',   350.00);
SET IDENTITY_INSERT dbo.ServiceCatalog OFF;
GO

-- ------------------------------------------------------------
-- Core Entities
-- ------------------------------------------------------------

SET IDENTITY_INSERT dbo.Addresses ON;
INSERT INTO dbo.Addresses (AddressID, Street, City, State, PostalCode, Country) VALUES
    (1, '14 Elm Street',    'Springfield', 'Illinois', '62701', 'USA'),
    (2, '233 Oak Avenue',   'Chicago',     'Illinois', '60601', 'USA'),
    (3, '8 Maple Lane',     'Peoria',      'Illinois', '61602', 'USA'),
    (4, '55 Birch Road',    'Rockford',    'Illinois', '61101', 'USA'),
    (5, '101 Cedar Court',  'Aurora',      'Illinois', '60505', 'USA');
SET IDENTITY_INSERT dbo.Addresses OFF;
GO

SET IDENTITY_INSERT dbo.Users ON;
INSERT INTO dbo.Users (UserID, RoleID, Username, PasswordHash, LastLogin, IsActive) VALUES
    (1, 1, 'admin.rodriguez',   0x00000000000000000000000000000000000000000000000000000000000000001, '2026-05-06 08:30:00', 1),
    (2, 2, 'dr.chen',           0x00000000000000000000000000000000000000000000000000000000000000002, '2026-05-07 07:45:00', 1),
    (3, 3, 'receptionist.lee',  0x00000000000000000000000000000000000000000000000000000000000000003, '2026-05-07 08:00:00', 1);
SET IDENTITY_INSERT dbo.Users OFF;
GO

SET IDENTITY_INSERT dbo.Patients ON;
INSERT INTO dbo.Patients (PatientID, AddressID, FirstName, LastName, DOB, Gender, Phone, Email, DateCreated) VALUES
    (1, 1, 'James',  'Hartley',  '1985-03-12', 'Male',   '+1-555-0101', 'james.hartley@email.com',  '2024-01-15 09:00:00'),
    (2, 2, 'Maria',  'Gonzalez', '1990-07-24', 'Female', '+1-555-0102', 'maria.gonzalez@email.com', '2024-02-20 10:30:00'),
    (3, 3, 'Robert', 'Kim',      '1978-11-05', 'Male',   '+1-555-0103', 'robert.kim@email.com',     '2024-03-08 14:00:00'),
    (4, 4, 'Sophia', 'Patel',    '2001-05-18', 'Female', '+1-555-0104', 'sophia.patel@email.com',   '2024-04-01 11:15:00'),
    (5, 5, 'David',  'Thompson', '1963-09-30', 'Male',   '+1-555-0105', 'david.thompson@email.com', '2024-05-22 16:45:00');
SET IDENTITY_INSERT dbo.Patients OFF;
GO

SET IDENTITY_INSERT dbo.Doctors ON;
INSERT INTO dbo.Doctors (DoctorID, DepartmentID, FirstName, LastName, Phone, Email, Specialization, LicenseNumber) VALUES
    (1, 1, 'Wei',    'Chen',   '+1-555-0201', 'dr.wei.chen@hospital.com',    'Cardiologist',      'MD-IL-10011'),
    (2, 2, 'Priya',  'Sharma', '+1-555-0202', 'dr.priya.sharma@hospital.com','Orthopedic Surgeon','MD-IL-10022'),
    (3, 3, 'Carlos', 'Vega',   '+1-555-0203', 'dr.carlos.vega@hospital.com', 'Neurologist',       'MD-IL-10033');
SET IDENTITY_INSERT dbo.Doctors OFF;
GO

-- ------------------------------------------------------------
-- Patient Supporting Data
-- ------------------------------------------------------------

SET IDENTITY_INSERT dbo.EmergencyContacts ON;
INSERT INTO dbo.EmergencyContacts (EmergencyContactID, PatientID, FullName, Relationship, Phone, Email) VALUES
    (1, 1, 'Linda Hartley',  'Spouse', '+1-555-1001', 'linda.hartley@email.com'),
    (2, 2, 'Carlos Gonzalez','Father', '+1-555-1002', 'carlos.g@email.com'),
    (3, 3, 'Amy Kim',        'Spouse', '+1-555-1003', 'amy.kim@email.com'),
    (4, 4, 'Raj Patel',      'Father', '+1-555-1004', 'raj.patel@email.com'),
    (5, 5, 'Nancy Thompson', 'Spouse', '+1-555-1005', 'nancy.thompson@email.com');
SET IDENTITY_INSERT dbo.EmergencyContacts OFF;
GO

SET IDENTITY_INSERT dbo.PatientInsurancePolicies ON;
INSERT INTO dbo.PatientInsurancePolicies (PatientInsuranceID, PatientID, InsuranceProviderID, PolicyNumber, CoveragePercent, ExpiryDate, IsPrimary) VALUES
    (1, 1, 1, 'BC-2024-00101', 80.00, '2027-12-31', 1),
    (2, 2, 2, 'NM-2024-00202', 75.00, '2026-06-30', 1),
    (3, 3, 3, 'UH-2024-00303', 90.00, '2028-03-31', 1);
SET IDENTITY_INSERT dbo.PatientInsurancePolicies OFF;
GO

-- ------------------------------------------------------------
-- Scheduling
-- ------------------------------------------------------------

SET IDENTITY_INSERT dbo.Appointments ON;
INSERT INTO dbo.Appointments (AppointmentID, PatientID, DoctorID, CreatedByUserID, AppointmentDate, Status, Reason) VALUES
    (1, 1, 1, 3, '2026-04-10 09:00:00', 'Completed', 'Chest pain and shortness of breath'),
    (2, 2, 2, 3, '2026-04-12 10:30:00', 'Completed', 'Knee pain after sports injury'),
    (3, 3, 3, 3, '2026-04-15 14:00:00', 'Completed', 'Recurring migraines'),
    (4, 4, 1, 3, '2026-05-05 11:00:00', 'Scheduled', 'Follow-up cardiac checkup'),
    (5, 5, 2, 3, '2026-05-08 15:30:00', 'Scheduled', 'Lower back pain');
SET IDENTITY_INSERT dbo.Appointments OFF;
GO

-- ------------------------------------------------------------
-- Billing
-- ------------------------------------------------------------

SET IDENTITY_INSERT dbo.Bills ON;
INSERT INTO dbo.Bills (BillID, PatientID, AppointmentID, TotalAmount, PaidAmount, Balance, BillStatus, CreatedDate) VALUES
    (1, 1, 1, 350.00, 350.00,   0.00, 'Paid',    '2026-04-10 10:00:00'),
    (2, 2, 2, 270.00, 150.00, 120.00, 'Partial', '2026-04-12 11:30:00'),
    (3, 3, 3, 150.00,   0.00, 150.00, 'Unpaid',  '2026-04-15 15:00:00');
SET IDENTITY_INSERT dbo.Bills OFF;
GO

SET IDENTITY_INSERT dbo.BillItems ON;
INSERT INTO dbo.BillItems (BillItemID, BillID, ServiceID, Quantity, UnitPrice, LineTotal) VALUES
    (1, 1, 1, 1, 150.00, 150.00),
    (2, 1, 2, 1, 200.00, 200.00),
    (3, 2, 1, 1, 150.00, 150.00),
    (4, 2, 3, 1, 120.00, 120.00),
    (5, 3, 1, 1, 150.00, 150.00);
SET IDENTITY_INSERT dbo.BillItems OFF;
GO

SET IDENTITY_INSERT dbo.Payments ON;
INSERT INTO dbo.Payments (PaymentID, BillID, PaymentDate, Amount, PaymentMethod, ReferenceNumber) VALUES
    (1, 1, '2026-04-10 10:15:00', 350.00, 'Credit Card', 'TXN-2026-0001'),
    (2, 2, '2026-04-12 12:00:00', 150.00, 'Cash',        'TXN-2026-0002');
SET IDENTITY_INSERT dbo.Payments OFF;
GO

-- ------------------------------------------------------------
-- Clinical Records
-- ------------------------------------------------------------

SET IDENTITY_INSERT dbo.MedicalRecords ON;
INSERT INTO dbo.MedicalRecords (RecordID, AppointmentID, Diagnosis, Notes, TreatmentPlan, CreatedDate) VALUES
    (1, 1, 'Stable angina',
        'Patient reports intermittent chest tightness during exertion. BP 135/88.',
        'Prescribe nitroglycerin. Lifestyle modification. Follow up in 4 weeks.',
        '2026-04-10 09:45:00'),
    (2, 2, 'Grade II knee sprain',
        'Swelling and tenderness around the medial collateral ligament.',
        'RICE protocol. Physical therapy referral. Review in 3 weeks.',
        '2026-04-12 11:00:00'),
    (3, 3, 'Migraine without aura',
        'Frequency: 3-4 episodes/month lasting 6-12 hours. No aura reported.',
        'Sumatriptan 50mg PRN. Avoid known triggers. Headache diary recommended.',
        '2026-04-15 14:30:00');
SET IDENTITY_INSERT dbo.MedicalRecords OFF;
GO

SET IDENTITY_INSERT dbo.Prescriptions ON;
INSERT INTO dbo.Prescriptions (PrescriptionID, RecordID, DoctorID, PrescriptionDate) VALUES
    (1, 1, 1, '2026-04-10'),
    (2, 3, 3, '2026-04-15');
SET IDENTITY_INSERT dbo.Prescriptions OFF;
GO

SET IDENTITY_INSERT dbo.PrescriptionItems ON;
INSERT INTO dbo.PrescriptionItems (PrescriptionItemID, PrescriptionID, MedicationName, Dosage, Frequency, Duration) VALUES
    (1, 1, 'Nitroglycerin', '0.4 mg sublingual', 'As needed for chest pain',  '30 days'),
    (2, 1, 'Aspirin',       '81 mg',             'Once daily',                '90 days'),
    (3, 2, 'Sumatriptan',   '50 mg',             'At onset of migraine',      '30 days'),
    (4, 2, 'Metoprolol',    '25 mg',             'Once daily at bedtime',     '60 days');
SET IDENTITY_INSERT dbo.PrescriptionItems OFF;
GO

SET IDENTITY_INSERT dbo.LabOrders ON;
INSERT INTO dbo.LabOrders (LabOrderID, AppointmentID, LabTestTypeID, Result, Status, DateRequested) VALUES
    (1, 1, 1, 'WBC: 6.8 K/uL, RBC: 4.5 M/uL, Hgb: 13.8 g/dL - Within normal range',  'Completed', '2026-04-10 09:30:00'),
    (2, 1, 3, 'Total Cholesterol: 210 mg/dL, LDL: 130 mg/dL, HDL: 55 mg/dL - Borderline', 'Completed', '2026-04-10 09:30:00'),
    (3, 3, 2, NULL, 'Pending', '2026-04-15 14:00:00');
SET IDENTITY_INSERT dbo.LabOrders OFF;
GO

-- Resync all identity seeds after explicit inserts
DBCC CHECKIDENT ('dbo.Roles',                   RESEED);
DBCC CHECKIDENT ('dbo.Departments',             RESEED);
DBCC CHECKIDENT ('dbo.InsuranceProviders',      RESEED);
DBCC CHECKIDENT ('dbo.LabTestCatalog',          RESEED);
DBCC CHECKIDENT ('dbo.ServiceCatalog',          RESEED);
DBCC CHECKIDENT ('dbo.Addresses',               RESEED);
DBCC CHECKIDENT ('dbo.Users',                   RESEED);
DBCC CHECKIDENT ('dbo.Patients',                RESEED);
DBCC CHECKIDENT ('dbo.Doctors',                 RESEED);
DBCC CHECKIDENT ('dbo.EmergencyContacts',       RESEED);
DBCC CHECKIDENT ('dbo.PatientInsurancePolicies',RESEED);
DBCC CHECKIDENT ('dbo.Appointments',            RESEED);
DBCC CHECKIDENT ('dbo.Bills',                   RESEED);
DBCC CHECKIDENT ('dbo.BillItems',               RESEED);
DBCC CHECKIDENT ('dbo.Payments',                RESEED);
DBCC CHECKIDENT ('dbo.MedicalRecords',          RESEED);
DBCC CHECKIDENT ('dbo.Prescriptions',           RESEED);
DBCC CHECKIDENT ('dbo.PrescriptionItems',       RESEED);
DBCC CHECKIDENT ('dbo.LabOrders',               RESEED);
GO
