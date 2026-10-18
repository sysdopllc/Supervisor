# Supervisor HA — Preguntas de Seguridad

**SYSDOP LLC** · Ejemplos públicos. Detalle en OPERACION-Y-SEGURIDAD.md.

| Pregunta | Respuesta |
|---|---|
| ¿Qué replica? | Archivos de las rutas configuradas y configuración de IIS, según topología. |
| ¿Es una solución de failover completa? | No: no incluye balanceador, quorum ni fencing. |
| ¿Qué cambia al instalar? | Registro, firewall, archivos propios, llaves/configuración y tareas. |
| ¿DryRun no toca nada? | No: solo limita la aplicación continua de IIS; archivos e instalación son reales. |
| ¿Qué red requiere? | SMB entre peers; administración opcional por WinRM/RPC y dependencias del sistema. |
| ¿Qué identidades usa? | Cuenta autorizada local/dominio para copia; SYSTEM para aplicación de IIS. |
| ¿Soporta gMSA? | No con el instalador actual. |
| ¿Se oculta la contraseña? | En A–P, A–P–P y A–A–A sin InfraPass; A–A conserva el flujo visible. |
| ¿Distribuye certificados TLS? | No; deben estar provisionados en los nodos. |
| ¿Por qué exporta RSA? | Para compatibilizar la configuración protegida de IIS entre nodos. |
| ¿Es benigna cualquier alerta de aspnet_regiis? | No; correlacionar autorización, comandos, hashes y destinos. |
| ¿Se garantizan llaves temporales eliminadas? | No; comprobar limpieza y respaldos en cada etapa. |
| ¿Hay que excluir PowerShell del EDR? | No globalmente; investigar primero la detección concreta. |
| ¿La firma elimina todas las alertas? | No; depende de la política y del comportamiento observado. |
| ¿Réplica equivale a backup? | No; borrados y sobrescrituras pueden propagarse. |
| ¿Preserva todas las versiones? | No; usa fecha/tamaño y no tiene resolución distribuida de conflictos. |
| ¿Sirve para bases de datos activas? | No garantiza consistencia de aplicaciones o bases de datos. |
| ¿Se prueba con direcciones del documento? | No; son TEST-NET. Sustituir por el laboratorio autorizado. |
| ¿Cómo verifico? | Comparar archivos, hashes, ACL, logs y funcionamiento IIS en el destino. |
| ¿Cómo se retira? | Detener y comprobar motores; desregistrar sus tareas y preservar evidencia. |
| ¿El formulario está aprobado? | No; todos sus datos son ficticios y requieren revisión del entorno. |
