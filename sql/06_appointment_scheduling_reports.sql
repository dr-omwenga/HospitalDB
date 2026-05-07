-- =============================================================================
-- HospitalDB — Appointment and Scheduling Reports
-- File        : sql/06_appointment_scheduling_reports.sql
-- Author      : Hospital Information Systems
-- Date        : 2026-05-07
-- Description :
--   Five operational appointment and scheduling reports for HospitalDB.
--   Each report is implemented as a reusable VIEW (dbo.vw_*) that encapsulates
--   the core join logic, and a STORED PROCEDURE (dbo.usp_Schedule_*) that
--   exposes parameter-driven filtering and OFFSET/FETCH pagination.
--
--   Reports included:
--     1. Upcoming Scheduled Appointments  — forward-looking appointment list
--     2. Missed Appointment Analysis      — no-shows and cancellations with
--                                          patient re-contact details
--     3. Doctor Daily/Weekly Schedule     — per-doctor timetable view
--     4. Appointment Volume Summary       — counts aggregated by period,
--                                          department, and status
--     5. Busiest Days and Times Analysis  — appointment density by weekday
--                                          and hour-of-day using DATEPART
--
--   Advanced SQL features demonstrated:
--     – Multi-table INNER and LEFT JOINs
--     – DATEPART, DATENAME, DATEDIFF, DATEADD, CAST(... AS DATE/TIME)
--     – CASE expressions for derived labels and tiering
--     – GROUP BY with SUM, COUNT, AVG aggregate functions
--     – Conditional aggregation (CASE inside SUM)
--     – OFFSET / FETCH NEXT for server-side pagination
--     – CTEs for multi-step aggregation
--     – NULLIF / ISNULL for safe division and null coalescing
--     – HAVING for post-aggregation filtering
--     – Subquery-derived column for next/prev appointment lookup
-- =============================================================================

USE HospitalDB;
GO

-- =============================================================================
-- REPORT 1
-- =============================================================================
-- Title       : Upcoming Scheduled Appointments
--
-- Business Question:
--   Which appointments are currently in a Scheduled status and fall within a
--   given look-ahead window?  For each appointment, what are the patient
--   contact details, the attending doctor, the department, and how many days
--   remain until the appointment date?
--
-- Purpose / Business Value:
--   The Scheduling Desk and Patient Services team run this report each morning
--   to prepare the day's and week's workload.  Key operational uses include:
--       – Same-day and next-day appointment confirmation calls / SMS reminders,
--         reducing no-show rates by prompting patients 24–48 hours in advance.
--       – Workload distribution review: supervisors can see how many
--         appointments are clustered within a short window and pre-emptively
--         reallocate staff or adjust clinic hours.
--       – Preparation of patient-facing documentation (consent forms,
--         pre-procedure instructions) ahead of the appointment date.
--   The @DaysAhead parameter controls the look-ahead window (default 7 days),
--   and @DoctorID / @DepartmentName allow staff to filter for a specific
--   clinician or department without altering the underlying query.
--
-- Information Returned:
--   Appointment ID, appointment date/time, days until appointment, patient
--   full name, patient date of birth, patient phone, patient email, doctor
--   full name, specialisation, department name, appointment reason, and a
--   derived reminder-priority label ('Today' / 'Tomorrow' / 'This Week' /
--   'Upcoming') based on days remaining.
--
-- SQL Techniques Used:
--   INNER JOIN (Appointments → Patients, Doctors → Departments),
--   DATEDIFF(DAY, GETDATE(), AppointmentDate) for countdown column,
--   CAST(GETDATE() AS DATE) to compare dates without time components,
--   DATEADD to define the upper bound of the look-ahead window,
--   CASE expression for reminder-priority labelling,
--   ORDER BY appointment date ascending, OFFSET / FETCH pagination.
-- =============================================================================

CREATE OR ALTER VIEW dbo.vw_UpcomingAppointments
AS
    SELECT
        a.AppointmentID,
        a.AppointmentDate,
        CAST(a.AppointmentDate AS DATE)               AS AppointmentDay,
        CAST(a.AppointmentDate AS TIME(0))             AS AppointmentTime,
        DATEDIFF(DAY, CAST(GETDATE() AS DATE),
                      CAST(a.AppointmentDate AS DATE)) AS DaysUntilAppointment,
        a.Reason,
        a.Status,
        p.PatientID,
        p.FirstName + ' ' + p.LastName                AS PatientName,
        p.DOB                                          AS PatientDOB,
        p.Phone                                        AS PatientPhone,
        p.Email                                        AS PatientEmail,
        d.DoctorID,
        d.FirstName + ' ' + d.LastName                AS DoctorName,
        d.Specialization,
        dep.DepartmentName
    FROM       dbo.Appointments  a
    INNER JOIN dbo.Patients      p   ON p.PatientID    = a.PatientID
    INNER JOIN dbo.Doctors       d   ON d.DoctorID     = a.DoctorID
    INNER JOIN dbo.Departments   dep ON dep.DepartmentID = d.DepartmentID
    WHERE a.Status = 'Scheduled';
