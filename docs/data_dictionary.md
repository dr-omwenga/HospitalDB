# HospitalDB — Data Dictionary

**Database:** HospitalDB  
**Platform:** Microsoft SQL Server  
**Tables:** 21  
**Last Updated:** 2026-05-07

---

## Table of Contents

| # | Table | Domain |
|---|-------|--------|
| 1 | [Roles](#roles) | Security |
| 2 | [Users](#users) | Security |
| 3 | [AuditLogs](#auditlogs) | Security |
| 4 | [ErrorLogs](#errorlogs) | System |
| 5 | [Addresses](#addresses) | Reference |
| 6 | [Departments](#departments) | Reference |
| 7 | [InsuranceProviders](#insuranceproviders) | Reference |
| 8 | [LabTestCatalog](#labtestcatalog) | Reference |
| 9 | [ServiceCatalog](#servicecatalog) | Reference |
| 10 | [Patients](#patients) | Clinical |
| 11 | [EmergencyContacts](#emergencycontacts) | Clinical |
| 12 | [PatientInsurancePolicies](#patientinsurancepolicies) | Clinical |
| 13 | [Doctors](#doctors) | Clinical |
| 14 | [Appointments](#appointments) | Scheduling |
| 15 | [MedicalRecords](#medicalrecords) | Clinical |
| 16 | [Prescriptions](#prescriptions) | Clinical |
| 17 | [PrescriptionItems](#prescriptionitems) | Clinical |
| 18 | [LabOrders](#laborders) | Clinical |
| 19 | [Bills](#bills) | Billing |
| 20 | [BillItems](#billitems) | Billing |
| 21 | [Payments](#payments) | Billing |

---

## Security Domain

### Roles

Defines the access roles that can be assigned to system users.

| Column | Type | Nullable | Identity | Constraints | Description |
|--------|------|----------|----------|-------------|-------------|
| RoleID | INT | NO | YES | PK | Unique role identifier |
| RoleName | VARCHAR(50) | NO | — | UNIQUE | Human-readable role label (e.g., `Admin`, `Doctor`, `Receptionist`) |

**Typical values:** Admin, Doctor, Receptionist, Nurse

---

### Users

System accounts used to log in to the hospital application. Linked to a role that controls access permissions.

| Column | Type | Nullable | Identity | Constraints | Description |
|--------|------|----------|----------|-------------|-------------|
| UserID | INT | NO | YES | PK | Unique user identifier |
| RoleID | INT | NO | — | FK → Roles | Role assigned to this user |
| Username | VARCHAR(80) | NO | — | UNIQUE | Login name |
| PasswordHash | VARBINARY(256) | NO | — | — | Hashed password (store bcrypt / PBKDF2 only) |
| LastLogin | DATETIME | YES | — | — | Timestamp of the most recent successful login |
| IsActive | BIT | NO | — | — | `1` = active account, `0` = disabled |

---

### AuditLogs

Tracks data modification events performed by users for compliance and change-history purposes.

| Column | Type | Nullable | Identity | Constraints | Description |
|--------|------|----------|----------|-------------|-------------|
| AuditID | INT | NO | YES | PK | Unique audit entry identifier |
| PerformedByUserID | INT | NO | — | FK → Users | User who performed the action |
| TableName | VARCHAR(80) | NO | — | — | Name of the table that was changed |
| ActionType | VARCHAR(20) | NO | — | — | Type of action: `INSERT`, `UPDATE`, or `DELETE` |
| ActionDate | DATETIME | NO | — | — | Date and time the action occurred |
| OldValue | NVARCHAR(MAX) | NO | — | — | JSON or text representation of the row before the change |
| NewValue | NVARCHAR(MAX) | NO | — | — | JSON or text representation of the row after the change |

---

## System Domain

### ErrorLogs

Records unhandled errors raised by stored procedures and application code.

| Column | Type | Nullable | Identity | Constraints | Description |
|--------|------|----------|----------|-------------|-------------|
| ErrorID | INT | NO | YES | PK | Unique error entry identifier |
| ProcedureName | VARCHAR(120) | NO | — | — | Name of the stored procedure or module where the error occurred |
| ErrorMessage | NVARCHAR(MAX) | NO | — | — | Full error message text |
| ErrorDate | DATETIME | NO | — | — | Date and time the error was logged |

---

## Reference Domain

### Addresses

Reusable mailing addresses referenced by patients.

| Column | Type | Nullable | Identity | Constraints | Description |
|--------|------|----------|----------|-------------|-------------|
| AddressID | INT | NO | YES | PK | Unique address identifier |
| Street | VARCHAR(120) | NO | — | — | Street number and name |
| City | VARCHAR(60) | NO | — | — | City name |
| State | VARCHAR(60) | NO | — | — | State or province |
| PostalCode | VARCHAR(20) | NO | — | — | ZIP / postal code |
| Country | VARCHAR(60) | NO | — | — | Country name |

---

### Departments

Hospital departments that doctors are assigned to.

| Column | Type | Nullable | Identity | Constraints | Description |
|--------|------|----------|----------|-------------|-------------|
| DepartmentID | INT | NO | YES | PK | Unique department identifier |
| DepartmentName | VARCHAR(100) | NO | — | — | Full department name (e.g., `Cardiology`) |
| Location | VARCHAR(100) | NO | — | — | Physical location within the building |

---

### InsuranceProviders

Third-party insurance companies that cover patient costs.

| Column | Type | Nullable | Identity | Constraints | Description |
|--------|------|----------|----------|-------------|-------------|
| InsuranceProviderID | INT | NO | YES | PK | Unique provider identifier |
| ProviderName | VARCHAR(100) | NO | — | — | Insurance company name |
| Phone | VARCHAR(25) | NO | — | — | Provider contact phone number |
| Email | VARCHAR(120) | NO | — | — | Provider contact email address |

---

### LabTestCatalog

Master list of available laboratory tests with their standard prices.

| Column | Type | Nullable | Identity | Constraints | Description |
|--------|------|----------|----------|-------------|-------------|
| LabTestTypeID | INT | NO | YES | PK | Unique test type identifier |
| TestName | VARCHAR(120) | NO | — | UNIQUE | Full name of the lab test (e.g., `Complete Blood Count (CBC)`) |
| StandardPrice | DECIMAL(10,2) | NO | — | — | Default charge for this test in USD |

---

### ServiceCatalog

Master list of clinical services and procedures that can be billed.

| Column | Type | Nullable | Identity | Constraints | Description |
|--------|------|----------|----------|-------------|-------------|
| ServiceID | INT | NO | YES | PK | Unique service identifier |
| ServiceName | VARCHAR(120) | NO | — | — | Descriptive service name (e.g., `General Consultation`) |
| StandardPrice | DECIMAL(10,2) | NO | — | — | Default charge for this service in USD |

---

## Clinical Domain

### Patients

Core patient registry. One record per patient.

| Column | Type | Nullable | Identity | Constraints | Description |
|--------|------|----------|----------|-------------|-------------|
| PatientID | INT | NO | YES | PK | Unique patient identifier |
| AddressID | INT | NO | — | FK → Addresses | Patient's registered home address |
| FirstName | VARCHAR(60) | NO | — | — | Patient first name |
| LastName | VARCHAR(60) | NO | — | — | Patient last name |
| DOB | DATE | NO | — | — | Date of birth |
| Gender | VARCHAR(20) | NO | — | — | Gender identity (e.g., `Male`, `Female`, `Non-binary`) |
| Phone | VARCHAR(25) | NO | — | — | Primary contact phone number |
| Email | VARCHAR(120) | NO | — | — | Contact email address |
| DateCreated | DATETIME | NO | — | — | Date the patient record was first created in the system |

---

### EmergencyContacts

Emergency contact persons associated with a patient. A patient may have multiple entries.

| Column | Type | Nullable | Identity | Constraints | Description |
|--------|------|----------|----------|-------------|-------------|
| EmergencyContactID | INT | NO | YES | PK | Unique contact identifier |
| PatientID | INT | NO | — | FK → Patients | Patient this contact belongs to |
| FullName | VARCHAR(120) | NO | — | — | Full name of the emergency contact |
| Relationship | VARCHAR(50) | NO | — | — | Relationship to patient (e.g., `Spouse`, `Parent`, `Sibling`) |
| Phone | VARCHAR(25) | NO | — | — | Contact phone number |
| Email | VARCHAR(120) | NO | — | — | Contact email address |

---

### PatientInsurancePolicies

Insurance policies held by patients. A patient may have multiple policies; at most one should have `IsPrimary = 1`.

| Column | Type | Nullable | Identity | Constraints | Description |
|--------|------|----------|----------|-------------|-------------|
| PatientInsuranceID | INT | NO | YES | PK | Unique policy record identifier |
| PatientID | INT | NO | — | FK → Patients | Patient who holds this policy |
| InsuranceProviderID | INT | NO | — | FK → InsuranceProviders | Insurance company providing the policy |
| PolicyNumber | VARCHAR(50) | NO | — | — | Unique policy number issued by the insurer |
| CoveragePercent | DECIMAL(5,2) | NO | — | — | Percentage of costs covered by the insurer (0.00–100.00) |
| ExpiryDate | DATE | NO | — | — | Policy expiry date |
| IsPrimary | BIT | NO | — | — | `1` = primary policy for this patient, `0` = secondary |

---

### Doctors

Registered medical practitioners. Each doctor belongs to one department.

| Column | Type | Nullable | Identity | Constraints | Description |
|--------|------|----------|----------|-------------|-------------|
| DoctorID | INT | NO | YES | PK | Unique doctor identifier |
| DepartmentID | INT | NO | — | FK → Departments | Department the doctor is assigned to |
| FirstName | VARCHAR(60) | NO | — | — | Doctor's first name |
| LastName | VARCHAR(60) | NO | — | — | Doctor's last name |
| Phone | VARCHAR(25) | NO | — | — | Direct contact phone number |
| Email | VARCHAR(120) | NO | — | — | Professional email address |
| Specialization | VARCHAR(100) | NO | — | — | Medical specialty (e.g., `Cardiologist`, `Neurologist`) |
| LicenseNumber | VARCHAR(50) | NO | — | UNIQUE | State medical license number |

---

## Scheduling Domain

### Appointments

Scheduled or completed meetings between a patient and a doctor.

| Column | Type | Nullable | Identity | Constraints | Description |
|--------|------|----------|----------|-------------|-------------|
| AppointmentID | INT | NO | YES | PK | Unique appointment identifier |
| PatientID | INT | NO | — | FK → Patients | Patient attending the appointment |
| DoctorID | INT | NO | — | FK → Doctors | Doctor conducting the appointment |
| CreatedByUserID | INT | NO | — | FK → Users | System user who booked the appointment |
| AppointmentDate | DATETIME | NO | — | — | Scheduled date and time |
| Status | VARCHAR(30) | NO | — | — | Current status: `Scheduled`, `Completed`, `Cancelled`, `No-Show` |
| Reason | VARCHAR(255) | NO | — | — | Patient's stated reason for visiting |

---

## Clinical Records Domain

### MedicalRecords

Clinical notes recorded by a doctor following a completed appointment. One record per appointment (enforced by UNIQUE constraint).

| Column | Type | Nullable | Identity | Constraints | Description |
|--------|------|----------|----------|-------------|-------------|
| RecordID | INT | NO | YES | PK | Unique medical record identifier |
| AppointmentID | INT | NO | — | FK → Appointments, UNIQUE | The appointment this record documents |
| Diagnosis | VARCHAR(255) | NO | — | — | Primary diagnosis recorded by the doctor |
| Notes | NVARCHAR(MAX) | NO | — | — | Free-text clinical observations |
| TreatmentPlan | NVARCHAR(MAX) | NO | — | — | Detailed treatment plan and follow-up instructions |
| CreatedDate | DATETIME | NO | — | — | Date and time the record was created |

---

### Prescriptions

A prescription header issued by a doctor as part of a medical record. One prescription may contain multiple items.

| Column | Type | Nullable | Identity | Constraints | Description |
|--------|------|----------|----------|-------------|-------------|
| PrescriptionID | INT | NO | YES | PK | Unique prescription identifier |
| RecordID | INT | NO | — | FK → MedicalRecords | Medical record this prescription is part of |
| DoctorID | INT | NO | — | FK → Doctors | Doctor who issued the prescription |
| PrescriptionDate | DATE | NO | — | — | Date the prescription was written |

---

### PrescriptionItems

Individual medication lines within a prescription.

| Column | Type | Nullable | Identity | Constraints | Description |
|--------|------|----------|----------|-------------|-------------|
| PrescriptionItemID | INT | NO | YES | PK | Unique line item identifier |
| PrescriptionID | INT | NO | — | FK → Prescriptions | Parent prescription |
| MedicationName | VARCHAR(120) | NO | — | — | Name of the medication |
| Dosage | VARCHAR(60) | NO | — | — | Dose amount and unit (e.g., `50 mg`, `0.4 mg sublingual`) |
| Frequency | VARCHAR(60) | NO | — | — | How often to take (e.g., `Once daily`, `Twice daily with food`) |
| Duration | VARCHAR(60) | NO | — | — | How long to take (e.g., `30 days`, `Until symptoms resolve`) |

---

### LabOrders

Laboratory tests ordered during an appointment.

| Column | Type | Nullable | Identity | Constraints | Description |
|--------|------|----------|----------|-------------|-------------|
| LabOrderID | INT | NO | YES | PK | Unique lab order identifier |
| AppointmentID | INT | NO | — | FK → Appointments | Appointment that generated this order |
| LabTestTypeID | INT | NO | — | FK → LabTestCatalog | Type of test ordered |
| Result | NVARCHAR(MAX) | YES | — | — | Lab result text (NULL if not yet resulted) |
| Status | VARCHAR(30) | NO | — | — | Order status: `Pending`, `In Progress`, `Completed`, `Cancelled` |
| DateRequested | DATETIME | NO | — | — | Date and time the test was ordered |

---

## Billing Domain

### Bills

A billing summary generated for a patient after an appointment.

| Column | Type | Nullable | Identity | Constraints | Description |
|--------|------|----------|----------|-------------|-------------|
| BillID | INT | NO | YES | PK | Unique bill identifier |
| PatientID | INT | NO | — | FK → Patients | Patient being billed |
| AppointmentID | INT | NO | — | FK → Appointments | Appointment that generated the bill |
| TotalAmount | DECIMAL(10,2) | NO | — | — | Sum of all line items |
| PaidAmount | DECIMAL(10,2) | NO | — | — | Total payments received against this bill |
| Balance | DECIMAL(10,2) | NO | — | — | Remaining outstanding balance (`TotalAmount - PaidAmount`) |
| BillStatus | VARCHAR(30) | NO | — | — | Status: `Unpaid`, `Partial`, `Paid`, `Void` |
| CreatedDate | DATETIME | NO | — | — | Date the bill was created |

---

### BillItems

Individual service line items that make up a bill.

| Column | Type | Nullable | Identity | Constraints | Description |
|--------|------|----------|----------|-------------|-------------|
| BillItemID | INT | NO | YES | PK | Unique bill line item identifier |
| BillID | INT | NO | — | FK → Bills | Parent bill |
| ServiceID | INT | NO | — | FK → ServiceCatalog | Service rendered |
| Quantity | INT | NO | — | — | Number of units of the service |
| UnitPrice | DECIMAL(10,2) | NO | — | — | Price per unit at time of billing (may differ from catalog price) |
| LineTotal | DECIMAL(10,2) | NO | — | — | `Quantity × UnitPrice` |

---

### Payments

Individual payment transactions applied to a bill.

| Column | Type | Nullable | Identity | Constraints | Description |
|--------|------|----------|----------|-------------|-------------|
| PaymentID | INT | NO | YES | PK | Unique payment identifier |
| BillID | INT | NO | — | FK → Bills | Bill being paid |
| PaymentDate | DATETIME | NO | — | — | Date and time the payment was recorded |
| Amount | DECIMAL(10,2) | NO | — | — | Payment amount in USD |
| PaymentMethod | VARCHAR(40) | NO | — | — | Method used: `Cash`, `Credit Card`, `Debit Card`, `Insurance`, `Bank Transfer` |
| ReferenceNumber | VARCHAR(80) | NO | — | — | External transaction reference (e.g., card authorization code) |
