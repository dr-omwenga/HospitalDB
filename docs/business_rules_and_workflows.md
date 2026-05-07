# HospitalDB — Business Rules and Automated Workflows

**Project:** HospitalDB  
**Date:** 2026-05-07  
**Purpose:** This document explains every business rule and operational workflow that the database application is designed to enforce or automate. It is intended for business analysts, developers, new team members, and auditors who need to understand *why* the schema and stored procedures are structured the way they are.

---

## How to Read This Document

Each rule is written in plain language and follows this pattern:

- **What the rule says** — the constraint or policy in one sentence.
- **How it is enforced** — the table column, constraint, view, or stored procedure that implements it.
- **Why it exists** — the business or clinical reason behind the rule.

Rules are grouped by the nine functional domains of the system.

---

## 1. Patient Registration

### Rule 1.1 — Every patient must have a physical address on record

Every patient record requires a valid address before it can be saved. The `Patients.AddressID` column is mandatory and links to the `Addresses` table.

**Why:** Billing correspondence, debt collection, and geographic service-demand analysis all depend on a complete address. No patient can be registered without one.

---

### Rule 1.2 — A patient may hold multiple insurance policies, but only one can be flagged as primary

The `PatientInsurancePolicies` table allows a patient to be enrolled in more than one insurance plan. The `IsPrimary` column marks exactly one policy as the primary plan.

**Why:** All billing and prescription-coverage checks look up `IsPrimary = 1` first. Without a clear primary policy, the system cannot determine which insurer to bill first, which would break the claims workflow.

---

### Rule 1.3 — Every patient must have at least one emergency contact

Emergency contacts are stored in the `EmergencyContacts` table with a mandatory link back to the patient.

**Why:** Triage staff need a contact to notify or obtain consent from when a patient is incapacitated. This is also a regulatory requirement in most healthcare jurisdictions.

---

### Rule 1.4 — Patient PII is stored in full but displayed masked by default

Names, dates of birth, email addresses, and phone numbers are always stored unmasked in the database. However, all application-facing queries go through masked views (`vw_Patients_Masked`, `vw_Doctors_Masked`, `vw_EmergencyContacts_Masked`) that hide sensitive values unless the user's session has been explicitly elevated.

| Field | Masked Display | Example |
|---|---|---|
| Name | First + last character only | `Margaret` → `M******t` |
| Date of birth | Year retained, month/day hidden | `1990-07-15` → `1990-**-**` |
| Email | First character + domain only | `john.doe@example.com` → `j***@example.com` |
| Phone | First 2 + last 2 digits only | `0712345678` → `07******78` |
| Policy number | First 2 + last 2 characters | `POL-20483921` → `PO**********21` |
| Licence number | First 3 + last 2 characters | `LIC-0049302` → `LIC******02` |

**Why:** Healthcare data is protected by HIPAA, GDPR, and local health-records legislation. Masking by default means analysts, QA testers, and external auditors can work with realistic data shapes without ever seeing real patient details.

---

## 2. User Accounts and Role-Based Access

### Rule 2.1 — Every system user must be assigned exactly one role

The `Users.RoleID` column is mandatory and links to the `Roles` table. The eight defined roles are: **Administrator**, **Doctor**, **Nurse**, **Receptionist**, **BillingManager**, **Pharmacist**, **LabTechnician**, and **Patient**.

**Why:** Role assignment is the foundation of the access-control model. Reports, masked views, and authorisation procedures all check the role to determine what data the user is permitted to see.

---

### Rule 2.2 — Usernames must be unique across the entire system

A `UNIQUE` constraint on `Users.Username` prevents two accounts from sharing the same login name.

**Why:** Duplicate usernames would make audit log attribution ambiguous — it would be impossible to know which person performed a recorded action.

---

### Rule 2.3 — Passwords are never stored in plain text

The `Users.PasswordHash VARBINARY(256)` column stores only the hashed credential. The plain-text password is never persisted.

**Why:** If the database is compromised, hashed passwords cannot be directly used to log in. This is a baseline security requirement under OWASP and all major compliance frameworks.

---

### Rule 2.4 — Accounts can be deactivated without deletion

The `Users.IsActive BIT` column allows an account to be disabled (set to `0`) when a staff member leaves, rather than deleting the record.

**Why:** Deleting a user record would orphan all audit log entries attributed to that user, destroying the compliance trail. Deactivation preserves history while preventing further logins.