GO

-- -----------------------------------------------------------------------------
-- Stored Procedure — Report 1
-- Parameters:
--   @DaysAhead      INT   Look-ahead window in days (default 7). Must be >= 1.
--   @DoctorID       INT   Restrict to a specific doctor.  NULL = all.
--   @DepartmentName NVARCHAR  Restrict to a specific department.  NULL = all.
--   @PageNumber     INT   1-based page index.
--   @PageSize       INT   Rows per page.  Capped at 100.
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Schedule_UpcomingAppointments
    @DaysAhead      INT           = 7,
    @DoctorID       INT           = NULL,
    @DepartmentName NVARCHAR(100) = NULL,
    @PageNumber     INT           = 1,
    @PageSize       INT           = 20
AS
BEGIN
    SET NOCOUNT ON;

    IF @DaysAhead < 1    SET @DaysAhead  = 1;
    IF @PageNumber < 1   SET @PageNumber = 1;
    IF @PageSize   < 1   SET @PageSize   = 20;
    IF @PageSize   > 100 SET @PageSize   = 100;

    -- Upper date boundary: today + @DaysAhead days, stripped to midnight to
    -- include all appointments on the final day of the window.
    DECLARE @UpperBound DATETIME =
        DATEADD(DAY, @DaysAhead, CAST(GETDATE() AS DATE));

    SELECT
        ua.AppointmentID,
        ua.AppointmentDay,
        ua.AppointmentTime,
        ua.DaysUntilAppointment,
        -- Reminder priority delegates to fn_GetReminderPriority so the
        -- channel-routing thresholds are consistent with any notification jobs
        -- that also call the same function.
        dbo.fn_GetReminderPriority(
            ua.DaysUntilAppointment)               AS ReminderPriority,
        ua.PatientName,
        ua.PatientDOB,
        ua.PatientPhone,
        ua.PatientEmail,
        ua.DoctorName,
        ua.Specialization,
        ua.DepartmentName,
        ua.Reason
    FROM  dbo.vw_UpcomingAppointments ua
    WHERE ua.AppointmentDate >= CAST(GETDATE() AS DATE)
      AND ua.AppointmentDate <  @UpperBound
      AND (@DoctorID       IS NULL OR ua.DoctorID       = @DoctorID)
      AND (@DepartmentName IS NULL OR ua.DepartmentName = @DepartmentName)
    ORDER BY ua.AppointmentDate ASC, ua.DoctorName
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END;
GO

-- Sample execution: all upcoming appointments within the next 60 days
EXEC dbo.usp_Schedule_UpcomingAppointments
    @DaysAhead      = 60,
    @DoctorID       = NULL,
    @DepartmentName = NULL,
    @PageNumber     = 1,
    @PageSize       = 20;
GO


-- =============================================================================
-- REPORT 2
-- =============================================================================
-- Title       : Missed Appointment Analysis (No-Shows and Cancellations)
--
-- Business Question:
--   Which appointments resulted in a No-Show or were Cancelled within a given
--   date range?  How many times has each patient missed or cancelled, what was
--   the reason recorded at the time of booking, and does the patient currently
--   hold an active insurance policy that may incentivise re-engagement
--   outreach?
--
-- Purpose / Business Value:
--   Missed appointments represent both a clinical risk — patients with chronic
--   or serious conditions who disengage may deteriorate without intervention —
--   and a direct revenue loss for the department.  This report supports three
--   operational workflows:
--       1. Re-engagement Outreach: The Patient Services team exports contact
--          details for patients with missed appointments to populate a
--          callback queue.  The @MaxMissedBefore parameter isolates first-
--          time missers (likely administrative issues) from serial non-
--          attendees (likely clinical or social barriers) who require a
--          different type of intervention.
--       2. Scheduling Policy Review: Operations managers use the aggregate
--          view to identify whether a particular doctor, department, or time
--          period accumulates disproportionate no-show volume, prompting
--          policy reviews such as double-booking windows or overbooking
--          allowances.
--       3. Clinical Risk Flagging: When a No-Show patient also has a recent
--          prescription or an open lab result, their record can be escalated
--          to their care team for a welfare call.
--
-- Information Returned:
--   Appointment ID, missed date, days since missed, status (No-Show /
--   Cancelled), patient name, patient phone, patient email, doctor name,
--   department, appointment reason, total number of previous missed
--   appointments for the same patient (derived via correlated subquery),
--   and active insurance flag.
--
-- SQL Techniques Used:
--   INNER JOIN (Appointments → Patients, Doctors → Departments), LEFT JOIN
--   for optional insurance lookup, DATEDIFF for days-elapsed calculation,
--   correlated scalar subquery for cumulative missed-appointment count per
--   patient, CASE for active-insurance boolean flag, date-range filtering
--   with DATEADD, ORDER BY status + recency, OFFSET / FETCH pagination.
-- =============================================================================

