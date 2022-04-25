@echo off
START "" "C:\Users\Alex\AppData\Local\Programs\3CXDesktopApp\3CXDesktopApp.exe"
timeout 5
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -noprofile -executionpolicy bypass -File "G:\Git Projects\Scripts\3cxminimise.ps1"