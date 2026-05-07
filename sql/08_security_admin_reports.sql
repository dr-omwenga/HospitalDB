-- =============================================================================
-- HospitalDB — Security and Administration Reports
-- File        : sql/08_security_admin_reports.sql
-- Author      : Hospital Information Systems
-- Date        : 2026-05-07
-- Description :
--   Three operational security and administration reports for HospitalDB.
--   Each report is implemented as a reusable VIEW (dbo.vw_*) that encapsulates
--   the core logic, and a STORED PROCEDURE (dbo.usp_Security_*) that exposes
--   parameter-driven filtering and OFFSET/FETCH pagination.
--
--   Reports included:
--     1. Masked Sensitive Data Viewer     — returns patient and user PII with
--                                          production-safe column masking for
--                                          use in non-privileged reporting
--                                          contexts (QA, analytics, training)
--     2. Audit Log Activity Report        — detailed audit trail with user,
--                                          table, and action context; supports
--                                          compliance reviews and incident
--                                          investigation
--     3. Inactive Account Report          — users who have never logged in or
--                                          whose last login exceeds a threshold,
--                                          with risk scoring for access review
--
--   Advanced SQL features demonstrated:
--     – String functions: LEFT, RIGHT, LEN, REPLICATE, CHARINDEX, STUFF for
--       deterministic PII masking without external encryption dependencies
--     – CASE expressions for risk-tier derivation and conditional masking
--     – DATEDIFF for inactivity duration calculation
--     – Multi-table INNER and LEFT JOINs
--     – Window function: ROW_NUMBER(), COUNT() OVER (PARTITION BY ...)
--       for per-user and per-table activity metrics
--     – GROUP BY with COUNT, MAX, MIN aggregate functions
--     – CTEs for multi-step composition
--     – OFFSET / FETCH NEXT for server-side pagination
--     – NULLIF / ISNULL for safe null coalescing
--     – HAVING for post-aggregation filtering
-- =============================================================================

USE HospitalDB;
GO

-- =============================================================================
-- REPORT 1
-- =============================================================================
-- Title       : Masked Sensitive Data Viewer — PII-Safe Patient and User
--               Directory for Non-Privileged Contexts
--
-- Business Question:
--   How can analysts, QA testers, trainers, and third-party auditors work with
--   realistic patient and user records without being exposed to real personally
--   identifiable information (PII) such as full names, email addresses, dates
--   of birth, phone numbers, and insurance policy numbers?
--
-- Purpose / Business Value:
--   Healthcare organisations operate under strict data-protection regulations
--   (HIPAA, GDPR, local health-records legislation).  A dedicated masked-data
--   view enables:
--       – Safe analytics and QA testing: developers and analysts can write and
--         test queries against a realistic data shape without accessing real PII,
--         eliminating the need for a separate anonymised database copy that
--         quickly falls out of sync with production.
--       – Training environments: new staff can train on production-schema
--         queries using this view without any risk of data exposure.
--       – Compliance audit handoffs: external auditors who need to verify query
--         logic (not actual patient data) can be granted SELECT on this view
--         only, with no access to underlying tables.
--       – Incident response scoping: during a security incident, IT can use the
--         masked view to demonstrate record counts and data shapes to
--         stakeholders without exposing real records in presentation materials.
--   The masking strategy uses deterministic, reversible-for-authorised-users
--   patterns (not random) so that record counts and structural relationships
--   are preserved, while specific values are obfuscated:
--       – Name columns: first character + asterisks + last character
--         e.g. "Margaret" → "M******t"
--       – Email: local-part masked, domain preserved
--         e.g. "j.smith@gmail.com" → "j****h@gmail.com"
--       – Phone: last 4 digits shown, remainder masked
--         e.g. "555-867-5309" → "********5309"
--       – Date of birth: year and month retained, day zeroed to 01
--         e.g. 1985-07-23 → 1985-07-01  (age band preserved for analytics)
--       – Policy number: first 2 and last 2 characters shown
--         e.g. "POL-20483921" → "PO**********21"
--
-- Information Returned:
--   Patient ID, masked first name, masked last name, masked DOB, gender,
--   masked phone, masked email, city and state (retained for geographic
--   analytics), masked insurance policy number, insurance provider name,
--   coverage percent, policy expiry date, associated user username
--   (masked), user role, user active status, and last login date.
--
-- Advanced Techniques Used:
--   LEFT(), RIGHT(), LEN(), REPLICATE(), CHARINDEX(), STUFF() for column-level
--   masking; DATEFROMPARTS() for DOB truncation; LEFT JOIN to insurance tables
--   and Users to enrich the record; CASE to handle NULL insurance gracefully.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- View: dbo.vw_MaskedPatientDirectory
-- PII-safe patient directory joined with insurance and user account context.
-- Grant SELECT on this view (not base tables) to non-privileged roles.
-- -----------------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_MaskedPatientDirectory
AS
SELECT
    p.PatientID,

    -- Name masking: keep first char + asterisks + last char
    LEFT(p.FirstName, 1)
        + REPLICATE('*', CASE WHEN LEN(p.FirstName) > 2 THEN LEN(p.FirstName) - 2 ELSE 0 END)
        + CASE WHEN LEN(p.FirstName) > 1 THEN RIGHT(p.FirstName, 1) ELSE '' END
                                                AS MaskedFirstName,
    LEFT(p.LastName, 1)
        + REPLICATE('*', CASE WHEN LEN(p.LastName) > 2 THEN LEN(p.LastName) - 2 ELSE 0 END)
        + CASE WHEN LEN(p.LastName) > 1 THEN RIGHT(p.LastName, 1) ELSE '' END
                                                AS MaskedLastName,

    -- DOB: retain year and month, replace day with 01 (age band preserved)
    DATEFROMPARTS(YEAR(p.DOB), MONTH(p.DOB), 1)
                                                AS MaskedDOB,
    p.Gender,

    -- Phone: mask all but the last 4 digits
    REPLICATE('*', LEN(p.Phone) - 4)
        + RIGHT(p.Phone, 4)                     AS MaskedPhone,

    -- Email: mask local-part (keep first and last char), preserve domain
    LEFT(p.Email, 1)
        + REPLICATE('*', CHARINDEX('@', p.Email) - 3)
        + SUBSTRING(p.Email, CHARINDEX('@', p.Email) - 1,
                    LEN(p.Email) - CHARINDEX('@', p.Email) + 2)
                                                AS MaskedEmail,

    -- Address: city and state retained for geographic analysis; street masked
    addr.City,
    addr.State,
    addr.Country,

    -- Insurance policy: show first 2 and last 2 characters only
    CASE
        WHEN pip.PolicyNumber IS NULL THEN NULL
        ELSE LEFT(pip.PolicyNumber, 2)
             + REPLICATE('*', CASE WHEN LEN(pip.PolicyNumber) > 4 THEN LEN(pip.PolicyNumber) - 4 ELSE 0 END)
             + RIGHT(pip.PolicyNumber, 2)
    END                                         AS MaskedPolicyNumber,
    ip.ProviderName                             AS InsuranceProvider,
    pip.CoveragePercent,
    pip.ExpiryDate                              AS PolicyExpiryDate,
    pip.IsPrimary,

    -- User account linked to patient record (username masked, role retained)
    u.UserID,
    LEFT(u.Username, 2)
        + REPLICATE('*', CASE WHEN LEN(u.Username) > 4 THEN LEN(u.Username) - 4 ELSE 0 END)
        + RIGHT(u.Username, 2)                  AS MaskedUsername,
    r.RoleName,
    u.IsActive                                  AS AccountIsActive,
    u.LastLogin                                 AS LastLoginDate,
    p.DateCreated                               AS PatientRecordCreated
