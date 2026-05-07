-- =============================================================================
-- HospitalDB — Billing and Financial Reports
-- File        : sql/07_billing_financial_reports.sql
-- Author      : Hospital Information Systems
-- Date        : 2026-05-07
-- Description :
--   Three operational billing and financial reports for HospitalDB.
--   Each report is implemented as a reusable VIEW (dbo.vw_*) that encapsulates
--   the core join and aggregation logic, and a STORED PROCEDURE
--   (dbo.usp_Billing_*) that exposes parameter-driven filtering and
--   OFFSET/FETCH pagination.
--
--   Reports included:
--     1. Unpaid and Overdue Bills          — accounts-receivable aging with
--                                           bucket classification (0-30,
--                                           31-60, 61-90, 90+ days overdue)
--     2. Revenue Summary                   — collected revenue by department
--                                           and service type, with period
--                                           grouping and contribution %
--     3. Payment Method Analysis           — transaction volume and value
--                                           broken down by payment method,
--                                           including trend and share %
--
--   Advanced SQL features demonstrated:
--     – Multi-table INNER and LEFT JOINs across billing, patient, and
--       scheduling domains
--     – DATEDIFF-based aging bucket derivation using CASE expressions
--     – GROUP BY with SUM, COUNT, AVG, MIN, MAX aggregate functions
--     – Conditional aggregation (CASE inside SUM/COUNT)
--     – Common Table Expressions (CTEs) for modular decomposition
--     – Window function: SUM() OVER () for grand-total share percentages
--     – ROLLUP for hierarchical subtotals
--     – GROUPING() to identify and label rollup rows
--     – OFFSET / FETCH NEXT for server-side pagination
--     – NULLIF / ISNULL for safe division and null coalescing
--     – HAVING clause for post-aggregation filtering
--     – Correlated subquery for last-payment lookup
-- =============================================================================

USE HospitalDB;
GO

-- =============================================================================
-- REPORT 1
-- =============================================================================
-- Title       : Unpaid and Overdue Bills — Accounts-Receivable Aging Report
--
-- Business Question:
--   Which patients currently have outstanding (Unpaid or Partially Paid) bills,
--   how long have those bills been unpaid, and into which aging bucket does each
--   balance fall — 0-30 days, 31-60 days, 61-90 days, or 90+ days overdue?
--
-- Purpose / Business Value:
--   This is the primary accounts-receivable (AR) collection tool for the
--   Billing Department.  Aging buckets are the industry-standard mechanism for
--   prioritising collection effort: newer balances (0-30 days) may need only an
--   automated reminder, while 61-90 day and 90+ day accounts typically require
--   direct outreach, payment-plan negotiation, or escalation to a collections
--   agency.  The report helps:
--       – Calculate the total AR exposure on any given day (gross amount owed
--         vs. amount already collected).
--       – Identify patients at risk of becoming bad debt and flag them for
--         proactive follow-up before the 90-day threshold.
--       – Measure collection efficiency over time by comparing the aging
--         distribution month-over-month.
--       – Support month-end close: Finance can quickly see exactly what portion
--         of total revenue has been received and what remains outstanding.
--   The @AgingBucket, @DepartmentName, and @MinBalance parameters let billing
--   staff generate targeted collection lists (e.g. all 90+ day accounts with a
--   balance > $200 in the Emergency Department) without ad-hoc query writing.
--
-- Information Returned:
--   Bill ID, patient full name, patient phone, attending doctor, department,
--   appointment date, bill created date, days since bill was raised, aging
--   bucket label, total billed amount, amount already paid, current balance,
--   bill status, date of the most recent payment on the bill, and the number of
--   payment transactions recorded against it.
--
-- Advanced Techniques Used:
--   DATEDIFF to compute DaysOutstanding; CASE expression to derive AgingBucket
--   label; correlated subquery for LastPaymentDate; LEFT JOIN Payments for
--   PaymentCount; INNER JOINs across Bills → Patients, Appointments, Doctors,
--   Departments; OFFSET / FETCH NEXT pagination in the stored procedure.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- View: dbo.vw_UnpaidBills
-- Encapsulates the join logic and aging derivation for all outstanding bills.
-- Includes both Unpaid and Partially Paid statuses so the stored procedure can
-- filter by either or both.
-- -----------------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_UnpaidBills
AS
SELECT
    b.BillID,
    b.PatientID,
    p.FirstName + ' ' + p.LastName              AS PatientFullName,
    p.Phone                                     AS PatientPhone,
    p.Email                                     AS PatientEmail,
    b.AppointmentID,
    a.AppointmentDate,
    dept.DepartmentName,
    dr.DoctorID,
    dr.FirstName + ' ' + dr.LastName            AS DoctorFullName,
    b.CreatedDate                               AS BillCreatedDate,
    DATEDIFF(DAY, b.CreatedDate, GETDATE())     AS DaysOutstanding,
    CASE
        WHEN DATEDIFF(DAY, b.CreatedDate, GETDATE()) BETWEEN 0  AND 30 THEN '0-30 Days'
        WHEN DATEDIFF(DAY, b.CreatedDate, GETDATE()) BETWEEN 31 AND 60 THEN '31-60 Days'
        WHEN DATEDIFF(DAY, b.CreatedDate, GETDATE()) BETWEEN 61 AND 90 THEN '61-90 Days'
        ELSE '90+ Days'
    END                                         AS AgingBucket,
    -- Sort key so ORDER BY AgingBucket is chronologically meaningful
    CASE
        WHEN DATEDIFF(DAY, b.CreatedDate, GETDATE()) BETWEEN 0  AND 30 THEN 1
        WHEN DATEDIFF(DAY, b.CreatedDate, GETDATE()) BETWEEN 31 AND 60 THEN 2
        WHEN DATEDIFF(DAY, b.CreatedDate, GETDATE()) BETWEEN 61 AND 90 THEN 3
        ELSE 4
    END                                         AS AgingBucketSortKey,
    b.TotalAmount,
    b.PaidAmount,
    b.Balance,
    b.BillStatus,
    -- Correlated subquery: most recent payment date for this bill
    (
        SELECT MAX(py.PaymentDate)
        FROM   dbo.Payments py
        WHERE  py.BillID = b.BillID
    )                                           AS LastPaymentDate,
    -- Number of payment transactions already recorded
    (
        SELECT COUNT(*)
        FROM   dbo.Payments py
        WHERE  py.BillID = b.BillID
    )                                           AS PaymentTransactionCount
