# Huawei Dorado iSCSI Setup for Proxmox

Script interactivo para configurar conexiones iSCSI a cabinas **Huawei Dorado** en Proxmox VE.

## Instalación

En cada nodo Proxmox, ejecutar como **root**:

```bash
curl -LO https://raw.githubusercontent.com/licosta/proxmox/main/scripts/pve_iscsi_dorado.sh
chmod +x pve_iscsi_dorado.sh
./pve_iscsi_dorado.sh
```

**Copiar y pegar las 3 líneas. No requiere nada más.**

## Uso

Ejecutá este script **en cada nodo Proxmox** por separado. No usa SSH.

- **Cluster:** ejecutá en cada nodo para configurar su iniciador
- **Standalone:** ejecutá una sola vez
- El script te muestra los IQNs de todos los nodos para que los autorices en Dorado

## Qué hace (19 pasos)

1. **Bienvenida** — verificación de root
2. **Cluster** — nombres de nodos (solo para referencia y storage)
3. **Cabina Dorado** — IPs de portales, IQN del target, LUN ID
4. **Red** — interfaces iSCSI (IPs pre-configuradas), ajuste opcional de MTU
5. **CHAP** — autenticación (opcional)
6. **Storage PVE** — nombre y tipos de contenido
7. **Avanzado** — alias multipath, modo verbose
8. **Resumen** — confirmación
9. **Paquetes** — open-iscsi, multipath-tools, lsscsi
10. **IQN iniciador** — configura el IQN de ESTE nodo
11. **iface iSCSI** — crea iface dedicada
12. **Descubrimiento** — descubre targets en portales
13. **Preparación Dorado** — ⬅️ muestra IQNs y dice qué crear en Dorado
14. **Login** — conecta (aparece el iniciador en Dorado)
15. **Autorización post-login** — ⬅️ asociar y autorizar iniciador en Dorado
16. **Multipath** — genera `multipath.conf` optimizado ALUA para Dorado
17. **WWIDs** — detecta WWIDs de los discos Dorado
18. **Storage** — crea el storage iSCSI en PVE
19. **Servicios** — habilita open-iscsi, multipathd, iscsid

## Flujo de autorización en Dorado (dos pasos)

**Paso 13 (antes del login):** El script muestra los IQNs y te dice qué crear en Dorado.

**Paso 14 (login):** El script ejecuta el login — el iniciador aparece en Dorado.

**Paso 15 (post-login):** ⬅️ Asociás y autorizás el iniciador en la consola:
```
1. Buscar el iniciador en Hosts > pve_cluster > Initiators
2. Asociar el/los IQNs al host (Enable)
3. Autorizar (Allow)
4. Verificar LUN mapeada
5. Guardar cambios
```

Importante: hasta que no hacés el login desde Proxmox, el iniciador **no aparece** en Dorado. Primero se hace el login (para que Dorado lo vea) y después se autoriza.

## Sin SSH

Este script NO usa SSH. Cada nodo se configura localmente. El campo "nodos del cluster" es solo para:
- Generar la tabla completa de IQNs
- Crear el storage con los nodos correctos (`--nodes` en `pvesm add`)

Si ejecutás el script en cada nodo, vas generando la tabla de IQNs progresivamente. Al final te dice cuántos nodos faltan por configurar.

## Autenticación CHAP

Si Dorado usa CHAP, el script te pide usuario y contraseña en el paso 5. Las credenciales se injectan en la base de datos iscsiadm antes del login.

## Notas

- Las interfaces de red iSCSI deben tener IP ya configurada (el script solo ajusta el MTU)
- Tested con Dorado serie 5000/6000/V6
- Multipath usa política `group_by_prio` con `prio alua` para ALUA activo-pasivo
