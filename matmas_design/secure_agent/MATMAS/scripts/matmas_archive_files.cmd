@echo off
REM ---------------------------------------------------------------------------
REM MATMAS - archive the files that were landed in this run
REM Post-processing command of mapping task mt_MATMAS_PROCESS:
REM   C:\Informatica\SecureAgent\MATMAS\scripts\matmas_archive_files.cmd C:\Informatica\SecureAgent\MATMAS
REM Moves only the files listed in work\matmas_filelist.txt to archive\<ERP folder>\<name>_<timestamp>.<ext>
REM Files that arrive during the run stay in inbound for the next run.
REM Landed data stays in MATMAS.LANDING_RAW, so a failed route is re-run with
REM EXEC MATMAS.sp_MATMAS_Reprocess '<BATCH_ID>' without the file.
REM ---------------------------------------------------------------------------
setlocal EnableExtensions
set "ROOT=%~1"
if "%ROOT%"=="" set "ROOT=C:\Informatica\SecureAgent\MATMAS"
set "LIST=%ROOT%\work\matmas_filelist.txt"
if not exist "%LIST%" exit /b 0
for /f %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMddHHmmss"') do set "TS=%%T"

for /f "usebackq delims=" %%F in ("%LIST%") do call :archive "%%F"
exit /b 0

:archive
if /I "%~nx1"=="_empty.txt" goto :eof
if not exist "%~1" goto :eof
for %%P in ("%~dp1.") do set "ERP=%%~nxP"
if not exist "%ROOT%\archive\%ERP%" mkdir "%ROOT%\archive\%ERP%"
move /Y "%~1" "%ROOT%\archive\%ERP%\%~n1_%TS%%~x1" >nul
echo archived %~1
goto :eof
