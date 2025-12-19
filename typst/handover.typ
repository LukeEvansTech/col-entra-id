// Entra ID User Lifecycle Management - Handover Document
// Generated with Typst

#set document(
  title: "Entra ID User Lifecycle Management - Handover Document",
  author: "LukeEvansTech",
)

#set page(
  paper: "a4",
  margin: (x: 2.5cm, y: 2.5cm),
  numbering: "1",
  number-align: center,
)

#set text(
  font: "Open Sans",
  size: 11pt,
)

#show raw: set text(font: "JetBrains Mono", size: 9pt)

#set heading(numbering: "1.1")

#set par(
  justify: true,
  leading: 0.65em,
)

// Color definitions - City of London branding (coat of arms)
#let primary-color = rgb("#C8102E")   // City of London red (from coat of arms)
#let secondary-color = rgb("#E65100") // Orange accent (from logo underline)
#let accent-color = rgb("#d44a4a")    // Lighter red

// Custom styles
#let note-box(body) = {
  block(
    fill: rgb("#ffebee"),  // Light red tint
    inset: 12pt,
    radius: 4pt,
    width: 100%,
    body
  )
}

#let warning-box(body) = {
  block(
    fill: rgb("#fff3e0"),
    inset: 12pt,
    radius: 4pt,
    width: 100%,
    body
  )
}

// Cover Page
#page(numbering: none)[
  #align(center + horizon)[
    #block(
      fill: primary-color,
      inset: 2em,
      radius: 8pt,
      width: 100%,
    )[
      #text(fill: white, size: 28pt, weight: "bold")[
        Entra ID User Lifecycle Management
      ]
      #v(0.5em)
      #text(fill: white, size: 16pt)[
        Handover Document
      ]
    ]

    #v(2em)

    #text(size: 14pt)[
      Azure Automation Runbooks for Managing Inactive Users\
      in Microsoft Entra ID
    ]

    #v(3em)

    #line(length: 40%, stroke: primary-color)

    #v(2em)

    #text(size: 12pt, fill: gray)[
      LukeEvansTech\
      #datetime.today().display("[month repr:long] [day], [year]")
    ]
  ]
]

// Table of Contents
#page(numbering: none)[
  #outline(
    title: [Contents],
    indent: auto,
    depth: 2,
  )
]

#pagebreak()

= Overview

This solution provides Azure Automation runbooks that automate the lifecycle management of inactive user accounts in Microsoft Entra ID (Azure AD). The solution implements a two-stage approach for member users and a single-stage approach for guest users.

== Azure Environment

#figure(
  table(
    columns: (1fr, 2fr),
    align: (left, left),
    fill: (x, y) => if y == 0 { primary-color } else if calc.odd(y) { rgb("#f5f5f5") } else { white },
    text(fill: white, weight: "bold")[Property],
    text(fill: white, weight: "bold")[Value],
    [Automation Account], [`col-uks-mgmt-EntraID-aa`],
    [Resource Group], [`col-uks-rg-mgmt`],
    [Location], [UK South],
    [Subscription], [`col-sub-cop-management`],
    [Subscription ID], [`280f1edf-4eca-4558-bdaf-12db0a42dabc`],
  ),
  caption: [Azure Automation Environment],
)

== Key Features

- *Two-Stage Member Lifecycle* -- Member users are first disabled after 90 days of inactivity, then deleted after 180 days
- *Guest Cleanup* -- Guest users are deleted after 90 days of inactivity to maintain a clean directory
- *Flexible Exclusions* -- Exclude users by security group, domain, department, or license type
- *Safe by Default* -- All runbooks default to WhatIf mode - preview changes before applying them
- *Soft Delete* -- Deleted users are moved to the recycle bin and recoverable for 30 days
- *Managed Identity* -- Uses Azure managed identity for secure, credential-free authentication

#pagebreak()

= User Lifecycle Strategy

== Member Users

The member user lifecycle follows a two-stage approach:

#figure(
  table(
    columns: (1fr, 1fr, 2fr),
    align: (center, center, left),
    fill: (x, y) => if y == 0 { primary-color } else if calc.odd(y) { rgb("#f5f5f5") } else { white },
    text(fill: white, weight: "bold")[Stage],
    text(fill: white, weight: "bold")[Days],
    text(fill: white, weight: "bold")[Action],
    [1], [90], [Disable account - User cannot sign in],
    [2], [180], [Soft delete - User moved to deleted items],
    [Auto], [+30], [Permanent deletion by Microsoft],
  ),
  caption: [Member User Lifecycle Stages],
)

#v(1em)

#note-box[
  *Note:* Users disabled at 90 days must remain disabled until they reach 180 days of inactivity to be processed by the deletion runbook.
]

