@echo off
Echo ED25519 key generator
set userdir="%UserProfile%\Desktop"
set pubdir="%UserProfile%\Desktop"
set /p key="Enter key Name: "
echo "Key name: %key%"

ssh-keygen -a 100 -t ed25519 -f %userdir%\%key% -C %key% -N ""

rem ssh-add %userdir%\%key%
rem MOVE %userdir%\%key%.pub %userdir%\pub\

FOR /F "delims=" %%I IN (%userdir%) DO SET unuserdir=%%I
FOR /F "delims=" %%I IN (%pubdir%) DO SET unpubdir=%%I

cls
echo ED25519 key created
echo.
echo Private Key located at %unuserdir%\%key%
echo Public Key located at %unpubdir%\%key%.pub
rem echo Key added to SSH-Add
echo.
echo Press any key to exit
pause > nul