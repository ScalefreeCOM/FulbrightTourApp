# Salesforce schema reference

Everything the app reads or writes in Salesforce: objects, standard fields, custom fields and picklist values.
Use this to prepare another org for the app.

**Legend — "Provided by":**
- **Standard** — part of every Sales Cloud org.
- **Package** — created by the app's metadata package (`salesforce/force-app`, deploy with `salesforce/deploy.sh`).
- **Prerequisites** — existed in the Fulbright org before the app; other orgs can create them with the
  prerequisites package (`salesforce/prerequisites`) or map their own fields instead.

Every API name and value below can be changed per org in `config/salesforce-mapping.json`
(see [`config/salesforce-mapping.default.json`](../config/salesforce-mapping.default.json)); the mapping key is shown in
the last column. Names in *italics* are labels used in the Fulbright org (e.g. Campaign is labelled "Program").

---

## Campaign — *Program* (one per study tour)

| Field | Type | Provided by | Used for | Mapping key |
|---|---|---|---|---|
| `Name` | Text (80) | Standard | Tour title (contains city and year) | — |
| `StartDate`, `EndDate` | Date | Standard | Tour dates; all deadlines are calculated from them. Programs without a start date (umbrella program, thank-you mailings) are not listed as tours | — |
| `IsActive` | Checkbox | Standard | Set on programs the app creates; inactive (past) tours are still listed | — |
| `ParentId` | Lookup (Campaign) | Standard | Child programs, e.g. the thank-you mailing to officials. Tours may be top-level or children of an umbrella program | — |
| `Type` | Picklist | Standard | Value **`Study Tour`** marks study-tour programs; the program picker lists these (with a start date), newest first | `program.type`, `program.studyTourTypeValue` |
| `Study_Tour_City__c` | Text (80) | Package | City / region | `program.city` |
| `Drive_Folder__c` | URL | Package | Tour folder in the shared Google Drive | `program.driveFolder` |
| `Agenda_Document__c` | URL | Package | The tour's copy of the agenda template | `program.agendaDocument` |
| `Knowledge_Base__c` | URL | Package | Knowledge base for the email assistant (default from config) | `program.knowledgeBase` |

## CampaignMember — *Program Member* (participants of a tour)

| Field | Type | Provided by | Used for | Mapping key |
|---|---|---|---|---|
| `CampaignId`, `LeadId`, `ContactId` | Lookup | Standard | Links members (Leads) and officials (Contacts) to programs | — |
| `Status` | Picklist | Standard | Value **`Responded`** for members the app adds | `programMember.status`, `programMember.newMemberStatusValue` |
| `Attendance_Status__c` | Picklist (restricted): Invited, Applied, **Attending**, Cancelled | Prerequisites | Only **Attending** members are participants (lists, checks, deletion) | `programMember.attendanceStatus`, `programMember.attendingValue` |

## Lead — *Member* (participants)

| Field | Type | Provided by | Used for | Mapping key |
|---|---|---|---|---|
| `FirstName`, `LastName` | Text | Standard | Name (cleansing, host lists) | `member.firstName`, `member.lastName` |
| `Email` | Email | Standard | Matching incoming emails, host lists | `member.email` |
| `MobilePhone` | Phone | Standard | Phone (normalised to international format) | `member.phone` |
| `Company`, `Title` | Text | Standard | Organisation and position | `member.organization`, `member.title` |
| `LeadSource` | Picklist | Standard | Value **`Other`** for members created from emails | `member.leadSource`, `member.leadSourceValue` |
| `IsConverted` | Checkbox | Standard | Converted Leads are skipped (read-only in Salesforce) | — |
| `Birth_Date__c` | Date | Prerequisites | Date of birth — **ID data, deleted after the tour** | `member.birthDate` |
| `Citizenship__c` | Picklist (restricted): 194 English country names | Prerequisites | Citizenship — **ID data** | `member.nationality` |
| `Identification_Type__c` | Picklist (restricted): `National/Personal ID card`, `Passport` | Prerequisites | Document type — **ID data, deleted** | `member.identificationType`, `member.idTypePassportValue`, `member.idTypeIdCardValue` |
| `Identification_Number__c` | Text (20) | Prerequisites | Passport / ID number — **ID data, deleted** | `member.passportNumber` |
| `Expiry_Date__c` | Date | Prerequisites | Document expiry — **ID data, deleted** | `member.passportExpiry` |
| `Issuing_Country__c` | Picklist (restricted): 194 English country names | Prerequisites | Issuing country — **ID data, deleted** | `member.passportIssuingCountry` |
| `Dietary_Needs__c` | Text (255) | Package | Restaurant headcount | `member.dietary` |
| `Emergency_Contact_Name__c` | Text (120) | Package | Emergency contact — **deleted after the tour** | `member.emergencyContact` |
| `Emergency_Contact_Phone__c` | Phone | Package | Emergency phone — **deleted after the tour** | `member.emergencyPhone` |

