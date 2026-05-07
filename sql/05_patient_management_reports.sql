-- =============================================================================
-- HospitalDB — Patient Management Reports
-- File        : sql/05_patient_management_reports.sql
-- Author      : Hospital Information Systems
-- Date        : 2026-05-07
-- Description :
--   Five detailed patient-management operational reports for the HospitalDB
--   system.  Each report is implemented as:
--       • A reusable VIEW  (dbo.vw_*)      — encapsulates the core join logic
--         and computed columns so downstream queries remain concise.
--       • A STORED PROCEDURE (dbo.usp_Report_*) — exposes dynamic filtering,
--         parameter-driven behaviour, and cursor-free pagination via
--         OFFSET / FETCH NEXT.
--
--   Advanced SQL features demonstrated across all five reports:
--       – Multi-table INNER and LEFT JOINs (up to six tables in one query)
--       – GROUP BY with SUM, COUNT, MAX, AVG aggregate functions
--       – Conditional aggregation using CASE expressions inside SUM()
--       – Common Table Expressions (WITH ... AS) for modular decomposition
--       – Correlated scalar subqueries for mode/modal-value derivation
--       – GROUP BY with partial ROLLUP for hierarchical subtotals
--       – GROUPING() function to identify and label rollup rows
--       – Temporal logic: DATEDIFF, DATEADD, GETDATE, CAST(... AS DATE)
--       – OFFSET / FETCH NEXT for server-side pagination
--       – NULLIF / ISNULL for safe division and null coalescing
--       – EXISTS subquery for semi-join filtering
--       – HAVING clause for post-aggregation filtering
-- =============================================================================

USE HospitalDB;
GO

-- =============================================================================
-- REPORT 1
-- =============================================================================
-- Title       : Patient Outstanding Balance and Payment History Summary
--
-- Business Question:
--   Which patients currently carry an outstanding account balance, how much do
--   they owe in aggregate across all their bills, how many payment transactions
--   has each patient made to date, and what is each patient's preferred method
--   of payment?
--
-- Purpose / Business Value:
--   The Billing Department relies on this report as its primary
--   accounts-receivable (AR) management tool.  By surfacing outstanding
--   balances alongside a derived collection-risk tier (High / Medium / Low /
--   Cleared), billing staff can prioritise follow-up calls, identify patients
--   who may be eligible for a structured payment plan, and flag high-risk
--   debtors for escalation.  Tracking preferred payment methods in the same
--   view assists the Finance team with cashflow forecasting and informs
--   negotiations with payment processors over transaction-fee structures.  The
--   stored procedure's @MinBalance and @BillStatus filters allow the team to
--   generate targeted sub-lists (e.g. all accounts with a balance > $100 and
--   at least one Unpaid bill) without duplicating query logic.
--
-- Information Returned:
--   Patient ID, full name, account-opened date, total bills on record, gross
--   amount billed, total amount paid across all bills, current outstanding
--   balance, count of payment transactions, date of most recent payment,
--   preferred payment method (derived via correlated subquery), and a
--   computed collection-risk tier.
--
-- SQL Techniques Used:
--   LEFT JOIN (patients with no bills remain in the result), aggregate
--   functions (SUM, COUNT, MAX), correlated scalar subquery for modal
--   payment-method derivation, GROUP BY across concatenated name columns,
--   ORDER BY with OFFSET / FETCH NEXT for pagination, EXISTS semi-join for
--   status-based filtering.
-- =============================================================================

CREATE OR ALTER VIEW dbo.vw_PatientFinancialSummary
AS
    SELECT
        p.PatientID,
        p.FirstName + ' ' + p.LastName                AS PatientName,
        p.DateCreated                                  AS AccountOpened,
        COUNT(DISTINCT b.BillID)                       AS TotalBills,
        ISNULL(SUM(b.TotalAmount), 0)                  AS TotalBilled,
        ISNULL(SUM(b.PaidAmount),  0)                  AS TotalPaid,
        ISNULL(SUM(b.Balance),     0)                  AS OutstandingBalance,
        COUNT(DISTINCT py.PaymentID)                   AS PaymentTransactions,
        MAX(py.PaymentDate)                            AS MostRecentPayment,
        -- Correlated scalar subquery: returns the payment method this patient
        -- has used most frequently (statistical mode).  NULLIF prevents a
        -- divide-by-zero scenario; TOP 1 with ORDER BY COUNT(*) DESC selects
        -- the modal value without requiring a window function.
        (
            SELECT TOP 1 py2.PaymentMethod
            FROM   dbo.Payments    py2
            INNER JOIN dbo.Bills   b2  ON py2.BillID  = b2.BillID
            WHERE  b2.PatientID = p.PatientID
            GROUP  BY py2.PaymentMethod
            ORDER  BY COUNT(*) DESC
        )                                              AS PreferredPaymentMethod
    FROM       dbo.Patients  p
    LEFT JOIN  dbo.Bills     b  ON b.PatientID = p.PatientID
    LEFT JOIN  dbo.Payments  py ON py.BillID   = b.BillID
    GROUP BY
        p.PatientID,
        p.FirstName,
        p.LastName,
        p.DateCreated;
