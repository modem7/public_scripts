@echo off
set TERM=xterm
title IPMI Fan Speed Menu
:home
cls
echo.
echo Select a task:
echo =============
echo.
echo 1) Standard speed
echo 2) Full speed
echo 3) HeavyIO speed
echo 4) Exit
echo.
set /p web=Type option:
if "%web%"=="1" goto standard
if "%web%"=="2" goto full
if "%web%"=="3" goto heavyio
if "%web%"=="4" exit
goto home

:standard
cls
echo Setting fan to Standard Speed
ssh -t alex@192.168.0.254 sudo ipmitool raw 0x30 0x45 1 0
cls
echo Fan set to Standard Speed
pause
goto home

:full
cls
echo Setting fan to Full Speed
ssh -t -t alex@192.168.0.254 sudo ipmitool raw 0x30 0x45 1 1
cls
echo Fan set to Full Speed
pause
goto home

:heavyio
cls
echo Setting fan to HeavyIO Speed
ssh -t -t alex@192.168.0.254 sudo ipmitool raw 0x30 0x45 1 4
cls
echo Fan set to heavyIO Speed
pause
goto home