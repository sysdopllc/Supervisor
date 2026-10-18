# Supervisor HA — A-A-A

**SYSDOP LLC · MIT**

Malla de tres nodos; cada nodo replica a sus dos peers.

## Contenido y preparación

Esta carpeta contiene los motores de archivos e IIS, el instalador por nodo,
documentación de seguridad, un instructivo PDF y un formulario DOCX público.
Los paquetes son independientes; no mezclar variantes sobre las mismas tareas.
Guía específica: README-A-A-A.md.

1. Preparar Windows e IIS con cuentas y certificados autorizados.
2. Revisar `$AppPaths` en los motores. Las rutas `E:\ExampleApps`,
   `E:\ExampleMedia` y `C:\inetpub\wwwroot\example-site` son ilustrativas.
3. Autorizar los flujos SMB de la topología y evaluar UAC/firewall del instalador.
4. Ejecutar `Instalar.bat` por nodo, primero el primario de llaves. Indicar los
   peers y roles del laboratorio. Mantener IIS en DryRun hasta validar.
5. Probar archivos, ACL, hashes, borrados, reinicio, recuperación y sitios IIS.

**DryRun limita IIS, no la instalación ni la réplica de archivos.**
La instalación por nodo pide la contraseña oculta en PowerShell cuando no se proporciona InfraPass.
El desplegador remoto opcional requiere revisar permisos, red y tratamiento de credenciales.

## Componentes y funcionamiento

- `Sync-WebConfig.ps1`: FileSystemWatcher, cola, reintentos, robocopy y tombstones.
- `Sync-IIS.ps1`: envía/aplica configuración de IIS, con respaldo y validación.
- `Instalar.ps1` / `Instalar.bat`: configuración por nodo y tareas programadas.
- `cluster.config`: configuración generada localmente; no distribuirla con datos reales.


La convergencia inicial copia de forma aditiva con `/XO`, pero puede sobrescribir
versiones de la misma ruta. Los borrados posteriores se propagan según la topología.
No hay quorum ni resolución distribuida de conflictos. Respaldar por separado.

## Documentación

- [Operación y seguridad](OPERACION-Y-SEGURIDAD.md): arquitectura, identidades,
  pasos del instalador, registros, llaves RSA, plantilla SOC y retirada.
- [Evaluación de controles](EXCEPCIONES-SEGURIDAD.md): GPO, AppLocker/WDAC,
  antivirus, EDR, ASR, DLP, ZTNA y PAM.
- [Preguntas frecuentes](FAQ-SEGURIDAD.md).
- [Alternativas de arquitectura](IIS-HA-Enfoques.md).
- `Instructivo-Ejecutivo-Supervisor.pdf` y `FORMULARIO PERMISOS SUPERVISOR HA.docx`.
- En la raíz del repositorio: LICENSE, LIMITACIONES.md, CONTRIBUTING.md y SECURITY.md.

## Ejemplos

NODE-A (`192.0.2.10`), NODE-B (`192.0.2.20`) y NODE-C (`198.51.100.30`)
son nombres y direcciones ficticios. EXAMPLE es un dominio ilustrativo y
`svc-supervisor` una cuenta de ejemplo. Ninguno acredita acceso o autorización.