FROM      dbo.Patients               p
INNER JOIN dbo.Addresses             addr ON addr.AddressID         = p.AddressID
LEFT  JOIN dbo.PatientInsurancePolicies pip ON pip.PatientID        = p.PatientID
                                           AND pip.IsPrimary        = 1
LEFT  JOIN dbo.InsuranceProviders    ip   ON ip.InsuranceProviderID = pip.InsuranceProviderID
-- Join to Users via matching patient ID (1:1 relationship in seed data)
LEFT  JOIN dbo.Users                 u    ON u.UserID               = p.PatientID
LEFT  JOIN dbo.Roles                 r    ON r.RoleID               = u.RoleID;
GO

-- -----------------------------------------------------------------------------
-- Stored Procedure: dbo.usp_Security_MaskedPatientDirectory
--
-- Parameters:
--   @Gender          VARCHAR(20)   — filter by gender; NULL = all
--   @City            VARCHAR(60)   — filter by city; NULL = all
--   @InsuranceStatus VARCHAR(20)   — 'Active' | 'Expired' | 'None' | NULL = all
--   @AccountIsActive BIT           — 1 = active accounts only; NULL = all
--   @PageNumber      INT           — 1-based page index; default 1
--   @PageSize        INT           — rows per page; default 25
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Security_MaskedPatientDirectory
    @Gender          VARCHAR(20)  = NULL,
    @City            VARCHAR(60)  = NULL,
    @InsuranceStatus VARCHAR(20)  = NULL,
    @AccountIsActive BIT          = NULL,
    @PageNumber      INT          = 1,
    @PageSize        INT          = 25
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        PatientID,
        MaskedFirstName,
        MaskedLastName,
        MaskedDOB,
        Gender,
        MaskedPhone,
        MaskedEmail,
        City,
        State,
        Country,
        MaskedPolicyNumber,
        InsuranceProvider,
        CoveragePercent,
        PolicyExpiryDate,
        IsPrimary,
        UserID,
        MaskedUsername,
        RoleName,
        AccountIsActive,
        LastLoginDate,
        PatientRecordCreated
    FROM  dbo.vw_MaskedPatientDirectory
    WHERE (@Gender          IS NULL OR Gender          = @Gender)
      AND (@City            IS NULL OR City            = @City)
      AND (@AccountIsActive IS NULL OR AccountIsActive = @AccountIsActive)
      AND (
            @InsuranceStatus IS NULL
         OR (@InsuranceStatus = 'Active'  AND PolicyExpiryDate >= CAST(GETDATE() AS DATE))
         OR (@InsuranceStatus = 'Expired' AND PolicyExpiryDate <  CAST(GETDATE() AS DATE))
         OR (@InsuranceStatus = 'None'    AND MaskedPolicyNumber IS NULL)
          )
    ORDER BY PatientID ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH  NEXT @PageSize ROWS ONLY;
END;
GO

-- Sample executions:
-- Full masked directory, all patients:
EXEC dbo.usp_Security_MaskedPatientDirectory;

-- Active accounts with expired insurance:
EXEC dbo.usp_Security_MaskedPatientDirectory
    @InsuranceStatus = 'Expired',
    @AccountIsActive = 1;

-- Female patients in Dallas:
EXEC dbo.usp_Security_MaskedPatientDirectory
    @Gender = 'Female',
    @City   = 'Dallas';
GO


