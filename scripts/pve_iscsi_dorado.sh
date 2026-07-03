#!/bin/bash
#===============================================================================
# Proxmox Cluster + Huawei Dorado iSCSI - Configuración Interactiva
# Script interactivo para configurar iSCSI + Multipath en cluster Proxmox VE
# conectando a cabina Huawei Dorado con LUNs compartidas.
#
# El script te guía paso a paso, preguntando lo necesario en cada fase.
# Al llegar a la autorización en Dorado, espera tu confirmación antes de continuar.
#
# Uso:
#   ./pve_iscsi_dorado.sh
#
# Requisitos:
#   - Root
#   - SSH passwordless a nodos remotos (si hay cluster)
#   - open-iscsi, multipath-tools, lsscsi
#===============================================================================

set -euo pipefail

# ─── Colores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'
HLINE="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── SSH options ──────────────────────────────────────────────────────────────
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

# ─── Estado global ────────────────────────────────────────────────────────────
declare -A NODE_IQNS
declare -a ALL_WWIDS=()
declare -A NODE_LUNS_FOUND
FIRST_NODE=""
SKIP_SSH=false
DORADO_WWIDS=()
ISCSI_PORT=3260
STORAGE_CONTENT="images,rootdir,iso,backup,vztmpl"
MULTIPATH_ALIAS="huawei_dorado"
INITIATOR_IFACE_NAME="huawei_iscsi_iface"
INITIATOR_IQN=""
PORTAL_A=""
PORTAL_B=""
TARGET_IQN=""
LUN_ID=""
NODES=""
STORAGE_NAME="dorado_shared"
CHAP_USER=""
CHAP_PASS=""
IFACE_A=""
IFACE_B=""
MTU=9000
BACKUP_DIR="/etc/pve/iscsi_dorado_backup/$(date +%Y%m%d_%H%M%S)"
VERBOSE=false

# ─── Helpers ──────────────────────────────────────────────────────────────────
press_enter() {
    echo ""
    echo -e "${CYAN}Presiona ${BOLD}ENTER${NC}${CYAN} para continuar...${NC}"
    read -r
}

ask_continue() {
    echo ""
    local answer
    read -p "   ¿Continuar? [S/n]: " answer
    [[ "$answer" =~ ^[nN]$ ]] && exit 0
}

ask_yes() {
    local prompt="${1:-¿Confirmar?}"
    local answer
    read -p "$prompt [S/n]: " answer
    [[ "$answer" =~ ^[nN]$ ]]
}

print_step() {
    echo ""
    echo -e "${MAGENTA}${BOLD}${HLINE}${NC}"
    echo -e "${MAGENTA}${BOLD}  $1${NC}"
    echo -e "${MAGENTA}${BOLD}${HLINE}${NC}"
}

print_substep() {
    echo ""
    echo -e "  ${CYAN}▶ $1${NC}"
}

ok()   { echo -e "     ${GREEN}✓ $1${NC}"; }
warn() { echo -e "     ${YELLOW}⚠ $1${NC}"; }
err()  { echo -e "     ${RED}✗ $1${NC}"; }
info() { echo -e "     ${BLUE}ℹ $1${NC}"; }

cmd_exec() {
    local cmd="$1"; local node="${2:-local}"
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "     ${CYAN}CMD [$node]: $cmd${NC}"
    fi
    if [[ "$node" == "local" ]]; then
        eval "$cmd" 2>&1
    else
        ssh $SSH_OPTS "root@${node}" "$cmd" 2>&1
    fi
}

banner() {
    cat <<'EOF'

     ███╗   ██╗██╗   ██╗███╗   ███╗███╗   ███╗██╗   ██╗███████╗
     ████╗  ██║██║   ██║████╗ ████║████╗ ████║██║   ██║██╔════╝
     ██╔██╗ ██║██║   ██║██╔████╔██║██╔████╔██║██║   ██║███████╗
     ██║╚██╗██║██║   ██║██║╚██╔╝██║██║╚██╔╝██║██║   ██║╚════██║
     ██║ ╚████║╚██████╔╝██║ ╚═╝ ██║██║ ╚═╝ ██║╚██████╔╝███████║
     ╚═╝  ╚═══╝ ╚═════╝ ╚═╝     ╚═╝╚═╝     ╚═╝ ╚═════╝ ╚══════╝
          ━━ DORADO iSCSI Interactive Setup ━━

EOF
}

# ─── 0. Bienvenida ─────────────────────────────────────────────────────────────
step_welcome() {
    clear
    banner
    echo -e "${BOLD}Bienvenido al asistente de configuración iSCSI para Huawei Dorado${NC}"
    echo ""
    echo "Este script te guiará paso a paso para:"
    echo "  • Instalar paquetes necesarios"
    echo "  • Configurar iniciadores iSCSI en todos los nodos"
    echo "  • Descubrir y conectar a la cabina Dorado"
    echo "  • Configurar multipath con optimización ALUA"
    echo "  • Crear el storage compartido en Proxmox VE"
    echo ""
    echo -e "${YELLOW}IMPORTANTE:${NC} Necesitarás acceso a la consola de gestión de Dorado"
    echo "            para autorizar los iniciadores cuando el script te lo indique."
    echo ""

    if ! [[ $EUID -eq 0 ]]; then
        echo -e "${RED}Este script debe ejecutarse como ROOT.${NC}"
        exit 1
    fi

    ask_continue
}

