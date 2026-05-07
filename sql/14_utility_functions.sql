-- =============================================================================
-- HospitalDB — Reporting Utility Functions
-- File        : sql/14_utility_functions.sql
-- Author      : Hospital Information Systems
-- Date        : 2026-05-07
-- Description :
--   Four scalar user-defined functions that encapsulate reusable business logic
--   shared across stored procedures and views in the HospitalDB reporting layer
--   (files 05–09).  Centralising this logic eliminates duplicate CASE
--   expressions, ensures that threshold changes (e.g. adjusting the "High Risk"
--   inactivity boundary from 90 to 60 days) are applied in a single place, and
--   makes individual business rules independently testable.
--
--   Functions defined in this file:
--     1. dbo.fn_GetAgingBucket         — maps an integer days-outstanding value
--                                        to an AR aging-bucket label.
--                                        Used by: vw_UnpaidBills (07)
--
--     2. dbo.fn_GetCollectionRiskTier  — maps an outstanding monetary balance
--                                        to a collection-outreach priority tier.
--                                        Used by: usp_Report_PatientFinancialSummary (05)
--
--     3. dbo.fn_GetReminderPriority    — maps days remaining until an appointment
--                                        to a patient-reminder priority label.
--                                        Used by: usp_Schedule_UpcomingAppointments (06)
--
--     4. dbo.fn_GetInactivityRiskTier  — classifies a user account's inactivity
--                                        risk based on IsActive flag and last-
--                                        login date relative to a reference date.
--                                        Used by: vw_InactiveAccounts (08)
--
--   Design notes:
--     – All four functions use WITH SCHEMABINDING to prevent silent breakage if
--       any referenced object is altered or dropped.
--     – Functions 1–3 are fully deterministic (output depends only on inputs).
--     – Function 4 accepts an explicit @AsOfDate parameter instead of calling
--       GETDATE() internally.  This keeps the function deterministic, supports
--       back-dated "what-if" risk assessments (e.g. what would the risk tier have
--       been on a specific audit date?), and makes unit-testing straightforward.
--     – Return types are sized to accommodate the longest possible label with
--       two characters of headroom.
--     – Scalar UDF inlining (SQL Server 2019+) applies to functions 1–3.
--       Function 4 is eligible for inlining because it references only built-in
--       functions and its arguments and contains no side effects.
--
--   Execution note:
--     This file must be deployed BEFORE files 05, 06, 07, and 08 are re-created,
--     because those files reference these functions inside view and procedure
--     definitions.
-- =============================================================================

USE HospitalDB;
GO


-- =============================================================================
-- FUNCTION 1
-- =============================================================================
-- Name        : dbo.fn_GetAgingBucket
--
-- Purpose:
--   Converts an integer representing the number of days a bill has been
--   outstanding into the industry-standard AR aging-bucket label used throughout
--   HospitalDB billing reports.  The four buckets align with the hospital's
--   collection-escalation policy:
--     •  0–30 days  → automated payment reminder
--     • 31–60 days  → outbound phone follow-up
--     • 61–90 days  → payment-plan negotiation
--     •  90+ days   → escalate to collections
--
--   Centralising this derivation in a function means the same thresholds are
--   used consistently by vw_UnpaidBills, any future aging summary stored
--   procedures, and any scheduled jobs that categorise bills for escalation.
--
-- Parameters:
--   @DaysOutstanding  INT   — result of DATEDIFF(DAY, BillCreatedDate, AsOfDate).
--                             Negative values (future-dated bills) fall into the
--                             '0-30 Days' bucket.
--
-- Returns:
--   VARCHAR(20):  '0-30 Days' | '31-60 Days' | '61-90 Days' | '90+ Days'
--
-- Usage examples:
--   SELECT dbo.fn_GetAgingBucket(0);     -- '0-30 Days'
--   SELECT dbo.fn_GetAgingBucket(45);    -- '31-60 Days'
--   SELECT dbo.fn_GetAgingBucket(100);   -- '90+ Days'
--   SELECT dbo.fn_GetAgingBucket(-5);    -- '0-30 Days'  (future-dated bill)
-- =============================================================================
CREATE OR ALTER FUNCTION dbo.fn_GetAgingBucket
(
    @DaysOutstanding INT
)
RETURNS VARCHAR(20)
WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE
        WHEN @DaysOutstanding <= 30 THEN '0-30 Days'
        WHEN @DaysOutstanding <= 60 THEN '31-60 Days'
        WHEN @DaysOutstanding <= 90 THEN '61-90 Days'
        ELSE                            '90+ Days'
    END;
END;
GO


