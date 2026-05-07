# HospitalDB — Performance Index Guide

**File:** `sql/10_performance_indexes.sql`  
**Date:** 2026-05-07  
**Audience:** DBAs, developers, and anyone running or maintaining the HospitalDB report queries

---

## 1. Why Additional Indexes Are Needed

`sql/03_create_indexes.sql` established a baseline set of 11 indexes covering the most obvious foreign-key join paths (e.g. `Appointments.PatientID`, `Bills.PatientID`). However, a systematic analysis of the WHERE, JOIN, ORDER BY, and GROUP BY clauses across all five report files (05–09) revealed 24 additional column access patterns that the baseline set does not cover. Without these indexes, SQL Server must perform full or large range scans on growing tables every time those reports run.

### How the Analysis Was Done

Every stored procedure and view in files 05–09 was reviewed. For each query, the following clauses were extracted:

- **JOIN conditions** — the column on the "inner" side of each join (the column SQL Server must look up)
- **WHERE predicates** — equality, range, and `IN` filters applied before aggregation
- **ORDER BY columns** — the sort key for paginated stored procedures
- **GROUP BY dimensions** — aggregate grouping columns that become seeks or scans

Each column was then checked against the existing index list. Columns that appeared in multiple reports or drove high-volume operations were rated High priority; columns that appeared in fewer reports or supported lower-volume filters were rated Medium or Supporting.

---

## 2. What Was Not Changed

The following indexes already exist and are **not** duplicated in the new file:

| Index / Constraint | Table | Column(s) |
|---|---|---|
| `IX_Patients_LastName` | Patients | LastName |
| `IX_Patients_Email` | Patients | Email |
| `IX_Appointments_PatientID` | Appointments | PatientID |
| `IX_Appointments_DoctorID` | Appointments | DoctorID |
| `IX_Appointments_AppointmentDate` | Appointments | AppointmentDate |
| `IX_Bills_PatientID` | Bills | PatientID |
| `IX_Bills_AppointmentID` | Bills | AppointmentID |
| `IX_Payments_BillID` | Payments | BillID |
| `IX_MedicalRecords_CreatedDate` | MedicalRecords | CreatedDate |
| `IX_Prescriptions_RecordID` | Prescriptions | RecordID |
| `IX_LabOrders_AppointmentID` | LabOrders | AppointmentID |
| `UQ_Doctors_LicenseNumber` | Doctors | LicenseNumber |
| `UQ_LabTestCatalog_TestName` | LabTestCatalog | TestName |
| `UQ_MedicalRecords_AppointmentID` | MedicalRecords | AppointmentID |
| `UQ_Roles_RoleName` | Roles | RoleName |
| `UQ_Users_Username` | Users | Username |

---

## 3. New Indexes — Tier 1 (High Priority)

These indexes address the most frequently hit WHERE conditions and JOIN lookups across the report set. Each one eliminates a full or large range scan that would occur on every execution of one or more stored procedures.

### Index 1 — `IX_Appointments_Status`

| Property | Detail |
|---|---|
| **Table** | `dbo.Appointments` |
| **Key column** | `Status` |
| **INCLUDE columns** | `AppointmentDate`, `PatientID`, `DoctorID` |

**Why:** Every scheduling report filters appointments by status. `vw_UpcomingAppointments` uses `WHERE Status = 'Scheduled'`; `vw_MissedAppointments` uses `WHERE Status IN ('No-Show', 'Cancelled')`. Without this index, SQL Server scans every appointment row and then discards the non-matching ones. The INCLUDE columns mean the daily scheduler query (filter on Status, sort by AppointmentDate) is fully satisfied from the index leaf pages without any key lookup into the clustered index.

---

### Index 2 — `IX_BillItems_BillID`

| Property | Detail |
|---|---|
| **Table** | `dbo.BillItems` |
| **Key column** | `BillID` |
| **INCLUDE columns** | `ServiceID`, `Quantity`, `UnitPrice`, `LineTotal` |