# ─── 1. Info del cluster ─────────────────────────────────────────────────────
step_cluster_info() {
    print_step " PASO 1: Información del Cluster"

    # Detectar si hay cluster
    local cluster_mode="standalone"
    if command -v pvecm &>/dev/null && pvecm nodes 2>/dev/null | grep -qE "^[[:space:]]*[0-9]+"; then
        local node_count
        node_count=$(pvecm nodes 2>/dev/null | grep -cE "^[[:space:]]*[0-9]+")
        if [[ "$node_count" -gt 1 ]]; then
            cluster_mode="cluster"
        fi
    fi

    echo ""
    if [[ "$cluster_mode" == "cluster" ]]; then
        echo -e "${GREEN}✓ Cluster detectado (${node_count} nodos)${NC}"
        echo "Se configurarán los iniciadores en todos los nodos del cluster."
    else
        echo -e "${YELLOW}⚠ Standalone o cluster de 1 nodo detectado${NC}"
        echo "Se configurará el iniciador en este nodo únicamente."
        echo "Si más adelante agregás más nodos al cluster, ejecutá el script"
        echo "desde cada nodo nuevo."
    fi
    echo ""

    echo "Introduce los nombres de los nodos separados por coma."
    echo "Si solo es un nodo, escribe su nombre de host."
    echo ""
    echo -e "${CYAN}Ejemplo cluster:${NC} pve1,pve2,pve3"
    echo -e "${CYAN}Ejemplo standalone:${NC} pve1"
    echo ""

    local default_node
    default_node=$(hostname)
    read -p "Nodos [${default_node}]: " NODES_INPUT
    NODES="${NODES_INPUT:-${default_node}}"
    NODES=$(echo "$NODES" | sed 's/[[:space:]]*,[[:space:]]*/,/g' | sed 's/^,//;s/,$//')

    IFS=',' read -ra NODE_ARRAY <<< "$NODES"
    local actual_count=${#NODE_ARRAY[@]}

    if [[ $actual_count -eq 1 ]]; then
        ok "Modo standalone — 1 nodo: ${NODES}"
    else
        ok "Modo cluster — ${actual_count} nodos: ${NODES}"
    fi

    # Verificar SSH a nodos remotos
    for node in "${NODE_ARRAY[@]}"; do
        node=$(echo "$node" | tr -d ' ')
        if [[ "$node" == "$(hostname)" ]]; then
            info "Nodo local (OK)"
        else
            echo -n "   Verificando SSH a ${node}... "
            if timeout 5 ssh $SSH_OPTS "root@${node}" "echo ok" &>/dev/null; then
                ok "SSH OK"
            else
                warn "SSH falló o no reachable. Verificar passwordless SSH."
                echo -n "   ¿Seguir igual? [s/N]: "
                local cont; read cont
                if [[ ! "$cont" =~ ^[sS]$ ]]; then
                    exit 1
                fi
            fi
        fi
    done
}

# ─── 2. Info del Dorado ─────────────────────────────────────────────────────
step_dorado_info() {
    print_step " PASO 2: Información de Huawei Dorado"

    echo ""
    echo "Introduce los datos de conexión a la cabina Huawei Dorado."
    echo ""

    # Portal A
    while true; do
        read -p "IP Portal Primario Dorado: " PORTAL_A
        [[ -n "$PORTAL_A" ]] && break
        echo "   Valor requerido."
    done

    # Portal B
    echo ""
    echo -e "${CYAN}Portal Secundario (ALUA):${NC}"
    echo "   Introduce la IP del segundo puerto de controladora."
    echo "   Si solo tienes un puerto activo, déjalo vacío."
    read -p "IP Portal Secundario [opcional]: " PORTAL_B

    # Puerto
    echo ""
    read -p "Puerto iSCSI [${ISCSI_PORT}]: " tmp_port
    ISCSI_PORT="${tmp_port:-${ISCSI_PORT}}"

    # IQN Target
    echo ""
    echo -e "${CYAN}IQN del Target:${NC}"
    echo "   Lo encontrarás en la consola de gestión de Dorado:"
    echo "   Sistema > Configuración > Destinos iSCSI > [tu target] > IQN"
    while true; do
        read -p "IQN del Target: " TARGET_IQN
        [[ -n "$TARGET_IQN" ]] && break
        echo "   Valor requerido."
    done

    # LUN ID
    echo ""
    echo -e "${CYAN}LUN ID(s):${NC}"
    echo "   Indica el ID de la primera LUN a mapear."
    echo "   Si son varias LUNs consecutivas desde 0, puedes indicar el rango."
    read -p "ID de LUN inicial [0]: " tmp_lun
    LUN_ID="${tmp_lun:-0}"

    ok "Portal A: ${PORTAL_A}:${ISCSI_PORT}"
    [[ -n "$PORTAL_B" ]] && ok "Portal B: ${PORTAL_B}:${ISCSI_PORT}"
    ok "Target: ${TARGET_IQN}"
    ok "LUN ID: ${LUN_ID}"

    # Verificar conectividad
    echo ""
    echo "Verificando conectividad..."
    echo -n "   ${PORTAL_A}: "
    if timeout 3 ping -c1 "$PORTAL_A" &>/dev/null; then
        ok "reachable"
    else
        warn "NO reachable. Verificar red/firewall."
    fi

    if [[ -n "$PORTAL_B" ]]; then
        echo -n "   ${PORTAL_B}: "
        if timeout 3 ping -c1 "$PORTAL_B" &>/dev/null; then
            ok "reachable"
        else
            warn "NO reachable."
        fi
    fi
}

# ─── 3. Red ────────────────────────────────────────────────────────────────────
step_network() {
    print_step " PASO 3: Configuración de Red iSCSI"

    echo ""
    echo -e "${YELLOW}IMPORTANTE:${NC} Las interfaces deben tener IP configurada beforehand."
    echo "            Este script solo ajusta el MTU, no configura IPs."
    echo ""

    # Mostrar interfaces disponibles con IP
    echo "Interfaces con IP asignada en este nodo:"
    ip -br addr show | grep -v "^lo\|^docker\|^veth" | awk '{print "   " $1 " → " $3}'

    echo ""
    echo "Indica las interfaces dedicadas a iSCSI."
    echo "Si tienes dual-port ALUA, especifica una iface por cada portal."
    echo ""

    read -p "Interfaz para Portal A (ej: enp0s3): " IFACE_A
    echo ""
    read -p "Interfaz para Portal B [opcional, solo si tienes segundo portal]: " IFACE_B

    if [[ -z "$IFACE_A" ]]; then
        warn "Sin iface específica, se usará la ruta por defecto del kernel."
    else
        ok "Iface A: ${IFACE_A}"
        # Verificar que tiene IP
        local iface_ip
        iface_ip=$(ip -br addr show "$IFACE_A" 2>/dev/null | awk '{print $3}' || true)
        if [[ -n "$iface_ip" ]]; then
            ok "  IP actual: ${iface_ip}"
        else
            warn "  No tiene IP asignada en este nodo."
            warn "  Asegurate de que la IP esté configurada (static o DHCP)."
        fi

        if [[ -n "$IFACE_B" ]]; then
            ok "Iface B: ${IFACE_B}"
            iface_ip=$(ip -br addr show "$IFACE_B" 2>/dev/null | awk '{print $3}' || true)
            if [[ -n "$iface_ip" ]]; then
                ok "  IP actual: ${iface_ip}"
            else
                warn "  No tiene IP asignada en este nodo."
            fi
        fi
    fi

    echo ""
    echo "Ajuste de MTU para la red iSCSI:"
    echo "  9000  → Jumbo frames (recomendado para iSCSI)"
    echo "  1500  → MTU estándar"
    echo ""
    read -p "¿MTU? [9000]: " tmp_mtu
    MTU="${tmp_mtu:-9000}"

    if [[ "$MTU" == "9000" ]]; then
        ok "MTU: ${MTU} (jumbo frames)"
        if [[ -n "$IFACE_A" ]]; then
            echo -n "   ¿Aplicar MTU ${MTU} a ${IFACE_A}? [s/N]: "
            local apply_mtu; read apply_mtu
            if [[ "$apply_mtu" =~ ^[sS]$ ]]; then
                ip link set "$IFACE_A" mtu "$MTU" 2>/dev/null && ok "MTU aplicado a ${IFACE_A}" || warn "No se pudo aplicar MTU"
            fi
            if [[ -n "$IFACE_B" ]]; then
                echo -n "   ¿Aplicar MTU ${MTU} a ${IFACE_B}? [s/N]: "
                read apply_mtu
                if [[ "$apply_mtu" =~ ^[sS]$ ]]; then
                    ip link set "$IFACE_B" mtu "$MTU" 2>/dev/null && ok "MTU aplicado a ${IFACE_B}" || warn "No se pudo aplicar MTU"
                fi
            fi
        fi
        if [[ -n "$IFACE_A" ]]; then
            echo -n "   ¿Aplicar MTU ${MTU} a ${IFACE_A}? [s/N]: "
            local apply_mtu; read apply_mtu
            if [[ "$apply_mtu" =~ ^[sS]$ ]]; then
                ip link set "$IFACE_A" mtu "$MTU" && ok "MTU ${MTU} aplicado a ${IFACE_A}" || warn "No se pudo aplicar MTU a ${IFACE_A}"
            fi
            if [[ -n "$IFACE_B" ]]; then
                echo -n "   ¿Aplicar MTU ${MTU} a ${IFACE_B}? [s/N]: "
                read apply_mtu
                if [[ "$apply_mtu" =~ ^[sS]$ ]]; then
                    ip link set "$IFACE_B" mtu "$MTU" && ok "MTU ${MTU} aplicado a ${IFACE_B}" || warn "No se pudo aplicar MTU a ${IFACE_B}"
                fi
            fi
        fi
    else
        ok "MTU: ${MTU}"
    fi

    ok "Configuración de red completada"
}

# ─── 4. CHAP ──────────────────────────────────────────────────────────────────
step_chap() {
    print_step " PASO 4: Autenticación CHAP (Opcional)"

    echo ""
    echo "Si la cabina Dorado requiere autenticación CHAP, introduce las credenciales."
    echo "Si no usas CHAP, déjalo en blanco."
    echo ""

    read -p "Usuario CHAP: " CHAP_USER
    if [[ -n "$CHAP_USER" ]]; then
        read -s -p "Contraseña CHAP: " CHAP_PASS
        echo ""
        ok "CHAP configurado: ${CHAP_USER}"
    else
        ok "Sin autenticación CHAP"
    fi
}

# ─── 5. Storage ────────────────────────────────────────────────────────────────
step_storage() {
    print_step " PASO 5: Storage en Proxmox VE"

    echo ""
    echo "Configuración del storage iSCSI en Proxmox."
    echo ""

    read -p "Nombre del storage [dorado_shared]: " tmp_st
    STORAGE_NAME="${tmp_st:-dorado_shared}"

    echo ""
    echo "Tipos de contenido para el storage:"
    echo "  images,rootdir  → VMs (discos + raíz)"
    echo "  images          → solo discos de VMs"
    echo "  iso              → solo ISOs"
    echo "  backup           → solo backups"
    echo "  iso,backup       → ISOs y backups"
    echo "  images,rootdir,iso,backup,vztmpl → todo"
    echo ""
    read -p "Contenido [images,rootdir,iso,backup,vztmpl]: " tmp_ct
    STORAGE_CONTENT="${tmp_ct:-images,rootdir,iso,backup,vztmpl}"

    ok "Storage: ${STORAGE_NAME}"
    ok "Contenido: ${STORAGE_CONTENT}"

    if ! command -v pvesm &>/dev/null; then
        warn "pvesm no encontrado. No se creará storage PVE."
    fi
}

# ─── 6. Opciones avanzadas ─────────────────────────────────────────────────────
step_advanced() {
    print_step " PASO 6: Opciones Avanzadas"

    echo ""
    echo "Ajustes avanzados. Los valores por defecto suelen funcionar bien."
    echo ""

    read -p "Alias para dispositivo multipath [huawei_dorado]: " tmp_alias
    MULTIPATH_ALIAS="${tmp_alias:-huawei_dorado}"

    echo ""
    read -p "¿Verbose? [N]: " tmp_v
    [[ "$tmp_v" =~ ^[sSyY]$ ]] && VERBOSE=true

    ok "Multipath alias: ${MULTIPATH_ALIAS}"
    [[ "$VERBOSE" == "true" ]] && ok "Modo verbose: ON"
}

# ─── 7. Resumen antes de empezar ─────────────────────────────────────────────
step_summary() {
    print_step " RESUMEN ANTES DE INICIAR"

    echo ""
    echo -e "${BOLD}Cluster:${NC}         ${NODES}"
    echo -e "${BOLD}Cabina:${NC}          Huawei Dorado"
    echo -e "${BOLD}Portal A:${NC}         ${PORTAL_A}:${ISCSI_PORT}"
    echo -e "${BOLD}Portal B:${NC}         ${PORTAL_B:--}"
    echo -e "${BOLD}Target IQN:${NC}       ${TARGET_IQN}"
    echo -e "${BOLD}LUN ID:${NC}           ${LUN_ID}"
    echo -e "${BOLD}Interfaz(es):${NC}    ${IFACE_A:--}${IFACE_B:+, $IFACE_B}"
    echo -e "${BOLD}MTU:${NC}              ${MTU}"
    echo -e "${BOLD}CHAP:${NC}             ${CHAP_USER:--}"
    echo -e "${BOLD}Storage:${NC}          ${STORAGE_NAME} (${STORAGE_CONTENT})"
    echo -e "${BOLD}Multipath alias:${NC}  ${MULTIPATH_ALIAS}"
    echo ""

    echo -e "${YELLOW}${BOLD}Flujo:${NC}"
    echo "  1. Instalar paquetes en todos los nodos"
    echo "  2. Configurar IQNs de iniciadores"
    echo "  3. Descubrir targets (SIN LOGIN)"
    echo "  4. ⬅️  Aquí te mostraremos los IQNs para autorizar en Dorado"
    echo "  5. Esperar a que autorices en la consola de Dorado"
    echo "  6. Login + Multipath + WWIDs"
    echo "  7. Crear storage en PVE"
    echo ""

    echo -e "${CYAN}¿Todo correcto?${NC}"
    ask_continue
}

# ─── 8. Instalar paquetes ─────────────────────────────────────────────────────
step_install() {
    print_step " PASO 8: Instalando Paquetes"

    declare -a PKGS=("open-iscsi" "multipath-tools" "lsscsi")
    local missing=()

    for pkg in "${PKGS[@]}"; do
        if ! command -v "${pkg//-/}" &>/dev/null && ! dpkg -l "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "Todos los paquetes ya están instalados"
    else
        echo ""
        echo "Instalando: ${missing[*]}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq "${missing[@]}"
        ok "Paquetes instalados"
    fi

    IFS=',' read -ra NODE_ARRAY <<< "$NODES"
    for node in "${NODE_ARRAY[@]}"; do
        node=$(echo "$node" | tr -d ' ')
        [[ "$node" == "$(hostname)" ]] && continue

        print_substep "Verificando paquetes en ${node}..."
        local remote_missing
        remote_missing=$(ssh $SSH_OPTS "root@${node}" "dpkg -l ${PKGS[*]} 2>/dev/null | grep -c '^ii' || echo 0" 2>/dev/null || echo "0")
        if [[ "$remote_missing" -lt ${#PKGS[@]} ]]; then
            echo -n "   Instalando en ${node}... "
            ssh $SSH_OPTS "root@${node}" "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq ${missing[*]}" 2>/dev/null && ok "OK" || warn "falló"
        else
            ok "${node}: OK"
        fi
    done
}

# ─── 9. Configurar IQN iniciador ──────────────────────────────────────────────
step_configure_initiators() {
    print_step " PASO 9: Configurando Iniciadores IQN"

    IFS=',' read -ra NODE_ARRAY <<< "$NODES"

    for node in "${NODE_ARRAY[@]}"; do
        node=$(echo "$node" | tr -d ' ')
        print_substep "Configurando iniciador en ${node}..."

        local initiator_file="/etc/iscsi/initiatorname.iscsi"

        if [[ "$node" != "$(hostname)" ]]; then
            initiator_file="/etc/iscsi/initiatorname.iscsi"
        fi

        local current_iqn=""
        if [[ "$node" == "$(hostname)" ]]; then
            current_iqn=$(grep -i "^InitiatorName=" "$initiator_file" 2>/dev/null | cut -d= -f2 || true)
        else
            current_iqn=$(ssh $SSH_OPTS "root@${node}" "grep -i '^InitiatorName=' /etc/iscsi/initiatorname.iscsi 2>/dev/null | cut -d= -f2" 2>/dev/null || true)
        fi

        if [[ -n "$current_iqn" ]]; then
            ok "IQN actual: ${current_iqn}"
            echo -n "   ¿Usar este IQN? [S/n]: "
            local use_current; read use_current
            if [[ "$use_current" =~ ^[nN]$ ]]; then
                local new_iqn
                read -p "   Nuevo IQN para ${node}: " new_iqn
                if [[ -n "$new_iqn" ]]; then
                    if [[ "$node" == "$(hostname)" ]]; then
                        echo "InitiatorName=${new_iqn}" > "$initiator_file"
                        chmod 640 "$initiator_file"
                    else
                        ssh $SSH_OPTS "root@${node}" "echo 'InitiatorName=${new_iqn}' > /etc/iscsi/initiatorname.iscsi && chmod 640 /etc/iscsi/initiatorname.iscsi" 2>/dev/null
                    fi
                    current_iqn="$new_iqn"
                    ok "IQN actualizado: ${current_iqn}"
                fi
            fi
        else
            echo "   No se detectó IQN. Generando uno nuevo..."
            local new_iqn="iqn.$(date +%Y-%m).${node}:initiator"
            if [[ "$node" == "$(hostname)" ]]; then
                echo "InitiatorName=${new_iqn}" > "$initiator_file"
                chmod 640 "$initiator_file"
            else
                ssh $SSH_OPTS "root@${node}" "echo 'InitiatorName=${new_iqn}' > /etc/iscsi/initiatorname.iscsi && chmod 640 /etc/iscsi/initiatorname.iscsi" 2>/dev/null
            fi
            current_iqn="$new_iqn"
            ok "IQN generado: ${current_iqn}"
        fi

        NODE_IQNS["$node"]="$current_iqn"
    done

    echo ""
    echo -e "${BOLD}IQNs de iniciadores:${NC}"
    for n in "${!NODE_IQNS[@]}"; do
        echo -e "   ${CYAN}${n}:${NC} ${NODE_IQNS[$n]}"
    done
}

# ─── 10. Crear iface ───────────────────────────────────────────────────────────
step_create_iface() {
    print_step " PASO 10: Creando iface iSCSI"

    echo ""
    echo "Creando iface '${INITIATOR_IFACE_NAME}' para el tráfico iSCSI."
    echo "Esto permite un control más fino sobre la iface de red usada."
    echo ""

    IFS=',' read -ra NODE_ARRAY <<< "$NODES"

    for node in "${NODE_ARRAY[@]}"; do
        node=$(echo "$node" | tr -d ' ')
        print_substep "Creando iface en ${node}..."

        local mac_addr=""
        if [[ -n "$IFACE_A" ]]; then
            if [[ "$node" == "$(hostname)" ]]; then
                mac_addr=$(ip link show "$IFACE_A" 2>/dev/null | grep ether | awk '{print $2}' || true)
            else
                mac_addr=$(ssh $SSH_OPTS "root@${node}" "ip link show $IFACE_A 2>/dev/null | grep ether | awk '{print $2}'" 2>/dev/null || true)
            fi
        fi

        local iface_content="# Huawei Dorado iSCSI iface
# Nodo: ${node}
# Generado: $(date)
iface.iface_name ${INITIATOR_IFACE_NAME}
iface.net_iface_name ${IFACE_A:-auto}
iface.hwaddress ${mac_addr:-auto}
iface.transport_name tcp
iface.initiatorname ${NODE_IQNS[$node]}
iface.tcp_xmit_wsf_semantics 0
iface.tcp_recv_wsf_semantics 0
iface.iface_num 0
iface.mtu ${MTU}
"

        local cmd="mkdir -p /etc/iscsi/ifaces && cat > /etc/iscsi/ifaces/${INITIATOR_IFACE_NAME}.iface <<'IFACEEOF'
${iface_content}
IFACEEOF"

        if [[ "$node" == "$(hostname)" ]]; then
            eval "$cmd"
            ok "Iface creada: /etc/iscsi/ifaces/${INITIATOR_IFACE_NAME}.iface"
        else
            ssh $SSH_OPTS "root@${node}" "$cmd" 2>/dev/null && ok "${node}: OK" || warn "${node}: falló"
        fi
    done
}

# ─── 11. Descubrimiento ───────────────────────────────────────────────────────
step_discovery() {
    print_step " PASO 11: Descubriendo Targets iSCSI"

    echo ""
    echo "Haciendo descubrimiento en el/los portales Dorado."
    echo "El login se hará DESPUÉS de la autorización en Dorado."
    echo ""

    IFS=',' read -ra NODE_ARRAY <<< "$NODES"

    for node in "${NODE_ARRAY[@]}"; do
        node=$(echo "$node" | tr -d ' ')

        # Portal A
        print_substep "${node} → descubriendo en ${PORTAL_A}:${ISCSI_PORT}..."
        local disc_result
        if [[ "$node" == "$(hostname)" ]]; then
            disc_result=$(iscsiadm -m discovery -t st -p "${PORTAL_A}:${ISCSI_PORT}" -I "${INITIATOR_IFACE_NAME}" 2>&1 || true)
        else
            disc_result=$(ssh $SSH_OPTS "root@${node}" "iscsiadm -m discovery -t st -p ${PORTAL_A}:${ISCSI_PORT} -I ${INITIATOR_IFACE_NAME}" 2>/dev/null || true)
        fi

        if echo "$disc_result" | grep -qi "empty\|error\|no targets\|auth"; then
            warn "Descubrimiento tuvo problemas (puede ser normal si no está autorizado aún)"
        else
            ok "Descubrimiento exitoso"
        fi

        # Portal B
        if [[ -n "$PORTAL_B" ]]; then
            print_substep "${node} → descubriendo en ${PORTAL_B}:${ISCSI_PORT}..."
            if [[ "$node" == "$(hostname)" ]]; then
                iscsiadm -m discovery -t st -p "${PORTAL_B}:${ISCSI_PORT}" -I "${INITIATOR_IFACE_NAME}" 2>&1 || true
            else
                ssh $SSH_OPTS "root@${node}" "iscsiadm -m discovery -t st -p ${PORTAL_B}:${ISCSI_PORT} -I ${INITIATOR_IFACE_NAME}" 2>/dev/null || true
            fi
            ok "Descubrimiento completado"
        fi
    done
}

# ─── 12. Preparación en Dorado (antes del login) ──────────────────────────────
step_dorado_prep() {
    print_step " PASO 12: Preparación en Dorado (antes del login)"

    echo ""
    echo -e "${BOLD}Antes de hacer el login, creá el Host en Dorado con estos IQNs:${NC}"
    echo ""
    echo -e "  ┌──────────────────────────────────────────────────────────────────┐"
    printf   "  │ %-20s │ %-52s │\n" "NODO" "IQN DEL INICIADOR"
    echo -e "  ├──────────────────────────────────────────────────────────────────┤"
    for node in "${!NODE_IQNS[@]}"; do
        printf "  │ %-20s │ %-52s │\n" "$node" "${NODE_IQNS[$node]}"
    done
    echo -e "  └──────────────────────────────────────────────────────────────────┘"
    echo ""

    echo -e "${CYAN}En la consola de Dorado, hacé esto:${NC}"
    echo ""
    echo -e "${BOLD}1.${NC} Ve a: Configuración > Hosts > Crear Host"
    echo "   - Nombre: pve_cluster (o el que prefieras)"
    echo "   - Tipo: Host iSCSI"
    echo ""
    echo -e "${BOLD}2.${NC} Añadí los IQNs de arriba al host (uno por cada nodo)"
    echo ""
    echo -e "${BOLD}3.${NC} Asociá el host con el target: ${TARGET_IQN}"
    echo "   Portales: ${PORTAL_A}:${ISCSI_PORT}${PORTAL_B:+ y ${PORTAL_B}:${ISCSI_PORT}}"
    echo ""
    echo -e "${BOLD}4.${NC} MAPEÁ las LUNs al host (LUN ${LUN_ID} y las que necesites)"
    echo ""
    echo -e "${BOLD}5.${NC} Guardá los cambios en Dorado"
    echo ""
    echo -e "${YELLOW}Cuando esté todo listo, volvé aquí y presioná ENTER.${NC}"
    echo ""
    echo "El siguiente paso será hacer el login — en ese momento aparecerán"
    echo "los iniciadores en la consola de Dorado para asociarlos y autorizar."
    echo ""

    press_enter
    ok "Continuando al login..."
}

# ─── 13. Login ─────────────────────────────────────────────────────────────────
step_login() {
    print_step " PASO 13: Login a los Targets"

    echo ""
    echo -e "${YELLOW}ATENCIÓN:${NC} Al ejecutar el login, Dorado mostrará los iniciadores"
    echo "en su consola. Después del login tendés que asociarlos y autorizar."
    echo ""

    IFS=',' read -ra NODE_ARRAY <<< "$NODES"

    for node in "${NODE_ARRAY[@]}"; do
        node=$(echo "$node" | tr -d ' ')
        print_substep "${node} → login en ${PORTAL_A}:${ISCSI_PORT}..."

        # CHAP
        if [[ -n "$CHAP_USER" ]]; then
            local chap_cmds=(
                "iscsiadm -m node -T ${TARGET_IQN} -p ${PORTAL_A}:${ISCSI_PORT} -I ${INITIATOR_IFACE_NAME} -o update -n node.session.auth.authmethod -v CHAP"
                "iscsiadm -m node -T ${TARGET_IQN} -p ${PORTAL_A}:${ISCSI_PORT} -I ${INITIATOR_IFACE_NAME} -o update -n node.session.auth.username -v '${CHAP_USER}'"
                "iscsiadm -m node -T ${TARGET_IQN} -p ${PORTAL_A}:${ISCSI_PORT} -I ${INITIATOR_IFACE_NAME} -o update -n node.session.auth.password -v '${CHAP_PASS}'"
            )
            if [[ "$node" == "$(hostname)" ]]; then
                for c in "${chap_cmds[@]}"; do eval "$c" 2>/dev/null || true; done
            else
                for c in "${chap_cmds[@]}"; do ssh $SSH_OPTS "root@${node}" "$c" 2>/dev/null || true; done
            fi
            ok "CHAP configurado"
        fi

        # Login
        local login_cmd="iscsiadm -m node -T ${TARGET_IQN} -p ${PORTAL_A}:${ISCSI_PORT} -I ${INITIATOR_IFACE_NAME} --login"
        if [[ "$node" == "$(hostname)" ]]; then
            local result; result=$(eval "$login_cmd" 2>&1 || true)
            if echo "$result" | grep -qi "login failed\|iscsi_err"; then
                warn "Login tuvo problemas: $result"
            else
                ok "Login enviado"
            fi
        else
            ssh $SSH_OPTS "root@${node}" "$login_cmd" 2>/dev/null && ok "${node} A: OK" || warn "${node} A: tuvo problemas"
        fi

        # Persist
        local persist_cmd="iscsiadm -m node -T ${TARGET_IQN} -p ${PORTAL_A}:${ISCSI_PORT} -I ${INITIATOR_IFACE_NAME} -o update -n node.startup -v automatic"
        if [[ "$node" == "$(hostname)" ]]; then
            eval "$persist_cmd" 2>/dev/null || true
        else
            ssh $SSH_OPTS "root@${node}" "$persist_cmd" 2>/dev/null || true
        fi

        # Portal B
        if [[ -n "$PORTAL_B" ]]; then
            print_substep "${node} → login en ${PORTAL_B}:${ISCSI_PORT}..."
            if [[ "$node" == "$(hostname)" ]]; then
                iscsiadm -m node -T "${TARGET_IQN}" -p "${PORTAL_B}:${ISCSI_PORT}" -I "${INITIATOR_IFACE_NAME}" --login 2>&1 && ok "OK" || warn "falló"
            else
                ssh $SSH_OPTS "root@${node}" "iscsiadm -m node -T ${TARGET_IQN} -p ${PORTAL_B}:${ISCSI_PORT} -I ${INITIATOR_IFACE_NAME} --login" 2>/dev/null && ok "${node} B: OK" || warn "${node} B: falló"
            fi
        fi
    done

    echo ""
    ok "Login enviado a todos los nodos"
    echo ""
    echo "Sesiones iSCSI activas:"
    iscsiadm -m session -P1 2>/dev/null | grep -E "tcp|Portal" | head -20 || echo "   Ninguna visible todavía"
}

# ─── 14. Autorización post-login ──────────────────────────────────────────────
step_authorization() {
    print_step " ⬅️  PASO 14: AUTORIZACIÓN EN DORADO (POST-LOGIN)"

    echo ""
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║          ACCIÓN REQUERIDA EN LA CONSOLA DORADO              ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}El login ya se ejecutó. Ahora asociá y autorizá los iniciadores:${NC}"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}1.${NC} En la consola de Dorado, buscá los iniciadores que aparecieron."
    echo "   Deberían estar en: Hosts > pve_cluster > Initiators"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}2.${NC} Asociá CADA iniciador al host:"
    echo ""
    echo -e "  ┌──────────────────────────────────────────────────────────────────┐"
    printf   "  │ %-20s │ %-52s │\n" "NODO" "IQN DEL INICIADOR"
    echo -e "  ├──────────────────────────────────────────────────────────────────┤"
    for node in "${!NODE_IQNS[@]}"; do
        printf "  │ %-20s │ %-52s │\n" "$node" "${NODE_IQNS[$node]}"
    done
    echo -e "  └──────────────────────────────────────────────────────────────────┘"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}3.${NC} Autorizá cada iniciador (Enable / Allow)"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}4.${NC} Verificá que la LUN ${LUN_ID} esté mapeada al host"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}5.${NC} Guardá los cambios en Dorado"
    echo ""
    echo -e "${YELLOW}Cuando esté todo autorizado, volvé aquí y presioná ENTER.${NC}"
    echo ""

    press_enter

    echo ""
    echo "Esperando a que las LUNs se detecten..."
    local auth_ok=false
    local waited=0

    while [[ "$auth_ok" == "false" && $waited -lt 180 ]]; do
        echo -n "   Verificando LUNs visibles... "
        local lun_count
        lun_count=$(lsblk -d -n -o NAME 2>/dev/null | grep -cE '^sd[a-z]+$|^dm-[0-9]+$' || echo "0")
        if [[ "$lun_count" -gt 0 ]]; then
            ok "LUN visible ($lun_count dispositivos)"
            auth_ok=true
        else
            waited=$((waited + 15))
            echo -ne "${YELLOW}Aún sin LUN (${waited}s). ¿Seguir? [S]: ${NC}"
            local retry; read -t 15 retry || true
            if [[ "$retry" =~ ^[nN]$ ]]; then
                warn "Continuando igualmente..."
                auth_ok=true
            fi
        fi
    done

    [[ "$auth_ok" == "true" ]] && ok "Continuando con la configuración..."
}

