# Guía paso a paso: desplegar la cadena Activo > Pasivo1 > Pasivo2

> Elaborado por SYSDOP LLC
> Ejemplo público con datos ficticios. DryRun solo afecta IIS; archivos e instalación son reales.
> Complementa a `README-A-P-P.md` (qué es) con el detalle de **qué se responde y qué se ve en pantalla** al instalar.

## 1. Cómo queda la réplica

```
   ACTIVO  --(por eventos; latencia a medir)-->  PASIVO1  --(ráfaga diaria 23:00)-->  PASIVO2
```

- El **Activo** vigila sus carpetas y su configuración de IIS y las empuja al **Pasivo1** al instante.
- El **Pasivo1** guarda esa copia y, una vez al día, la reenvía al **Pasivo2** (respaldo / DR).
- Ningún pasivo copia de vuelta hacia el Activo.
- La ráfaga sale del Pasivo1 **porque es el nodo que tiene ruta SMB (TCP 445) al Pasivo2**. Si el Activo no llega al tercer servidor por firewall, no importa: el Pasivo1 lo hace por él.

## 2. Antes de empezar

| Requisito | Detalle |
|---|---|
| Cuenta para las tareas | La misma en los 3 nodos, **admin local en los 3**. Puede ser de dominio (`ad.example.com\svc-supervisor`, recomendada) o local (`.\svc-supervisor`). Si es local, debe tener el **mismo password** en los 3. |
| Red | TCP 445 entre Activo y Pasivo1, y entre Pasivo1 y Pasivo2. **Entre Activo y Pasivo2 no hace falta.** |
| IIS | Ya instalado en los 3 (la réplica no instala ni habilita nada de IIS). |
| Unidades | Las letras que se replican (`C:`, `E:`) deben existir en los 3 servidores. |
| Paquete | Carpeta `HA Activo Pasivo Pasivo` copiada a cada servidor, por ejemplo en `C:\HA`. |

> El paquete no lleva ninguna IP fija: el instalador pregunta todo, así que sirve para cualquier trío de servidores.

## 3. Qué preguntan las pantallas y qué se responde

`Instalar.bat` (doble clic, acepta el UAC) pregunta siempre lo mismo, en este orden:

| # | Pregunta en pantalla | Qué significa |
|---|---|---|
| 1 | `Usuario [.\svc-supervisor]:` | La cuenta con la que correrán las tareas. |
| 2 | `Servidor peer:` | **El OTRO nodo con el que se relaciona ESTE servidor.** Nunca el propio. |
| 3 | `Rol de este nodo? (A/P):` | `A` solo en el Activo; `P` en los dos pasivos. |
| 4 | `IP o nombre del 3er nodo [vacio=ninguno]:` | Solo se responde en **UN** nodo: el que envía la ráfaga (el Pasivo1). En los demás, Enter. |
| 5 | `Hora de la rafaga diaria HH:mm [23:00]:` | Solo aparece si respondiste el 3er nodo. Enter deja 23:00. |
| 6 | `Primario? (S/N) [N]:` | `S` solo en el **primer** servidor que instalas (el Activo). Es la fuente de las llaves de cifrado de IIS. |
| 7 | `Activar replica de IIS EN VIVO ahora? (S/N) [N]:` | `S` para réplica real de IIS; `N` deja el modo prueba (DryRun, solo registra). |
| 8 | `Password de ... (no se muestra al escribir)` | Lo pide `Instalar.ps1` al final. **No se ve nada al teclear, es normal.** |

### Respuestas por nodo

| Orden | Nodo | 1 Usuario | 2 Peer | 3 Rol | 4 3er nodo | 5 Hora | 6 Primario | 7 IIS en vivo |
|---|---|---|---|---|---|---|---|---|
| 1 | **ACTIVO** | la cuenta | IP del **Pasivo1** | `A` | **Enter** (vacío) | - | `S` | `N` |
| 2 | **PASIVO1** | la cuenta | IP del **Activo** | `P` | IP del **Pasivo2** | Enter (23:00) | `N` | `N` |
| 3 | **PASIVO2** | la cuenta | IP del **Pasivo1** | `P` | **Enter** (vacío) | - | `N` | `N` |

### Despliegue ilustrativo

| Nodo | Dirección | Peer que se escribe | Rol | 3er nodo |
|---|---|---|---|---|
| ACTIVO | 192.0.2.10 | `192.0.2.20` | `A` | vacío |
| PASIVO1 | 192.0.2.20 | `192.0.2.10` | `P` | `198.51.100.30` |
| PASIVO2 | 198.51.100.30 | `192.0.2.20` | `P` | vacío |

Cuenta ficticia de ejemplo: `ad.example.com\svc-supervisor` (de dominio, admin local en los 3 nodos).
Flujo de ejemplo a solicitar y validar: TCP 445 entre 198.51.100.30 y 192.0.2.20, en ambos sentidos.

