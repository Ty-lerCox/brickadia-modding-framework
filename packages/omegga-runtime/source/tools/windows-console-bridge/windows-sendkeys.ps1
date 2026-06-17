param(
  [Parameter(Mandatory = $true)]
  [int]$TargetPid,

  [string]$WindowTitle,

  [Parameter(Mandatory = $true)]
  [string]$Text,

  [int]$ActivateDelayMs = 150,

  [switch]$PressEnter
)

$ErrorActionPreference = 'Stop'

function ConvertTo-SendKeysLiteral([string]$Value) {
  $builder = New-Object System.Text.StringBuilder

  foreach ($char in $Value.ToCharArray()) {
    switch ($char) {
      '+' { [void]$builder.Append('{+}') }
      '^' { [void]$builder.Append('{^}') }
      '%' { [void]$builder.Append('{%}') }
      '~' { [void]$builder.Append('{~}') }
      '(' { [void]$builder.Append('{(}') }
      ')' { [void]$builder.Append('{)}') }
      '[' { [void]$builder.Append('{[}') }
      ']' { [void]$builder.Append('{]}') }
      '{' { [void]$builder.Append('{{}') }
      '}' { [void]$builder.Append('{}}') }
      default { [void]$builder.Append($char) }
    }
  }

  $builder.ToString()
}

$shell = New-Object -ComObject WScript.Shell
$activated = $false
if ($WindowTitle) {
  $activated = $shell.AppActivate($WindowTitle)
}
if (-not $activated) {
  $activated = $shell.AppActivate($TargetPid)
}
if (-not $activated) {
  throw "Failed to activate bridge console window."
}
Start-Sleep -Milliseconds $ActivateDelayMs
$shell.SendKeys((ConvertTo-SendKeysLiteral $Text))
if ($PressEnter) {
  $shell.SendKeys('~')
}
