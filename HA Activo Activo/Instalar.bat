@echo off
REM ====================================================================
REM  Elaborado por SYSDOP LLC
REM  Instalar.bat  -  Doble clic en CADA servidor (nodos A y B).
REM  Se auto-eleva, pide el password de svc-supervisor y registra todo.
REM ====================================================================
setlocal

REM --- Auto-elevar a Administrador ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Solicitando permisos de Administrador...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

echo Usuario para las tareas (admin en AMBOS servidores).
echo  - Recomendado con dominio: EXAMPLE\svc-supervisor  (o una cuenta de servicio del dominio)
echo  - Sin dominio (workgroup):  .\svc-supervisor
set "SYNCUSER="
set /p SYNCUSER=Usuario [.\svc-supervisor]:
if "%SYNCUSER%"=="" set SYNCUSER=.\svc-supervisor

set /p INFRAPASS=Password de %SYNCUSER%:

echo.
echo IP o NOMBRE del OTRO servidor (el peer con el que se replica).
echo  Ejemplos:  198.51.100.30   o   NODE-C
:askpeer
set "PEER="
set /p PEER=Servidor peer:
if "%PEER%"=="" (echo  ^>^> Debes indicar el peer. & goto askpeer)

echo.
echo Es ESTE el PRIMER servidor que instalas (primario de llaves de cifrado IIS)?
echo  Responde S en el PRIMERO, N en el SEGUNDO.  (Instala primero el primario.)
set "PRIMARY=N"
set /p PRIMARY=Primario? (S/N) [N]:

echo.
echo Replica de IIS:  Live = replica REAL entre los 2 servidores.  DryRun = solo prueba (no aplica).
set "IISMODE=DryRun"
set /p IISLIVE=Activar replica de IIS EN VIVO ahora? (S/N) [N]:
if /i "%IISLIVE%"=="S" set IISMODE=Live

set "PRIMFLAG="
if /i "%PRIMARY%"=="S" set "PRIMFLAG=-IsPrimary"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar.ps1" -User "%SYNCUSER%" -InfraPass "%INFRAPASS%" -Peer "%PEER%" -IISMode "%IISMODE%" %PRIMFLAG%

echo.
echo ==== Fin. Revisa el resultado arriba. ====
pause