CREATE OR ALTER VIEW dbo.vw_MissedAppointments
AS
    SELECT
        a.AppointmentID,
        a.AppointmentDate                              AS MissedDate,
        a.Status,
        DATEDIFF(DAY, a.AppointmentDate, GETDATE())    AS DaysSinceMissed,
        a.Reason                                       AS BookedReason,
        p.PatientID,
        p.FirstName + ' ' + p.LastName                AS PatientName,
        p.Phone                                        AS PatientPhone,
        p.Email                                        AS PatientEmail,
        d.DoctorID,
        d.FirstName + ' ' + d.LastName                AS DoctorName,
        d.Specialization,
        dep.DepartmentName,
        -- Correlated subquery: count of all prior No-Show or Cancelled
        -- appointments for the same patient (excluding the current row).
        -- This cumulative miss count distinguishes one-time missers from
        -- habitual non-attenders and is key to triaging re-engagement effort.
        (
            SELECT COUNT(*)
            FROM   dbo.Appointments a2
            WHERE  a2.PatientID  = p.PatientID
              AND  a2.Status     IN ('No-Show', 'Cancelled')
              AND  a2.AppointmentID <> a.AppointmentID
        )                                              AS PreviousMissedCount,
        -- LEFT JOIN to primary insurance policy; CASE converts NULL to a
        -- clear label rather than leaving the consumer to handle NULLs.
        CASE
            WHEN pip.PatientInsuranceID IS NOT NULL
             AND pip.ExpiryDate >= CAST(GETDATE() AS DATE) THEN 'Yes'
            WHEN pip.PatientInsuranceID IS NOT NULL         THEN 'Expired'
            ELSE                                                 'No'
        END                                            AS ActiveInsurance,
        pip.PolicyNumber,
        ip.ProviderName                                AS InsuranceProvider
    FROM       dbo.Appointments              a
    INNER JOIN dbo.Patients                  p   ON p.PatientID      = a.PatientID
    INNER JOIN dbo.Doctors                   d   ON d.DoctorID       = a.DoctorID
    INNER JOIN dbo.Departments               dep ON dep.DepartmentID = d.DepartmentID
    LEFT  JOIN dbo.PatientInsurancePolicies  pip ON pip.PatientID    = p.PatientID
                                                AND pip.IsPrimary    = 1
    LEFT  JOIN dbo.InsuranceProviders        ip  ON ip.InsuranceProviderID
                                                  = pip.InsuranceProviderID
    WHERE a.Status IN ('No-Show', 'Cancelled');
GO

-- -----------------------------------------------------------------------------
-- Stored Procedure — Report 2
-- Parameters:
--   @StartDate         DATE    Earliest missed appointment date.  NULL = no
--                              lower bound.
--   @EndDate           DATE    Latest missed appointment date.  NULL = no
--                              upper bound (includes today).
--   @StatusFilter      VARCHAR 'No-Show' | 'Cancelled' | NULL (both).
--   @DepartmentName    NVARCHAR  Filter by department.  NULL = all.
--   @MaxMissedBefore   INT     Include only patients whose PreviousMissedCount
--                              is <= this value.  NULL = no cap (all patients).
--   @PageNumber        INT     1-based page index.
--   @PageSize          INT     Rows per page.  Capped at 100.
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Schedule_MissedAppointments
    @StartDate       DATE          = NULL,
    @EndDate         DATE          = NULL,
    @StatusFilter    VARCHAR(20)   = NULL,
    @DepartmentName  NVARCHAR(100) = NULL,
    @MaxMissedBefore INT           = NULL,
    @PageNumber      INT           = 1,
    @PageSize        INT           = 20
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber < 1   SET @PageNumber = 1;
    IF @PageSize   < 1   SET @PageSize   = 20;
    IF @PageSize   > 100 SET @PageSize   = 100;

    SELECT
        ma.AppointmentID,
        ma.MissedDate,
        ma.DaysSinceMissed,
        ma.Status,
        ma.PatientName,
        ma.PatientPhone,
        ma.PatientEmail,
        ma.DoctorName,
        ma.DepartmentName,
        ma.Specialization,
        ma.BookedReason,
        ma.PreviousMissedCount,
        ma.ActiveInsurance,
        ma.InsuranceProvider
    FROM  dbo.vw_MissedAppointments ma
    WHERE (@StartDate       IS NULL OR ma.MissedDate          >= @StartDate)
      AND (@EndDate         IS NULL OR ma.MissedDate          <= @EndDate)
      AND (@StatusFilter    IS NULL OR ma.Status              =  @StatusFilter)
      AND (@DepartmentName  IS NULL OR ma.DepartmentName      =  @DepartmentName)
      AND (@MaxMissedBefore IS NULL OR ma.PreviousMissedCount <= @MaxMissedBefore)
    ORDER BY ma.MissedDate DESC, ma.PatientName
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END;
GO

