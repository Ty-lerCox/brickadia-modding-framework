@echo off
setlocal

set "ROOT=C:\Users\tycox\OneDrive\Documents\GitHub\Brickadia"
set "OMEGGA=C:\Users\tycox\OneDrive\Documents\GitHub\Brickadia\omegga-master\omegga-master"
set "STDOUT=%OMEGGA%\chat-proof-stdout.log"
set "STDERR=%OMEGGA%\chat-proof-stderr.log"

del /q "%STDOUT%" "%STDERR%" 2>nul
call "%ROOT%\run-omegga.cmd" 1>"%STDOUT%" 2>"%STDERR%"
