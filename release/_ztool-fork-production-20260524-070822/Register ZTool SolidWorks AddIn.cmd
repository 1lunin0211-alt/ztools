@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Register ZTool SolidWorks AddIn.ps1" -RemoveLegacy
exit /b %ERRORLEVEL%
