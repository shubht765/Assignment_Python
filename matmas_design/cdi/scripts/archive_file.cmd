@echo off
REM archive_file.cmd <source_folder> <file_name> <archive_folder> <batch_id>
REM Called by the taskflow Command Task after a successful LAND + HARMONIZE.
set SRC=%~1
set FILE=%~2
set ARC=%~3
set BATCH=%~4
if not exist "%ARC%" mkdir "%ARC%"
if not exist "%SRC%\%FILE%" ( echo file %SRC%\%FILE% not found & exit /b 2 )
move /Y "%SRC%\%FILE%" "%ARC%\%~n2_%BATCH%%~x2"
exit /b %ERRORLEVEL%
