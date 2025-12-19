# Setup Guide

## Azure Environment

The Azure Automation environment is already configured and operational:

| Property | Value |
|----------|-------|
| Automation Account | `col-uks-mgmt-EntraID-aa` |
| Resource Group | `col-uks-rg-mgmt` |
| Location | UK South |
| Subscription | `col-sub-cop-management` |
| Subscription ID | `280f1edf-4eca-4558-bdaf-12db0a42dabc` |

[Open in Azure Portal](https://portal.azure.com/#@corpoflondon.onmicrosoft.com/resource/subscriptions/280f1edf-4eca-4558-bdaf-12db0a42dabc/resourceGroups/col-uks-rg-mgmt/providers/Microsoft.Automation/automationAccounts/col-uks-mgmt-EntraID-aa/overview)

---

## Configuration Overview

The following components are configured:

- [x] Azure Automation account created
- [x] System-assigned managed identity enabled
- [x] Microsoft Graph permissions granted
- [x] PowerShell modules imported
- [x] Runbooks imported and published
- [x] Schedules configured

---

## 1. Managed Identity

The system-assigned managed identity is enabled on the Automation account. This identity is used to authenticate to Microsoft Graph without storing credentials.

To view the managed identity:

1. Open the Automation account in Azure Portal
2. Go to **Identity** under Settings
3. The **Object ID** is displayed under System assigned

---

## 2. Microsoft Graph Permissions

Permissions were granted using the [Grant-ManagedIdentityPermissions.ps1](scripts.md) script:

```powershell
./scripts/Grant-ManagedIdentityPermissions.ps1 -AutomationAccountName "col-uks-mgmt-EntraID-aa"
```

See [Permissions](permissions.md) for the full list of required permissions.

To verify permissions:

1. Navigate to **Entra ID** > **Enterprise applications**
2. Search for `col-uks-mgmt-EntraID-aa`
3. Go to **Permissions** under Security
4. Verify all required permissions are listed

---

## 3. PowerShell Modules

The following modules are imported with **Runtime version 7.2**:

| Module | Purpose |
|--------|---------|
| `Microsoft.Graph.Authentication` | Connect to Microsoft Graph |
| `Microsoft.Graph.Users` | Read and modify user accounts |
| `Microsoft.Graph.Groups` | Read group membership |
| `Microsoft.Graph.Identity.DirectoryManagement` | Read license information |

To view or update modules:

1. Open the Automation account
2. Go to **Modules** under Shared Resources
3. Click **Browse gallery** to add new modules

!!! note
    Always select **Runtime version: 7.2** when importing modules.

---

## 4. Runbooks

The following runbooks are imported and published:

| Runbook | Purpose |
|---------|---------|
| `Entra-ID-Disable-Inactive-Member-Users-90-Days.ps1` | Disable members inactive 90+ days |
| `Entra-ID-Delete-Inactive-Member-Users-180-Days.ps1` | Delete members inactive 180+ days |
| `Entra-ID-Delete-Inactive-Guest-Users-90-Days.ps1` | Delete guests inactive 90+ days |
| `Entra-ID-Get-Inactive-Users-With-Manager-And-License.ps1` | Report inactive users with managers |

To view runbooks:

1. Open the Automation account
2. Go to **Runbooks** under Process Automation

See [Runbooks Overview](runbooks.md) for detailed documentation.

---

## 5. Schedules

### Recommended Schedule

| Runbook | Frequency | Notes |
|---------|-----------|-------|
| Disable Members (90 days) | Weekly | First stage of member lifecycle |
| Delete Members (180 days) | Weekly | Second stage, runs after disable |
| Delete Guests (90 days) | Weekly | Independent guest cleanup |
| Report Inactive Users | Weekly | For line manager review |

To view or modify schedules:

1. Open a runbook
2. Click **Schedules** under Resources
3. Click on a schedule to modify

To create a new schedule:

1. Click **Add a schedule**
2. Configure:
   - **Name**: e.g., `Weekly-InactiveUserCheck`
   - **Recurrence**: Weekly
   - **Start time**: Off-peak hours (e.g., Sunday 02:00)
3. Configure parameters for the scheduled run
4. Click **OK**

---

## 6. Parameters

Default parameter values are configured for the City of London environment:

| Parameter | Default Value |
|-----------|---------------|
| `ExclusionGroupName` | `Line Manager - Inactive User Review - Exclusion` |
| `ExclusionDomainList` | `cityoflondon.police.uk`, `freemens.org` |
| `ExclusionDepartmentList` | `Members` |

See [Parameters Reference](parameters.md) for full parameter documentation.

---

## Testing Changes

Before making changes to production:

1. Start the runbook manually with `WhatIf = $true`
2. Review the output in **Jobs**
3. Verify the correct users would be affected
4. Adjust exclusions as needed
5. Only set `WhatIf = $false` when satisfied

---

## Troubleshooting

### Permission Denied Errors

If you see `Authorization_RequestDenied`:

- Re-run the [permissions script](scripts.md)
- Wait 5-10 minutes for propagation
- Verify permissions in **Enterprise Applications** > `col-uks-mgmt-EntraID-aa` > **Permissions**

### Module Import Failures

If modules fail to import:

- Ensure you're selecting **Runtime version 7.2**
- Import `Microsoft.Graph.Authentication` first
- Wait for each module to finish before importing the next

### No Users Found

If runbooks report no inactive users:

- Check the `InactiveDays` parameter
- Verify exclusion filters aren't too broad
- Enable `DebugMode = $true` for detailed logging

### Job Failures

To investigate failed jobs:

1. Open the Automation account
2. Go to **Jobs** under Process Automation
3. Click on the failed job
4. Review **Output**, **Errors**, and **Warnings** tabs