-- =============================================================================
-- FUNCTION 2
-- =============================================================================
-- Name        : dbo.fn_GetCollectionRiskTier
--
-- Purpose:
--   Assigns a collection-outreach priority tier to a patient account based on
--   their current outstanding balance.  The tier drives escalation workflows in
--   the Billing Department:
--     • High    (≥ $500) — immediate outreach + payment-plan offer
--     • Medium  (≥ $100) — follow-up call within the current billing cycle
--     • Low     (>   $0) — automated reminder only
--     • Cleared (=   $0) — no action required; account is settled
--
--   The thresholds are defined once here rather than being embedded inline in
--   usp_Report_PatientFinancialSummary and any other procedures or dashboards
--   that need to classify balances.  Adjusting the 'High' threshold from $500
--   to $300, for example, requires changing one line in this function.
--
-- Parameters:
--   @OutstandingBalance  DECIMAL(10,2)  — the patient's current aggregate
--                                         outstanding balance across all bills.
--                                         May be 0.00 but must not be NULL.
--
-- Returns:
--   VARCHAR(20):  'High' | 'Medium' | 'Low' | 'Cleared'
--
-- Usage examples:
--   SELECT dbo.fn_GetCollectionRiskTier(750.00);   -- 'High'
--   SELECT dbo.fn_GetCollectionRiskTier(250.00);   -- 'Medium'
--   SELECT dbo.fn_GetCollectionRiskTier(50.00);    -- 'Low'
--   SELECT dbo.fn_GetCollectionRiskTier(0.00);     -- 'Cleared'
-- =============================================================================
CREATE OR ALTER FUNCTION dbo.fn_GetCollectionRiskTier
(
    @OutstandingBalance DECIMAL(10,2)
)
RETURNS VARCHAR(20)
WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE
        WHEN @OutstandingBalance >= 500 THEN 'High'
        WHEN @OutstandingBalance >= 100 THEN 'Medium'
        WHEN @OutstandingBalance >    0 THEN 'Low'
        ELSE                                 'Cleared'
    END;
END;
GO


-- =============================================================================
-- FUNCTION 3
-- =============================================================================
-- Name        : dbo.fn_GetReminderPriority
--
-- Purpose:
--   Maps the number of days remaining until a scheduled appointment to a
--   human-readable reminder-priority label.  The Scheduling Desk uses these
--   labels to route appointments into the appropriate outbound communication
--   channel:
--     • Today     (0 days)  — immediate action; contact patient by phone now
--     • Tomorrow  (1 day)   — same-day outbound call or SMS
--     • This Week (2–7 days)— bulk SMS batch queued for that evening
--     • Upcoming  (8+ days) — standard automated email reminder
--
--   The function is called by usp_Schedule_UpcomingAppointments, ensuring the
--   same priority logic is applied whether the procedure is called interactively,
--   from a reporting dashboard, or from an automated notification job.
--
-- Parameters:
--   @DaysUntilAppointment  INT  — result of DATEDIFF(DAY, CAST(GETDATE() AS DATE),
--                                  CAST(AppointmentDate AS DATE)).
--                                  Negative values (past appointments still in
--                                  'Scheduled' status) return 'Today' to flag
--                                  them for immediate review.
--
-- Returns:
--   VARCHAR(20):  'Today' | 'Tomorrow' | 'This Week' | 'Upcoming'
--
-- Usage examples:
--   SELECT dbo.fn_GetReminderPriority(0);    -- 'Today'
--   SELECT dbo.fn_GetReminderPriority(1);    -- 'Tomorrow'
--   SELECT dbo.fn_GetReminderPriority(5);    -- 'This Week'
--   SELECT dbo.fn_GetReminderPriority(14);   -- 'Upcoming'
--   SELECT dbo.fn_GetReminderPriority(-2);   -- 'Today'  (overdue scheduled appointment)
-- =============================================================================
CREATE OR ALTER FUNCTION dbo.fn_GetReminderPriority
(
    @DaysUntilAppointment INT
)
RETURNS VARCHAR(20)
WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE
        WHEN @DaysUntilAppointment <= 0 THEN 'Today'
        WHEN @DaysUntilAppointment =  1 THEN 'Tomorrow'
        WHEN @DaysUntilAppointment <= 7 THEN 'This Week'
        ELSE                                 'Upcoming'
    END;
END;
GO


