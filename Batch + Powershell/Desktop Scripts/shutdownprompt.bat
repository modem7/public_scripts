@echo off
echo Minutes until shut down?
echo.
set /p min=Minutes:
set /a sec=%min%*60
shutdown -s -f -t %sec%