**Why:** `BillItems` had **no index at all** in the baseline set. Every billing and revenue report (`vw_RevenueSummary`, `vw_PatientLifetimeValue`, `usp_Billing_RevenueSummary`, `usp_Report_MonthlyRevenueAnalysis`) joins Bills → BillItems on `BillID`. Without an index on `BillItems.BillID`, SQL Server scans the entire BillItems table for every bill row it processes. This is the single highest-impact addition in the file. The INCLUDE columns make the join covering — the revenue aggregation CTEs can read `ServiceID`, `Quantity`, `UnitPrice`, and `LineTotal` directly from the index without returning to the base table.

---

### Index 3 — `IX_Bills_BillStatus`

| Property | Detail |
|---|---|
| **Table** | `dbo.Bills` |
| **Key column** | `BillStatus` |
| **INCLUDE columns** | `PatientID`, `AppointmentID`, `TotalAmount`, `PaidAmount`, `Balance`, `CreatedDate` |

**Why:** `vw_UnpaidBills` filters `WHERE BillStatus IN ('Unpaid', 'Partially Paid')`. The AR aging stored procedure (`usp_Billing_UnpaidBills`) further filters by `@BillStatus`. Without this index every AR query scans all bills regardless of status. The INCLUDE columns allow the entire aging report to be served from the index pages — the engine never needs to read the clustered index rows for the filtered bills.

---

### Index 4 — `IX_AuditLogs_PerformedByUserID`

| Property | Detail |
|---|---|
| **Table** | `dbo.AuditLogs` |
| **Key column** | `PerformedByUserID` |
| **INCLUDE columns** | `ActionDate`, `TableName`, `ActionType` |

**Why:** `AuditLogs` had **no index on its FK column** `PerformedByUserID`. Three security objects depend on this join:  
- `vw_AuditLogDetail` — INNER JOIN AuditLogs → Users on `PerformedByUserID`  
- `vw_InactiveAccounts` — LEFT JOIN AuditLogs ON `PerformedByUserID` to count per-user audit events  
- `usp_Security_SystemActivitySummary` — aggregation by user  

Without an index, each execution of these objects performs a full scan of `AuditLogs` (the largest table in the database) to match users. The INCLUDE columns allow the summary aggregation (`COUNT`, `MIN`, `MAX`, `GROUP BY ActionType`) to run entirely on the index leaf pages.

---

### Index 5 — `IX_AuditLogs_ActionDate`

| Property | Detail |
|---|---|
| **Table** | `dbo.AuditLogs` |
| **Key column** | `ActionDate` |
| **INCLUDE columns** | `PerformedByUserID`, `TableName`, `ActionType` |

**Why:** `usp_Security_AuditLogReport` returns its detail result set ordered `ORDER BY ActionDate DESC` with a date-range WHERE clause. `usp_Security_SystemActivitySummary` groups audit events by day using `CAST(ActionDate AS DATE)`. `vw_InactiveAccounts` filters `WHERE ActionDate >= DATEADD(DAY, -30, GETDATE())`. Without this index, all three operations scan the full `AuditLogs` table on every call. The INCLUDE columns allow the entire WHERE + GROUP BY in the summary queries to be satisfied from the index.

---

### Index 6 — `IX_Doctors_DepartmentID`

| Property | Detail |
|---|---|
| **Table** | `dbo.Doctors` |
| **Key column** | `DepartmentID` |
| **INCLUDE columns** | `FirstName`, `LastName`, `Specialization` |

**Why:** The join chain `Appointments → Doctors → Departments` appears in **virtually every multi-table report** across all five report files. `DepartmentName` is the primary GROUP BY dimension in revenue, scheduling volume, and lab backlog reports, and the primary WHERE filter in department-specific drill-downs. Without an index on `Doctors.DepartmentID`, every query that navigates this chain must perform a full scan of the Doctors table. The INCLUDE columns mean most reporting views can read the doctor's display name directly from this index.

---

### Index 7 — `IX_PatientInsurancePolicies_PatientID_IsPrimary`

| Property | Detail |
|---|---|
| **Table** | `dbo.PatientInsurancePolicies` |
| **Key columns** | `PatientID`, `IsPrimary` (composite) |
| **INCLUDE columns** | `InsuranceProviderID`, `PolicyNumber`, `CoveragePercent`, `ExpiryDate` |

