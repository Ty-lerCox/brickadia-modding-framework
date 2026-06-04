param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$RoleSetupPath = '',
  [string]$PatchedOutputRoot = '',
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

function Get-PermissionEntry {
  param(
    [Parameter(Mandatory = $true)]$Role,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $matches = @($Role.permissions | Where-Object {
    $null -ne $_ -and ($_.PSObject.Properties.Name -contains 'name') -and [string]$_.name -eq $Name
  })

  [pscustomobject]@{
    Count = $matches.Count
    State = if ($matches.Count -gt 0) { [string]$matches[0].state } else { $null }
  }
}

function Test-PatchedRole {
  param(
    [Parameter(Mandatory = $true)]$Role,
    [System.Collections.Generic.List[string]]$Errors,
    [Parameter(Mandatory = $true)][string]$CaseName
  )

  foreach ($permission in @(
    'BR.Permission.Building',
    'BR.Permission.Building.Applicator',
    'BR.Permission.Building.Applicator.EditBricks',
    'BR.Permission.Building.Applicator.EditEntities'
  )) {
    $entry = Get-PermissionEntry -Role $Role -Name $permission
    if ($entry.Count -ne 1 -or $entry.State -ne 'Allowed') {
      $Errors.Add("${CaseName}: expected $permission to be exactly once with state Allowed; got count=$($entry.Count) state=$($entry.State)")
    }
  }

  $spawnItems = Get-PermissionEntry -Role $Role -Name 'BR.Permission.SpawnItems'
  if ($spawnItems.Count -ne 1 -or $spawnItems.State -ne 'Forbidden') {
    $Errors.Add("${CaseName}: expected BR.Permission.SpawnItems to be exactly once with state Forbidden; got count=$($spawnItems.Count) state=$($spawnItems.State)")
  }

  $duplicates = @($Role.permissions | Group-Object name | Where-Object { $_.Name -and $_.Count -gt 1 })
  foreach ($duplicate in $duplicates) {
    $Errors.Add("${CaseName}: duplicate permission entry found: $($duplicate.Name)")
  }
}

function Invoke-RoleCase {
  param(
    [Parameter(Mandatory = $true)][string]$CaseName,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [System.Collections.Generic.List[string]]$Errors
  )

  $patchScript = Join-Path $Root 'scripts/patch-role-permissions.ps1'
  $patchedPath = Join-Path $OutputRoot "$CaseName.RoleSetup2.no-spawn-items.json"
  $patchReportPath = Join-Path $OutputRoot "$CaseName.role-patch-report.json"

  $patchOutput = & $patchScript -InputPath $InputPath -OutputPath $patchedPath -OutJson $patchReportPath -RoleName 'Default' -PresetNoSpawnItemApplicator
  $patchReport = $patchOutput | ConvertFrom-Json
  if ($patchReport.status -ne 'passed') {
    $Errors.Add("${CaseName}: patch script did not pass")
  }

  $patched = Get-Content -Raw -LiteralPath $patchedPath | ConvertFrom-Json
  if ($null -eq $patched.defaultRole) {
    $Errors.Add("${CaseName}: patched output is missing defaultRole")
  } else {
    Test-PatchedRole -Role $patched.defaultRole -Errors $Errors -CaseName $CaseName
  }

  [ordered]@{
    case = $CaseName
    inputPath = [System.IO.Path]::GetFullPath($InputPath)
    patchedPath = [System.IO.Path]::GetFullPath($patchedPath)
    patchReportPath = [System.IO.Path]::GetFullPath($patchReportPath)
    patchStatus = $patchReport.status
    defaultPermissionCount = if ($patched.defaultRole) { @($patched.defaultRole.permissions).Count } else { 0 }
  }
}

$errors = New-Object System.Collections.Generic.List[string]
$cases = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[object]

if (!$PatchedOutputRoot) {
  if ($OutJson) {
    $PatchedOutputRoot = Join-Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($OutJson))) 'role-permissions'
  } else {
    $PatchedOutputRoot = Join-Path $Root 'artifacts/local/role-permissions'
  }
}
New-Item -ItemType Directory -Force -Path $PatchedOutputRoot | Out-Null

$fixturePath = Join-Path $Root 'tests/fixtures/roles/default-role.json'
if (!(Test-Path -LiteralPath $fixturePath)) {
  $errors.Add('Missing role fixture: tests/fixtures/roles/default-role.json')
} else {
  $cases.Add((Invoke-RoleCase -CaseName 'fixture-default-role' -InputPath $fixturePath -OutputRoot $PatchedOutputRoot -Errors $errors))
  $evidence.Add([ordered]@{
    kind = 'json'
    path = $fixturePath
    summary = 'Self-contained RoleSetup2-style fixture'
  })
}

$liveRoleSetupPath = $RoleSetupPath
if (!$liveRoleSetupPath) {
  $siblingRoot = Split-Path -Parent $Root
  $candidate = Join-Path $siblingRoot 'Brickadia/omegga-master/omegga-master/data/Saved/Server/RoleSetup2.json'
  if (Test-Path -LiteralPath $candidate) {
    $liveRoleSetupPath = $candidate
  }
}

if ($liveRoleSetupPath) {
  if (!(Test-Path -LiteralPath $liveRoleSetupPath)) {
    $errors.Add("RoleSetupPath does not exist: $liveRoleSetupPath")
  } else {
    $cases.Add((Invoke-RoleCase -CaseName 'live-default-role' -InputPath $liveRoleSetupPath -OutputRoot $PatchedOutputRoot -Errors $errors))
    $evidence.Add([ordered]@{
      kind = 'json'
      path = [System.IO.Path]::GetFullPath($liveRoleSetupPath)
      summary = 'Current server RoleSetup2.json, copied into a patched temp output'
    })
  }
}

$result = [ordered]@{
  feature = 'permissions.role-patcher'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = if ($liveRoleSetupPath -and (Test-Path -LiteralPath $liveRoleSetupPath)) { 'L2 Headless' } else { 'L0 Static' }
  startedAt = (Get-Date).ToUniversalTime().ToString('o')
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    outputRoot = [System.IO.Path]::GetFullPath($PatchedOutputRoot)
    cases = $cases
  }
  evidence = $evidence
  errors = @($errors)
}

$json = $result | ConvertTo-Json -Depth 10
if ($OutJson) {
  $outPath = [System.IO.Path]::GetFullPath($OutJson)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
  Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
}

Write-Output $json
if ($errors.Count -ne 0) {
  exit 1
}