FROM      dbo.Bills        b
INNER JOIN dbo.Patients    p    ON p.PatientID     = b.PatientID
INNER JOIN dbo.Appointments a   ON a.AppointmentID = b.AppointmentID
INNER JOIN dbo.Doctors     dr   ON dr.DoctorID     = a.DoctorID
INNER JOIN dbo.Departments dept ON dept.DepartmentID = dr.DepartmentID
WHERE b.BillStatus IN ('Unpaid', 'Partially Paid');
GO

-- -----------------------------------------------------------------------------
-- Stored Procedure: dbo.usp_Billing_UnpaidBills
--
-- Parameters:
--   @AgingBucket     VARCHAR(20)    — '0-30 Days' | '31-60 Days' |
--                                     '61-90 Days' | '90+ Days' | NULL = all
--   @DepartmentName  VARCHAR(100)   — filter by department; NULL = all
--   @MinBalance      DECIMAL(10,2)  — minimum outstanding balance; default 0
--   @BillStatus      VARCHAR(30)    — 'Unpaid' | 'Partially Paid' | NULL = both
--   @PageNumber      INT            — 1-based page index; default 1
--   @PageSize        INT            — rows per page; default 25
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Billing_UnpaidBills
    @AgingBucket    VARCHAR(20)   = NULL,
    @DepartmentName VARCHAR(100)  = NULL,
    @MinBalance     DECIMAL(10,2) = 0,
    @BillStatus     VARCHAR(30)   = NULL,
    @PageNumber     INT           = 1,
    @PageSize       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        BillID,
        PatientFullName,
        PatientPhone,
        PatientEmail,
        DoctorFullName,
        DepartmentName,
        AppointmentDate,
        BillCreatedDate,
        DaysOutstanding,
        AgingBucket,
        TotalAmount,
        PaidAmount,
        Balance,
        BillStatus,
        LastPaymentDate,
        PaymentTransactionCount
    FROM  dbo.vw_UnpaidBills
    WHERE (@AgingBucket    IS NULL OR AgingBucket    = @AgingBucket)
      AND (@DepartmentName IS NULL OR DepartmentName = @DepartmentName)
      AND (@BillStatus     IS NULL OR BillStatus     = @BillStatus)
      AND Balance >= @MinBalance
    ORDER BY
        AgingBucketSortKey DESC,   -- most overdue first
        Balance            DESC    -- largest balance within each bucket first
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH  NEXT @PageSize ROWS ONLY;
END;
GO

-- Sample executions:
-- All unpaid/partially-paid bills, worst-aged first:
EXEC dbo.usp_Billing_UnpaidBills;

-- Only bills overdue 90+ days with a balance over $100:
EXEC dbo.usp_Billing_UnpaidBills
    @AgingBucket = '90+ Days',
    @MinBalance  = 100.00;

-- Emergency Medicine unpaid bills only:
EXEC dbo.usp_Billing_UnpaidBills
    @DepartmentName = 'Emergency Medicine',
    @BillStatus     = 'Unpaid';
GO


-- =============================================================================
-- REPORT 2
-- =============================================================================
-- Title       : Revenue Summary — Collected Revenue by Department, Service,
--               and Period
--
-- Business Question:
--   How much revenue has been collected (i.e. money actually paid, not merely
--   billed) across each department and service type over a given time period,
--   and what percentage of total collected revenue does each department or
--   service contribute?
--
-- Purpose / Business Value:
--   The Finance and Executive Leadership teams use this report as the
--   organisation's primary revenue performance dashboard:
--       – Department heads can track whether their units are hitting revenue
--         targets and identify high-value service lines that drive the most
--         income, informing staffing, equipment procurement, and capacity
--         planning decisions.
--       – The Finance team uses the monthly grouping mode to prepare monthly
--         management accounts and spot seasonality or anomalous drops in
--         collection rates.
--       – Contribution percentages expose which departments are cross-subsidising
--         others, enabling more transparent internal cost-allocation discussions.
--       – Comparing TotalBilled vs. TotalCollected highlights the collection-gap
--         (unrealised revenue) by service area, which feeds directly into the AR
--         aging report (Report 1) for follow-up.
--   The @GroupBy parameter allows the same stored procedure to produce three
--   distinct views of the data — by Department, by Service, or by Month — without
--   maintaining separate queries.
--
-- Information Returned:
--   Grouping dimension (department name, service name, or period label), number
--   of bills in the group, number of individual line items, total gross amount
--   billed, total amount collected (paid), outstanding balance remaining,
--   collection rate as a percentage, and the group's percentage share of the
--   total collected revenue across all groups in the result set.
--
-- Advanced Techniques Used:
--   Two CTEs — BillingFacts (joins BillItems → Bills → Appointments → Doctors →
--   Departments → ServiceCatalog + filters) and RevenueSummary (aggregates per
--   chosen dimension) — plus a window function SUM(...) OVER () for grand-total
--   share percentages; NULLIF for safe-division guard on CollectionRatePct;
--   ROLLUP on the grouping column for a grand-total summary row; GROUPING() to
--   label the rollup row; OFFSET / FETCH NEXT pagination.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- View: dbo.vw_RevenueSummary
-- Base view joining billing line items through to departments and services.
-- The stored procedure aggregates over this view with its @GroupBy logic.
-- -----------------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_RevenueSummary
AS
SELECT
    bi.BillItemID,
    bi.BillID,
    bi.ServiceID,
    sc.ServiceName,
    bi.Quantity,
    bi.UnitPrice,
    bi.LineTotal                                AS BilledLineTotal,
    -- Proportional payment: allocate PaidAmount across line items by weight
    CASE
        WHEN b.TotalAmount = 0 THEN 0
        ELSE ROUND(b.PaidAmount * (bi.LineTotal / b.TotalAmount), 2)
    END                                         AS CollectedLineTotal,
    b.BillStatus,
    b.CreatedDate                               AS BillDate,
    YEAR(b.CreatedDate)                         AS BillYear,
    MONTH(b.CreatedDate)                        AS BillMonth,
    -- ISO period label e.g. "2025-03"
    CAST(YEAR(b.CreatedDate) AS VARCHAR(4))
        + '-'
        + RIGHT('0' + CAST(MONTH(b.CreatedDate) AS VARCHAR(2)), 2)
                                                AS PeriodLabel,
    a.AppointmentID,
    a.AppointmentDate,
    p.PatientID,
    p.FirstName + ' ' + p.LastName              AS PatientFullName,
    dr.DoctorID,
    dr.FirstName + ' ' + dr.LastName            AS DoctorFullName,
    dept.DepartmentID,
    dept.DepartmentName
