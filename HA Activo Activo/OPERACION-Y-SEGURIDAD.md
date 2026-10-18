# Supervisor HA — Operación y seguridad

**SYSDOP LLC** · Guía pública para Infraestructura, Seguridad de la Información y SOC.
Los nombres, cuentas y direcciones son ejemplos ficticios. Este documento describe
el comportamiento del código; no acredita la autorización de ninguna instalación.

## 1. Arquitectura y orden de instalación

Hay cuatro paquetes: A–A bidireccional, A–P unidireccional, A–P–P en cadena y
A–A–A en malla. Sigue el README específico; no combines sus motores.
Instala primero el primario de llaves. En cadena sigue A, B, C; en malla indica
los peers y el primario de llaves de cada nodo. En A–P asigna roles opuestos.

El instalador realiza estos pasos, con diferencias según la variante:

1. Recoge usuario, peers, rol, primario y modo de IIS. A–P, A–P–P y A–A–A piden
   la contraseña oculta y la validan si no se proporciona `-InfraPass`.
   A–A conserva el flujo BAT de contraseña visible: revisar LIMITACIONES.md.
2. Establece `LocalAccountTokenFilterPolicy=1`, incluso con cuenta de dominio,
   y habilita el grupo de firewall `File and Printer Sharing`.
3. Comprueba la cuenta local cuando corresponde, copia los motores y escribe
   `C:\Supervisor\cluster.config`. Las pruebas de conectividad no sustituyen
   una prueba con la identidad real de las tareas.
4. Exporta/importa llaves RSA de IIS según el primario y la topología.
   Revisar los respaldos y los archivos exportados al terminar.
5. Registra y arranca `WebConfigSync`, `IISSync`, `IISSync-Apply` y, donde
   corresponda, `HASyncDaily`.

**`DryRun` solo limita la aplicación continua de IIS.** No convierte el
instalador ni el motor de archivos en una simulación. La sincronización de
llaves durante la instalación puede modificar la configuración local.

## 2. Red, cuentas y configuración

La réplica utiliza recursos administrativos SMB (`C$`, `E$`) por TCP 445.
Autoriza exclusivamente los pares requeridos por la topología. El código
habilita un grupo de firewall existente: eso no demuestra restricción a los peers.
Los desplegadores opcionales usan WinRM; el cambio remoto de roles puede usar
RPC mediante `schtasks`. Instalar y reiniciar localmente evita depender de esos
canales de administración remota.

| Configuración | Uso |
|---|---|
| `Peer=` | Peer de A–A/A–P; en cadena depende del nodo |
| `Peers=` | Lista de peers en malla |
| `Role=Active` o `Passive` | Dirección en A–P y cadena |
| `Tertiary=` / `TertiaryTime=` | Destino y hora de la ráfaga diaria |
| `IsPrimary=` | Primario de llaves |

Dos modelos de identidad:

- **Local:** `.\svc-supervisor`, creada y habilitada en cada nodo, con el mismo
  nombre y contraseña y los permisos administrativos requeridos. Revisar el
  impacto de UAC remoto y las políticas de inicio de sesión por lotes.
- **Dominio:** `EXAMPLE\svc-supervisor` o `ad.example.com\svc-supervisor`,
  autorizada como administrador local en los nodos. La política del dominio
  puede bloquear la cuenta tras intentos fallidos. `LocalAccountTokenFilterPolicy`
  no es necesario para este modelo, aunque el instalador actual lo establece.

`WebConfigSync` e `IISSync` usan la cuenta elegida; `IISSync-Apply` usa SYSTEM.
El instalador actual no admite gMSA sin adaptación. Coordina la rotación de
credenciales con el registro de tareas; no desactives la caducidad por defecto.
No guardes contraseñas en documentación, argumentos literales ni formularios.

## 3. Carpetas y exclusiones

Edita `$AppPaths` en `Sync-WebConfig.ps1` y, en cadena, también en
`Sync-Daily.ps1`. La edición pública contiene rutas ilustrativas:

```powershell
$AppPaths = @('E:\ExampleApps', 'E:\ExampleMedia', 'C:\inetpub\wwwroot\example-site')
```

Usa la misma selección en los nodos correspondientes. Las carpetas inexistentes
se omiten; revisa los logs para distinguir omisión de réplica correcta. Después
de editar, actualiza el motor instalado y reinicia su tarea. Retirar una ruta
de la lista deja de replicarla; no elimina el contenido existente.

Los motores excluyen `logs`, `Logs`, `Log`, `*.log`, `*.tmp`, `*.etl`,
`log.sqlite`, `*.sqlite-wal` y `*.sqlite-shm`. Revisa estas exclusiones para tu
aplicación: una base de datos activa no queda consistente por copiar su archivo.
`applicationHost.config` se gestiona por separado con `Sync-IIS.ps1`.

## 4. Motores y registros

FileSystemWatcher genera eventos; una cola organiza cambios, renombrados,
borrados y reintentos. Robocopy compara fechas/tamaños con `/XO`; no usa hashes
para resolver conflictos. Hay convergencia inicial y repaso periódico.
Los tombstones reducen la reaparición de borrados durante una ventana breve;
no sustituyen un registro durable de cambios ni un respaldo.

