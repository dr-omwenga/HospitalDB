-- =============================================================================
-- HospitalDB — Data Security and PII Masking Framework
-- File        : sql/09_data_masking.sql
-- Author      : Hospital Information Systems
-- Date        : 2026-05-07
-- Description :
--   Implements a consistent, centralised data-masking framework for all
--   personally identifiable information (PII) stored in HospitalDB.
--
--   The framework is composed of four layers:
--
--     Layer 1 — Masking Helper Functions (dbo.fn_Mask*)
--       Reusable scalar UDFs that apply a single, standardised masking
--       algorithm to one column value.  All masking logic lives here;
--       views and procedures call these functions rather than repeating
--       inline CASE/REPLICATE expressions.
--
--     Layer 2 — Privilege Context Function (dbo.fn_IsPrivilegedSession)
--       Reads SESSION_CONTEXT(N'DataAccess') to determine whether the
--       current connection has been explicitly authorised for full (unmasked)
--       data access.  Views use this function to decide at query-time whether
--       to return raw or masked column values.
--
--     Layer 3 — Masked Views (dbo.vw_*_Masked)
--       One view per sensitive entity table.  Each view applies masking by
--       default and exposes the full value only when fn_IsPrivilegedSession()
--       returns 1.  Granting SELECT on these views (and revoking direct SELECT
--       on the base tables) enforces masking for non-privileged roles.
--
--     Layer 4 — Access Control Procedures
--       usp_Security_AuthorizeFullDataAccess  — elevates the current session
--         to full-data access (read-only flag prevents elevation reversal).
--       usp_Security_GetPatientRecord         — explicit @AccessLevel param
--         for cases where SESSION_CONTEXT cannot be set by the caller.
--
--   Sensitive fields masked:
--     • Email address  — j***@example.com      (first local char + *** + domain)
--     • Phone number   — 07******78            (first 2 + middle masked + last 2)
--     • Date of birth  — 1990-**-**            (year retained for analytics)
--     • Name columns   — M******t              (first + middle masked + last)
--     • Policy number  — PO**********21        (first 2 + middle masked + last 2)
--     • License number — LIC***********02      (first 3 + middle masked + last 2)
--
--   Permission model:
--     GRANT  SELECT ON dbo.vw_Patients_Masked         TO [reporting_role];
--     GRANT  SELECT ON dbo.vw_Doctors_Masked          TO [reporting_role];
--     GRANT  SELECT ON dbo.vw_EmergencyContacts_Masked TO [reporting_role];
--     REVOKE SELECT ON dbo.Patients                   FROM [reporting_role];
--     -- Full access:
--     GRANT  EXECUTE ON dbo.usp_Security_AuthorizeFullDataAccess TO [clinical_role];
--
--   NOTE: Run this file AFTER 08_security_admin_reports.sql.  The final
--   section re-issues vw_MaskedPatientDirectory using the standardised
--   masking functions, replacing the inline expressions in file 08.
-- =============================================================================

USE HospitalDB;
GO

-- =============================================================================
-- LAYER 1 — MASKING HELPER FUNCTIONS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Function : dbo.fn_MaskEmail
-- Purpose  : Masks an email address local-part, preserving the domain.
-- Algorithm: Keep the first character of the local part, replace the rest
--            with '***', retain everything from '@' onward.
-- Example  : john.doe@example.com  →  j***@example.com
-- -----------------------------------------------------------------------------
CREATE OR ALTER FUNCTION dbo.fn_MaskEmail
(
    @Email VARCHAR(120)
)
RETURNS VARCHAR(120)
AS
BEGIN
    IF @Email IS NULL RETURN NULL;

    DECLARE @AtPos INT = CHARINDEX('@', @Email);

    -- If no '@' found, the value is malformed; return fully masked
    IF @AtPos = 0
        RETURN REPLICATE('*', LEN(@Email));

    -- First char of local part + '***' + '@domain'
    RETURN LEFT(@Email, 1)
           + '***'
           + SUBSTRING(@Email, @AtPos, LEN(@Email) - @AtPos + 1);
