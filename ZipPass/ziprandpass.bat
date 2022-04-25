@echo off

rem 16 stings pwd

setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION
set alfanum=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789

set pwd=
FOR /L %%b IN (0, 1, 16) DO (
    SET /A rnd_num=!RANDOM! * 62 / 32768 + 1
    for /F %%c in ('echo %%alfanum:~!rnd_num!^,1%%') do set "pwd=!pwd!%%c"
)

"C:\Program Files\7-Zip\7z.exe" a %1.zip %1 -p"%pwd%"

echo password is %pwd%
pause