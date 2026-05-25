@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Unregister ZTool SolidWorks AddIn.ps1" -RemoveLegacy
exit /b %ERRORLEVEL%