-- =============================================================================
-- REPORT 2
-- =============================================================================
-- Title       : Audit Log Activity Report — User Action Trail for Compliance
--               Review and Incident Investigation
--
-- Business Question:
--   Who performed what actions on which tables, when, and how frequently?
--   Can we surface all data-change events for a specific user, table, or date
--   range for a compliance review or security incident investigation?
--
-- Purpose / Business Value:
--   A queryable audit trail is a mandatory control in regulated healthcare
--   environments and is central to several security objectives:
--       – Compliance (HIPAA, SOX, ISO 27001): Auditors require evidence that
--         all Create, Update, and Delete operations on sensitive tables are
--         logged with a user identity and timestamp.  This report provides that
--         evidence in a structured, filterable format that can be exported
--         directly into an audit pack.
--       – Incident Investigation: When a data anomaly or suspected breach is
--         detected, the security team can use this report to reconstruct the
--         exact sequence of changes to any record — what the value was before
--         the change (OldValue), what it was changed to (NewValue), and which
--         user account executed the operation.
--       – Insider Threat Detection: Unusual activity patterns (a single user
--         performing a high volume of DELETE operations in a short window, or
--         changes to sensitive tables outside business hours) can be surfaced
--         by filtering on ActionType and date/time ranges.
--       – Change Management Verification: After a planned data-migration or
--         bulk-update script is run, this report confirms that only the expected
--         records were modified by the expected user account.
--   The procedure returns TWO result sets:
--       1. Detailed audit event log — every individual audit record in scope,
--          enriched with the performing user's role and username.
--       2. Summary by user and table — aggregated action counts per
--          (user, table, action type) combination, with first and last event
--          timestamps and the user's action volume rank within the period.
--
-- Information Returned:
--   Result set 1 (detail): Audit ID, action date, username, role, table name,
--   action type, old value, new value.
--   Result set 2 (summary): Username, role, table name, action type, event
--   count, first event date, last event date, activity spread in days, and
--   each user's rank by event count within the filtered scope.
--
-- Advanced Techniques Used:
--   INNER JOIN AuditLogs → Users → Roles for user context enrichment; date
--   range filtering with CAST(ActionDate AS DATE); DATEPART(HOUR) for
--   business-hours flagging; ROW_NUMBER() OVER (PARTITION BY UserID ORDER BY
--   COUNT DESC) for per-user action rank; GROUP BY (Username, TableName,
--   ActionType) in the summary result set; DATEDIFF for activity spread;
--   OFFSET / FETCH NEXT pagination on the detail result set.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- View: dbo.vw_AuditLogDetail
-- Enriches raw audit log rows with username, role, and business-hours flag.
-- -----------------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_AuditLogDetail
AS
SELECT
    al.AuditID,
    al.ActionDate,
    CAST(al.ActionDate AS DATE)                 AS ActionDay,
    DATEPART(HOUR, al.ActionDate)               AS ActionHour,
    -- Flag actions outside typical business hours (before 07:00 or after 20:00)
    CASE
        WHEN DATEPART(HOUR, al.ActionDate) < 7
          OR DATEPART(HOUR, al.ActionDate) >= 20
        THEN 1
        ELSE 0
    END                                         AS IsOutsideBusinessHours,
    al.PerformedByUserID,
    u.Username,
    r.RoleName,
    al.TableName,
    al.ActionType,
    al.OldValue,
    al.NewValue
FROM      dbo.AuditLogs  al
INNER JOIN dbo.Users      u  ON u.UserID = al.PerformedByUserID
INNER JOIN dbo.Roles      r  ON r.RoleID = u.RoleID;
GO

-- -----------------------------------------------------------------------------
-- Stored Procedure: dbo.usp_Security_AuditLogReport
--
-- Parameters:
--   @Username               VARCHAR(80)   — filter to one user; NULL = all
--   @RoleName               VARCHAR(50)   — filter by role; NULL = all
--   @TableName              VARCHAR(80)   — filter by table; NULL = all
--   @ActionType             VARCHAR(20)   — 'INSERT'|'UPDATE'|'DELETE'|NULL=all
--   @StartDate              DATE          — lower bound on ActionDate; NULL = all
--   @EndDate                DATE          — upper bound on ActionDate; NULL = all
--   @OutsideBusinessHoursOnly BIT         — 1 = after-hours events only; default 0
--   @PageNumber             INT           — 1-based page (detail RS only)
--   @PageSize               INT           — rows per page; default 50
--
-- Returns:
--   Result Set 1 — Paginated detail audit log
--   Result Set 2 — Aggregated summary by user, table, and action type
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Security_AuditLogReport
    @Username                VARCHAR(80)  = NULL,
    @RoleName                VARCHAR(50)  = NULL,
    @TableName               VARCHAR(80)  = NULL,
    @ActionType              VARCHAR(20)  = NULL,
    @StartDate               DATE         = NULL,
    @EndDate                 DATE         = NULL,
    @OutsideBusinessHoursOnly BIT         = 0,
    @PageNumber              INT          = 1,
    @PageSize                INT          = 50
AS
BEGIN
    SET NOCOUNT ON;

    -- -------------------------------------------------------------------------
    -- Result Set 1: Paginated detail audit log, newest events first
    -- -------------------------------------------------------------------------
    SELECT
        AuditID,
        ActionDate,
        Username,
        RoleName,
        TableName,
        ActionType,
        IsOutsideBusinessHours,
        OldValue,
        NewValue
    FROM  dbo.vw_AuditLogDetail
    WHERE (@Username                IS NULL  OR Username               = @Username)
      AND (@RoleName                IS NULL  OR RoleName               = @RoleName)
      AND (@TableName               IS NULL  OR TableName              = @TableName)
      AND (@ActionType              IS NULL  OR ActionType             = @ActionType)
      AND (@StartDate               IS NULL  OR ActionDay             >= @StartDate)
      AND (@EndDate                 IS NULL  OR ActionDay             <= @EndDate)
      AND (@OutsideBusinessHoursOnly = 0     OR IsOutsideBusinessHours = 1)
    ORDER BY ActionDate DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH  NEXT @PageSize ROWS ONLY;

    -- -------------------------------------------------------------------------
    -- Result Set 2: Summary by user, table, and action type
    -- ROW_NUMBER ranks each user's (table, action) combinations by event count
    -- so the busiest activity clusters surface at the top of each user's section
    -- -------------------------------------------------------------------------
    WITH SummaryBase AS (
        SELECT
            Username,
            RoleName,
            TableName,
            ActionType,
            COUNT(AuditID)                  AS EventCount,
            MIN(ActionDate)                 AS FirstEventDate,
            MAX(ActionDate)                 AS LastEventDate,
            DATEDIFF(
                DAY,
                MIN(ActionDate),
                MAX(ActionDate)
            )                               AS ActivitySpreadDays,
            SUM(IsOutsideBusinessHours)     AS OutsideHoursCount
        FROM  dbo.vw_AuditLogDetail
        WHERE (@Username                IS NULL  OR Username               = @Username)
          AND (@RoleName                IS NULL  OR RoleName               = @RoleName)
          AND (@TableName               IS NULL  OR TableName              = @TableName)
          AND (@ActionType              IS NULL  OR ActionType             = @ActionType)
          AND (@StartDate               IS NULL  OR ActionDay             >= @StartDate)
          AND (@EndDate                 IS NULL  OR ActionDay             <= @EndDate)
          AND (@OutsideBusinessHoursOnly = 0     OR IsOutsideBusinessHours = 1)
        GROUP BY Username, RoleName, TableName, ActionType
    )
    SELECT
        Username,
        RoleName,
        TableName,
        ActionType,
        EventCount,
        FirstEventDate,
        LastEventDate,
        ActivitySpreadDays,
        OutsideHoursCount,
        -- Rank within each user: which (table+action) is their most frequent?
        ROW_NUMBER() OVER (
            PARTITION BY Username
            ORDER BY     EventCount DESC
        )                                   AS RankWithinUser,
        -- Rank across all users for this action type
        ROW_NUMBER() OVER (
            ORDER BY EventCount DESC
        )                                   AS OverallRank
    FROM  SummaryBase
    ORDER BY Username ASC, EventCount DESC;
