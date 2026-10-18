@echo off
REM ====================================================================
REM  Elaborado por SYSDOP LLC
REM  Reiniciar-Tareas.bat  -  Reinicia las tareas de replica de ESTE nodo
REM  SIN cambiar el rol. Se auto-eleva.
REM ====================================================================
setlocal

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permisos de Administrador...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Reiniciar-Tareas.ps1"

echo.
echo ==== Fin. ====
pause
