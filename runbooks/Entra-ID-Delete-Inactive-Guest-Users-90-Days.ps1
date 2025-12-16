<#
.SYNOPSIS
    Azure Automation runbook to identify and delete inactive guest users in an Entra ID/M365 tenant.
.DESCRIPTION
    This Azure Automation runbook connects to Microsoft Graph using a managed identity and identifies guest users who:
    1. Have been inactive (no sign-in) for the specified number of days
    2. Were created before the inactivity threshold (to avoid acting on newly created accounts)
    3. Are not members of an exclusion group (if specified)
    4. Do not belong to excluded domains

    Inactive guest users are soft deleted. The script supports WhatIf mode for safe testing.
.PARAMETER InactiveDays
    Number of days without activity to consider a user inactive. Default is 90 days.
.PARAMETER ExclusionGroupName
    Name of the group containing users to exclude from the inactive user report. Users in this group will be skipped.
.PARAMETER ExclusionDomainList
    List of domains to exclude from the inactive user report. Guest users with UPNs or email addresses containing domains in this list will be skipped.
.PARAMETER DebugMode
    When set to $true, emits additional diagnostic logging.
.PARAMETER WhatIf
    When set to $true, shows what actions would be taken without actually performing the operations. Default is $true for safety.
.NOTES
    PowerShell 7 Azure Automation runbook

    Requires the following modules to be imported in Azure Automation:
    - Microsoft.Graph.Authentication
    - Microsoft.Graph.Users
    - Microsoft.Graph.Groups

    Requires a system-assigned managed identity with the following Microsoft Graph application permissions:
    - User.Read.All
    - Directory.Read.All
    - Group.Read.All (required for exclusion group operations)
    - User.ReadWrite.All (required for soft delete operations)

    Runtime Version: PowerShell 7.x
#>

param (
    [int]$InactiveDays = 90,
    [string]$ExclusionGroupName = "",
    [string[]]$ExclusionDomainList = @("cityoflondon.police.uk", "freemens.org"),
    [bool]$DebugMode = $false,
    [bool]$WhatIf = $true
)

$ErrorActionPreference = "Stop"

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
        "Error" { Write-Error $logMessage -ErrorAction Continue }
    }
}

function Write-DebugLog {
    param(
        [string]$Message
    )

    if ($DebugMode) {
        Write-AutomationLog "Debug: $Message" "Information"
    }
}

function Get-LastSignInDate {
    param(
        $SignInActivity
    )

    if (-not $SignInActivity) {
        return $null
    }

    $lastSignIn = $null
    $candidateProperties = @(
        "LastSignInDateTime",
        "LastNonInteractiveSignInDateTime",
        "LastSuccessfulSignInDateTime"
    )

    foreach ($property in $candidateProperties) {
        $value = $SignInActivity.$property
        if ([string]::IsNullOrEmpty($value)) {
            continue
        }

        try {
            $candidate = [datetime]$value
            if ($null -eq $lastSignIn -or $candidate -gt $lastSignIn) {
                $lastSignIn = $candidate
            }
        }
        catch {
            Write-DebugLog "Unable to parse sign-in timestamp '$value' for property '$property'"
        }
    }

    return $lastSignIn
}

function Process-InactiveGuestUsers {
    param(
        [array]$InactiveUsers,
        [bool]$WhatIf
    )

    if (-not $InactiveUsers -or $InactiveUsers.Count -eq 0) {
        Write-AutomationLog "No inactive guest users to process" "Information"
        return @{
            ProcessedCount = 0
            SuccessCount   = 0
            ErrorCount     = 0
            Errors         = @()
        }
    }

    $processedCount = 0
    $errorCount = 0
    $errors = @()

    Write-AutomationLog "Processing $($InactiveUsers.Count) inactive guest users for deletion..." "Information"

    if ($WhatIf) {
        Write-AutomationLog "WhatIf mode enabled - no delete operations will be performed" "Information"
    }

    foreach ($user in $InactiveUsers) {
        try {
            if ($WhatIf) {
                Write-AutomationLog "WhatIf: Would delete guest user '$($user.DisplayName)' ($($user.UserPrincipalName)) - Created: $($user.CreatedDate), Last sign-in: $($user.LastSignIn)" "Information"
                $processedCount++
                continue
            }

            # Soft delete - user moves to deleted items, recoverable for 30 days
            Remove-MgUser -UserId $user.Id -Confirm:$false

            Write-AutomationLog "Successfully deleted guest user '$($user.DisplayName)' ($($user.UserPrincipalName)) - Created: $($user.CreatedDate), Last sign-in: $($user.LastSignIn)" "Information"
            $processedCount++
        }
        catch {
            $errorMessage = "Failed to delete guest user '$($user.DisplayName)' ($($user.UserPrincipalName)): $($_.Exception.Message)"
            Write-AutomationLog $errorMessage "Error"
            $errorCount++
            $errors += @{
                User  = $user
                Error = $_.Exception.Message
            }
        }
    }

    Write-AutomationLog "Delete operation complete: $processedCount guest users deleted, $errorCount errors" "Information"

    return @{
        ProcessedCount = $InactiveUsers.Count
        SuccessCount   = $processedCount
        ErrorCount     = $errorCount
        Errors         = $errors
    }
}

