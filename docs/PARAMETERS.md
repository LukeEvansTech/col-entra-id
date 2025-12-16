# Runbook Parameters Reference

## Common Parameters

These parameters are available across all runbooks:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `InactiveDays` | int | 90 | Number of days without sign-in to consider inactive |
| `ExclusionGroupName` | string | See below | Security group whose members are excluded |
| `ExclusionDomainList` | string[] | See below | Domains to exclude (matches UPN and email) |
| `ExclusionDepartmentList` | string[] | `@("Members")` | Department values to exclude |
| `DebugMode` | bool | `$false` | Enable verbose diagnostic logging |
| `WhatIf` | bool | `$true` | Preview mode - no changes made |

## Member Runbook Parameters

### Disable-InactiveMembers.ps1

| Parameter | Default |
|-----------|---------|
| `ExclusionGroupName` | `"Line Manager - Inactive User Review - Exclusion"` |
| `ExclusionDomainList` | `@("cityoflondon.police.uk", "freemens.org")` |
| `LicensesToInclude` | See license list below |
| `UserAction` | `"Disable"` |

### Delete-InactiveMembers.ps1

| Parameter | Default |
|-----------|---------|
| `UserAction` | `"SoftDelete"` |

## Guest Runbook Parameters

### Disable-InactiveGuests.ps1 / Delete-InactiveGuests.ps1

Guest runbooks filter on `userType eq 'Guest'` and may have different default exclusions.

## License Include List

Default licenses checked (member runbooks):

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
.\Disable-InactiveMembers.ps1 -InactiveDays 90 -WhatIf $true
```

### Disable members inactive for 180 days
```powershell
.\Disable-InactiveMembers.ps1 -InactiveDays 180 -WhatIf $false
```

### Exclude additional domain
```powershell
.\Disable-InactiveMembers.ps1 -ExclusionDomainList @("cityoflondon.police.uk", "freemens.org", "contractor.com")
```

### Process all licensed users (no license filter)
```powershell
.\Disable-InactiveMembers.ps1 -LicensesToInclude @()
```

### Enable debug logging
```powershell
.\Disable-InactiveMembers.ps1 -DebugMode $true -WhatIf $true
```

## Azure Automation Schedule Parameters

When creating a schedule in Azure Automation, specify parameters as:

| Parameter | Value |
|-----------|-------|
| INACTIVEDAYS | `90` |
| WHATIF | `false` |
| DEBUGMODE | `false` |

> **Note**: Azure Automation converts parameter names to uppercase.
