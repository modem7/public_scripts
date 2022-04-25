@echo off

::::::::::::::::::::::::::::::::::::::::::::::
::deletes files in folder older than 12 days::
::::::::::::::::::::::::::::::::::::::::::::::

@pushd %~dp0

CD /D "W:\PlexBackup"

FORFILES /S /D -13 /C "cmd /c IF @isdir == TRUE rd /S /Q @path"

@popd