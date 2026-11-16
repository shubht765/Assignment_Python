@echo off
REM MATMAS - wrapper so the IDMC Command Task can call the PowerShell archive script.
REM Command Task: Script File Name = C:\Informatica\scripts\matmas_archive_source.cmd
REM               Input Arguments  = "<SOURCE_DIRECTORY>" "<FILE_PATTERN>" "<SOURCE_ARCHIVE_DIRECTORY>" <RUN_ID>
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0matmas_archive_source.ps1" -SourceDir "%~1" -FilePattern "%~2" -ArchiveDir "%~3" -RunId "%~4"
exit /b %ERRORLEVEL%