El Pusher de IIS envía `applicationHost.config`; el Applier compara la versión
entrante, respalda la local y valida la aplicación con `appcmd list config`.
La copia completa requiere que módulos, rutas, identidades y certificados sean
compatibles en todos los nodos. Validar el archivo no prueba que todos los sitios
respondan correctamente. Los certificados TLS se provisionan por separado.

| Artefacto | Ruta |
|---|---|
| Archivo/cola de eventos | `C:\Supervisor\logs\webconfig_sync.log` |
| Aplicación de IIS | `C:\Supervisor\logs\iis_sync.log` |
| Ráfaga diaria | `C:\Supervisor\logs\daily_sync.log` |
| Respaldos de configuración | `C:\Supervisor\state\apphost-bak\` |
| Respaldos de llaves | `C:\Supervisor\state\iiskeys-bak-*` |
| Configuración recibida | `C:\Supervisor\incoming\` |

```powershell
Get-Content 'C:\Supervisor\logs\webconfig_sync.log' -Wait -Tail 30
Get-Content 'C:\Supervisor\logs\iis_sync.log' -Tail 50 | Select-String 'WARN|ERROR'
Get-ScheduledTask WebConfigSync,IISSync,IISSync-Apply | Get-ScheduledTaskInfo
```

Prueba con archivos ficticios: crear, modificar, renombrar y borrar; compara
hashes y ACL en destino. Prueba también una interrupción, reinicio y reconexión.
En cadena ejecuta `Start-ScheduledTask HASyncDaily` en el emisor y comprueba los
datos del tercer nodo. Mide latencia: no se garantiza un plazo fijo.
Para IIS, prueba primero DryRun y luego Live en laboratorio; comprueba sitios,
pools y respuestas HTTP. Un resultado 0 de tarea no certifica el conjunto.

## 5. Inventario para Seguridad

| Componente | Función y acceso |
|---|---|
| `powershell.exe` | Instalador y motores; algunas tareas usan ExecutionPolicy Bypass |
| `robocopy.exe` | Archivos y configuración sobre SMB; conserva metadatos y ACL según flags |
| `aspnet_regiis.exe` | Exporta/importa contenedores RSA de IIS |
| `appcmd.exe` | Valida la configuración IIS aplicada |
| `Register-ScheduledTask` / `schtasks.exe` | Registro, consulta y control de tareas |
| `FileSystemWatcher`, colas .NET | Vigilancia y gestión de eventos |
| `WindowsIdentity`, CIM, `Get-NetIPAddress` | Identidad, procesos y direcciones locales |
| `PrincipalContext.ValidateCredentials` | Validación contra Windows/dominio en variantes compatibles |
| `TcpClient` | Prueba TCP 445 en cadena |

Los motores no requieren servicios de internet. DNS, autenticación de dominio,
validación de certificados y administración pueden generar tráfico adicional
del sistema operativo. No deducir aislamiento total solo por revisar el código.

### Llaves RSA y alertas del SIEM

`aspnet_regiis -px/-pi` permite exportar/importar `iisConfigurationKey` e
`iisWasKey`, que intervienen en la protección de configuración de IIS.
Exportarlas con clave privada es una operación sensible. El instalador intenta
coordinar su adopción y limpieza; en cadena hay archivos que deben permanecer
hasta que el siguiente nodo los adopte. Verifica cada etapa y los respaldos.

Una alerta como `EXAMPLE-IIS-KEY-EXPORT` es un **nombre ficticio**. No se puede
clasificar como benigna solo por el nombre del ejecutable. Correlaciona hash del
script, árbol de procesos, cuenta, hosts, horario, ticket, destinos y ACL.
No publiques llaves ni contenido real de `applicationHost.config` como evidencia.

Plantilla para el SOC (completar con evidencia del despliegue):

> Solicitud EXAMPLE-CHANGE-001: se solicita validar la actividad de Supervisor HA
> en NODE-A y NODE-B, dentro de la ventana autorizada. Adjuntamos hashes de scripts,
> identidad de ejecución, procesos y destinos esperados. La exportación/importación
> RSA corresponde al procedimiento descrito; confirmar que los eventos observados
> coinciden y documentar adopción, ACL, respaldo y retirada de archivos temporales.
> Este texto es una plantilla y no certifica que una ejecución haya sido autorizada.

## 6. Cambios, retirada y continuidad

Para cambiar peers/roles utiliza el instalador por nodo con la guía de la variante.
Antes de invertir roles compara los datos y confirma cuál es la fuente válida.
Conserva respaldos independientes y prueba restauración; réplica no es backup.

Para retirar la solución: detener las tareas de réplica, verificar que sus motores
han terminado y después desregistrar solo esas tareas. En cadena incluir la tarea
diaria donde exista. Conservar logs y respaldos hasta cerrar la revisión.
No eliminar IIS, sus sitios, certificados ni los datos replicados. Revertir cambios
de firewall/UAC solo después de revisar sus demás consumidores y obtener aprobación.
