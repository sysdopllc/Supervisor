# Alternativas para configuración IIS

SYSDOP LLC

## Réplica de archivo (implementada)

Supervisor envía `applicationHost.config` por SMB. Un proceso con identidad de
servicio lo transmite y otro, SYSTEM, lo aplica con respaldo y validación.
Las llaves RSA deben ser compatibles entre nodos; los certificados TLS se
provisionan por separado. El sentido de la copia depende de la variante.
La configuración local permite operar sin acceder continuamente a un almacén
central, pero requiere resolver divergencias y validar compatibilidad de módulos,
rutas e identidades. No garantiza consistencia ante escrituras simultáneas.

## IIS Shared Configuration (alternativa, no instalada)

Centraliza configuración en un recurso compartido. Requiere diseñar la
disponibilidad, autenticación y protección de ese recurso y su material de
cifrado. No se activa con estos scripts.

## Herramientas de despliegue o réplica de datos (alternativas)

Web Deploy o un proceso de configuración versionada pueden controlar la
publicación de cambios. DFS Replication puede ser una opción para archivos
compatibles con sus requisitos. Son diseños distintos y requieren evaluación
propia; no sustituyen automáticamente el flujo de IIS ni aportan consistencia
de aplicaciones activas. Consultar documentación oficial antes de diseñarlos.
