@echo off
REM This script will be run when the plugin is installed...
where cargo >nul 2>nul
if %ERRORLEVEL% EQU 0 (
  cargo build --release
) else (
  echo WARNING: Rust is not installed. This plugin could not be built. It will not work unless it has a bundled binary.
)
exit /b 0
