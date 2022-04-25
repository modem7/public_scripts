@ECHO OFF
SETLOCAL
SET "sourcedir=V:\"
SET "keepdir=Backups"

FOR /d %%a IN ("%sourcedir%\*") DO IF /i NOT "%%~nxa"=="%keepdir%" RD /S /Q "%%a"
GOTO :EOF