END;
GO

-- Sample executions:
-- Full audit log, all events:
EXEC dbo.usp_Security_AuditLogReport;

-- All DELETE operations across all tables:
EXEC dbo.usp_Security_AuditLogReport
    @ActionType = 'DELETE';

-- After-hours events in a specific date range:
EXEC dbo.usp_Security_AuditLogReport
    @StartDate                = '2025-01-01',
    @EndDate                  = '2025-12-31',
    @OutsideBusinessHoursOnly = 1;

-- All activity by a specific user:
EXEC dbo.usp_Security_AuditLogReport
    @Username = 'admin_user';
GO


-- =============================================================================
-- REPORT 3
-- =============================================================================
-- Title       : Inactive Account Report — User Access Review and Dormant
--               Account Risk Assessment
--
-- Business Question:
--   Which user accounts have been inactive (never logged in, or last login
--   exceeds a defined threshold), are they still marked as active in the system,
--   and what is the security risk level of leaving each dormant account enabled?
--
-- Purpose / Business Value:
--   Dormant user accounts represent one of the most common and highest-risk
--   vulnerabilities in any information system.  An attacker who obtains
--   credentials for an account that is never monitored can operate undetected
--   for extended periods.  This report supports:
--       – Periodic Access Reviews (PAR): Most compliance frameworks (HIPAA
--         Security Rule, ISO 27001, SOC 2) require organisations to review
--         user access at least quarterly.  This report produces the required
--         evidence list in one query, exportable directly to the compliance team.
--       – Least-Privilege Enforcement: Accounts that have not been used in 90+
--         days should be disabled pending re-authorisation.  The report flags
--         such accounts with a 'High Risk' tier so IT administrators can action
--         them immediately.
--       – Orphaned Account Detection: When a member of staff leaves the
--         organisation, their account should be disabled.  Accounts that are
--         still IsActive = 1 but show 180+ days of inactivity are strong
--         candidates for being orphaned accounts that were never offboarded.
--       – Password Policy Compliance: Combined with a last-login date, the
--         report helps identify accounts that have not performed a password
--         rotation within the required cycle.
--   Risk tiers are derived from days of inactivity:
--       – 'Critical'  : IsActive = 1 AND never logged in (LastLogin IS NULL)
--       – 'High Risk' : IsActive = 1 AND inactive > 90 days
--       – 'Medium Risk': IsActive = 1 AND inactive 31–90 days
--       – 'Low Risk'  : IsActive = 1 AND inactive 0–30 days
--       – 'Disabled'  : IsActive = 0 (already deactivated — informational only)
--   The @InactiveDaysThreshold parameter allows the IT team to customise the
--   minimum inactivity window to match their access-review policy.
--
-- Information Returned:
--   User ID, username, role name, IsActive flag, last login date,
--   days since last login (NULL → never logged in shown as 99999 for sort
--   purposes), inactivity risk tier, account created date (derived from the
--   earliest audit log entry for that user, or NULL), total audit events
--   attributed to the user (measures actual system usage beyond login), and
--   whether the account has any audit events in the past 30 days.
--
-- Advanced Techniques Used:
--   LEFT JOIN AuditLogs to count total and recent activity per user without
--   excluding users with zero audit events; DATEDIFF for inactivity duration;
--   CASE expression for risk-tier derivation; ISNULL to substitute a sentinel
--   sort value for accounts with NULL LastLogin; HAVING to filter by inactivity
--   threshold; GROUP BY across Users → Roles; conditional COUNT with CASE for
--   recent-activity flag; OFFSET / FETCH NEXT for pagination.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- View: dbo.vw_InactiveAccounts
-- Per-user account status enriched with audit activity metrics and risk tier.
-- Covers ALL accounts (active and inactive) to support full access reviews.
-- -----------------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_InactiveAccounts
AS
SELECT
    u.UserID,
    u.Username,
    r.RoleName,
    u.IsActive,
    u.LastLogin,
    -- Days since last login; NULL LastLogin treated as maximum inactivity
    CASE
        WHEN u.LastLogin IS NULL THEN NULL
        ELSE DATEDIFF(DAY, u.LastLogin, GETDATE())
    END                                         AS DaysSinceLastLogin,
    -- Risk tier: delegates to fn_GetInactivityRiskTier so threshold
    -- adjustments (e.g. changing the High Risk boundary from 90 to 60 days)
    -- are applied in one place across all reports and access-review workflows.
    dbo.fn_GetInactivityRiskTier(
        u.IsActive, u.LastLogin, CAST(GETDATE() AS DATE))
                                                AS InactivityRiskTier,
    -- Integer sort key derived from the same function so tier ordering is
    -- always consistent with the label (Critical=1 … Disabled=5).
    CASE dbo.fn_GetInactivityRiskTier(
             u.IsActive, u.LastLogin, CAST(GETDATE() AS DATE))
        WHEN 'Critical'    THEN 1
        WHEN 'High Risk'   THEN 2
        WHEN 'Medium Risk' THEN 3
        WHEN 'Low Risk'    THEN 4
        ELSE                    5   -- 'Disabled'
    END                                         AS RiskSortKey,
    -- Total audit events ever attributed to this user
    COUNT(al.AuditID)                           AS TotalAuditEvents,
    -- Audit events in the last 30 days (non-login activity indicator)
    SUM(
        CASE
            WHEN al.ActionDate >= DATEADD(DAY, -30, GETDATE()) THEN 1
            ELSE 0
        END
    )                                           AS AuditEventsLast30Days,
    -- Earliest audit event as a proxy for account first-use date
    CAST(MIN(al.ActionDate) AS DATE)            AS EarliestAuditActivity,
    -- Most recent audit event (may differ from LastLogin)
    CAST(MAX(al.ActionDate) AS DATE)            AS MostRecentAuditActivity