---

### Rule 2.5 — Full data access requires explicit session elevation, and that elevation cannot be revoked within the same connection

Calling `usp_Security_AuthorizeFullDataAccess` with an approved role writes a `'Full'` flag into the session context with a read-only lock. It cannot be changed or cleared by any subsequent code in the same connection. A new database connection always starts with masked access.

**Approved roles for elevation:** Administrator, Doctor, Nurse, BillingManager.

**Why:** The read-only lock prevents a malicious or misconfigured piece of code from elevating a low-privilege session by calling the procedure itself. Each connection must be intentionally and explicitly elevated.

---

### Rule 2.6 — Dormant accounts are automatically risk-tiered for periodic access reviews

The inactive account report (`vw_InactiveAccounts`) classifies every user account into a risk tier based on inactivity:

| Tier | Condition |
|---|---|
| **Critical** | Account is active AND has never logged in |
| **High Risk** | Active account, no login in over 90 days |
| **Medium Risk** | Active account, inactive 31–90 days |
| **Low Risk** | Active account, inactive 0–30 days |
| **Disabled** | `IsActive = 0` (already deactivated — informational) |

**Why:** Dormant accounts are one of the most common attack vectors. An attacker who gains credentials for an unmonitored account can operate undetected for extended periods. Most compliance frameworks (HIPAA, ISO 27001, SOC 2) require quarterly access reviews.

---

## 3. Appointment Scheduling

### Rule 3.1 — Every appointment must record the patient, the doctor, and the user who created it

All three foreign keys on `Appointments` are mandatory. No appointment can be saved without identifying the patient being seen, the doctor delivering the care, and the staff member who made the booking.

**Why:** The booking user is required for audit and accountability. If an appointment is later disputed or a complaint is raised, the system can identify exactly who created the record.

---

### Rule 3.2 — An appointment follows a defined status lifecycle

`Appointments.Status` can only hold one of four values: `Scheduled`, `Completed`, `No-Show`, or `Cancelled`. Other parts of the system depend on these specific values:

- Clinical records can only be created for `Completed` appointments.
- The scheduling reports filter on `Scheduled` for upcoming work.
- The missed-appointment analysis targets `No-Show` and `Cancelled`.

**Why:** A well-defined lifecycle prevents ambiguous data (e.g. an appointment that is both "done" and "pending") and ensures downstream reports receive clean, consistent inputs.

---

### Rule 3.3 — Appointment reminders are prioritised by proximity

The upcoming appointments procedure derives a `ReminderPriority` label for every scheduled appointment:

| Label | Condition |
|---|---|
| **Today** | Appointment is today |
| **Tomorrow** | 1 day away |
| **This Week** | 2–7 days away |
| **Upcoming** | More than 7 days away |

**Why:** Same-day appointments require immediate phone outreach. Sending those via bulk SMS would be too slow. The label allows the scheduling team to route each slot to the correct communication channel automatically.

---

### Rule 3.4 — Double-booking must be detectable on demand

The duplicate record scan (`usp_Security_DuplicateRecordScan`) identifies any combination of the same patient, same doctor, and same calendar day that appears more than once in the appointments table. It returns every overlapping record alongside its current status.

**Why:** The database schema does not prevent double-bookings at the constraint level (different appointment reasons may legitimately exist). The report provides a periodic sweep so the scheduling team can investigate and resolve conflicts.

---

### Rule 3.5 — A patient's history of missed appointments is tracked and counted

The missed appointment view uses a correlated subquery to count every prior `No-Show` or `Cancelled` appointment for each patient (`PreviousMissedCount`). This count appears alongside the patient's contact details in every missed-appointment report.

**Why:** A patient missing their first appointment likely has an administrative issue (wrong date, transport problem). A patient who has missed five appointments has a pattern that warrants a different clinical or social intervention. The system surfaces this distinction automatically.

---

## 4. Clinical Records and Prescriptions

### Rule 4.1 — A medical record can only exist for a completed appointment

A unique constraint (`UQ_MedicalRecords_AppointmentID`) enforces a strict one-to-one relationship: each appointment can have at most one medical record. The foreign key ensures the appointment must exist before the record can be created.

**Why:** Recording a diagnosis against a cancelled or no-show appointment would be clinically meaningless and could corrupt a patient's care history. The constraint makes this structurally impossible.

---

