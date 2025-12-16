# Entra ID Inactive User Management

Azure Automation runbooks for identifying and managing inactive users in Microsoft Entra ID (Azure AD).

## Overview

This repository contains PowerShell runbooks that automate the lifecycle management of inactive user accounts:

| Runbook | Description |
|---------|-------------|
| `Disable-InactiveMembers.ps1` | Disables member accounts inactive for 90+ days |
| `Delete-InactiveMembers.ps1` | Soft deletes member accounts inactive for specified period |
| `Disable-InactiveGuests.ps1` | Disables guest accounts inactive for specified period |
| `Delete-InactiveGuests.ps1` | Soft deletes guest accounts inactive for specified period |

## Prerequisites

- Azure Automation account with PowerShell 7.x runtime
- System-assigned managed identity enabled
- Microsoft Graph PowerShell modules imported:
  - `Microsoft.Graph.Authentication`
  - `Microsoft.Graph.Users`
  - `Microsoft.Graph.Groups`
  - `Microsoft.Graph.Identity.DirectoryManagement`

## Quick Start

1. **Grant permissions** to your managed identity:
   ```powershell
   ./scripts/Grant-ManagedIdentityPermissions.ps1 -AutomationAccountName "your-automation-account"
   ```

2. **Import runbooks** into your Azure Automation account

3. **Configure parameters** and schedule as needed

See [docs/SETUP.md](docs/SETUP.md) for detailed setup instructions.

## Repository Structure

```
colrunbooks/
├── runbooks/           # Azure Automation runbooks
├── scripts/            # Supporting utility scripts
└── docs/               # Documentation
    ├── SETUP.md        # Setup guide
    ├── PERMISSIONS.md  # Permission requirements
    └── PARAMETERS.md   # Parameter reference
```

## Documentation

- [Setup Guide](docs/SETUP.md) - Azure Automation configuration
- [Permissions](docs/PERMISSIONS.md) - Required Graph API permissions
- [Parameters](docs/PARAMETERS.md) - Runbook parameter reference

## Safety Features

- **WhatIf mode** - All runbooks default to `$WhatIf = $true` for safe testing
- **Exclusion groups** - Skip users in specified security groups
- **Domain exclusions** - Skip users from specified domains
- **Department exclusions** - Skip users in specified departments
- **License filtering** - Only process users with specific licenses
- **Creation date check** - Skip recently created accounts