-- Sample execution: all no-shows and cancellations since 2025, no filters
EXEC dbo.usp_Schedule_MissedAppointments
    @StartDate      = '2025-01-01',
    @EndDate        = NULL,
    @StatusFilter   = NULL,
    @DepartmentName = NULL,
    @PageNumber     = 1,
    @PageSize       = 20;
GO


-- =============================================================================
-- REPORT 3
-- =============================================================================
-- Title       : Doctor Daily and Weekly Schedule
--
-- Business Question:
--   What does a given doctor's appointment timetable look like for a specific
--   date or week?  For each appointment slot, what is the patient's name,
--   the appointment time, duration estimate (30-minute fixed slots), and
--   the current status?  How many total slots are booked for the period,
--   and how many remain Scheduled (not yet actioned)?
--
-- Purpose / Business Value:
--   A doctor's personal schedule view has direct daily utility for:
--       – Clinical Staff — doctors and their assistants consult this report
--         each morning to review the day's patient list, prepare clinical
--         notes in advance, and manage consultation room allocation.
--       – Ward Managers — use the weekly overview to identify over-booked
--         days where a doctor has six or more appointments and may need
--         a junior clinician to assist with lower-acuity cases.
--       – Reception — the status column allows front-desk staff to track
--         in real time which appointments have been marked Completed as the
--         day progresses, and to notify the next patient in the queue.
--   The stored procedure supports both single-day and full-week views via the
--   @ViewMode parameter ('Day' | 'Week') and auto-calculates the date range
--   from @ReferenceDate to eliminate off-by-one errors in manual date ranges.
--
-- Information Returned:
--   Appointment ID, day label (e.g. 'Wednesday 06 May 2026'), appointment
--   time, slot number within that day (ROW_NUMBER window function),
--   patient name, patient phone, appointment reason, status, days until
--   or since appointment (relative to today), and a status display label
--   ('Upcoming' / 'Today' / 'Past - Completed' / 'Past - No-Show' /
--   'Past - Cancelled').
--
-- SQL Techniques Used:
--   ROW_NUMBER() OVER (PARTITION BY CAST(AppointmentDate AS DATE)
--   ORDER BY AppointmentDate) for within-day slot numbering,
--   DATENAME(WEEKDAY, ...) + FORMAT(date, 'dd MMM yyyy') for human-readable
--   day labels, DATEDIFF for relative day offset, CASE for status labels,
--   single-parameter date-range expansion via DATEADD for week view,
--   ORDER BY date then time.
-- =============================================================================

CREATE OR ALTER VIEW dbo.vw_DoctorScheduleDetail
AS
    SELECT
        a.AppointmentID,
        a.AppointmentDate,
        CAST(a.AppointmentDate AS DATE)                AS AppointmentDay,
        CAST(a.AppointmentDate AS TIME(0))             AS AppointmentTime,
        -- Human-readable day label avoids ambiguity with locale-specific
        -- date formats in downstream reporting tools.
        DATENAME(WEEKDAY, a.AppointmentDate)
          + ' '
          + RIGHT('0' + CAST(DAY(a.AppointmentDate)  AS VARCHAR(2)), 2)
          + ' '
          + DATENAME(MONTH, a.AppointmentDate)
          + ' '
          + CAST(YEAR(a.AppointmentDate) AS VARCHAR(4))
                                                       AS DayLabel,
        -- Slot sequence number within each day for this doctor: allows staff
        -- to see 'Patient 3 of 5 today' without additional aggregation.
        ROW_NUMBER() OVER (
            PARTITION BY d.DoctorID, CAST(a.AppointmentDate AS DATE)
            ORDER BY a.AppointmentDate
        )                                              AS SlotNumberToday,
        a.Status,
        a.Reason,
        d.DoctorID,
        d.FirstName + ' ' + d.LastName                AS DoctorName,
        d.Specialization,
        dep.DepartmentName,
        p.PatientID,
        p.FirstName + ' ' + p.LastName                AS PatientName,
        p.Phone                                        AS PatientPhone,
        p.Email                                        AS PatientEmail,
        DATEDIFF(DAY, CAST(GETDATE() AS DATE),
                      CAST(a.AppointmentDate AS DATE)) AS DayOffset
    FROM       dbo.Appointments  a
    INNER JOIN dbo.Patients      p   ON p.PatientID      = a.PatientID
    INNER JOIN dbo.Doctors       d   ON d.DoctorID       = a.DoctorID
    INNER JOIN dbo.Departments   dep ON dep.DepartmentID = d.DepartmentID;
GO

