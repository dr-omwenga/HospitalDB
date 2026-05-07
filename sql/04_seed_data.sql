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
    (3, 'Receptionist'),
    (4, 'Nurse'),
    (5, 'Lab Technician'),
    (6, 'Pharmacist'),
    (7, 'IT Support'),
    (8, 'Billing Specialist');
SET IDENTITY_INSERT dbo.Roles OFF;
GO

SET IDENTITY_INSERT dbo.Departments ON;
INSERT INTO dbo.Departments (DepartmentID, DepartmentName, Location) VALUES
    ( 1, 'Cardiology',                  'Building A - Floor 2'),
    ( 2, 'Orthopedics',                 'Building B - Floor 1'),
    ( 3, 'Neurology',                   'Building A - Floor 3'),
    ( 4, 'Pediatrics',                  'Building C - Floor 1'),
    ( 5, 'Emergency',                   'Building A - Ground'),
    ( 6, 'Oncology',                    'Building B - Floor 2'),
    ( 7, 'Radiology',                   'Building D - Floor 1'),
    ( 8, 'General Surgery',             'Building B - Floor 3'),
    ( 9, 'Internal Medicine',           'Building A - Floor 1'),
    (10, 'Obstetrics & Gynecology',     'Building C - Floor 2'),
    (11, 'Psychiatry',                  'Building D - Floor 2'),
    (12, 'Dermatology',                 'Building C - Floor 3'),
    (13, 'Gastroenterology',            'Building A - Floor 4'),
    (14, 'Endocrinology',               'Building B - Floor 4'),
    (15, 'Pulmonology',                 'Building A - Floor 5');
SET IDENTITY_INSERT dbo.Departments OFF;
GO

SET IDENTITY_INSERT dbo.InsuranceProviders ON;
INSERT INTO dbo.InsuranceProviders (InsuranceProviderID, ProviderName, Phone, Email) VALUES
    ( 1, 'BlueCross Health',         '+1-800-555-0101', 'contact@bluecrosshealth.com'),
    ( 2, 'National MediCare',        '+1-800-555-0202', 'info@nationalmedicare.com'),
    ( 3, 'Unity Health Shield',      '+1-800-555-0303', 'support@unityhealthshield.com'),
    ( 4, 'Aetna Plus',               '+1-800-555-0404', 'members@aetnaplus.com'),
    ( 5, 'Cigna Medical',            '+1-800-555-0505', 'care@cignamedical.com'),
    ( 6, 'Humana Health',            '+1-800-555-0606', 'info@humanahealth.com'),
    ( 7, 'UnitedHealth Premier',     '+1-800-555-0707', 'support@unitedhealthpremier.com'),
    ( 8, 'Anthem Blue',              '+1-800-555-0808', 'contact@anthemblue.com'),
    ( 9, 'Kaiser Connect',           '+1-800-555-0909', 'help@kaiserconnect.com'),
    (10, 'Molina Healthcare',        '+1-800-555-1010', 'info@molinahealthcare.com'),
    (11, 'Centene Corp',             '+1-800-555-1111', 'support@centenecorp.com'),
    (12, 'WellCare Health',          '+1-800-555-1212', 'care@wellcarehealth.com'),
    (13, 'Medica Group',             '+1-800-555-1313', 'info@medicagroup.com'),
    (14, 'HealthPartners',           '+1-800-555-1414', 'members@healthpartners.com'),
    (15, 'BCBS Illinois',            '+1-800-555-1515', 'contact@bcbsillinois.com'),
    (16, 'Meridian Health Plan',     '+1-800-555-1616', 'support@meridianhealthplan.com'),
    (17, 'Coventry Health',          '+1-800-555-1717', 'info@coventryhealth.com'),
    (18, 'Bright Health',            '+1-800-555-1818', 'care@brighthealth.com'),
    (19, 'Oscar Health',             '+1-800-555-1919', 'hello@oscarhealth.com'),
    (20, 'Friday Health Plans',      '+1-800-555-2020', 'info@fridayhealthplans.com'),
    (21, 'Clover Health',            '+1-800-555-2121', 'support@cloverhealth.com'),
    (22, 'Alignment Health',         '+1-800-555-2222', 'members@alignmenthealth.com'),
    (23, 'Point32Health',            '+1-800-555-2323', 'info@point32health.com'),
    (24, 'Ambetter Health',          '+1-800-555-2424', 'care@ambetterhealth.com'),
    (25, 'Simply Health',            '+1-800-555-2525', 'contact@simplyhealth.com'),
    (26, 'EmblemHealth',             '+1-800-555-2626', 'support@emblemhealth.com'),
    (27, 'Independence Health',      '+1-800-555-2727', 'info@independencehealth.com'),
    (28, 'PreferredOne',             '+1-800-555-2828', 'members@preferredone.com'),
    (29, 'Sanford Health Plan',      '+1-800-555-2929', 'care@sanfordhealthplan.com'),
    (30, 'Sutter Health Plan',       '+1-800-555-3030', 'info@sutterhealthplan.com');
SET IDENTITY_INSERT dbo.InsuranceProviders OFF;
GO

SET IDENTITY_INSERT dbo.LabTestCatalog ON;
INSERT INTO dbo.LabTestCatalog (LabTestTypeID, TestName, StandardPrice) VALUES
    ( 1, 'Complete Blood Count (CBC)',              45.00),
    ( 2, 'Basic Metabolic Panel (BMP)',             55.00),
    ( 3, 'Lipid Panel',                             60.00),
    ( 4, 'Thyroid Stimulating Hormone (TSH)',       75.00),
    ( 5, 'Urinalysis',                              30.00),
    ( 6, 'Comprehensive Metabolic Panel (CMP)',     65.00),
    ( 7, 'Hemoglobin A1c (HbA1c)',                 50.00),
    ( 8, 'Prothrombin Time (PT/INR)',               40.00),
    ( 9, 'Activated Partial Thromboplastin (aPTT)', 42.00),
    (10, 'Blood Culture (Aerobic)',                 80.00),
    (11, 'Urine Culture & Sensitivity',             70.00),
    (12, 'Troponin I',                              95.00),
    (13, 'D-Dimer',                                 88.00),
    (14, 'C-Reactive Protein (CRP)',                55.00),
    (15, 'Erythrocyte Sedimentation Rate (ESR)',    35.00),
    (16, 'Ferritin',                                60.00),
    (17, 'Vitamin D (25-OH)',                       70.00),
    (18, 'Vitamin B12',                             65.00),
    (19, 'Folate',                                  55.00),
    (20, 'Prostate-Specific Antigen (PSA)',         80.00),
    (21, 'CA-125 (Ovarian Tumor Marker)',           95.00),
    (22, 'CEA (Carcinoembryonic Antigen)',          90.00),
    (23, 'Hepatitis B Surface Antigen (HBsAg)',     75.00),
    (24, 'Hepatitis C Antibody (Anti-HCV)',         75.00),
    (25, 'HIV Antibody / Antigen (4th Gen)',        85.00),
    (26, 'Stool Occult Blood Test (FOBT)',          40.00),
    (27, 'Arterial Blood Gas (ABG)',               110.00),
    (28, 'Magnesium',                               45.00),
    (29, 'Serum Uric Acid',                         40.00),
    (30, 'Free T4 (Thyroxine)',                     65.00);
SET IDENTITY_INSERT dbo.LabTestCatalog OFF;
GO

SET IDENTITY_INSERT dbo.ServiceCatalog ON;
INSERT INTO dbo.ServiceCatalog (ServiceID, ServiceName, StandardPrice) VALUES
    ( 1, 'General Consultation',             150.00),
    ( 2, 'ECG / EKG',                        200.00),
    ( 3, 'X-Ray (Single View)',              120.00),
    ( 4, 'MRI Scan',                        1200.00),
    ( 5, 'Emergency Room Visit',             350.00),
    ( 6, 'Specialist Consultation',          250.00),
    ( 7, 'CT Scan (Without Contrast)',       800.00),
    ( 8, 'CT Scan (With Contrast)',         1050.00),
    ( 9, 'Ultrasound (Abdominal)',           300.00),
    (10, 'Ultrasound (Obstetric)',           280.00),
    (11, 'Echocardiogram',                   650.00),
    (12, 'Pulmonary Function Test',          220.00),
    (13, 'Endoscopy (Upper GI)',             900.00),
    (14, 'Colonoscopy',                     1100.00),
    (15, 'Minor Surgical Procedure',         500.00),
    (16, 'Day Surgery',                     2500.00),
    (17, 'Wound Dressing / Care',             80.00),
    (18, 'Intravenous Infusion (per session)',180.00),
    (19, 'Physical Therapy Session',         120.00),
    (20, 'Occupational Therapy Session',     110.00),
    (21, 'Nutritional Counseling',            90.00),
    (22, 'Psychiatric Evaluation',           300.00),
    (23, 'Psychotherapy Session',            150.00),
    (24, 'Vaccination / Immunization',        60.00),
    (25, 'Allergy Testing (Panel)',           350.00),
    (26, 'Bone Density Scan (DEXA)',         250.00),
    (27, 'Mammography',                      200.00),
    (28, 'Ambulance Transport',              450.00),
    (29, 'ICU Care (per day)',              3500.00),
    (30, 'Dialysis Session',                 500.00);
SET IDENTITY_INSERT dbo.ServiceCatalog OFF;
GO

-- ------------------------------------------------------------
-- Core Entities
-- ------------------------------------------------------------