## 4. Qué se ve al instalar (y qué significa)

Tras el password, el instalador imprime sus pasos:

| Línea | Qué hace |
|---|---|
| `Password verificado para ...` | La cuenta y el password son correctos. Recién aquí empieza a tocar el servidor. |
| `[1/7] LocalAccountTokenFilterPolicy=1` | Permite que una cuenta **local** llegue al `C$` del otro nodo. El instalador también lo establece con cuenta de dominio; revisar su alcance con Seguridad. |
| `[2/7] Firewall: File and Printer Sharing` | Habilita la regla de SMB de Windows en este servidor. |
| `[3/7] HARD CHECK del usuario` | Con cuenta local: existe, habilitada y admin. Con cuenta de dominio dice que no aplica. También prueba el `C$` del peer y el **445 del 3er nodo**. |
| `[4/7] Copiando motores a C:\Supervisor` | Copia los scripts y escribe `cluster.config` con lo que respondiste. |
| `Sincronizando llaves de cifrado de IIS` | Iguala las llaves entre nodos para que los app pools con cuenta de servicio arranquen en todos. |
| `[5/7] [6/7]` | Registra y arranca `WebConfigSync`, `IISSync` e `IISSync-Apply`. |
| `HASyncDaily registrada: ...` | Solo en el nodo con 3er nodo. Es la ráfaga diaria. |
| `[7/7] (Re)arrancando tareas` + tabla | Estado final. `LastTaskResult` 0 o 267009 (en ejecución) es lo normal. |

## 5. El orden importa (llaves de cifrado de IIS)

Instala **ACTIVO, luego PASIVO1, luego PASIVO2**. Motivo: el Activo exporta sus llaves de IIS, el Pasivo1 las adopta y las deja listas para el Pasivo2, y el Pasivo2 las adopta y las borra de ambos.

**Si instalaste fuera de orden** (por ejemplo el Pasivo2 antes que el Pasivo1), verás:

```
AVISO: <peer> no tiene llaves IIS exportadas. Instala primero ese nodo ... y luego re-corre aqui
```

La adopción de llaves sigue pendiente. Revisa los logs y el estado; cuando el nodo anterior esté listo, vuelve a ejecutar el instalador con las mismas respuestas y verifica el resultado.

## 6. Cuenta local o cuenta de dominio

| | Cuenta local (`.\svc-supervisor`) | Cuenta de dominio (`ad.example.com\svc-supervisor`) |
|---|---|---|
| Requisito | Mismo nombre **y mismo password** creada a mano en los 3 nodos | Existe una sola vez en el dominio |
| Hay que agregarla a Administradores locales | Sí, en los 3 | Sí, en los 3 |
| `LocalAccountTokenFilterPolicy` | Necesario (lo pone el instalador) | No lo requiere; el instalador actual lo establece igualmente. Revisar el impacto con Seguridad |
| Cómo autentica entre nodos | NTLM por nombre y password idénticos | El dominio (Kerberos o NTLM) |
| Riesgo al teclear mal el password | Bloqueo local del equipo | **Bloqueo de la cuenta en el dominio**: cuidado, cada intento fallido cuenta |

Usa **la misma forma en los 3 nodos**. No mezcles local en uno y de dominio en otro: la réplica autentica de nodo a nodo con esa misma cuenta.

## 7. Verificar que quedó bien

En cada nodo, PowerShell como administrador:

```powershell
Get-ScheduledTask WebConfigSync,IISSync,IISSync-Apply | Get-ScheduledTaskInfo |
  Format-Table TaskName,LastTaskResult,LastRunTime -AutoSize
Get-Content C:\Supervisor\cluster.config
```

**Prueba de tiempo real** (Activo a Pasivo1): crea un archivo cualquiera en una carpeta replicada del Activo y míralo llegar:

```powershell
Get-Content C:\Supervisor\logs\webconfig_sync.log -Tail 20 -Wait
```
Comprueba la línea `PUSH peer: <archivo>`, la latencia y el contenido/hash en destino.

**Ver los tres registros a la vez, en vivo** (una sola línea; prefijo por registro y color en `ERROR` y `WARN`):

```powershell
Get-ChildItem C:\Supervisor\logs\*.log | % { Start-Job -Arg $_.FullName { param($f) Get-Content $f -Wait -Tail 5 | % { "[{0}] {1}" -f ((Split-Path $f -Leaf) -replace '_sync\.log|\.log'), $_ } } } | Out-Null; while ($true) { Get-Job | Receive-Job | % { Write-Host $_ -Fore $(switch -Wildcard ($_) {'*ERROR*'{'Red'} '*WARN*'{'Yellow'} default{'Gray'}}) }; Start-Sleep -m 400 }
```

