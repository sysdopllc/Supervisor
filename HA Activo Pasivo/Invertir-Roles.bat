@echo off
REM ====================================================================
REM  Elaborado por SYSDOP LLC
REM  Invertir-Roles.bat  -  Cambia el sentido de la replica A>P.
REM  Intercambia Activo <-> Pasivo entre este nodo y su peer.
REM  Doble clic; se auto-eleva y pide confirmacion.
REM    - Si el peer esta CAIDO y solo quieres promover este nodo a Activo,
REM      corre desde consola:  Invertir-Roles.bat /promote
REM ====================================================================
setlocal

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permisos de Administrador...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

set "EXTRA="
if /i "%~1"=="/promote" set "EXTRA=-PromoteLocalOnly"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invertir-Roles.ps1" %EXTRA%

echo.
echo ==== Fin. Revisa el resultado arriba. ====
pause