FROM      dbo.BillItems      bi
INNER JOIN dbo.Bills          b    ON b.BillID         = bi.BillID
INNER JOIN dbo.Appointments   a    ON a.AppointmentID  = b.AppointmentID
INNER JOIN dbo.Patients       p    ON p.PatientID      = b.PatientID
INNER JOIN dbo.Doctors        dr   ON dr.DoctorID      = a.DoctorID
INNER JOIN dbo.Departments    dept ON dept.DepartmentID = dr.DepartmentID
INNER JOIN dbo.ServiceCatalog sc   ON sc.ServiceID     = bi.ServiceID;
GO

-- -----------------------------------------------------------------------------
-- Stored Procedure: dbo.usp_Billing_RevenueSummary
--
-- Parameters:
--   @GroupBy         VARCHAR(20)   — 'Department' | 'Service' | 'Month'
--                                    (default 'Department')
--   @Year            INT           — calendar year filter; NULL = all years
--   @Month           INT           — calendar month (1-12); NULL = all months
--   @DepartmentName  VARCHAR(100)  — limit to one department; NULL = all
--   @MinCollected    DECIMAL(10,2) — minimum collected amount in the group;
--                                    default 0 (excludes zero-revenue groups)
--   @PageNumber      INT           — 1-based page index; default 1
--   @PageSize        INT           — rows per page; default 25
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Billing_RevenueSummary
    @GroupBy        VARCHAR(20)   = 'Department',
    @Year           INT           = NULL,
    @Month          INT           = NULL,
    @DepartmentName VARCHAR(100)  = NULL,
    @MinCollected   DECIMAL(10,2) = 0,
    @PageNumber     INT           = 1,
    @PageSize       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;

    -- Step 1: Filter the base view rows that fall within the requested scope.
    WITH FilteredFacts AS (
        SELECT *
        FROM   dbo.vw_RevenueSummary
        WHERE  (@Year           IS NULL OR BillYear      = @Year)
          AND  (@Month          IS NULL OR BillMonth     = @Month)
          AND  (@DepartmentName IS NULL OR DepartmentName = @DepartmentName)
    ),
    -- Step 2: Aggregate by the chosen dimension, with ROLLUP for grand total.
    Aggregated AS (
        SELECT
            -- Dimension column driven by @GroupBy
            CASE @GroupBy
                WHEN 'Service'     THEN ServiceName
                WHEN 'Month'       THEN PeriodLabel
                ELSE                    DepartmentName    -- default: Department
            END                                  AS GroupingDimension,
            COUNT(DISTINCT BillID)               AS BillCount,
            COUNT(BillItemID)                    AS LineItemCount,
            SUM(BilledLineTotal)                 AS TotalBilled,
            SUM(CollectedLineTotal)              AS TotalCollected,
            SUM(BilledLineTotal
                - CollectedLineTotal)            AS TotalOutstanding,
            -- Collection rate: what fraction of billed revenue was collected
            ROUND(
                100.0 * SUM(CollectedLineTotal)
                / NULLIF(SUM(BilledLineTotal), 0),
            2)                                   AS CollectionRatePct
        FROM FilteredFacts
        GROUP BY ROLLUP (
            CASE @GroupBy
                WHEN 'Service' THEN ServiceName
                WHEN 'Month'   THEN PeriodLabel
                ELSE               DepartmentName
            END
        )
    )
    -- Step 3: Add window-function share % and label the ROLLUP grand-total row.
    SELECT
        ISNULL(GroupingDimension, 'GRAND TOTAL')  AS GroupingDimension,
        BillCount,
        LineItemCount,
        TotalBilled,
        TotalCollected,
        TotalOutstanding,
        CollectionRatePct,
        -- Each group's share of the grand total collected revenue
        ROUND(
            100.0 * TotalCollected
            / NULLIF(SUM(TotalCollected) OVER (), 0),
        2)                                         AS ShareOfTotalCollectedPct,
        -- Flag the ROLLUP summary row for easy client-side identification
        CASE WHEN GroupingDimension IS NULL THEN 1 ELSE 0 END AS IsGrandTotal
    FROM  Aggregated
    WHERE TotalCollected >= @MinCollected
       OR GroupingDimension IS NULL    -- always include grand total row
    ORDER BY
        IsGrandTotal ASC,
        TotalCollected DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH  NEXT @PageSize ROWS ONLY;
END;
GO

-- Sample executions:
-- Revenue by department for all time:
EXEC dbo.usp_Billing_RevenueSummary;

-- Revenue by service for the year 2025:
EXEC dbo.usp_Billing_RevenueSummary
    @GroupBy = 'Service',
    @Year    = 2025;

-- Monthly revenue trend for Cardiology in 2025:
EXEC dbo.usp_Billing_RevenueSummary
    @GroupBy        = 'Month',
    @Year           = 2025,
    @DepartmentName = 'Cardiology';
GO