**Why:** Every report that references insurance uses the join pattern `LEFT JOIN PatientInsurancePolicies pip ON pip.PatientID = p.PatientID AND pip.IsPrimary = 1`. This appears in `vw_MaskedPatientDirectory`, `vw_ActivePrescriptionsWithInsurance`, and `vw_MissedAppointments`. A composite key `(PatientID, IsPrimary)` lets the engine seek directly to the primary-policy row for each patient without scanning all policies for that patient. The INCLUDE columns make the entire insurance side of the join covering — provider ID, policy number, coverage, and expiry are all available from the index leaf without a key lookup.

---

### Index 8 — `IX_Payments_PaymentDate`

| Property | Detail |
|---|---|
| **Table** | `dbo.Payments` |
| **Key column** | `PaymentDate` |
| **INCLUDE columns** | `BillID`, `Amount`, `PaymentMethod` |

**Why:** `usp_Billing_PaymentMethodAnalysis` filters `WHERE CAST(PaymentDate AS DATE) BETWEEN @StartDate AND @EndDate`. `usp_Billing_TopPayingPatients` and `usp_Billing_MonthlyRevenueTrend` also apply date range predicates on `PaymentDate`. All three aggregate `SUM(Amount)` and `GROUP BY PaymentMethod`. Without this index, every date-filtered payment query scans all payment rows. The INCLUDE columns allow the revenue aggregation to run entirely on the index.

---

## 4. New Indexes — Tier 2 (Medium Priority)

These indexes support specific report features — secondary date filters, GROUP BY dimensions, and method/status equality predicates — that are less universal than Tier 1 but still represent unindexed access patterns in the current schema.

### Index 9 — `IX_Bills_CreatedDate`

| Property | Detail |
|---|---|
| **Table** | `dbo.Bills` |
| **Key column** | `CreatedDate` |
| **INCLUDE columns** | `PatientID`, `AppointmentID`, `TotalAmount`, `PaidAmount`, `Balance`, `BillStatus` |

`usp_Billing_RevenueSummary` and `usp_Report_MonthlyRevenueAnalysis` filter `WHERE YEAR(CreatedDate) = @Year`. `usp_Billing_MonthlyRevenueTrend` groups by year and month of `CreatedDate`. An index on `CreatedDate` lets the engine range-scan the bill rows for a given year rather than reading all bills. The INCLUDE columns avoid key lookups in the aggregation CTEs.

---

### Index 10 — `IX_BillItems_ServiceID`

| Property | Detail |
|---|---|
| **Table** | `dbo.BillItems` |
| **Key column** | `ServiceID` |

`vw_RevenueSummary` joins `BillItems → ServiceCatalog` on `ServiceID`. Without this index, the engine seeks `ServiceCatalog` from the BillItems side using a scan. With the FK index in place, the join becomes a seek on both sides.

---

### Index 11 — `IX_Payments_PaymentMethod`

| Property | Detail |
|---|---|
| **Table** | `dbo.Payments` |
| **Key column** | `PaymentMethod` |
| **INCLUDE columns** | `Amount`, `BillID`, `PaymentDate` |

`usp_Billing_PaymentMethodAnalysis` filters `WHERE PaymentMethod = @PaymentMethod`. `vw_PatientLifetimeValue` and `usp_Billing_TopPayingPatients` derive each patient's preferred payment method by grouping `COUNT(PaymentID)` over `(PatientID, PaymentMethod)`. The INCLUDE columns make the modal-method derivation covering.

---

### Index 12 — `IX_Users_RoleID`

| Property | Detail |
|---|---|
| **Table** | `dbo.Users` |
| **Key column** | `RoleID` |

`vw_AuditLogDetail`, `vw_InactiveAccounts`, and `vw_MaskedPatientDirectory` all join `Users → Roles` through `RoleID`. Without an index on this FK column, each of those joins scans the Users table looking for role matches.

---

### Index 13 — `IX_Users_IsActive_LastLogin`

| Property | Detail |
|---|---|
| **Table** | `dbo.Users` |
| **Key columns** | `IsActive`, `LastLogin` (composite) |
| **INCLUDE columns** | `RoleID`, `Username` |

