# Supervisor HA

**SYSDOP LLC · Open source · MIT**

Herramientas PowerShell para replicar archivos y configuración de IIS entre
servidores Windows. Usan FileSystemWatcher, robocopy, SMB y tareas programadas.
Cada carpeta contiene una variante independiente y su instalador.

| Variante | Flujo | Guía |
|---|---|---|
| Activo–Activo | Dos nodos, réplica bidireccional | [A–A](HA%20Activo%20Activo/README.md) |
| Activo–Pasivo | Réplica unidireccional y cambio manual de roles | [A–P](HA%20Activo%20Pasivo/README-A-P.md) |
| Activo–Pasivo–Pasivo | A→B por eventos; B→C mediante tarea diaria | [A–P–P](HA%20Activo%20Pasivo%20Pasivo/README-A-P-P.md) |
| Activo–Activo–Activo | Malla de tres nodos | [A–A–A](HA%20Activo%20Activo%20Activo/README-A-A-A.md) |

## Antes de instalar

Esta publicación conserva los motores y documenta sus límites; no equivale a
una certificación de funcionamiento en tu entorno. Revisa [LIMITACIONES.md](LIMITACIONES.md).
Necesitas Windows, IIS ya instalado, PowerShell de Windows, permisos administrativos,
SMB entre los nodos y una cuenta de servicio autorizada. El paquete no instala IIS.
La publicación no incluye credenciales, certificados ni configuración de un despliegue real.

1. Elige **una** topología. No instales varias variantes sobre las mismas tareas.
2. Prepara un laboratorio aislado con datos ficticios y respaldos.
3. Configura `$AppPaths` en los motores. Las rutas `E:\ExampleApps`,
   `E:\ExampleMedia` y `C:\inetpub\wwwroot\example-site` son ejemplos.
4. Revisa el documento de seguridad y el formulario de permisos de esa carpeta.
5. Ejecuta el instalador por nodo, primero el primario de llaves, indicando tus
   nombres, cuentas, roles y direcciones. Mantén IIS en `DryRun` hasta validar.
6. Comprueba contenido, hashes, permisos, borrados, reinicios y recuperación.
   **`DryRun` solo afecta la aplicación continua de IIS: la instalación cambia
   registro, firewall, tareas y puede importar llaves; la réplica de archivos es real.**

## Documentación para operaciones y seguridad

Cada variante conserva documentación de arquitectura, autenticación, cambios
de sistema, controles de seguridad, respuesta a alertas, registros, instalación
y retirada. Incluye un instructivo PDF y un formulario DOCX de SYSDOP LLC,
recreados con datos ficticios. No constituyen una solicitud aprobada.

La [guía detallada A–P–P](HA%20Activo%20Pasivo%20Pasivo/GUIA-PASO-A-PASO.md)
describe el orden de instalación y la ráfaga diaria.

## Convenciones públicas

Los ejemplos utilizan `192.0.2.0/24`, `198.51.100.0/24` y `203.0.113.0/24`
([RFC 5737](https://www.rfc-editor.org/rfc/rfc5737.txt)); dominios `example.com`
y nombres de equipo `NODE-A`, `NODE-B`, `NODE-C`
([RFC 2606](https://www.rfc-editor.org/rfc/rfc2606.txt)). Son documentación,
no direcciones que debas desplegar en una red real. Los valores de loopback
del código son controles para rechazar el propio equipo.

## Licencia y contribuciones

Autor y responsable de esta edición: **SYSDOP LLC**. Licencia [MIT](LICENSE):
puedes utilizar, modificar y distribuir el software conservando su aviso.
Consulta [CONTRIBUTING.md](CONTRIBUTING.md) y [SECURITY.md](SECURITY.md).
