@echo off
REM ====================================================================
REM  Elaborado por SYSDOP LLC
REM  Instalar.bat  (MALLA Activo-Activo-Activo)  -  Doble clic en CADA nodo.
REM  Se auto-eleva, pregunta los datos y registra todo. El password lo pide
REM  Instalar.ps1 OCULTO y lo valida antes de tocar el servidor.
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

echo ============================================================
echo   Supervisor HA  -  MALLA Activo-Activo-Activo (3 nodos)
echo   Todos los nodos son ACTIVOS y se replican entre si.
echo ============================================================
echo.
echo Usuario para las tareas (admin en TODOS los nodos).
echo  - Recomendado con dominio: EXAMPLE\svc-supervisor  (o una cuenta de servicio del dominio)
echo  - Sin dominio (workgroup):  .\svc-supervisor
echo  El password NO se pide aqui: lo pide Instalar.ps1 al final, OCULTO, y lo valida.
set "SYNCUSER="
set /p SYNCUSER=Usuario [.\svc-supervisor]:
if "%SYNCUSER%"=="" set SYNCUSER=.\svc-supervisor

echo.
echo IP o NOMBRE de los OTROS servidores de la malla (los peers de ESTE nodo),
echo SEPARADOS POR COMA.  Ejemplo con 3 nodos, corriendo en el nodo 1:
echo    NODO2,NODO3    o    192.0.2.20,198.51.100.30
:askpeers
set "PEERS="
set /p PEERS=Servidores peer (coma):
if "%PEERS%"=="" (echo  ^>^> Debes indicar al menos un peer. & goto askpeers)

echo.
echo Es ESTE el nodo PRIMARIO de llaves de cifrado IIS?
echo  Responde S en UN solo nodo (instalalo PRIMERO). N en los demas.
set "PRIMARY=N"
set /p PRIMARY=Primario? (S/N) [N]:

set "PRIMFLAG="
set "KEYPRIMFLAG="
if /i "%PRIMARY%"=="S" goto after_primary

echo.
echo IP o NOMBRE del nodo PRIMARIO (donde respondiste S). Necesario para sincronizar llaves IIS.
set "KEYPRIM="
set /p KEYPRIM=Nodo primario:
if not "%KEYPRIM%"=="" set "KEYPRIMFLAG=-KeyPrimary "%KEYPRIM%""
goto ask_iis

:after_primary
set "PRIMFLAG=-IsPrimary"

:ask_iis
echo.
echo Replica de IIS:  Live = replica REAL entre los servidores.  DryRun = solo prueba (no aplica).
set "IISMODE=DryRun"
set /p IISLIVE=Activar replica de IIS EN VIVO ahora? (S/N) [N]:
if /i "%IISLIVE%"=="S" set IISMODE=Live

REM El password no viaja por aqui: Instalar.ps1 lo pide OCULTO y lo valida antes de
REM tocar el servidor (no queda en pantalla ni en la linea de comandos del proceso).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar.ps1" -User "%SYNCUSER%" -Peers "%PEERS%" -IISMode "%IISMODE%" %PRIMFLAG% %KEYPRIMFLAG%

echo.
echo ==== Fin. Revisa el resultado arriba. ====
echo Recuerda instalar TODOS los nodos de la malla (el -IsPrimary primero).
pause