-- =============================================================================
-- FUNCTION 4
-- =============================================================================
-- Name        : dbo.fn_GetInactivityRiskTier
--
-- Purpose:
--   Classifies a user account into an inactivity-risk tier for the quarterly
--   access-review process mandated by the hospital's information-security policy.
--   The risk model uses two inputs — whether the account is currently enabled and
--   how recently the user last authenticated — to assign one of five tiers:
--
--     • Disabled    (IsActive = 0)               — account already deactivated;
--                                                  included in the review log
--                                                  for completeness.
--     • Critical    (active, never logged in)     — account was created but has
--                                                  never been used; must be
--                                                  disabled or assigned within
--                                                  the next review cycle.
--     • High Risk   (active, >90 days inactive)  — longest-inactive live accounts;
--                                                  immediate access revocation
--                                                  unless the user can be
--                                                  re-verified.
--     • Medium Risk (active, 31–90 days inactive)— flag for supervisor review
--                                                  and re-confirmation within 14
--                                                  business days.
--     • Low Risk    (active, ≤30 days inactive)  — within acceptable login
--                                                  frequency; no action needed.
--
--   The explicit @AsOfDate parameter (rather than an internal GETDATE() call)
--   keeps this function deterministic: the same inputs always produce the same
--   output.  Callers pass CAST(GETDATE() AS DATE) for live reports or any
--   historical date for audit simulations.
--
-- Parameters:
--   @IsActive   BIT       — 1 if the user account is currently enabled.
--   @LastLogin  DATETIME  — timestamp of the user's most recent successful
--                           authentication; NULL if the account has never been
--                           used.
--   @AsOfDate   DATE      — reference date for the inactivity calculation.
--                           Pass CAST(GETDATE() AS DATE) for current reports.
--
-- Returns:
--   VARCHAR(20):  'Disabled' | 'Critical' | 'High Risk' | 'Medium Risk' | 'Low Risk'
--
-- Usage examples:
--   -- Disabled account:
--   SELECT dbo.fn_GetInactivityRiskTier(0, '2025-01-01', '2026-05-07');  -- 'Disabled'
--   -- Active, never logged in:
--   SELECT dbo.fn_GetInactivityRiskTier(1, NULL, '2026-05-07');           -- 'Critical'
--   -- Active, last login 120 days ago:
--   SELECT dbo.fn_GetInactivityRiskTier(1, '2026-01-07', '2026-05-07');   -- 'High Risk'
--   -- Active, last login 45 days ago:
--   SELECT dbo.fn_GetInactivityRiskTier(1, '2026-03-23', '2026-05-07');   -- 'Medium Risk'
--   -- Active, last login 10 days ago:
--   SELECT dbo.fn_GetInactivityRiskTier(1, '2026-04-27', '2026-05-07');   -- 'Low Risk'
-- =============================================================================
CREATE OR ALTER FUNCTION dbo.fn_GetInactivityRiskTier
(
    @IsActive   BIT,
    @LastLogin  DATETIME,
    @AsOfDate   DATE
)
RETURNS VARCHAR(20)
WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE
        WHEN @IsActive = 0
            THEN 'Disabled'
        WHEN @LastLogin IS NULL AND @IsActive = 1
            THEN 'Critical'
        WHEN DATEDIFF(DAY, @LastLogin, @AsOfDate) > 90  AND @IsActive = 1
            THEN 'High Risk'
        WHEN DATEDIFF(DAY, @LastLogin, @AsOfDate) BETWEEN 31 AND 90
            THEN 'Medium Risk'
        ELSE
            'Low Risk'
    END;
END;
GO


-- =============================================================================
-- Smoke tests — verify all four functions return expected values.
-- Run these after deployment to confirm correct behaviour.
-- =============================================================================
SELECT
    -- fn_GetAgingBucket
    dbo.fn_GetAgingBucket(-5)   AS Aging_NegFuture,       -- '0-30 Days'
    dbo.fn_GetAgingBucket(0)    AS Aging_Zero,             -- '0-30 Days'
    dbo.fn_GetAgingBucket(30)   AS Aging_30,               -- '0-30 Days'
    dbo.fn_GetAgingBucket(31)   AS Aging_31,               -- '31-60 Days'
    dbo.fn_GetAgingBucket(60)   AS Aging_60,               -- '31-60 Days'
    dbo.fn_GetAgingBucket(61)   AS Aging_61,               -- '61-90 Days'
    dbo.fn_GetAgingBucket(90)   AS Aging_90,               -- '61-90 Days'
    dbo.fn_GetAgingBucket(91)   AS Aging_91,               -- '90+ Days'

    -- fn_GetCollectionRiskTier
    dbo.fn_GetCollectionRiskTier(0.00)    AS Risk_Cleared, -- 'Cleared'
    dbo.fn_GetCollectionRiskTier(50.00)   AS Risk_Low,     -- 'Low'
    dbo.fn_GetCollectionRiskTier(100.00)  AS Risk_Medium,  -- 'Medium'
    dbo.fn_GetCollectionRiskTier(500.00)  AS Risk_High,    -- 'High'

    -- fn_GetReminderPriority
    dbo.fn_GetReminderPriority(-1)   AS Remind_Overdue,    -- 'Today'
    dbo.fn_GetReminderPriority(0)    AS Remind_Today,      -- 'Today'
    dbo.fn_GetReminderPriority(1)    AS Remind_Tomorrow,   -- 'Tomorrow'
    dbo.fn_GetReminderPriority(7)    AS Remind_ThisWeek,   -- 'This Week'
    dbo.fn_GetReminderPriority(8)    AS Remind_Upcoming,   -- 'Upcoming'

    -- fn_GetInactivityRiskTier
    dbo.fn_GetInactivityRiskTier(0, '2025-01-01', '2026-05-07') AS Inact_Disabled,    -- 'Disabled'
    dbo.fn_GetInactivityRiskTier(1, NULL,          '2026-05-07') AS Inact_Critical,    -- 'Critical'
    dbo.fn_GetInactivityRiskTier(1, '2026-01-07',  '2026-05-07') AS Inact_HighRisk,   -- 'High Risk'
    dbo.fn_GetInactivityRiskTier(1, '2026-03-23',  '2026-05-07') AS Inact_MedRisk,    -- 'Medium Risk'
    dbo.fn_GetInactivityRiskTier(1, '2026-04-27',  '2026-05-07') AS Inact_LowRisk;    -- 'Low Risk'
GO