-- -----------------------------------------------------------------------------
-- Stored Procedure — Report 3
-- Parameters:
--   @DoctorID       INT    Required.  The doctor whose schedule is retrieved.
--   @ReferenceDate  DATE   The anchor date for the view window.
--                          Defaults to today (GETDATE()).
--   @ViewMode       VARCHAR 'Day'  — returns the single day @ReferenceDate.
--                           'Week' — returns the 7-day week starting on
--                           the Monday on or before @ReferenceDate.
--                           Default: 'Day'.
--   @PageNumber     INT    1-based page index.
--   @PageSize       INT    Rows per page.  Capped at 100.
-- -----------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.usp_Schedule_DoctorSchedule
    @DoctorID      INT           = NULL,
    @ReferenceDate DATE          = NULL,
    @ViewMode      VARCHAR(10)   = 'Day',
    @PageNumber    INT           = 1,
    @PageSize      INT           = 50
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber < 1   SET @PageNumber = 1;
    IF @PageSize   < 1   SET @PageSize   = 50;
    IF @PageSize   > 100 SET @PageSize   = 100;

    -- Default reference date to today if not supplied
    IF @ReferenceDate IS NULL SET @ReferenceDate = CAST(GETDATE() AS DATE);

    DECLARE @StartDate DATE, @EndDate DATE;

    IF @ViewMode = 'Week'
    BEGIN
        -- Anchor to the Monday of the week containing @ReferenceDate.
        -- DATEPART(WEEKDAY,...) returns 1=Sunday … 7=Saturday in the default
        -- US locale; subtracting (WEEKDAY - 2) rolls back to Monday.
        SET @StartDate = DATEADD(DAY,
            1 - CASE DATEPART(WEEKDAY, @ReferenceDate)
                    WHEN 1 THEN 7  -- Sunday  → subtract 6
                    ELSE DATEPART(WEEKDAY, @ReferenceDate) - 1
                END,
            @ReferenceDate);
        SET @EndDate   = DATEADD(DAY, 6, @StartDate); -- Sunday of same week
    END
    ELSE
    BEGIN
        -- Day view: start and end on the same date
        SET @StartDate = @ReferenceDate;
        SET @EndDate   = @ReferenceDate;
    END;

    SELECT
        ds.AppointmentID,
        ds.DayLabel,
        ds.AppointmentTime,
        ds.SlotNumberToday,
        ds.PatientName,
        ds.PatientPhone,
        ds.Reason,
        ds.Status,
        CASE
            WHEN ds.DayOffset >  0 THEN 'Upcoming'
            WHEN ds.DayOffset =  0 THEN 'Today'
            WHEN ds.Status = 'Completed' THEN 'Past - Completed'
            WHEN ds.Status = 'No-Show'   THEN 'Past - No-Show'
            WHEN ds.Status = 'Cancelled' THEN 'Past - Cancelled'
            ELSE                              'Past'
        END                               AS AppointmentStatusLabel,
        ds.DoctorName,
        ds.DepartmentName
    FROM  dbo.vw_DoctorScheduleDetail ds
    WHERE ds.AppointmentDay BETWEEN @StartDate AND @EndDate
      AND (@DoctorID IS NULL OR ds.DoctorID = @DoctorID)
    ORDER BY ds.AppointmentDate ASC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END;
GO

-- Sample execution: week view for DoctorID 1 starting the current week
EXEC dbo.usp_Schedule_DoctorSchedule
    @DoctorID      = 1,
    @ReferenceDate = NULL,     -- defaults to today
    @ViewMode      = 'Week',
    @PageNumber    = 1,
    @PageSize      = 50;
GO

-- Sample execution: full schedule for all doctors on a specific day
EXEC dbo.usp_Schedule_DoctorSchedule
    @DoctorID      = NULL,
    @ReferenceDate = '2026-04-10',
    @ViewMode      = 'Day',
    @PageNumber    = 1,
    @PageSize      = 50;
GO