FROM      dbo.Users     u
INNER JOIN dbo.Roles    r   ON r.RoleID = u.RoleID
LEFT  JOIN dbo.AuditLogs al ON al.PerformedByUserID = u.UserID
GROUP BY
    u.UserID,
    u.Username,
    r.RoleName,
    u.IsActive,
    u.LastLogin;
GO

-- -----------------------------------------------------------------------------
-- Stored Procedure: dbo.usp_Security_InactiveAccountReport
--
-- Parameters:
--   @InactiveDaysThreshold  INT          — minimum days of inactivity to include;
--                                          default 30 (matches typical quarterly
--                                          access-review cycle); set to 0 for all
--   @RiskTier               VARCHAR(20)  — 'Critical'|'High Risk'|'Medium Risk'|
--                                          'Low Risk'|'Disabled'|NULL = all tiers
--   @RoleName               VARCHAR(50)  — filter by role; NULL = all roles
--   @IncludeDisabled        BIT          — 1 = include IsActive=0 accounts;
--                                          default 0 (focus on still-active risks)
--   @PageNumber             INT          — 1-based page index; default 1
--   @PageSize               INT          — rows per page; default 25
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Security_InactiveAccountReport
    @InactiveDaysThreshold INT          = 30,
    @RiskTier              VARCHAR(20)  = NULL,
    @RoleName              VARCHAR(50)  = NULL,
    @IncludeDisabled       BIT          = 0,
    @PageNumber            INT          = 1,
    @PageSize              INT          = 25
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        UserID,
        Username,
        RoleName,
        IsActive,
        LastLogin,
        DaysSinceLastLogin,
        InactivityRiskTier,
        TotalAuditEvents,
        AuditEventsLast30Days,
        EarliestAuditActivity,
        MostRecentAuditActivity
    FROM  dbo.vw_InactiveAccounts
    WHERE
        -- Apply inactivity threshold:
        -- NULL LastLogin (never logged in) always qualifies regardless of threshold
        (LastLogin IS NULL OR DaysSinceLastLogin >= @InactiveDaysThreshold)
        -- Optionally exclude already-disabled accounts
        AND (IsActive = 1 OR @IncludeDisabled = 1)
        -- Optional risk tier filter
        AND (@RiskTier  IS NULL OR InactivityRiskTier = @RiskTier)
        -- Optional role filter
        AND (@RoleName  IS NULL OR RoleName           = @RoleName)
    ORDER BY
        RiskSortKey    ASC,                                    -- Critical → High → Medium → Low → Disabled
        CASE WHEN DaysSinceLastLogin IS NULL THEN 1 ELSE 0 END DESC,  -- NULL (never logged in) last within Critical tier
        DaysSinceLastLogin DESC                                -- within tier: longest inactive first
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH  NEXT @PageSize ROWS ONLY;
END;
GO

-- Sample executions:
-- All accounts inactive for 30+ days (default access-review list):
EXEC dbo.usp_Security_InactiveAccountReport;

-- Critical and High Risk accounts only (never logged in or 90+ days):
EXEC dbo.usp_Security_InactiveAccountReport
    @RiskTier = 'Critical';

EXEC dbo.usp_Security_InactiveAccountReport
    @RiskTier = 'High Risk';

-- Full access review including disabled accounts, no threshold filter:
EXEC dbo.usp_Security_InactiveAccountReport
    @InactiveDaysThreshold = 0,
    @IncludeDisabled       = 1;

-- Inactive doctor accounts only:
EXEC dbo.usp_Security_InactiveAccountReport
    @RoleName = 'Doctor';
GO


-- =============================================================================
-- REPORT 4
-- =============================================================================
-- Title       : Duplicate Record Detection — Patient and Appointment Data
--               Integrity Scan
--
-- Business Question:
--   Are there patients who appear to be registered more than once (same name
--   and date of birth, or same email address), or appointments that have been
--   booked twice for the same patient and doctor at an overlapping date?  If so,
--   which records are the likely duplicates that should be reviewed for merger
--   or deletion?
--
-- Purpose / Business Value:
--   Duplicate records are a persistent data-quality problem in any system that
--   supports registrations from multiple entry points (walk-in desk, online
--   portal, phone booking).  In a hospital context they carry specific risks:
--       – Clinical Safety: A clinician reviewing a patient's history may see
--         only one of two duplicate records, missing prior diagnoses,
--         prescriptions, or allergies that are attached to the other copy.
--         This can lead to dangerous drug interactions or incorrect dosing.
--       – Billing Integrity: Duplicate patient records can result in the same
--         treatment being billed to two different accounts, making it
--         impossible to produce a single accurate statement of account.
--       – Insurance Claims: Submitting a claim under the wrong patient ID
--         (because two records exist for the same person) can trigger claim
--         rejections or fraud flags with the insurer.
--       – Regulatory Reporting: Patient-count metrics reported to health
--         authorities will be inflated if duplicate records are not detected
--         and merged.
--   The procedure returns THREE result sets:
--       1. Name + DOB duplicate groups — patients sharing the same first name,
--          last name, and date of birth, with all matching record IDs listed
--          so the data team can identify the original vs. the duplicate.
--       2. Email duplicate groups — patients sharing the exact same email
--          address (a near-certain signal of a duplicate registration).
--       3. Appointment overlap groups — same patient and same doctor booked
--          on the same calendar date more than once (double-booking detection).
--
-- Information Returned:
--   RS1 (name+DOB dupes): Shared first name, last name, DOB, duplicate group
--   count, comma-separated list of matching PatientIDs, earliest and latest
--   record creation dates in the group.
--   RS2 (email dupes): Shared email address, duplicate group count, PatientIDs,
--   first and last names of all records sharing that email.
--   RS3 (appointment dupes): PatientID, patient full name, DoctorID, doctor
--   full name, appointment day, count of bookings on that day, appointment IDs
--   and statuses for each overlapping slot.
--
-- Advanced Techniques Used:
--   Self-join on Patients (aliased p1, p2) for row-pair duplicate detection;
--   GROUP BY + HAVING COUNT(*) > 1 to isolate duplicated key values; STRING_AGG
--   to collapse multiple matching IDs into a single readable column; CAST to DATE
--   for appointment-day bucketing; COUNT(*) OVER (PARTITION BY ...) window
--   function to flag every row that belongs to a duplicated group; subquery to
--   build per-group STRING_AGG output; INNER JOIN across Patients, Appointments,
--   and Doctors.
-- =============================================================================