The app always writes the English **API values** of the country picklists (e.g. `United States of America`,
`Türkiye`, `United Kingdom of Great Britain and Northern Ireland`); labels may be translated.

## Opportunity — host visit (one per host organisation and tour)

| Field | Type | Provided by | Used for | Mapping key |
|---|---|---|---|---|
| `Name`, `AccountId` | Text, Lookup (Account) | Standard | Visit and host organisation | — |
| `CampaignId` | Lookup (Campaign) | Standard | Links the visit to the tour's program | — |
| `StageName` | Picklist | Standard | Host status — see values below | `hostVisit.stage…` |
| `Visit_Start__c`, `Visit_End__c` | Date/Time | Package | Meeting time; drives the agenda | `hostVisit.visitStart`, `hostVisit.visitEnd` |
| `List_Deadline__c` | Date | Package | Deadline for the attendee list | `hostVisit.listDeadline` |
| `Attendee_List_Recipient__c` | Lookup (Contact) | Package | Receives the filled attendee form | `hostVisit.recipient`, `hostVisit.recipientRelationship` |
| Attached Excel file | File (ContentDocumentLink) | Standard | The host's own registration form (`.xlsx`) | — |

| Stage value | Meaning in the app | Mapping key |
|---|---|---|
| `Qualification` | Identified | `hostVisit.stageIdentified` |
| `Needs Analysis` | Invitation letter sent | `hostVisit.stageLetterSent` |
| `Proposal`, `Negotiation` | In discussion | `hostVisit.stagesInDiscussion` |
| `Closed Won` | Confirmed | `hostVisit.stageConfirmed` |
| `Closed Lost` | Declined | `hostVisit.stageDeclined` |

## Contact and Account — officials and host organisations

| Field | Type | Provided by | Used for | Mapping key |
|---|---|---|---|---|
| `Contact.FirstName`, `LastName`, `Email`, `Title`, `AccountId` | Standard | Standard | Recognising officials' emails; new contacts from emails | — |
| `Contact.Greeting__c` | Text (100), **required** | Prerequisites | Salutation in letters; set when the app creates a contact | `contact.greeting` |
| `Account.Name`, `Account.Website` | Standard | Standard | Host organisation; matching by email domain | — |

## Task — checklist items and email activities

| Field | Type | Provided by | Used for | Mapping key |
|---|---|---|---|---|
| `WhatId`, `WhoId`, `OwnerId` | Lookup | Standard | Program (checklist) / member or contact (emails) / responsible user | — |
| `Subject`, `Description`, `ActivityDate` | Standard | Standard | Title, notes, due date | — |
| `Status` | Picklist | Standard | Values **`Open`**, **`Completed`** | `task.openValue`, `task.completedValue` |
| `Priority` | Picklist | Standard | Value **`Normal`** | `task.priorityValue` |
| `TaskSubtype` | Picklist | Standard | Value **`Email`** for logged emails | `task.emailSubtypeValue` |
| `Study_Tour_Phase__c` | Picklist (restricted, on Activity): `0 Setup`, `1 Host Outreach`, `2 Program and Promotion`, `3 Registration`, `4 Submissions and Logistics`, `5 Tour Days`, `6 Wrap-up` | Package | Marks a Task as checklist item of a phase | `task.phase`, `task.phaseValues` |

Records the app creates as Tasks: checklist items, incoming and outgoing emails, "Data protection: passport data
deleted" and "Data protection: attendee data sent to …" on each affected member.

## Event — agenda

Standard fields `Subject`, `StartDateTime`, `EndDateTime`, `Location`, `Description`, `WhatId`.

## Other objects (read only)

| Object | Fields | Used for |
|---|---|---|
| `User` | `Id`, `Name`, `Email`, `IsActive`, `UserType` | Task owners; recognising organisers' emails |
| `PermissionSetAssignment` | `AssigneeId`, `PermissionSet.PermissionsModifyAllData` | Shows the org-wide passport deletion to administrators only |
| `ContentDocumentLink`, `ContentVersion` | Standard | Downloading the host's Excel form from the Opportunity |

---

## Permission sets

| Permission set | Package | Grants |
|---|---|---|
| `Fulbright_Study_Tours` | Package | Read/edit on the 12 package fields — assign to every team member |
| `Fulbright_Study_Tours_Prerequisites` | Prerequisites | Read/edit on the pre-existing fields (except the required `Greeting__c`) — only for orgs that deploy the prerequisites package |

## Preparing another org — checklist

1. Deploy the **prerequisites package** — or map your own fields for birth date, citizenship, ID type/number/expiry,
   issuing country, attendance status and greeting in `config/salesforce-mapping.json`.
2. Deploy the **main package** with `salesforce/deploy.sh`.
3. Make sure the standard picklists contain the values above (Campaign Type `Study Tour`, CampaignMember Status
   `Responded`, Lead Source `Other`, the Opportunity stages, Task Status/Priority) — or map your values.
4. Assign the permission set(s) to the team.

> **Fulbright org:** all values listed above exist.