SET IDENTITY_INSERT dbo.Addresses ON;
INSERT INTO dbo.Addresses (AddressID, Street, City, State, PostalCode, Country) VALUES
    ( 1, '14 Elm Street',          'Springfield',  'Illinois',   '62701', 'USA'),
    ( 2, '233 Oak Avenue',         'Chicago',       'Illinois',   '60601', 'USA'),
    ( 3, '8 Maple Lane',           'Peoria',        'Illinois',   '61602', 'USA'),
    ( 4, '55 Birch Road',          'Rockford',      'Illinois',   '61101', 'USA'),
    ( 5, '101 Cedar Court',        'Aurora',        'Illinois',   '60505', 'USA'),
    ( 6, '47 Walnut Drive',        'Naperville',    'Illinois',   '60540', 'USA'),
    ( 7, '320 Pine Street',        'Joliet',        'Illinois',   '60432', 'USA'),
    ( 8, '19 Ash Boulevard',       'Waukegan',      'Illinois',   '60085', 'USA'),
    ( 9, '76 Hickory Way',         'Champaign',     'Illinois',   '61820', 'USA'),
    (10, '88 Poplar Place',        'Elgin',         'Illinois',   '60120', 'USA'),
    (11, '500 Magnolia Trail',     'Decatur',       'Illinois',   '62521', 'USA'),
    (12, '1212 Sycamore Road',     'Evanston',      'Illinois',   '60201', 'USA'),
    (13, '34 Chestnut Circle',     'Schaumburg',    'Illinois',   '60193', 'USA'),
    (14, '671 Willow Glen',        'Bolingbrook',   'Illinois',   '60440', 'USA'),
    (15, '29 Redwood Lane',        'Bloomington',   'Illinois',   '61701', 'USA'),
    (16, '83 Spruce Court',        'Arlington Hts', 'Illinois',   '60004', 'USA'),
    (17, '215 Hawthorn Ave',       'Normal',        'Illinois',   '61761', 'USA'),
    (18, '77 Dogwood Drive',       'Quincy',        'Illinois',   '62301', 'USA'),
    (19, '402 Cypress Street',     'Moline',        'Illinois',   '61265', 'USA'),
    (20, '56 Juniper Road',        'Tinley Park',   'Illinois',   '60477', 'USA'),
    (21, '130 Fir Avenue',         'Oak Park',      'Illinois',   '60301', 'USA'),
    (22, '900 Beech Street',       'Cicero',        'Illinois',   '60804', 'USA'),
    (23, '44 Laurel Lane',         'Berwyn',        'Illinois',   '60402', 'USA'),
    (24, '367 Acacia Way',         'Des Plaines',   'Illinois',   '60016', 'USA'),
    (25, '12 Linden Blvd',         'Oak Lawn',      'Illinois',   '60453', 'USA'),
    (26, '88 Cottonwood Court',    'Orland Park',   'Illinois',   '60462', 'USA'),
    (27, '275 Ironwood Circle',    'Wheaton',       'Illinois',   '60187', 'USA'),
    (28, '543 Tamarack Drive',     'Downers Grove', 'Illinois',   '60515', 'USA'),
    (29, '18 Locust Street',       'Plainfield',    'Illinois',   '60585', 'USA'),
    (30, '61 Bamboo Boulevard',    'Oswego',        'Illinois',   '60543', 'USA');
SET IDENTITY_INSERT dbo.Addresses OFF;
GO

-- ------------------------------------------------------------
-- Security: Row-level permissions
-- Each user row is granted SELECT via the db_datareader role
-- (applied at the end of this script). PasswordHash stores a
-- PBKDF2/bcrypt digest — never a plain-text value.
-- ------------------------------------------------------------
SET IDENTITY_INSERT dbo.Users ON;
INSERT INTO dbo.Users (UserID, RoleID, Username, PasswordHash, LastLogin, IsActive) VALUES
    -- Admins (RoleID = 1)
    ( 1, 1, 'admin.rodriguez',    0xA1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2, '2026-05-06 08:30:00', 1),
    ( 2, 1, 'admin.patel',        0xB2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2C3, '2026-05-05 09:15:00', 1),
    ( 3, 1, 'admin.nguyen',       0xC3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2C3D4, '2026-05-01 10:00:00', 1),
    -- Doctors (RoleID = 2)
    ( 4, 2, 'dr.chen',            0xD4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2C3D4E5, '2026-05-07 07:45:00', 1),
    ( 5, 2, 'dr.sharma',          0xE5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2C3D4E5F6, '2026-05-07 08:00:00', 1),
    ( 6, 2, 'dr.vega',            0xF6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2C3D4E5F6A7, '2026-05-06 07:30:00', 1),
    ( 7, 2, 'dr.okonkwo',         0xA7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2C3D4E5F6A7B8, '2026-05-07 07:55:00', 1),
    ( 8, 2, 'dr.yamamoto',        0xB8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2C3D4E5F6A7B8C9, '2026-05-04 08:10:00', 1),
    ( 9, 2, 'dr.hassan',          0xC9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2C3D4E5F6A7B8C9D0, '2026-05-07 08:20:00', 1),
    (10, 2, 'dr.petrov',          0xD0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2C3D4E5F6A7B8C9D0E1, '2026-05-06 14:00:00', 1),
    (11, 2, 'dr.mbeki',           0xE1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2C3D4E5F6A7B8C9D0E1F2, '2026-05-05 07:50:00', 1),
    (12, 2, 'dr.torres',          0xF2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2C3D4E5F6A7B8C9D0E1F2A3, '2026-05-07 08:05:00', 1),
    (13, 2, 'dr.li',              0xA3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2C3D4E5F6A7B8C9D0E1F2A3B4, '2026-05-03 09:00:00', 1),
    (14, 2, 'dr.eriksson',        0xB4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5, '2026-05-07 07:40:00', 1),
    (15, 2, 'dr.rahman',          0xC5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6, '2026-05-06 10:30:00', 1),
    (16, 2, 'dr.kowalski',        0xD6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7, '2026-05-07 07:45:00', 1),
    (17, 2, 'dr.nakamura',        0xE7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8, '2026-05-05 08:15:00', 1),
    (18, 2, 'dr.ali',             0xF8A9B0C1D2E3F4A5B6C7D8E9F0A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9, '2026-05-07 07:30:00', 1),
    (19, 2, 'dr.johansson',       0xA9B0C1D2E3F4A5B6C7D8E9F0A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0, '2026-05-02 09:00:00', 0),
    (20, 2, 'dr.mensah',          0xB0C1D2E3F4A5B6C7D8E9F0A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1, '2026-04-28 08:00:00', 1),
    (21, 2, 'dr.silva',           0xC1D2E3F4A5B6C7D8E9F0A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2, '2026-05-07 08:30:00', 1),
    (22, 2, 'dr.dubois',          0xD2E3F4A5B6C7D8E9F0A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3, '2026-05-06 07:55:00', 1),
    (23, 2, 'dr.mueller',         0xE3F4A5B6C7D8E9F0A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4, '2026-05-07 08:00:00', 1),
    -- Receptionists (RoleID = 3)
    (24, 3, 'receptionist.lee',   0xF4A5B6C7D8E9F0A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5, '2026-05-07 08:00:00', 1),
    (25, 3, 'receptionist.moore', 0xA5B6C7D8E9F0A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6, '2026-05-07 08:05:00', 1),
    (26, 3, 'receptionist.white', 0xB6C7D8E9F0A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7, '2026-05-07 07:58:00', 1),
    (27, 3, 'receptionist.davis', 0xC7D8E9F0A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8, '2026-05-06 08:00:00', 1),
    (28, 3, 'receptionist.clark', 0xD8E9F0A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9, '2026-05-05 08:10:00', 1),
    (29, 3, 'receptionist.hall',  0xE9F0A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0, '2026-05-04 08:00:00', 1),
    (30, 3, 'receptionist.young', 0xF0A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1, NULL,                   0);
SET IDENTITY_INSERT dbo.Users OFF;
GO

-- Grant read access to the HospitalDB-level read role
-- (run once by a db_owner / sysadmin after users exist)
-- ALTER ROLE db_datareader ADD MEMBER [<login>];

SET IDENTITY_INSERT dbo.Patients ON;
INSERT INTO dbo.Patients (PatientID, AddressID, FirstName, LastName, DOB, Gender, Phone, Email, DateCreated) VALUES
    ( 1,  1, 'James',    'Hartley',    '1985-03-12', 'Male',           '+1-555-0101', 'james.hartley@email.com',    '2024-01-15 09:00:00'),
    ( 2,  2, 'Maria',    'Gonzalez',   '1990-07-24', 'Female',         '+1-555-0102', 'maria.gonzalez@email.com',   '2024-02-20 10:30:00'),
    ( 3,  3, 'Robert',   'Kim',        '1978-11-05', 'Male',           '+1-555-0103', 'robert.kim@email.com',       '2024-03-08 14:00:00'),
    ( 4,  4, 'Sophia',   'Patel',      '2001-05-18', 'Female',         '+1-555-0104', 'sophia.patel@email.com',     '2024-04-01 11:15:00'),
    ( 5,  5, 'David',    'Thompson',   '1963-09-30', 'Male',           '+1-555-0105', 'david.thompson@email.com',   '2024-05-22 16:45:00'),
    ( 6,  6, 'Aisha',    'Okonkwo',    '1995-08-14', 'Female',         '+1-555-0106', 'aisha.okonkwo@email.com',    '2024-06-10 08:30:00'),
    ( 7,  7, 'Liam',     'O''Brien',   '1982-01-22', 'Male',           '+1-555-0107', 'liam.obrien@email.com',      '2024-06-18 11:00:00'),
    ( 8,  8, 'Yuki',     'Yamamoto',   '2000-11-30', 'Female',         '+1-555-0108', 'yuki.yamamoto@email.com',    '2024-07-02 09:45:00'),
    ( 9,  9, 'Carlos',   'Mendez',     '1975-04-07', 'Male',           '+1-555-0109', 'carlos.mendez@email.com',    '2024-07-15 14:20:00'),
    (10, 10, 'Fatima',   'Al-Hassan',  '1988-09-19', 'Female',         '+1-555-0110', 'fatima.alhassan@email.com',  '2024-07-28 10:00:00'),
    (11, 11, 'Ethan',    'Brooks',     '2010-02-28', 'Male',           '+1-555-0111', 'ethan.brooks@email.com',     '2024-08-05 09:00:00'),
    (12, 12, 'Ingrid',   'Eriksson',   '1970-06-15', 'Female',         '+1-555-0112', 'ingrid.eriksson@email.com',  '2024-08-20 13:30:00'),
    (13, 13, 'Mohammed', 'Rahman',     '1959-12-03', 'Male',           '+1-555-0113', 'mohammed.rahman@email.com',  '2024-09-01 08:15:00'),
    (14, 14, 'Chloe',    'Dubois',     '1997-03-25', 'Female',         '+1-555-0114', 'chloe.dubois@email.com',     '2024-09-14 11:45:00'),
    (15, 15, 'Samuel',   'Mensah',     '1944-07-11', 'Male',           '+1-555-0115', 'samuel.mensah@email.com',    '2024-09-22 15:00:00'),
    (16, 16, 'Elena',    'Petrov',     '1993-10-08', 'Female',         '+1-555-0116', 'elena.petrov@email.com',     '2024-10-03 09:30:00'),
    (17, 17, 'Hiroshi',  'Nakamura',   '1980-05-20', 'Male',           '+1-555-0117', 'hiroshi.nakamura@email.com', '2024-10-17 12:00:00'),
    (18, 18, 'Amara',    'Diallo',     '2005-01-16', 'Female',         '+1-555-0118', 'amara.diallo@email.com',     '2024-10-30 10:15:00'),
    (19, 19, 'Lucas',    'Kowalski',   '1967-08-29', 'Male',           '+1-555-0119', 'lucas.kowalski@email.com',   '2024-11-08 14:45:00'),
    (20, 20, 'Nora',     'Mueller',    '1955-03-17', 'Female',         '+1-555-0120', 'nora.mueller@email.com',     '2024-11-19 09:00:00'),
    (21, 21, 'Omar',     'Ali',        '1991-11-04', 'Male',           '+1-555-0121', 'omar.ali@email.com',         '2024-11-27 10:30:00'),
    (22, 22, 'Priya',    'Singh',      '2003-07-09', 'Female',         '+1-555-0122', 'priya.singh@email.com',      '2024-12-05 11:00:00'),
    (23, 23, 'Thomas',   'Johansson',  '1976-02-14', 'Male',           '+1-555-0123', 'thomas.johansson@email.com', '2024-12-12 08:45:00'),
    (24, 24, 'Keiko',    'Tanaka',     '1948-06-30', 'Female',         '+1-555-0124', 'keiko.tanaka@email.com',     '2024-12-20 13:15:00'),
    (25, 25, 'Andre',    'Silva',      '1998-09-23', 'Male',           '+1-555-0125', 'andre.silva@email.com',      '2025-01-07 09:00:00'),
    (26, 26, 'Mei',      'Li',         '1987-04-05', 'Female',         '+1-555-0126', 'mei.li@email.com',           '2025-01-15 10:45:00'),
    (27, 27, 'Kevin',    'Torres',     '2008-12-18', 'Male',           '+1-555-0127', 'kevin.torres@email.com',     '2025-02-01 09:30:00'),
    (28, 28, 'Sara',     'Mbeki',      '1972-08-07', 'Female',         '+1-555-0128', 'sara.mbeki@email.com',       '2025-02-18 11:00:00'),
    (29, 29, 'Daniel',   'Cruz',       '1961-05-26', 'Male',           '+1-555-0129', 'daniel.cruz@email.com',      '2025-03-04 14:00:00'),
    (30, 30, 'Isabelle', 'Laurent',    '1994-01-31', 'Female',         '+1-555-0130', 'isabelle.laurent@email.com', '2025-03-19 10:00:00');