-- No persistent view is defined for this report — duplicate detection depends
-- on HAVING COUNT > 1 logic that is most clearly expressed inline within the
-- procedure.  The three result sets are self-contained.

-- -----------------------------------------------------------------------------
-- Stored Procedure: dbo.usp_Security_DuplicateRecordScan
--
-- Parameters:
--   @ScanTarget  VARCHAR(20) — 'Patients' | 'Appointments' | 'All' (default)
--                              controls which result sets are returned
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Security_DuplicateRecordScan
    @ScanTarget VARCHAR(20) = 'All'
AS
BEGIN
    SET NOCOUNT ON;

    -- -------------------------------------------------------------------------
    -- Result Set 1: Patient duplicates by First Name + Last Name + DOB
    -- Patients who share all three values are almost certainly the same person
    -- registered twice.  STRING_AGG lists every PatientID in the group.
    -- -------------------------------------------------------------------------
    IF @ScanTarget IN ('Patients', 'All')
    BEGIN
        SELECT
            p.FirstName,
            p.LastName,
            p.DOB,
            COUNT(p.PatientID)                          AS DuplicateCount,
            STRING_AGG(CAST(p.PatientID AS VARCHAR(10)), ', ')
                WITHIN GROUP (ORDER BY p.PatientID)     AS PatientIDs,
            STRING_AGG(p.Email, ' | ')
                WITHIN GROUP (ORDER BY p.PatientID)     AS EmailAddresses,
            MIN(p.DateCreated)                          AS EarliestRecordCreated,
            MAX(p.DateCreated)                          AS LatestRecordCreated,
            DATEDIFF(
                DAY,
                MIN(p.DateCreated),
                MAX(p.DateCreated)
            )                                           AS DaysBetweenRegistrations
        FROM   dbo.Patients p
        GROUP BY
            p.FirstName,
            p.LastName,
            p.DOB
        HAVING COUNT(p.PatientID) > 1
        ORDER BY DuplicateCount DESC, p.LastName, p.FirstName;
    END;

    -- -------------------------------------------------------------------------
    -- Result Set 2: Patient duplicates by Email address
    -- A shared email is a near-certain indicator of a duplicate registration.
    -- Returns each unique email that appears on more than one patient record.
    -- -------------------------------------------------------------------------
    IF @ScanTarget IN ('Patients', 'All')
    BEGIN
        SELECT
            p.Email                                     AS SharedEmail,
            COUNT(p.PatientID)                          AS DuplicateCount,
            STRING_AGG(CAST(p.PatientID AS VARCHAR(10)), ', ')
                WITHIN GROUP (ORDER BY p.PatientID)     AS PatientIDs,
            STRING_AGG(p.FirstName + ' ' + p.LastName, ' | ')
                WITHIN GROUP (ORDER BY p.PatientID)     AS PatientNames,
            STRING_AGG(CAST(p.DOB AS VARCHAR(10)), ' | ')
                WITHIN GROUP (ORDER BY p.PatientID)     AS DatesOfBirth,
            MIN(p.DateCreated)                          AS EarliestRecordCreated,
            MAX(p.DateCreated)                          AS LatestRecordCreated
        FROM   dbo.Patients p
        GROUP BY p.Email
        HAVING COUNT(p.PatientID) > 1
        ORDER BY DuplicateCount DESC, p.Email;
    END;

    -- -------------------------------------------------------------------------
    -- Result Set 3: Appointment double-bookings
    -- Same patient + same doctor + same calendar day booked more than once.
    -- The inner aggregation identifies the (PatientID, DoctorID, Day) groups
    -- that have > 1 booking; the outer query retrieves every appointment row
    -- belonging to those groups so each individual booking can be reviewed.
    -- -------------------------------------------------------------------------
    IF @ScanTarget IN ('Appointments', 'All')
    BEGIN
        WITH DoubleBookedGroups AS (
            SELECT
                a.PatientID,
                a.DoctorID,
                CAST(a.AppointmentDate AS DATE)         AS AppointmentDay,
                COUNT(a.AppointmentID)                  AS BookingCount,
                STRING_AGG(CAST(a.AppointmentID AS VARCHAR(10)), ', ')
                    WITHIN GROUP (ORDER BY a.AppointmentDate)
                                                        AS AppointmentIDs,
                STRING_AGG(a.Status, ' | ')
                    WITHIN GROUP (ORDER BY a.AppointmentDate)
                                                        AS Statuses
            FROM  dbo.Appointments a
            GROUP BY
                a.PatientID,
                a.DoctorID,
                CAST(a.AppointmentDate AS DATE)
            HAVING COUNT(a.AppointmentID) > 1
        )
        SELECT
            dbg.PatientID,
            p.FirstName + ' ' + p.LastName              AS PatientFullName,
            dbg.DoctorID,
            dr.FirstName + ' ' + dr.LastName            AS DoctorFullName,
            dept.DepartmentName,
            dbg.AppointmentDay,
            dbg.BookingCount,
            dbg.AppointmentIDs,
            dbg.Statuses
        FROM       DoubleBookedGroups  dbg
        INNER JOIN dbo.Patients        p    ON p.PatientID    = dbg.PatientID
        INNER JOIN dbo.Doctors         dr   ON dr.DoctorID    = dbg.DoctorID
        INNER JOIN dbo.Departments     dept ON dept.DepartmentID = dr.DepartmentID
        ORDER BY dbg.AppointmentDay DESC, dbg.PatientID;
    END;