`vw_InactiveAccounts` applies `DATEDIFF(DAY, LastLogin, GETDATE())` and filters on `IsActive`. `usp_Security_InactiveAccountReport` orders results by `LastLogin DESC`. `usp_Security_MaskedPatientDirectory` filters `WHERE AccountIsActive = @AccountIsActive`. The composite `(IsActive, LastLogin)` supports the dominant access pattern: filter active accounts first, then range/sort on last-login recency. Placing `IsActive` first (lower cardinality) concentrates the seek on the much smaller set of active accounts before evaluating the date range.

---

### Index 14 — `IX_AuditLogs_ActionType_TableName`

| Property | Detail |
|---|---|
| **Table** | `dbo.AuditLogs` |
| **Key columns** | `ActionType`, `TableName` (composite) |
| **INCLUDE columns** | `ActionDate`, `PerformedByUserID` |

`usp_Security_AuditLogReport` accepts `@ActionType` and `@TableName` as independent WHERE filters. `usp_Security_SystemActivitySummary` identifies the most-active table per user via `FIRST_VALUE(...) OVER (PARTITION BY UserID ORDER BY COUNT(*) DESC)`. `ActionType` is placed first because it has lower cardinality (INSERT / UPDATE / DELETE) and will eliminate more rows at the seek step before evaluating `TableName`.

---

### Index 15 — `IX_LabOrders_Status`

| Property | Detail |
|---|---|
| **Table** | `dbo.LabOrders` |
| **Key column** | `Status` |
| **INCLUDE columns** | `AppointmentID`, `LabTestTypeID`, `DateRequested` |

`usp_Report_LabOrderBacklog` filters `WHERE Status = @StatusFilter` (Pending / In-Progress). Without this index, the backlog query scans all lab orders including completed ones. The INCLUDE columns cover both the join columns and the sort column, making the full backlog query satisfiable from this index.

---

### Index 16 — `IX_LabOrders_LabTestTypeID`

| Property | Detail |
|---|---|
| **Table** | `dbo.LabOrders` |
| **Key column** | `LabTestTypeID` |

`vw_LabOrderDetail` joins `LabOrders → LabTestCatalog` on `LabTestTypeID`. `usp_Report_LabOrderBacklog` groups the summary result set by `TestName` (resolved through this join). Without the index the join causes a full scan of LabOrders per catalog entry.

---

### Index 17 — `IX_PatientInsurancePolicies_ExpiryDate`

| Property | Detail |
|---|---|
| **Table** | `dbo.PatientInsurancePolicies` |
| **Key column** | `ExpiryDate` |
| **INCLUDE columns** | `PatientID`, `IsPrimary` |

`usp_Security_MaskedPatientDirectory` filters by insurance status using `ExpiryDate >= GETDATE()` (Active) or `ExpiryDate < GETDATE()` (Expired). `usp_Report_ActivePrescriptions` derives `InsuranceStatus` from the expiry date. A range index on `ExpiryDate` turns these into efficient date-range seeks rather than full scans of the policies table.

---

## 5. New Indexes — Tier 3 (Supporting)

These indexes complete the FK join coverage for tables that were not indexed in the baseline set, and support lower-frequency equality predicates.

| # | Index Name | Table | Key | Purpose |
|---|---|---|---|---|
| 18 | `IX_Prescriptions_DoctorID` | Prescriptions | DoctorID | JOIN in `vw_ActivePrescriptionsWithInsurance` |
| 19 | `IX_PrescriptionItems_PrescriptionID` | PrescriptionItems | PrescriptionID | JOIN from Prescriptions (table had zero indexes) |
| 20 | `IX_EmergencyContacts_PatientID` | EmergencyContacts | PatientID | JOIN in patient management queries |
| 21 | `IX_Addresses_City` | Addresses | City (+ INCLUDE State, Country) | `WHERE City = @City` in masked patient directory |
| 22 | `IX_Patients_Gender` | Patients | Gender | `WHERE Gender = @Gender` in patient directory |
| 23 | `IX_Patients_DOB` | Patients | DOB | `GROUP BY DOB` in duplicate record detection scan |
| 24 | `IX_LabOrders_DateRequested` | LabOrders | DateRequested (+ INCLUDE Status, AppointmentID, LabTestTypeID) | `ORDER BY DateRequested` in lab backlog procedure |

