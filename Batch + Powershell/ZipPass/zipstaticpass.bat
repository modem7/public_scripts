@echo off

setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

set pwd="NprhnM437ZmC"

"C:\Program Files\7-Zip\7z.exe" a %1.zip %1 -p"%pwd%"

echo password is %pwd%
pause