SET IDENTITY_INSERT dbo.Patients OFF;
GO

SET IDENTITY_INSERT dbo.Doctors ON;
INSERT INTO dbo.Doctors (DoctorID, DepartmentID, FirstName, LastName, Phone, Email, Specialization, LicenseNumber) VALUES
    -- Cardiology (DepartmentID = 1)
    ( 1, 1, 'Wei',       'Chen',       '+1-555-0201', 'dr.wei.chen@hospital.com',       'Cardiologist',                'MD-IL-10011'),
    ( 2, 1, 'Adaeze',    'Okonkwo',    '+1-555-0202', 'dr.adaeze.okonkwo@hospital.com', 'Interventional Cardiologist', 'MD-IL-10012'),
    ( 3, 1, 'Stefan',    'Petrov',     '+1-555-0203', 'dr.stefan.petrov@hospital.com',  'Electrophysiologist',         'MD-IL-10013'),
    ( 4, 1, 'Yuna',      'Yamamoto',   '+1-555-0204', 'dr.yuna.yamamoto@hospital.com',  'Cardiologist',                'MD-IL-10014'),
    ( 5, 1, 'Omar',      'Hassan',     '+1-555-0205', 'dr.omar.hassan@hospital.com',    'Cardiologist',                'MD-IL-10015'),
    ( 6, 1, 'Claire',    'Dubois',     '+1-555-0206', 'dr.claire.dubois@hospital.com',  'Cardiac Surgeon',             'MD-IL-10016'),
    -- Orthopedics (DepartmentID = 2)
    ( 7, 2, 'Priya',     'Sharma',     '+1-555-0207', 'dr.priya.sharma@hospital.com',   'Orthopedic Surgeon',          'MD-IL-10022'),
    ( 8, 2, 'Marcus',    'Torres',     '+1-555-0208', 'dr.marcus.torres@hospital.com',  'Sports Medicine',             'MD-IL-10023'),
    ( 9, 2, 'Anya',      'Kowalski',   '+1-555-0209', 'dr.anya.kowalski@hospital.com',  'Spine Surgeon',               'MD-IL-10024'),
    (10, 2, 'Taro',      'Nakamura',   '+1-555-0210', 'dr.taro.nakamura@hospital.com',  'Joint Replacement Surgeon',   'MD-IL-10025'),
    (11, 2, 'Fatou',     'Mbeki',      '+1-555-0211', 'dr.fatou.mbeki@hospital.com',    'Orthopedic Surgeon',          'MD-IL-10026'),
    (12, 2, 'Lars',      'Eriksson',   '+1-555-0212', 'dr.lars.eriksson@hospital.com',  'Hand Surgeon',                'MD-IL-10027'),
    -- Neurology (DepartmentID = 3)
    (13, 3, 'Carlos',    'Vega',       '+1-555-0213', 'dr.carlos.vega@hospital.com',    'Neurologist',                 'MD-IL-10033'),
    (14, 3, 'Hiroko',    'Li',         '+1-555-0214', 'dr.hiroko.li@hospital.com',      'Epileptologist',              'MD-IL-10034'),
    (15, 3, 'Rashid',    'Rahman',     '+1-555-0215', 'dr.rashid.rahman@hospital.com',  'Neuro-Oncologist',            'MD-IL-10035'),
    (16, 3, 'Ingrid',    'Johansson',  '+1-555-0216', 'dr.ingrid.johansson@hospital.com','Stroke Specialist',          'MD-IL-10036'),
    (17, 3, 'Ben',       'Ali',        '+1-555-0217', 'dr.ben.ali@hospital.com',         'Neurologist',                'MD-IL-10037'),
    (18, 3, 'Mei',       'Mueller',    '+1-555-0218', 'dr.mei.mueller@hospital.com',     'Movement Disorder Specialist','MD-IL-10038'),
    -- Pediatrics (DepartmentID = 4)
    (19, 4, 'Nkechi',    'Mensah',     '+1-555-0219', 'dr.nkechi.mensah@hospital.com',  'Pediatrician',                'MD-IL-10044'),
    (20, 4, 'Lucas',     'Silva',      '+1-555-0220', 'dr.lucas.silva@hospital.com',    'Pediatric Surgeon',           'MD-IL-10045'),
    (21, 4, 'Hannah',    'Johansson',  '+1-555-0221', 'dr.hannah.johansson@hospital.com','Neonatologist',              'MD-IL-10046'),
    (22, 4, 'Kenji',     'Tanaka',     '+1-555-0222', 'dr.kenji.tanaka@hospital.com',   'Pediatric Cardiologist',      'MD-IL-10047'),
    (23, 4, 'Amina',     'Diallo',     '+1-555-0223', 'dr.amina.diallo@hospital.com',   'Pediatrician',                'MD-IL-10048'),
    (24, 4, 'Pierre',    'Laurent',    '+1-555-0224', 'dr.pierre.laurent@hospital.com', 'Pediatric Neurologist',       'MD-IL-10049'),
    -- Emergency (DepartmentID = 5)
    (25, 5, 'Ivan',      'Petrov',     '+1-555-0225', 'dr.ivan.petrov@hospital.com',    'Emergency Medicine',          'MD-IL-10055'),
    (26, 5, 'Zara',      'Hassan',     '+1-555-0226', 'dr.zara.hassan@hospital.com',    'Emergency Medicine',          'MD-IL-10056'),
    (27, 5, 'Marco',     'Cruz',       '+1-555-0227', 'dr.marco.cruz@hospital.com',     'Trauma Surgeon',              'MD-IL-10057'),
    (28, 5, 'Yuki',      'Nakamura',   '+1-555-0228', 'dr.yuki.nakamura@hospital.com',  'Emergency Medicine',          'MD-IL-10058'),
    (29, 5, 'Abena',     'Mensah',     '+1-555-0229', 'dr.abena.mensah@hospital.com',   'Critical Care Specialist',    'MD-IL-10059'),
    (30, 5, 'Viktor',    'Mueller',    '+1-555-0230', 'dr.viktor.mueller@hospital.com', 'Emergency Medicine',          'MD-IL-10060');
SET IDENTITY_INSERT dbo.Doctors OFF;
GO

-- ------------------------------------------------------------
-- Patient Supporting Data
-- ------------------------------------------------------------

SET IDENTITY_INSERT dbo.EmergencyContacts ON;
INSERT INTO dbo.EmergencyContacts (EmergencyContactID, PatientID, FullName, Relationship, Phone, Email) VALUES
    ( 1,  1, 'Linda Hartley',       'Spouse',  '+1-555-1001', 'linda.hartley@email.com'),
    ( 2,  2, 'Carlos Gonzalez',     'Father',  '+1-555-1002', 'carlos.g@email.com'),
    ( 3,  3, 'Amy Kim',             'Spouse',  '+1-555-1003', 'amy.kim@email.com'),
    ( 4,  4, 'Raj Patel',           'Father',  '+1-555-1004', 'raj.patel@email.com'),
    ( 5,  5, 'Nancy Thompson',      'Spouse',  '+1-555-1005', 'nancy.thompson@email.com'),
    ( 6,  6, 'Chidi Okonkwo',       'Brother', '+1-555-1006', 'chidi.okonkwo@email.com'),
    ( 7,  7, 'Siobhan O''Brien',    'Spouse',  '+1-555-1007', 'siobhan.obrien@email.com'),
    ( 8,  8, 'Kenji Yamamoto',      'Father',  '+1-555-1008', 'kenji.yamamoto@email.com'),
    ( 9,  9, 'Rosa Mendez',         'Sister',  '+1-555-1009', 'rosa.mendez@email.com'),
    (10, 10, 'Yusuf Al-Hassan',     'Spouse',  '+1-555-1010', 'yusuf.alhassan@email.com'),
    (11, 11, 'Claire Brooks',       'Mother',  '+1-555-1011', 'claire.brooks@email.com'),
    (12, 12, 'Erik Eriksson',       'Spouse',  '+1-555-1012', 'erik.eriksson@email.com'),
    (13, 13, 'Fatima Rahman',       'Daughter','+1-555-1013', 'fatima.rahman@email.com'),
    (14, 14, 'Henri Dubois',        'Father',  '+1-555-1014', 'henri.dubois@email.com'),
    (15, 15, 'Grace Mensah',        'Spouse',  '+1-555-1015', 'grace.mensah@email.com'),
    (16, 16, 'Alexei Petrov',       'Brother', '+1-555-1016', 'alexei.petrov@email.com'),
    (17, 17, 'Emiko Nakamura',      'Spouse',  '+1-555-1017', 'emiko.nakamura@email.com'),
    (18, 18, 'Boubacar Diallo',     'Father',  '+1-555-1018', 'boubacar.diallo@email.com'),
    (19, 19, 'Marta Kowalski',      'Spouse',  '+1-555-1019', 'marta.kowalski@email.com'),
    (20, 20, 'Hans Mueller',        'Spouse',  '+1-555-1020', 'hans.mueller@email.com'),
    (21, 21, 'Layla Ali',           'Sister',  '+1-555-1021', 'layla.ali@email.com'),
    (22, 22, 'Arjun Singh',         'Father',  '+1-555-1022', 'arjun.singh@email.com'),
    (23, 23, 'Britta Johansson',    'Spouse',  '+1-555-1023', 'britta.johansson@email.com'),
    (24, 24, 'Hiroshi Tanaka',      'Son',     '+1-555-1024', 'hiroshi.tanaka@email.com'),
    (25, 25, 'Camila Silva',        'Mother',  '+1-555-1025', 'camila.silva@email.com'),
    (26, 26, 'Wei Li',              'Spouse',  '+1-555-1026', 'wei.li@email.com'),
    (27, 27, 'Diana Torres',        'Mother',  '+1-555-1027', 'diana.torres@email.com'),
    (28, 28, 'Kofi Mbeki',          'Spouse',  '+1-555-1028', 'kofi.mbeki@email.com'),
    (29, 29, 'Elena Cruz',          'Spouse',  '+1-555-1029', 'elena.cruz@email.com'),
    (30, 30, 'Sebastien Laurent',   'Father',  '+1-555-1030', 'sebastien.laurent@email.com');
