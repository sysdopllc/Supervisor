# SYSDOP LLC — Formulario de permisos A-A-A

Ejemplo ficticio. No aprobado. Solicitud SYSDOP-HA-EXAMPLE-001.

Malla de tres nodos; cada nodo replica a sus dos peers.

| Origen | Destino | Protocolo | Puerto |
|---|---|---|---|
| NODE-A / 192.0.2.10 | NODE-B / 192.0.2.20 | TCP | 445 |
| NODE-A / 192.0.2.10 | NODE-C / 198.51.100.30 | TCP | 445 |
| NODE-B / 192.0.2.20 | NODE-A / 192.0.2.10 | TCP | 445 |
| NODE-B / 192.0.2.20 | NODE-C / 198.51.100.30 | TCP | 445 |
| NODE-C / 198.51.100.30 | NODE-A / 192.0.2.10 | TCP | 445 |
| NODE-C / 198.51.100.30 | NODE-B / 192.0.2.20 | TCP | 445 |

Responsables por rol: Plataforma y Seguridad. Ventana, caducidad y decisión pendientes.
Ver DOCX para alcance, evaluación, validación y reversión.
