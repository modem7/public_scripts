@echo off
set TERM=xterm
title Greyhole
:home
cls
echo.
echo Select a task:
echo =============
echo.
echo 1) View Log Status
echo 2) View Queue
echo 3) View Status
echo 4) Process Spool
echo 5) Process Spool Keep Alive
echo 6) Exit
echo.
set /p web=Type option:
if "%web%"=="1" goto log
if "%web%"=="2" goto queue
if "%web%"=="3" goto status
if "%web%"=="4" goto standard
if "%web%"=="5" goto full
if "%web%"=="6" exit
goto home

:log
cls
echo Greyhole log. Press Ctrl+C to exit.
ssh -t alex@192.168.0.254 "greyhole -L"
cls
goto home

:queue
cls
echo Greyhole queue. Press Ctrl+C to exit.
ssh -t alex@192.168.0.254 "clear && watch -d greyhole --view-queue"
cls
goto home

:status
cls
echo Greyhole daemon status.
ssh -t alex@192.168.0.254 "greyhole -S"
pause
cls
goto home

:standard
cls
echo Processing Spool.
ssh -t alex@192.168.0.254 "sudo greyhole --process-spool"
cls
echo Spool Processed.
pause
goto home

:full
cls
echo Processing Spool for 60 seconds.
ssh -t alex@192.168.0.254 "sudo greyhole --process-spool --keepalive"
cls
echo Spool Processed.
pause
goto home