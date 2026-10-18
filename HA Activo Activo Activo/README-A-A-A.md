# HA Activo > Activo > Activo (malla de 3 nodos)

> Elaborado por SYSDOP LLC

Variante de **malla (mesh) de tres nodos**. Los **tres son ACTIVOS**: cada uno
replica **bidireccional y en tiempo real** con los otros dos. No hay pasivos, no
hay "maestro". Gana la versión **más reciente por archivo**.

```
        NODO 1  <───────────>  NODO 2
           \                    /
            \                  /
             \                /
              \              /
               <── NODO 3 ──>
     (los 3 se replican entre si, en tiempo real, en ambos sentidos)
```

## Para qué sirve (ejemplo de tres servidores de contenido desincronizados)
Cuando los 3 servidores tienen datos/multimedia distintos y **no se sabe cuál
está más al día**, esta malla los hace **converger**:

- La **convergencia inicial es ADITIVA** (robocopy `/XO`, **no** `/MIR`): al
  arrancar, cada nodo copia hacia y desde cada peer lo que **falta o es más
  nuevo**, **sin borrar nada**. Resultado: la **UNIÓN** de los datos de los 3
  queda en los 3. Un archivo con una ruta diferente se agrega; las versiones que comparten ruta pueden sobrescribirse según fecha/tamaño.
- De ahí en adelante, cada cambio (nuevo/modificado/renombrado/borrado) se
  propaga al instante a los otros dos. **Gana el más reciente** (por fecha+size),
  así que la edición más nueva termina en los 3 sin ciclos (anti ping-pong por
  timestamp).

> IMPORTANTE (borrados): tras la convergencia inicial, un **borrado** en un nodo
> **sí** se propaga a los otros (con tombstone anti-resurrección). Si lo que
> quieres es SOLO rellenar huecos sin arriesgar borrados, arranca la malla, deja
> que converja la unión, y recién entonces opera normal. La convergencia inicial es aditiva, pero no preserva todas las versiones de una misma ruta; realizarla sobre copias de laboratorio.

## Piezas (respecto a la versión de 2 nodos)
- `cluster.config` usa **`Peers=hostA,hostB`** (lista) en vez de `Peer=host`.
  El motor descarta automáticamente el propio nombre y deduplica. Sigue siendo
  compatible con el formato viejo `Peer=host` (queda como malla de 1 peer).
- `Sync-WebConfig.ps1`: replica de archivos a **todos los peers** a la vez, con
  reintentos **independientes por peer** (que un archivo esté bloqueado en un
  nodo no frena a los demás).
- `Sync-IIS.ps1`: cada nodo empuja su `applicationHost.config` a cada peer con
  **nombre por-origen** (`applicationHost.<EQUIPO>.config`) para que dos nodos no
  se pisen; el Applier aplica el **más reciente** de todos los entrantes.
- `Instalar.ps1` / `Instalar.bat`: preguntan la **lista** de peers y (en los no
  primarios) el **nodo primario** de llaves IIS.

## Instalación (3 nodos)
Doble clic en **`Instalar.bat`** en **cada** servidor. Instala **primero el
primario**.

1. **NODO 1 (primario)** — responde `S` a "Primario?". Peers = `NODO2,NODO3`.
2. **NODO 2** — responde `N`. Peers = `NODO1,NODO3`. Nodo primario = `NODO1`.
3. **NODO 3** — responde `N`. Peers = `NODO1,NODO2`. Nodo primario = `NODO1`.

Puedes usar nombres (`NODE-A`) o IPs (`192.0.2.20`). El instalador escribe
`cluster.config`, valida el usuario/SMB, sincroniza llaves IIS y arranca las
tareas. La replica de IIS arranca en **DryRun** (solo registra) hasta que valides
`C:\Supervisor\logs\iis_sync.log` en los 3 y pases `$Mode='Live'`.

> Opcional (requiere WinRM): `Desplegar-Todos.ps1` instala los 3 nodos de una
> sola corrida desde el primario. Si WinRM no está, usa `Instalar.bat` por nodo
> (requiere validar los prerrequisitos).

## Escala a más nodos
La misma malla sirve para **N nodos**: en cada uno, `Peers=` = todos los demás.
El costo de red crece con N (cada cambio va a N-1 peers); para 3 es ideal.

## Seguridad, SMB, firewall, llaves IIS
Aplican **igual** que en las otras topologías. Ver `OPERACION-Y-SEGURIDAD.md`,
`EXCEPCIONES-SEGURIDAD.md`, `FAQ-SEGURIDAD.md`, `IIS-HA-Enfoques.md` en esta
carpeta. Cada nodo necesita permiso SMB (C$/E$) hacia los otros dos.

## Verificación rápida (tras instalar los 3)
- `C:\Supervisor\logs\webconfig_sync.log`: debe listar `peers=2 [NODO2, NODO3]` y
  líneas `SYNC carpeta ... push=.. pull=..` por cada peer al arrancar.
- Crea un archivo de prueba en `E:\ExampleApps` del NODO 1 → debe aparecer en el
  2 y el 3 en segundos (`PUSH NODO2: ...` / `PUSH NODO3: ...`).
- Repite creando en el NODO 2 y en el 3 → debe converger en los otros dos.
