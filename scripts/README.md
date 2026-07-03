# Huawei Dorado iSCSI Setup for Proxmox Cluster

Script interactivo para configurar conexiones iSCSI a cabinas **Huawei Dorado** desde un cluster **Proxmox VE**.

## Instalación

En cada nodo Proxmox, ejecutar como **root**:

```bash
cd /root
curl -LO https://raw.githubusercontent.com/licosta/proxmox/main/scripts/pve_iscsi_dorado.sh
chmod +x pve_iscsi_dorado.sh
./pve_iscsi_dorado.sh
```

**Copiar y pegar las 5 líneas tal cual. No requiere nada más.**

## Uso

```bash
./pve_iscsi_dorado.sh
```

## Qué hace

El script te guía paso a paso por 20 fases:

1. **Bienvenida** — verificación de root y requisitos
2. **Cluster** — nombres de nodos, verificación SSH
3. **Cabina Dorado** — IPs de portales, IQN del target, LUN ID
4. **Red** — interfaces dedicadas a iSCSI, MTU
5. **CHAP** — autenticación (opcional)
6. **Storage PVE** — nombre y tipos de contenido
7. **Avanzado** — alias multipath, modo verbose
8. **Resumen** — confirmación antes de ejecutar
9. **Paquetes** — open-iscsi, multipath-tools, lsscsi en todos los nodos
10. **IQNs iniciador** — genera/configura IQN por nodo
11. **iface iSCSI** — crea iface dedicada con MAC y MTU
12. **Descubrimiento** — sin login todavía
13. **Autorización** — ⬅️ te muestra los IQNs y espera a que autorices en Dorado
14. **Login** — conecta a ambos portales en todos los nodos
15. **Multipath** — genera `multipath.conf` optimizado ALUA para Dorado
16. **WWIDs** — detecta WWIDs de los discos Dorado (4 métodos)
17. **Nodo primario** — identifica desde qué nodo se gestiona el storage
18. **Storage** — crea el storage iSCSI en PVE (se replica a todos los nodos)
19. **Servicios** — habilita open-iscsi, multipathd, iscsid
20. **Verificación** — tabla de estado por nodo

## Flujo de autorización en Dorado

En el paso 13, el script te muestra una tabla con los IQNs de cada nodo y te indica qué hacer en la consola de gestión de Dorado:

```
PASO 1: Crear Host → Configuración > Hosts > Crear Host
PASO 2: Añadir IQNs de iniciador al host
PASO 3: Asociar el host con el target iSCSI
PASO 4: Mapear las LUNs al host
```

Una vez completado, presionás Enter y el script continúa con el login.

## Ejecución distribuida

- Los paquetes se instalan en todos los nodos vía SSH
- Los IQNs se configuran por nodo individualmente
- El login se hace en todos los nodos (Portal A + Portal B si hay ALUA)
- El `multipath.conf` se despliega a todos los nodos
- El storage PVE se crea desde el nodo donde se ejecuta y se sincroniza a todos vía `pmxcfs`

## Autenticación CHAP

Si Dorado usa CHAP, el script te pide usuario y contraseña en el paso 5. Las credenciales se injectan en la base de datos iscsiadm antes del login.

## Notas

- Requiere SSH passwordless a los nodos remotos
- El usuario debe ser root
- Tested con Dorado serie 5000/6000/V6
- Multipath usa política `group_by_prio` con `prio alua` para ALUA activo-pasivo
