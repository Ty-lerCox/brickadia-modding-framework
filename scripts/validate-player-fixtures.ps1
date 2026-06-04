param(
  [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutJson = ''
)

$ErrorActionPreference = 'Stop'

$fixtureRoot = Join-Path $Root 'tests/fixtures/players'
$uuidRegex = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
$errors = New-Object System.Collections.Generic.List[string]
$cases = New-Object System.Collections.Generic.List[object]
$evidence = New-Object System.Collections.Generic.List[object]

if (!(Test-Path -LiteralPath $fixtureRoot)) {
  $errors.Add("Missing fixture root: tests/fixtures/players")
} else {
  foreach ($file in Get-ChildItem -LiteralPath $fixtureRoot -Filter '*.json' | Sort-Object Name) {
    $relative = Join-Path 'tests/fixtures/players' $file.Name
    $evidence.Add([ordered]@{
      kind = 'json'
      path = $file.FullName
      summary = "Player fixture $($file.Name)"
    })

    try {
      $fixture = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
    } catch {
      $errors.Add("Invalid JSON in ${relative}: $($_.Exception.Message)")
      continue
    }

    if ($fixture.schemaVersion -ne 1) {
      $errors.Add("${relative}: schemaVersion must be 1")
    }
    if (!($fixture.players -is [array])) {
      $errors.Add("${relative}: players must be an array")
      continue
    }

    $valid = New-Object System.Collections.Generic.List[object]
    $invalid = New-Object System.Collections.Generic.List[object]
    foreach ($player in @($fixture.players)) {
      $uuid = ''
      if ($null -ne $player.uuid) {
        $uuid = [string]$player.uuid
      } elseif ($null -ne $player.id) {
        $uuid = [string]$player.id
      }
      $usernameOk = $null -eq $player.username -or $player.username -is [string]
      $displayNameOk = $null -eq $player.displayName -or $player.displayName -is [string]
      $rolesOk = $null -eq $player.roles -or $player.roles -is [array]
      if ($uuid -match $uuidRegex -and $usernameOk -and $displayNameOk -and $rolesOk) {
        $valid.Add($player)
      } else {
        $invalid.Add($player)
      }
    }

    if ($fixture.case -eq 'malformed') {
      if ($valid.Count -ne [int]$fixture.expected.validCount) {
        $errors.Add("${relative}: expected validCount $($fixture.expected.validCount), got $($valid.Count)")
      }
      if ($invalid.Count -ne [int]$fixture.expected.invalidCount) {
        $errors.Add("${relative}: expected invalidCount $($fixture.expected.invalidCount), got $($invalid.Count)")
      }
      foreach ($expectedId in @($fixture.expected.validIds)) {
        if (!(@($valid | ForEach-Object { $_.uuid }) -contains $expectedId)) {
          $errors.Add("${relative}: expected valid id $expectedId was not found")
        }
      }
    } else {
      if ($invalid.Count -ne 0) {
        $errors.Add("${relative}: expected no invalid player records, got $($invalid.Count)")
      }
      if ($fixture.expected -and $fixture.expected.PSObject.Properties.Name -contains 'listCount') {
        if (@($fixture.players).Count -ne [int]$fixture.expected.listCount) {
          $errors.Add("${relative}: expected listCount $($fixture.expected.listCount), got $(@($fixture.players).Count)")
        }
      }
    }

    $cases.Add([ordered]@{
      file = $relative
      case = $fixture.case
      playerCount = @($fixture.players).Count
      validCount = $valid.Count
      invalidCount = $invalid.Count
    })
  }
}

$result = [ordered]@{
  feature = 'players.mock-fixtures'
  status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  validationLevel = 'L0 Static'
  startedAt = (Get-Date).ToUniversalTime().ToString('o')
  finishedAt = (Get-Date).ToUniversalTime().ToString('o')
  data = [ordered]@{
    fixtureRoot = $fixtureRoot
    cases = $cases
  }
  evidence = $evidence
  errors = @($errors)
}

$json = $result | ConvertTo-Json -Depth 8
if ($OutJson) {
  $outPath = [System.IO.Path]::GetFullPath($OutJson)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
  Set-Content -LiteralPath $outPath -Value $json -Encoding UTF8
}

Write-Output $json
if ($errors.Count -ne 0) {
  exit 1
}