END;
GO

-- -----------------------------------------------------------------------------
-- Function : dbo.fn_MaskPhone
-- Purpose  : Masks a phone number, revealing only the first 2 and last 2
--            characters.
-- Algorithm: LEFT(2) + REPLICATE('*', len - 4) + RIGHT(2)
-- Example  : 0712345678  →  07******78
-- -----------------------------------------------------------------------------
CREATE OR ALTER FUNCTION dbo.fn_MaskPhone
(
    @Phone VARCHAR(25)
)
RETURNS VARCHAR(25)
AS
BEGIN
    IF @Phone IS NULL RETURN NULL;

    DECLARE @Len INT = LEN(@Phone);

    -- Too short to apply partial masking — return fully masked
    IF @Len <= 4
        RETURN REPLICATE('*', @Len);

    RETURN LEFT(@Phone, 2)
           + REPLICATE('*', @Len - 4)
           + RIGHT(@Phone, 2);
END;
GO

-- -----------------------------------------------------------------------------
-- Function : dbo.fn_MaskDOB
-- Purpose  : Masks a date of birth by retaining the year (useful for age-band
--            analytics) while hiding the specific month and day.
-- Algorithm: YEAR retained; month and day replaced with '**'
-- Example  : 1990-07-15  →  '1990-**-**'
-- Returns  : VARCHAR(10) — always the same fixed width
-- -----------------------------------------------------------------------------
CREATE OR ALTER FUNCTION dbo.fn_MaskDOB
(
    @DOB DATE
)
RETURNS VARCHAR(10)
AS
BEGIN
    IF @DOB IS NULL RETURN NULL;

    RETURN CAST(YEAR(@DOB) AS VARCHAR(4)) + '-**-**';
END;
GO

-- -----------------------------------------------------------------------------
-- Function : dbo.fn_MaskName
-- Purpose  : Masks a name (first name, last name, or full name) by keeping
--            only the first and last characters.
-- Algorithm: LEFT(1) + REPLICATE('*', len - 2) + RIGHT(1)
-- Examples : Margaret  →  M******t
--            Li        →  L*
--            A         →  *
-- -----------------------------------------------------------------------------
CREATE OR ALTER FUNCTION dbo.fn_MaskName
(
    @Name VARCHAR(120)
)
RETURNS VARCHAR(120)
AS
BEGIN
    IF @Name IS NULL RETURN NULL;

    DECLARE @Len INT = LEN(@Name);

    IF @Len = 0 RETURN '';
    IF @Len = 1 RETURN '*';
    IF @Len = 2 RETURN LEFT(@Name, 1) + '*';

    RETURN LEFT(@Name, 1)
           + REPLICATE('*', @Len - 2)
           + RIGHT(@Name, 1);
END;
GO

-- -----------------------------------------------------------------------------
-- Function : dbo.fn_MaskPolicyNumber
-- Purpose  : Masks an insurance policy number, showing only the first 2 and
--            last 2 characters.
-- Example  : POL-20483921  →  PO**********21
-- -----------------------------------------------------------------------------
CREATE OR ALTER FUNCTION dbo.fn_MaskPolicyNumber
(
    @PolicyNumber VARCHAR(50)
)
RETURNS VARCHAR(50)
AS
BEGIN
    IF @PolicyNumber IS NULL RETURN NULL;

    DECLARE @Len INT = LEN(@PolicyNumber);

    IF @Len <= 4
        RETURN REPLICATE('*', @Len);

    RETURN LEFT(@PolicyNumber, 2)
           + REPLICATE('*', @Len - 4)
           + RIGHT(@PolicyNumber, 2);
END;
GO