Se corta con **Ctrl+C** y se limpian los trabajos con `Get-Job | Stop-Job; Get-Job | Remove-Job`.

**Prueba de la ráfaga diaria**, en el **Pasivo1**, sin esperar a las 23:00:

```powershell
Start-ScheduledTask -TaskName HASyncDaily
Get-Content C:\Supervisor\logs\daily_sync.log -Tail 20
```
Debe decir `OK carpeta [...] -> \\<Pasivo2>\...` y cerrar con `Rafaga diaria finalizada`.

## 8. Problemas frecuentes

| Mensaje | Causa | Qué hacer |
|---|---|---|
| `El password no puede ir vacio` | Diste Enter sin escribir | Escríbelo. No se ve al teclear, es normal. Hay 3 intentos. |
| `Usuario o password INCORRECTO` | Password mal escrito o cuenta equivocada | Reintenta. Ojo con el bloqueo si es cuenta de dominio. Al agotar los 3 intentos **no se modificó nada** en el servidor. |
| `-Peer (...) es ESTE mismo servidor` | Pusiste la IP o el nombre de este servidor como peer | Pon el **otro** nodo. |
| `-Tertiary (...) es el mismo nodo que -Peer` | El 3er nodo no puede ser el peer | Deja el 3er nodo vacío o pon el tercer servidor real. |
| `AVISO: el 3er nodo ... NO responde en TCP 445` | Este servidor no tiene ruta al 3er nodo | Configura el 3er nodo en el servidor que sí llega (el Pasivo1), o pide el permiso de firewall. |
| `AVISO: C$ del peer ... aun no accesible` | El peer todavía no está instalado, o firewall, o password distinto | Termina de instalar el otro nodo y verifica `Test-Path \\<peer>\C$`. |
| `AVISO: <peer> no tiene llaves IIS exportadas` | Instalación fuera de orden | Re-corre `Instalar.bat` aquí cuando el nodo de arriba esté instalado. |
| `Cannot bind argument to parameter 'InfraPass'` | Paquete con petición de contraseña en BAT | Usa este paquete: ya no pide el password en el `.bat`. |
| Los cambios de IIS no se propagan | Quedó en DryRun | Re-corre `Instalar.bat` respondiendo `S` a "IIS EN VIVO" en los nodos. |

## 9. Cambios posteriores

| Quiero... | Cómo |
|---|---|
| Cambiar peer, rol, hora o el 3er nodo | Vuelve a correr `Instalar.bat` en ese nodo con las respuestas nuevas. Es idempotente. |
| Quitar la ráfaga de un nodo | Re-corre `Instalar.bat` dejando el 3er nodo **vacío**: la tarea `HASyncDaily` se elimina sola. |
| Invertir Activo y Pasivo1 (failover) | `Invertir-Roles.bat` en cualquiera de los dos. La ráfaga sigue saliendo del nodo que tiene el 3er nodo configurado. |
| Reiniciar las tareas sin reinstalar | `Reiniciar-Tareas.bat`. |
| Ver qué está haciendo | `C:\Supervisor\logs\webconfig_sync.log`, `iis_sync.log`, `daily_sync.log`. |

## 10. Desinstalar (sin tocar IIS ni los portales)

Primero detén las tareas y confirma que sus motores han terminado. Después, en el nodo que se quiera sacar, PowerShell como administrador:

```powershell
Unregister-ScheduledTask WebConfigSync -Confirm:$false
Unregister-ScheduledTask IISSync       -Confirm:$false
Unregister-ScheduledTask IISSync-Apply -Confirm:$false
Unregister-ScheduledTask HASyncDaily   -Confirm:$false   # solo donde exista
```

Eso quita **solo las tareas de réplica**. No desinstala IIS ni sus roles, no toca sitios, app pools, bindings ni `applicationHost.config`, y no altera los datos de los portales. Conserva la carpeta `C:\Supervisor` (motores, registros y respaldos propios) hasta cerrar la revisión.

## 11. Dónde está cada cosa

| Qué | Dónde |
|---|---|
| Motores y configuración en el servidor | `C:\Supervisor\` (`cluster.config`, `logs\`, `state\`, `incoming\`) |
| Registros | `C:\Supervisor\logs\webconfig_sync.log`, `iis_sync.log`, `daily_sync.log` |
| Respaldo de `applicationHost.config` antes de cada aplicación | `C:\Supervisor\state\apphost-bak\` |
| Notas técnicas de evolución | `CAMBIOS-2026-09-11.md` (raíz del paquete) |
| Documentación de seguridad | `OPERACION-Y-SEGURIDAD.md`, `EXCEPCIONES-SEGURIDAD.md`, `FAQ-SEGURIDAD.md` |