-- =============================================================================
-- REPORT 3
-- =============================================================================
-- Title       : Payment Method Analysis — Transaction Volume, Value, and
--               Trend by Payment Method
--
-- Business Question:
--   Which payment methods (Cash, Credit Card, Insurance, etc.) are patients
--   using, how many transactions has each method generated, how much revenue
--   has each method contributed, and how does each method's share of total
--   payments trend over time?
--
-- Purpose / Business Value:
--   Understanding payment-method distribution is critical for both operational
--   and strategic finance decisions:
--       – Treasury / Cash Management: A high proportion of cash payments
--         requires more robust cash-handling procedures; a shift towards
--         card-based payments may trigger a review of merchant-fee contracts.
--       – Insurance Reconciliation: Seeing exactly how much revenue is arriving
--         via insurance reimbursement (vs. direct patient payment) helps the
--         billing team track insurance-reimbursement lag and flag overdue claims.
--       – Payment Failure and Fraud Detection: An unusually large number of
--         low-value transactions through a single method in a short period may
--         indicate data-entry errors or suspicious activity worth investigating.
--       – Patient Experience: If a particular payment method accounts for a
--         growing share of transactions, it may justify adding
--         self-service kiosks or online payment portals for that method.
--   The procedure returns TWO result sets:
--       1. Detailed transaction list — every individual payment with patient
--          and bill context, filtered by date range and/or method.
--       2. Aggregated summary by payment method — total transactions, total
--          amount, average transaction size, min/max amounts, and each method's
--          percentage share of the overall total collected in the date range.
--
-- Information Returned:
--   Result set 1 (detail): Payment ID, payment date, payment method, amount,
--   reference number, bill ID, bill status, patient full name, doctor full name,
--   department name, appointment date.
--   Result set 2 (summary): Payment method, transaction count, total amount,
--   average amount, minimum amount, maximum amount, first and last payment
--   dates (spread), and percentage share of total payments by value and volume.
--
-- Advanced Techniques Used:
--   Two separate SELECT statements within a single stored procedure for dual
--   result sets; window functions SUM(...) OVER () and COUNT(...) OVER () for
--   grand-total share percentages in the summary result set; GROUP BY on
--   PaymentMethod; INNER JOINs across Payments → Bills → Appointments →
--   Patients → Doctors → Departments; OFFSET / FETCH NEXT on the detail result
--   set; HAVING to exclude methods with zero transactions.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- View: dbo.vw_PaymentDetail
-- Flat view of every payment transaction enriched with billing, patient,
-- doctor, and department context.  Powers both result sets in the SP.
-- -----------------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_PaymentDetail
AS
SELECT
    py.PaymentID,
    py.PaymentDate,
    YEAR(py.PaymentDate)                        AS PaymentYear,
    MONTH(py.PaymentDate)                       AS PaymentMonth,
    py.PaymentMethod,
    py.Amount,
    py.ReferenceNumber,
    b.BillID,
    b.TotalAmount                               AS BillTotalAmount,
    b.Balance                                   AS BillBalance,
    b.BillStatus,
    b.CreatedDate                               AS BillCreatedDate,
    p.PatientID,
    p.FirstName + ' ' + p.LastName              AS PatientFullName,
    p.Phone                                     AS PatientPhone,
    a.AppointmentID,
    a.AppointmentDate,
    dr.DoctorID,
    dr.FirstName + ' ' + dr.LastName            AS DoctorFullName,
    dept.DepartmentID,
    dept.DepartmentName
FROM      dbo.Payments      py
INNER JOIN dbo.Bills         b    ON b.BillID          = py.BillID
INNER JOIN dbo.Appointments  a    ON a.AppointmentID   = b.AppointmentID
INNER JOIN dbo.Patients      p    ON p.PatientID       = b.PatientID
INNER JOIN dbo.Doctors       dr   ON dr.DoctorID       = a.DoctorID
INNER JOIN dbo.Departments   dept ON dept.DepartmentID = dr.DepartmentID;
GO

-- -----------------------------------------------------------------------------
-- Stored Procedure: dbo.usp_Billing_PaymentMethodAnalysis
--
-- Parameters:
--   @StartDate       DATE          — payment date lower bound; NULL = no limit
--   @EndDate         DATE          — payment date upper bound; NULL = no limit
--   @PaymentMethod   VARCHAR(40)   — filter to one method; NULL = all methods
--   @DepartmentName  VARCHAR(100)  — filter by department; NULL = all
--   @PageNumber      INT           — 1-based page (applies to detail RS only)
--   @PageSize        INT           — rows per page for detail RS; default 25
--
-- Returns:
--   Result Set 1 — Paginated transaction-level detail
--   Result Set 2 — Unpaginated aggregated summary by payment method
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Billing_PaymentMethodAnalysis
    @StartDate      DATE         = NULL,
    @EndDate        DATE         = NULL,
    @PaymentMethod  VARCHAR(40)  = NULL,
    @DepartmentName VARCHAR(100) = NULL,
    @PageNumber     INT          = 1,
    @PageSize       INT          = 25