-- -----------------------------------------------------------------------------
-- Function : dbo.fn_MaskLicenseNumber
-- Purpose  : Masks a medical license number, showing the first 3 and last 2
--            characters only.  License numbers typically have a meaningful
--            prefix (issuing body code) and a check suffix.
-- Example  : LIC-0049302  →  LIC******02
-- -----------------------------------------------------------------------------
CREATE OR ALTER FUNCTION dbo.fn_MaskLicenseNumber
(
    @LicenseNumber VARCHAR(50)
)
RETURNS VARCHAR(50)
AS
BEGIN
    IF @LicenseNumber IS NULL RETURN NULL;

    DECLARE @Len INT = LEN(@LicenseNumber);

    IF @Len <= 5
        RETURN REPLICATE('*', @Len);

    RETURN LEFT(@LicenseNumber, 3)
           + REPLICATE('*', @Len - 5)
           + RIGHT(@LicenseNumber, 2);
END;
GO


-- =============================================================================
-- LAYER 2 — PRIVILEGE CONTEXT FUNCTION
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Function : dbo.fn_IsPrivilegedSession
-- Purpose  : Returns 1 if the current database session has been explicitly
--            elevated to full data access via usp_Security_AuthorizeFullDataAccess,
--            otherwise returns 0 (masked access).
--
-- Mechanism: Reads SESSION_CONTEXT(N'DataAccess').  The authorisation procedure
--            sets this to 'Full' with @read_only = 1, meaning the value cannot
--            be altered by the caller for the remainder of the session.  A new
--            connection always starts with NULL (i.e. masked access).
--
-- Usage in views:
--   CASE WHEN dbo.fn_IsPrivilegedSession() = 1 THEN p.Email
--        ELSE dbo.fn_MaskEmail(p.Email)
--   END AS Email
-- -----------------------------------------------------------------------------
CREATE OR ALTER FUNCTION dbo.fn_IsPrivilegedSession()
RETURNS BIT
AS
BEGIN
    RETURN CASE
        WHEN CAST(SESSION_CONTEXT(N'DataAccess') AS VARCHAR(20)) = 'Full'
            THEN CAST(1 AS BIT)
        ELSE CAST(0 AS BIT)
    END;
END;
GO


-- =============================================================================
-- LAYER 3 — PRIVILEGE-AWARE MASKED VIEWS
-- =============================================================================
-- Design rule: every sensitive column has a CASE expression:
--   • Privileged session  → raw value
--   • Non-privileged      → dbo.fn_Mask*() result
-- Non-sensitive columns (IDs, Gender, DateCreated, etc.) are always returned
-- as-is since they carry no PII risk on their own.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- View : dbo.vw_Patients_Masked
-- Sensitive columns: FirstName, LastName, DOB, Phone, Email
-- Safe columns:      PatientID, AddressID, Gender, DateCreated
-- -----------------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_Patients_Masked
AS
SELECT
    p.PatientID,
    p.AddressID,

    CASE WHEN dbo.fn_IsPrivilegedSession() = 1
         THEN p.FirstName
         ELSE dbo.fn_MaskName(p.FirstName)
    END                                         AS FirstName,

    CASE WHEN dbo.fn_IsPrivilegedSession() = 1
         THEN p.LastName
         ELSE dbo.fn_MaskName(p.LastName)
    END                                         AS LastName,

    CASE WHEN dbo.fn_IsPrivilegedSession() = 1
         THEN CAST(p.DOB AS VARCHAR(10))
         ELSE dbo.fn_MaskDOB(p.DOB)
    END                                         AS DOB,

    p.Gender,   -- not individually sensitive; age+gender alone cannot identify

    CASE WHEN dbo.fn_IsPrivilegedSession() = 1
         THEN p.Phone
         ELSE dbo.fn_MaskPhone(p.Phone)
    END                                         AS Phone,

    CASE WHEN dbo.fn_IsPrivilegedSession() = 1
         THEN p.Email
         ELSE dbo.fn_MaskEmail(p.Email)
    END                                         AS Email,

    p.DateCreated
FROM dbo.Patients p;
GO

