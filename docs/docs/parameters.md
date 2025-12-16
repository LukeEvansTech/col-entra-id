# Parameters Reference

## Common Parameters

These parameters are available across all runbooks:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `InactiveDays` | int | Varies | Number of days without sign-in to consider inactive |
| `ExclusionGroupName` | string | See below | Security group whose members are excluded |
| `ExclusionDomainList` | string[] | See below | Domains to exclude (matches UPN and email) |
| `DebugMode` | bool | `$false` | Enable verbose diagnostic logging |
| `WhatIf` | bool | `$true` | Preview mode - no changes made |

## Member Runbook Parameters

### Entra-ID-Disable-Inactive-Member-Users-90-Days.ps1

| Parameter | Default |
|-----------|---------|
| `InactiveDays` | `90` |
| `ExclusionGroupName` | `"Line Manager - Inactive User Review - Exclusion"` |
| `ExclusionDomainList` | `@("cityoflondon.police.uk", "freemens.org")` |
| `ExclusionDepartmentList` | `@("Members")` |
| `LicensesToInclude` | See license list below |
| `UserAction` | `"Disable"` |
| `WhatIf` | `$false` |

### Entra-ID-Delete-Inactive-Member-Users-180-Days.ps1

| Parameter | Default |
|-----------|---------|
| `InactiveDays` | `180` |
| `ExclusionGroupName` | `"Line Manager - Inactive User Review - Exclusion"` |
| `ExclusionDomainList` | `@("cityoflondon.police.uk", "freemens.org")` |
| `ExclusionDepartmentList` | `@("Members")` |
| `LicensesToInclude` | See license list below |
| `WhatIf` | `$true` |

!!! note
    This runbook targets **disabled** member users (`accountEnabled eq false`) - users that were previously disabled by the 90-day runbook.

## Guest Runbook Parameters

### Entra-ID-Delete-Inactive-Guest-Users-90-Days.ps1

| Parameter | Default |
|-----------|---------|
| `InactiveDays` | `90` |
| `ExclusionGroupName` | `""` (empty) |
| `ExclusionDomainList` | `@("cityoflondon.police.uk", "freemens.org")` |
| `WhatIf` | `$true` |

!!! info
    Guest runbooks do not include license or department filtering as these typically don't apply to guest accounts.

## License Include List

Default licenses checked (member runbooks only):

```powershell
$LicensesToInclude = @(
    "Microsoft 365 E5",
    "Microsoft 365 E3",
    "Microsoft 365 F1",
    "Microsoft 365 F5 Security Compliance",
    "Office 365 E5",
    "Office 365 E3",
    "Office 365 F1"
)
```

Pass an empty array to disable license filtering:

```powershell
-LicensesToInclude @()
```

## UserAction Values

| Value | Description |
|-------|-------------|
| `Disable` | Sets `accountEnabled` to `$false` |
| `SoftDelete` | Moves user to deleted items (recoverable for 30 days) |

## Examples

### Preview inactive members (safe mode)

```powershell
.\Entra-ID-Disable-Inactive-Member-Users-90-Days.ps1 -WhatIf $true
```

### Disable members inactive for 90 days

```powershell
.\Entra-ID-Disable-Inactive-Member-Users-90-Days.ps1 -WhatIf $false
```

### Delete members inactive for 180 days

```powershell
.\Entra-ID-Delete-Inactive-Member-Users-180-Days.ps1 -WhatIf $false
```

### Delete guests inactive for 90 days

```powershell
.\Entra-ID-Delete-Inactive-Guest-Users-90-Days.ps1 -WhatIf $false
```

### Exclude additional domain

```powershell
.\Entra-ID-Disable-Inactive-Member-Users-90-Days.ps1 `
    -ExclusionDomainList @("cityoflondon.police.uk", "freemens.org", "contractor.com")
```

### Process all licensed users (no license filter)

```powershell
.\Entra-ID-Disable-Inactive-Member-Users-90-Days.ps1 -LicensesToInclude @()
```

### Enable debug logging

```powershell
.\Entra-ID-Disable-Inactive-Member-Users-90-Days.ps1 -DebugMode $true -WhatIf $true
```

## Azure Automation Schedule Parameters

When creating a schedule in Azure Automation, specify parameters as:

| Parameter | Value |
|-----------|-------|
| INACTIVEDAYS | `90` |
| WHATIF | `false` |
| DEBUGMODE | `false` |

!!! note
    Azure Automation converts parameter names to uppercase.
