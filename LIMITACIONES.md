# Alcance y limitaciones

SYSDOP LLC · Supervisor HA

- El nombre HA describe el objetivo de réplica. No incluye balanceador, quorum,
  fencing, resolución distribuida de conflictos ni conmutación automática del tráfico.
- La réplica no sustituye un respaldo. Un borrado puede propagarse a los peers.
  La convergencia inicial usa `/XO` de forma aditiva; no garantiza conservar todas
  las versiones cuando dos archivos comparten ruta. Fecha y tamaño no equivalen
  a comparación criptográfica ni a consistencia de una base de datos en uso.
- Los tombstones son temporales. Un borrado durante una parada o partición puede
  no propagarse; el backstop aditivo puede reintroducir archivos.
- `DryRun` limita la aplicación continua de IIS. El instalador modifica registro,
  habilita reglas de firewall, importa/exporta llaves y registra tareas. El motor
  de archivos copia y propaga borrados aunque IIS siga en `DryRun`.
- Activo–Activo conserva un instalador que pide la contraseña visible en BAT y la
  pasa por argumentos a PowerShell. Los desplegadores remotos también requieren
  revisar el tratamiento de la contraseña. A–P, A–P–P y A–A–A la piden oculta en
  PowerShell cuando no se proporciona `-InfraPass`. No pasar secretos literales
  por consola, archivos de respuesta ni tickets; validar el flujo antes de usarlo.
- `Desplegar-Ambos.ps1` en A–P y A–P–P no configura roles opuestos ni el tercer
  nodo. Para esas variantes usar `Instalar.bat` **en cada nodo**, con su guía.
- El instalador establece `LocalAccountTokenFilterPolicy=1` y habilita el grupo
  `File and Printer Sharing`; no crea automáticamente una regla limitada a los
  peers. Es un cambio de seguridad que debe evaluarse y acotarse en cada entorno.
- Los certificados TLS no se distribuyen. Deben estar instalados y autorizados
  previamente en los almacenes de cada servidor.
- Las llaves RSA exportadas y sus respaldos son material sensible. Comprobar
  ACL, transferencias, adopción y retirada efectiva; no suponer que un mensaje
  de finalización demuestra que no quedan archivos de llave.
- `Invertir-Roles` usa reinicio remoto de tareas cuando es posible; ese control
  puede necesitar RPC además de SMB. La alternativa es reiniciar localmente.
- Quitar una tarea no certifica la parada de un proceso ya en ejecución.
  Detener las tareas, verificar los motores y retirar solo los objetos de la
  réplica. Conservar registros y respaldos; no eliminar sitios, datos ni IIS.
- Los scripts están sin firma Authenticode. La firma y las reglas de confianza
  dependen de cada organización; firmar no garantiza aceptación por un EDR.
- Validaciones de esta edición: análisis de privacidad, sintaxis y comparación
  de cambios. La prueba funcional en Windows/IIS queda pendiente en un laboratorio
  autorizado. No se ha contactado ningún servidor de una organización usuaria.
