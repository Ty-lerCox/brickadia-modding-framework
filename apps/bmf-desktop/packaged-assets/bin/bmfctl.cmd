@echo off
setlocal

set "BMF_SHIM_DIR=%~dp0"
for %%I in ("%BMF_SHIM_DIR%..") do set "BMF_ROOT=%%~fI"
for %%I in ("%BMF_ROOT%\..\..") do set "BMF_APP_DIR=%%~fI"

set "BMF_ELECTRON=%BMF_APP_DIR%\BMF Desktop.exe"
set "BMF_CLI=%BMF_ROOT%\cli\bin\bmfctl.js"

if not defined APPDATA (
  if defined LOCALAPPDATA set "APPDATA=%LOCALAPPDATA%"
)
if not defined APPDATA set "APPDATA=%USERPROFILE%\AppData\Roaming"
set "BMF_USER_DATA=%APPDATA%\BMF Desktop"
set "BMF_SNAPSHOT_ROOT=%BMF_USER_DATA%\snapshots"

if not exist "%BMF_ELECTRON%" (
  echo BMF Desktop executable was not found: "%BMF_ELECTRON%" 1>&2
  exit /b 1
)

if not exist "%BMF_CLI%" (
  echo bmfctl entrypoint was not found: "%BMF_CLI%" 1>&2
  exit /b 1
)

set "ELECTRON_RUN_AS_NODE=1"
"%BMF_ELECTRON%" "%BMF_CLI%" --bmf-root "%BMF_ROOT%" --profile-store "%BMF_USER_DATA%\profiles\profiles.json" --journal-root "%BMF_USER_DATA%\transactions" --service-root "%BMF_USER_DATA%\services" --download-dir "%BMF_USER_DATA%\updates" %*
set "BMF_EXIT_CODE=%ERRORLEVEL%"
endlocal & exit /b %BMF_EXIT_CODE%