### Rule 4.2 — Every medical record must capture a diagnosis, clinical notes, and a treatment plan

All three fields — `Diagnosis`, `Notes`, and `TreatmentPlan` — are mandatory (`NOT NULL`). A record cannot be saved with any of them empty.

**Why:** An incomplete clinical record is both a patient safety risk (the next clinician has insufficient information) and a medicolegal liability. Enforcing completeness at the database level removes the possibility of partial saves slipping through the application layer.

---

### Rule 4.3 — Prescriptions are always linked to a specific medical record, not directly to a patient

`Prescriptions.RecordID` means a prescription can only be issued after a documented consultation has taken place. The prescribing doctor is also captured on the same record.

**Why:** This enforces the clinical principle that medication should only be prescribed following a formal assessment. It creates a clear chain of accountability: patient → appointment → medical record → prescription.

---

### Rule 4.4 — A prescription can contain multiple medications

`PrescriptionItems` stores one row per drug, each with its own `MedicationName`, `Dosage`, `Frequency`, and `Duration`. Multiple items link to the same `PrescriptionID`.

**Why:** Many patients require more than one medication from a single consultation. Storing each drug as a separate line item allows the pharmacy to dispense items individually, check for interactions, and record separate administration instructions.

---

### Rule 4.5 — Active prescriptions are monitored for insurance coverage status

The active prescription report joins each prescription back to the patient's insurance policy and derives an `InsuranceStatus` label:

| Label | Condition |
|---|---|
| **Active** | Policy exists and has not expired |
| **Expiring Soon** | Policy expires within the next 30 days |
| **Expired** | Policy exists but expiry date has passed |
| **No Insurance** | No policy on file |

**Why:** Pharmacy staff need to know before dispensing whether the medication will be covered. Sending a patient to the counter with an expired policy wastes time and may result in the patient being unable to afford the medication.

---

## 5. Laboratory Orders

### Rule 5.1 — Lab tests must be ordered against a clinical appointment, not directly against a patient

`LabOrders.AppointmentID` is mandatory. Every test request must be tied to a specific encounter, creating the chain: patient → appointment → lab order → result.

**Why:** A free-floating lab order with no appointment context cannot be attributed to a clinical decision or a responsible clinician. It would be impossible to reconcile results with a diagnosis or include the test cost in the correct bill.

---

### Rule 5.2 — Test types and their standard prices are managed from a central catalogue

`LabTestCatalog` defines all available tests. A unique constraint on `TestName` prevents the same test from being entered twice under different names or spellings.

**Why:** Without a catalogue, test names and prices would be entered free-text per order, making reporting, pricing consistency, and billing reconciliation impossible.

---

### Rule 5.3 — Lab orders are automatically classified by SLA compliance

The lab backlog report derives an urgency tier for every pending or in-progress order based on how many days have elapsed since the request:

| Tier | Days Elapsed |
|---|---|
| **Within SLA** | 0–2 days |
| **Attention (3–6 days)** | 3–6 days |
| **Overdue (7+ days)** | 7 or more days |

**Why:** Lab coordinators review dozens of open orders at a time. Without automatic tiering, they would need to manually calculate elapsed time for each row. The tiers let them sort by urgency and escalate overdue orders immediately.

---

## 6. Billing and Financial Management

### Rule 6.1 — Every bill must be linked to a patient and a specific appointment

Both `Bills.PatientID` and `Bills.AppointmentID` are mandatory. A bill cannot exist without an associated clinical encounter.

**Why:** This preserves the financial audit trail. Every charge can be traced back to the appointment that generated it, supporting dispute resolution, insurance claims, and revenue reconciliation.

---

### Rule 6.2 — A bill tracks gross amount, amount paid, and outstanding balance as separate values

`TotalAmount`, `PaidAmount`, and `Balance` are stored independently. When a partial payment is made, `PaidAmount` increases and `Balance` decreases, but `TotalAmount` remains unchanged.

**Why:** Preserving the original billed amount is essential for collection-rate calculations, insurance claim validation (where the insurer pays a percentage of the original charge), and financial reporting that distinguishes gross revenue from collected revenue.

---

### Rule 6.3 — Bill status reflects the current collection state

`BillStatus` must be one of: `Unpaid`, `Partially Paid`, or `Paid`. The AR aging and revenue reports use this status to filter their result sets — only open balances appear in collection queues; paid bills are excluded automatically.

