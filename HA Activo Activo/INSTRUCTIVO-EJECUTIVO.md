# SYSDOP LLC — Supervisor HA A-A

## Propósito

Dos nodos con réplica bidireccional por eventos.

## Preparación

Elegir una sola variante. Preparar Windows/IIS, cuenta de servicio autorizada, certificados y respaldo. Configurar rutas de ejemplo antes de instalar.

## Orden de instalación

Instalar primero el primario de llaves. En cadena: Activo, Pasivo1, Pasivo2. En malla: configurar los demás peers y el primario. En Activo–Pasivo: roles opuestos.

## Efectos reales

El instalador modifica registro, firewall, tareas y llaves de IIS. DryRun solo limita la aplicación continua de IIS; la réplica de archivos es real.

## Datos de ejemplo

NODE-A: 192.0.2.10; NODE-B: 192.0.2.20; NODE-C: 198.51.100.30. Cuenta EXAMPLE\svc-supervisor. Direcciones TEST-NET para documentación, no para desplegar.

## Pruebas

Crear, modificar, renombrar y borrar datos ficticios; comparar hashes y ACL. Probar reinicio, desconexión y recuperación. Validar IIS en DryRun y Live dentro del laboratorio.

## Seguridad

Revisar flujos SMB y ACL; proteger llaves y respaldos. Conservar telemetría. Una alerta no se descarta por usar ejecutables nativos. No aplicar exclusiones globales de antivirus o EDR.

## Limitaciones

La réplica no sustituye un respaldo y no aporta quorum, fencing ni balanceo. Activo–Activo conserva el flujo visible de contraseña. Los desplegadores A–P/A–P–P no configuran roles opuestos. Consultar LIMITACIONES.md.

## Retirada

Detener tareas y verificar los motores antes de desregistrarlas. Conservar evidencia. No eliminar IIS, certificados ni datos de aplicaciones.

## Documentación completa

README, OPERACION-Y-SEGURIDAD, EXCEPCIONES-SEGURIDAD, FAQ-SEGURIDAD, IIS-HA-Enfoques y formulario público. Licencia MIT. Autor: SYSDOP LLC.