-- -----------------------------------------------------------------------------
-- View : dbo.vw_Doctors_Masked
-- Sensitive columns: Phone, Email, LicenseNumber
-- Semi-public:       FirstName, LastName, Specialization (appear on appointment
--                    documents — masked only in strict-privacy contexts but kept
--                    visible here as doctors are public-facing staff)
-- -----------------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_Doctors_Masked
AS
SELECT
    d.DoctorID,
    d.DepartmentID,

    -- Doctor names are semi-public; masked only in privileged-off contexts
    -- where even staff directory access is restricted
    CASE WHEN dbo.fn_IsPrivilegedSession() = 1
         THEN d.FirstName
         ELSE dbo.fn_MaskName(d.FirstName)
    END                                         AS FirstName,

    CASE WHEN dbo.fn_IsPrivilegedSession() = 1
         THEN d.LastName
         ELSE dbo.fn_MaskName(d.LastName)
    END                                         AS LastName,

    CASE WHEN dbo.fn_IsPrivilegedSession() = 1
         THEN d.Phone
         ELSE dbo.fn_MaskPhone(d.Phone)
    END                                         AS Phone,

    CASE WHEN dbo.fn_IsPrivilegedSession() = 1
         THEN d.Email
         ELSE dbo.fn_MaskEmail(d.Email)
    END                                         AS Email,

    d.Specialization,   -- non-PII; required for scheduling and referrals

    CASE WHEN dbo.fn_IsPrivilegedSession() = 1
         THEN d.LicenseNumber
         ELSE dbo.fn_MaskLicenseNumber(d.LicenseNumber)
    END                                         AS LicenseNumber
FROM dbo.Doctors d;
GO

-- -----------------------------------------------------------------------------
-- View : dbo.vw_EmergencyContacts_Masked
-- Sensitive columns: FullName, Phone, Email
-- Safe columns:      EmergencyContactID, PatientID, Relationship
-- -----------------------------------------------------------------------------
CREATE OR ALTER VIEW dbo.vw_EmergencyContacts_Masked
AS
SELECT
    ec.EmergencyContactID,
    ec.PatientID,

    CASE WHEN dbo.fn_IsPrivilegedSession() = 1
         THEN ec.FullName
         ELSE dbo.fn_MaskName(ec.FullName)
    END                                         AS FullName,

    ec.Relationship,   -- non-sensitive; needed for triage decisions

    CASE WHEN dbo.fn_IsPrivilegedSession() = 1
         THEN ec.Phone
         ELSE dbo.fn_MaskPhone(ec.Phone)
    END                                         AS Phone,

    CASE WHEN dbo.fn_IsPrivilegedSession() = 1
         THEN ec.Email
         ELSE dbo.fn_MaskEmail(ec.Email)
    END                                         AS Email
FROM dbo.EmergencyContacts ec;
GO


-- =============================================================================
-- LAYER 4 — ACCESS CONTROL PROCEDURES
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Procedure : dbo.usp_Security_AuthorizeFullDataAccess
-- Purpose   : Elevates the current database session to full (unmasked) data
--             access by writing 'Full' into SESSION_CONTEXT with @read_only = 1.
--             Once set, the value cannot be changed or revoked within the same
--             connection — the session must be closed and reopened to revert.
--
-- Parameters:
--   @CallerRole  VARCHAR(50) — the role of the calling user (must be in the
--                              approved list below to grant elevation)
--
-- Approved roles: Administrator, Doctor, Nurse, BillingManager
-- All other roles receive an error and remain on masked access.
--
-- Usage:
--   EXEC dbo.usp_Security_AuthorizeFullDataAccess @CallerRole = 'Doctor';
--   SELECT * FROM dbo.vw_Patients_Masked;  -- returns full unmasked data
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Security_AuthorizeFullDataAccess
    @CallerRole VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    IF @CallerRole IN ('Administrator', 'Doctor', 'Nurse', 'BillingManager')
    BEGIN
        -- @read_only = 1: cannot be changed for the rest of this session,
        -- preventing a non-privileged caller from re-setting it to NULL.
        EXEC sys.sp_set_session_context
            @key       = N'DataAccess',
            @value     = N'Full',
            @read_only = 1;

        PRINT 'Session elevated to full data access. Masked views will return unmasked values for this connection.';
    END
    ELSE
    BEGIN
        RAISERROR(
            'Role [%s] is not authorised for full data access. Masked values will be returned by all views.',
            16, 1, @CallerRole
        );
    END