**Why:** Without a clear status field, every billing query would need to re-derive the collection state from the balance column, introducing inconsistencies if rounding or edge cases produce near-zero balances.

---

### Rule 6.4 — Every charge on a bill must reference a catalogue service

`BillItems.ServiceID` is a mandatory foreign key to `ServiceCatalog`. Charges cannot be entered as free text.

**Why:** A catalogue-backed billing system enables standardised fee schedules, consistent reporting across departments, and accurate insurance tariff matching. It also prevents arbitrary or fraudulent charges from being entered without a corresponding service definition.

---

### Rule 6.5 — Every payment is recorded as an individual transaction with a method and reference number

`Payments` stores one row per transaction with `PaymentMethod` and `ReferenceNumber`. Multiple partial payments against the same bill each get their own row.

**Why:** Individual transaction records support bank reconciliation (matching each payment to a bank statement entry), dispute resolution (producing a complete payment history for a patient), and the payment-method analysis report which compares volumes by method.

---

### Rule 6.6 — Outstanding bills are automatically placed into aging buckets

The unpaid bills view calculates how many days each bill has been outstanding and assigns it to a collection-priority bucket:

| Bucket | Days Outstanding | Recommended Action |
|---|---|---|
| **0–30 Days** | 0–30 | Automated reminder |
| **31–60 Days** | 31–60 | Escalated follow-up call |
| **61–90 Days** | 61–90 | Payment plan offer |
| **90+ Days** | Over 90 | Collections escalation |

**Why:** Industry-standard AR management is driven by aging. The longer a balance remains unpaid, the less likely it is to be collected. Automatic bucket assignment means the billing team can generate a targeted collection list at any time without manual sorting.

---

### Rule 6.7 — Revenue is allocated proportionally across service line items

When calculating how much revenue each service type has actually generated, the system does not simply use billed amounts. It allocates each bill's `PaidAmount` across its line items in proportion to each item's share of the total bill.

**Formula:** `CollectedLineTotal = PaidAmount × (LineTotal ÷ TotalAmount)`

**Why:** A bill may be partially paid. Without proportional allocation, one service type would appear to have collected its full amount while another appears to have collected nothing — even though both contributed to the partial payment.

---

### Rule 6.8 — Insurance and out-of-pocket payments are tracked separately

The monthly revenue analysis procedure uses conditional aggregation to split total payments into insurance reimbursements and direct patient payments, reporting both figures alongside an `InsuranceContributionPct`.

**Why:** The Finance team negotiates contracts with insurers based on actual reimbursement volumes. Treasury needs to model cashflow separately for predictable insurance receipts (which arrive on fixed claim cycles) and variable patient payments.

---

## 7. Audit and Compliance

### Rule 7.1 — Every data-changing action must be attributed to a named user

`AuditLogs.PerformedByUserID` is mandatory and links to `Users`. Anonymous audit entries are structurally impossible.

**Why:** Compliance frameworks (HIPAA Security Rule, GDPR Article 5, ISO 27001) require that every access to or modification of sensitive data is attributable to an identified individual. Anonymous entries would invalidate the audit trail entirely.

---

### Rule 7.2 — Both the original value and the new value must be captured for every change

`AuditLogs.OldValue` and `AuditLogs.NewValue` are both mandatory `NVARCHAR(MAX)` columns. Every recorded action preserves the before and after state of the affected data.

**Why:** An audit trail that records only that *a change happened* is insufficient for incident investigation. Regulators and forensic analysts need to know exactly what the data said before the change and what it was changed to.

---

### Rule 7.3 — Actions performed outside business hours are automatically flagged

The audit log view marks any action before 07:00 or at/after 20:00 with `IsOutsideBusinessHours = 1`. The audit report can filter exclusively to these events.

**Why:** Legitimate clinical and administrative work rarely occurs in the middle of the night. After-hours database activity — particularly deletions or bulk updates — is a key indicator of insider threat or compromised credentials. Automatic flagging surfaces these events without requiring manual timestamp inspection.

---

### Rule 7.4 — System errors are captured in a structured log

The `ErrorLogs` table records `ProcedureName`, `ErrorMessage`, and `ErrorDate` for every handled exception. Stored procedures are expected to write to this table inside their error-handling blocks.

**Why:** Unhandled errors that surface only in application logs are difficult to correlate with specific database operations. A structured error table allows the DBA and development team to search, filter, and analyse failures by procedure name, date range, or error type without parsing unstructured log files.