# ─── 13. Login ─────────────────────────────────────────────────────────────────
step_login() {
    print_step " PASO 13: Login a los Targets"

    echo ""
    echo "Conectando a los portales Dorado en todos los nodos..."
    echo ""

    IFS=',' read -ra NODE_ARRAY <<< "$NODES"

    for node in "${NODE_ARRAY[@]}"; do
        node=$(echo "$node" | tr -d ' ')
        print_substep "${node} → login en ${PORTAL_A}:${ISCSI_PORT}..."

        # CHAP si aplica
        if [[ -n "$CHAP_USER" ]]; then
            local chap_cmds=(
                "iscsiadm -m node -T ${TARGET_IQN} -p ${PORTAL_A}:${ISCSI_PORT} -I ${INITIATOR_IFACE_NAME} -o update -n node.session.auth.authmethod -v CHAP"
                "iscsiadm -m node -T ${TARGET_IQN} -p ${PORTAL_A}:${ISCSI_PORT} -I ${INITIATOR_IFACE_NAME} -o update -n node.session.auth.username -v '${CHAP_USER}'"
                "iscsiadm -m node -T ${TARGET_IQN} -p ${PORTAL_A}:${ISCSI_PORT} -I ${INITIATOR_IFACE_NAME} -o update -n node.session.auth.password -v '${CHAP_PASS}'"
            )
            if [[ "$node" == "$(hostname)" ]]; then
                for c in "${chap_cmds[@]}"; do eval "$c" 2>/dev/null || true; done
            else
                for c in "${chap_cmds[@]}"; do ssh $SSH_OPTS "root@${node}" "$c" 2>/dev/null || true; done
            fi
            ok "CHAP configurado"
        fi

        # Login
        local login_cmd="iscsiadm -m node -T ${TARGET_IQN} -p ${PORTAL_A}:${ISCSI_PORT} -I ${INITIATOR_IFACE_NAME} --login"
        if [[ "$node" == "$(hostname)" ]]; then
            local result; result=$(eval "$login_cmd" 2>&1 || true)
            if echo "$result" | grep -qi "login failed\|auth"; then
                err "Login falló: ${result}"
            else
                ok "Login exitoso"
            fi
        else
            ssh $SSH_OPTS "root@${node}" "$login_cmd" 2>/dev/null && ok "${node} A: OK" || err "${node} A: falló"
        fi

        # Persist
        local persist_cmd="iscsiadm -m node -T ${TARGET_IQN} -p ${PORTAL_A}:${ISCSI_PORT} -I ${INITIATOR_IFACE_NAME} -o update -n node.startup -v automatic"
        if [[ "$node" == "$(hostname)" ]]; then
            eval "$persist_cmd" 2>/dev/null || true
        else
            ssh $SSH_OPTS "root@${node}" "$persist_cmd" 2>/dev/null || true
        fi

        # Portal B
        if [[ -n "$PORTAL_B" ]]; then
            print_substep "${node} → login en ${PORTAL_B}:${ISCSI_PORT}..."
            if [[ "$node" == "$(hostname)" ]]; then
                iscsiadm -m node -T "${TARGET_IQN}" -p "${PORTAL_B}:${ISCSI_PORT}" -I "${INITIATOR_IFACE_NAME}" --login 2>&1 && ok "OK" || warn "falló"
            else
                ssh $SSH_OPTS "root@${node}" "iscsiadm -m node -T ${TARGET_IQN} -p ${PORTAL_B}:${ISCSI_PORT} -I ${INITIATOR_IFACE_NAME} --login" 2>/dev/null && ok "${node} B: OK" || warn "${node} B: falló"
            fi
        fi
    done

    echo ""
    echo "Sesiones iSCSI activas:"
    iscsiadm -m session -P1 2>/dev/null | grep -E "tcp|Portal" | head -20 || echo "   Ninguna visible todavía"
}

