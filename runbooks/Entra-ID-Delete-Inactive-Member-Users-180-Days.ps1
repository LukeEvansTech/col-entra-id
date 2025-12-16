<#
.SYNOPSIS
    Azure Automation runbook to identify and delete inactive disabled member users in an Entra ID/M365 tenant.
.DESCRIPTION
    This Azure Automation runbook connects to Microsoft Graph using a managed identity and identifies disabled member users who:
    1. Have been inactive (no sign-in) for the specified number of days (default 180)
    2. Were created before the inactivity threshold (to avoid acting on newly created accounts)
    3. Are not members of an exclusion group (if specified)
    4. Do not belong to excluded departments or domains
    5. (Optional) Hold at least one license from a provided include list

    This runbook is designed as a follow-up to the 90-day disable runbook - it targets users that were
    previously disabled and soft deletes them after 180 days of total inactivity.

    The script supports WhatIf mode for safe testing.
.PARAMETER InactiveDays
    Number of days without activity to consider a user inactive. Default is 180 days.
.PARAMETER ExclusionGroupName
    Name of the group containing users to exclude from the inactive user report. Users in this group will be skipped.
.PARAMETER ExclusionDomainList
    List of domains to exclude from the inactive user report. Users with UPNs or email addresses containing domains in this list will be skipped.
.PARAMETER ExclusionDepartmentList
    List of department values to exclude from the inactive user report. Users with departments in this list will be skipped.
.PARAMETER DebugMode
    When set to $true, emits additional diagnostic logging.
.PARAMETER LicensesToInclude
    Array of friendly license names to include in the inactive user check. Only users with at least one of these licenses will be processed.
.PARAMETER WhatIf
    When set to $true, shows what actions would be taken without actually performing the operations. Default is $true for safety.
.NOTES
    PowerShell 7 Azure Automation runbook

    Requires the following modules to be imported in Azure Automation:
    - Microsoft.Graph.Authentication
    - Microsoft.Graph.Users
    - Microsoft.Graph.Groups
    - Microsoft.Graph.Identity.DirectoryManagement

    Requires a system-assigned managed identity with the following Microsoft Graph application permissions:
    - User.Read.All
    - Directory.Read.All
    - Group.Read.All (required for exclusion group operations)
    - User.ReadWrite.All (required for soft delete operations)

    Runtime Version: PowerShell 7.x
#>

