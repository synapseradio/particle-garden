@echo off
setlocal

set APP_NAME=Particle Garden
set EXECUTABLE=particle_garden.exe

echo === Packaging %APP_NAME% for Windows ===

:: Full release build
echo Building...
call nimble release
if errorlevel 1 (
    echo Build failed!
    exit /b 1
)

:: Rename binary
if exist "%EXECUTABLE%" del "%EXECUTABLE%"
rename main.exe "%EXECUTABLE%"

echo.
echo === Created %EXECUTABLE% ===
echo.
echo To distribute:
echo   1. Share %EXECUTABLE% directly, or
echo   2. Create a zip: powershell Compress-Archive -Path "%EXECUTABLE%" -DestinationPath "%APP_NAME%.zip"
echo.
