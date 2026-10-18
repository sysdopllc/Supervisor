# HA Activo > Pasivo (replica UNIDIRECCIONAL en tiempo real)

> Elaborado por SYSDOP LLC

Esta carpeta es la variante **Activo > Pasivo** del replicador. Es el **mismo
motor en tiempo real** del modo Activo<>Activo (watcher por carpeta, cola con
reintentos, tombstone de borrados, push de un archivo a la vez con robocopy
`/XO`), con **una sola diferencia de comportamiento**: **deja de ser
bidireccional**.

- El nodo **ACTIVO** vigila sus carpetas y **empuja** los cambios (altas,
  modificaciones, renombrados y borrados) al **PASIVO**, al instante.
- El nodo **PASIVO** **nunca** copia de vuelta hacia el activo. Solo recibe.
- Para **invertir** quien manda (failover/failback) se corre
  `Invertir-Roles.bat`: cambia el rol y reinicia las tareas. **Solo entonces**
  cambia el sentido.

## Que cambia respecto a Activo<>Activo
- `cluster.config` gana una linea **`Role=Active|Passive`** (la pregunta el
  instalador). El motor lee ese rol al arrancar.
- `Sync-WebConfig.ps1`: el Activo hace **solo push** (startup, backstop y
  watcher). El Pasivo queda en reposo (latido en el log); no empuja.
- `Sync-IIS.ps1`: el Activo es **Pusher** del `applicationHost.config`; el
  Pasivo es **Applier** (lo adopta). Las tareas del rol que no aplica quedan
  en reposo, asi un `Invertir-Roles` basta para invertir el sentido sin
  reinstalar.

## Instalacion
En CADA servidor, doble clic en **`Instalar.bat`**:
1. Usuario/clave de servicio (admin en ambos, mismo nombre y password).
2. IP o nombre del **peer** (el otro nodo).
3. **Rol de este nodo**: `A` = Activo (empuja) / `P` = Pasivo (recibe).
4. Primario de llaves IIS (normalmente el Activo) y modo IIS (DryRun/Live).

Instala con roles **opuestos**: si en uno respondes Activo, en el otro Pasivo.

## Invertir roles (failover / failback)
- Ambos nodos vivos: en cualquiera, `Invertir-Roles.bat` (pide confirmacion;
  recuerda que el **nuevo Activo** sobrescribe al nuevo Pasivo: promueve el que
  tiene los datos buenos).
- Peer caido (promover este nodo a Activo): `Invertir-Roles.bat /promote`.
- Si `Invertir-Roles` no pudo reiniciar el peer remotamente, en el peer corre
  `Reiniciar-Tareas.bat` (reinicia sin volver a invertir).

## Logs
- Archivos: `C:\Supervisor\logs\webconfig_sync.log` (busca `ROL=ACTIVO` /
  `ROL=PASIVO`).
- IIS: `C:\Supervisor\logs\iis_sync.log`.

## Seguridad, SMB, firewall, llaves IIS
Aplican **igual** que en Activo<>Activo. Ver en esta misma carpeta:
`OPERACION-Y-SEGURIDAD.md`, `EXCEPCIONES-SEGURIDAD.md`, `FAQ-SEGURIDAD.md`,
`IIS-HA-Enfoques.md`. La unica diferencia operativa es la direccionalidad y el
rol descritos arriba.
