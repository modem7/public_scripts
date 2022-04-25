:::::::::::::::::::::::::::::::::::::::::
:: Automatically check & get admin rights
:::::::::::::::::::::::::::::::::::::::::
@echo off

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

:gotPrivileges 
::::::::::::::::::::::::::::
:START
::::::::::::::::::::::::::::
setlocal & pushd .

REM Run shell as admin (example) - put here code as you like
cls
goto Choices

REM use this command to determine what the adapter index number is
REM wmic nic get name, index


:Top
choice /c:123
If ERRORLEVEL == 3 goto NICIndex
If ERRORLEVEL == 2 goto Disable_LAN
If ERRORLEVEL == 1 goto Enable_LAN
goto EOF

:1
:Enable_LAN
wmic path win32_networkadapter where index=14 call enable

goto :EOF

:2
:Disable_LAN
wmic path win32_networkadapter where index=14 call disable
goto :EOF

:3
:NICIndex
cls
wmic nic get name, index
pause
goto :EOF

:Choices
echo 1 Enable LAN
echo 2 Disable LAN
echo 3 Get NIC index
goto Top


:EOF