END;
GO

-- -----------------------------------------------------------------------------
-- Procedure : dbo.usp_Security_GetPatientRecord
-- Purpose   : Returns a single patient's full record with masking level
--             controlled explicitly by the @AccessLevel parameter.  Intended
--             for application layers where SESSION_CONTEXT cannot be set
--             (e.g. read-only reporting tools, REST API service accounts).
--
-- Parameters:
--   @PatientID   INT          — the patient to retrieve
--   @AccessLevel VARCHAR(10)  — 'Masked' (default) or 'Full'
--
-- Security note: restrict EXECUTE permission on this procedure to roles that
--   have been approved for full access.  Granting EXECUTE to a low-privilege
--   role while @AccessLevel = 'Full' is an application-layer authorisation
--   failure; the procedure itself does not validate the caller's role.
--   Use usp_Security_AuthorizeFullDataAccess + the masked views for a
--   role-validated, session-scoped approach instead.
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Security_GetPatientRecord
    @PatientID   INT,
    @AccessLevel VARCHAR(10) = 'Masked'
AS
BEGIN
    SET NOCOUNT ON;

    IF @AccessLevel = 'Full'
    BEGIN
        -- Return the complete, unmasked patient record with address
        SELECT
            p.PatientID,
            p.FirstName,
            p.LastName,
            CAST(p.DOB AS VARCHAR(10))      AS DOB,
            p.Gender,
            p.Phone,
            p.Email,
            p.DateCreated,
            a.Street,
            a.City,
            a.State,
            a.PostalCode,
            a.Country
        FROM      dbo.Patients   p
        INNER JOIN dbo.Addresses a ON a.AddressID = p.AddressID
        WHERE p.PatientID = @PatientID;
    END
    ELSE
    BEGIN
        -- Return the masked record via the privilege-aware view
        SELECT
            pm.PatientID,
            pm.FirstName,
            pm.LastName,
            pm.DOB,
            pm.Gender,
            pm.Phone,
            pm.Email,
            pm.DateCreated,
            -- Street address masked; city/state kept for operational use
            REPLICATE('*', 6)               AS Street,
            a.City,
            a.State,
            a.PostalCode,
            a.Country
        FROM      dbo.vw_Patients_Masked pm
        INNER JOIN dbo.Addresses          a  ON a.AddressID = pm.AddressID
        WHERE pm.PatientID = @PatientID;
    END
END;
GO


-- =============================================================================
-- UPGRADE: vw_MaskedPatientDirectory
-- =============================================================================
-- Replaces the inline masking expressions in sql/08_security_admin_reports.sql
-- with calls to the standardised masking functions defined in this file.
-- Masking patterns now match the organisation-wide standard:
--   Email  : j***@example.com   (was: j...e@domain)
--   Phone  : 07******78         (was: ********5309  — last 4 shown)
--   Name   : M******t           (unchanged — same algorithm, now via fn_MaskName)
--   Policy : PO**********21     (unchanged — same algorithm, now via fn_MaskPolicyNumber)
--   DOB    : 1990-**-**         (was: DATEFROMPARTS with day=01)
-- =============================================================================
CREATE OR ALTER VIEW dbo.vw_MaskedPatientDirectory
AS
SELECT
    p.PatientID,
    dbo.fn_MaskName(p.FirstName)                AS MaskedFirstName,
    dbo.fn_MaskName(p.LastName)                 AS MaskedLastName,
    dbo.fn_MaskDOB(p.DOB)                       AS MaskedDOB,
    p.Gender,
    dbo.fn_MaskPhone(p.Phone)                   AS MaskedPhone,
    dbo.fn_MaskEmail(p.Email)                   AS MaskedEmail,

    -- Address: city and state retained for geographic analysis; street masked
    addr.City,
    addr.State,
    addr.Country,

    -- Insurance policy
    dbo.fn_MaskPolicyNumber(pip.PolicyNumber)   AS MaskedPolicyNumber,
    ip.ProviderName                             AS InsuranceProvider,
    pip.CoveragePercent,
    pip.ExpiryDate                              AS PolicyExpiryDate,
    pip.IsPrimary,

    -- User account context
    u.UserID,
    dbo.fn_MaskName(u.Username)                 AS MaskedUsername,
    r.RoleName,
    u.IsActive                                  AS AccountIsActive,
    u.LastLogin                                 AS LastLoginDate,
    p.DateCreated                               AS PatientRecordCreated
