@echo off
REM ====================================================================
REM  Elaborado por SYSDOP LLC
REM  Instalar.bat  (MODO A>P, Activo > Pasivo, UNIDIRECCIONAL)
REM  Doble clic en CADA servidor: en uno responde ACTIVO, en el otro PASIVO.
REM  Se auto-eleva, pregunta los datos y registra todo. El password lo pide
REM  Instalar.ps1 OCULTO y lo valida antes de tocar el servidor.
REM  El ACTIVO empuja al PASIVO; el PASIVO nunca copia de vuelta.
REM  Para invertir quien manda: Invertir-Roles.bat (no reinstala).
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
echo  El password NO se pide aqui: lo pide Instalar.ps1 al final, OCULTO, y lo valida.
set "SYNCUSER="
set /p SYNCUSER=Usuario [.\svc-supervisor]:
if "%SYNCUSER%"=="" set SYNCUSER=.\svc-supervisor

echo.
echo IP o NOMBRE del OTRO servidor (el peer con el que se replica).
echo  Ejemplos:  198.51.100.30   o   NODE-C
:askpeer
set "PEER="
set /p PEER=Servidor peer:
if "%PEER%"=="" (echo  ^>^> Debes indicar el peer. & goto askpeer)

echo.
echo ROL de ESTE servidor en la topologia A^>P (Activo ^> Pasivo):
echo  - ACTIVO  = este nodo EMPUJA sus cambios al pasivo (fuente de verdad).
echo  - PASIVO  = este nodo solo RECIBE; nunca copia de vuelta al activo.
echo  Responde A en el ACTIVO, P en el PASIVO.
:askrole
set "ROLEIN="
set /p ROLEIN=Rol de este nodo? (A/P):
if /i "%ROLEIN%"=="A" (set "ROLE=Active" & goto roleok)
if /i "%ROLEIN%"=="P" (set "ROLE=Passive" & goto roleok)
echo  ^>^> Responde A (Activo) o P (Pasivo). & goto askrole
:roleok

echo.
echo Es ESTE el PRIMER servidor que instalas (primario de llaves de cifrado IIS)?
echo  Sugerencia: el ACTIVO suele ser el primario. Responde S en el PRIMERO, N en el SEGUNDO.
set "PRIMARY=N"
set /p PRIMARY=Primario? (S/N) [N]:

echo.
echo Replica de IIS:  Live = replica REAL entre los 2 servidores.  DryRun = solo prueba (no aplica).
set "IISMODE=DryRun"
set /p IISLIVE=Activar replica de IIS EN VIVO ahora? (S/N) [N]:
if /i "%IISLIVE%"=="S" set IISMODE=Live

set "PRIMFLAG="
if /i "%PRIMARY%"=="S" set "PRIMFLAG=-IsPrimary"

REM El password no viaja por aqui: Instalar.ps1 lo pide OCULTO y lo valida antes de
REM tocar el servidor (no queda en pantalla ni en la linea de comandos del proceso).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar.ps1" -User "%SYNCUSER%" -Peer "%PEER%" -Role "%ROLE%" -IISMode "%IISMODE%" %PRIMFLAG%

echo.
echo ==== Fin. Revisa el resultado arriba. ====
pause