== Guest Users

Guest users follow a simplified single-stage lifecycle:

#figure(
  table(
    columns: (1fr, 1fr, 2fr),
    align: (center, center, left),
    fill: (x, y) => if y == 0 { primary-color } else if calc.odd(y) { rgb("#f5f5f5") } else { white },
    text(fill: white, weight: "bold")[Stage],
    text(fill: white, weight: "bold")[Days],
    text(fill: white, weight: "bold")[Action],
    [1], [90], [Soft delete - User moved to deleted items],
    [Auto], [+30], [Permanent deletion by Microsoft],
  ),
  caption: [Guest User Lifecycle Stages],
)

#pagebreak()

= Runbooks

== Summary Table

#figure(
  table(
    columns: (2fr, 1fr, 1fr, 0.5fr),
    align: (left, center, center, center),
    fill: (x, y) => if y == 0 { primary-color } else if calc.odd(y) { rgb("#f5f5f5") } else { white },
    text(fill: white, weight: "bold")[Runbook],
    text(fill: white, weight: "bold")[Target],
    text(fill: white, weight: "bold")[Action],
    text(fill: white, weight: "bold")[Days],
    [Disable-Inactive-Member-Users-90-Days], [Members], [Disable], [90],
    [Delete-Inactive-Member-Users-180-Days], [Members], [Delete], [180],
    [Delete-Inactive-Guest-Users-90-Days], [Guests], [Delete], [90],
    [Get-Inactive-Users-With-Manager], [Members], [Report], [30],
  ),
  caption: [Runbook Overview],
)

== Disable Inactive Member Users (90 Days)

*Purpose:* Identifies and disables member users who have been inactive for 90+ days. This is the first stage of the member user lifecycle.

*Target Users:*
- User type: Member
- Account status: Enabled
- Excludes Cross-Tenant Sync users

*Action:* Sets `accountEnabled` to `false` for identified users.

== Delete Inactive Member Users (180 Days)

*Purpose:* Identifies and soft deletes disabled member users who have been inactive for 180+ days. This is the second stage of the member user lifecycle.

*Target Users:*
- User type: Member
- Account status: Disabled
- Excludes Cross-Tenant Sync users

*Action:* Soft deletes identified users via `Remove-MgUser`. Users can be recovered for 30 days.

== Delete Inactive Guest Users (90 Days)

*Purpose:* Identifies and soft deletes guest users who have been inactive for 90+ days.

*Target Users:*
- User type: Guest
- Any account status

*Action:* Soft deletes identified users via `Remove-MgUser`. Users can be recovered for 30 days.

== Report Inactive Users with Manager

*Purpose:* Identifies licensed member users with managers who have been inactive for a specified period (default 30 days). Optionally adds users to a security group for line manager review.

*Target Users:*
- User type: Member
- Has a manager assigned
- Has specific licenses

*Action:* Reports inactive users and optionally adds them to a review group.

#pagebreak()

= Default Exclusions

== Member Runbooks

Member runbooks are pre-configured with these exclusions:

#figure(
  table(
    columns: (1fr, 2fr),
    align: (left, left),
    fill: (x, y) => if y == 0 { primary-color } else if calc.odd(y) { rgb("#f5f5f5") } else { white },
    text(fill: white, weight: "bold")[Type],
    text(fill: white, weight: "bold")[Values],
    [Domains], [`cityoflondon.police.uk`, `freemens.org`],
    [Departments], [`Members`],
    [Exclusion Group], [`Line Manager - Inactive User Review - Exclusion`],
  ),
  caption: [Member Runbook Exclusions],
)

== Guest Runbooks

Guest runbooks only filter by domain:

#figure(
  table(
    columns: (1fr, 2fr),
    align: (left, left),
    fill: (x, y) => if y == 0 { primary-color } else if calc.odd(y) { rgb("#f5f5f5") } else { white },
    text(fill: white, weight: "bold")[Type],
    text(fill: white, weight: "bold")[Values],
    [Domains], [`cityoflondon.police.uk`, `freemens.org`],
  ),
  caption: [Guest Runbook Exclusions],
)

#v(1em)

#note-box[
  *Note:* Guest runbooks do not use group or department exclusions as these typically don't apply to guest accounts.
]

#pagebreak()

= Setup & Configuration

== Current Configuration

The Azure Automation environment is fully configured and operational:

- System-assigned managed identity enabled
- Microsoft Graph permissions granted
- PowerShell modules imported (Runtime 7.2)
- Runbooks imported and published
- Schedules configured

== Required Modules

- `Microsoft.Graph.Authentication`
- `Microsoft.Graph.Users`
- `Microsoft.Graph.Groups`
- `Microsoft.Graph.Identity.DirectoryManagement`

