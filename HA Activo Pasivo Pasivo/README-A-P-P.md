# HA Activo > Pasivo > Pasivo (3 nodos en cadena)

> Elaborado por SYSDOP LLC

Variante de **tres nodos en cadena**. El Activo replica en **tiempo real** al
Pasivo1, y el **Pasivo1** reenvia una **rafaga diaria** a un **tercer nodo
(Pasivo2)** a una hora fija (por defecto **23:00**).

```
   Activo  --(tiempo real, inmediato)-->  Pasivo1  --(rafaga diaria 23:00)-->  Pasivo2
```

- **Activo > Pasivo1**: el mismo motor en tiempo real del modo A>P (watcher,
  cola, tombstone, push con robocopy `/XO`). Unidireccional: el pasivo no
  copia de vuelta.
- **Pasivo1 > Pasivo2**: una **vez al dia** el nodo que tiene configurado el 3er
  nodo (normalmente el **Pasivo1**) empuja una copia de las carpetas +
  `applicationHost.config` al Pasivo2 (DR/respaldo). Como el Pasivo1 es la
  replica en tiempo real del Activo, el Pasivo2 recibe lo mismo que tiene el Activo.
- **Por que en cadena**: la rafaga sale del nodo que **si tiene ruta SMB (TCP 445)**
  al 3er nodo. Si el Activo no llega al 3er nodo (firewall), el Pasivo1 lo hace
  por el. Ningun nodo copia de vuelta al Activo.

## Piezas nuevas respecto a A>P
- `Sync-Daily.ps1`: la rafaga diaria. Corre en el nodo que tiene `Tertiary=` en su
  `cluster.config` (lo dispara la tarea `HASyncDaily`), sea Activo o Pasivo.
  Aditivo `/XO` por defecto (no poda borrados en el Pasivo2); con `-Mirror` hace
  espejo exacto `/MIR` (usalo con cuidado).
- `cluster.config` gana `Tertiary=` (3er nodo al que ESTE nodo envia la rafaga) y
  `TertiaryTime=` (hora HH:mm).
- El instalador registra la tarea programada `HASyncDaily` (diaria a
  `TertiaryTime`) en el nodo donde indiques el 3er nodo, y la elimina si
  reinstalas ese nodo sin 3er nodo.
- Las llaves de cifrado de IIS tambien viajan por la cadena: el Pasivo1, tras
  adoptar las del Activo, las deja exportadas para el Pasivo2; el Pasivo2 las
  adopta y las borra de ambos al instalarse.

## Instalacion (3 nodos, en este orden)
Doble clic en **`Instalar.bat`** en cada servidor. **No hay IPs fijas**: el
instalador pregunta todo, asi el mismo paquete sirve para cualquier trio de
servidores.

> Paso a paso detallado (que se responde en cada pantalla, que se ve al instalar,
> verificacion y problemas frecuentes): **`GUIA-PASO-A-PASO.md`** en esta carpeta.

| Orden | Nodo | Rol | Peer | 3er nodo | Primario |
|---|---|---|---|---|---|
| 1 | **ACTIVO** | `A` | IP del Pasivo1 | vacio | `S` |
| 2 | **PASIVO1** | `P` | IP del Activo | IP del Pasivo2 + hora | `N` |
| 3 | **PASIVO2** | `P` | IP del Pasivo1 | vacio | `N` |

Al final, `Instalar.ps1` pide el **password** de la cuenta **oculto** (no se ve al
escribir) y lo valida contra Windows antes de tocar nada.

Si no hay 3er nodo, deja el 3er nodo en blanco en todos: queda como **A>P de 2
nodos**, identico al folder "HA Activo Pasivo".

> Si el Activo si llega al 3er nodo por 445 y prefieres que la rafaga salga de el,
> indica el 3er nodo en el Activo en vez de en el Pasivo1 (nunca en los dos).

## Red (SMB / TCP 445)
- Activo <-> Pasivo1: replica en tiempo real y llaves IIS al instalar.
- Pasivo1 <-> Pasivo2: rafaga diaria y llaves IIS al instalar.
- Activo -> Pasivo2: **no hace falta**.

El instalador prueba el 445 hacia el 3er nodo y avisa si no responde.

## Probar la rafaga sin esperar a las 23:00
En el nodo que envia la rafaga (normalmente el Pasivo1), PowerShell elevado:
```
Start-ScheduledTask -TaskName HASyncDaily
```
Revisa `C:\Supervisor\logs\daily_sync.log`.

## Invertir roles
`Invertir-Roles.bat` intercambia **Activo <-> Pasivo1** (el par de tiempo real).
La rafaga sigue saliendo del nodo que tiene `Tertiary=` (no depende del rol), asi
que el Pasivo2 la sigue recibiendo despues de un failover.

## Desinstalar (sin tocar IIS ni los portales)
Primero detener las tareas y verificar que los motores han terminado. Después, en el nodo que se quiera quitar, PowerShell elevado:
```
Unregister-ScheduledTask WebConfigSync -Confirm:$false
Unregister-ScheduledTask IISSync       -Confirm:$false
Unregister-ScheduledTask IISSync-Apply -Confirm:$false
Unregister-ScheduledTask HASyncDaily   -Confirm:$false   # solo en el nodo que envia la rafaga
```
Esto solo quita las tareas de replica. **No** desinstala IIS ni sus roles, **no**
borra ni modifica sitios, app pools, bindings ni `applicationHost.config`, y **no**
borra ni altera los datos de los portales. La carpeta `C:\Supervisor` (motores,
logs y respaldos propios) debe conservarse hasta cerrar la revisión.

## Seguridad, SMB, firewall, llaves IIS
Aplican **igual** que en Activo<>Activo / A>P. Ver `OPERACION-Y-SEGURIDAD.md`,
`EXCEPCIONES-SEGURIDAD.md`, `FAQ-SEGURIDAD.md`, `IIS-HA-Enfoques.md` en esta
carpeta. La cuenta de las tareas debe existir con el **mismo nombre y password**
en los 3 nodos.