SET IDENTITY_INSERT dbo.EmergencyContacts OFF;
GO

SET IDENTITY_INSERT dbo.PatientInsurancePolicies ON;
INSERT INTO dbo.PatientInsurancePolicies (PatientInsuranceID, PatientID, InsuranceProviderID, PolicyNumber, CoveragePercent, ExpiryDate, IsPrimary) VALUES
    -- Primary policies (one per patient)
    ( 1,  1, 1, 'BC-2024-10101', 80.00, '2027-12-31', 1),
    ( 2,  2, 2, 'NM-2024-10202', 75.00, '2026-06-30', 1),
    ( 3,  3, 3, 'UH-2024-10303', 90.00, '2028-03-31', 1),
    ( 4,  4, 1, 'BC-2024-10404', 80.00, '2027-09-30', 1),
    ( 5,  5, 2, 'NM-2024-10505', 70.00, '2026-12-31', 1),
    ( 6,  6, 3, 'UH-2024-10606', 85.00, '2028-06-30', 1),
    ( 7,  7, 1, 'BC-2024-10707', 80.00, '2027-03-31', 1),
    ( 8,  8, 2, 'NM-2024-10808', 75.00, '2027-06-30', 1),
    ( 9,  9, 3, 'UH-2024-10909', 90.00, '2026-09-30', 1),
    (10, 10, 1, 'BC-2024-11010', 80.00, '2028-12-31', 1),
    (11, 11, 2, 'NM-2024-11111', 60.00, '2027-12-31', 1),
    (12, 12, 3, 'UH-2024-11212', 85.00, '2028-03-31', 1),
    (13, 13, 1, 'BC-2024-11313', 80.00, '2027-06-30', 1),
    (14, 14, 2, 'NM-2024-11414', 75.00, '2026-12-31', 1),
    (15, 15, 3, 'UH-2024-11515', 90.00, '2028-09-30', 1),
    (16, 16, 1, 'BC-2025-11616', 80.00, '2028-01-31', 1),
    (17, 17, 2, 'NM-2025-11717', 70.00, '2027-03-31', 1),
    (18, 18, 3, 'UH-2025-11818', 85.00, '2028-06-30', 1),
    (19, 19, 1, 'BC-2025-11919', 80.00, '2027-09-30', 1),
    (20, 20, 2, 'NM-2025-12020', 75.00, '2026-06-30', 1),
    (21, 21, 3, 'UH-2025-12121', 90.00, '2028-12-31', 1),
    (22, 22, 1, 'BC-2025-12222', 80.00, '2027-12-31', 1),
    (23, 23, 2, 'NM-2025-12323', 65.00, '2027-06-30', 1),
    (24, 24, 3, 'UH-2025-12424', 85.00, '2028-03-31', 1),
    (25, 25, 1, 'BC-2025-12525', 80.00, '2028-09-30', 1),
    -- Secondary policies for select patients
    (26,  1, 3, 'UH-2024-20101', 15.00, '2027-12-31', 0),
    (27,  5, 1, 'BC-2024-20505', 20.00, '2026-12-31', 0),
    (28, 10, 2, 'NM-2024-21010', 15.00, '2028-12-31', 0),
    (29, 15, 1, 'BC-2024-21515', 10.00, '2028-09-30', 0),
    (30, 20, 3, 'UH-2025-22020', 20.00, '2026-06-30', 0);
SET IDENTITY_INSERT dbo.PatientInsurancePolicies OFF;
GO

-- ------------------------------------------------------------
-- Scheduling
-- ------------------------------------------------------------

SET IDENTITY_INSERT dbo.Appointments ON;
INSERT INTO dbo.Appointments (AppointmentID, PatientID, DoctorID, CreatedByUserID, AppointmentDate, Status, Reason) VALUES
    ( 1,  1,  1,  3, '2026-04-10 09:00:00', 'Completed', 'Chest pain and shortness of breath'),
    ( 2,  2,  2,  3, '2026-04-12 10:30:00', 'Completed', 'Knee pain after sports injury'),
    ( 3,  3,  3,  3, '2026-04-15 14:00:00', 'Completed', 'Recurring migraines'),
    ( 4,  4,  1,  3, '2026-05-05 11:00:00', 'Scheduled', 'Follow-up cardiac checkup'),
    ( 5,  5,  2,  3, '2026-05-08 15:30:00', 'Scheduled', 'Lower back pain'),
    ( 6,  6,  4, 24, '2025-06-15 09:00:00', 'Completed', 'Annual physical examination'),
    ( 7,  7,  5, 25, '2025-07-03 10:30:00', 'Completed', 'Type 2 diabetes management follow-up'),
    ( 8,  8,  6, 26, '2025-07-18 14:00:00', 'Completed', 'Abdominal pain and nausea'),
    ( 9,  9,  7, 27, '2025-08-01 09:00:00', 'Cancelled', 'Routine blood pressure review'),
    (10, 10,  8, 28, '2025-08-14 11:30:00', 'Completed', 'Post-operative wound check'),
    (11, 11,  9, 29, '2025-09-02 13:00:00', 'No-Show',   'Fever and sore throat'),
    (12, 12, 10, 30, '2025-09-18 10:00:00', 'Completed', 'Prenatal checkup at 20 weeks'),
    (13, 13, 11, 24, '2025-10-07 15:30:00', 'Completed', 'Anxiety and sleep disorder evaluation'),
    (14, 14, 12, 25, '2025-10-22 08:30:00', 'Completed', 'Eczema and skin rash review'),
    (15, 15, 13, 26, '2025-11-04 11:00:00', 'Cancelled', 'Acid reflux and GERD symptoms'),
    (16, 16, 14, 27, '2025-11-20 09:30:00', 'Completed', 'Thyroid function and hormone levels review'),
    (17, 17, 15, 28, '2025-12-03 14:00:00', 'Completed', 'Persistent cough and breathlessness'),
    (18, 18, 16, 29, '2025-12-17 10:30:00', 'No-Show',   'Joint pain and morning stiffness'),
    (19, 19, 17, 30, '2026-01-08 13:00:00', 'Completed', 'Numbness and tingling in left hand'),
    (20, 20, 18, 24, '2026-01-22 09:00:00', 'Completed', 'Well-child visit and vaccinations'),
    (21, 21, 19, 25, '2026-02-05 11:30:00', 'Completed', 'Fatigue and chest tightness'),
    (22, 22, 20, 26, '2026-02-19 14:00:00', 'Completed', 'Knee pain and limited range of motion'),
    (23, 23, 21, 27, '2026-03-05 10:00:00', 'Cancelled', 'Epilepsy medication review'),
    (24, 24, 22, 28, '2026-03-19 09:30:00', 'Completed', 'Pelvic pain and gynecological examination'),
    (25, 25, 23, 29, '2026-04-02 13:30:00', 'Completed', 'Chemotherapy side effects consultation'),
    (26, 26, 24, 30, '2026-04-16 10:00:00', 'No-Show',   'Ultrasound for suspected gallstones'),
    (27, 27, 25, 24, '2026-04-28 14:30:00', 'Completed', 'Post-CT scan results review'),
    (28, 28, 26, 25, '2026-05-19 09:30:00', 'Scheduled', 'Hypertension medication adjustment'),
    (29, 29, 27, 26, '2026-05-26 11:00:00', 'Scheduled', 'Asthma control and inhaler technique review'),
    (30, 30, 28, 27, '2026-06-10 10:30:00', 'Scheduled', 'General health screening');
SET IDENTITY_INSERT dbo.Appointments OFF;
GO

-- ------------------------------------------------------------
-- Scheduling: Audit Trail
-- ------------------------------------------------------------
SET IDENTITY_INSERT dbo.AuditLogs ON;
INSERT INTO dbo.AuditLogs (AuditID, PerformedByUserID, TableName, ActionType, ActionDate, OldValue, NewValue) VALUES
    ( 1,  1, 'Patients',                 'INSERT', '2025-01-15 09:10:00', '{}',                                                             '{"PatientID":1,"FirstName":"James","LastName":"Hartley"}'),
    ( 2, 24, 'Appointments',             'INSERT', '2025-03-20 10:05:00', '{}',                                                             '{"AppointmentID":6,"PatientID":6,"Status":"Scheduled"}'),
    ( 3,  4, 'MedicalRecords',           'UPDATE', '2025-04-10 11:30:00', '{"Diagnosis":"Suspected angina"}',                             '{"Diagnosis":"Stable angina pectoris"}'),
    ( 4,  2, 'Users',                    'UPDATE', '2025-04-22 14:15:00', '{"IsActive":1}',                                                '{"IsActive":0}'),
    ( 5, 25, 'Appointments',             'UPDATE', '2025-05-03 09:45:00', '{"Status":"Scheduled"}',                                       '{"Status":"Cancelled"}'),
    ( 6,  5, 'Prescriptions',            'INSERT', '2025-05-15 13:00:00', '{}',                                                             '{"PrescriptionID":1,"DoctorID":5}'),
    ( 7,  1, 'Doctors',                  'INSERT', '2025-06-02 08:30:00', '{}',                                                             '{"DoctorID":15,"LastName":"Rahman","Specialization":"Pulmonology"}'),
    ( 8, 26, 'Patients',                 'UPDATE', '2025-06-18 10:20:00', '{"Phone":"+1-555-0108"}',                                      '{"Phone":"+1-555-9108"}'),
    ( 9,  3, 'InsuranceProviders',       'INSERT', '2025-07-01 09:00:00', '{}',                                                             '{"InsuranceProviderID":18,"ProviderName":"Bright Health"}'),
    (10,  6, 'MedicalRecords',           'INSERT', '2025-07-10 14:45:00', '{}',                                                             '{"RecordID":3,"AppointmentID":3,"Diagnosis":"Migraine"}'),
    (11, 27, 'Appointments',             'INSERT', '2025-07-22 11:00:00', '{}',                                                             '{"AppointmentID":10,"PatientID":10,"Status":"Scheduled"}'),
    (12,  2, 'ServiceCatalog',           'UPDATE', '2025-08-05 09:15:00', '{"StandardPrice":180.00}',                                     '{"StandardPrice":200.00}'),
    (13,  8, 'Prescriptions',            'UPDATE', '2025-08-19 13:30:00', '{"Dosage":"25 mg"}',                                          '{"Dosage":"50 mg"}'),
    (14, 28, 'Patients',                 'UPDATE', '2025-09-03 10:00:00', '{"Email":"lucas.kowalski@email.com"}',                        '{"Email":"l.kowalski@clinic.com"}'),
    (15,  1, 'Roles',                    'INSERT', '2025-09-15 14:20:00', '{}',                                                             '{"RoleID":8,"RoleName":"Billing Specialist"}'),
    (16,  3, 'Users',                    'INSERT', '2025-09-28 09:30:00', '{}',                                                             '{"UserID":30,"Username":"receptionist.young","RoleID":3}'),
    (17, 29, 'Bills',                    'UPDATE', '2025-10-12 11:45:00', '{"BillStatus":"Unpaid","PaidAmount":0.00}',                   '{"BillStatus":"Partial","PaidAmount":150.00}'),
    (18,  9, 'LabOrders',               'INSERT', '2025-10-25 14:00:00', '{}',                                                             '{"LabOrderID":2,"AppointmentID":1,"Status":"Pending"}'),
    (19,  2, 'Departments',             'UPDATE', '2025-11-06 08:45:00', '{"Location":"Building A - Floor 3"}',                         '{"Location":"Building A - Floor 3 (Renovated)"}'),
    (20,  4, 'MedicalRecords',           'UPDATE', '2025-11-18 10:30:00', '{"Notes":"Mild fatigue reported"}',                           '{"Notes":"Mild fatigue; improved with medication"}'),
    (21, 30, 'Appointments',             'DELETE', '2025-12-01 09:00:00', '{"AppointmentID":9,"Status":"Cancelled"}',                   '{}'),
    (22, 10, 'Prescriptions',            'INSERT', '2025-12-14 13:15:00', '{}',                                                             '{"PrescriptionID":2,"DoctorID":10}'),
    (23,  1, 'PatientInsurancePolicies', 'UPDATE', '2025-12-28 14:30:00', '{"ExpiryDate":"2025-12-31"}',                                 '{"ExpiryDate":"2026-12-31"}'),
    (24, 24, 'EmergencyContacts',        'INSERT', '2026-01-10 10:00:00', '{}',                                                             '{"EmergencyContactID":25,"PatientID":25}'),
    (25,  5, 'MedicalRecords',           'UPDATE', '2026-01-24 11:45:00', '{"Diagnosis":"Uncontrolled T2DM"}',                           '{"Diagnosis":"Type 2 DM - improved glycemic control"}'),
    (26,  3, 'LabTestCatalog',           'UPDATE', '2026-02-07 09:00:00', '{"StandardPrice":40.00}',                                     '{"StandardPrice":45.00}'),
    (27, 25, 'Appointments',             'INSERT', '2026-02-21 10:30:00', '{}',                                                             '{"AppointmentID":24,"PatientID":24,"Status":"Scheduled"}'),
    (28, 11, 'Prescriptions',            'UPDATE', '2026-03-07 14:00:00', '{"Duration":"30 days"}',                                     '{"Duration":"60 days"}'),
    (29,  2, 'Users',                    'DELETE', '2026-04-01 09:45:00', '{"UserID":19,"Username":"dr.johansson","IsActive":0}',      '{}'),
    (30, 26, 'Appointments',             'UPDATE', '2026-04-30 11:00:00', '{"Status":"Scheduled"}',                                     '{"Status":"Completed"}');