Write-AutomationLog "Starting Inactive Guest Users Deletion runbook (Azure Automation)" "Information"
Write-AutomationLog "Inactive threshold: $InactiveDays days" "Information"
Write-AutomationLog "WhatIf mode: $WhatIf" "Information"

Write-AutomationLog "Connecting to Microsoft Graph using managed identity..." "Information"
try {
    Connect-MgGraph -Identity -NoWelcome
    $context = Get-MgContext
    if (-not $context) {
        throw "No Graph context returned"
    }

    Write-AutomationLog "Connected to Microsoft Graph. Tenant ID: $($context.TenantId) | Auth Type: $($context.AuthType)" "Information"
}
catch {
    Write-AutomationLog "Error connecting to Microsoft Graph: $_" "Error"
    throw "Failed to connect to Microsoft Graph. Ensure the managed identity has the required Graph permissions."
}

$currentDate = Get-Date
$inactiveThreshold = $currentDate.AddDays(-$InactiveDays)
$creationThreshold = $currentDate.AddDays(-$InactiveDays)
Write-AutomationLog "Identifying guest users inactive since: $inactiveThreshold" "Information"
Write-AutomationLog "Excluding guest users created after: $creationThreshold" "Information"

Write-AutomationLog "Retrieving guest users with sign-in activity..." "Information"
try {
    $allGuestUsers = Get-MgUser -Filter "userType eq 'Guest'" -All -Property "id,userPrincipalName,displayName,mail,userType,signInActivity,accountEnabled,createdDateTime" -ConsistencyLevel "eventual"
    Write-AutomationLog "Retrieved $($allGuestUsers.Count) guest users" "Information"
}
catch {
    Write-AutomationLog "Error retrieving guest users with server-side filter: $_" "Warning"
    Write-AutomationLog "Attempting alternative retrieval with client-side filtering..." "Information"

    try {
        $allGuestUsers = Get-MgUser -All -Property "id,userPrincipalName,displayName,mail,userType,signInActivity,accountEnabled,createdDateTime" -ConsistencyLevel "eventual" | Where-Object { $_.UserType -eq 'Guest' }
        Write-AutomationLog "Retrieved $($allGuestUsers.Count) guest users via alternative approach" "Information"
    }
    catch {
        Write-AutomationLog "Failed to retrieve guest users with alternative approach: $_" "Error"
        throw "Unable to retrieve guest user data from Microsoft Graph."
    }
}

Write-AutomationLog "Applying creation date filter..." "Information"
$beforeCreationFilter = $allGuestUsers.Count
$allGuestUsers = $allGuestUsers | Where-Object {
    if ($_.CreatedDateTime) {
        $created = [datetime]$_.CreatedDateTime
        if ($created -lt $creationThreshold) {
            return $true
        }

        Write-DebugLog "Excluding recently created guest '$($_.UserPrincipalName)' - created $($created.ToString('yyyy-MM-dd'))"
        return $false
    }

    Write-AutomationLog "No creation date found for guest '$($_.UserPrincipalName)' - including by default" "Warning"
    return $true
}
$excludedCreation = $beforeCreationFilter - $allGuestUsers.Count
Write-AutomationLog "Excluded $excludedCreation guest users created within the last $InactiveDays days" "Information"

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
            Write-AutomationLog "Exclusion group '$ExclusionGroupName' not found. Proceeding without group exclusions." "Warning"
        }
    }
    catch {
        Write-AutomationLog "Error retrieving exclusion group '$ExclusionGroupName': $_" "Warning"
        Write-AutomationLog "Proceeding without group exclusions." "Warning"
    }
}