AS
BEGIN
    SET NOCOUNT ON;

    -- -------------------------------------------------------------------------
    -- Result Set 1: Paginated transaction-level detail
    -- -------------------------------------------------------------------------
    SELECT
        PaymentID,
        PaymentDate,
        PaymentMethod,
        Amount,
        ReferenceNumber,
        BillID,
        BillStatus,
        PatientFullName,
        PatientPhone,
        DoctorFullName,
        DepartmentName,
        AppointmentDate
    FROM  dbo.vw_PaymentDetail
    WHERE (@StartDate      IS NULL OR CAST(PaymentDate AS DATE) >= @StartDate)
      AND (@EndDate        IS NULL OR CAST(PaymentDate AS DATE) <= @EndDate)
      AND (@PaymentMethod  IS NULL OR PaymentMethod              = @PaymentMethod)
      AND (@DepartmentName IS NULL OR DepartmentName             = @DepartmentName)
    ORDER BY PaymentDate DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH  NEXT @PageSize ROWS ONLY;

    -- -------------------------------------------------------------------------
    -- Result Set 2: Aggregated summary by payment method
    -- Window functions compute each method's share of the total collected
    -- within the same filtered scope, without a self-join.
    -- -------------------------------------------------------------------------
    SELECT
        PaymentMethod,
        COUNT(PaymentID)                                    AS TransactionCount,
        SUM(Amount)                                         AS TotalAmountCollected,
        ROUND(AVG(Amount), 2)                               AS AvgTransactionAmount,
        MIN(Amount)                                         AS MinTransactionAmount,
        MAX(Amount)                                         AS MaxTransactionAmount,
        CAST(MIN(PaymentDate) AS DATE)                      AS FirstPaymentDate,
        CAST(MAX(PaymentDate) AS DATE)                      AS LastPaymentDate,
        -- Days between first and last payment for this method (activity spread)
        DATEDIFF(
            DAY,
            MIN(PaymentDate),
            MAX(PaymentDate)
        )                                                   AS ActivitySpreadDays,
        -- Share of total collected value (window over the same filtered set)
        ROUND(
            100.0 * SUM(Amount)
            / NULLIF(SUM(SUM(Amount)) OVER (), 0),
        2)                                                  AS ShareOfTotalValuePct,
        -- Share of total transaction count
        ROUND(
            100.0 * COUNT(PaymentID)
            / NULLIF(SUM(COUNT(PaymentID)) OVER (), 0),
        2)                                                  AS ShareOfTotalVolumePct
    FROM  dbo.vw_PaymentDetail
    WHERE (@StartDate      IS NULL OR CAST(PaymentDate AS DATE) >= @StartDate)
      AND (@EndDate        IS NULL OR CAST(PaymentDate AS DATE) <= @EndDate)
      AND (@PaymentMethod  IS NULL OR PaymentMethod              = @PaymentMethod)
      AND (@DepartmentName IS NULL OR DepartmentName             = @DepartmentName)
    GROUP BY PaymentMethod
    HAVING COUNT(PaymentID) > 0
    ORDER BY TotalAmountCollected DESC;
END;
GO

-- Sample executions:
-- All payment methods, all time — both result sets:
EXEC dbo.usp_Billing_PaymentMethodAnalysis;

-- Credit card payments in 2025 only:
EXEC dbo.usp_Billing_PaymentMethodAnalysis
    @PaymentMethod = 'Credit Card',
    @StartDate     = '2025-01-01',
    @EndDate       = '2025-12-31';

-- All methods for Cardiology department:
EXEC dbo.usp_Billing_PaymentMethodAnalysis
    @DepartmentName = 'Cardiology';
GO


