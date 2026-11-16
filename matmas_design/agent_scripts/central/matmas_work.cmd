@echo off
REM ---------------------------------------------------------------------------
REM MATMAS - work folder on the CENTRAL Secure Agent (US.US02.01)
REM Install as C:\Informatica\scripts\matmas_work.cmd
REM Called by the taskflow Command Tasks:
REM   CT_PrepWork : matmas_work.cmd clear <RUN_ID>   empties work\inbox before the OneLake -> work copy
REM   CT_ListWork : matmas_work.cmd list  <RUN_ID>   writes work\matmas_filelist.txt (file list read by m_P2O_102_MATMAS_Load)
REM ---------------------------------------------------------------------------
setlocal EnableExtensions
set "MODE=%~1"
set "ROOT=C:\Informatica\MATMAS\work"
if not exist "%ROOT%\inbox" mkdir "%ROOT%\inbox"
if /I "%MODE%"=="clear" (
    del /q "%ROOT%\inbox\*" 2>nul
    echo inbox cleared for run %~2
    exit /b 0
)
if /I "%MODE%"=="list" (
    dir /b /s /a-d "%ROOT%\inbox\*" > "%ROOT%\matmas_filelist.txt" 2>nul
    type "%ROOT%\matmas_filelist.txt"
    exit /b 0
)
echo usage: matmas_work.cmd clear^|list RUN_ID
exit /b 1