SET IDENTITY_INSERT dbo.AuditLogs OFF;
GO

-- ------------------------------------------------------------
-- Billing
-- ------------------------------------------------------------

SET IDENTITY_INSERT dbo.Bills ON;
INSERT INTO dbo.Bills (BillID, PatientID, AppointmentID, TotalAmount, PaidAmount, Balance, BillStatus, CreatedDate) VALUES
    ( 1,  1,  1,  350.00,  350.00,    0.00, 'Paid',    '2026-04-10 10:00:00'),
    ( 2,  2,  2,  250.00,  150.00,  100.00, 'Partial', '2026-04-12 11:30:00'),
    ( 3,  3,  3,  150.00,    0.00,  150.00, 'Unpaid',  '2026-04-15 15:00:00'),
    ( 4,  4,  4,  150.00,    0.00,  150.00, 'Unpaid',  '2026-05-05 12:00:00'),
    ( 5,  5,  5,  150.00,    0.00,  150.00, 'Unpaid',  '2026-05-08 16:30:00'),
    ( 6,  6,  6,  150.00,  150.00,    0.00, 'Paid',    '2025-06-15 10:00:00'),
    ( 7,  7,  7,  250.00,  250.00,    0.00, 'Paid',    '2025-07-03 11:30:00'),
    ( 8,  8,  8,  300.00,  150.00,  150.00, 'Partial', '2025-07-18 15:00:00'),
    ( 9,  9,  9,  150.00,    0.00,  150.00, 'Unpaid',  '2025-08-01 10:00:00'),
    (10, 10, 10,  500.00,  500.00,    0.00, 'Paid',    '2025-08-14 12:30:00'),
    (11, 11, 11,   60.00,    0.00,   60.00, 'Unpaid',  '2025-09-02 14:00:00'),
    (12, 12, 12,  280.00,  280.00,    0.00, 'Paid',    '2025-09-18 11:00:00'),
    (13, 13, 13,  300.00,  150.00,  150.00, 'Partial', '2025-10-07 16:30:00'),
    (14, 14, 14,  150.00,  150.00,    0.00, 'Paid',    '2025-10-22 09:30:00'),
    (15, 15, 15,  150.00,    0.00,  150.00, 'Unpaid',  '2025-11-04 12:00:00'),
    (16, 16, 16,  250.00,  250.00,    0.00, 'Paid',    '2025-11-20 10:30:00'),
    (17, 17, 17,  220.00,  110.00,  110.00, 'Partial', '2025-12-03 15:00:00'),
    (18, 18, 18,   60.00,    0.00,   60.00, 'Unpaid',  '2025-12-17 11:30:00'),
    (19, 19, 19,  250.00,  250.00,    0.00, 'Paid',    '2026-01-08 14:00:00'),
    (20, 20, 20,  150.00,  150.00,    0.00, 'Paid',    '2026-01-22 10:00:00'),
    (21, 21, 21,  200.00,  100.00,  100.00, 'Partial', '2026-02-05 12:30:00'),
    (22, 22, 22,  120.00,  120.00,    0.00, 'Paid',    '2026-02-19 15:00:00'),
    (23, 23, 23,  150.00,    0.00,  150.00, 'Unpaid',  '2026-03-05 11:00:00'),
    (24, 24, 24,  280.00,  280.00,    0.00, 'Paid',    '2026-03-19 10:30:00'),
    (25, 25, 25,  250.00,  125.00,  125.00, 'Partial', '2026-04-02 14:30:00'),
    (26, 26, 26,   60.00,    0.00,   60.00, 'Unpaid',  '2026-04-16 11:00:00'),
    (27, 27, 27,  800.00,  800.00,    0.00, 'Paid',    '2026-04-28 15:30:00'),
    (28, 28, 28,  150.00,    0.00,  150.00, 'Unpaid',  '2026-05-19 10:00:00'),
    (29, 29, 29,  150.00,    0.00,  150.00, 'Unpaid',  '2026-05-26 12:00:00'),
    (30, 30, 30,  150.00,    0.00,  150.00, 'Unpaid',  '2026-06-10 11:30:00');
SET IDENTITY_INSERT dbo.Bills OFF;
GO

SET IDENTITY_INSERT dbo.BillItems ON;
INSERT INTO dbo.BillItems (BillItemID, BillID, ServiceID, Quantity, UnitPrice, LineTotal) VALUES
    ( 1,  1,  5, 1,  350.00,  350.00),  -- Emergency Room Visit
    ( 2,  2,  6, 1,  250.00,  250.00),  -- Specialist Consultation
    ( 3,  3,  1, 1,  150.00,  150.00),  -- General Consultation
    ( 4,  4,  1, 1,  150.00,  150.00),  -- General Consultation
    ( 5,  5,  1, 1,  150.00,  150.00),  -- General Consultation
    ( 6,  6,  1, 1,  150.00,  150.00),  -- General Consultation
    ( 7,  7,  6, 1,  250.00,  250.00),  -- Specialist Consultation
    ( 8,  8,  9, 1,  300.00,  300.00),  -- Ultrasound (Abdominal)
    ( 9,  9,  1, 1,  150.00,  150.00),  -- General Consultation
    (10, 10, 15, 1,  500.00,  500.00),  -- Minor Surgical Procedure
    (11, 11, 24, 1,   60.00,   60.00),  -- Vaccination / Immunization
    (12, 12, 10, 1,  280.00,  280.00),  -- Ultrasound (Obstetric)
    (13, 13, 22, 1,  300.00,  300.00),  -- Psychiatric Evaluation
    (14, 14,  1, 1,  150.00,  150.00),  -- General Consultation
    (15, 15,  1, 1,  150.00,  150.00),  -- General Consultation
    (16, 16,  6, 1,  250.00,  250.00),  -- Specialist Consultation
    (17, 17, 12, 1,  220.00,  220.00),  -- Pulmonary Function Test
    (18, 18, 24, 1,   60.00,   60.00),  -- Vaccination / Immunization
    (19, 19,  6, 1,  250.00,  250.00),  -- Specialist Consultation
    (20, 20,  1, 1,  150.00,  150.00),  -- General Consultation
    (21, 21,  2, 1,  200.00,  200.00),  -- ECG / EKG
    (22, 22,  3, 1,  120.00,  120.00),  -- X-Ray (Single View)
    (23, 23,  1, 1,  150.00,  150.00),  -- General Consultation
    (24, 24, 10, 1,  280.00,  280.00),  -- Ultrasound (Obstetric)
    (25, 25,  6, 1,  250.00,  250.00),  -- Specialist Consultation
    (26, 26, 24, 1,   60.00,   60.00),  -- Vaccination / Immunization
    (27, 27,  7, 1,  800.00,  800.00),  -- CT Scan (Without Contrast)
    (28, 28,  1, 1,  150.00,  150.00),  -- General Consultation
    (29, 29,  1, 1,  150.00,  150.00),  -- General Consultation
    (30, 30,  1, 1,  150.00,  150.00);  -- General Consultation
SET IDENTITY_INSERT dbo.BillItems OFF;
GO