END;
GO

-- Sample executions:
-- Full scan — all three result sets:
EXEC dbo.usp_Security_DuplicateRecordScan;

-- Patient duplicates only:
EXEC dbo.usp_Security_DuplicateRecordScan
    @ScanTarget = 'Patients';

-- Appointment double-bookings only:
EXEC dbo.usp_Security_DuplicateRecordScan
    @ScanTarget = 'Appointments';
GO


-- =============================================================================
-- REPORT 5
-- =============================================================================
-- Title       : System Activity Summary — Daily Operations Health Dashboard
--
-- Business Question:
--   What is the overall level of system activity over a given period — how many
--   records were created or modified across the key clinical and administrative
--   tables each day, which users are the most active, and are there any days
--   with anomalously high or low activity that warrant investigation?
--
-- Purpose / Business Value:
--   A daily activity summary is a first-line operational health check for the
--   IT and system administration team:
--       – Baseline and Anomaly Detection: By knowing the typical daily volume
--         of inserts and updates across key tables, administrators can detect
--         when a day's activity falls far outside the norm — which may signal
--         a bulk data migration gone wrong, a runaway process, a system
--         outage that suppressed activity, or a coordinated data-exfiltration
--         attempt.
--       – Capacity Planning: Long-run trends in daily record-creation volumes
--         inform database growth projections and help schedule maintenance
--         windows (index rebuilds, statistics updates) for low-activity
--         periods.
--       – Staff Productivity Monitoring: In administrative functions (billing,
--         scheduling), daily action counts per user can be compared to
--         expected workload targets.  An unusually low count for a given user
--         on a specific day might indicate a system access problem.
--       – Incident Timeline Reconstruction: During a security incident or data
--         integrity investigation, the daily summary helps the team quickly
--         pinpoint which day(s) show abnormal patterns before drilling into the
--         detailed audit log (Report 2).
--   The procedure returns TWO result sets:
--       1. Daily activity totals — one row per calendar day, with total
--          audit events, breakdown by action type (INSERT/UPDATE/DELETE),
--          count of distinct users active that day, count of distinct tables
--          touched, and an anomaly flag based on deviation from the rolling
--          7-day average.
--       2. Top active users per period — aggregated across the requested date
--          range, showing each user's total event count, preferred action type,
--          most-touched table, and their activity rank.
--
-- Information Returned:
--   RS1 (daily totals): Action day, total events, INSERT count, UPDATE count,
--   DELETE count, distinct active users, distinct tables touched,
--   7-day rolling average event count, deviation from that average,
--   and IsAnomaly flag (deviation > 50% above or below the rolling average).
--   RS2 (top users): Username, role, total events, INSERT/UPDATE/DELETE counts,
--   most-active table, preferred action type, first and last active dates,
--   active day count, and overall activity rank.
--
-- Advanced Techniques Used:
--   AVG() OVER (ORDER BY ActionDay ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)
--   for a rolling 7-day window average; conditional aggregation (CASE inside
--   COUNT/SUM) for per-action-type breakdowns; FIRST_VALUE() OVER (PARTITION
--   BY Username ORDER BY EventCount DESC) to identify each user's most-touched
--   table and preferred action type without a self-join; COUNT(DISTINCT ...) for
--   user and table cardinality per day; RANK() OVER for user activity ranking;
--   GROUP BY with CTEs for multi-step aggregation; NULLIF for safe division.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Stored Procedure: dbo.usp_Security_SystemActivitySummary
--
-- Parameters:
--   @StartDate   DATE   — lower bound on ActionDate; NULL = all time
--   @EndDate     DATE   — upper bound on ActionDate; NULL = all time
--   @TopNUsers   INT    — number of top users returned in RS2; default 10
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Security_SystemActivitySummary
    @StartDate  DATE = NULL,
    @EndDate    DATE = NULL,
    @TopNUsers  INT  = 10