param (
    [int]$InactiveDays = 180,
    [string]$ExclusionGroupName = "Line Manager - Inactive User Review - Exclusion",
    [string[]]$ExclusionDomainList = @("cityoflondon.police.uk", "freemens.org"),
    [string[]]$ExclusionDepartmentList = @("Members"),
    [bool]$DebugMode = $false,
    [string[]]$LicensesToInclude = @(
        "Microsoft 365 E5",
        "Microsoft 365 E3",
        "Microsoft 365 F1",
        "Microsoft 365 F5 Security Compliance",
        "Office 365 E5",
        "Office 365 E3",
        "Office 365 F1"
    ),
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

function Get-LicenseMap {
    param(
        [hashtable]$FriendlyNames
    )

    $map = @{}

    try {
        $subscriptions = Get-MgSubscribedSku -All
        foreach ($sub in $subscriptions) {
            $skuPartNumber = $sub.SkuPartNumber
            $displayName = if ($FriendlyNames.ContainsKey($skuPartNumber)) {
                $FriendlyNames[$skuPartNumber]
            }
            else {
                $skuPartNumber
            }

            $map[$sub.SkuId] = [pscustomobject]@{
                DisplayName   = $displayName
                SkuPartNumber = $skuPartNumber
            }
        }

        Write-AutomationLog "Retrieved license mapping for $(($map.Keys).Count) licenses" "Information"
    }
    catch {
        Write-AutomationLog "Failed to retrieve license details: $_" "Warning"
    }

    return $map
}

function Get-LicenseTokens {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SkuId,
        [hashtable]$LicenseMap
    )

    $tokens = @()

    if ($LicenseMap -and $LicenseMap.ContainsKey($SkuId)) {
        $info = $LicenseMap[$SkuId]
        if ($info.DisplayName) {
            $tokens += $info.DisplayName
        }
        if ($info.SkuPartNumber) {
            $tokens += $info.SkuPartNumber
        }
    }

    if ($SkuId) {
        $tokens += $SkuId.ToString()
    }

    return $tokens | ForEach-Object { ($_ -as [string]) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
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

function Process-InactiveMemberUsers {
    param(
        [array]$InactiveUsers,
        [bool]$WhatIf
    )

    if (-not $InactiveUsers -or $InactiveUsers.Count -eq 0) {
        Write-AutomationLog "No inactive users to process" "Information"
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

    Write-AutomationLog "Processing $($InactiveUsers.Count) inactive disabled member users for deletion..." "Information"

    if ($WhatIf) {
        Write-AutomationLog "WhatIf mode enabled - no delete operations will be performed" "Information"
    }

    foreach ($user in $InactiveUsers) {
        try {
            if ($WhatIf) {
                Write-AutomationLog "WhatIf: Would delete user '$($user.DisplayName)' ($($user.UserPrincipalName)) - Created: $($user.CreatedDate), Last sign-in: $($user.LastSignIn)" "Information"
                $processedCount++
                continue
            }

            # Soft delete - user moves to deleted items, recoverable for 30 days
            Remove-MgUser -UserId $user.Id -Confirm:$false

            Write-AutomationLog "Successfully deleted user '$($user.DisplayName)' ($($user.UserPrincipalName)) - Created: $($user.CreatedDate), Last sign-in: $($user.LastSignIn)" "Information"
            $processedCount++
        }
        catch {
            $errorMessage = "Failed to delete user '$($user.DisplayName)' ($($user.UserPrincipalName)): $($_.Exception.Message)"
            Write-AutomationLog $errorMessage "Error"
            $errorCount++
            $errors += @{
                User  = $user
                Error = $_.Exception.Message
            }
        }
    }

    Write-AutomationLog "Delete operation complete: $processedCount users deleted, $errorCount errors" "Information"

    return @{
        ProcessedCount = $InactiveUsers.Count
        SuccessCount   = $processedCount
        ErrorCount     = $errorCount
        Errors         = $errors
    }
}

# Friendly license names (friendly name -> human readable)
$licenseFriendlyNames = @{
    "SPE_F1"                   = "Microsoft 365 F1"
    "SPE_F5_SECCOMP"           = "Microsoft 365 F5 Security Compliance"
    "SPE_E3"                   = "Microsoft 365 E3"
    "SPE_E5"                   = "Microsoft 365 E5"
    "M365_F1"                  = "Microsoft 365 F1"
    "M365_E3"                  = "Microsoft 365 E3"
    "M365_E5"                  = "Microsoft 365 E5"
    "M365_E5_SUITE_COMPONENTS" = "Microsoft 365 E5 Components"
    "STANDARDPACK"             = "Office 365 E1"
    "ENTERPRISEPACK"           = "Office 365 E3"
    "ENTERPRISEPREMIUM"        = "Office 365 E5"
    "DESKLESSPACK"             = "Office 365 F1"
    "DESKLESSPACK_YAMMER"      = "Office 365 F1"
    "OFFICESUBSCRIPTION"       = "Office 365 ProPlus"
    "EMS"                      = "Enterprise Mobility + Security E3"
    "EMSPREMIUM"               = "Enterprise Mobility + Security E5"
    "WIN10_VDA_E3"             = "Windows 10 Enterprise E3"
    "WIN10_VDA_E5"             = "Windows 10 Enterprise E5"
    "WIN_DEF_ATP"              = "Microsoft Defender for Endpoint"
    "POWERAPPS_PER_APP"        = "Power Apps Per App"
    "FLOW_FREE"                = "Power Automate Free"
    "POWERBI_STANDARD"         = "Power BI Free"
    "FORMS_PRO"                = "Forms Pro"
    "MCOCAP"                   = "Common Area Phone"
    "PHONESYSTEM_VIRTUALUSER"  = "Phone System - Virtual User"
    "TEAMS_COMMERCIAL_TRIAL"   = "Teams Commercial Trial"
    "STREAM"                   = "Stream"
    "PROJECTPREMIUM"           = "Project Premium"
    "VISIOCLIENT"              = "Visio Online Plan 2"
}

Write-AutomationLog "Starting Inactive Member Users Deletion runbook (Azure Automation)" "Information"
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
Write-AutomationLog "Identifying users inactive since: $inactiveThreshold" "Information"
Write-AutomationLog "Excluding users created after: $creationThreshold" "Information"

Write-AutomationLog "Retrieving disabled member users with sign-in activity..." "Information"
try {
    $allMemberUsers = Get-MgUser -Filter "userType eq 'Member' and accountEnabled eq false" -All -Property "id,userPrincipalName,displayName,mail,userType,signInActivity,accountEnabled,assignedLicenses,createdDateTime,department" -ConsistencyLevel "eventual"
    Write-AutomationLog "Retrieved $($allMemberUsers.Count) disabled member users" "Information"

    $beforeCtsFilter = $allMemberUsers.Count
    $allMemberUsers = $allMemberUsers | Where-Object { -not ($_.UserPrincipalName -match '#EXT#') }
    $removedCts = $beforeCtsFilter - $allMemberUsers.Count
    if ($removedCts -gt 0) {
        Write-AutomationLog "Filtered out $removedCts Cross-Tenant Sync users with '#EXT#' in UPN" "Information"
    }
}
catch {
    Write-AutomationLog "Error retrieving member users with server-side filter: $_" "Warning"
    Write-AutomationLog "Attempting alternative retrieval with client-side filtering..." "Information"

    try {
        $allMemberUsers = Get-MgUser -All -Property "id,userPrincipalName,displayName,mail,userType,signInActivity,accountEnabled,assignedLicenses,createdDateTime,department" -ConsistencyLevel "eventual" | Where-Object { $_.UserType -eq 'Member' -and $_.AccountEnabled -eq $false }
        Write-AutomationLog "Retrieved $($allMemberUsers.Count) disabled member users via alternative approach" "Information"

        $beforeCtsFilter = $allMemberUsers.Count
        $allMemberUsers = $allMemberUsers | Where-Object { -not ($_.UserPrincipalName -match '#EXT#') }
        $removedCts = $beforeCtsFilter - $allMemberUsers.Count
        if ($removedCts -gt 0) {
            Write-AutomationLog "Filtered out $removedCts Cross-Tenant Sync users with '#EXT#' in UPN (alternative)" "Information"
        }
    }
    catch {
        Write-AutomationLog "Failed to retrieve member users with alternative approach: $_" "Error"
        throw "Unable to retrieve member user data from Microsoft Graph."
    }
}

Write-AutomationLog "Applying creation date filter..." "Information"
$beforeCreationFilter = $allMemberUsers.Count
$allMemberUsers = $allMemberUsers | Where-Object {
    if ($_.CreatedDateTime) {
        $created = [datetime]$_.CreatedDateTime
        if ($created -lt $creationThreshold) {
            return $true
        }

        Write-DebugLog "Excluding recently created user '$($_.UserPrincipalName)' - created $($created.ToString('yyyy-MM-dd'))"
        return $false
    }

    Write-AutomationLog "No creation date found for user '$($_.UserPrincipalName)' - including by default" "Warning"
    return $true
}
$excludedCreation = $beforeCreationFilter - $allMemberUsers.Count
Write-AutomationLog "Excluded $excludedCreation users created within the last $InactiveDays days" "Information"

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
    $beforeGroupFilter = $allMemberUsers.Count
    $allMemberUsers = $allMemberUsers | Where-Object { $_.Id -notin $exclusionGroupIds }
    $excludedGroupCount = $beforeGroupFilter - $allMemberUsers.Count
    Write-AutomationLog "Excluded $excludedGroupCount users that are members of '$ExclusionGroupName'" "Information"
}

if ($ExclusionDepartmentList.Count -gt 0) {
    $normalizedDepartments = $ExclusionDepartmentList | ForEach-Object { ($_ -as [string]).Trim().ToLower() } | Where-Object { $_ -ne "" } | Select-Object -Unique
    if ($normalizedDepartments.Count -gt 0) {
        $beforeDepartmentFilter = $allMemberUsers.Count
        $allMemberUsers = $allMemberUsers | Where-Object {
            $dept = if ($_.Department) { ($_.Department -as [string]).Trim().ToLower() } else { "" }
            $shouldExclude = $normalizedDepartments -contains $dept
            if ($shouldExclude) {
                Write-DebugLog "Excluding user '$($_.UserPrincipalName)' due to department '$dept'"
            }
            return -not $shouldExclude
        }

        $excludedDepartments = $beforeDepartmentFilter - $allMemberUsers.Count
        Write-AutomationLog "Excluded $excludedDepartments users with departments: $($normalizedDepartments -join ', ')" "Information"
    }
}

if ($ExclusionDomainList.Count -gt 0) {
    $normalizedDomains = $ExclusionDomainList | ForEach-Object { ($_ -as [string]).Trim().ToLower() } | Where-Object { $_ -ne "" } | Select-Object -Unique
    if ($normalizedDomains.Count -gt 0) {
        $beforeDomainFilter = $allMemberUsers.Count
        $filteredUsers = @()

        foreach ($user in $allMemberUsers) {
            $upnLower = ($user.UserPrincipalName -as [string]).ToLower()
            $mailLower = if ($user.Mail) { ($user.Mail -as [string]).ToLower() } else { "" }
            $excludeUser = $false

            foreach ($domain in $normalizedDomains) {
                if ($upnLower -like "*$domain*" -or ($mailLower -and $mailLower -like "*$domain*")) {
                    $excludeUser = $true
                    Write-DebugLog "Excluding user '$($user.UserPrincipalName)' due to domain match '$domain'"
                    break
                }
            }

            if (-not $excludeUser) {
                $filteredUsers += $user
            }
        }

        $allMemberUsers = $filteredUsers
        $excludedDomains = $beforeDomainFilter - $allMemberUsers.Count
        Write-AutomationLog "Excluded $excludedDomains users from domains: $($normalizedDomains -join ', ')" "Information"
    }
}

$licenseMap = @{}
if ($LicensesToInclude.Count -gt 0) {
    Write-AutomationLog "Applying license include filter..." "Information"
    $licenseMapResult = Get-LicenseMap -FriendlyNames $licenseFriendlyNames
    if ($licenseMapResult -is [hashtable]) {
        $licenseMap = $licenseMapResult
    }
    elseif ($licenseMapResult -is [System.Collections.IEnumerable]) {
        foreach ($item in $licenseMapResult) {
            if ($item -is [hashtable]) {
                $licenseMap = $item
            }
        }
    }

    if (-not $licenseMap) {
        $licenseMap = @{}
    }

    if (-not $licenseMap -or $licenseMap.Count -eq 0) {
        Write-AutomationLog "License mapping unavailable. Skipping license include filter." "Warning"
    }
    else {
        $beforeLicenseFilter = $allMemberUsers.Count
        $licensedUsers = @()
        $licenseStats = @{}

        foreach ($user in $allMemberUsers) {
            $hasTargetLicense = $false
            $userLicenseNames = @()

            foreach ($assigned in ($user.AssignedLicenses | ForEach-Object { $_ })) {
                $licenseInfo = if ($licenseMap.ContainsKey($assigned.SkuId)) { $licenseMap[$assigned.SkuId] } else { $null }
                $displayName = if ($licenseInfo) { $licenseInfo.DisplayName } else { $assigned.SkuId.ToString() }

                $userLicenseNames += $displayName

                if (-not $licenseStats.ContainsKey($displayName)) {
                    $licenseStats[$displayName] = 0
                }
                $licenseStats[$displayName]++

                $tokens = Get-LicenseTokens -SkuId $assigned.SkuId -LicenseMap $licenseMap
                foreach ($token in $tokens) {
                    if ($LicensesToInclude -contains $token) {
                        $hasTargetLicense = $true
                        break
                    }
                }

                if ($hasTargetLicense) {
                    break
                }
            }

            if ($hasTargetLicense) {
                $licensedUsers += $user
                Write-DebugLog "Including user '$($user.DisplayName)' with licenses: $($userLicenseNames -join ', ')"
            }
            else {
                Write-DebugLog "Excluding user '$($user.DisplayName)' - licenses: $($userLicenseNames -join ', ')"
            }
        }

        $allMemberUsers = $licensedUsers
        $excludedByLicense = $beforeLicenseFilter - $allMemberUsers.Count
        Write-AutomationLog "License include filter results: $beforeLicenseFilter -> $($allMemberUsers.Count) users (excluded $excludedByLicense)" "Information"

        if ($licenseStats.Count -gt 0) {
            Write-AutomationLog "License distribution among filtered users:" "Information"
            $licenseStats.GetEnumerator() | Sort-Object Name | ForEach-Object {
                if ($LicensesToInclude -contains $_.Name) {
                    Write-AutomationLog "- $($_.Name): $($_.Value) users" "Information"
                }
            }
        }
    }
}

$inactiveUsers = @()

foreach ($user in $allMemberUsers) {
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
Write-AutomationLog "Found $inactiveCount inactive disabled member users (inactive >= $InactiveDays days)" "Information"

if ($inactiveCount -gt 0) {
    Write-AutomationLog "Inactive user sample (up to 10 entries):" "Information"
    $inactiveUsers | Select-Object DisplayName, UserPrincipalName, LastSignIn, CreatedDate | Select-Object -First 10 | ForEach-Object {
        Write-AutomationLog "- $($_.DisplayName) ($($_.UserPrincipalName)) | Last sign-in: $($_.LastSignIn) | Created: $($_.CreatedDate)" "Information"
    }

    Write-AutomationLog "Emitting full inactive user list to the job output stream" "Information"
    $inactiveUsers

    $result = Process-InactiveMemberUsers -InactiveUsers $inactiveUsers -WhatIf:$WhatIf
    Write-AutomationLog "Processing summary: processed=$($result.ProcessedCount); successful=$($result.SuccessCount); errors=$($result.ErrorCount)" "Information"

    if ($result.ErrorCount -gt 0) {
        Write-AutomationLog "Processing errors encountered:" "Warning"
        foreach ($err in $result.Errors) {
            Write-AutomationLog "- $($err.User.DisplayName) ($($err.User.UserPrincipalName)): $($err.Error)" "Warning"
        }
    }
}
else {
    Write-AutomationLog "No inactive disabled member users found - no action required" "Information"
}

Write-AutomationLog "Runbook execution complete" "Information"
