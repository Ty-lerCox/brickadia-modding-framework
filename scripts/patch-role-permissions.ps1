param(
  [Parameter(Mandatory = $true)]
  [string]$InputPath,
  [string]$OutputPath = '',
  [string]$OutJson = '',
  [string]$RoleName = 'Default',
  [string[]]$Allow = @(),
  [string[]]$Forbid = @(),
  [string[]]$Remove = @(),
  [switch]$PresetNoSpawnItemApplicator
)

$ErrorActionPreference = 'Stop'

function Test-PermissionName {
  param([string]$Name)
  return $Name -match '^BR\.Permission\.[A-Za-z0-9_.-]+$'
}

function Add-OrSetPermission {
  param(
    [Parameter(Mandatory = $true)]$Role,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][ValidateSet('Allowed', 'Forbidden')][string]$State
  )

  if (!(Test-PermissionName $Name)) {
    throw "Invalid permission name: $Name"
  }

  if (!($Role.PSObject.Properties.Name -contains 'permissions') -or $null -eq $Role.permissions) {
    Add-Member -InputObject $Role -NotePropertyName permissions -NotePropertyValue @() -Force
  }

  $next = New-Object System.Collections.Generic.List[object]
  $matched = $false
  foreach ($permission in @($Role.permissions)) {
    if ($null -eq $permission -or !($permission.PSObject.Properties.Name -contains 'name')) {
      continue
    }
    if ([string]$permission.name -eq $Name) {
      if (!$matched) {
        $permission.state = $State
        $next.Add($permission)
        $matched = $true
      }
    } else {
      $next.Add($permission)
    }
  }

  if (!$matched) {
    $next.Add([ordered]@{
      name = $Name
      state = $State
    })
  }

  $Role.permissions = @($next.ToArray())
}

function Remove-Permission {
  param(
    [Parameter(Mandatory = $true)]$Role,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if (!(Test-PermissionName $Name)) {
    throw "Invalid permission name: $Name"
  }

  $next = New-Object System.Collections.Generic.List[object]
  foreach ($permission in @($Role.permissions)) {
    if ($null -ne $permission -and ($permission.PSObject.Properties.Name -contains 'name') -and [string]$permission.name -eq $Name) {
      continue
    }
    $next.Add($permission)
  }
  $Role.permissions = @($next.ToArray())
}

function Get-Role {
  param(
    [Parameter(Mandatory = $true)]$Document,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($Name -ieq 'Default') {
    if ($Document.PSObject.Properties.Name -contains 'defaultRole' -and $null -ne $Document.defaultRole) {
      return $Document.defaultRole
    }
  }

  foreach ($role in @($Document.roles)) {
    if ($null -ne $role -and ($role.PSObject.Properties.Name -contains 'name') -and [string]$role.name -eq $Name) {
      return $role
    }
  }

  return $null
}

$inputFullPath = [System.IO.Path]::GetFullPath($InputPath)
if (!(Test-Path -LiteralPath $inputFullPath)) {
  throw "Input role setup file does not exist: $inputFullPath"
}

$document = Get-Content -Raw -LiteralPath $inputFullPath | ConvertFrom-Json
$role = Get-Role -Document $document -Name $RoleName
if ($null -eq $role) {
  throw "Role '$RoleName' was not found in $inputFullPath"
}

$initialPermissions = @($role.permissions | Where-Object { $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'name') } | ForEach-Object {
  [ordered]@{ name = [string]$_.name; state = [string]$_.state }
})

$allowSet = New-Object System.Collections.Generic.List[string]
$forbidSet = New-Object System.Collections.Generic.List[string]
$removeSet = New-Object System.Collections.Generic.List[string]

if ($PresetNoSpawnItemApplicator) {
  foreach ($permission in @(
    'BR.Permission.Building',
    'BR.Permission.Building.Applicator',
    'BR.Permission.Building.Applicator.EditBricks',
    'BR.Permission.Building.Applicator.EditEntities'
  )) {
    $allowSet.Add($permission)
  }
  $forbidSet.Add('BR.Permission.SpawnItems')
}

foreach ($permission in @($Allow)) { if ($permission) { $allowSet.Add($permission) } }
foreach ($permission in @($Forbid)) { if ($permission) { $forbidSet.Add($permission) } }
foreach ($permission in @($Remove)) { if ($permission) { $removeSet.Add($permission) } }

foreach ($permission in $allowSet) {
  Add-OrSetPermission -Role $role -Name $permission -State 'Allowed'
}
foreach ($permission in $forbidSet) {
  Add-OrSetPermission -Role $role -Name $permission -State 'Forbidden'
}
foreach ($permission in $removeSet) {
  Remove-Permission -Role $role -Name $permission
}

$finalPermissions = @($role.permissions | Where-Object { $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'name') } | ForEach-Object {
  [ordered]@{ name = [string]$_.name; state = [string]$_.state }
})

$writtenPath = $null
if ($OutputPath) {
  $outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputFullPath) | Out-Null
  $document | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $outputFullPath -Encoding UTF8
  $writtenPath = $outputFullPath
}

$result = [ordered]@{
  feature = 'permissions.role-patch'
  status = 'passed'
  validationLevel = 'L0 Static'
  startedAt = (Get-Date).ToUniversalTime().ToString('o')
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    inputPath = $inputFullPath
    outputPath = $writtenPath
    roleName = $RoleName
    presetNoSpawnItemApplicator = [bool]$PresetNoSpawnItemApplicator
    allow = @($allowSet)
    forbid = @($forbidSet)
    remove = @($removeSet)
    initialPermissions = $initialPermissions
    finalPermissions = $finalPermissions
  }
  evidence = @(
    [ordered]@{
      kind = 'json'
      path = $inputFullPath
      summary = 'Input RoleSetup2-style permissions file'
    }
  )
  errors = @()
}

$json = $result | ConvertTo-Json -Depth 12
if ($OutJson) {
  $outPath = [System.IO.Path]::GetFullPath($OutJson)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
  Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
}

Write-Output $json
