# Setup Guide

## 1. Create Azure Automation Account

If you don't have an existing Automation account:

1. Navigate to **Azure Portal** > **Create a resource** > **Automation**
2. Configure:
   - **Name**: e.g., `col-uks-mgmt-EntraID-aa`
   - **Region**: Your preferred region
   - **Resource group**: Select or create one
3. Click **Create**

## 2. Enable Managed Identity

1. Open your Automation account
2. Go to **Identity** under Settings
3. Under **System assigned**, set Status to **On**
4. Click **Save**
5. Note the **Object ID** - you'll need this for permissions

## 3. Grant Microsoft Graph Permissions

Run the permissions script from a PowerShell session with Global Admin rights:

```powershell
./scripts/Grant-ManagedIdentityPermissions.ps1 -AutomationAccountName "your-automation-account-name"
```

See [Permissions](permissions.md) for details on required permissions.

## 4. Import PowerShell Modules

In your Automation account:

1. Go to **Modules** under Shared Resources
2. Click **Browse gallery**
3. Search and import these modules (in order):
   - `Microsoft.Graph.Authentication`
   - `Microsoft.Graph.Users`
   - `Microsoft.Graph.Groups`
   - `Microsoft.Graph.Identity.DirectoryManagement`

!!! note
    Select **Runtime version: 7.2** for each module.

## 5. Import Runbooks

1. Go to **Runbooks** under Process Automation
2. Click **Import a runbook**
3. Upload each `.ps1` file from the `runbooks/` folder:
   - `Entra-ID-Disable-Inactive-Member-Users-90-Days.ps1`
   - `Entra-ID-Delete-Inactive-Member-Users-180-Days.ps1`
   - `Entra-ID-Delete-Inactive-Guest-Users-90-Days.ps1`
4. Set **Runtime version** to **7.2**
5. Click **Create**
6. **Publish** each runbook after import

## 6. Configure Runbook Parameters

Edit default parameter values as needed for your environment:

- `InactiveDays` - Days of inactivity threshold
- `ExclusionGroupName` - Security group for exclusions
- `ExclusionDomainList` - Domains to exclude
- `ExclusionDepartmentList` - Departments to exclude
- `LicensesToInclude` - License types to process (member runbooks only)
- `WhatIf` - Set to `$false` for production runs

See [Parameters](parameters.md) for full parameter reference.

## 7. Schedule Runbooks

1. Open the runbook
2. Click **Schedules** > **Add a schedule**
3. Create a new schedule:
   - **Name**: e.g., `Weekly-InactiveUserCheck`
   - **Recurrence**: Weekly (recommended)
   - **Start time**: Off-peak hours
4. Configure parameters for the scheduled run
5. Click **OK**

### Recommended Schedule

| Runbook | Frequency | Notes |
|---------|-----------|-------|
| Disable Members (90 days) | Weekly | First stage of member lifecycle |
| Delete Members (180 days) | Weekly | Second stage, runs after disable |
| Delete Guests (90 days) | Weekly | Independent guest cleanup |

## 8. Test with WhatIf

Before enabling production runs:

1. Start the runbook manually with `WhatIf = $true` (default)
2. Review the output in **Jobs**
3. Verify the correct users would be affected
4. Adjust exclusions as needed
5. Only set `WhatIf = $false` when satisfied

## Troubleshooting

### Permission Denied Errors

If you see `Authorization_RequestDenied`:

- Re-run the permissions script
- Wait 5-10 minutes for propagation
- Verify permissions in **Enterprise Applications** > your managed identity > **Permissions**

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