# ─── 14. Multipath config ──────────────────────────────────────────────────────
step_multipath() {
    print_step " PASO 15: Configurando Multipath"

    echo ""
    echo "Generando multipath.conf optimizado para Huawei Dorado ALUA..."
    echo ""

    mkdir -p "${BACKUP_DIR}"
    [[ -f /etc/multipath.conf ]] && cp -a /etc/multipath.conf "${BACKUP_DIR}/multipath.conf.bak"

    cat > /etc/multipath.conf <<'EOF'
# /etc/multipath.conf
# Huawei Dorado + Proxmox Cluster
# Generado: $(date)

defaults {
    user_friendly_names     yes
    find_multipaths         yes
    polling_interval        10
    path_checker           tur
    path_selector          "round-robin 0"
    path_grouping_policy    group_by_prio
    uid_attribute          ID_SERIAL
    rr_min_io_rq           1
    failback               immediate
    no_path_retry          queue
    dev_loss_tmo           30
    fast_io_fail_tmo       5
    max_fds                max
    retain_attached_hw_handler yes
    detect_checker         yes
    flush_on_last_del      yes
}

blacklist {
    devnode "^(ram|raw|loop|fd|md|dm-|sr-|cdrom|tty|ps|vmcore|nfs|pvmapper).*"
    wwid .*
}

devices {
    device {
        vendor                  "HUAWEI"
        product                 "Dorado"
        product_blacklist       ".*"
        path_grouping_policy    group_by_prio
        path_checker           tur
        path_selector          "round-robin 0"
        prio                   alua
        prio_args              "exclusive_pref_bit=1"
        failback               immediate
        features               "1 queue_if_no_path"
        hardware_handler       "1 alua"
        dev_loss_tmo           30
        fast_io_fail_tmo       5
        no_path_retry          queue
        rr_min_io_rq           1
    }
    device {
        vendor                  "HUAWEI"
        product                 "OceanStor"
        path_grouping_policy    group_by_prio
        path_checker           tur
        path_selector          "round-robin 0"
        prio                   alua
        prio_args              "exclusive_pref_bit=1"
        failback               immediate
        features               "1 queue_if_no_path"
        hardware_handler       "1 alua"
        dev_loss_tmo           30
        fast_io_fail_tmo       5
        no_path_retry          queue
        rr_min_io_rq           1
    }
    device {
        vendor                  "HUAWEI"
        product                 "V6"
        path_grouping_policy    group_by_prio
        path_checker           tur
        path_selector          "round-robin 0"
        prio                   alua
        prio_args              "exclusive_pref_bit=1"
        failback               immediate
        features               "1 queue_if_no_path"
        hardware_handler       "1 alua"
        dev_loss_tmo           30
        fast_io_fail_tmo       5
        no_path_retry          queue
    }
}
EOF

    ok "multipath.conf generado"

    # Deploy a nodos remotos
    IFS=',' read -ra NODE_ARRAY <<< "$NODES"
    for node in "${NODE_ARRAY[@]}"; do
        node=$(echo "$node" | tr -d ' ')
        [[ "$node" == "$(hostname)" ]] && continue
        echo -n "   Copiando a ${node}... "
        scp $SSH_OPTS /etc/multipath.conf "root@${node}:/etc/multipath.conf" 2>/dev/null && ok "OK" || warn "falló"
    done

    # Restart multipathd
    echo ""
    print_substep "Reiniciando multipathd..."
    systemctl restart multipathd 2>/dev/null && ok "OK" || warn "falló"
    systemctl enable multipathd 2>/dev/null

    for node in "${NODE_ARRAY[@]}"; do
        node=$(echo "$node" | tr -d ' ')
        [[ "$node" == "$(hostname)" ]] && continue
        echo -n "   Reiniciando multipathd en ${node}... "
        ssh $SSH_OPTS "root@${node}" "systemctl restart multipathd && systemctl enable multipathd" 2>/dev/null && ok "OK" || warn "falló"
    done
}

