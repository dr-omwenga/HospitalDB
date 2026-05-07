-- =============================================================================
-- HospitalDB — Performance Indexes (Report-Driven)
-- File        : sql/10_performance_indexes.sql
-- Author      : Hospital Information Systems
-- Date        : 2026-05-07
-- Description :
--   Additional NONCLUSTERED indexes derived from a systematic analysis of
--   WHERE, JOIN, ORDER BY, and GROUP BY clauses across all report files
--   (05–09). These indexes complement the baseline indexes in
--   03_create_indexes.sql and target the column access patterns that appear
--   most frequently in the operational stored procedures and views.
--
--   Existing baseline indexes (03_create_indexes.sql) — NOT repeated here:
--     IX_Patients_LastName              Patients(LastName)
--     IX_Patients_Email                 Patients(Email)
--     IX_Appointments_PatientID         Appointments(PatientID)
--     IX_Appointments_DoctorID          Appointments(DoctorID)
--     IX_Appointments_AppointmentDate   Appointments(AppointmentDate)
--     IX_Bills_PatientID                Bills(PatientID)
--     IX_Bills_AppointmentID            Bills(AppointmentID)
--     IX_Payments_BillID                Payments(BillID)
--     IX_MedicalRecords_CreatedDate     MedicalRecords(CreatedDate)
--     IX_Prescriptions_RecordID         Prescriptions(RecordID)
--     IX_LabOrders_AppointmentID        LabOrders(AppointmentID)
--   Plus UNIQUE constraints acting as indexes:
--     UQ_Doctors_LicenseNumber, UQ_LabTestCatalog_TestName,
--     UQ_MedicalRecords_AppointmentID, UQ_Roles_RoleName, UQ_Users_Username
--
--   Indexes in this file are grouped into three priority tiers:
--     Tier 1 (High)    — columns in the hottest WHERE/JOIN paths, missing
--                        entirely from the baseline set
--     Tier 2 (Medium)  — columns that support specific report features
--                        (date ranges, secondary filters, GROUP BY dimensions)
--     Tier 3 (Support) — FK JOIN paths and lower-frequency filters that
--                        round out full-scan elimination across all tables
--
--   INCLUDE columns are added where the extra key columns eliminate key
--   lookups on the most critical covering paths.
--
--   Safe to re-run: each CREATE INDEX is guarded by a DROP IF EXISTS.
-- =============================================================================

USE HospitalDB;
GO

-- =============================================================================
-- TIER 1 — HIGH PRIORITY
-- Columns that appear in WHERE or JOIN conditions across the majority of
-- report procedures and views.  Absence of these indexes forces full or
-- large range scans on high-frequency queries.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Appointments.Status
--    Used in: vw_UpcomingAppointments     WHERE Status = 'Scheduled'
--             vw_MissedAppointments        WHERE Status IN ('No-Show','Cancelled')
--             vw_ActivePrescriptions       (via Appointments JOIN)
--             usp_Schedule_AppointmentVolumeSummary  GROUP BY Status
--             usp_Schedule_BusiestDaysAndTimes       filtering
--    INCLUDE AppointmentDate so the scheduler daily-briefing query
--    (filter on Status, order by date) is fully covered without a key lookup.
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.Appointments')
      AND  name      = 'IX_Appointments_Status'
)
    DROP INDEX IX_Appointments_Status ON dbo.Appointments;
GO

CREATE NONCLUSTERED INDEX IX_Appointments_Status
    ON dbo.Appointments (Status)
    INCLUDE (AppointmentDate, PatientID, DoctorID);
GO

-- -----------------------------------------------------------------------------
-- 2. BillItems.BillID
--    Used in: vw_RevenueSummary  JOIN BillItems → Bills
--             vw_PatientLifetimeValue  JOIN BillItems → Bills (via CTEs)
--             usp_Billing_RevenueSummary
--             usp_Report_MonthlyRevenueAnalysis
--    BillItems has NO index in the baseline set.  Every billing/revenue
--    report traverses Bills → BillItems; without this index the engine
--    performs a full BillItems scan for every bill row.
--    INCLUDE the remaining payload columns to make the join covering.
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.BillItems')
      AND  name      = 'IX_BillItems_BillID'
)
    DROP INDEX IX_BillItems_BillID ON dbo.BillItems;
GO

CREATE NONCLUSTERED INDEX IX_BillItems_BillID
    ON dbo.BillItems (BillID)
    INCLUDE (ServiceID, Quantity, UnitPrice, LineTotal);