if ($exclusionGroupIds.Count -gt 0) {
    $beforeGroupFilter = $allGuestUsers.Count
    $allGuestUsers = $allGuestUsers | Where-Object { $_.Id -notin $exclusionGroupIds }
    $excludedGroupCount = $beforeGroupFilter - $allGuestUsers.Count
    Write-AutomationLog "Excluded $excludedGroupCount guest users that are members of '$ExclusionGroupName'" "Information"
}

if ($ExclusionDomainList.Count -gt 0) {
    $normalizedDomains = $ExclusionDomainList | ForEach-Object { ($_ -as [string]).Trim().ToLower() } | Where-Object { $_ -ne "" } | Select-Object -Unique
    if ($normalizedDomains.Count -gt 0) {
        $beforeDomainFilter = $allGuestUsers.Count
        $filteredUsers = @()

        foreach ($user in $allGuestUsers) {
            $upnLower = ($user.UserPrincipalName -as [string]).ToLower()
            $mailLower = if ($user.Mail) { ($user.Mail -as [string]).ToLower() } else { "" }
            $excludeUser = $false

            foreach ($domain in $normalizedDomains) {
                if ($upnLower -like "*$domain*" -or ($mailLower -and $mailLower -like "*$domain*")) {
                    $excludeUser = $true
                    Write-DebugLog "Excluding guest '$($user.UserPrincipalName)' due to domain match '$domain'"
                    break
                }
            }

            if (-not $excludeUser) {
                $filteredUsers += $user
            }
        }

        $allGuestUsers = $filteredUsers
        $excludedDomains = $beforeDomainFilter - $allGuestUsers.Count
        Write-AutomationLog "Excluded $excludedDomains guest users from domains: $($normalizedDomains -join ', ')" "Information"
    }
}

$inactiveUsers = @()

foreach ($user in $allGuestUsers) {
    $lastSignIn = Get-LastSignInDate -SignInActivity $user.SignInActivity
    if ($null -eq $lastSignIn -or $lastSignIn -lt $inactiveThreshold) {
        $createdDateFormatted = if ($user.CreatedDateTime) { ([datetime]$user.CreatedDateTime).ToString("yyyy-MM-dd") } else { "Unknown" }
        $lastSignInFormatted = if ($lastSignIn) { $lastSignIn.ToString("yyyy-MM-dd HH:mm:ss") } else { "Never" }

        $inactiveUsers += [pscustomobject]@{
            Id                = $user.Id
            UserPrincipalName = $user.UserPrincipalName
            DisplayName       = $user.DisplayName
            Email             = $user.Mail
            CreatedDate       = $createdDateFormatted
            LastSignIn        = $lastSignInFormatted
        }
    }
}

$inactiveCount = $inactiveUsers.Count
Write-AutomationLog "Found $inactiveCount inactive guest users (inactive >= $InactiveDays days)" "Information"

if ($inactiveCount -gt 0) {
    Write-AutomationLog "Inactive guest user sample (up to 10 entries):" "Information"
    $inactiveUsers | Select-Object DisplayName, UserPrincipalName, LastSignIn, CreatedDate | Select-Object -First 10 | ForEach-Object {
        Write-AutomationLog "- $($_.DisplayName) ($($_.UserPrincipalName)) | Last sign-in: $($_.LastSignIn) | Created: $($_.CreatedDate)" "Information"
    }

    Write-AutomationLog "Emitting full inactive guest user list to the job output stream" "Information"
    $inactiveUsers

    $result = Process-InactiveGuestUsers -InactiveUsers $inactiveUsers -WhatIf:$WhatIf
    Write-AutomationLog "Processing summary: processed=$($result.ProcessedCount); successful=$($result.SuccessCount); errors=$($result.ErrorCount)" "Information"

    if ($result.ErrorCount -gt 0) {
        Write-AutomationLog "Processing errors encountered:" "Warning"
        foreach ($err in $result.Errors) {
            Write-AutomationLog "- $($err.User.DisplayName) ($($err.User.UserPrincipalName)): $($err.Error)" "Warning"
        }
    }
}
else {
    Write-AutomationLog "No inactive guest users found - no action required" "Information"
}

Write-AutomationLog "Runbook execution complete" "Information"