GO

-- -----------------------------------------------------------------------------
-- Stored Procedure — Report 1
-- Parameters:
--   @MinBalance  DECIMAL  Minimum outstanding balance to include in results.
--                         Defaults to 0.00 (all patients returned).
--   @BillStatus  VARCHAR  If supplied, restricts output to patients who have
--                         at least one bill matching this status
--                         ('Paid' | 'Partial' | 'Unpaid').  NULL = no filter.
--   @PageNumber  INT      1-based page index for pagination.
--   @PageSize    INT      Number of rows per page.  Capped at 100.
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Report_PatientFinancialSummary
    @MinBalance  DECIMAL(10,2) = 0.00,
    @BillStatus  VARCHAR(20)   = NULL,
    @PageNumber  INT           = 1,
    @PageSize    INT           = 10
AS
BEGIN
    SET NOCOUNT ON;

    -- Sanitise pagination inputs
    IF @PageNumber < 1   SET @PageNumber = 1;
    IF @PageSize   < 1   SET @PageSize   = 10;
    IF @PageSize   > 100 SET @PageSize   = 100;

    SELECT
        fs.PatientID,
        fs.PatientName,
        fs.AccountOpened,
        fs.TotalBills,
        fs.TotalBilled,
        fs.TotalPaid,
        fs.OutstandingBalance,
        fs.PaymentTransactions,
        fs.MostRecentPayment,
        fs.PreferredPaymentMethod,
        -- Derived risk tier delegates to fn_GetCollectionRiskTier so that
        -- balance thresholds are defined in a single place across all reports.
        dbo.fn_GetCollectionRiskTier(fs.OutstandingBalance)
                                               AS CollectionRisk
    FROM  dbo.vw_PatientFinancialSummary fs
    WHERE fs.OutstandingBalance >= @MinBalance
      AND (
            @BillStatus IS NULL
            OR EXISTS (
                -- Semi-join: include this patient only if they have at least
                -- one bill whose status matches the supplied filter value.
                SELECT 1
                FROM   dbo.Bills b
                WHERE  b.PatientID  = fs.PatientID
                  AND  b.BillStatus = @BillStatus
            )
          )
    ORDER BY fs.OutstandingBalance DESC, fs.PatientName
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END;
GO

-- Sample execution: all patients with a positive outstanding balance, page 1
EXEC dbo.usp_Report_PatientFinancialSummary
    @MinBalance = 0.01,
    @BillStatus = NULL,
    @PageNumber = 1,
    @PageSize   = 10;
GO


-- =============================================================================
-- REPORT 2
-- =============================================================================
-- Title       : Doctor Appointment Performance and Completion Rate by
--               Department
--
-- Business Question:
--   How many appointments has each doctor handled within a given date range,
--   what proportion of those appointments were completed versus cancelled or
--   not attended (No-Show), how many unique patients were seen, and how do
--   these performance metrics compare across departments?
--
-- Purpose / Business Value:
--   Clinical Management and Department Heads require an objective performance
--   dashboard to monitor appointment utilisation, identify workload imbalances
--   across medical staff, and flag departments where cancellation or no-show
--   rates may signal patient-dissatisfaction or scheduling inefficiencies.
--   This report feeds directly into:
--       – Quarterly departmental KPI review packs
--       – Staffing and scheduling optimisation decisions
--       – Accreditation submissions requiring evidence of clinical activity
--   The @DepartmentName and date-range parameters allow ad-hoc drilldown
--   into a single department or a specific operational period without
--   maintaining separate queries for each scenario.
--
-- Information Returned:
--   Doctor name, department name, specialisation, total appointments within
--   the filtered period, individual status counts (Completed / Scheduled /
--   Cancelled / No-Show), completion rate (% of closed appointments that
--   resulted in a completed visit), no-show rate (% of all appointments),
--   and count of unique patients seen.
--
-- SQL Techniques Used:
--   INNER JOIN (Doctors → Departments) and LEFT JOIN (→ Appointments) to
--   retain doctors with zero appointments in the period, CTE for date-range
--   and department pre-filtering, conditional aggregation (CASE inside SUM)
--   for per-status counts, CAST / NULLIF for safe percentage derivation,
--   HAVING for post-aggregation threshold filtering, OFFSET / FETCH
--   pagination ordered by completion rate descending.
-- =============================================================================