GO

-- -----------------------------------------------------------------------------
-- 3. Bills.BillStatus
--    Used in: vw_UnpaidBills    WHERE BillStatus IN ('Unpaid','Partially Paid')
--             usp_Billing_UnpaidBills    @BillStatus parameter filter
--             usp_Billing_PaymentMethodAnalysis  BillStatus column in result
--    INCLUDE the columns needed by the AR aging query so the engine
--    can satisfy the entire read from the index leaf without touching
--    the clustered index rows.
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.Bills')
      AND  name      = 'IX_Bills_BillStatus'
)
    DROP INDEX IX_Bills_BillStatus ON dbo.Bills;
GO

CREATE NONCLUSTERED INDEX IX_Bills_BillStatus
    ON dbo.Bills (BillStatus)
    INCLUDE (PatientID, AppointmentID, TotalAmount, PaidAmount, Balance, CreatedDate);
GO

-- -----------------------------------------------------------------------------
-- 4. AuditLogs.PerformedByUserID
--    Used in: vw_AuditLogDetail   JOIN AuditLogs → Users
--             vw_InactiveAccounts  LEFT JOIN AuditLogs ON PerformedByUserID
--             usp_Security_AuditLogReport  (both result sets)
--             usp_Security_SystemActivitySummary
--    AuditLogs has NO index on this FK column in the baseline set.
--    Every security report re-joins AuditLogs → Users through this column.
--    INCLUDE audit metadata so the join + summary aggregation avoids
--    key lookups.
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.AuditLogs')
      AND  name      = 'IX_AuditLogs_PerformedByUserID'
)
    DROP INDEX IX_AuditLogs_PerformedByUserID ON dbo.AuditLogs;
GO

CREATE NONCLUSTERED INDEX IX_AuditLogs_PerformedByUserID
    ON dbo.AuditLogs (PerformedByUserID)
    INCLUDE (ActionDate, TableName, ActionType);
GO

-- -----------------------------------------------------------------------------
-- 5. AuditLogs.ActionDate
--    Used in: usp_Security_AuditLogReport  WHERE ActionDay >= @StartDate
--                                           ORDER BY ActionDate DESC
--             usp_Security_SystemActivitySummary  GROUP BY day, rolling 7-day
--             vw_InactiveAccounts  WHERE ActionDate >= DATEADD(DAY,-30,...)
--    ActionDate is the primary sort column for all audit output and the
--    only range predicate for compliance date-range queries.
--    INCLUDE the filter columns so the WHERE clause is satisfied at the
--    index level before any key lookups.
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.AuditLogs')
      AND  name      = 'IX_AuditLogs_ActionDate'
)
    DROP INDEX IX_AuditLogs_ActionDate ON dbo.AuditLogs;
GO

CREATE NONCLUSTERED INDEX IX_AuditLogs_ActionDate
    ON dbo.AuditLogs (ActionDate)
    INCLUDE (PerformedByUserID, TableName, ActionType);
GO

-- -----------------------------------------------------------------------------
-- 6. Doctors.DepartmentID
--    Used in: virtually EVERY multi-table report
--             All JOIN chains follow: Appointments → Doctors → Departments
--             Department name is the primary GROUP BY / filter dimension
--             across billing, scheduling, and lab reports.
--    INCLUDE name columns so the Departments lookup can be satisfied from
--    the Doctors index itself in most reporting CTEs.
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.Doctors')
      AND  name      = 'IX_Doctors_DepartmentID'
)
    DROP INDEX IX_Doctors_DepartmentID ON dbo.Doctors;
GO

CREATE NONCLUSTERED INDEX IX_Doctors_DepartmentID
    ON dbo.Doctors (DepartmentID)
    INCLUDE (FirstName, LastName, Specialization);
GO

-- -----------------------------------------------------------------------------
-- 7. PatientInsurancePolicies — composite (PatientID, IsPrimary)
--    Used in: vw_MaskedPatientDirectory  LEFT JOIN pip ON PatientID AND IsPrimary=1
--             vw_ActivePrescriptionsWithInsurance  LEFT JOIN ... IsPrimary=1
--             vw_MissedAppointments  LEFT JOIN ... IsPrimary=1
--             usp_Security_MaskedPatientDirectory
--    The IsPrimary=1 filter always accompanies the PatientID equality join.
--    A composite key (PatientID, IsPrimary) lets the engine seek directly
--    to the primary policy row without scanning all policies for that patient.
--    INCLUDE the insurance payload so the entire insurance join is covered.
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.PatientInsurancePolicies')
      AND  name      = 'IX_PatientInsurancePolicies_PatientID_IsPrimary'
)
    DROP INDEX IX_PatientInsurancePolicies_PatientID_IsPrimary
        ON dbo.PatientInsurancePolicies;
