@echo off
REM ====================================================================
REM  Elaborado por SYSDOP LLC
REM  Instalar.bat  (MODO A>P>P, Activo > Pasivo1 > Pasivo2, 3 NODOS EN CADENA)
REM  Doble clic en CADA servidor, en este orden: ACTIVO, PASIVO1 y PASIVO2.
REM  Se auto-eleva, pregunta los datos de ESTE nodo y registra todo. El password lo
REM  pide Instalar.ps1 OCULTO y lo valida antes de tocar el servidor.
REM  Activo -> Pasivo1: tiempo real. Pasivo1 -> Pasivo2: rafaga diaria (def 23:00).
REM  Ningun pasivo copia de vuelta. Para invertir Activo<->Pasivo1: Invertir-Roles.bat.
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

echo Usuario para las tareas (admin en TODOS los nodos, mismo nombre y password).
echo  - Recomendado con dominio: EXAMPLE\svc-supervisor  (o una cuenta de servicio del dominio)
echo  - Sin dominio (workgroup):  .\svc-supervisor
echo  El password NO se pide aqui: lo pide Instalar.ps1 al final, OCULTO, y lo valida.
set "SYNCUSER="
set /p SYNCUSER=Usuario [.\svc-supervisor]:
if "%SYNCUSER%"=="" set SYNCUSER=.\svc-supervisor

echo.
echo IP o NOMBRE del PEER de ESTE nodo:
echo  - En el ACTIVO:  el PASIVO1 ^(al que empuja en tiempo real^).
echo  - En el PASIVO1: el ACTIVO ^(del que recibe en tiempo real^).
echo  - En el PASIVO2: el PASIVO1 ^(el que le envia la rafaga diaria^).
:askpeer
set "PEER="
set /p PEER=Servidor peer:
if "%PEER%"=="" (echo  ^>^> Debes indicar el peer. & goto askpeer)

echo.
echo ROL de ESTE servidor en la cadena A^>P^>P:
echo  - ACTIVO  = este nodo EMPUJA en tiempo real al Pasivo1.
echo  - PASIVO  = este nodo solo RECIBE; nunca copia de vuelta al Activo. (Pasivo1 o Pasivo2.)
echo  Responde A en el ACTIVO, P en los dos pasivos.
:askrole
set "ROLEIN="
set /p ROLEIN=Rol de este nodo? (A/P):
if /i "%ROLEIN%"=="A" (set "ROLE=Active" & goto roleok)
if /i "%ROLEIN%"=="P" (set "ROLE=Passive" & goto roleok)
echo  ^>^> Responde A (Activo) o P (Pasivo). & goto askrole
:roleok

set "TERTIARY="
set "TERTTIME=23:00"
echo.
echo TERCER nodo / Pasivo2: RAFAGA DIARIA que ESTE nodo envia al 3er servidor.
echo  Respondelo SOLO en UN nodo: el que tiene ruta SMB ^(TCP 445^) al 3er servidor, normalmente el PASIVO1.
echo  En los otros nodos deja en blanco. Sin 3er servidor, en blanco en todos ^(queda A^>P de 2 nodos^).
set /p TERTIARY=IP o nombre del 3er nodo [vacio=ninguno]:
if "%TERTIARY%"=="" goto aftertert
set /p TERTTIME=Hora de la rafaga diaria HH:mm [23:00]:
if "%TERTTIME%"=="" set TERTTIME=23:00
:aftertert

echo.
echo Es ESTE el PRIMER servidor que instalas (primario de llaves de cifrado IIS)?
echo  Responde S SOLO en el primero que instalas ^(normalmente el ACTIVO^); N en el PASIVO1 y en el PASIVO2.
set "PRIMARY=N"
set /p PRIMARY=Primario? (S/N) [N]:

echo.
echo Replica de IIS:  Live = replica REAL entre los servidores.  DryRun = solo prueba (no aplica).
set "IISMODE=DryRun"
set /p IISLIVE=Activar replica de IIS EN VIVO ahora? (S/N) [N]:
if /i "%IISLIVE%"=="S" set IISMODE=Live

set "PRIMFLAG="
if /i "%PRIMARY%"=="S" set "PRIMFLAG=-IsPrimary"

REM El password no viaja por aqui: Instalar.ps1 lo pide OCULTO y lo valida antes de
REM tocar el servidor (no queda en pantalla ni en la linea de comandos del proceso).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar.ps1" -User "%SYNCUSER%" -Peer "%PEER%" -Role "%ROLE%" -Tertiary "%TERTIARY%" -TertiaryTime "%TERTTIME%" -IISMode "%IISMODE%" %PRIMFLAG%

echo.
echo ==== Fin. Revisa el resultado arriba. ====
pause

