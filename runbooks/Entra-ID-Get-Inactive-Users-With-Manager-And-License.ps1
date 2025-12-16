<#
.SYNOPSIS
    Azure Automation runbook to identify licensed users with managers who are inactive in an Entra ID/M365 tenant.
.DESCRIPTION
    This Azure Automation runbook connects to Microsoft Graph using managed identity and identifies users who:
    1. Have a manager assigned
    2. Have specific licenses assigned (configurable via friendly names)
    3. Haven't signed in for a specified number of days

    Optionally, inactive users can be added to a specified group for further management.
    The results are output to the Azure Automation logs for review.
.PARAMETER InactiveDays
    Number of days without activity to consider a user inactive. Default is 30 days.
.PARAMETER LicensesToCheck
    Array of friendly license names to check for. If not specified, all licenses will be considered.
.PARAMETER InactiveUsersGroupName
    Name of the group to add inactive users to. Default is "Inactive Users". Set to empty string or $null to only report without adding to group.
.PARAMETER ExclusionGroupName
    Name of the group containing users to exclude from the inactive user report. Users in this group will be skipped.
.NOTES
    PowerShell 7 Azure Automation runbook

    Requires the following modules to be imported in Azure Automation:
    - Microsoft.Graph.Authentication
    - Microsoft.Graph.Users
    - Microsoft.Graph.Groups
    - Microsoft.Graph.Identity.DirectoryManagement

    Requires a system-assigned managed identity with the following permissions:
    - User.Read.All
    - Directory.Read.All
    - Group.Read.All (required for group operations)
    - GroupMember.ReadWrite.All (required for adding users to groups)

    Runtime Version: PowerShell 7.x
#>

param (
    [int]$InactiveDays = 30,
    [string[]]$LicensesToCheck = @(
        # Default list of licenses to check - customize as needed
        "Microsoft 365 E5",
        "Microsoft 365 E3",
        "Office 365 E5",
        "Office 365 E3",
        "Office 365 E1"
    ),
    [string]$InactiveUsersGroupName = "Line Manager - Inactive User Review",
    [string]$ExclusionGroupName = "Line Manager - Inactive User Review - Exclusion"
)

# Set error handling for Azure Automation
$ErrorActionPreference = "Stop"