GO

CREATE NONCLUSTERED INDEX IX_PatientInsurancePolicies_PatientID_IsPrimary
    ON dbo.PatientInsurancePolicies (PatientID, IsPrimary)
    INCLUDE (InsuranceProviderID, PolicyNumber, CoveragePercent, ExpiryDate);
GO

-- -----------------------------------------------------------------------------
-- 8. Payments.PaymentDate
--    Used in: usp_Billing_PaymentMethodAnalysis  WHERE PaymentDate range
--             usp_Billing_TopPayingPatients  WHERE PaymentDate range
--             usp_Billing_MonthlyRevenueTrend  GROUP BY year/month of PaymentDate
--             vw_PatientLifetimeValue  MIN/MAX PaymentDate
--    INCLUDE Amount and PaymentMethod so the method-analysis aggregation
--    (SUM(Amount) GROUP BY PaymentMethod) can run on the index pages.
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.Payments')
      AND  name      = 'IX_Payments_PaymentDate'
)
    DROP INDEX IX_Payments_PaymentDate ON dbo.Payments;
GO

CREATE NONCLUSTERED INDEX IX_Payments_PaymentDate
    ON dbo.Payments (PaymentDate)
    INCLUDE (BillID, Amount, PaymentMethod);
GO


-- =============================================================================
-- TIER 2 — MEDIUM PRIORITY
-- Columns that support specific report features: secondary date filters,
-- GROUP BY dimensions, and method/status equality predicates.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 9. Bills.CreatedDate
--    Used in: usp_Billing_RevenueSummary       WHERE YEAR(CreatedDate) = @Year
--             usp_Report_MonthlyRevenueAnalysis WHERE YEAR(CreatedDate) = @Year
--             usp_Billing_MonthlyRevenueTrend   GROUP BY year/month
--    INCLUDE the columns needed by the monthly revenue aggregation CTE.
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.Bills')
      AND  name      = 'IX_Bills_CreatedDate'
)
    DROP INDEX IX_Bills_CreatedDate ON dbo.Bills;
GO

CREATE NONCLUSTERED INDEX IX_Bills_CreatedDate
    ON dbo.Bills (CreatedDate)
    INCLUDE (PatientID, AppointmentID, TotalAmount, PaidAmount, Balance, BillStatus);
GO

-- -----------------------------------------------------------------------------
-- 10. BillItems.ServiceID
--     Used in: vw_RevenueSummary    JOIN BillItems → ServiceCatalog
--              usp_Billing_RevenueSummary  GROUP BY ServiceName (via ServiceID)
--     Allows the engine to seek into ServiceCatalog for each BillItem row
--     rather than scanning the catalog.
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.BillItems')
      AND  name      = 'IX_BillItems_ServiceID'
)
    DROP INDEX IX_BillItems_ServiceID ON dbo.BillItems;
GO

CREATE NONCLUSTERED INDEX IX_BillItems_ServiceID
    ON dbo.BillItems (ServiceID);
GO

-- -----------------------------------------------------------------------------
-- 11. Payments.PaymentMethod
--     Used in: usp_Billing_PaymentMethodAnalysis  WHERE PaymentMethod = @PaymentMethod
--              vw_PatientLifetimeValue  GROUP BY PatientID, PaymentMethod
--              usp_Billing_TopPayingPatients  GROUP BY PaymentMethod (modal method)
--     INCLUDE Amount for the SUM(Amount) GROUP BY PaymentMethod aggregation.
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.Payments')
      AND  name      = 'IX_Payments_PaymentMethod'
)
    DROP INDEX IX_Payments_PaymentMethod ON dbo.Payments;
GO

CREATE NONCLUSTERED INDEX IX_Payments_PaymentMethod
    ON dbo.Payments (PaymentMethod)
    INCLUDE (Amount, BillID, PaymentDate);
GO

-- -----------------------------------------------------------------------------
-- 12. Users.RoleID
--     Used in: vw_AuditLogDetail    JOIN Users → Roles
--              vw_InactiveAccounts   JOIN Users → Roles
--              vw_MaskedPatientDirectory  LEFT JOIN Users → Roles
--              usp_Security_InactiveAccountReport  @RoleName filter (via Roles JOIN)
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.Users')
      AND  name      = 'IX_Users_RoleID'
)
    DROP INDEX IX_Users_RoleID ON dbo.Users;