SET IDENTITY_INSERT dbo.Payments ON;
INSERT INTO dbo.Payments (PaymentID, BillID, PaymentDate, Amount, PaymentMethod, ReferenceNumber) VALUES
    -- Bill  1 (350.00 Paid   — 2 instalments)
    ( 1,  1, '2026-04-10 10:30:00',  200.00, 'Credit Card',    'TXN-2026-0001'),
    ( 2,  1, '2026-04-11 09:00:00',  150.00, 'Insurance',      'TXN-2026-0002'),
    -- Bill  2 (250.00 Partial — 1 payment)
    ( 3,  2, '2026-04-12 12:00:00',  150.00, 'Cash',           'TXN-2026-0003'),
    -- Bill  6 (150.00 Paid   — 2 instalments)
    ( 4,  6, '2025-06-15 10:30:00',  100.00, 'Cash',           'TXN-2025-0001'),
    ( 5,  6, '2025-06-22 09:00:00',   50.00, 'Cash',           'TXN-2025-0002'),
    -- Bill  7 (250.00 Paid   — 2 instalments)
    ( 6,  7, '2025-07-03 12:00:00',  150.00, 'Credit Card',    'TXN-2025-0003'),
    ( 7,  7, '2025-07-10 09:00:00',  100.00, 'Debit Card',     'TXN-2025-0004'),
    -- Bill  8 (300.00 Partial — 1 payment)
    ( 8,  8, '2025-07-18 15:30:00',  150.00, 'Debit Card',     'TXN-2025-0005'),
    -- Bill 10 (500.00 Paid   — 2 instalments)
    ( 9, 10, '2025-08-14 13:00:00',  300.00, 'Insurance',      'TXN-2025-0006'),
    (10, 10, '2025-08-21 09:00:00',  200.00, 'Credit Card',    'TXN-2025-0007'),
    -- Bill 12 (280.00 Paid   — 2 instalments)
    (11, 12, '2025-09-18 11:30:00',  180.00, 'Insurance',      'TXN-2025-0008'),
    (12, 12, '2025-09-25 09:00:00',  100.00, 'Cash',           'TXN-2025-0009'),
    -- Bill 13 (300.00 Partial — 1 payment)
    (13, 13, '2025-10-07 17:00:00',  150.00, 'Credit Card',    'TXN-2025-0010'),
    -- Bill 14 (150.00 Paid   — 2 instalments)
    (14, 14, '2025-10-22 10:00:00',   80.00, 'Credit Card',    'TXN-2025-0011'),
    (15, 14, '2025-10-29 09:00:00',   70.00, 'Cash',           'TXN-2025-0012'),
    -- Bill 16 (250.00 Paid   — 2 instalments)
    (16, 16, '2025-11-20 11:00:00',  150.00, 'Debit Card',     'TXN-2025-0013'),
    (17, 16, '2025-11-27 09:00:00',  100.00, 'Credit Card',    'TXN-2025-0014'),
    -- Bill 17 (220.00 Partial — 1 payment)
    (18, 17, '2025-12-03 15:30:00',  110.00, 'Insurance',      'TXN-2025-0015'),
    -- Bill 19 (250.00 Paid   — 2 instalments)
    (19, 19, '2026-01-08 14:30:00',  130.00, 'Cash',           'TXN-2026-0004'),
    (20, 19, '2026-01-15 09:00:00',  120.00, 'Credit Card',    'TXN-2026-0005'),
    -- Bill 20 (150.00 Paid   — 2 instalments)
    (21, 20, '2026-01-22 10:30:00',  100.00, 'Insurance',      'TXN-2026-0006'),
    (22, 20, '2026-01-29 09:00:00',   50.00, 'Cash',           'TXN-2026-0007'),
    -- Bill 21 (200.00 Partial — 1 payment)
    (23, 21, '2026-02-05 13:00:00',  100.00, 'Credit Card',    'TXN-2026-0008'),
    -- Bill 22 (120.00 Paid   — 2 instalments)
    (24, 22, '2026-02-19 15:30:00',   70.00, 'Debit Card',     'TXN-2026-0009'),
    (25, 22, '2026-02-26 09:00:00',   50.00, 'Cash',           'TXN-2026-0010'),
    -- Bill 24 (280.00 Paid   — 2 instalments)
    (26, 24, '2026-03-19 11:00:00',  180.00, 'Credit Card',    'TXN-2026-0011'),
    (27, 24, '2026-03-26 09:00:00',  100.00, 'Insurance',      'TXN-2026-0012'),
    -- Bill 25 (250.00 Partial — 1 payment)
    (28, 25, '2026-04-02 15:00:00',  125.00, 'Cash',           'TXN-2026-0013'),
    -- Bill 27 (800.00 Paid   — 2 instalments)
    (29, 27, '2026-04-28 16:00:00',  500.00, 'Insurance',      'TXN-2026-0014'),
    (30, 27, '2026-05-05 09:00:00',  300.00, 'Credit Card',    'TXN-2026-0015');
SET IDENTITY_INSERT dbo.Payments OFF;
GO

-- ------------------------------------------------------------
-- Clinical Records
-- ------------------------------------------------------------

SET IDENTITY_INSERT dbo.MedicalRecords ON;
INSERT INTO dbo.MedicalRecords (RecordID, AppointmentID, Diagnosis, Notes, TreatmentPlan, CreatedDate) VALUES
    -- Appointments 1-3 (Apr 2026 — Cardiology, Orthopaedics, Neurology)
    ( 1,  1, 'Stable angina',
        'Patient reports intermittent chest tightness during exertion. BP 135/88.',
        'Prescribe nitroglycerin. Lifestyle modification. Follow up in 4 weeks.',
        '2026-04-10 09:45:00'),
    ( 2,  2, 'Grade II knee sprain',
        'Swelling and tenderness around the medial collateral ligament.',
        'RICE protocol. Physical therapy referral. Review in 3 weeks.',
        '2026-04-12 11:00:00'),
    ( 3,  3, 'Migraine without aura',
        'Frequency: 3-4 episodes/month lasting 6-12 hours. No aura reported.',
        'Sumatriptan 50mg PRN. Avoid known triggers. Headache diary recommended.',
        '2026-04-15 14:30:00'),
    -- Appointment 6 (Jun 2025 — Annual physical)
    ( 4,  6, 'Annual physical - within normal limits',
        'BP 118/76, HR 72 bpm, BMI 23.4. No significant findings. Immunisations up to date.',
        'Continue healthy diet and exercise. Preventive lipid-lowering therapy initiated. Review in 12 months.',
        '2025-06-15 09:45:00'),
    -- Appointment 7 (Jul 2025 — T2DM management)
    ( 5,  7, 'Type 2 diabetes mellitus - suboptimal glycaemic control',
        'HbA1c 7.8%. Fasting glucose 142 mg/dL. No signs of nephropathy or retinopathy at this visit.',
        'Increase Metformin to 1000mg twice daily. Dietary counselling referral. HbA1c recheck in 3 months.',
        '2025-07-03 11:15:00'),
    -- Appointment 8 (Jul 2025 — Abdominal pain)
    ( 6,  8, 'Acute gastroenteritis',
        'Patient presents with 2-day history of nausea, vomiting, and watery diarrhoea. Mild dehydration noted. Temp 37.9 degrees C.',
        'Oral rehydration. Ondansetron for nausea. Clear fluids diet. Return if symptoms worsen or persist beyond 5 days.',
        '2025-07-18 14:45:00'),
    -- Appointment 10 (Aug 2025 — Post-op wound)
    ( 7, 10, 'Post-operative wound check - healing satisfactorily',
        'Wound site clean, no erythema or discharge. Sutures intact. Patient reports mild itching only.',
        'Continue dry dressing changes. Suture removal at next visit in 1 week. No antibiotics indicated.',
        '2025-08-14 12:00:00'),
    -- Appointment 12 (Sep 2025 — Prenatal)
    ( 8, 12, 'Uncomplicated pregnancy - 20 weeks gestation',
        'Fundal height 20 cm. FHR 148 bpm. Anomaly scan normal. BP 110/70. No oedema.',
        'Continue folic acid and prenatal vitamins. Glucose tolerance test at 24-28 weeks. Next scan at 32 weeks.',
        '2025-09-18 10:45:00'),
    -- Appointment 13 (Oct 2025 — Psychiatry)
    ( 9, 13, 'Generalised anxiety disorder (GAD)',
        'Patient reports persistent worry, sleep disturbance, and irritability for 4+ months. GAD-7 score: 14 (moderate-severe).',
        'Initiate Sertraline 50mg. Lorazepam PRN for acute episodes. CBT referral placed. Review in 4 weeks.',
        '2025-10-07 16:00:00'),
    -- Appointment 14 (Oct 2025 — Dermatology)
    (10, 14, 'Atopic dermatitis - moderate flare',
        'Widespread erythematous plaques on bilateral antecubital fossae and neck. EASI score 18. No secondary infection.',
        'Topical hydrocortisone 1% twice daily. Cetirizine for itch. Emollient moisturiser after bathing. Review in 4 weeks.',
        '2025-10-22 09:15:00'),
    -- Appointment 16 (Nov 2025 — Endocrinology)
    (11, 16, 'Primary hypothyroidism',
        'TSH 8.5 mIU/L (elevated). Free T4 0.7 ng/dL (low). Patient reports fatigue, cold intolerance, and weight gain of 4 kg over 3 months.',
        'Initiate levothyroxine 50 mcg once daily on empty stomach. Recheck TFTs in 6-8 weeks. Calcium supplement advised.',
        '2025-11-20 10:15:00'),
    -- Appointment 17 (Dec 2025 — Pulmonology)
    (12, 17, 'Moderate COPD exacerbation',
        'SpO2 91% on room air. FEV1/FVC ratio 0.62. Increased sputum production. Bilateral wheeze on auscultation.',
        'Salbutamol inhaler 2 puffs q4h PRN. Prednisolone 40mg for 7 days. Pulmonary rehab referral. Review in 2 weeks.',
        '2025-12-03 14:30:00'),
    -- Appointment 19 (Jan 2026 — Neurology)
    (13, 19, 'Carpal tunnel syndrome - right hand',
        'Positive Tinel''s and Phalen''s signs right wrist. Nocturnal paraesthesias for 3 months. Grip strength mildly reduced.',
        'Wrist splint at night. Ibuprofen 400mg BD with food. Pyridoxine 100mg daily. Nerve conduction study ordered. Review 6 weeks.',
        '2026-01-08 13:30:00'),
    -- Appointment 20 (Jan 2026 — Paediatrics)
    (14, 20, 'Well-child visit - normal growth and development',
        'Height 112 cm (50th percentile), weight 19.5 kg (55th percentile). Developmental milestones met. No parental concerns.',
        'Vaccinations administered per schedule. Continue balanced diet and adequate sleep. Next well-child visit at 6 years.',
        '2026-01-22 09:30:00'),
    -- Appointment 21 (Feb 2026 — Cardiology)
    (15, 21, 'Paroxysmal atrial fibrillation',
        'Irregular pulse 88 bpm. ECG confirms AF. CHA2DS2-VASc score 2. No haemodynamic compromise at this visit.',
        'Initiate apixaban 5mg twice daily for stroke prevention. Bisoprolol 2.5mg for rate control. Cardiology referral placed.',
        '2026-02-05 12:00:00'),
    -- Appointment 22 (Feb 2026 — Orthopaedics)
    (16, 22, 'Osteoarthritis - right knee',
        'Crepitus and restricted range of motion on right knee examination. Kellgren-Lawrence grade II on X-ray.',
        'Physiotherapy referral. Weight management counselling. Ibuprofen topical gel PRN. Review in 8 weeks.',
        '2026-02-19 14:30:00'),
    -- Appointment 24 (Mar 2026 — OB/GYN)
    (17, 24, 'Symptomatic uterine fibroids',
        'Ultrasound confirms multiple intramural fibroids, largest 3.2 cm. Heavy menstrual bleeding and pelvic discomfort reported.',
        'Tranexamic acid during menses. Ibuprofen for dysmenorrhoea. GnRH agonist therapy discussed. Gynaecology follow-up 8 weeks.',
        '2026-03-19 10:00:00'),
    -- Appointment 25 (Apr 2026 — Oncology)
    (18, 25, 'Chemotherapy-related nausea and fatigue - Cycle 4',
        'Patient tolerating Cycle 4 of CHOP regimen. Grade 2 nausea and fatigue reported. No neutropenic fever. CBC and CRP pending.',
        'Ondansetron and dexamethasone pre-medication at next cycle. Dietary support consult. Fatigue management plan reviewed.',
        '2026-04-02 14:00:00'),
    -- Appointment 27 (Apr 2026 — Radiology review)
    (19, 27, 'Incidental pulmonary nodule - low malignancy suspicion',
        'CT chest shows 6mm right upper lobe nodule, smooth margins. No lymphadenopathy. Non-smoker. Concurrent mild productive cough.',
        'Low-risk Fleischner pathway: CT follow-up in 12 months. Short azithromycin course for mild respiratory infection. Vitamin D supplement.',
        '2026-04-28 15:00:00');