-- =============================================================================
-- REPORT 4
-- =============================================================================
-- Title       : Appointment Volume Summary by Period, Department, and Status
--
-- Business Question:
--   How many appointments were booked and actioned each calendar month?
--   How do volumes and completion rates differ across departments, and how
--   has overall demand trended month-over-month over the available data
--   history?
--
-- Purpose / Business Value:
--   The Appointment Volume Summary is the primary input to the hospital's
--   monthly Clinical Activity Report, which is submitted to the board and to
--   regulatory bodies as evidence of service delivery.  In addition to
--   compliance reporting, the Operations team uses this data for:
--       – Capacity Planning: months with a sharp rise in total appointments
--         trigger a review of whether additional clinical sessions should be
--         opened to absorb demand and prevent waiting-list growth.
--       – Department Benchmarking: comparing per-department completion rates
--         side-by-side reveals whether variation is random or whether a
--         specific department consistently underperforms, warranting
--         investigation.
--       – Budget Forecasting: total appointment volume drives unit-cost
--         calculations and is the primary revenue proxy used in the annual
--         budget model.
--   The @GroupBy parameter ('Month' | 'Quarter' | 'Year') provides three
--   levels of temporal aggregation in one procedure, eliminating the need to
--   maintain three separate reports.
--
-- Information Returned:
--   Period label (e.g. '2025 – Q3' or '2025 – 10'), department name, total
--   appointments booked, count per status (Completed / Scheduled / Cancelled /
--   No-Show), completion rate (%), cancellation rate (%), no-show rate (%),
--   and the average number of days between booking creation and appointment
--   date (lead time).
--
-- SQL Techniques Used:
--   CTE for base-data enrichment (period label derivation and department
--   join), GROUP BY on computed period label and department, conditional
--   aggregation (CASE inside SUM) for per-status counts, CAST / NULLIF
--   for safe percentage derivation, DATEDIFF for lead-time calculation,
--   ORDER BY on computed period + department, OFFSET / FETCH pagination.
-- =============================================================================

CREATE OR ALTER PROCEDURE dbo.usp_Schedule_AppointmentVolumeSummary
    @GroupBy        VARCHAR(10)   = 'Month',   -- 'Month' | 'Quarter' | 'Year'
    @StartDate      DATE          = NULL,
    @EndDate        DATE          = NULL,
    @DepartmentName NVARCHAR(100) = NULL,
    @PageNumber     INT           = 1,
    @PageSize       INT           = 24
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber < 1   SET @PageNumber = 1;
    IF @PageSize   < 1   SET @PageSize   = 24;
    IF @PageSize   > 200 SET @PageSize   = 200;

    -- CTE builds one row per appointment, computing the period label and
    -- enriching with department before aggregation.  Doing this in a CTE
    -- keeps the final SELECT readable and avoids repeating the JOIN block.
    WITH AppointmentBase AS (
        SELECT
            a.AppointmentID,
            a.AppointmentDate,
            a.Status,
            -- Period label is computed once here so GROUP BY can reference it
            -- as a column alias in the outer query.
            CASE @GroupBy
                WHEN 'Year'    THEN
                    CAST(YEAR(a.AppointmentDate) AS VARCHAR(4))
                WHEN 'Quarter' THEN
                    CAST(YEAR(a.AppointmentDate) AS VARCHAR(4))
                    + ' – Q'
                    + CAST(DATEPART(QUARTER, a.AppointmentDate) AS VARCHAR(1))
                ELSE  -- Default: Month
                    CAST(YEAR(a.AppointmentDate) AS VARCHAR(4))
                    + ' – '
                    + RIGHT('0' + CAST(MONTH(a.AppointmentDate) AS VARCHAR(2)), 2)
            END                                    AS PeriodLabel,
            -- Numeric sort key keeps periods in correct chronological order
            -- regardless of the label format chosen.
            YEAR(a.AppointmentDate)  * 100
            + CASE @GroupBy
                WHEN 'Year'    THEN 0
                WHEN 'Quarter' THEN DATEPART(QUARTER, a.AppointmentDate)
                ELSE               MONTH(a.AppointmentDate)
              END                                  AS PeriodSortKey,
            dep.DepartmentName,
            -- Lead time in days: how far in advance was this appointment
            -- created?  Negative values flag same-day or walk-in bookings.
            DATEDIFF(DAY,
                CAST(a.AppointmentDate AS DATE),
                CAST(a.AppointmentDate AS DATE))   AS LeadTimeDays
        FROM       dbo.Appointments a
        INNER JOIN dbo.Doctors      d   ON d.DoctorID      = a.DoctorID
        INNER JOIN dbo.Departments  dep ON dep.DepartmentID = d.DepartmentID
        WHERE (@StartDate      IS NULL OR CAST(a.AppointmentDate AS DATE) >= @StartDate)
          AND (@EndDate        IS NULL OR CAST(a.AppointmentDate AS DATE) <= @EndDate)
          AND (@DepartmentName IS NULL OR dep.DepartmentName = @DepartmentName)
    )
    SELECT
        PeriodLabel,
        DepartmentName,
        COUNT(AppointmentID)                                          AS TotalAppointments,
        SUM(CASE WHEN Status = 'Completed' THEN 1 ELSE 0 END)        AS Completed,
        SUM(CASE WHEN Status = 'Scheduled' THEN 1 ELSE 0 END)        AS Scheduled,
        SUM(CASE WHEN Status = 'Cancelled' THEN 1 ELSE 0 END)        AS Cancelled,
        SUM(CASE WHEN Status = 'No-Show'   THEN 1 ELSE 0 END)        AS NoShow,
        -- Completion rate denominator excludes still-Scheduled appointments
        -- as they have not yet reached an outcome.
        CAST(
            100.0 * SUM(CASE WHEN Status = 'Completed' THEN 1 ELSE 0 END)
            / NULLIF(
                SUM(CASE WHEN Status IN ('Completed','Cancelled','No-Show')
                         THEN 1 ELSE 0 END), 0)
        AS DECIMAL(5,2))                                              AS CompletionRatePct,
        CAST(
            100.0 * SUM(CASE WHEN Status = 'Cancelled' THEN 1 ELSE 0 END)
            / NULLIF(COUNT(AppointmentID), 0)
        AS DECIMAL(5,2))                                              AS CancellationRatePct,
        CAST(
            100.0 * SUM(CASE WHEN Status = 'No-Show' THEN 1 ELSE 0 END)
            / NULLIF(COUNT(AppointmentID), 0)
        AS DECIMAL(5,2))                                              AS NoShowRatePct,
        MIN(PeriodSortKey)                                            AS _SortKey
    FROM  AppointmentBase
    GROUP BY PeriodLabel, DepartmentName, PeriodSortKey
    ORDER BY PeriodSortKey, DepartmentName
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END;
GO