GO

CREATE NONCLUSTERED INDEX IX_Users_RoleID
    ON dbo.Users (RoleID);
GO

-- -----------------------------------------------------------------------------
-- 13. Users — composite (IsActive, LastLogin)
--     Used in: vw_InactiveAccounts   WHERE IsActive = 0/1, DATEDIFF on LastLogin
--              usp_Security_InactiveAccountReport  filter + ORDER BY LastLogin
--              vw_MaskedPatientDirectory  WHERE AccountIsActive = @AccountIsActive
--     Composite (IsActive, LastLogin) supports the most common query pattern:
--     filter to active accounts first, then sort/range on LastLogin.
--     INCLUDE RoleID so the Roles join can be resolved at the index level.
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.Users')
      AND  name      = 'IX_Users_IsActive_LastLogin'
)
    DROP INDEX IX_Users_IsActive_LastLogin ON dbo.Users;
GO

CREATE NONCLUSTERED INDEX IX_Users_IsActive_LastLogin
    ON dbo.Users (IsActive, LastLogin)
    INCLUDE (RoleID, Username);
GO

-- -----------------------------------------------------------------------------
-- 14. AuditLogs — composite (ActionType, TableName)
--     Used in: usp_Security_AuditLogReport
--                WHERE ActionType = @ActionType AND TableName = @TableName
--              usp_Security_SystemActivitySummary
--                GROUP BY TableName to find most-active table per user
--     Putting ActionType first (lower cardinality) lets the engine seek
--     by action type and then narrow to a specific table name.
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.AuditLogs')
      AND  name      = 'IX_AuditLogs_ActionType_TableName'
)
    DROP INDEX IX_AuditLogs_ActionType_TableName ON dbo.AuditLogs;
GO

CREATE NONCLUSTERED INDEX IX_AuditLogs_ActionType_TableName
    ON dbo.AuditLogs (ActionType, TableName)
    INCLUDE (ActionDate, PerformedByUserID);
GO

-- -----------------------------------------------------------------------------
-- 15. LabOrders.Status
--     Used in: usp_Report_LabOrderBacklog
--                WHERE Status = @StatusFilter (Pending, In-Progress)
--              usp_Security_DuplicateRecordScan  ORDER BY / filtering
--     INCLUDE DateRequested for the ORDER BY lod.DateRequested ASC
--     in the backlog procedure so it avoids a key lookup.
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.LabOrders')
      AND  name      = 'IX_LabOrders_Status'
)
    DROP INDEX IX_LabOrders_Status ON dbo.LabOrders;
GO

CREATE NONCLUSTERED INDEX IX_LabOrders_Status
    ON dbo.LabOrders (Status)
    INCLUDE (AppointmentID, LabTestTypeID, DateRequested);
GO

-- -----------------------------------------------------------------------------
-- 16. LabOrders.LabTestTypeID
--     Used in: vw_LabOrderDetail   JOIN LabOrders → LabTestCatalog
--              usp_Report_LabOrderBacklog  GROUP BY TestName (via LabTestTypeID)
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.LabOrders')
      AND  name      = 'IX_LabOrders_LabTestTypeID'
)
    DROP INDEX IX_LabOrders_LabTestTypeID ON dbo.LabOrders;
GO

CREATE NONCLUSTERED INDEX IX_LabOrders_LabTestTypeID
    ON dbo.LabOrders (LabTestTypeID);
GO

-- -----------------------------------------------------------------------------
-- 17. PatientInsurancePolicies.ExpiryDate
--     Used in: usp_Security_MaskedPatientDirectory
--                WHERE ExpiryDate >= GETDATE() (Active insurance filter)
--                WHERE ExpiryDate <  GETDATE() (Expired insurance filter)
--              usp_Report_ActivePrescriptions
--                insurance status derivation (Active / Expiring Soon / Expired)
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.PatientInsurancePolicies')
      AND  name      = 'IX_PatientInsurancePolicies_ExpiryDate'
)
    DROP INDEX IX_PatientInsurancePolicies_ExpiryDate
        ON dbo.PatientInsurancePolicies;
GO

CREATE NONCLUSTERED INDEX IX_PatientInsurancePolicies_ExpiryDate
    ON dbo.PatientInsurancePolicies (ExpiryDate)
    INCLUDE (PatientID, IsPrimary);
