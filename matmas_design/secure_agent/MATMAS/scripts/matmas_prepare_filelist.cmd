@echo off
REM ---------------------------------------------------------------------------
REM MATMAS - build the indirect file list for m_MATMAS_LAND
REM Pre-processing command of mapping task mt_MATMAS_LAND:
REM   C:\Informatica\SecureAgent\MATMAS\scripts\matmas_prepare_filelist.cmd C:\Informatica\SecureAgent\MATMAS
REM Lists every *.txt / *.csv in every sub-folder of MATMAS\inbound (one folder per ERP).
REM A new ERP folder is picked up automatically; routing happens in SQL by folder name.
REM ---------------------------------------------------------------------------
setlocal EnableExtensions
set "ROOT=%~1"
if "%ROOT%"=="" set "ROOT=C:\Informatica\SecureAgent\MATMAS"
set "WORK=%ROOT%\work"
set "LIST=%WORK%\matmas_filelist.txt"
if not exist "%WORK%" mkdir "%WORK%"
type nul > "%LIST%"

for /d %%D in ("%ROOT%\inbound\*") do (
    for %%F in ("%%~fD\*.txt" "%%~fD\*.csv") do echo %%~fF>>"%LIST%"
)

REM the indirect source must never be empty: list a zero-byte placeholder (lands 0 rows)
for %%A in ("%LIST%") do if %%~zA==0 (
    type nul > "%WORK%\_empty.txt"
    echo %WORK%\_empty.txt>>"%LIST%"
)
type "%LIST%"
exit /b 0
