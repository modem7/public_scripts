@echo off
rem https://www.bloggingforlogging.com/2018/05/20/decrypting-the-secrets-of-ansible-vault-in-powershell/
rem the name of the script is drive path name of the Parameter %0
rem (= the batch file) but with the extension ".ps1"
set args=%1
:More
shift
if '%1'=='' goto Done
set args=%args%, %1
goto More
:Done
powershell.exe -NoExit -Command "& 'Get-DecryptedAnsibleVault' -Path '%args%' | Set-Content -Path '%args%'"