GO


-- =============================================================================
-- TIER 3 — SUPPORTING
-- FK join paths and lower-frequency equality filters that eliminate remaining
-- full-scan exposure across the less-frequently-joined tables.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 18. Prescriptions.DoctorID
--     Used in: vw_ActivePrescriptionsWithInsurance  JOIN Prescriptions → Doctors
--              usp_Report_ActivePrescriptions
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.Prescriptions')
      AND  name      = 'IX_Prescriptions_DoctorID'
)
    DROP INDEX IX_Prescriptions_DoctorID ON dbo.Prescriptions;
GO

CREATE NONCLUSTERED INDEX IX_Prescriptions_DoctorID
    ON dbo.Prescriptions (DoctorID);
GO

-- -----------------------------------------------------------------------------
-- 19. PrescriptionItems.PrescriptionID
--     Used in: vw_ActivePrescriptionsWithInsurance  JOIN PrescriptionItems
--              usp_Report_ActivePrescriptions
--     PrescriptionItems has no baseline index; every prescription query
--     scans the entire table without it.
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.PrescriptionItems')
      AND  name      = 'IX_PrescriptionItems_PrescriptionID'
)
    DROP INDEX IX_PrescriptionItems_PrescriptionID ON dbo.PrescriptionItems;
GO

CREATE NONCLUSTERED INDEX IX_PrescriptionItems_PrescriptionID
    ON dbo.PrescriptionItems (PrescriptionID);
GO

-- -----------------------------------------------------------------------------
-- 20. EmergencyContacts.PatientID
--     Used in: patient management reports that join to emergency contact data
--              and any future patient-safety queries that require contact lookup
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.EmergencyContacts')
      AND  name      = 'IX_EmergencyContacts_PatientID'
)
    DROP INDEX IX_EmergencyContacts_PatientID ON dbo.EmergencyContacts;
GO

CREATE NONCLUSTERED INDEX IX_EmergencyContacts_PatientID
    ON dbo.EmergencyContacts (PatientID);
GO

-- -----------------------------------------------------------------------------
-- 21. Addresses.City
--     Used in: usp_Security_MaskedPatientDirectory  WHERE City = @City
--              Geographic analytics queries filtering by city
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.Addresses')
      AND  name      = 'IX_Addresses_City'
)
    DROP INDEX IX_Addresses_City ON dbo.Addresses;
GO

CREATE NONCLUSTERED INDEX IX_Addresses_City
    ON dbo.Addresses (City)
    INCLUDE (State, Country);
GO

-- -----------------------------------------------------------------------------
-- 22. Patients.Gender
--     Used in: usp_Security_MaskedPatientDirectory  WHERE Gender = @Gender
--              Demographic analysis queries
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.Patients')
      AND  name      = 'IX_Patients_Gender'
)
    DROP INDEX IX_Patients_Gender ON dbo.Patients;
GO

CREATE NONCLUSTERED INDEX IX_Patients_Gender
    ON dbo.Patients (Gender);
GO

-- -----------------------------------------------------------------------------
-- 23. Patients.DOB
--     Used in: usp_Security_DuplicateRecordScan  GROUP BY FirstName, LastName, DOB
--              Clinical reports that filter or sort by age band
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.Patients')
      AND  name      = 'IX_Patients_DOB'
)
    DROP INDEX IX_Patients_DOB ON dbo.Patients;
GO

CREATE NONCLUSTERED INDEX IX_Patients_DOB
    ON dbo.Patients (DOB);
GO

-- -----------------------------------------------------------------------------
-- 24. LabOrders.DateRequested
--     Used in: usp_Report_LabOrderBacklog  ORDER BY DateRequested ASC
--              SLA elapsed-days computation relies on DateRequested as the
--              baseline; the index supports both sort and range operations.
-- -----------------------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  object_id = OBJECT_ID('dbo.LabOrders')
      AND  name      = 'IX_LabOrders_DateRequested'
)
    DROP INDEX IX_LabOrders_DateRequested ON dbo.LabOrders;
GO

CREATE NONCLUSTERED INDEX IX_LabOrders_DateRequested
    ON dbo.LabOrders (DateRequested)
    INCLUDE (Status, AppointmentID, LabTestTypeID);
GO

-- =============================================================================
-- Summary: 24 new indexes across 12 tables
-- Run AFTER: 03_create_indexes.sql (baseline indexes must exist first)
-- Safe to re-run: DROP IF EXISTS guards each index creation
-- =============================================================================