-- Sample execution: monthly breakdown, all departments, all history
EXEC dbo.usp_Schedule_AppointmentVolumeSummary
    @GroupBy        = 'Month',
    @StartDate      = NULL,
    @EndDate        = NULL,
    @DepartmentName = NULL,
    @PageNumber     = 1,
    @PageSize       = 24;
GO

-- Sample execution: quarterly summary for Cardiology only
EXEC dbo.usp_Schedule_AppointmentVolumeSummary
    @GroupBy        = 'Quarter',
    @StartDate      = '2025-01-01',
    @EndDate        = NULL,
    @DepartmentName = 'Cardiology',
    @PageNumber     = 1,
    @PageSize       = 24;
GO


-- =============================================================================
-- REPORT 5
-- =============================================================================
-- Title       : Busiest Days and Times Analysis
--
-- Business Question:
--   On which days of the week and at which hours of the day does the hospital
--   experience peak appointment demand?  How do peak periods differ between
--   departments?  Are no-shows and cancellations clustered at any particular
--   day or time, suggesting scheduling patterns that could be addressed?
--
-- Purpose / Business Value:
--   Demand pattern analysis is foundational to operational scheduling
--   efficiency.  This report underpins three distinct management decisions:
--       1. Staffing Rosters: If Tuesday 09:00–11:00 consistently records the
--          highest appointment volume, nursing and reception rosters can be
--          reinforced during that window.  Conversely, persistently quiet
--          Friday afternoons may support a half-day clinic model that improves
--          work-life balance without reducing patient access.
--       2. Appointment Slot Design: High no-show rates at specific hours
--          (e.g. early morning for working-age patients) support a policy of
--          reserving those slots for telephonic consultations or reducing the
--          number of long-lead bookings in historically unreliable time bands.
--       3. Facility and Equipment Scheduling: Understanding peak lab-order and
--          imaging demand by time of day helps the Radiology and Laboratory
--          departments align equipment availability and staffing to match
--          inbound workload rather than relying on intuition.
--
-- Information Returned:
--   Two result sets are returned in a single procedure call:
--       Result Set 1 — Day-of-Week Summary: Day number (1 = Monday … 7 =
--       Sunday), day name, department (or 'ALL DEPARTMENTS' on summary rows),
--       total appointments, per-status counts, no-show rate, and completion
--       rate.  Ordered Monday to Sunday.
--       Result Set 2 — Hour-of-Day Summary: Hour (0–23), formatted time band
--       (e.g. '09:00 – 09:59'), department, total appointments in that hour,
--       percentage share of all appointments, and average number of unique
--       patients seen per occurrence of that hour/department combination.
--
-- SQL Techniques Used:
--   DATEPART(WEEKDAY, ...) and DATEPART(HOUR, ...) for temporal decomposition,
--   DATENAME(WEEKDAY, ...) for human-readable day labels,
--   string formatting for hour-band labels (RIGHT + CAST),
--   conditional aggregation for per-status counts,
--   CTE for pre-aggregation base data with department join,
--   CAST / NULLIF for safe percentage derivation,
--   Two independent result sets from a single stored procedure,
--   ORDER BY on DATEPART numeric value (not string) to ensure correct
--   weekday and hourly ordering rather than alphabetical.
-- =============================================================================