---

## 6. Gaps Left Intentionally Not Indexed

The following patterns were identified but deliberately excluded:

| Pattern | Reason Not Indexed |
|---|---|
| `YEAR(Bills.CreatedDate)` / `MONTH(...)` | Functions on a column prevent index seeks. The `IX_Bills_CreatedDate` index still eliminates most rows via a range scan on the raw date. If performance is critical, a persisted computed column `AS YEAR(CreatedDate)` with its own index would be more effective but requires a schema change. |
| `CAST(Payments.PaymentDate AS DATE)` | Same as above. `IX_Payments_PaymentDate` supports range scans even though the cast wraps the column. |
| `DATEPART(HOUR, AuditLogs.ActionDate)` | Used only in the `IsOutsideBusinessHours` flag derivation, not as a primary filter. A filtered index could help but would be very narrow in scope. |
| `DATEDIFF(DAY, Users.LastLogin, GETDATE())` | The result is non-deterministic. `IX_Users_IsActive_LastLogin` supports the `LastLogin` range scan adequately without a computed column. |

---

## 7. INCLUDE Column Strategy

Several indexes use `INCLUDE` columns. These are non-key columns stored in the index leaf pages but not part of the index key. They have two benefits:

1. **Covering index** — the query engine can satisfy the entire `SELECT` column list from the index without going back to the clustered index (key lookup). This eliminates one of the most expensive operations in OLTP read paths.
2. **No additional sort overhead** — INCLUDE columns are not sorted within the index, so they do not add maintenance cost when the table is modified (unlike adding them as key columns).

The downside is slightly larger index pages. INCLUDE columns were only added where the aggregation or projection in the stored procedure would otherwise require key lookups on a hot path.

---

## 8. Impact Summary by Table

| Table | New Indexes Added | Baseline Indexes Already Existed |
|---|---|---|
| Appointments | 1 (Status) | PatientID, DoctorID, AppointmentDate |
| Bills | 2 (BillStatus, CreatedDate) | PatientID, AppointmentID |
| BillItems | 2 (BillID, ServiceID) | None |
| Payments | 2 (PaymentDate, PaymentMethod) | BillID |
| AuditLogs | 3 (PerformedByUserID, ActionDate, ActionType+TableName) | None |
| Doctors | 1 (DepartmentID) | LicenseNumber (UNIQUE) |
| PatientInsurancePolicies | 2 (PatientID+IsPrimary, ExpiryDate) | None |
| Users | 2 (RoleID, IsActive+LastLogin) | Username (UNIQUE) |
| LabOrders | 3 (Status, LabTestTypeID, DateRequested) | AppointmentID |
| Prescriptions | 1 (DoctorID) | RecordID |
| PrescriptionItems | 1 (PrescriptionID) | None |
| EmergencyContacts | 1 (PatientID) | None |
| Addresses | 1 (City) | None |
| Patients | 2 (Gender, DOB) | LastName, Email |

---

## 9. Maintenance Notes

- **Write overhead** — each index adds a small overhead to `INSERT`, `UPDATE`, and `DELETE` on its table. At the current data volumes this is negligible. If any table grows to millions of rows and write performance becomes a concern, Tier 3 indexes should be reviewed first.
- **Safe to re-run** — every `CREATE INDEX` statement in `10_performance_indexes.sql` is preceded by a `DROP INDEX IF EXISTS` guard, so the file can be executed multiple times without error.
- **Execution order** — run `03_create_indexes.sql` before this file (the baseline must exist). This file does not depend on any report file being deployed.
- **Statistics** — after deploying on a populated database, run `UPDATE STATISTICS dbo.<TableName>` for each affected table, or let the auto-update statistics job pick them up on the next execution cycle.

---

*This document corresponds to `sql/10_performance_indexes.sql`. If the schema or reports change, review the index list and update accordingly.*
