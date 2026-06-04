param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$RoleAssignmentsPath = '',
  [string]$RoleSetupPath = '',
  [string]$PatchedOutputRoot = '',
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

function Get-AssignedRoles {
  param(
    [Parameter(Mandatory = $true)]$Document,
    [Parameter(Mandatory = $true)][string]$PlayerId
  )

  $property = $Document.savedPlayerRoles.PSObject.Properties[$PlayerId]
  if ($null -eq $property -or $null -eq $property.Value -or !($property.Value.PSObject.Properties.Name -contains 'roles')) {
    return @()
  }
  return @($property.Value.roles | ForEach-Object { [string]$_ })
}

function Assert-RolesEqual {
  param(
    [Parameter(Mandatory = $true)][string]$CaseName,
    [Parameter(Mandatory = $true)][string[]]$Actual,
    [Parameter(Mandatory = $true)][string[]]$Expected,
    [System.Collections.Generic.List[string]]$Errors
  )

  if ($Actual.Count -ne $Expected.Count) {
    $Errors.Add("${CaseName}: expected $($Expected.Count) roles, got $($Actual.Count)")
    return
  }
  for ($i = 0; $i -lt $Expected.Count; $i++) {
    if ($Actual[$i] -ne $Expected[$i]) {
      $Errors.Add("${CaseName}: expected role[$i]=$($Expected[$i]), got $($Actual[$i])")
    }
  }
}

function Invoke-AssignmentCase {
  param(
    [Parameter(Mandatory = $true)][string]$CaseName,
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$RoleSetup,
    [Parameter(Mandatory = $true)][string]$PlayerId,
    [Parameter(Mandatory = $true)][string[]]$ExpectedRoles,
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [System.Collections.Generic.List[string]]$Errors
  )

  $patchScript = Join-Path $Root 'scripts/patch-role-assignments.ps1'
  $patchedPath = Join-Path $OutputRoot "$CaseName.RoleAssignments.patched.json"
  $patchReportPath = Join-Path $OutputRoot "$CaseName.role-assignment-report.json"

  $patchOutput = & $patchScript `
    -InputPath $InputPath `
    -OutputPath $patchedPath `
    -OutJson $patchReportPath `
    -PlayerId $PlayerId `
    -AddRoles Moderator `
    -RemoveRoles Admin `
    -RoleSetupPath $RoleSetup

  $patchReport = $patchOutput | ConvertFrom-Json
  if ($patchReport.status -ne 'passed') {
    $Errors.Add("${CaseName}: patch script did not pass")
  }

  $patched = Get-Content -Raw -LiteralPath $patchedPath | ConvertFrom-Json
  $roles = @(Get-AssignedRoles -Document $patched -PlayerId $PlayerId)
  Assert-RolesEqual -CaseName $CaseName -Actual $roles -Expected $ExpectedRoles -Errors $Errors

  [ordered]@{
    case = $CaseName
    inputPath = [System.IO.Path]::GetFullPath($InputPath)
    roleSetupPath = [System.IO.Path]::GetFullPath($RoleSetup)
    patchedPath = [System.IO.Path]::GetFullPath($patchedPath)
    patchReportPath = [System.IO.Path]::GetFullPath($patchReportPath)
    playerId = $PlayerId
    patchStatus = $patchReport.status
    roles = $roles
  }
}

$errors = New-Object System.Collections.Generic.List[string]
$cases = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[object]

if (!$PatchedOutputRoot) {
  if ($OutJson) {
    $PatchedOutputRoot = Join-Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($OutJson))) 'role-assignments'
  } else {
    $PatchedOutputRoot = Join-Path $Root 'artifacts/local/role-assignments'
  }
}
New-Item -ItemType Directory -Force -Path $PatchedOutputRoot | Out-Null

$fixtureAssignments = Join-Path $Root 'tests/fixtures/roles/role-assignments.json'
$fixtureRoleSetup = Join-Path $Root 'tests/fixtures/roles/default-role.json'
if (!(Test-Path -LiteralPath $fixtureAssignments)) {
  $errors.Add('Missing role assignments fixture: tests/fixtures/roles/role-assignments.json')
} elseif (!(Test-Path -LiteralPath $fixtureRoleSetup)) {
  $errors.Add('Missing role setup fixture: tests/fixtures/roles/default-role.json')
} else {
  $cases.Add((Invoke-AssignmentCase `
    -CaseName 'fixture' `
    -InputPath $fixtureAssignments `
    -RoleSetup $fixtureRoleSetup `
    -PlayerId '11111111-1111-4111-8111-111111111111' `
    -ExpectedRoles @('Moderator') `
    -OutputRoot $PatchedOutputRoot `
    -Errors $errors))
  $evidence.Add([ordered]@{
    kind = 'json'
    path = $fixtureAssignments
    summary = 'Self-contained RoleAssignments.json fixture'
  })
}

$liveAssignments = $RoleAssignmentsPath
$liveRoleSetup = $RoleSetupPath
if (!$liveAssignments -or !$liveRoleSetup) {
  $siblingRoot = Split-Path -Parent $Root
  if (!$liveAssignments) {
    $candidateAssignments = Join-Path $siblingRoot 'Brickadia/omegga-master/omegga-master/data/Saved/Server/RoleAssignments.json'
    if (Test-Path -LiteralPath $candidateAssignments) { $liveAssignments = $candidateAssignments }
  }
  if (!$liveRoleSetup) {
    $candidateSetup = Join-Path $siblingRoot 'Brickadia/omegga-master/omegga-master/data/Saved/Server/RoleSetup2.json'
    if (Test-Path -LiteralPath $candidateSetup) { $liveRoleSetup = $candidateSetup }
  }
}

if ($liveAssignments -and $liveRoleSetup) {
  if (!(Test-Path -LiteralPath $liveAssignments)) {
    $errors.Add("RoleAssignmentsPath does not exist: $liveAssignments")
  } elseif (!(Test-Path -LiteralPath $liveRoleSetup)) {
    $errors.Add("RoleSetupPath does not exist: $liveRoleSetup")
  } else {
    $liveDoc = Get-Content -Raw -LiteralPath $liveAssignments | ConvertFrom-Json
    $firstPlayer = [string]($liveDoc.savedPlayerRoles.PSObject.Properties.Name | Sort-Object | Select-Object -First 1)
    if (!$firstPlayer) {
      $errors.Add('Live RoleAssignments.json has no savedPlayerRoles entries to patch in copy')
    } else {
      $cases.Add((Invoke-AssignmentCase `
        -CaseName 'live-copy' `
        -InputPath $liveAssignments `
        -RoleSetup $liveRoleSetup `
        -PlayerId $firstPlayer `
        -ExpectedRoles @('Moderator') `
        -OutputRoot $PatchedOutputRoot `
        -Errors $errors))
      $evidence.Add([ordered]@{
        kind = 'json'
        path = [System.IO.Path]::GetFullPath($liveAssignments)
        summary = 'Current server RoleAssignments.json, copied into a patched temp output'
      })
    }
  }
}

$result = [ordered]@{
  feature = 'permissions.role-assignments'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = if ($liveAssignments -and (Test-Path -LiteralPath $liveAssignments)) { 'L2 Headless' } else { 'L0 Static' }
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