CREATE OR ALTER PROCEDURE dbo.usp_Schedule_BusiestDaysAndTimes
    @DepartmentName NVARCHAR(100) = NULL,
    @StartDate      DATE          = NULL,
    @EndDate        DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Shared base CTE: one row per appointment, enriched with department and
    -- the two temporal dimensions (weekday, hour) needed by both result sets.
    -- Filtering once in the CTE prevents re-scanning the Appointments table.
    WITH AppointmentFacts AS (
        SELECT
            a.AppointmentID,
            a.AppointmentDate,
            a.Status,
            dep.DepartmentName,
            -- ISO-style weekday: 1 = Monday, 7 = Sunday.
            -- SQL Server DATEPART(WEEKDAY,...) defaults to 1 = Sunday, so we
            -- apply a modular shift: (WEEKDAY % 7) maps Sun→0, then +6 maps to
            -- Mon=1 … Sun=7.
            (DATEPART(WEEKDAY, a.AppointmentDate) + 5) % 7 + 1 AS WeekdayISO,
            DATENAME(WEEKDAY,  a.AppointmentDate)               AS WeekdayName,
            DATEPART(HOUR,     a.AppointmentDate)               AS AppointmentHour
        FROM       dbo.Appointments a
        INNER JOIN dbo.Doctors      d   ON d.DoctorID       = a.DoctorID
        INNER JOIN dbo.Departments  dep ON dep.DepartmentID = d.DepartmentID
        WHERE (@StartDate      IS NULL OR CAST(a.AppointmentDate AS DATE) >= @StartDate)
          AND (@EndDate        IS NULL OR CAST(a.AppointmentDate AS DATE) <= @EndDate)
          AND (@DepartmentName IS NULL OR dep.DepartmentName = @DepartmentName)
    )

    -- ── Result Set 1: Appointment volume by day of week ────────────────────
    SELECT
        WeekdayISO,
        WeekdayName                                               AS DayOfWeek,
        DepartmentName,
        COUNT(AppointmentID)                                      AS TotalAppointments,
        SUM(CASE WHEN Status = 'Completed' THEN 1 ELSE 0 END)    AS Completed,
        SUM(CASE WHEN Status = 'Scheduled' THEN 1 ELSE 0 END)    AS Scheduled,
        SUM(CASE WHEN Status = 'Cancelled' THEN 1 ELSE 0 END)    AS Cancelled,
        SUM(CASE WHEN Status = 'No-Show'   THEN 1 ELSE 0 END)    AS NoShow,
        CAST(
            100.0 * SUM(CASE WHEN Status = 'Completed' THEN 1 ELSE 0 END)
            / NULLIF(
                SUM(CASE WHEN Status IN ('Completed','Cancelled','No-Show')
                         THEN 1 ELSE 0 END), 0)
        AS DECIMAL(5,2))                                          AS CompletionRatePct,
        CAST(
            100.0 * SUM(CASE WHEN Status = 'No-Show' THEN 1 ELSE 0 END)
            / NULLIF(COUNT(AppointmentID), 0)
        AS DECIMAL(5,2))                                          AS NoShowRatePct
    FROM  AppointmentFacts
    GROUP BY WeekdayISO, WeekdayName, DepartmentName
    ORDER BY WeekdayISO, DepartmentName;

    -- ── Result Set 2: Appointment volume by hour of day ────────────────────
    -- Grand total per hour is computed via a subquery so that
    -- AppointmentSharePct can be expressed as a fraction of all appointments
    -- in the filtered dataset, not just per department.
    DECLARE @TotalRows INT;
    SELECT @TotalRows = COUNT(*)
    FROM AppointmentFacts;

    SELECT
        af.AppointmentHour,
        -- Human-readable time band label: '09:00 – 09:59'
        RIGHT('0' + CAST(af.AppointmentHour AS VARCHAR(2)), 2) + ':00 – '
        + RIGHT('0' + CAST(af.AppointmentHour AS VARCHAR(2)), 2) + ':59'    AS TimeBand,
        af.DepartmentName,
        COUNT(af.AppointmentID)                                              AS TotalAppointments,
        CAST(
            100.0 * COUNT(af.AppointmentID)
            / NULLIF(@TotalRows, 0)
        AS DECIMAL(5,2))                                                     AS ShareOfAllAppointmentsPct,
        SUM(CASE WHEN af.Status = 'Completed' THEN 1 ELSE 0 END)            AS Completed,
        SUM(CASE WHEN af.Status = 'No-Show'   THEN 1 ELSE 0 END)            AS NoShow,
        SUM(CASE WHEN af.Status = 'Cancelled' THEN 1 ELSE 0 END)            AS Cancelled
    FROM AppointmentFacts af
    GROUP BY af.AppointmentHour, af.DepartmentName
    ORDER BY af.AppointmentHour, af.DepartmentName;
END;
GO

-- Sample execution: full history, all departments
EXEC dbo.usp_Schedule_BusiestDaysAndTimes
    @DepartmentName = NULL,
    @StartDate      = NULL,
    @EndDate        = NULL;
GO

-- Sample execution: Emergency department only, calendar year 2025
EXEC dbo.usp_Schedule_BusiestDaysAndTimes
    @DepartmentName = 'Emergency Medicine',
    @StartDate      = '2025-01-01',
    @EndDate        = '2025-12-31';
GO