# Azure Automation logging function
function Write-AutomationLog {
    param(
        [string]$Message,
        [ValidateSet("Information", "Warning", "Error")]
        [string]$Level = "Information"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"

    switch ($Level) {
        "Information" { Write-Output $logMessage }
        "Warning" { Write-Warning $logMessage }
        "Error" { Write-Error $logMessage }
    }
}

# Function to get or create group and add users
function Add-UsersToGroup {
    param(
        [string]$GroupName,
        [array]$UserIds
    )

    if ([string]::IsNullOrEmpty($GroupName) -or $UserIds.Count -eq 0) {
        return
    }

    try {
        # Try to find existing group
        Write-AutomationLog "Looking for group: $GroupName" "Information"
        $group = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction SilentlyContinue

        if (-not $group) {
            # Create the group if it doesn't exist
            Write-AutomationLog "Group '$GroupName' not found. Creating new security group..." "Information"
            $group = New-MgGroup -DisplayName $GroupName -SecurityEnabled:$true -MailEnabled:$false -MailNickname ($GroupName -replace '[^a-zA-Z0-9]', '')
            Write-AutomationLog "Created group '$GroupName' with ID: $($group.Id)" "Information"
        }
        else {
            Write-AutomationLog "Found existing group '$GroupName' with ID: $($group.Id)" "Information"
        }

        # Get current group members to clear them first
        $currentMembers = @()
        try {
            $currentMembers = Get-MgGroupMember -GroupId $group.Id -All | Select-Object -ExpandProperty Id
            Write-AutomationLog "Found $($currentMembers.Count) existing members in group '$GroupName'" "Information"
        }
        catch {
            Write-AutomationLog "Could not retrieve current group members (this is normal for new groups): $_" "Warning"
        }

        # Clear existing group membership
        $removedCount = 0
        $removeErrorCount = 0
        if ($currentMembers.Count -gt 0) {
            Write-AutomationLog "Clearing existing group membership..." "Information"
            foreach ($memberId in $currentMembers) {
                try {
                    Remove-MgGroupMemberByRef -GroupId $group.Id -DirectoryObjectId $memberId
                    Write-AutomationLog "Removed user $memberId from group '$GroupName'" "Information"
                    $removedCount++
                }
                catch {
                    Write-AutomationLog "Failed to remove user $memberId from group '$GroupName': $_" "Error"
                    $removeErrorCount++
                }
            }
            Write-AutomationLog "Removed $removedCount members from group '$GroupName' ($removeErrorCount failed)" "Information"
        }

        # Add new inactive users to group
        $addedCount = 0
        $errorCount = 0

        foreach ($userId in $UserIds) {
            try {
                New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $userId
                Write-AutomationLog "Added user $userId to group '$GroupName'" "Information"
                $addedCount++
            }
            catch {
                Write-AutomationLog "Failed to add user $userId to group '$GroupName': $_" "Error"
                $errorCount++
            }
        }

        Write-AutomationLog "Group membership update complete for '$GroupName': $removedCount removed, $addedCount added, $errorCount failed to add" "Information"
        return @{
            GroupId          = $group.Id
            GroupName        = $GroupName
            RemovedCount     = $removedCount
            RemoveErrorCount = $removeErrorCount
            AddedCount       = $addedCount
            ErrorCount       = $errorCount
        }
    }
    catch {
        Write-AutomationLog "Error managing group '$GroupName': $_" "Error"
        return $null
    }
}

Write-AutomationLog "Starting Inactive Licensed Users with Manager Report (Azure Automation)" "Information"

# Connect to Microsoft Graph using managed identity
Write-AutomationLog "Connecting to Microsoft Graph using managed identity..." "Information"
try {
    # Connect using managed identity with required scopes
    Connect-MgGraph -Identity -NoWelcome

    # Verify connection
    $context = Get-MgContext
    if (-not $context) {
        throw "Failed to connect to Microsoft Graph. No context available."
    }

    $tenantId = $context.TenantId
    Write-AutomationLog "Successfully connected to Microsoft Graph using managed identity" "Information"
    Write-AutomationLog "Tenant ID: $tenantId" "Information"
    Write-AutomationLog "Authentication Type: $($context.AuthType)" "Information"
}
catch {
    Write-AutomationLog "Error connecting to Microsoft Graph: $_" "Error"
    throw "Failed to connect to Microsoft Graph. Ensure managed identity has required permissions."
}

# Get the current date and calculate the inactive threshold date
$currentDate = Get-Date
$inactiveThreshold = $currentDate.AddDays(-$InactiveDays)
Write-AutomationLog "Identifying users inactive since: $inactiveThreshold" "Information"

# Define friendly names for common license SKUs
$licenseFriendlyNames = @{
    # Microsoft 365 Licenses
    "SPE_F1"                   = "Microsoft 365 F1"
    "SPE_F5_SECCOMP"           = "Microsoft 365 F5 Security Compliance"
    "SPE_E3"                   = "Microsoft 365 E3"
    "SPE_E5"                   = "Microsoft 365 E5"
    "M365_F1"                  = "Microsoft 365 F1"
    "M365_E3"                  = "Microsoft 365 E3"
    "M365_E5"                  = "Microsoft 365 E5"
    "M365_E5_SUITE_COMPONENTS" = "Microsoft 365 E5 Components"

    # Office 365 Licenses
    "STANDARDPACK"             = "Office 365 E1"
    "ENTERPRISEPACK"           = "Office 365 E3"
    "ENTERPRISEPREMIUM"        = "Office 365 E5"
    "DESKLESSPACK"             = "Office 365 F1"
    "EXCHANGE_S_STANDARD"      = "Exchange Online Plan 1"
    "EXCHANGE_S_ENTERPRISE"    = "Exchange Online Plan 2"

    # Enterprise Mobility + Security
    "EMS"                      = "Enterprise Mobility + Security E3"
    "EMSPREMIUM"               = "Enterprise Mobility + Security E5"

    # Windows Licenses
    "WIN10_VDA_E3"             = "Windows 10 Enterprise E3"
    "WIN10_VDA_E5"             = "Windows 10 Enterprise E5"
    "WIN_DEF_ATP"              = "Microsoft Defender for Endpoint"

    # Power Platform
    "FLOW_FREE"                = "Power Automate Free"
    "POWERAPPS_VIRAL"          = "Power Apps Trial"
    "POWERAPPS_PER_APP_IW"     = "Power Apps Per App"
    "POWER_BI_STANDARD"        = "Power BI Free"
    "POWER_BI_PRO"             = "Power BI Pro"
    "POWER_BI_PREMIUM_P1"      = "Power BI Premium P1"

    # Phone System
    "PHONESYSTEM_VIRTUALUSER"  = "Phone System - Virtual User"
    "MCOEV"                    = "Phone System"
    "MCOEV_VIRTUALUSER"        = "Phone System - Virtual User"

    # Other
    "AAD_PREMIUM"              = "Azure AD Premium P1"
    "AAD_PREMIUM_P2"           = "Azure AD Premium P2"
    "ADALLOM_S_O365"           = "Microsoft Cloud App Security for Office 365"
    "ADALLOM_S_STANDALONE"     = "Microsoft Cloud App Security"
    "ATP_ENTERPRISE"           = "Office 365 Advanced Threat Protection"
    "PROJECTPROFESSIONAL"      = "Project Professional"
    "PROJECTONLINE_PLAN_1"     = "Project Plan 1"
    "PROJECTONLINE_PLAN_3"     = "Project Plan 3"
    "PROJECTONLINE_PLAN_5"     = "Project Plan 5"
    "VISIO_PLAN1_DEPT"         = "Visio Plan 1"
    "VISIO_PLAN2_DEPT"         = "Visio Plan 2"

    # Additional mappings for common SKUs
    "INTUNE_A"                 = "Intune"
    "Microsoft_Entra_Suite"    = "Microsoft Entra ID P1"
    "MCOMEETADV"               = "Teams Audio Conferencing"
    "MCOSTANDARD"              = "Teams Phone Standard"
    "MCOPSTN1"                 = "Teams Domestic Calling Plan"
    "MCOPSTN2"                 = "Teams International Calling Plan"
    "STREAM"                   = "Microsoft Stream"
    "FORMS_PRO"                = "Microsoft Forms Pro"
    "VISIOCLIENT"              = "Visio Online Plan 2"
}

# Get license details
Write-AutomationLog "Retrieving license details..." "Information"
try {
    $subscriptions = Get-MgSubscribedSku -All
    Write-AutomationLog "Retrieved $($subscriptions.Count) subscribed SKUs" "Information"

    $licenseMap = @{}
    foreach ($sub in $subscriptions) {
        $skuPartNumber = $sub.SkuPartNumber
        # Use friendly name if available, otherwise use the SKU part number
        if ($licenseFriendlyNames.ContainsKey($skuPartNumber)) {
            $licenseMap[$sub.SkuId] = $licenseFriendlyNames[$skuPartNumber]
        }
        else {
            $licenseMap[$sub.SkuId] = $skuPartNumber
        }
    }

    Write-AutomationLog "Mapped license details for $($licenseMap.Keys.Count) licenses" "Information"
}
catch {
    Write-AutomationLog "Failed to retrieve license details: $_" "Warning"
    Write-AutomationLog "Continuing with SKU IDs instead of friendly names." "Warning"
    $licenseMap = @{}
}

# Get all member users with licenses and manager information
Write-AutomationLog "Retrieving member users with licenses and manager information..." "Information"
try {
    # Get all member users first
    $allUsers = Get-MgUser -Filter "userType eq 'Member'" -All -Property "id,userPrincipalName,displayName,mail,accountEnabled,department,jobTitle,manager,assignedLicenses,createdDateTime,signInActivity" -ExpandProperty "manager" -ConsistencyLevel "eventual"

    Write-AutomationLog "Retrieved $($allUsers.Count) member users" "Information"

    # Filter locally for users with licenses
    $licensedUsers = $allUsers | Where-Object { $_.AssignedLicenses -and $_.AssignedLicenses.Count -gt 0 }

    Write-AutomationLog "Found $($licensedUsers.Count) licensed member users" "Information"

    # Use the filtered users for further processing
    $allUsers = $licensedUsers
}
catch {
    Write-AutomationLog "Error retrieving users with manager information: $_" "Warning"

    # Try an alternative approach if the first one fails
    try {
        Write-AutomationLog "Trying alternative approach..." "Information"
        $allUsers = Get-MgUser -All -Property "id,userPrincipalName,displayName,mail,userType,accountEnabled,department,jobTitle,assignedLicenses,createdDateTime,signInActivity"

        # Filter locally
        $allUsers = $allUsers | Where-Object { $_.UserType -eq 'Member' -and $_.AssignedLicenses -and $_.AssignedLicenses.Count -gt 0 }
        Write-AutomationLog "Filtered to $($allUsers.Count) licensed member users" "Information"

        # For each user, get their manager separately
        Write-AutomationLog "Retrieving manager information for each user..." "Information"
        $userCount = $allUsers.Count
        $i = 0

        foreach ($user in $allUsers) {
            $i++
            if ($i % 50 -eq 0) {
                Write-AutomationLog "Processed manager info for $i of $userCount users..." "Information"
            }

            try {
                $manager = Get-MgUserManager -UserId $user.Id
                $user | Add-Member -MemberType NoteProperty -Name "Manager" -Value $manager -Force
            }
            catch {
                # User might not have a manager - this is normal, continue processing
                Write-AutomationLog "User $($user.UserPrincipalName) has no manager assigned" "Information"
            }
        }

        Write-AutomationLog "Retrieved $($allUsers.Count) licensed member users using alternative approach" "Information"
    }
    catch {
        Write-AutomationLog "Failed to retrieve users with alternative approach: $_" "Error"
        throw "Unable to retrieve user data from Microsoft Graph"
    }
}

# Filter users who have a manager
$usersWithManager = $allUsers | Where-Object { $_.Manager -ne $null }
Write-AutomationLog "Found $($usersWithManager.Count) licensed member users with managers" "Information"

# Get exclusion group members
$exclusionGroupIds = @()
if (-not [string]::IsNullOrWhiteSpace($ExclusionGroupName)) {
    Write-AutomationLog "Retrieving exclusion group members for '$ExclusionGroupName'..." "Information"
    try {
        $exclusionGroup = Get-MgGroup -Filter "displayName eq '$ExclusionGroupName'" -ErrorAction SilentlyContinue
        if ($exclusionGroup) {
            $exclusionGroupIds = Get-MgGroupMember -GroupId $exclusionGroup.Id -All | Select-Object -ExpandProperty Id
            Write-AutomationLog "Found $($exclusionGroupIds.Count) users in exclusion group '$ExclusionGroupName'" "Information"
        }
        else {
            Write-AutomationLog "Exclusion group '$ExclusionGroupName' not found. Proceeding without exclusions." "Warning"
        }
    }
    catch {
        Write-AutomationLog "Error retrieving exclusion group '$ExclusionGroupName': $_" "Warning"
        Write-AutomationLog "Proceeding without group exclusions." "Warning"
    }
}

# Filter out users in exclusion group
if ($exclusionGroupIds.Count -gt 0) {
    $beforeExclusionFilter = $usersWithManager.Count
    $usersWithManager = $usersWithManager | Where-Object { $_.Id -notin $exclusionGroupIds }
    $excludedCount = $beforeExclusionFilter - $usersWithManager.Count
    Write-AutomationLog "Excluded $excludedCount users that are members of '$ExclusionGroupName'" "Information"
}

# Process users and identify inactive licensed users with managers
Write-AutomationLog "Processing users to identify inactive ones..." "Information"
$inactiveUsers = @()

foreach ($user in $usersWithManager) {
    # Get the last sign-in date from the signInActivity property
    $lastSignInDate = $user.SignInActivity.LastSignInDateTime
    $isInactive = $null -eq $lastSignInDate -or $lastSignInDate -lt $inactiveThreshold

    if ($isInactive) {
        # Get assigned license names
        $licenseNames = @()
        foreach ($license in $user.AssignedLicenses) {
            if ($licenseMap.ContainsKey($license.SkuId)) {
                $licenseNames += $licenseMap[$license.SkuId]
            }
            else {
                $licenseNames += $license.SkuId
            }
        }

        # Check if user has any of the specified licenses
        $hasTargetLicense = $false
        if ($LicensesToCheck.Count -eq 0) {
            # If no specific licenses are specified, consider all licenses
            $hasTargetLicense = $true
        }
        else {
            foreach ($licenseName in $licenseNames) {
                if ($LicensesToCheck -contains $licenseName) {
                    $hasTargetLicense = $true
                    break
                }
            }
        }

        if ($hasTargetLicense) {
            # Get manager details
            $managerDisplayName = "Unknown"
            $managerUPN = "Unknown"
            $managerDepartment = "Unknown"

            try {
                # Check if Manager property exists and has a valid Id
                if ($user.Manager -and -not [string]::IsNullOrEmpty($user.Manager.Id)) {
                    $managerId = $user.Manager.Id
                    $manager = Get-MgUser -UserId $managerId -Property "displayName,userPrincipalName,department"
                    $managerDisplayName = $manager.DisplayName
                    $managerUPN = $manager.UserPrincipalName
                    $managerDepartment = $manager.Department
                }
            }
            catch {
                # Manager details couldn't be retrieved - continue with defaults
                Write-AutomationLog "Could not retrieve manager details for user $($user.UserPrincipalName): $_" "Warning"
            }

            # Format dates properly
            $formattedCreatedDate = if ($user.CreatedDateTime) {
                Get-Date $user.CreatedDateTime -Format "yyyy-MM-dd HH:mm:ss"
            }
            else {
                $null
            }

            $formattedLastSignInDate = if ($lastSignInDate) {
                Get-Date $lastSignInDate -Format "yyyy-MM-dd HH:mm:ss"
            }
            else {
                $null
            }

            $inactiveUsers += [PSCustomObject]@{
                Id                  = $user.Id
                UserPrincipalName   = $user.UserPrincipalName
                DisplayName         = $user.DisplayName
                Email               = $user.Mail
                Department          = $user.Department
                JobTitle            = $user.JobTitle
                AccountEnabled      = $user.AccountEnabled
                CreatedDateTime     = $formattedCreatedDate
                LastSignInDate      = $formattedLastSignInDate
                DaysSinceLastSignIn = if ($lastSignInDate) { [math]::Round(($currentDate - $lastSignInDate).TotalDays) } else { "Never" }
                AssignedLicenses    = ($licenseNames -join ", ")
                ManagerDisplayName  = $managerDisplayName
                ManagerUPN          = $managerUPN
                ManagerDepartment   = $managerDepartment
            }
        }
    }
}

# Output results to Azure Automation logs
$inactiveUserCount = $inactiveUsers.Count
Write-AutomationLog "Found $inactiveUserCount inactive licensed users with managers" "Information"

# Add users to group if group name is specified
$groupResult = $null
if (-not [string]::IsNullOrEmpty($InactiveUsersGroupName) -and $inactiveUserCount -gt 0) {
    Write-AutomationLog "Adding inactive users to group '$InactiveUsersGroupName'..." "Information"
    $userIds = $inactiveUsers | Select-Object -ExpandProperty Id
    $groupResult = Add-UsersToGroup -GroupName $InactiveUsersGroupName -UserIds $userIds
}

if ($inactiveUserCount -gt 0) {
    Write-AutomationLog "`n=== INACTIVE LICENSED USERS WITH MANAGERS ===" "Information"
    Write-AutomationLog "Total inactive users found: $inactiveUserCount" "Information"
    Write-AutomationLog "Inactive threshold: $InactiveDays days (since $inactiveThreshold)" "Information"
    Write-AutomationLog "License types checked: $($LicensesToCheck -join ', ')" "Information"
    Write-AutomationLog "`n--- USER DETAILS ---" "Information"

    # Sort by days inactive (descending) and output each user
    $sortedUsers = $inactiveUsers | Sort-Object -Property DaysSinceLastSignIn -Descending

    foreach ($user in $sortedUsers) {
        $daysInactive = if ($user.DaysSinceLastSignIn -eq "Never") { "Never signed in" } else { "$($user.DaysSinceLastSignIn) days" }

        Write-AutomationLog "User: $($user.DisplayName) ($($user.UserPrincipalName))" "Information"
        Write-AutomationLog "  Department: $($user.Department)" "Information"
        Write-AutomationLog "  Job Title: $($user.JobTitle)" "Information"
        Write-AutomationLog "  Days Inactive: $daysInactive" "Information"
        Write-AutomationLog "  Last Sign-in: $($user.LastSignInDate)" "Information"
        Write-AutomationLog "  Manager: $($user.ManagerDisplayName) ($($user.ManagerUPN))" "Information"
        Write-AutomationLog "  Manager Department: $($user.ManagerDepartment)" "Information"
        Write-AutomationLog "  Licenses: $($user.AssignedLicenses)" "Information"
        Write-AutomationLog "  Account Enabled: $($user.AccountEnabled)" "Information"
        Write-AutomationLog "  Created: $($user.CreatedDateTime)" "Information"
        Write-AutomationLog "  ---" "Information"
    }

    # Summary statistics
    $neverSignedIn = ($inactiveUsers | Where-Object { $_.DaysSinceLastSignIn -eq "Never" }).Count
    $disabledAccounts = ($inactiveUsers | Where-Object { $_.AccountEnabled -eq $false }).Count
    $uniqueDepartments = ($inactiveUsers | Where-Object { $_.Department } | Select-Object -ExpandProperty Department -Unique).Count
    $uniqueManagers = ($inactiveUsers | Where-Object { $_.ManagerDisplayName -ne "Unknown" } | Select-Object -ExpandProperty ManagerDisplayName -Unique).Count

    Write-AutomationLog "`n=== SUMMARY STATISTICS ===" "Information"
    Write-AutomationLog "Total inactive users: $inactiveUserCount" "Information"
    Write-AutomationLog "Users who never signed in: $neverSignedIn" "Information"
    Write-AutomationLog "Disabled accounts: $disabledAccounts" "Information"
    Write-AutomationLog "Unique departments affected: $uniqueDepartments" "Information"
    Write-AutomationLog "Unique managers affected: $uniqueManagers" "Information"

    # Group management summary
    if ($groupResult) {
        Write-AutomationLog "`n--- GROUP MANAGEMENT SUMMARY ---" "Information"
        Write-AutomationLog "Target group: $($groupResult.GroupName) (ID: $($groupResult.GroupId))" "Information"
        Write-AutomationLog "Users removed from group: $($groupResult.RemovedCount)" "Information"
        if ($groupResult.RemoveErrorCount -gt 0) {
            Write-AutomationLog "Users failed to remove: $($groupResult.RemoveErrorCount)" "Warning"
        }
        Write-AutomationLog "Users added to group: $($groupResult.AddedCount)" "Information"
        if ($groupResult.ErrorCount -gt 0) {
            Write-AutomationLog "Users failed to add: $($groupResult.ErrorCount)" "Warning"
        }
    }
    elseif (-not [string]::IsNullOrEmpty($InactiveUsersGroupName)) {
        Write-AutomationLog "`n--- GROUP MANAGEMENT SUMMARY ---" "Information"
        Write-AutomationLog "Group management failed or no users to add to '$InactiveUsersGroupName'" "Warning"
    }

    # Top departments by inactive user count
    $departmentStats = $inactiveUsers | Where-Object { $_.Department } | Group-Object -Property Department | Sort-Object -Property Count -Descending | Select-Object -First 5
    if ($departmentStats) {
        Write-AutomationLog "`n--- TOP DEPARTMENTS BY INACTIVE USER COUNT ---" "Information"
        foreach ($dept in $departmentStats) {
            Write-AutomationLog "$($dept.Name): $($dept.Count) users" "Information"
        }
    }
}
else {
    Write-AutomationLog "No inactive licensed users with managers found." "Information"
}

# Disconnect from Microsoft Graph
Write-AutomationLog "Disconnecting from Microsoft Graph..." "Information"
try {
    Disconnect-MgGraph | Out-Null
    Write-AutomationLog "Disconnected from Microsoft Graph" "Information"
}
catch {
    Write-AutomationLog "Error disconnecting from Microsoft Graph: $_" "Warning"
}

Write-AutomationLog "Azure Automation runbook completed successfully!" "Information"
if ($inactiveUserCount -gt 0) {
    Write-AutomationLog "Review the detailed user list above for inactive licensed users with managers." "Information"
    if (-not [string]::IsNullOrEmpty($InactiveUsersGroupName)) {
        if ($groupResult -and $groupResult.AddedCount -gt 0) {
            Write-AutomationLog "Inactive users have been added to group '$InactiveUsersGroupName' for further management." "Information"
        }
        else {
            Write-AutomationLog "Check the group management summary above for any issues with adding users to '$InactiveUsersGroupName'." "Warning"
        }
    }
}