CREATE OR ALTER VIEW dbo.vw_DoctorAppointmentPerformance
AS
    SELECT
        d.DoctorID,
        d.FirstName + ' ' + d.LastName                              AS DoctorName,
        dep.DepartmentName,
        d.Specialization,
        COUNT(a.AppointmentID)                                       AS TotalAppointments,
        SUM(CASE WHEN a.Status = 'Completed' THEN 1 ELSE 0 END)     AS Completed,
        SUM(CASE WHEN a.Status = 'Scheduled' THEN 1 ELSE 0 END)     AS Scheduled,
        SUM(CASE WHEN a.Status = 'Cancelled' THEN 1 ELSE 0 END)     AS Cancelled,
        SUM(CASE WHEN a.Status = 'No-Show'   THEN 1 ELSE 0 END)     AS NoShow,
        -- Completion rate excludes still-Scheduled appointments from the
        -- denominator because they have not yet reached their outcome state.
        CAST(
            100.0
            * SUM(CASE WHEN a.Status = 'Completed' THEN 1 ELSE 0 END)
            / NULLIF(
                SUM(CASE WHEN a.Status IN ('Completed','Cancelled','No-Show')
                         THEN 1 ELSE 0 END), 0)
        AS DECIMAL(5,2))                                             AS CompletionRatePct,
        CAST(
            100.0
            * SUM(CASE WHEN a.Status = 'No-Show' THEN 1 ELSE 0 END)
            / NULLIF(COUNT(a.AppointmentID), 0)
        AS DECIMAL(5,2))                                             AS NoShowRatePct,
        COUNT(DISTINCT a.PatientID)                                  AS UniquePatientsSeen,
        MAX(a.AppointmentDate)                                       AS MostRecentAppointment
    FROM       dbo.Doctors     d
    INNER JOIN dbo.Departments dep ON dep.DepartmentID = d.DepartmentID
    LEFT  JOIN dbo.Appointments a  ON  a.DoctorID      = d.DoctorID
    GROUP BY
        d.DoctorID,
        d.FirstName,
        d.LastName,
        dep.DepartmentName,
        d.Specialization;
GO

-- -----------------------------------------------------------------------------
-- Stored Procedure — Report 2
-- Parameters:
--   @DepartmentName  NVARCHAR  Restrict results to a single department name.
--                              NULL returns all departments.
--   @StartDate       DATE      Inclusive lower bound for appointment dates.
--                              NULL applies no lower bound.
--   @EndDate         DATE      Inclusive upper bound for appointment dates.
--                              NULL applies no upper bound.
--   @MinAppointments INT       Exclude doctors with fewer than this many
--                              appointments in the period.  Default 0.
--   @PageNumber      INT       1-based page index.
--   @PageSize        INT       Rows per page.  Capped at 100.
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Report_DoctorAppointmentPerformance
    @DepartmentName  NVARCHAR(100) = NULL,
    @StartDate       DATE          = NULL,
    @EndDate         DATE          = NULL,
    @MinAppointments INT           = 0,
    @PageNumber      INT           = 1,
    @PageSize        INT           = 10
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber < 1   SET @PageNumber = 1;
    IF @PageSize   < 1   SET @PageSize   = 10;
    IF @PageSize   > 100 SET @PageSize   = 100;

    -- CTE pre-filters by department and appointment date range before
    -- aggregation, avoiding the need to JOIN the view and re-aggregate.
    WITH FilteredData AS (
        SELECT
            d.DoctorID,
            d.FirstName + ' ' + d.LastName  AS DoctorName,
            dep.DepartmentName,
            d.Specialization,
            a.AppointmentID,
            a.Status,
            a.PatientID
        FROM       dbo.Doctors      d
        INNER JOIN dbo.Departments  dep ON dep.DepartmentID = d.DepartmentID
        LEFT  JOIN dbo.Appointments a   ON  a.DoctorID      = d.DoctorID
                                       AND (@StartDate IS NULL
                                            OR a.AppointmentDate >= @StartDate)
                                       AND (@EndDate   IS NULL
                                            OR a.AppointmentDate <= @EndDate)
        WHERE (@DepartmentName IS NULL
               OR dep.DepartmentName = @DepartmentName)
    )
    SELECT
        DoctorID,
        DoctorName,
        DepartmentName,
        Specialization,
        COUNT(AppointmentID)                                          AS TotalAppointments,
        SUM(CASE WHEN Status = 'Completed' THEN 1 ELSE 0 END)        AS Completed,
        SUM(CASE WHEN Status = 'Scheduled' THEN 1 ELSE 0 END)        AS Scheduled,
        SUM(CASE WHEN Status = 'Cancelled' THEN 1 ELSE 0 END)        AS Cancelled,
        SUM(CASE WHEN Status = 'No-Show'   THEN 1 ELSE 0 END)        AS NoShow,
        CAST(
            100.0
            * SUM(CASE WHEN Status = 'Completed' THEN 1 ELSE 0 END)
            / NULLIF(
                SUM(CASE WHEN Status IN ('Completed','Cancelled','No-Show')
                         THEN 1 ELSE 0 END), 0)
        AS DECIMAL(5,2))                                              AS CompletionRatePct,
        CAST(
            100.0
            * SUM(CASE WHEN Status = 'No-Show' THEN 1 ELSE 0 END)
            / NULLIF(COUNT(AppointmentID), 0)
        AS DECIMAL(5,2))                                              AS NoShowRatePct,
        COUNT(DISTINCT PatientID)                                     AS UniquePatientsSeen
    FROM  FilteredData
    GROUP BY DoctorID, DoctorName, DepartmentName, Specialization
    HAVING COUNT(AppointmentID) >= @MinAppointments
    ORDER BY CompletionRatePct DESC, TotalAppointments DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END;