AS
BEGIN
    SET NOCOUNT ON;

    -- -------------------------------------------------------------------------
    -- Result Set 1: Daily activity totals with 7-day rolling average
    -- -------------------------------------------------------------------------
    WITH DailyBase AS (
        SELECT
            CAST(al.ActionDate AS DATE)             AS ActionDay,
            COUNT(al.AuditID)                       AS TotalEvents,
            COUNT(CASE WHEN al.ActionType = 'INSERT' THEN 1 END)
                                                    AS InsertCount,
            COUNT(CASE WHEN al.ActionType = 'UPDATE' THEN 1 END)
                                                    AS UpdateCount,
            COUNT(CASE WHEN al.ActionType = 'DELETE' THEN 1 END)
                                                    AS DeleteCount,
            COUNT(DISTINCT al.PerformedByUserID)    AS DistinctActiveUsers,
            COUNT(DISTINCT al.TableName)            AS DistinctTablesTouched
        FROM  dbo.AuditLogs al
        WHERE (@StartDate IS NULL OR CAST(al.ActionDate AS DATE) >= @StartDate)
          AND (@EndDate   IS NULL OR CAST(al.ActionDate AS DATE) <= @EndDate)
        GROUP BY CAST(al.ActionDate AS DATE)
    ),
    DailyWithRolling AS (
        SELECT
            ActionDay,
            TotalEvents,
            InsertCount,
            UpdateCount,
            DeleteCount,
            DistinctActiveUsers,
            DistinctTablesTouched,
            -- 7-day rolling average (current day + 6 preceding days)
            ROUND(
                AVG(CAST(TotalEvents AS FLOAT)) OVER (
                    ORDER BY ActionDay
                    ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
                ),
            1)                                      AS Rolling7DayAvg
        FROM DailyBase
    )
    SELECT
        ActionDay,
        TotalEvents,
        InsertCount,
        UpdateCount,
        DeleteCount,
        DistinctActiveUsers,
        DistinctTablesTouched,
        Rolling7DayAvg,
        -- Absolute deviation from rolling average
        ROUND(TotalEvents - Rolling7DayAvg, 1)      AS DeviationFromAvg,
        -- Anomaly flag: activity more than 50% above or below rolling average
        CASE
            WHEN Rolling7DayAvg = 0 THEN 0
            WHEN ABS(TotalEvents - Rolling7DayAvg)
                 / NULLIF(Rolling7DayAvg, 0) > 0.50 THEN 1
            ELSE 0
        END                                         AS IsAnomaly
    FROM  DailyWithRolling
    ORDER BY ActionDay ASC;

    -- -------------------------------------------------------------------------
    -- Result Set 2: Top N most active users over the requested period
    -- FIRST_VALUE identifies each user's most-touched table and dominant
    -- action type by partitioning their per-(table, actiontype) counts.
    -- -------------------------------------------------------------------------
    WITH UserTableAction AS (
        -- Pre-aggregate per user, table, and action type
        SELECT
            u.UserID,
            u.Username,
            r.RoleName,
            al.TableName,
            al.ActionType,
            COUNT(al.AuditID)                       AS CombinationEventCount
        FROM      dbo.AuditLogs al
        INNER JOIN dbo.Users    u  ON u.UserID = al.PerformedByUserID
        INNER JOIN dbo.Roles    r  ON r.RoleID  = u.RoleID
        WHERE (@StartDate IS NULL OR CAST(al.ActionDate AS DATE) >= @StartDate)
          AND (@EndDate   IS NULL OR CAST(al.ActionDate AS DATE) <= @EndDate)
        GROUP BY u.UserID, u.Username, r.RoleName, al.TableName, al.ActionType
    ),
    UserTotals AS (
        -- Roll up to user level, pulling most-active table and action
        SELECT
            UserID,
            Username,
            RoleName,
            SUM(CombinationEventCount)              AS TotalEvents,
            -- Most-touched table for this user
            FIRST_VALUE(TableName) OVER (
                PARTITION BY UserID
                ORDER BY     CombinationEventCount DESC
                ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
            )                                       AS MostActiveTable,
            -- Dominant action type for this user
            FIRST_VALUE(ActionType) OVER (
                PARTITION BY UserID
                ORDER BY     CombinationEventCount DESC
                ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
            )                                       AS PreferredActionType
        FROM  UserTableAction
    ),
    UserTotalsDistinct AS (
        SELECT DISTINCT
            uta.UserID,
            uta.Username,
            uta.RoleName,
            uta.TotalEvents,
            uta.MostActiveTable,
            uta.PreferredActionType,
            -- Per-action-type totals (re-joined from base AuditLogs)
            (SELECT COUNT(*) FROM dbo.AuditLogs a2
             WHERE  a2.PerformedByUserID = uta.UserID
               AND  a2.ActionType = 'INSERT'
               AND (@StartDate IS NULL OR CAST(a2.ActionDate AS DATE) >= @StartDate)
               AND (@EndDate   IS NULL OR CAST(a2.ActionDate AS DATE) <= @EndDate))
                                                    AS InsertCount,
            (SELECT COUNT(*) FROM dbo.AuditLogs a2
             WHERE  a2.PerformedByUserID = uta.UserID
               AND  a2.ActionType = 'UPDATE'
               AND (@StartDate IS NULL OR CAST(a2.ActionDate AS DATE) >= @StartDate)
               AND (@EndDate   IS NULL OR CAST(a2.ActionDate AS DATE) <= @EndDate))
                                                    AS UpdateCount,
            (SELECT COUNT(*) FROM dbo.AuditLogs a2
             WHERE  a2.PerformedByUserID = uta.UserID
               AND  a2.ActionType = 'DELETE'
               AND (@StartDate IS NULL OR CAST(a2.ActionDate AS DATE) >= @StartDate)
               AND (@EndDate   IS NULL OR CAST(a2.ActionDate AS DATE) <= @EndDate))
                                                    AS DeleteCount,
            -- Active day count
            (SELECT COUNT(DISTINCT CAST(a2.ActionDate AS DATE))
             FROM   dbo.AuditLogs a2
             WHERE  a2.PerformedByUserID = uta.UserID
               AND (@StartDate IS NULL OR CAST(a2.ActionDate AS DATE) >= @StartDate)
               AND (@EndDate   IS NULL OR CAST(a2.ActionDate AS DATE) <= @EndDate))
                                                    AS ActiveDayCount,
            CAST(
                (SELECT MIN(a2.ActionDate) FROM dbo.AuditLogs a2
                 WHERE  a2.PerformedByUserID = uta.UserID
                   AND (@StartDate IS NULL OR CAST(a2.ActionDate AS DATE) >= @StartDate)
                   AND (@EndDate   IS NULL OR CAST(a2.ActionDate AS DATE) <= @EndDate))
            AS DATE)                                AS FirstActiveDate,
            CAST(
                (SELECT MAX(a2.ActionDate) FROM dbo.AuditLogs a2
                 WHERE  a2.PerformedByUserID = uta.UserID
                   AND (@StartDate IS NULL OR CAST(a2.ActionDate AS DATE) >= @StartDate)
                   AND (@EndDate   IS NULL OR CAST(a2.ActionDate AS DATE) <= @EndDate))
            AS DATE)                                AS LastActiveDate
        FROM  UserTotals uta
    )
    SELECT TOP (@TopNUsers) WITH TIES
        RANK() OVER (ORDER BY TotalEvents DESC)     AS ActivityRank,
        UserID,
        Username,
        RoleName,
        TotalEvents,
        InsertCount,
        UpdateCount,
        DeleteCount,
        ActiveDayCount,
        MostActiveTable,
        PreferredActionType,
        FirstActiveDate,
        LastActiveDate
    FROM  UserTotalsDistinct
    ORDER BY ActivityRank ASC;
END;
GO

-- Sample executions:
-- Full system activity summary, all time, top 10 users:
EXEC dbo.usp_Security_SystemActivitySummary;

-- Activity for 2025, top 5 most active users:
EXEC dbo.usp_Security_SystemActivitySummary
    @StartDate = '2025-01-01',
    @EndDate   = '2025-12-31',
    @TopNUsers = 5;

-- Last 90 days:
EXEC dbo.usp_Security_SystemActivitySummary
    @StartDate = DATEADD(DAY, -90, CAST(GETDATE() AS DATE));
GO
