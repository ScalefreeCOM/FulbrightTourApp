# Salesforce metadata changes — review

Package: `salesforce/force-app` (SFDX source format). **Additive only:** new custom fields and one new permission set.
No existing fields, objects, page layouts, automations or data are changed or deleted.

Deploy: validate first (check-only), then deploy, then assign the permission set to the team.

| Object | Field (API name) | Label | Type | Details | Purpose |
|---|---|---|---|---|---|
| Activity (Task & Event) | `Study_Tour_Phase__c` | Study Tour Phase | Picklist | values: 0 Setup, 1 Host Outreach, 2 Program and Promotion, 3 Registration, 4 Submissions and Logistics, 5 Tour Days, 6 Wrap-up | Marks a Task as checklist item of a study tour phase (0–6). Empty for all other activities. |
| Program (Campaign) | `Agenda_Document__c` | Agenda Document | Url |  | Link to the tour's copy of the agenda Slides template. |
| Program (Campaign) | `Drive_Folder__c` | Drive Folder | Url |  | Link to the tour folder in the shared study-tour Drive folder; set when the app creates the folder. |
| Program (Campaign) | `Knowledge_Base__c` | Knowledge Base | Url | default: `knowledgeBaseURL` from the config file (filled in by `deploy.sh`) | Google Doc the email assistant uses; defaults to the shared knowledge base, can point to a program-specific doc. |
| Program (Campaign) | `Study_Tour_City__c` | Study Tour City | Text | length 80 | City/region of the tour; shown in the app header. |
| Member (Lead) | `Dietary_Needs__c` | Dietary Needs | Text | length 255 | Dietary requirements for restaurants (headcount in the app). |
| Member (Lead) | `Emergency_Contact_Name__c` | Emergency Contact Name | Text | length 120 | Emergency contact during the tour; deleted after the tour together with passport data. |
| Member (Lead) | `Emergency_Contact_Phone__c` | Emergency Contact Phone | Phone |  | Phone of the emergency contact; deleted after the tour. |
| Opportunity | `Attendee_List_Recipient__c` | Attendee List Recipient | Lookup | → Contact, on delete: SetNull | Contact who receives the filled attendee form. |
| Opportunity | `List_Deadline__c` | List Deadline | Date |  | Date the host needs the attendee list; shown and highlighted in the app. |
| Opportunity | `Visit_End__c` | Visit End | DateTime |  | End of the meeting with the host. |
| Opportunity | `Visit_Location__c` | Visit Location | TextArea |  | Meeting address if it differs from the host organization's address; shown on the agenda. |
| Opportunity | `Visit_Start__c` | Visit Start | DateTime |  | Start of the meeting with the host; drives the agenda. |

**13 fields.**

## Permission set `Fulbright_Study_Tours` (“Fulbright Study Tours”)

Access to the study tour fields used by the Fulbright Study Tours app. Assign to every team member.

| Field | Read | Edit |
|---|---|---|
| `Activity.Study_Tour_Phase__c` | ✓ | ✓ |
| `Campaign.Agenda_Document__c` | ✓ | ✓ |
| `Campaign.Drive_Folder__c` | ✓ | ✓ |
| `Campaign.Knowledge_Base__c` | ✓ | ✓ |
| `Campaign.Study_Tour_City__c` | ✓ | ✓ |
| `Lead.Dietary_Needs__c` | ✓ | ✓ |
| `Lead.Emergency_Contact_Name__c` | ✓ | ✓ |
| `Lead.Emergency_Contact_Phone__c` | ✓ | ✓ |
| `Opportunity.Attendee_List_Recipient__c` | ✓ | ✓ |
| `Opportunity.List_Deadline__c` | ✓ | ✓ |
| `Opportunity.Visit_End__c` | ✓ | ✓ |
| `Opportunity.Visit_Location__c` | ✓ | ✓ |
| `Opportunity.Visit_Start__c` | ✓ | ✓ |

No object permissions, user permissions or app/tab settings are included — only field-level access to the new fields.

## Not included (decided against)

- `Study_Tour_Data__c` (JSON storage field) — replaced by individual fields and native records.
- Separate Host / Team objects — hosts are Opportunities, team = Salesforce users.

## Commands

`deploy.sh` copies the package to a temporary folder, fills in the values from `config/studytours.config.json`
(e.g. the default knowledge base URL) and runs the Salesforce CLI.

```bash
salesforce/deploy.sh validate <org-alias>   # check-only, changes nothing
salesforce/deploy.sh deploy <org-alias>
sf org assign permset --name Fulbright_Study_Tours --target-org <org-alias>
```