SET IDENTITY_INSERT dbo.MedicalRecords OFF;
GO

SET IDENTITY_INSERT dbo.Prescriptions ON;
INSERT INTO dbo.Prescriptions (PrescriptionID, RecordID, DoctorID, PrescriptionDate) VALUES
    ( 1,  1,  1, '2026-04-10'),  -- Stable angina          (Appt  1, Dr 1)
    ( 2,  3,  3, '2026-04-15'),  -- Migraine               (Appt  3, Dr 3)
    ( 3,  2,  2, '2026-04-12'),  -- Knee sprain            (Appt  2, Dr 2)
    ( 4,  5,  5, '2025-07-03'),  -- T2DM management        (Appt  7, Dr 5)
    ( 5,  6,  6, '2025-07-18'),  -- Gastroenteritis        (Appt  8, Dr 6)
    ( 6,  9, 11, '2025-10-07'),  -- Anxiety disorder       (Appt 13, Dr 11)
    ( 7, 10, 12, '2025-10-22'),  -- Atopic dermatitis      (Appt 14, Dr 12)
    ( 8, 11, 14, '2025-11-20'),  -- Hypothyroidism         (Appt 16, Dr 14)
    ( 9, 12, 15, '2025-12-03'),  -- COPD exacerbation      (Appt 17, Dr 15)
    (10, 13, 17, '2026-01-08'),  -- Carpal tunnel          (Appt 19, Dr 17)
    (11, 15, 19, '2026-02-05'),  -- Atrial fibrillation    (Appt 21, Dr 19)
    (12, 17, 22, '2026-03-19'),  -- Uterine fibroids       (Appt 24, Dr 22)
    (13, 18, 23, '2026-04-02'),  -- Chemo nausea           (Appt 25, Dr 23)
    (14, 19, 25, '2026-04-28'),  -- Pulmonary nodule       (Appt 27, Dr 25)
    (15,  4,  4, '2025-06-15');  -- Annual physical        (Appt  6, Dr 4)
SET IDENTITY_INSERT dbo.Prescriptions OFF;
GO

SET IDENTITY_INSERT dbo.PrescriptionItems ON;
INSERT INTO dbo.PrescriptionItems (PrescriptionItemID, PrescriptionID, MedicationName, Dosage, Frequency, Duration) VALUES
    -- Prescription  1: Stable angina
    ( 1,  1, 'Nitroglycerin',           '0.4 mg sublingual',   'As needed for chest pain',                  '30 days'),
    ( 2,  1, 'Aspirin',                 '81 mg',               'Once daily',                                '90 days'),
    -- Prescription  2: Migraine without aura
    ( 3,  2, 'Sumatriptan',             '50 mg',               'At onset of migraine',                      '30 days'),
    ( 4,  2, 'Metoprolol',              '25 mg',               'Once daily at bedtime',                     '60 days'),
    -- Prescription  3: Grade II knee sprain
    ( 5,  3, 'Ibuprofen',               '400 mg',              'Three times daily with food',               '14 days'),
    ( 6,  3, 'Acetaminophen',           '500 mg',              'As needed for pain (max 4 g/day)',           '14 days'),
    -- Prescription  4: T2DM management
    ( 7,  4, 'Metformin',               '500 mg',              'Twice daily with meals',                    '90 days'),
    ( 8,  4, 'Lisinopril',              '5 mg',                'Once daily in the morning',                 '90 days'),
    -- Prescription  5: Acute gastroenteritis
    ( 9,  5, 'Ondansetron',             '4 mg',                'Every 8 hours as needed for nausea',        '5 days'),
    (10,  5, 'Oral Rehydration Salts',  '1 sachet in 200 mL',  'After each loose stool',                    '3 days'),
    -- Prescription  6: Generalised anxiety disorder
    (11,  6, 'Sertraline',              '50 mg',               'Once daily in the morning',                 '30 days'),
    (12,  6, 'Lorazepam',               '0.5 mg',              'As needed for acute anxiety (max 2/day)',   '14 days'),
    -- Prescription  7: Atopic dermatitis
    (13,  7, 'Hydrocortisone 1% Cream', 'Thin layer',          'Twice daily to affected areas',             '28 days'),
    (14,  7, 'Cetirizine',              '10 mg',               'Once daily at bedtime',                     '30 days'),
    -- Prescription  8: Primary hypothyroidism
    (15,  8, 'Levothyroxine',           '50 mcg',              'Once daily on empty stomach',               '90 days'),
    (16,  8, 'Calcium Carbonate',       '500 mg',              'Once daily with evening meal',              '90 days'),
    -- Prescription  9: COPD exacerbation
    (17,  9, 'Salbutamol Inhaler',      '100 mcg (2 puffs)',   'Every 4 hours as needed',                  '14 days'),
    (18,  9, 'Prednisolone',            '40 mg',               'Once daily in the morning',                 '7 days'),
    -- Prescription 10: Carpal tunnel syndrome
    (19, 10, 'Ibuprofen',               '400 mg',              'Twice daily with food',                     '21 days'),
    (20, 10, 'Pyridoxine (Vitamin B6)', '100 mg',              'Once daily',                                '60 days'),
    -- Prescription 11: Paroxysmal atrial fibrillation
    (21, 11, 'Apixaban',                '5 mg',                'Twice daily',                               '90 days'),
    (22, 11, 'Bisoprolol',              '2.5 mg',              'Once daily in the morning',                 '90 days'),
    -- Prescription 12: Uterine fibroids
    (23, 12, 'Tranexamic Acid',         '500 mg',              'Three times daily during menstruation',     '5 days per cycle'),
    (24, 12, 'Ibuprofen',               '400 mg',              'Three times daily during menstruation',     '5 days per cycle'),
    -- Prescription 13: Chemotherapy-related nausea
    (25, 13, 'Ondansetron',             '8 mg',                '30 min before chemotherapy, then every 8h', 'Per cycle'),
    (26, 13, 'Dexamethasone',           '8 mg',                '30 min before chemotherapy',                'Per cycle'),
    -- Prescription 14: Pulmonary nodule / concurrent infection
    (27, 14, 'Azithromycin',            '500 mg',              'Once daily',                                '5 days'),
    (28, 14, 'Vitamin D3',              '2000 IU',             'Once daily with food',                      '90 days'),
    -- Prescription 15: Annual physical (preventive)
    (29, 15, 'Atorvastatin',            '10 mg',               'Once daily at bedtime',                     '90 days'),
    (30, 15, 'Aspirin',                 '81 mg',               'Once daily with breakfast',                 '90 days');
SET IDENTITY_INSERT dbo.PrescriptionItems OFF;
GO