== Required Permissions

The managed identity requires these Microsoft Graph API permissions:

#figure(
  table(
    columns: (2fr, 3fr),
    align: (left, left),
    fill: (x, y) => if y == 0 { primary-color } else if calc.odd(y) { rgb("#f5f5f5") } else { white },
    text(fill: white, weight: "bold")[Permission],
    text(fill: white, weight: "bold")[Purpose],
    [`User.Read.All`], [Read all user properties including sign-in activity],
    [`User.ReadWrite.All`], [Disable and delete users],
    [`Group.Read.All`], [Read exclusion group membership],
    [`GroupMember.ReadWrite.All`], [Add users to review groups (reporting runbook)],
    [`AuditLog.Read.All`], [Access sign-in activity data],
  ),
  caption: [Required Microsoft Graph Permissions],
)

#pagebreak()

= Sign-In Activity Detection

All runbooks use Microsoft Graph's `signInActivity` property to determine the last sign-in date. The following properties are checked:

1. `LastSignInDateTime` -- Interactive sign-ins
2. `LastNonInteractiveSignInDateTime` -- Background/app sign-ins
3. `LastSuccessfulSignInDateTime` -- Last successful authentication

The most recent date wins. If no sign-in activity is recorded, the user is considered inactive.

#warning-box[
  *Important:* Users created within the grace period (90 or 180 days depending on the runbook) are automatically excluded, even if they have no sign-in activity recorded.
]

#pagebreak()

= Safety Features

The runbooks include multiple safety mechanisms:

+ *WhatIf Mode* -- All runbooks default to preview mode
+ *Exclusion Groups* -- Skip users in specified security groups
+ *Domain Exclusions* -- Skip users from specified domains
+ *Department Exclusions* -- Skip users in specified departments
+ *License Filtering* -- Only process users with specific licenses
+ *Creation Date Check* -- Skip recently created accounts
+ *Soft Delete* -- Deleted users recoverable for 30 days

#v(1em)

#note-box[
  *Recommendation:* Always run with `-WhatIf $true` first to review which users would be affected before executing with `-WhatIf $false`.
]

#pagebreak()

= Scripts

== Grant-ManagedIdentityPermissions.ps1

This script grants the required Microsoft Graph API permissions to the Azure Automation account's managed identity.

*Usage:*
```powershell
./scripts/Grant-ManagedIdentityPermissions.ps1 -AutomationAccountName "col-uks-mgmt-EntraID-aa"
```

*Requirements:*
- PowerShell 7.x with Microsoft.Graph modules
- Global Admin or Privileged Role Administrator role

*Permissions Granted:*
#figure(
  table(
    columns: (1fr, 2fr),
    align: (left, left),
    fill: (x, y) => if y == 0 { primary-color } else if calc.odd(y) { rgb("#f5f5f5") } else { white },
    text(fill: white, weight: "bold")[Permission],
    text(fill: white, weight: "bold")[Purpose],
    [`User.Read.All`], [Read user properties including sign-in activity],
    [`User.ReadWrite.All`], [Disable and delete user accounts],
    [`Directory.Read.All`], [Read directory data],
    [`Group.Read.All`], [Read exclusion group membership],
  ),
  caption: [Permissions Granted by Script],
)

#v(1em)

#note-box[
  *Note:* The script is idempotent - it can be run multiple times safely. Already-assigned permissions are skipped.
]

#pagebreak()

= Repository Structure

```
col-entra-id/
├── runbooks/               # Azure Automation runbooks
│   ├── Entra-ID-Disable-Inactive-Member-Users-90-Days.ps1
│   ├── Entra-ID-Delete-Inactive-Member-Users-180-Days.ps1
│   ├── Entra-ID-Delete-Inactive-Guest-Users-90-Days.ps1
│   └── Entra-ID-Get-Inactive-Users-With-Manager-And-License.ps1
├── scripts/                # Supporting utility scripts
│   └── Grant-ManagedIdentityPermissions.ps1
├── docs/                   # Documentation (Zensical site)
└── typst/                  # Handover document generation
```

#pagebreak()

= Contact & Support

For questions or issues with this solution:

- *Repository:* #link("https://github.com/LukeEvansTech/col-entra-id")[github.com/LukeEvansTech/col-entra-id]
- *Documentation:* #link("https://lukeevanstech.github.io/col-entra-id/")[lukeevanstech.github.io/col-entra-id]

#v(2em)

#align(center)[
  #line(length: 40%, stroke: gray)
  #v(1em)
  #text(fill: gray, size: 10pt)[
    Document generated on #datetime.today().display("[month repr:long] [day], [year]")
  ]
]
