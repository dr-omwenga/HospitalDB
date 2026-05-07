# HospitalDB — JSON Report Output

This folder contains structured JSON result sets produced by executing the HospitalDB report views against the live `HospitalDB` database.  Each file is suitable for consumption by downstream APIs, ETL pipelines, or front-end dashboards.

---

## Files

### 1. `report_unpaid_bills.json`
**Root key:** `unpaid_bills`  
**Source view:** `dbo.vw_UnpaidBills`  
**Row count:** 12  
**Domain:** Billing / Accounts Receivable

Accounts-receivable aging report.  Contains every bill with status `Unpaid` or `Partially Paid`, enriched with patient contact details, treating doctor, department, and an aging bucket classification.

| Field | Type | Description |
|---|---|---|
| `BillID` | int | Primary key of the bill |
| `PatientFullName` | string | Patient first + last name |
| `PatientPhone` / `PatientEmail` | string | Contact details |
| `DoctorFullName` / `DepartmentName` | string | Treating doctor and department |
| `AppointmentDate` / `BillCreatedDate` | datetime string | ISO-8601 timestamps |
| `DaysOutstanding` | int | Days since the bill was created |
| `AgingBucket` | string | `0-30 Days` / `31-60 Days` / `61-90 Days` / `90+ Days` |
| `TotalAmount` / `PaidAmount` / `Balance` | number | Monetary amounts |
| `BillStatus` | string | `Unpaid` or `Partially Paid` |
| `LastPaymentDate` | datetime string \| null | Date of most recent payment, if any |
| `PaymentTransactionCount` | int | Number of payment transactions against this bill |

---

### 2. `report_audit_log.json`
**Root key:** `audit_log`  
**Source view:** `dbo.vw_AuditLogDetail`  
**Row count:** 30  
**Domain:** Security / Compliance

Complete audit trail of all recorded database actions.  Each row identifies the user, their role, the table affected, the action type, and flags whether the action occurred outside normal business hours (before 07:00 or after 20:00).

| Field | Type | Description |
|---|---|---|
| `AuditID` | int | Primary key |
| `ActionDate` | datetime string | When the action occurred |
| `ActionDay` | date string | Date portion only |
| `ActionHour` | int | Hour (0–23) for time-of-day analysis |
| `IsOutsideBusinessHours` | bool | `true` if action occurred before 07:00 or after 20:00 |
| `PerformedByUserID` | int | FK to `dbo.Users` |
| `Username` / `RoleName` | string | User identity and role |
| `TableName` / `ActionType` | string | Which table was affected and what type of action |

---

### 3. `report_upcoming_appointments.json`
**Root key:** `upcoming_appointments`  
**Source view:** `dbo.vw_UpcomingAppointments`  
**Row count:** varies (only `Status = 'Scheduled'` rows)  
**Domain:** Scheduling

All currently scheduled (not yet completed or cancelled) appointments, ordered chronologically.  Includes patient and doctor context plus a `ReminderPriority` label for notification systems.

| Field | Type | Description |
|---|---|---|
| `AppointmentID` | int | Primary key |
| `AppointmentDate` / `AppointmentDay` / `AppointmentTime` | string | Full datetime, date, and `HH:mm` time |
| `Status` / `Reason` | string | Always `Scheduled`; free-text reason |
| `PatientID` / `PatientName` / `PatientPhone` / `PatientEmail` | int/string | Patient identity and contact |
| `DoctorID` / `DoctorName` / `Specialization` / `DepartmentName` | int/string | Doctor identity and specialty |
| `DaysUntilAppointment` | int | Positive = future; 0 = today; negative = overdue |
| `ReminderPriority` | string | `Today` / `Tomorrow` / `This Week` / `Upcoming` |

---

### 4. `report_payment_method_analysis.json`
**Root key:** `payment_method_analysis`  
**Source view:** `dbo.vw_PaymentDetail` (aggregated)  
**Row count:** varies (one row per payment method)  
**Domain:** Billing / Finance

Aggregated breakdown of payment activity by payment method.  Provides both volume (transaction count) and value (total amount) with percentage shares for easy pie-chart or KPI-card rendering.

| Field | Type | Description |
|---|---|---|
| `PaymentMethod` | string | Cash / Card / Insurance / etc. |
| `TransactionCount` | int | Number of payment records |
| `TotalAmountCollected` | number | Sum of all payments via this method |
| `AvgTransactionAmount` / `MinTransactionAmount` / `MaxTransactionAmount` | number | Statistical spread |
| `FirstPaymentDate` / `LastPaymentDate` | date string | Activity window |
| `ActivitySpreadDays` | int | Days between first and last payment |
| `ShareOfTotalValuePct` | number | Percentage of total revenue collected via this method |
| `ShareOfTotalVolumePct` | number | Percentage of total transaction count |

---

### 5. `report_user_account_risk.json`
**Root key:** `user_account_risk`  
**Source view:** `dbo.vw_InactiveAccounts`  
**Row count:** 30 (all users)  
**Domain:** Security / Access Management

Risk classification of every user account based on login inactivity.  Feeds access-review workflows, alerting pipelines, or auto-disable rules.

| Field | Type | Description |
|---|---|---|
| `UserID` / `Username` / `RoleName` | int/string | Account identity |
| `IsActive` | bool | Whether the account is enabled |
| `LastLogin` | datetime string \| null | Most recent login timestamp |
| `DaysSinceLastLogin` | int \| null | Null if the user has never logged in |
| `InactivityRiskTier` | string | `Critical` / `High Risk` / `Medium Risk` / `Low Risk` / `Disabled` |
| `TotalAuditEvents` | int | All-time audit log entries for this user |
| `AuditEventsLast30Days` | int | Recent activity count |
| `EarliestAuditActivity` / `MostRecentAuditActivity` | date string \| null | Audit activity window |

---

## Envelope Schema

Every JSON file follows the same envelope pattern:

```json
{
  "<root_key>": {
    "metadata": {
      "report":       "<file_stem>",
      "description":  "<human-readable description>",
      "source_view":  "<dbo.view_name>",
      "database":     "HospitalDB",
      "server":       "localhost",
      "generated_at": "<ISO-8601 timestamp>",
      "row_count":    <integer>
    },
    "data": [ { ...record... }, ... ]
  }
}
```

---

## Regenerating Output

To refresh these files, reconnect to `HospitalDB` via the `hospitaldb-local` profile and re-run the source views with the same SELECT projections.  The views are defined in:

- `sql/07_billing_financial_reports.sql` → `vw_UnpaidBills`, `vw_PaymentDetail`
- `sql/06_appointment_scheduling_reports.sql` → `vw_UpcomingAppointments`
- `sql/08_security_admin_reports.sql` → `vw_AuditLogDetail`, `vw_InactiveAccounts`