SET IDENTITY_INSERT dbo.LabOrders ON;
INSERT INTO dbo.LabOrders (LabOrderID, AppointmentID, LabTestTypeID, Result, Status, DateRequested) VALUES
    -- Appointment 1: Chest pain / stable angina
    ( 1,  1,  1, 'WBC: 6.8 K/uL, RBC: 4.5 M/uL, Hgb: 13.8 g/dL - Within normal range',                            'Completed', '2026-04-10 09:30:00'),
    ( 2,  1,  3, 'Total Cholesterol: 210 mg/dL, LDL: 130 mg/dL, HDL: 55 mg/dL - Borderline high LDL',               'Completed', '2026-04-10 09:30:00'),
    ( 3,  1, 12, 'Troponin I: 0.02 ng/mL - Within normal range (ref <0.04 ng/mL). ACS not indicated.',               'Completed', '2026-04-10 09:30:00'),
    -- Appointment 3: Migraine
    ( 4,  3,  2, 'Sodium: 139 mEq/L, Potassium: 4.1 mEq/L, Glucose: 92 mg/dL, Creatinine: 0.9 mg/dL - Normal',     'Completed', '2026-04-15 14:00:00'),
    -- Appointment 6: Annual physical
    ( 5,  6,  1, 'WBC: 7.2 K/uL, RBC: 4.8 M/uL, Hgb: 14.5 g/dL, Platelets: 245 K/uL - All within normal limits',  'Completed', '2025-06-15 09:15:00'),
    ( 6,  6,  6, 'ALT: 22 U/L, AST: 19 U/L, Creatinine: 0.8 mg/dL, Glucose: 88 mg/dL - All within normal limits',   'Completed', '2025-06-15 09:15:00'),
    ( 7,  6,  3, 'Total Cholesterol: 185 mg/dL, LDL: 112 mg/dL, HDL: 58 mg/dL, TG: 95 mg/dL - Optimal profile',     'Completed', '2025-06-15 09:15:00'),
    ( 8,  6,  7, 'HbA1c: 5.4% - Normal (non-diabetic range)',                                                         'Completed', '2025-06-15 09:15:00'),
    ( 9,  6,  4, 'TSH: 2.1 mIU/L - Within normal range (0.4-4.0 mIU/L)',                                             'Completed', '2025-06-15 09:15:00'),
    (10,  6,  5, 'Colour: Yellow, Clarity: Clear, Glucose: Negative, Protein: Negative - Normal urinalysis',          'Completed', '2025-06-15 09:15:00'),
    -- Appointment 7: T2DM management follow-up
    (11,  7,  7, 'HbA1c: 7.8% - Elevated; target <7.0%. Medication adjustment recommended.',                          'Completed', '2025-07-03 10:45:00'),
    (12,  7,  2, 'Glucose: 142 mg/dL (fasting, elevated), Creatinine: 1.0 mg/dL, eGFR: 85 mL/min - Hyperglycaemia', 'Completed', '2025-07-03 10:45:00'),
    (13,  7,  5, 'Glucose: 2+ in urine, Protein: Trace - Glycosuria correlates with elevated blood glucose',          'Completed', '2025-07-03 10:45:00'),
    -- Appointment 8: Abdominal pain
    (14,  8,  1, 'WBC: 12.8 K/uL (elevated), Neutrophils: 78% - Leukocytosis consistent with infection',             'Completed', '2025-07-18 14:15:00'),
    (15,  8,  6, 'ALT: 68 U/L (mildly elevated), AST: 54 U/L (mildly elevated), Bilirubin: Normal - Monitor LFTs',  'Completed', '2025-07-18 14:15:00'),
    (16,  8, 14, 'CRP: 48.2 mg/L (elevated; ref <10 mg/L) - Consistent with acute inflammatory process',             'Completed', '2025-07-18 14:15:00'),
    -- Appointment 10: Post-operative wound check
    (17, 10,  1, 'WBC: 8.1 K/uL, Hgb: 12.9 g/dL - Within acceptable post-operative range',                          'Completed', '2025-08-14 12:15:00'),
    (18, 10, 15, 'ESR: 28 mm/hr (mildly elevated) - Residual post-operative inflammatory response; improving trend',  'Completed', '2025-08-14 12:15:00'),
    -- Appointment 12: Prenatal 20 weeks
    (19, 12,  1, 'WBC: 9.4 K/uL, Hgb: 10.8 g/dL (low), MCV: 78 fL - Mild iron-deficiency anaemia in pregnancy',    'Completed', '2025-09-18 10:30:00'),
    (20, 12, 23, 'HBsAg: Non-reactive - Hepatitis B surface antigen not detected',                                    'Completed', '2025-09-18 10:30:00'),
    -- Appointment 13: Anxiety evaluation
    (21, 13,  4, 'TSH: 1.8 mIU/L - Normal; thyroid dysfunction excluded as underlying aetiology',                    'Completed', '2025-10-07 15:45:00'),
    (22, 13,  6, 'ALT, AST, electrolytes, glucose all within normal limits - No organic cause identified',            'Completed', '2025-10-07 15:45:00'),
    -- Appointment 16: Thyroid review
    (23, 16,  4, 'TSH: 8.5 mIU/L (elevated; ref 0.4-4.0 mIU/L) - Confirms primary hypothyroidism',                  'Completed', '2025-11-20 10:00:00'),
    (24, 16, 30, 'Free T4: 0.7 ng/dL (low; ref 0.8-1.8 ng/dL) - Consistent with hypothyroidism. Levothyroxine initiated.', 'Completed', '2025-11-20 10:00:00'),
    -- Appointment 17: COPD exacerbation
    (25, 17,  1, 'WBC: 11.2 K/uL (mildly elevated), RBC: 5.8 M/uL, Hgb: 17.4 g/dL - Polycythaemia consistent with chronic hypoxia', 'Completed', '2025-12-03 14:15:00'),
    (26, 17, 27, 'pH: 7.34, pO2: 61 mmHg (low), pCO2: 50 mmHg (elevated), HCO3: 27 mEq/L - Hypoxaemic respiratory failure', 'Completed', '2025-12-03 14:15:00'),
    -- Appointment 21: Atrial fibrillation
    (27, 21, 12, 'Troponin I: 0.09 ng/mL (borderline elevated; ref <0.04) - Serial troponins recommended',           'Completed', '2026-02-05 11:45:00'),
    (28, 21,  8, 'PT: 13.2 sec, INR: 1.1 - Normal; anticoagulation not yet initiated at time of test',               'Completed', '2026-02-05 11:45:00'),
    -- Appointment 25: Chemotherapy monitoring (Cycle 4)
    (29, 25,  1, NULL, 'Pending', '2026-04-02 14:15:00'),
    (30, 25, 14, NULL, 'Pending', '2026-04-02 14:15:00');
SET IDENTITY_INSERT dbo.LabOrders OFF;
GO

-- ------------------------------------------------------------
-- System: Error Logs
-- ------------------------------------------------------------
SET IDENTITY_INSERT dbo.ErrorLogs ON;
INSERT INTO dbo.ErrorLogs (ErrorID, ProcedureName, ErrorMessage, ErrorDate) VALUES
    ( 1, 'usp_CreateAppointment',      'The INSERT statement conflicted with the FOREIGN KEY constraint "FK_Appointments_Doctors". The conflict occurred in table "dbo.Doctors", column "DoctorID".',                       '2025-01-03 08:14:22'),
    ( 2, 'usp_ProcessPayment',         'Violation of UNIQUE KEY constraint ''UQ_Payments_BillID''. Cannot insert duplicate key in object ''dbo.Payments''. The duplicate key value is (42).',                           '2025-01-11 14:27:05'),
    ( 3, 'usp_LoginUser',              'Cannot insert the value NULL into column ''PasswordHash'', table ''HospitalDB.dbo.Users''; column does not allow nulls. INSERT fails.',                                       '2025-01-19 09:03:48'),
    ( 4, 'usp_UpdatePatientRecord',    'Conversion failed when converting date and/or time from character string. Input value: ''31-02-2025''.',                                                                        '2025-01-27 16:55:31'),
    ( 5, 'usp_GenerateBill',           'Arithmetic overflow error converting numeric to data type numeric. Column ''TotalAmount'' cannot store value 99999999.99.',                                                      '2025-02-04 11:42:17'),
    ( 6, 'usp_SubmitLabOrder',         'The INSERT statement conflicted with the FOREIGN KEY constraint "FK_LabOrders_LabTestCatalog". The conflict occurred in table "dbo.LabTestCatalog", column "LabTestTypeID".', '2025-02-12 07:18:54'),
    ( 7, 'usp_CancelAppointment',      'Transaction (Process ID 67) was deadlocked on lock resources with another process and has been chosen as the deadlock victim. Rerun the transaction.',                          '2025-02-20 13:07:36'),
    ( 8, 'usp_UpdateMedicalRecord',    'String or binary data would be truncated in table ''HospitalDB.dbo.MedicalRecords'', column ''Diagnosis''. Truncated value: ''...(5000+ chars)''.',                            '2025-02-28 10:33:09'),
    ( 9, 'usp_AssignDoctor',           'The multi-part identifier "d.DepartmentName" could not be bound. Missing JOIN to dbo.Departments in procedure body.',                                                           '2025-03-08 15:49:22'),
    (10, 'usp_GenerateReport',         'Timeout expired. The timeout period elapsed prior to completion of the operation or the server is not responding. Procedure exceeded 30-second threshold.',                     '2025-03-16 09:24:47'),
    (11, 'usp_SyncPatientData',        'Invalid object name ''dbo.PatientSnapshot''. The staging table was not created before sync procedure executed.',                                                                '2025-03-24 14:11:33'),
    (12, 'usp_CreatePatient',          'Violation of UNIQUE KEY constraint ''UQ_Users_Username''. Cannot insert duplicate key in object ''dbo.Users''. The duplicate key value is (''j.doe.patient'').',               '2025-04-01 08:58:16'),
    (13, 'usp_ProcessRefund',          'The UPDATE statement conflicted with the CHECK constraint on ''Payments''. The attempted refund amount (500.00) exceeds the original payment amount (350.00).',                 '2025-04-09 12:44:52'),
    (14, 'usp_BackupDatabase',         'Operating system error 5(Access is denied.) on file ''D:\Backups\HospitalDB_20250409.bak''. BACKUP DATABASE is aborting abnormally.',                                        '2025-04-09 23:00:04'),
    (15, 'usp_ValidatePrescription',   'Division by zero error encountered in dosage calculation. Frequency interval value was 0 for PrescriptionItemID 88.',                                                          '2025-04-17 10:22:39'),
    (16, 'usp_GetDoctorSchedule',      'Invalid column name ''AvailabilityFlag''. The column does not exist in table ''dbo.Doctors''. Schema migration may be incomplete.',                                            '2025-04-25 15:36:14'),
    (17, 'usp_SendNotification',       'A network-related or instance-specific error occurred while establishing a connection to the mail server. Connection refused on port 587.',                                       '2025-05-03 08:05:58'),
    (18, 'usp_UpdateInsurancePolicy',  'The DELETE statement conflicted with the REFERENCE constraint "FK_PatientInsurancePolicies_InsuranceProviders". Cannot delete active provider record.',                       '2025-05-11 13:51:27'),
    (19, 'usp_AuditLogin',             'Cannot open database ''HospitalDB'' requested by the login. The login failed. Login failed for user ''svc_audit''.',                                                           '2025-05-19 02:30:11'),
    (20, 'usp_CheckInventory',         'Object reference not set to an instance of an object. NullReferenceException in CLR function ''fn_GetStockLevel'' — parameter @ItemCode was NULL.',                            '2025-05-27 09:17:44'),
    (21, 'usp_CreateAppointment',      'The INSERT statement conflicted with the FOREIGN KEY constraint "FK_Appointments_Patients". PatientID 9999 does not exist in dbo.Patients.',                                 '2025-06-04 11:03:29'),
    (22, 'usp_ProcessPayment',         'Msg 8134, Level 16: Divide by zero error encountered while computing split-payment percentage. BillID 204 has zero outstanding balance.',                                      '2025-06-12 14:48:03'),
    (23, 'usp_GenerateBill',           'Explicit value must be specified for identity column in table ''dbo.Bills'' when IDENTITY_INSERT is set to OFF.',                                                              '2025-06-20 10:29:55'),
    (24, 'usp_UpdatePatientRecord',    'The transaction log for database ''HospitalDB'' is full due to ''LOG_BACKUP''. Free log space before retrying the operation.',                                                 '2025-07-04 23:47:18'),
    (25, 'usp_SubmitLabOrder',         'EXECUTE permission denied on object ''usp_SubmitLabOrder'', database ''HospitalDB'', schema ''dbo''. User ''reception_temp'' lacks required privilege.',                      '2025-08-15 07:34:42'),
    (26, 'usp_SyncPatientData',        'Row size (9842 bytes) exceeds the allowable maximum row size of 8060 bytes for non-LOB data. Consider moving large columns to a separate table.',                              '2025-09-22 16:12:07'),
    (27, 'usp_ValidatePrescription',   'String conversion error: value ''two tablets'' cannot be converted to DECIMAL(10,2) for column ''Dosage''. Non-numeric dosage input detected.',                               '2025-10-30 09:56:33'),
    (28, 'usp_GenerateReport',         'Index ''IX_MedicalRecords_CreatedDate'' is disabled. Query plan reverted to full table scan on dbo.MedicalRecords (1.2 M rows). Rebuild required.',                           '2025-12-01 14:23:19'),
    (29, 'usp_BackupDatabase',         'Msg 3201, Level 16: Cannot open backup device ''\\NAS01\HospitalBackups\HDB_2026.bak''. Operating system error 53 (The network path was not found).',                       '2026-02-14 23:00:07'),
    (30, 'usp_LoginUser',              'Msg 18456, Level 14: Login failed for user ''dr.temp.locum''. Reason: The account is disabled. Contact your system administrator to enable the account.',                     '2026-04-28 06:44:51');
SET IDENTITY_INSERT dbo.ErrorLogs OFF;
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
DBCC CHECKIDENT ('dbo.AuditLogs',               RESEED);
DBCC CHECKIDENT ('dbo.ErrorLogs',               RESEED);
GO
