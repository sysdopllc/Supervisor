# Supervisor HA — Evaluación de controles de seguridad

**SYSDOP LLC** · Guía reutilizable. No activa ni concede excepciones.

## Principio

Primero medir y reproducir un bloqueo; después evaluar una excepción mínima,
con responsable, ticket, plazo y reversión. Mantener antivirus, EDR, AMSI y
telemetría. No excluir globalmente PowerShell, robocopy, carpetas web ni llaves.
La presencia de binarios firmados de Windows no garantiza que su uso sea legítimo.

## 1. Qué puede generar alertas

| Acción | Control que puede observarla |
|---|---|
| Copia y borrado de muchos archivos | Antivirus, DLP, anti-ransomware, integridad |
| Exportación/importación RSA | Detección de acceso a llaves/credenciales |
| Creación de tareas de arranque | Persistencia y administración privilegiada |
| PowerShell con Bypass y ventana oculta | AMSI, EDR, control de aplicaciones |
| UAC remoto y shares administrativos | Hardening y detección de movimiento lateral |

## 2. GPO y hardening

Revisar Execution Policy, Constrained Language Mode, derechos de inicio por lotes,
reglas de denegación, grupos restringidos, shares administrativos y firewall.
Una GPO puede impedir ejecutar el script aunque use Bypass. No cambiarla sin
aprobación. El instalador actual establece UAC remoto y habilita un grupo de
firewall; comparar el antes/después y limitar la exposición mediante la política
autorizada del entorno. Consultar LIMITACIONES.md en la raíz del repositorio.

## 3. AppLocker / WDAC / App Control

Evaluar reglas por firma o hash del contenido revisado. Si se usa una regla por
ruta, impedir que usuarios no autorizados modifiquen esa ruta. Firmar no elimina
la necesidad de una política de confianza ni garantiza ejecución en FullLanguage.
La distribución actual no incluye firmas Authenticode.

## 4. Defender, ASR y Controlled Folder Access

Reproducir el caso con telemetría y revisar la regla concreta. Una exclusión de
proceso puede afectar a todo lo que abre ese proceso; evitar autorizar de forma
general `powershell.exe` o `robocopy.exe`. Distinguir antivirus, ASR y Controlled
Folder Access: una excepción de un control no equivale a una excepción en los
otros. Cualquier permiso debe corresponder al laboratorio/hosts y alcance aprobados.

## 5. Otros EDR y controles de endpoint

CrowdStrike Falcon, Trend Micro, Cisco Secure Endpoint y otros productos se
mencionan únicamente como ejemplos públicos. Su configuración depende de la
versión y de la política de quien despliega. Entregar al administrador el árbol
de procesos, hashes, cuentas, rutas y ventana de cambio; solicitar análisis de
la detección concreta. No asumir que se necesita una exclusión ni que la firma
de un publicador será suficiente. Preservar visibilidad y capacidad de respuesta.

## 6. ZTNA, DLP y PAM

Si una solución ZTNA/SWG (por ejemplo Netskope) interviene en el tráfico interno,
validar el flujo SMB concreto; no crear un bypass de toda la red. DLP también
puede controlar transferencias internas. PAM debe coordinar la rotación con las
tareas programadas. El modelo actual utiliza una contraseña y no implementa gMSA.

## 7. SIEM y material criptográfico

Relacionar exportaciones RSA, cambios de IIS y creación de tareas con el ticket,
identidad, nodos y horario. Mantener alertas por destinos o cuentas imprevistos.
Una ventana de mantenimiento no justifica suprimir toda la detección de llaves.
La plantilla de OPERACION-Y-SEGURIDAD.md requiere evidencia; no declara inocua
una actividad por el simple hecho de usar `aspnet_regiis.exe`.

## 8. Solicitud y cierre

Usar el formulario público de esta carpeta como ejemplo. Registrar alcance,
justificación, riesgos, duración, revisión, reversión y pruebas. Las filas de
ejemplo no son reglas listas para importar. Después de la prueba: verificar el
flujo permitido, un flujo no autorizado, los eventos visibles y la caducidad.