# ─── 15. Rescan + WWIDs ───────────────────────────────────────────────────────
step_scan_wwids() {
    print_step " PASO 16: Escaneando LUNs y Detectando WWIDs"

    echo ""
    echo "Rescaneando buses SCSI para detectar las LUNs de Dorado..."
    echo ""

    # Rescan
    for host in /sys/class/scsi_host/host*/scan; do
        echo "- - -" > "$host" 2>/dev/null || true
    done

    IFS=',' read -ra NODE_ARRAY <<< "$NODES"
    for node in "${NODE_ARRAY[@]}"; do
        node=$(echo "$node" | tr -d ' ')
        [[ "$node" == "$(hostname)" ]] && continue
        echo -n "   Rescaneando ${node}... "
        ssh $SSH_OPTS "root@${node}" "for h in /sys/class/scsi_host/host*/scan; do echo '- - -' > \"\$h\" 2>/dev/null || true; done; sleep 3" 2>/dev/null && ok "OK" || warn "falló"
    done

    sleep 5

    echo ""
    echo -e "${BOLD}Dispositivos detectados (nodo local):${NC}"
    lsblk -o NAME,SIZE,TYPE,VENDOR,MODEL,HCTL 2>/dev/null | head -20 || lsblk -o NAME,SIZE,TYPE,VENDOR | head -15

    echo ""
    echo -e "${BOLD}Buscando WWIDs de Dorado...${NC}"
    echo ""

    local all_wwids=()

    # Método 1: by-id
    echo "   [1/4] Buscando en /dev/disk/by-id/..."
    local byid_wwids
    byid_wwids=$(ls -la /dev/disk/by-id/ 2>/dev/null | grep -iE "scsi-.*|naa\.|huawei|dorado" | awk '{print $NF}' | sort -u || true)
    if [[ -n "$byid_wwids" ]]; then
        while IFS= read -r w; do
            [[ -z "$w" ]] && continue
            local base; base=$(basename "$w")
            if [[ ! " ${all_wwids[*]} " =~ " ${base} " ]]; then
                all_wwids+=("$base")
                ok "   WWID: $base"
            fi
        done <<< "$byid_wwids"
    else
        info "   No encontrado en by-id"
    fi

    # Método 2: lsscsi
    echo ""
    echo "   [2/4] Buscando por lsscsi..."
    local lsscsi_out
    lsscsi_out=$(lsscsi 2>/dev/null || true)
    if echo "$lsscsi_out" | grep -qiE "huawei|dorado|oceanstor"; then
        echo "$lsscsi_out" | grep -iE "huawei|dorado|oceanstor" | while read -r line; do
            ok "   $line"
        done
    else
        info "   No hay dispositivos Huawei todavía. Es normal si la LUN no está mapeada."
    fi

    # Método 3: sysfs
    echo ""
    echo "   [3/4] Buscando en sysfs..."
    for block_dev in /sys/block/sd*; do
        [[ ! -e "$block_dev" ]] && continue
        local dev_name; dev_name=$(basename "$block_dev")
        local vendor; vendor=$(cat "${block_dev}/device/vendor" 2>/dev/null | tr -d ' ' || true)
        local wwid; wwid=$(cat "${block_dev}/device/wwid" 2>/dev/null || true)

        if [[ "$vendor" =~ HUAWEI|DORADO|OCEAN || "$wwid" =~ ^naa\. ]]; then
            ok "   /dev/${dev_name} | Vendor: ${vendor} | WWID: ${wwid}"
            if [[ "$wwid" =~ ^naa\. && ! " ${all_wwids[*]} " =~ " ${wwid} " ]]; then
                all_wwids+=("$wwid")
            fi
        fi
    done

    # Método 4: multipath -v3
    echo ""
    echo "   [4/4] Buscando con multipath -v3..."
    local mpath_out
    mpath_out=$(multipath -v3 2>&1 | grep -A3 -iE "huawei|dorado|${TARGET_IQN}" | head -30 || true)
    if [[ -n "$mpath_out" ]]; then
        echo "$mpath_out" | while read -r line; do
            ok "   $line"
        done
    fi

    # Guardar
    ALL_WWIDS=("${all_wwids[@]}")

    echo ""
    echo -e "${BOLD}WWIDs totales detectados: ${#ALL_WWIDS[@]}${NC}"
    for w in "${ALL_WWIDS[@]}"; do
        ok "   → $w"
    done

    if [[ ${#ALL_WWIDS[@]} -eq 0 ]]; then
        echo ""
        warn "No se detectaron WWIDs de Dorado."
        echo "   Posibles causas:"
        echo "   1. La LUN no está mapeada en Dorado al iniciador"
        echo "   2. Falta esperar unos segundos tras el login"
        echo "   3. Problemas de red/firewall"
        echo ""
        echo -n "   ¿Escanear de nuevo? [S]: "
        local rescan; read rescan
        if [[ ! "$rescan" =~ ^[nN]$ ]]; then
            for h in /sys/class/scsi_host/host*/scan; do echo "- - -" > "$h" 2>/dev/null || true; done
            sleep 8
            echo -e "${BOLD}Resultado del re-scan:${NC}"
            lsblk -o NAME,SIZE,TYPE,VENDOR | head -10
            ls -la /dev/disk/by-id/ 2>/dev/null | grep -iE "scsi|naa" | head -10
        fi
    fi
}

# ─── 16. Agregar WWIDs al multipath ───────────────────────────────────────────
step_add_wwids() {
    print_step " PASO 17: Agregando WWIDs al Multipath"

    if [[ ${#ALL_WWIDS[@]} -eq 0 ]]; then
        echo ""
        warn "No hay WWIDs detectados. Multipath usará detección automática."
        echo "   Podrás agregar WWIDs manualmente más tarde editando /etc/multipath.conf"
    else
        echo ""
        echo "Agregando ${#ALL_WWIDS[@]} WWIDs al multipath.conf..."

        echo "" >> /etc/multipath.conf
        echo "# WWIDs Dorado - agregados por setup interactivo" >> /etc/multipath.conf
        echo "# $(date)" >> /etc/multipath.conf
        echo "multipaths {" >> /etc/multipath.conf

        local idx=0
        for wwid in "${ALL_WWIDS[@]}"; do
            [[ -z "$wwid" || "$wwid" == "naa.placeholder" ]] && continue

            local alias_name="${MULTIPATH_ALIAS}"
            [[ ${#ALL_WWIDS[@]} -gt 1 ]] && alias_name="${MULTIPATH_ALIAS}_${idx}"

            cat >> /etc/multipath.conf <<EOF
    multipath {
        wwid                   ${wwid}
        alias                  ${alias_name}
        path_grouping_policy   group_by_prio
        path_selector          "round-robin 0"
        path_checker           tur
        rr_min_io_rq           1
        failback               immediate
    }
EOF
            ok "   Agregado: ${alias_name} = ${wwid}"
            idx=$((idx + 1))
        done

        echo "}" >> /etc/multipath.conf
        ok "multipath.conf actualizado"

        # Deploy a nodos remotos
        IFS=',' read -ra NODE_ARRAY <<< "$NODES"
        for node in "${NODE_ARRAY[@]}"; do
            node=$(echo "$node" | tr -d ' ')
            [[ "$node" == "$(hostname)" ]] && continue
            echo -n "   Copiando a ${node}... "
            scp $SSH_OPTS /etc/multipath.conf "root@${node}:/etc/multipath.conf" 2>/dev/null && ok "OK" || warn "falló"
        done
    fi

    echo ""
    echo "Recargando multipath..."
    systemctl restart multipathd 2>/dev/null || true
    sleep 3
    multipath -F 2>/dev/null || true
    multipath -v2 2>&1 | head -20 || true

    echo ""
    echo -e "${BOLD}Dispositivos multipath activos:${NC}"
    multipath -ll 2>/dev/null | head -40 || warn "No hay dispositivos multipath todavía"
}

# ─── 17. Primer nodo del cluster ─────────────────────────────────────────────
step_first_node() {
    print_step " PASO 18: Identificando Nodo Principal"

    echo ""
    echo "En un cluster Proxmox VE, el storage se crea desde CUALQUIER nodo"
    echo "y se replica automáticamente a todos los demás vía pmxcfs (/etc/pve)."
    echo ""
    echo "Sin embargo, es importante saber qué nodo actúa como 'primario'"
    echo "para ciertos comandos de gestión."
    echo ""

    local current_node
    current_node=$(hostname)

    # Detectar si este nodo es el "quorum" / leader
    local is_leader=false
    if command -v pvecm &>/dev/null; then
        local node_status
        node_status=$(pvecm nodes 2>/dev/null | grep -E "^2.*${current_node}|Local.*${current_node}" || true)
        if echo "$node_status" | grep -qi "online\|local\|master\|primary"; then
            is_leader=true
        fi
    fi

    # Si solo hay un nodo, es el primero
    IFS=',' read -ra NODE_ARRAY <<< "$NODES"
    local node_count=${#NODE_ARRAY[@]}

    echo "   Nodo actual:      ${current_node}"
    echo "   Total nodos:      ${node_count}"
    echo "   ¿Es líder?:       ${is_leader:-desconocido}"
    echo ""

    if [[ $node_count -eq 1 ]]; then
        FIRST_NODE="${NODES// /}"
        ok "Un solo nodo — este es el nodo de gestión del storage."
    else
        echo "Tienes un cluster con ${node_count} nodos."
        echo "El storage se creará desde ESTE nodo y se sincronizará a todos."
        echo ""
        echo "Si prefieres que sea otro nodo el que gestione el storage,"
        echo "ejecuta este script desde ese nodo directamente."
        echo ""
        FIRST_NODE="${current_node}"
        ok "Nodo de gestión del storage: ${FIRST_NODE}"
    fi

    info "El storage creado aquí se sincroniza automáticamente"
    info "a todos los nodos del cluster vía /etc/pve/storage.cfg"
}

# ─── 18. Crear storage ────────────────────────────────────────────────────────
step_create_storage() {
    print_step " PASO 19: Creando Storage en Proxmox VE"

    if ! command -v pvesm &>/dev/null; then
        warn "pvesm no disponible. Omitiendo creación de storage."
        info "Ejecuta manualmente en el nodo deseado: pvesm add iscsi ..."
        press_enter
        return
    fi

    echo ""
    echo "Verificando si el storage ya existe..."
    if pvesm status "${STORAGE_NAME}" &>/dev/null; then
        echo -n "   El storage '${STORAGE_NAME}' ya existe. ¿Sobrescribir? [s/N]: "
        local overwrite; read overwrite
        if [[ "$overwrite" =~ ^[sS]$ ]]; then
            pvesm remove "${STORAGE_NAME}" 2>/dev/null && ok "Eliminado" || warn "No se pudo eliminar"
        else
            ok "Storage existente mantenido. Omitiendo creación."
            press_enter
            return
        fi
    fi

    echo ""
    echo "Creando storage iSCSI en PVE..."
    echo "   Nodo de gestión:  ${FIRST_NODE:-$(hostname)} (este nodo)"
    echo "   Storage syncs:    todos los nodos vía pmxcfs"
    echo "   Nombre:  ${STORAGE_NAME}"
    echo "   Portal:  ${PORTAL_A}"
    echo "   Target:  ${TARGET_IQN}"
    echo "   Nodos:   ${NODES}"
    echo "   Contenido: ${STORAGE_CONTENT}"
    echo ""

    local pvesm_cmd="pvesm add iscsi '${STORAGE_NAME}' \
        --portal '${PORTAL_A}' \
        --target '${TARGET_IQN}' \
        --content '${STORAGE_CONTENT}' \
        --nodes '${NODES}'"

    echo -n "   Ejecutando pvesm (se replica a todos los nodos)... "
    local output; output=$(eval "$pvesm_cmd" 2>&1") || true

    if echo "$output" | grep -qi "error\|fail\|unable"; then
        err "Falló: ${output}"
    else
        ok "Storage '${STORAGE_NAME}' creado"
    fi

    echo ""
    echo "Storages iSCSI en PVE:"
    pvesm status 2>/dev/null | grep -i iscsi || echo "   Ninguno visible"
}

# ─── 18. Habilitar servicios ──────────────────────────────────────────────────
step_enable_services() {
    print_step " PASO 20: Habilitando Servicios"

    echo ""
    print_substep "Habilitando servicios en todos los nodos..."

    IFS=',' read -ra NODE_ARRAY <<< "$NODES"
    for node in "${NODE_ARRAY[@]}"; do
        node=$(echo "$node" | tr -d ' ')
        echo -n "   ${node}: "
        if [[ "$node" == "$(hostname)" ]]; then
            systemctl enable open-iscsi 2>/dev/null && ok "OK" || warn "falló"
            systemctl enable multipathd 2>/dev/null || true
            systemctl enable iscsid 2>/dev/null || true
        else
            ssh $SSH_OPTS "root@${node}" "systemctl enable open-iscsi multipathd iscsid 2>/dev/null" 2>/dev/null && ok "OK" || warn "falló"
        fi
    done
}

# ─── 19. Verificación final ──────────────────────────────────────────────────
step_verify() {
    print_step " PASO 21: Verificación Final"

    echo ""
    echo -e "  ┌──────────────┬────────────────┬──────────────┬─────────┬──────────────┐"
    printf     "  │ %-12s │ %-14s │ %-12s │ %-7s │ %-12s │\n" "NODO" "SESIONES iSCSI" "MULTIPATH" "WWIDs" "STORAGE"
    echo -e "  ├──────────────┼────────────────┼──────────────┼─────────┼──────────────┤"

    IFS=',' read -ra NODE_ARRAY <<< "$NODES"
    for node in "${NODE_ARRAY[@]}"; do
        node=$(echo "$node" | tr -d ' ')
        local sess="—" mpath="—" wwid_c="—" stor="—"

        if [[ "$node" == "$(hostname)" ]]; then
            sess=$(iscsiadm -m session -P1 2>/dev/null | grep -c "tcp" || echo "0")
            mpath=$(multipath -ll 2>/dev/null | grep -c "${MULTIPATH_ALIAS}" || echo "0")
            wwid_c=$(ls -la /dev/disk/by-id/ 2>/dev/null | grep -ciE "scsi-|naa\.|huawei" || echo "0")
            stor=$(pvesm status "${STORAGE_NAME}" 2>/dev/null | grep -c "${STORAGE_NAME}" || echo "0")
        else
            sess=$(ssh $SSH_OPTS "root@${node}" "iscsiadm -m session -P1 2>/dev/null | grep -c 'tcp'" 2>/dev/null || echo "err")
            mpath=$(ssh $SSH_OPTS "root@${node}" "multipath -ll 2>/dev/null | grep -c '${MULTIPATH_ALIAS}'" 2>/dev/null || echo "err")
            wwid_c=$(ssh $SSH_OPTS "root@${node}" "ls -la /dev/disk/by-id/ 2>/dev/null | grep -ciE 'scsi-|naa\.|huawei'" 2>/dev/null || echo "err")
            stor=$(ssh $SSH_OPTS "root@${node}" "pvesm status '${STORAGE_NAME}' 2>/dev/null | grep -c '${STORAGE_NAME}'" 2>/dev/null || echo "err")
        fi

        local sc="$GREEN"; [[ "$sess" == "0" || "$sess" == "err" ]] && sc="$RED"
        local mc="$GREEN"; [[ "$mpath" == "0" || "$mpath" == "err" ]] && mc="$YELLOW"
        local wc="$GREEN"; [[ "$wwid_c" == "0" || "$wwid_c" == "err" ]] && wc="$YELLOW"
        local stc="$GREEN"; [[ "$stor" == "0" || "$stor" == "err" ]] && stc="$YELLOW"

        printf "  │ %-12s │ ${sc}%-14s${NC} │ ${mc}%-12s${NC} │ ${wc}%-7s${NC} │ ${stc}%-12s${NC} │\n" \
            "$node" "$sess sess" "$mpath paths" "$wwid_c WWIDs" "${STOR:-${STORAGE_NAME}}"
    done

    echo -e "  └──────────────┴────────────────┴──────────────┴─────────┴──────────────┘"

    echo ""
    echo -e "${BOLD}Sesiones iSCSI (nodo local):${NC}"
    iscsiadm -m session -P2 2>/dev/null | grep -E "Target|PortalSid|Lun" | head -15 || echo "   Ninguna"

    echo ""
    echo -e "${BOLD}Multipath (nodo local):${NC}"
    multipath -ll 2>/dev/null | head -25 || echo "   Ninguno"

    echo ""
    echo -e "${BOLD}WWIDs de Dorado (nodo local):${NC}"
    ls -la /dev/disk/by-id/ 2>/dev/null | grep -iE "scsi-|naa\.|huawei|dorado" | head -10 || echo "   Ninguno"
}

# ─── 22. Final ────────────────────────────────────────────────────────────────
step_final() {
    print_step " ¡CONFIGURACIÓN COMPLETADA!"

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║        ¡Huawei Dorado conectado exitosamente!                ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${BOLD}Resumen:${NC}"
    echo "   Cabina:        Huawei Dorado"
    echo "   Portal A:      ${PORTAL_A}:${ISCSI_PORT}"
    [[ -n "$PORTAL_B" ]] && echo "   Portal B:      ${PORTAL_B}:${ISCSI_PORT}"
    echo "   Target:        ${TARGET_IQN}"
    echo "   LUN ID:        ${LUN_ID}"
    echo "   Storage:       ${STORAGE_NAME} (${STORAGE_CONTENT})"
    echo "   WWIDs:         ${#ALL_WWIDS[@]}"
    echo "   Cluster nodes: ${NODES}"
    echo ""

    echo -e "${BOLD}IQNs de iniciadores (para referencia futura):${NC}"
    for n in "${!NODE_IQNS[@]}"; do
        echo -e "   ${n}: ${NODE_IQNS[$n]}"
    done
    echo ""

    echo -e "${BOLD}Comandos de verificación:${NC}"
    echo ""
    echo "   # Ver sesiones iSCSI"
    echo "   iscsiadm -m session -P3"
    echo ""
    echo "   # Ver multipath"
    echo "   multipath -ll"
    echo "   multipath -v3 2>&1 | grep -i dorado"
    echo ""
    echo "   # Ver LUNs y WWIDs"
    echo "   lsscsi -t"
    echo "   lsblk -o NAME,SIZE,TYPE,HCTL,VENDOR,MODEL"
    echo "   ls -la /dev/disk/by-id/ | grep -iE 'scsi|naa|huawei'"
    echo ""
    echo "   # Verificar que todos los nodos ven la misma LUN"
    echo "   ssh pve2 'ls -la /dev/disk/by-id/ | grep scsi'"
    echo "   ssh pve3 'ls -la /dev/disk/by-id/ | grep scsi'"
    echo ""
    echo "   # Storage en PVE"
    echo "   pvesm status"
    echo "   pvesm list ${STORAGE_NAME}"
    echo ""
    echo "   # Logs de multipath"
    echo "   journalctl -u multipathd -n 20"
    echo "   tail -f /var/log/syslog | grep -iE 'multipath|iscsi|huawei'"
    echo ""
    echo "   # Simular failover (logout de un portal)"
    echo "   iscsiadm -m session -P1  # ver SID de la sesión"
    echo "   iscsiadm -m session -r <SID> --action logout  # desde portal B"
    echo "   # Verificar que el tráfico pasa por portal A automáticamente"
    echo "   multipath -ll  # ver path activo"
    echo ""

    echo -e "${YELLOW}IMPORTANTE:${NC}"
    echo "   • Las sesiones iSCSI se mantienen activas tras reinicios (node.startup=automatic)"
    echo "   • Si necesitas desconectar: ./pve_iscsi_dorado.sh --disconnect"
    echo "   • Backup de config en: ${BACKUP_DIR}/"
    echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
    step_welcome
    step_cluster_info
    step_dorado_info
    step_network
    step_chap
    step_storage
    step_advanced
    step_summary
    step_install
    step_configure_initiators
    step_create_iface
    step_discovery
    step_dorado_prep
    step_login
    step_authorization
    step_multipath
    step_scan_wwids
    step_add_wwids
    step_first_node
    step_create_storage
    step_enable_services
    step_verify
    step_final
}

main "$@"