GO

-- Sample execution: all Cardiology doctors, full date history
EXEC dbo.usp_Report_DoctorAppointmentPerformance
    @DepartmentName  = 'Cardiology',
    @StartDate       = NULL,
    @EndDate         = NULL,
    @MinAppointments = 0,
    @PageNumber      = 1,
    @PageSize        = 10;
GO


-- =============================================================================
-- REPORT 3
-- =============================================================================
-- Title       : Active Patient Prescriptions with Insurance Coverage
--               Assessment
--
-- Business Question:
--   Which patients have prescriptions issued within the last 12 months, what
--   medications are they currently taking (name, dosage, frequency, duration),
--   which doctor issued each prescription, and does the patient hold a valid,
--   non-expired primary insurance policy that could offset medication costs?
--
-- Purpose / Business Value:
--   The Pharmacy, Clinical Coordination, and Patient Services teams share
--   responsibility for this data across three distinct use cases:
--       1. Medication Reconciliation — the Pharmacy team uses the medication
--          register to cross-check prescriptions before dispensing refills,
--          preventing dangerous drug interactions in multi-physician care
--          scenarios.
--       2. Insurance Expiry Alerts — the @ExpiringWithinDays parameter enables
--          a scheduled daily job to surface patients whose insurance is about
--          to lapse, prompting proactive outreach before the next refill is
--          due and reducing the risk of claims being rejected at the point of
--          dispensing.
--       3. Affordability Gap Identification — CoveragePercent alongside
--          the InsuranceStatus label ('No Insurance' / 'Expired' / 'Expiring
--          Soon' / 'Active') helps Patient Services identify under-insured
--          patients who may qualify for financial assistance programmes.
--
-- Information Returned:
--   Patient name, date of birth, age (computed), prescription date,
--   prescribing doctor name, specialisation, associated diagnosis, medication
--   name, dosage, frequency, duration, insurance provider, policy number,
--   coverage percentage, policy expiry date, days until expiry, and a derived
--   insurance status label.
--
-- SQL Techniques Used:
--   Six-table INNER JOIN chain (Patients → Appointments → MedicalRecords →
--   Prescriptions → PrescriptionItems → Doctors), LEFT JOIN for optional
--   insurance data (patients without insurance remain in the result),
--   DATEDIFF for age and expiry-day calculations, DATEADD for trailing-12-
--   month window, CAST(GETDATE() AS DATE) to strip time component,
--   CASE expression for status labelling, OFFSET / FETCH pagination.
-- =============================================================================

CREATE OR ALTER VIEW dbo.vw_ActivePrescriptionsWithInsurance
AS
    SELECT
        p.PatientID,
        p.FirstName + ' ' + p.LastName                   AS PatientName,
        p.DOB,
        DATEDIFF(YEAR, p.DOB, GETDATE())                 AS PatientAge,
        rx.PrescriptionID,
        rx.PrescriptionDate,
        d.DoctorID,
        d.FirstName + ' ' + d.LastName                   AS PrescribingDoctor,
        d.Specialization,
        mr.RecordID,
        mr.Diagnosis,
        rxi.PrescriptionItemID,
        rxi.MedicationName,
        rxi.Dosage,
        rxi.Frequency,
        rxi.Duration,
        ip.ProviderName                                  AS InsuranceProvider,
        pip.PolicyNumber,
        pip.CoveragePercent,
        pip.ExpiryDate                                   AS PolicyExpiryDate,
        DATEDIFF(DAY, GETDATE(), pip.ExpiryDate)         AS DaysUntilPolicyExpiry
    FROM       dbo.Patients                  p
    INNER JOIN dbo.Appointments              a    ON a.PatientID        = p.PatientID
    INNER JOIN dbo.MedicalRecords            mr   ON mr.AppointmentID   = a.AppointmentID
    INNER JOIN dbo.Prescriptions             rx   ON rx.RecordID        = mr.RecordID
    INNER JOIN dbo.PrescriptionItems         rxi  ON rxi.PrescriptionID = rx.PrescriptionID
    INNER JOIN dbo.Doctors                   d    ON d.DoctorID         = rx.DoctorID
    -- LEFT JOIN ensures patients without any insurance policy are still returned,
    -- appearing with NULL insurance columns and labelled 'No Insurance'.
    LEFT  JOIN dbo.PatientInsurancePolicies  pip  ON pip.PatientID      = p.PatientID
                                                 AND pip.IsPrimary      = 1
    LEFT  JOIN dbo.InsuranceProviders        ip   ON ip.InsuranceProviderID
                                                   = pip.InsuranceProviderID;
GO

-- -----------------------------------------------------------------------------
-- Stored Procedure — Report 3
-- Parameters:
--   @PatientID          INT   Target a single patient by ID.  NULL = all.
--   @ExpiringWithinDays INT   Return only rows where the primary insurance
--                             policy expires within the next N days.
--                             NULL disables this filter entirely.
--   @PageNumber         INT   1-based page index.
--   @PageSize           INT   Rows per page.  Capped at 200.
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Report_ActivePrescriptions
    @PatientID          INT = NULL,
    @ExpiringWithinDays INT = NULL,
    @PageNumber         INT = 1,
    @PageSize           INT = 15
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber < 1    SET @PageNumber = 1;
    IF @PageSize   < 1    SET @PageSize   = 15;
    IF @PageSize   > 200  SET @PageSize   = 200;

    SELECT
        ap.PatientID,
        ap.PatientName,
        ap.DOB,
        ap.PatientAge,
        ap.PrescriptionID,
        ap.PrescriptionDate,
        ap.PrescribingDoctor,
        ap.Specialization,
        ap.Diagnosis,
        ap.MedicationName,
        ap.Dosage,
        ap.Frequency,
        ap.Duration,
        ap.InsuranceProvider,
        ap.PolicyNumber,
        ap.CoveragePercent,
        ap.PolicyExpiryDate,
        ap.DaysUntilPolicyExpiry,
        CASE
            WHEN ap.PolicyExpiryDate IS NULL          THEN 'No Insurance'
            WHEN ap.DaysUntilPolicyExpiry <  0        THEN 'Expired'
            WHEN ap.DaysUntilPolicyExpiry <= 30       THEN 'Expiring Soon'
            ELSE                                           'Active'
        END                                           AS InsuranceStatus
    FROM  dbo.vw_ActivePrescriptionsWithInsurance ap
    WHERE
        -- Trailing 12-month window: only prescriptions issued in the past year
        ap.PrescriptionDate >= DATEADD(MONTH, -12, CAST(GETDATE() AS DATE))
        AND (@PatientID IS NULL OR ap.PatientID = @PatientID)
        AND (
              @ExpiringWithinDays IS NULL
              OR ap.DaysUntilPolicyExpiry BETWEEN 0 AND @ExpiringWithinDays
            )
    ORDER BY
        ap.PolicyExpiryDate ASC,     -- soonest-expiring policies first
        ap.PatientName,
        ap.PrescriptionDate DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END;
GO

-- Sample execution: all prescriptions where insurance expires within 365 days
EXEC dbo.usp_Report_ActivePrescriptions
    @PatientID          = NULL,
    @ExpiringWithinDays = 365,
    @PageNumber         = 1,
    @PageSize           = 15;
GO


-- =============================================================================
-- REPORT 4
-- =============================================================================
-- Title       : Laboratory Order Backlog and Pending Results Monitoring
--               Dashboard
--
-- Business Question:
--   Which laboratory orders are currently in a Pending state, how many days
--   have elapsed since each order was placed, which test types and departments
--   are accumulating the greatest backlogs, and what is the overall
--   completion rate broken down by test category?
--
-- Purpose / Business Value:
--   Unreturned laboratory results directly impair clinical decision-making
--   and patient safety.  This report serves two audiences:
--       1. Operational Triage (Part A — Order Detail): The Laboratory Manager
--          and department charge nurses use the per-order detail view to
--          prioritise chasing of specific results.  The UrgencyTier column
--          ('Within SLA' / 'Attention (3-6 days)' / 'Overdue (7+ days)')
--          surfaces the most critical cases without requiring manual date
--          arithmetic.  The @MinDaysElapsed parameter allows the team to
--          filter out fresh orders and focus exclusively on overdue ones.
--       2. Capacity Planning (Part B — Test-Type Summary): The Laboratory
--          Information Officer and Finance team use the aggregate summary to
--          identify which test categories have the highest pending-order
--          accumulation, supporting resource allocation, shift scheduling,
--          and instrument procurement decisions.
--
-- Information Returned:
--   Part A (Order Detail): Lab order ID, patient name, ordering doctor,
--   department, test name, standard price, current status, date requested,
--   days elapsed, urgency tier, and result text (NULL for Pending orders).
--   Part B (Test-Type Summary): Test name, total orders placed, pending
--   count, completed count, completion rate (%), and average standard price.
--
-- SQL Techniques Used:
--   Five-table INNER JOIN (LabOrders → Appointments → Patients / Doctors →
--   Departments → LabTestCatalog), DATEDIFF with GETDATE() for elapsed-days
--   computation, CASE for urgency tiering, GROUP BY with conditional
--   aggregation for per-test-type counts, CAST / NULLIF for percentage
--   columns, HAVING to exclude test types with no orders, OFFSET / FETCH
--   pagination on the detail result set only.
-- =============================================================================

CREATE OR ALTER VIEW dbo.vw_LabOrderDetail
AS
    SELECT
        lo.LabOrderID,
        lo.Status,
        lo.DateRequested,
        DATEDIFF(DAY, lo.DateRequested, GETDATE()) AS DaysElapsed,
        p.PatientID,
        p.FirstName + ' ' + p.LastName             AS PatientName,
        d.DoctorID,
        d.FirstName + ' ' + d.LastName             AS OrderingDoctor,
        dep.DepartmentName,
        lt.LabTestTypeID,
        lt.TestName,
        lt.Description                             AS TestDescription,
        lt.StandardPrice                           AS TestStandardPrice,
        lo.Result
    FROM       dbo.LabOrders      lo
    INNER JOIN dbo.Appointments   a   ON a.AppointmentID  = lo.AppointmentID
    INNER JOIN dbo.Patients       p   ON p.PatientID      = a.PatientID
    INNER JOIN dbo.Doctors        d   ON d.DoctorID       = a.DoctorID
    INNER JOIN dbo.Departments    dep ON dep.DepartmentID = d.DepartmentID
    INNER JOIN dbo.LabTestCatalog lt  ON lt.LabTestTypeID = lo.LabTestTypeID;
GO

-- -----------------------------------------------------------------------------
-- Stored Procedure — Report 4
-- Returns two result sets:
--   Result Set 1 — Paginated per-order detail (filtered by all parameters).
--   Result Set 2 — Test-type completion summary (filtered by @DepartmentName).
-- Parameters:
--   @StatusFilter     VARCHAR  Filter detail by order status.
--                              'Pending' | 'Completed' | NULL = all.
--   @MinDaysElapsed   INT      Include only orders older than N days.
--   @DepartmentName   NVARCHAR Restrict both result sets to a single
--                              department.  NULL = hospital-wide.
--   @PageNumber       INT      1-based page index (detail result set only).
--   @PageSize         INT      Rows per page, detail only.  Capped at 200.
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Report_LabOrderBacklog
    @StatusFilter     VARCHAR(20)   = 'Pending',
    @MinDaysElapsed   INT           = 0,
    @DepartmentName   NVARCHAR(100) = NULL,
    @PageNumber       INT           = 1,
    @PageSize         INT           = 20
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber < 1    SET @PageNumber = 1;
    IF @PageSize   < 1    SET @PageSize   = 20;
    IF @PageSize   > 200  SET @PageSize   = 200;

    -- ── Result Set 1: Per-order detail with urgency tiering ────────────────
    SELECT
        lod.LabOrderID,
        lod.PatientName,
        lod.OrderingDoctor,
        lod.DepartmentName,
        lod.TestName,
        lod.TestStandardPrice,
        lod.Status,
        lod.DateRequested,
        lod.DaysElapsed,
        CASE
            WHEN lod.DaysElapsed >= 7 THEN 'Overdue (7+ days)'
            WHEN lod.DaysElapsed >= 3 THEN 'Attention (3-6 days)'
            ELSE                           'Within SLA'
        END                               AS UrgencyTier,
        lod.Result
    FROM  dbo.vw_LabOrderDetail lod
    WHERE (@StatusFilter   IS NULL OR lod.Status         = @StatusFilter)
      AND (@DepartmentName IS NULL OR lod.DepartmentName = @DepartmentName)
      AND  lod.DaysElapsed >= @MinDaysElapsed
    ORDER BY lod.DaysElapsed DESC, lod.DateRequested ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;

    -- ── Result Set 2: Aggregated test-type completion summary ──────────────
    SELECT
        lt.TestName,
        COUNT(lo.LabOrderID)                                        AS TotalOrders,
        SUM(CASE WHEN lo.Status = 'Pending'   THEN 1 ELSE 0 END)   AS PendingOrders,
        SUM(CASE WHEN lo.Status = 'Completed' THEN 1 ELSE 0 END)   AS CompletedOrders,
        CAST(
            100.0
            * SUM(CASE WHEN lo.Status = 'Completed' THEN 1 ELSE 0 END)
            / NULLIF(COUNT(lo.LabOrderID), 0)
        AS DECIMAL(5,2))                                            AS CompletionRatePct,
        CAST(AVG(lt.StandardPrice) AS DECIMAL(10,2))               AS AvgTestStandardPrice
    FROM       dbo.LabOrders      lo
    INNER JOIN dbo.LabTestCatalog lt  ON lt.LabTestTypeID = lo.LabTestTypeID
    INNER JOIN dbo.Appointments   a   ON a.AppointmentID  = lo.AppointmentID
    INNER JOIN dbo.Doctors        d   ON d.DoctorID       = a.DoctorID
    INNER JOIN dbo.Departments    dep ON dep.DepartmentID = d.DepartmentID
    WHERE (@DepartmentName IS NULL OR dep.DepartmentName = @DepartmentName)
    GROUP BY lt.TestName
    HAVING COUNT(lo.LabOrderID) > 0
    ORDER BY PendingOrders DESC, TotalOrders DESC;
END;
GO

-- Sample execution: all pending orders, no minimum age, all departments
EXEC dbo.usp_Report_LabOrderBacklog
    @StatusFilter   = 'Pending',
    @MinDaysElapsed = 0,
    @DepartmentName = NULL,
    @PageNumber     = 1,
    @PageSize       = 20;
GO


-- =============================================================================
-- REPORT 5
-- =============================================================================
-- Title       : Monthly Revenue, Departmental Contribution and
--               Insurance vs. Out-of-Pocket Payment Analysis
--
-- Business Question:
--   What is the hospital's monthly billing revenue broken down by department?
--   What proportion of collected revenue originates from insurance payors
--   versus direct patient out-of-pocket payments, and which departments or
--   billing months are generating the greatest uncollected balances?
--
-- Purpose / Business Value:
--   The Chief Financial Officer, Finance Committee, and Department Heads
--   require this report as the primary tool for:
--       1. Revenue Performance Monitoring — monthly billed vs collected
--          figures reveal collection-rate trends over time, enabling early
--          detection of deteriorating payor behaviour before it impacts the
--          hospital's operating liquidity.
--       2. Payor-Mix Analysis — separating insurance-sourced collections from
--          out-of-pocket payments quantifies the hospital's dependency on
--          specific payor types.  The InsuranceContributionPct column
--          provides the evidence base for insurance contract renegotiations
--          and for assessing the financial impact of adding or dropping a
--          payor network.
--       3. Departmental Accountability — the ROLLUP subtotal rows consolidate
--          per-department detail into monthly totals within the same result
--          set, eliminating post-processing in external spreadsheets.
--          Department Heads can see their own contribution to the monthly
--          total and their share of outstanding balances at a glance.
--       4. Bad-Debt Risk Identification — departments with a consistently low
--          collection rate can be escalated to a targeted billing intervention
--          programme or reviewed for insurance-coverage gaps.
--
-- Information Returned:
--   Billing year, billing month (zero-padded string), department name (with
--   '-- Monthly Total --' label on ROLLUP rows), unique patient count,
--   total amount billed, total collected, total outstanding balance,
--   collection rate (%), insurance-sourced payments, out-of-pocket payments,
--   and insurance contribution percentage.  ROLLUP rows appear after each
--   month's department-level detail, providing a per-month all-departments
--   subtotal.
--
-- SQL Techniques Used:
--   Two Common Table Expressions — BillingFacts (bills enriched with year,
--   month, and department via a three-table JOIN chain) and PaymentSplit
--   (conditional aggregation splitting insurance from out-of-pocket payments
--   per bill) — joined via BillID.  GROUP BY with partial ROLLUP on
--   DepartmentName produces per-department rows and per-month subtotals in
--   one pass.  GROUPING() identifies rollup rows for labelling.  CAST /
--   NULLIF / ISNULL ensure safe numeric formatting throughout.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Stored Procedure — Report 5
-- Parameters:
--   @Year           INT      Restrict results to a single calendar year.
--                            NULL returns all available years.
--   @DepartmentName NVARCHAR Restrict results to a single department name.
--                            NULL returns all departments.
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Report_MonthlyRevenueAnalysis
    @Year           INT           = NULL,
    @DepartmentName NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- CTE 1: One row per bill, enriched with billing period and department.
    -- The three-table JOIN chain (Bills → Appointments → Doctors →
    -- Departments) is the only path from a bill to its clinical department,
    -- since Bills does not reference Departments directly.
    WITH BillingFacts AS (
        SELECT
            b.BillID,
            b.PatientID,
            YEAR(b.CreatedDate)   AS BillingYear,
            MONTH(b.CreatedDate)  AS BillingMonth,
            dep.DepartmentName,
            b.TotalAmount,
            b.PaidAmount,
            b.Balance
        FROM       dbo.Bills        b
        INNER JOIN dbo.Appointments a   ON a.AppointmentID  = b.AppointmentID
        INNER JOIN dbo.Doctors      d   ON d.DoctorID       = a.DoctorID
        INNER JOIN dbo.Departments  dep ON dep.DepartmentID = d.DepartmentID
        WHERE (@Year           IS NULL OR YEAR(b.CreatedDate)  = @Year)
          AND (@DepartmentName IS NULL OR dep.DepartmentName   = @DepartmentName)
    ),

    -- CTE 2: Per-bill payment breakdown split into insurance vs. all other
    -- (out-of-pocket) payment methods.  Grouped at bill level so the outer
    -- query can SUM across multiple bills per department per month without
    -- introducing fan-out from the Payments table.
    PaymentSplit AS (
        SELECT
            py.BillID,
            SUM(CASE WHEN py.PaymentMethod = 'Insurance'
                     THEN py.Amount ELSE 0 END)  AS InsurancePaid,
            SUM(CASE WHEN py.PaymentMethod <> 'Insurance'
                     THEN py.Amount ELSE 0 END)  AS OutOfPocketPaid
        FROM  dbo.Payments py
        GROUP BY py.BillID
    )

    SELECT
        bf.BillingYear,
        -- Zero-pad month number for consistent string sorting (01, 02 … 12)
        RIGHT('0' + CAST(bf.BillingMonth AS VARCHAR(2)), 2)        AS BillingMonth,
        -- GROUPING() returns 1 on the rollup (subtotal) row for DepartmentName,
        -- allowing a readable label to replace the NULL placeholder.
        CASE
            WHEN GROUPING(bf.DepartmentName) = 1 THEN '-- Monthly Total --'
            ELSE bf.DepartmentName
        END                                                        AS Department,
        COUNT(DISTINCT bf.PatientID)                               AS UniquePatientsBilled,
        CAST(SUM(bf.TotalAmount) AS DECIMAL(12,2))                 AS TotalBilled,
        CAST(SUM(bf.PaidAmount)  AS DECIMAL(12,2))                 AS TotalCollected,
        CAST(SUM(bf.Balance)     AS DECIMAL(12,2))                 AS TotalOutstanding,
        CAST(
            100.0 * SUM(bf.PaidAmount)
            / NULLIF(SUM(bf.TotalAmount), 0)
        AS DECIMAL(5,2))                                           AS CollectionRatePct,
        CAST(ISNULL(SUM(ps.InsurancePaid),   0) AS DECIMAL(12,2)) AS InsurancePaid,
        CAST(ISNULL(SUM(ps.OutOfPocketPaid), 0) AS DECIMAL(12,2)) AS OutOfPocketPaid,
        CAST(
            100.0 * ISNULL(SUM(ps.InsurancePaid), 0)
            / NULLIF(SUM(bf.PaidAmount), 0)
        AS DECIMAL(5,2))                                           AS InsuranceContributionPct
    FROM      BillingFacts bf
    LEFT JOIN PaymentSplit  ps ON ps.BillID = bf.BillID
    -- Partial ROLLUP: BillingYear and BillingMonth are fixed grouping columns;
    -- ROLLUP applies only to DepartmentName, producing one additional subtotal
    -- row per year/month combination (all departments combined).
    GROUP BY bf.BillingYear, bf.BillingMonth, ROLLUP(bf.DepartmentName)
    ORDER BY
        bf.BillingYear,
        bf.BillingMonth,
        GROUPING(bf.DepartmentName),   -- department detail rows (0) before rollup (1)
        bf.DepartmentName;
END;
GO

-- Sample execution: all years and departments (includes monthly rollup rows)
EXEC dbo.usp_Report_MonthlyRevenueAnalysis
    @Year           = NULL,
    @DepartmentName = NULL;
GO

-- Sample execution: calendar year 2025 only
EXEC dbo.usp_Report_MonthlyRevenueAnalysis
    @Year           = 2025,
    @DepartmentName = NULL;
GO
