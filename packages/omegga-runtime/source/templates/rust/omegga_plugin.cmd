@echo off
set FILE=omegga-{{name}}.exe
set BASE=%~dp0
set DEBUG=%BASE%target\debug\
set RELEASE=%BASE%target\release\

if exist "%DEBUG%%FILE%" (
  "%DEBUG%%FILE%"
  exit /b %ERRORLEVEL%
)

if exist "%RELEASE%%FILE%" (
  "%RELEASE%%FILE%"
  exit /b %ERRORLEVEL%
)

echo The rust plugin {{name}} is not built! Please build it first.
exit /b 1