---

## 8. Data Quality and Integrity

### Rule 8.1 — Duplicate patient registrations are detectable on demand

The duplicate record scan checks for patients sharing the same `FirstName + LastName + DOB` combination and separately for patients sharing the same `Email` address. Any group with more than one match is returned for review.

**Why:** Duplicate patient records are a patient safety risk (incomplete medical history) and a billing integrity risk (charges may be split across two accounts for the same person). Periodic scans catch duplicates created through multiple registration channels (walk-in, online portal, phone booking).

---

### Rule 8.2 — Doctor licence numbers must be unique

A `UNIQUE` constraint on `Doctors.LicenseNumber` prevents two doctor records from sharing a licence number.

**Why:** Medical licences are issued to individuals and cannot be shared. A duplicate licence number would indicate either a data entry error (the same doctor registered twice) or a fraudulent account created under a stolen licence.

---

### Rule 8.3 — Lab test names must be unique in the catalogue

A `UNIQUE` constraint on `LabTestCatalog.TestName` prevents the same test from being added twice under different casing or spelling variants.

**Why:** Duplicate catalogue entries would allow the same test to be ordered under two different IDs, fragmenting reporting (the same test would appear as two separate line items in revenue and backlog reports) and potentially causing pricing inconsistencies.

---

### Rule 8.4 — Role names must be unique

A `UNIQUE` constraint on `Roles.RoleName` prevents duplicate role definitions.

**Why:** If two roles existed with the same name, access-control logic that filters by role name (such as the authorisation procedure for full data access) would apply permissions inconsistently, potentially granting elevated access to accounts that should not have it.

---

## 9. Automated Operational Workflows — Summary

The following table maps each recurring operational task to the database object that automates it and the team responsible for running it.

| Operational Task | Automated By | Responsible Team | Frequency |
|---|---|---|---|
| Morning appointment briefing | `usp_Schedule_UpcomingAppointments` | Scheduling Desk | Daily |
| Patient reminder prioritisation (Today / Tomorrow / This Week) | `ReminderPriority` label in upcoming appointments SP | Patient Services | Daily |
| AR collection queue by aging bucket | `usp_Billing_UnpaidBills` | Billing Department | Daily / Weekly |
| Monthly management accounts (billed vs. collected) | `usp_Billing_MonthlyRevenueTrend` | Finance | Month-end |
| Revenue by department and service line | `usp_Billing_RevenueSummary` | Finance / Dept Heads | Monthly |
| Insurance vs. out-of-pocket split | `usp_Report_MonthlyRevenueAnalysis` | Finance | Monthly |
| Top paying patients / lifetime value | `usp_Billing_TopPayingPatients` | Finance / Management | Quarterly |
| Lab backlog escalation (SLA tiers) | `usp_Report_LabOrderBacklog` | Lab Coordinator | Daily |
| Patient re-engagement outreach list | `usp_Schedule_MissedAppointments` | Patient Services | Weekly |
| Active prescription insurance check | `usp_Report_ActivePrescriptions` | Pharmacy | On-demand |
| Doctor daily / weekly timetable | `usp_Schedule_DoctorSchedule` | Scheduling Desk | Daily |
| Busiest days and peak-hour analysis | `usp_Schedule_BusiestDaysAndTimes` | Operations | Monthly |
| Quarterly user access review | `usp_Security_InactiveAccountReport` | IT / Security | Quarterly |
| Compliance audit handoff | `usp_Security_AuditLogReport` | Compliance / IT | On-demand |
| After-hours activity review | `usp_Security_AuditLogReport` with `@OutsideBusinessHoursOnly = 1` | Security | Weekly |
| Daily system anomaly detection | `usp_Security_SystemActivitySummary` (7-day rolling average + `IsAnomaly` flag) | IT Operations | Daily |
| Duplicate patient scan | `usp_Security_DuplicateRecordScan` | Data Quality Team | Monthly |
| Non-privileged data access (masked view) | `vw_Patients_Masked`, `vw_Doctors_Masked`, `vw_EmergencyContacts_Masked` | All reporting roles | Continuous |
| Full data access elevation | `usp_Security_AuthorizeFullDataAccess` | Clinical / Admin roles | Per session |

---

*This document is generated from the HospitalDB schema and stored procedure definitions. If the schema or procedures are updated, this document should be reviewed and updated accordingly.*
