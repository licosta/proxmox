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

El script te guía paso a paso por 22 pasos:

1. **Bienvenida** — verificación de root y requisitos
2. **Cluster** — nombres de nodos, detección automática de standalone/cluster
3. **Cabina Dorado** — IPs de portales, IQN del target, LUN ID
4. **Red** — interfaces iSCSI (IPs pre-configuradas), ajuste opcional de MTU
5. **CHAP** — autenticación (opcional)
6. **Storage PVE** — nombre y tipos de contenido
7. **Avanzado** — alias multipath, modo verbose
8. **Resumen** — confirmación antes de ejecutar
9. **Paquetes** — open-iscsi, multipath-tools, lsscsi en todos los nodos
10. **IQNs iniciador** — genera/configura IQN por nodo
11. **iface iSCSI** — crea iface dedicada con MAC y MTU
12. **Descubrimiento** — descubre targets en portales
13. **Preparación Dorado** — ⬅️ te muestra IQNs para crear el Host en Dorado ANTES del login
14. **Login** — conecta a ambos portales (esto hace aparecer los iniciadores en Dorado)
15. **Autorización post-login** — ⬅️ asociar y autorizar cada iniciador en la consola Dorado
16. **Multipath** — genera `multipath.conf` optimizado ALUA para Dorado
17. **WWIDs** — detecta WWIDs de los discos Dorado (4 métodos)
18. **Nodo primario** — identifica desde qué nodo se gestiona el storage
19. **Storage** — crea el storage iSCSI en PVE (se replica a todos los nodos vía pmxcfs)
20. **Servicios** — habilita open-iscsi, multipathd, iscsid
21. **Verificación** — tabla de estado por nodo
22. **Final** — resumen y comandos útiles

## Flujo de autorización en Dorado (dos pasos)

El flujo tiene **dos pausas** para autorización:

**Paso 13 (antes del login):** El script te muestra los IQNs y te dice qué crear en Dorado:
```
PASO 1: Crear Host → Configuración > Hosts > Crear Host
PASO 2: Añadir IQNs de iniciador al host
PASO 3: Asociar el host con el target iSCSI
PASO 4: Mapear las LUNs al host
PASO 5: Guardar cambios
```

**Paso 14 (login):** El script ejecuta el login — esto hace que los iniciadores aparezcan en la consola de Dorado.

**Paso 15 (después del login):** ⬅️ Ahora asociás y autorizás cada iniciador en la consola:
```
PASO 1: Buscar los iniciadores que aparecieron en Hosts > pve_cluster > Initiators
PASO 2: Asociar cada IQN al host
PASO 3: Autorizar (Enable / Allow)
PASO 4: Verificar LUN mapeada
PASO 5: Guardar
```

Esto es importante: hasta que no hacés el login desde Proxmox, el iniciador **no aparece** en Dorado. Por eso primero se hace el login (para que Dorado lo vea) y después se autoriza.

## Ejecución distribuida

- Los paquetes se instalan en todos los nodos vía SSH
- Los IQNs se configuran por nodo individualmente
- El login se hace en todos los nodos (Portal A + Portal B si hay ALUA)
- El `multipath.conf` se despliega a todos los nodos
- El storage PVE se crea desde el nodo donde se ejecuta y se sincroniza a todos vía `pmxcfs`

## Autenticación CHAP

Si Dorado usa CHAP, el script te pide usuario y contraseña en el paso 5. Las credenciales se injectan en la base de datos iscsiadm antes del login.

## Notas

- **Cluster y standalone:** el script detecta automáticamente si es un nodo único o un cluster. Si es cluster de un solo nodo, lo trata como standalone.
- Las interfaces de red iSCSI deben tener IP ya configurada (el script solo ajusta el MTU opcionalmente)
- Requiere SSH passwordless a los nodos remotos (si hay más de uno)
- El usuario debe ser root
- Tested con Dorado serie 5000/6000/V6
- Multipath usa política `group_by_prio` con `prio alua` para ALUA activo-pasivo
