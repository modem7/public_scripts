@echo off

goto privileges

:gotPrivileges

::::::::::::::::::::::::::::

:START

::::::::::::::::::::::::::::

setlocal & pushd .

REM Run shell as admin (example) – put code here as you like

title iDrive Service Script
:home
cls
echo.
echo Select a task:
echo =============
echo.
echo 1) Stop and Disable Service
echo 2) Start Service and Set to Delayed Auto
echo 3) Exit
echo.
set /p web=Type option:
if "%web%"=="1" goto stop
if "%web%"=="2" goto startservice
if "%web%"=="3" exit
goto home

:stop
cls
echo Stopping Service
sc stop IDriveService
sc config IDriveService start=disabled
cls
echo Service Stopped and Service Disabled
pause
goto home

:startservice
cls
echo Starting Service
sc config IDriveService start=delayed-auto
sc start IDriveService
cls
echo Service Started
pause
goto home

:::::::::::::::::::::::::::::::::::::::::

:: Automatically check & get admin rights

:::::::::::::::::::::::::::::::::::::::::

:privileges

CLS

ECHO.

ECHO =============================

ECHO Running Admin shell

ECHO =============================

:checkPrivileges

NET FILE 1>NUL 2>NUL

if '%errorlevel%' == '0' ( goto gotPrivileges ) else ( goto getPrivileges )

:getPrivileges

if '%1'=='ELEV' (shift & goto gotPrivileges)

ECHO.

ECHO **************************************

ECHO Invoking UAC for Privilege Escalation

ECHO **************************************

setlocal DisableDelayedExpansion

set "batchPath=%~0"

setlocal EnableDelayedExpansion

ECHO Set UAC = CreateObject^("Shell.Application"^) > "%temp%\OEgetPrivileges.vbs"

ECHO UAC.ShellExecute "!batchPath!", "ELEV", "", "runas", 1 >> "%temp%\OEgetPrivileges.vbs"

"%temp%\OEgetPrivileges.vbs"

exit /B