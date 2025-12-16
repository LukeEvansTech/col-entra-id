<#
.SYNOPSIS
    Grants Microsoft Graph API permissions to an Azure Automation managed identity.
.DESCRIPTION
    This script assigns the required Microsoft Graph application permissions to a
    system-assigned managed identity for an Azure Automation account. These permissions
    are required for the 90DayDisable.ps1 runbook to function correctly.
.PARAMETER AutomationAccountName
    The name of the Azure Automation account whose managed identity needs permissions.
.NOTES
    Requires:
    - Microsoft.Graph PowerShell module
    - Global Admin or Privileged Role Administrator role
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$AutomationAccountName
)

# Check and install/import required modules
$requiredModules = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Applications"
)

foreach ($moduleName in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        Write-Host "Installing $moduleName..." -ForegroundColor Yellow
        Install-Module -Name $moduleName -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $moduleName -ErrorAction Stop
}

Connect-MgGraph -Scopes "Application.Read.All", "AppRoleAssignment.ReadWrite.All"

# Get the managed identity service principal
$managedIdentity = Get-MgServicePrincipal -Filter "displayName eq '$AutomationAccountName'"

if (-not $managedIdentity) {
    Write-Error "Managed identity not found for '$AutomationAccountName'"
    return
}

Write-Host "Found managed identity: $($managedIdentity.Id)"

# Get Microsoft Graph service principal
$graphApp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

# Define required permissions for the 90DayDisable runbook
$requiredPermissions = @(
    "User.Read.All",
    "User.ReadWrite.All",
    "Directory.Read.All",
    "Group.Read.All"
)

foreach ($permissionName in $requiredPermissions) {
    $appRole = $graphApp.AppRoles | Where-Object { $_.Value -eq $permissionName }

    if (-not $appRole) {
        Write-Warning "Permission '$permissionName' not found"
        continue
    }

    # Check if already assigned
    $existing = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $managedIdentity.Id |
        Where-Object { $_.AppRoleId -eq $appRole.Id }

    if ($existing) {
        Write-Host "Permission '$permissionName' already assigned" -ForegroundColor Yellow
        continue
    }

    # Assign the permission
    New-MgServicePrincipalAppRoleAssignment `
        -ServicePrincipalId $managedIdentity.Id `
        -PrincipalId $managedIdentity.Id `
        -ResourceId $graphApp.Id `
        -AppRoleId $appRole.Id

    Write-Host "Granted '$permissionName'" -ForegroundColor Green
}

Write-Host "`nDone. Permissions may take a few minutes to propagate."