-- =============================================================================
-- REPORT 4
-- =============================================================================
-- Title       : Top-Paying Patients — Lifetime Value and Payment Behaviour
--               Ranking
--
-- Business Question:
--   Which patients have contributed the most revenue to the organisation through
--   actual payments (not merely billings), how many visits have they made, what
--   is their average spend per visit, and how does their outstanding balance
--   compare to what they have paid?
--
-- Purpose / Business Value:
--   Understanding patient lifetime value (LTV) serves several strategic
--   purposes:
--       – Patient Retention: High-value patients represent a disproportionate
--         share of revenue.  Identifying them enables targeted loyalty
--         programmes, priority scheduling, and proactive outreach that reduces
--         churn.
--       – Billing Risk Assessment: A patient who has historically paid large
--         bills consistently is a lower collection risk than a new patient; this
--         context helps billing staff decide when to extend credit or waive
--         late fees.
--       – Marketing and Service Planning: If top-paying patients cluster in
--         specific departments or age groups, the organisation can tailor
--         capacity and service development accordingly.
--       – Executive Reporting: Finance leadership uses LTV rankings during
--         budget reviews to model revenue concentration risk (e.g. "our top 10
--         patients account for X% of total collections").
--   The @TopN parameter caps the result set (e.g. top 10, top 25), and
--   @DepartmentName allows a department head to see their own patient LTV
--   rankings without seeing unrelated departments.
--
-- Information Returned:
--   LTV rank (dense rank by total amount paid), patient ID, full name, date of
--   birth, total bills raised, total amount billed, total amount paid (lifetime
--   value), current outstanding balance across all bills, collection rate %,
--   number of payment transactions, average spend per bill, preferred payment
--   method (modal method by transaction count), date of first and most recent
--   payment, and count of departments visited.
--
-- Advanced Techniques Used:
--   CTE (PatientPaymentFacts) pre-aggregates per-patient metrics from a
--   5-table JOIN (Patients → Bills → Payments → Appointments → Doctors →
--   Departments); a second CTE (ModalMethod) uses a correlated window
--   ROW_NUMBER() OVER (PARTITION BY PatientID ORDER BY txn_count DESC) to
--   identify each patient's most-used payment method without a self-join;
--   DENSE_RANK() OVER (ORDER BY TotalAmountPaid DESC) for the LTV rank;
--   TOP (@TopN) WITH TIES to honour @TopN while keeping ties at the boundary;
--   NULLIF for safe-division guards.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- View: dbo.vw_PatientLifetimeValue
-- Per-patient aggregated billing and payment summary across all time.
-- Includes preferred payment method derived via ROW_NUMBER window function.
-- -----------------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_PatientLifetimeValue
AS
WITH PaymentFacts AS (
    -- One row per payment transaction enriched with patient and department
    SELECT
        p.PatientID,
        p.FirstName + ' ' + p.LastName          AS PatientFullName,
        p.DOB,
        py.PaymentID,
        py.Amount                               AS PaymentAmount,
        py.PaymentDate,
        py.PaymentMethod,
        b.BillID,
        b.TotalAmount                           AS BillTotalAmount,
        b.Balance                               AS BillBalance,
        dept.DepartmentID
    FROM      dbo.Payments     py
    INNER JOIN dbo.Bills        b    ON b.BillID          = py.BillID
    INNER JOIN dbo.Patients     p    ON p.PatientID       = b.PatientID
    INNER JOIN dbo.Appointments a    ON a.AppointmentID   = b.AppointmentID
    INNER JOIN dbo.Doctors      dr   ON dr.DoctorID       = a.DoctorID
    INNER JOIN dbo.Departments  dept ON dept.DepartmentID = dr.DepartmentID
),
-- Rank payment methods per patient; rank 1 = most frequently used method
MethodRanked AS (
    SELECT
        PatientID,
        PaymentMethod,
        COUNT(PaymentID)     AS MethodTxnCount,
        ROW_NUMBER() OVER (
            PARTITION BY PatientID
            ORDER BY     COUNT(PaymentID) DESC
        )                    AS MethodRank
    FROM  PaymentFacts
    GROUP BY PatientID, PaymentMethod
),
BillFacts AS (
    -- Aggregate at bill level (independent of payments) to avoid double-count
    SELECT
        PatientID,
        COUNT(DISTINCT BillID)  AS TotalBillCount,
        SUM(TotalAmount)        AS TotalAmountBilled,
        SUM(Balance)            AS TotalOutstandingBalance
    FROM  dbo.Bills
    GROUP BY PatientID
)
SELECT
    pf.PatientID,
    pf.PatientFullName,
    pf.DOB,
    bf.TotalBillCount,
    bf.TotalAmountBilled,
    SUM(pf.PaymentAmount)                       AS TotalAmountPaid,
    bf.TotalOutstandingBalance,
    ROUND(
        100.0 * SUM(pf.PaymentAmount)
        / NULLIF(bf.TotalAmountBilled, 0),
    2)                                          AS CollectionRatePct,
    COUNT(pf.PaymentID)                         AS PaymentTransactionCount,
    ROUND(
        SUM(pf.PaymentAmount)
        / NULLIF(CAST(bf.TotalBillCount AS DECIMAL(10,2)), 0),
    2)                                          AS AvgSpendPerBill,
    mm.PaymentMethod                            AS PreferredPaymentMethod,
    CAST(MIN(pf.PaymentDate) AS DATE)           AS FirstPaymentDate,
    CAST(MAX(pf.PaymentDate) AS DATE)           AS MostRecentPaymentDate,
    COUNT(DISTINCT pf.DepartmentID)             AS DepartmentsVisited
FROM       PaymentFacts  pf
INNER JOIN BillFacts     bf ON bf.PatientID  = pf.PatientID
INNER JOIN MethodRanked  mm ON mm.PatientID  = pf.PatientID
                            AND mm.MethodRank = 1
GROUP BY
    pf.PatientID,
    pf.PatientFullName,
    pf.DOB,
    bf.TotalBillCount,
    bf.TotalAmountBilled,
    bf.TotalOutstandingBalance,
    mm.PaymentMethod;
GO

-- -----------------------------------------------------------------------------
-- Stored Procedure: dbo.usp_Billing_TopPayingPatients
--
-- Parameters:
--   @TopN            INT           — number of top patients to return; default 10
--   @DepartmentName  VARCHAR(100)  — restrict to patients who visited this
--                                    department; NULL = all departments
--   @StartDate       DATE          — only count payments on/after this date;
--                                    NULL = all time
--   @EndDate         DATE          — only count payments on/before this date;
--                                    NULL = all time
--   @MinTotalPaid    DECIMAL(10,2) — minimum lifetime payments to qualify;
--                                    default 0
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Billing_TopPayingPatients
    @TopN           INT           = 10,
    @DepartmentName VARCHAR(100)  = NULL,
    @StartDate      DATE          = NULL,
    @EndDate        DATE          = NULL,
    @MinTotalPaid   DECIMAL(10,2) = 0
AS
BEGIN
    SET NOCOUNT ON;

    WITH FilteredPayments AS (
        -- Re-aggregate with optional date and department filters applied
        SELECT
            p.PatientID,
            p.FirstName + ' ' + p.LastName          AS PatientFullName,
            p.DOB,
            SUM(py.Amount)                          AS TotalAmountPaid,
            COUNT(py.PaymentID)                     AS PaymentTransactionCount,
            CAST(MIN(py.PaymentDate) AS DATE)       AS FirstPaymentDate,
            CAST(MAX(py.PaymentDate) AS DATE)       AS MostRecentPaymentDate,
            COUNT(DISTINCT dept.DepartmentID)       AS DepartmentsVisited
        FROM      dbo.Payments     py
        INNER JOIN dbo.Bills        b    ON b.BillID          = py.BillID
        INNER JOIN dbo.Patients     p    ON p.PatientID       = b.PatientID
        INNER JOIN dbo.Appointments a    ON a.AppointmentID   = b.AppointmentID
        INNER JOIN dbo.Doctors      dr   ON dr.DoctorID       = a.DoctorID
        INNER JOIN dbo.Departments  dept ON dept.DepartmentID = dr.DepartmentID
        WHERE (@StartDate      IS NULL OR CAST(py.PaymentDate AS DATE) >= @StartDate)
          AND (@EndDate        IS NULL OR CAST(py.PaymentDate AS DATE) <= @EndDate)
          AND (@DepartmentName IS NULL OR dept.DepartmentName           = @DepartmentName)
        GROUP BY p.PatientID, p.FirstName, p.LastName, p.DOB
        HAVING SUM(py.Amount) >= @MinTotalPaid
    ),
    BillTotals AS (
        SELECT
            PatientID,
            COUNT(DISTINCT BillID)  AS TotalBillCount,
            SUM(TotalAmount)        AS TotalAmountBilled,
            SUM(Balance)            AS TotalOutstandingBalance
        FROM  dbo.Bills
        GROUP BY PatientID
    ),
    -- Preferred payment method within the same date/department filter scope
    MethodRanked AS (
        SELECT
            b.PatientID,
            py.PaymentMethod,
            COUNT(py.PaymentID) AS MethodTxnCount,
            ROW_NUMBER() OVER (
                PARTITION BY b.PatientID
                ORDER BY     COUNT(py.PaymentID) DESC
            )                   AS MethodRank
        FROM      dbo.Payments     py
        INNER JOIN dbo.Bills        b    ON b.BillID          = py.BillID
        INNER JOIN dbo.Appointments a    ON a.AppointmentID   = b.AppointmentID
        INNER JOIN dbo.Doctors      dr   ON dr.DoctorID       = a.DoctorID
        INNER JOIN dbo.Departments  dept ON dept.DepartmentID = dr.DepartmentID
        WHERE (@StartDate      IS NULL OR CAST(py.PaymentDate AS DATE) >= @StartDate)
          AND (@EndDate        IS NULL OR CAST(py.PaymentDate AS DATE) <= @EndDate)
          AND (@DepartmentName IS NULL OR dept.DepartmentName           = @DepartmentName)
        GROUP BY b.PatientID, py.PaymentMethod
    ),
    Ranked AS (
        SELECT
            DENSE_RANK() OVER (ORDER BY fp.TotalAmountPaid DESC)  AS LTVRank,
            fp.PatientID,
            fp.PatientFullName,
            fp.DOB,
            bt.TotalBillCount,
            bt.TotalAmountBilled,
            fp.TotalAmountPaid,
            bt.TotalOutstandingBalance,
            ROUND(
                100.0 * fp.TotalAmountPaid
                / NULLIF(bt.TotalAmountBilled, 0),
            2)                                                     AS CollectionRatePct,
            fp.PaymentTransactionCount,
            ROUND(
                fp.TotalAmountPaid
                / NULLIF(CAST(bt.TotalBillCount AS DECIMAL(10,2)), 0),
            2)                                                     AS AvgSpendPerBill,
            mr.PaymentMethod                                       AS PreferredPaymentMethod,
            fp.FirstPaymentDate,
            fp.MostRecentPaymentDate,
            fp.DepartmentsVisited
        FROM       FilteredPayments fp
        INNER JOIN BillTotals       bt ON bt.PatientID  = fp.PatientID
        LEFT  JOIN MethodRanked     mr ON mr.PatientID  = fp.PatientID
                                      AND mr.MethodRank = 1
    )
    SELECT TOP (@TopN) WITH TIES
        LTVRank,
        PatientID,
        PatientFullName,
        DOB,
        TotalBillCount,
        TotalAmountBilled,
        TotalAmountPaid,
        TotalOutstandingBalance,
        CollectionRatePct,
        PaymentTransactionCount,
        AvgSpendPerBill,
        PreferredPaymentMethod,
        FirstPaymentDate,
        MostRecentPaymentDate,
        DepartmentsVisited
    FROM  Ranked
    ORDER BY LTVRank ASC;
END;
GO

-- Sample executions:
-- Top 10 patients by lifetime payments, all time:
EXEC dbo.usp_Billing_TopPayingPatients;

-- Top 5 patients who visited Cardiology in 2025:
EXEC dbo.usp_Billing_TopPayingPatients
    @TopN           = 5,
    @DepartmentName = 'Cardiology',
    @StartDate      = '2025-01-01',
    @EndDate        = '2025-12-31';

-- Top 20 patients who have paid at least $500 overall:
EXEC dbo.usp_Billing_TopPayingPatients
    @TopN         = 20,
    @MinTotalPaid = 500.00;
GO


-- =============================================================================
-- REPORT 5
-- =============================================================================
-- Title       : Monthly Revenue Trend — Billed vs. Collected with
--               Month-over-Month Growth
--
-- Business Question:
--   How does total billed revenue and total collected revenue change from month
--   to month?  Are collection rates improving or declining, and which months
--   represent revenue peaks or troughs that require operational attention?
--
-- Purpose / Business Value:
--   A month-over-month revenue trend is a foundational management-accounting
--   report used at every level of the organisation:
--       – Executive / Board: The CEO and CFO track whether revenue growth is
--         on target and whether the organisation's financial health is improving.
--         A consistent gap between billed and collected amounts signals a
--         worsening AR problem before it becomes a cash-flow crisis.
--       – Finance / Treasury: Monthly collected-revenue figures feed directly
--         into cash-flow forecasts and liquidity planning.  Seasonal dips
--         (e.g. holiday periods) can be anticipated and managed with credit
--         facilities.
--       – Operations: Peaks in billing volume reveal periods of high patient
--         throughput; troughs may indicate scheduling inefficiencies or staff
--         shortages that suppressed capacity.
--       – Billing Department: Month-over-month changes in the collection gap
--         (TotalBilled − TotalCollected) expose whether the AR team's efforts
--         are reducing the outstanding debt stock or whether new overdue
--         balances are accumulating faster than they are being recovered.
--   The @Year filter focuses the trend on a specific year for annual reviews.
--   The @DepartmentName filter allows departmental P&L views.
--   Month-over-month growth columns use LAG() to compare each month to the
--   previous one without a self-join.
--
-- Information Returned:
--   Year, month number, month name, number of bills raised that month, number
--   of payment transactions, total amount billed, total amount collected,
--   collection gap (billed minus collected), collection rate %, running
--   year-to-date collected total, month-over-month change in billed amount
--   (absolute and %), month-over-month change in collected amount (absolute
--   and %), and average days between bill creation and first payment received.
--
-- Advanced Techniques Used:
--   CTE (MonthlyBilling) aggregates Bills by year/month; CTE (MonthlyPayments)
--   aggregates Payments by year/month; LEFT JOIN between the two on year+month
--   ensures months with bills but no payments still appear; LAG() window
--   function for month-over-month deltas; SUM() OVER (PARTITION BY Year ORDER
--   BY Month) for running YTD total; DATEDIFF in a correlated subquery for
--   average days-to-first-payment; NULLIF for safe division; ORDER BY year and
--   month for chronological output.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Stored Procedure: dbo.usp_Billing_MonthlyRevenueTrend
--
-- No separate view is defined because the dual-source aggregation (Bills +
-- Payments on separate time axes) is most clearly expressed inside the
-- procedure's CTEs, where parameter filters can be pushed down early.
--
-- Parameters:
--   @Year            INT           — calendar year to report; NULL = all years
--   @DepartmentName  VARCHAR(100)  — restrict to one department; NULL = all
--   @PageNumber      INT           — 1-based page index; default 1
--   @PageSize        INT           — rows per page; default 24 (2 years of data)
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Billing_MonthlyRevenueTrend
    @Year           INT          = NULL,
    @DepartmentName VARCHAR(100) = NULL,
    @PageNumber     INT          = 1,
    @PageSize       INT          = 24
AS
BEGIN
    SET NOCOUNT ON;

    -- -------------------------------------------------------------------------
    -- CTE 1: Monthly billing totals (from Bills table, date = bill created date)
    -- -------------------------------------------------------------------------
    WITH MonthlyBilling AS (
        SELECT
            YEAR(b.CreatedDate)                 AS BillYear,
            MONTH(b.CreatedDate)                AS BillMonth,
            COUNT(DISTINCT b.BillID)            AS BillCount,
            SUM(b.TotalAmount)                  AS TotalBilled,
            SUM(b.Balance)                      AS TotalOutstanding
        FROM      dbo.Bills        b
        INNER JOIN dbo.Appointments a    ON a.AppointmentID   = b.AppointmentID
        INNER JOIN dbo.Doctors      dr   ON dr.DoctorID       = a.DoctorID
        INNER JOIN dbo.Departments  dept ON dept.DepartmentID = dr.DepartmentID
        WHERE (@Year           IS NULL OR YEAR(b.CreatedDate)   = @Year)
          AND (@DepartmentName IS NULL OR dept.DepartmentName   = @DepartmentName)
        GROUP BY YEAR(b.CreatedDate), MONTH(b.CreatedDate)
    ),
    -- -------------------------------------------------------------------------
    -- CTE 2: Monthly payment totals (from Payments table, date = payment date)
    -- -------------------------------------------------------------------------
    MonthlyPayments AS (
        SELECT
            YEAR(py.PaymentDate)                AS PayYear,
            MONTH(py.PaymentDate)               AS PayMonth,
            COUNT(py.PaymentID)                 AS PaymentTransactionCount,
            SUM(py.Amount)                      AS TotalCollected
        FROM      dbo.Payments     py
        INNER JOIN dbo.Bills        b    ON b.BillID          = py.BillID
        INNER JOIN dbo.Appointments a    ON a.AppointmentID   = b.AppointmentID
        INNER JOIN dbo.Doctors      dr   ON dr.DoctorID       = a.DoctorID
        INNER JOIN dbo.Departments  dept ON dept.DepartmentID = dr.DepartmentID
        WHERE (@Year           IS NULL OR YEAR(py.PaymentDate)  = @Year)
          AND (@DepartmentName IS NULL OR dept.DepartmentName   = @DepartmentName)
        GROUP BY YEAR(py.PaymentDate), MONTH(py.PaymentDate)
    ),
    -- -------------------------------------------------------------------------
    -- CTE 3: Join billing and payment months; compute collection gap and rate.
    -- LEFT JOIN ensures months with bills but zero payments are still shown.
    -- -------------------------------------------------------------------------
    Combined AS (
        SELECT
            mb.BillYear                                         AS ReportYear,
            mb.BillMonth                                        AS ReportMonth,
            DATENAME(MONTH, DATEFROMPARTS(mb.BillYear, mb.BillMonth, 1))
                                                                AS MonthName,
            mb.BillCount,
            ISNULL(mp.PaymentTransactionCount, 0)               AS PaymentTransactionCount,
            mb.TotalBilled,
            ISNULL(mp.TotalCollected, 0)                        AS TotalCollected,
            mb.TotalBilled - ISNULL(mp.TotalCollected, 0)       AS CollectionGap,
            ROUND(
                100.0 * ISNULL(mp.TotalCollected, 0)
                / NULLIF(mb.TotalBilled, 0),
            2)                                                  AS CollectionRatePct
        FROM       MonthlyBilling   mb
        LEFT  JOIN MonthlyPayments  mp
               ON  mp.PayYear  = mb.BillYear
              AND  mp.PayMonth = mb.BillMonth
    ),
    -- -------------------------------------------------------------------------
    -- CTE 4: Add LAG-based MoM growth columns and running YTD total.
    -- -------------------------------------------------------------------------
    WithTrend AS (
        SELECT
            ReportYear,
            ReportMonth,
            MonthName,
            BillCount,
            PaymentTransactionCount,
            TotalBilled,
            TotalCollected,
            CollectionGap,
            CollectionRatePct,
            -- Running year-to-date collected, resets at the start of each year
            SUM(TotalCollected) OVER (
                PARTITION BY ReportYear
                ORDER BY     ReportMonth
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            )                                                   AS YTDCollected,
            -- Month-over-month absolute change in billed amount
            TotalBilled - LAG(TotalBilled) OVER (
                ORDER BY ReportYear, ReportMonth
            )                                                   AS MoMBilledChange,
            -- Month-over-month % change in billed amount
            ROUND(
                100.0 * (TotalBilled - LAG(TotalBilled) OVER (
                    ORDER BY ReportYear, ReportMonth
                )) / NULLIF(LAG(TotalBilled) OVER (
                    ORDER BY ReportYear, ReportMonth
                ), 0),
            2)                                                  AS MoMBilledChangePct,
            -- Month-over-month absolute change in collected amount
            TotalCollected - LAG(TotalCollected) OVER (
                ORDER BY ReportYear, ReportMonth
            )                                                   AS MoMCollectedChange,
            -- Month-over-month % change in collected amount
            ROUND(
                100.0 * (TotalCollected - LAG(TotalCollected) OVER (
                    ORDER BY ReportYear, ReportMonth
                )) / NULLIF(LAG(TotalCollected) OVER (
                    ORDER BY ReportYear, ReportMonth
                ), 0),
            2)                                                  AS MoMCollectedChangePct
        FROM Combined
    )
    SELECT
        ReportYear,
        ReportMonth,
        MonthName,
        BillCount,
        PaymentTransactionCount,
        TotalBilled,
        TotalCollected,
        CollectionGap,
        CollectionRatePct,
        YTDCollected,
        MoMBilledChange,
        MoMBilledChangePct,
        MoMCollectedChange,
        MoMCollectedChangePct
    FROM  WithTrend
    ORDER BY ReportYear ASC, ReportMonth ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH  NEXT @PageSize ROWS ONLY;
END;
GO

-- Sample executions:
-- Full monthly trend across all time, all departments:
EXEC dbo.usp_Billing_MonthlyRevenueTrend;

-- Monthly trend for 2025 only:
EXEC dbo.usp_Billing_MonthlyRevenueTrend
    @Year = 2025;

-- Monthly trend for Orthopedics in 2025:
EXEC dbo.usp_Billing_MonthlyRevenueTrend
    @Year           = 2025,
    @DepartmentName = 'Orthopedics';
GO
