param(
  [Parameter(Mandatory = $true)]
  [string]$InputPath,
  [string]$OutputPath = '',
  [string]$OutJson = '',
  [Parameter(Mandatory = $true)]
  [string]$PlayerId,
  [string[]]$AddRoles = @(),
  [string[]]$RemoveRoles = @(),
  [string[]]$SetRoles = @(),
  [switch]$Clear,
  [switch]$DeleteWhenEmpty,
  [string]$RoleSetupPath = '',
  [switch]$AllowUnknownRoles
)

$ErrorActionPreference = 'Stop'

$uuidRegex = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'

function Test-RoleName {
  param([string]$Name)
  return $Name -and $Name.Length -le 64 -and $Name -notmatch '[\x00-\x1F/\\]'
}

function Add-UniqueRole {
  param(
    [System.Collections.Generic.List[string]]$Roles,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if (!(Test-RoleName $Name)) {
    throw "Invalid role name: $Name"
  }
  foreach ($role in $Roles) {
    if ([string]::Equals($role, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
      return
    }
  }
  $Roles.Add($Name)
}

function Read-AssignableRoles {
  param([string]$Path)

  $names = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
  if (!$Path) {
    return $names
  }

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if (!(Test-Path -LiteralPath $fullPath)) {
    throw "Role setup file does not exist: $fullPath"
  }
  $setup = Get-Content -Raw -LiteralPath $fullPath | ConvertFrom-Json
  foreach ($role in @($setup.roles)) {
    if ($null -ne $role -and ($role.PSObject.Properties.Name -contains 'name') -and [string]$role.name) {
      [void]$names.Add([string]$role.name)
    }
  }
  return $names
}

function Assert-KnownRole {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)]$KnownRoles
  )

  if (!$AllowUnknownRoles -and $KnownRoles.Count -gt 0 -and !$KnownRoles.Contains($Name)) {
    throw "Role '$Name' is not present in RoleSetup2 roles[]"
  }
}

if ($PlayerId -notmatch $uuidRegex) {
  throw "PlayerId must be a UUID: $PlayerId"
}

if (!$Clear -and @($AddRoles).Count -eq 0 -and @($RemoveRoles).Count -eq 0 -and @($SetRoles).Count -eq 0) {
  throw 'At least one role operation must be supplied'
}

$inputFullPath = [System.IO.Path]::GetFullPath($InputPath)
if (!(Test-Path -LiteralPath $inputFullPath)) {
  throw "Input RoleAssignments.json does not exist: $inputFullPath"
}

$knownRoles = Read-AssignableRoles -Path $RoleSetupPath
foreach ($role in @($AddRoles + $RemoveRoles + $SetRoles)) {
  if ($role) {
    if (!(Test-RoleName $role)) {
      throw "Invalid role name: $role"
    }
    Assert-KnownRole -Name $role -KnownRoles $knownRoles
  }
}

$document = Get-Content -Raw -LiteralPath $inputFullPath | ConvertFrom-Json
if (!($document.PSObject.Properties.Name -contains 'savedPlayerRoles') -or $null -eq $document.savedPlayerRoles) {
  Add-Member -InputObject $document -NotePropertyName savedPlayerRoles -NotePropertyValue ([pscustomobject]@{}) -Force
}

$recordProperty = $document.savedPlayerRoles.PSObject.Properties[$PlayerId]
if ($null -eq $recordProperty) {
  $record = [pscustomobject]@{ roles = @() }
  Add-Member -InputObject $document.savedPlayerRoles -NotePropertyName $PlayerId -NotePropertyValue $record -Force
} else {
  $record = $recordProperty.Value
}

if (!($record.PSObject.Properties.Name -contains 'roles') -or $null -eq $record.roles) {
  Add-Member -InputObject $record -NotePropertyName roles -NotePropertyValue @() -Force
}

$beforeRoles = @($record.roles | ForEach-Object { [string]$_ })
$roles = New-Object System.Collections.Generic.List[string]

if (@($SetRoles).Count -gt 0) {
  foreach ($role in @($SetRoles)) {
    if ($role) { Add-UniqueRole -Roles $roles -Name $role }
  }
} else {
  foreach ($role in $beforeRoles) {
    if ($role) { Add-UniqueRole -Roles $roles -Name $role }
  }
}

if ($Clear) {
  $roles.Clear()
}

foreach ($remove in @($RemoveRoles)) {
  $next = New-Object System.Collections.Generic.List[string]
  foreach ($role in $roles) {
    if (![string]::Equals($role, $remove, [System.StringComparison]::OrdinalIgnoreCase)) {
      $next.Add($role)
    }
  }
  $roles = $next
}

foreach ($role in @($AddRoles)) {
  if ($role) { Add-UniqueRole -Roles $roles -Name $role }
}

$afterRoles = @($roles.ToArray())
if ($afterRoles.Count -eq 0 -and $DeleteWhenEmpty) {
  $document.savedPlayerRoles.PSObject.Properties.Remove($PlayerId)
} else {
  $record.roles = $afterRoles
}

$writtenPath = $null
if ($OutputPath) {
  $outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputFullPath) | Out-Null
  $document | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $outputFullPath -Encoding UTF8
  $writtenPath = $outputFullPath
}

$result = [ordered]@{
  feature = 'permissions.role-assignment-patch'
  status = 'passed'
  validationLevel = 'L0 Static'
  startedAt = (Get-Date).ToUniversalTime().ToString('o')
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    inputPath = $inputFullPath
    outputPath = $writtenPath
    roleSetupPath = if ($RoleSetupPath) { [System.IO.Path]::GetFullPath($RoleSetupPath) } else { $null }
    playerId = $PlayerId
    beforeRoles = $beforeRoles
    afterRoles = $afterRoles
    addRoles = @($AddRoles)
    removeRoles = @($RemoveRoles)
    setRoles = @($SetRoles)
    clear = [bool]$Clear
    deleteWhenEmpty = [bool]$DeleteWhenEmpty
  }
  evidence = @(
    [ordered]@{
      kind = 'json'
      path = $inputFullPath
      summary = 'Input RoleAssignments.json'
    }
  )
  errors = @()
}

$json = $result | ConvertTo-Json -Depth 10
if ($OutJson) {
  $outPath = [System.IO.Path]::GetFullPath($OutJson)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
  Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
}

Write-Output $json
