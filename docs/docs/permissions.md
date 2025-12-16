# Microsoft Graph Permissions

## Required Permissions

The managed identity requires these Microsoft Graph **application** permissions:

| Permission | Purpose |
|------------|---------|
| `User.Read.All` | Read user profiles and sign-in activity |
| `User.ReadWrite.All` | Disable and delete user accounts |
| `Directory.Read.All` | Read directory data including licenses |
| `Group.Read.All` | Read exclusion group membership |

## Granting Permissions

### Using the Script (Recommended)

```powershell
./scripts/Grant-ManagedIdentityPermissions.ps1 -AutomationAccountName "your-automation-account-name"
```

**Prerequisites**:

- PowerShell 7.x
- Global Administrator or Privileged Role Administrator role
- Microsoft.Graph.Authentication module
- Microsoft.Graph.Applications module

### Manual Method (Azure Portal)

!!! warning
    Application permissions for managed identities cannot be granted through the Azure Portal. You must use PowerShell or the Microsoft Graph API.

### Manual Method (PowerShell)

```powershell
Connect-MgGraph -Scopes "Application.Read.All", "AppRoleAssignment.ReadWrite.All"

# Get service principals
$managedIdentity = Get-MgServicePrincipal -Filter "displayName eq 'your-automation-account'"
$graphApp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

# Get the permission
$permission = $graphApp.AppRoles | Where-Object { $_.Value -eq "User.ReadWrite.All" }

# Assign
New-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $managedIdentity.Id `
    -PrincipalId $managedIdentity.Id `
    -ResourceId $graphApp.Id `
    -AppRoleId $permission.Id
```

## Verifying Permissions

### Via Azure Portal

1. Go to **Azure Active Directory** > **Enterprise applications**
2. Change filter to **Managed Identities**
3. Find your Automation account
4. Click **Permissions** under Security
5. Verify all required permissions are listed

### Via PowerShell

```powershell
Connect-MgGraph -Scopes "Application.Read.All"

$mi = Get-MgServicePrincipal -Filter "displayName eq 'your-automation-account'"
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $mi.Id |
    Select-Object AppRoleId, ResourceDisplayName
```

## Permission Propagation

After granting permissions:

- Allow 5-10 minutes for propagation
- If issues persist, try disconnecting and reconnecting in the runbook
- Check Azure AD sign-in logs for detailed error information

## Least Privilege Considerations

If you want to limit permissions:

| Operation | Minimum Permission |
|-----------|-------------------|
| Read users only | `User.Read.All` |
| Disable users | `User.ReadWrite.All` |
| Delete users | `User.ReadWrite.All` |
| Read groups | `Group.Read.All` |
| Read licenses | `Directory.Read.All` |

!!! note
    `User.ReadWrite.All` is required for both disable and soft delete operations.