FROM      dbo.Patients               p
INNER JOIN dbo.Addresses             addr ON addr.AddressID         = p.AddressID
LEFT  JOIN dbo.PatientInsurancePolicies pip ON pip.PatientID        = p.PatientID
                                           AND pip.IsPrimary        = 1
LEFT  JOIN dbo.InsuranceProviders    ip   ON ip.InsuranceProviderID = pip.InsuranceProviderID
LEFT  JOIN dbo.Users                 u    ON u.UserID               = p.PatientID
LEFT  JOIN dbo.Roles                 r    ON r.RoleID               = u.RoleID;
GO


-- =============================================================================
-- QUICK VALIDATION QUERIES
-- =============================================================================
-- Verify masking functions produce correct output for each pattern.

-- Email masking
SELECT
    'john.doe@example.com'                                  AS Input,
    dbo.fn_MaskEmail('john.doe@example.com')                AS Masked,
    'j***@example.com'                                      AS Expected;

-- Phone masking
SELECT
    '0712345678'                                            AS Input,
    dbo.fn_MaskPhone('0712345678')                          AS Masked,
    '07******78'                                            AS Expected;

-- DOB masking
SELECT
    '1990-07-15'                                            AS Input,
    dbo.fn_MaskDOB('1990-07-15')                            AS Masked,
    '1990-**-**'                                            AS Expected;

-- Name masking
SELECT
    'Margaret'                                              AS Input,
    dbo.fn_MaskName('Margaret')                             AS Masked,
    'M******t'                                              AS Expected;

-- Policy number masking
SELECT
    'POL-20483921'                                          AS Input,
    dbo.fn_MaskPolicyNumber('POL-20483921')                 AS Masked,
    'PO**********21'                                        AS Expected;

-- License number masking
SELECT
    'LIC-0049302'                                           AS Input,
    dbo.fn_MaskLicenseNumber('LIC-0049302')                 AS Masked,
    'LIC******02'                                           AS Expected;
GO

-- =============================================================================
-- USAGE EXAMPLES
-- =============================================================================

-- 1. Non-privileged access (default — masked values returned):
SELECT TOP 5 PatientID, FirstName, LastName, DOB, Phone, Email
FROM   dbo.vw_Patients_Masked;

-- 2. Elevate to full access for this session, then query:
EXEC dbo.usp_Security_AuthorizeFullDataAccess @CallerRole = 'Doctor';

SELECT TOP 5 PatientID, FirstName, LastName, DOB, Phone, Email
FROM   dbo.vw_Patients_Masked;   -- now returns full unmasked data

-- 3. Single-patient lookup with explicit access level:
EXEC dbo.usp_Security_GetPatientRecord @PatientID = 1, @AccessLevel = 'Masked';
EXEC dbo.usp_Security_GetPatientRecord @PatientID = 1, @AccessLevel = 'Full';

-- 4. Masked emergency contacts:
SELECT TOP 5 * FROM dbo.vw_EmergencyContacts_Masked;

-- 5. Masked doctors directory:
SELECT TOP 5 * FROM dbo.vw_Doctors_Masked;

-- 6. Standardised masked patient directory (upgraded from file 08):
SELECT TOP 5 * FROM dbo.vw_MaskedPatientDirectory;
GO
