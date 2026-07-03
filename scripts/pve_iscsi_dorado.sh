#!/bin/bash
#===============================================================================
# Proxmox + Huawei Dorado iSCSI - Configuración Interactiva
# Script interactivo para configurar iSCSI + Multipath en nodos Proxmox
# conectando a cabina Huawei Dorado.
#
# EJECUTAR EN CADA NODO del cluster por separado.
# Este script NO usa SSH. Cada nodo se configura localmente.
# El parámetro --nodes es solo informativo (para IQNs de referencia y storage).
#
# Uso:
#   ./pve_iscsi_dorado.sh
#
# Requisitos:
#   - Root
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

# ─── Estado global ────────────────────────────────────────────────────────────
declare -A NODE_IQNS          # IQNs de todos los nodos del cluster
declare -a ALL_WWIDS=()       # WWIDs detectados en este nodo
ISCSI_PORT=3260
STORAGE_CONTENT="images,rootdir,iso,backup,vztmpl"
MULTIPATH_ALIAS="huawei_dorado"
INITIATOR_IFACE_NAME="huawei_iscsi_iface"
INITIATOR_IQN=""
PORTAL_A=""
PORTAL_B=""
TARGET_IQN=""
LUN_ID=""
NODES=""                     # Nodos del cluster (referencia para storage)
NODE_LOCAL=""                # Nombre de este nodo
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

ok()   { echo -e "     ${GREEN}✓ $1${NC}"; }
warn() { echo -e "     ${YELLOW}⚠ $1${NC}"; }
err()  { echo -e "     ${RED}✗ $1${NC}"; }
info() { echo -e "     ${BLUE}ℹ $1${NC}"; }

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

# ─── 1. Bienvenida ─────────────────────────────────────────────────────────────
step_welcome() {
    clear
    banner
    echo -e "${BOLD}Bienvenido al asistente de configuración iSCSI para Huawei Dorado${NC}"
    echo ""
    echo "Este script se ejecuta LOCALMENTE en cada nodo Proxmox."
    echo "Se configura este nodo únicamente — sin SSH a otros nodos."
    echo ""
    echo "Qué hace:"
    echo "  • Instalar paquetes necesarios"
    echo "  • Configurar el iniciador iSCSI de ESTE nodo"
    echo "  • Conectar a la cabina Dorado"
    echo "  • Configurar multipath con optimización ALUA"
    echo "  • Crear el storage compartido en Proxmox VE"
    echo ""
    echo -e "${YELLOW}IMPORTANTE:${NC}"
    echo "  • Ejecutá este script EN CADA NODO del cluster por separado"
    echo "  • Al final te mostrará los IQNs de todos los nodos"
    echo "  • Necesitarás acceso a la consola de Dorado para autorizar"
    echo ""

    if ! [[ $EUID -eq 0 ]]; then
        echo -e "${RED}Este script debe ejecutarse como ROOT.${NC}"
        exit 1
    fi

    NODE_LOCAL=$(hostname)
    ok "Nodo local: ${NODE_LOCAL}"
    ask_continue
}

# ─── 2. Info del cluster ─────────────────────────────────────────────────────
step_cluster_info() {
    print_step " PASO 1: Información del Cluster"

    echo ""
    echo "Este script configura SOLO este nodo (${NODE_LOCAL})."
    echo "Sin embargo, necesitamos saber cuántos nodos tiene el cluster"
    echo "para:"
    echo "  a) Generar la tabla completa de IQNs de todos los nodos"
    echo "  b) Crear el storage con los nodos correctos"
    echo ""
    echo "Si es un solo nodo (standalone), ingresá solo su nombre."
    echo ""
    echo -e "${CYAN}Ejemplo cluster de 3 nodos:${NC} pve1,pve2,pve3"
    echo -e "${CYAN}Ejemplo standalone:${NC} pve1"
    echo ""

    read -p "Nodos del cluster [${NODE_LOCAL}]: " NODES_INPUT
    NODES="${NODES_INPUT:-${NODE_LOCAL}}"
    NODES=$(echo "$NODES" | sed 's/[[:space:]]*,[[:space:]]*/,/g' | sed 's/^,//;s/,$//')

    IFS=',' read -ra NODE_ARRAY <<< "$NODES"
    local count=${#NODE_ARRAY[@]}

    if [[ $count -eq 1 ]]; then
        ok "Standalone — 1 nodo: ${NODES}"
    else
        ok "Cluster — ${count} nodos: ${NODES}"
        info "Debés ejecutar este script en CADA nodo del cluster."
    fi
}

# ─── 3. Info del Dorado ───────────────────────────────────────────────────────
step_dorado_info() {
    print_step " PASO 2: Información de Huawei Dorado"

    echo ""
    echo "Datos de conexión a la cabina Huawei Dorado."
    echo ""

    while true; do
        read -p "IP Portal Primario Dorado: " PORTAL_A
        [[ -n "$PORTAL_A" ]] && break
        echo "   Valor requerido."
    done

    echo ""
    echo -e "${CYAN}Portal Secundario (ALUA — segundo puerto de controladora):${NC}"
    read -p "IP Portal Secundario [opcional]: " PORTAL_B

    echo ""
    read -p "Puerto iSCSI [${ISCSI_PORT}]: " tmp_port
    ISCSI_PORT="${tmp_port:-${ISCSI_PORT}}"

    echo ""
    echo -e "${CYAN}IQN del Target:${NC}"
    echo "   En la consola de Dorado:"
    echo "   Sistema > Configuración > Destinos iSCSI > [tu target] > IQN"
    while true; do
        read -p "IQN del Target: " TARGET_IQN
        [[ -n "$TARGET_IQN" ]] && break
        echo "   Valor requerido."
    done

    echo ""
    echo -e "${CYAN}LUN ID(s):${NC}"
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

# ─── 4. Red ────────────────────────────────────────────────────────────────────
step_network() {
    print_step " PASO 3: Configuración de Red iSCSI"

    echo ""
    echo -e "${YELLOW}IMPORTANTE:${NC} Las interfaces deben tener IP ya configurada."
    echo "            Este script solo ajusta el MTU, no configura IPs."
    echo ""

    echo "Interfaces con IP en este nodo:"
    ip -br addr show | grep -v "^lo\|^docker\|^veth" | awk '{print "   " $1 " → " $3}'

    echo ""
    read -p "Interfaz para Portal A (ej: enp0s3): " IFACE_A
    echo ""
    read -p "Interfaz para Portal B [opcional]: " IFACE_B

    if [[ -z "$IFACE_A" ]]; then
        warn "Sin iface específica — se usará la ruta por defecto."
    else
        local iface_ip
        iface_ip=$(ip -br addr show "$IFACE_A" 2>/dev/null | awk '{print $3}' || true)
        if [[ -n "$iface_ip" ]]; then
            ok "Iface A: ${IFACE_A} → ${iface_ip}"
        else
            warn "Iface A: ${IFACE_A} — sin IP detectada en este nodo"
        fi

        if [[ -n "$IFACE_B" ]]; then
            iface_ip=$(ip -br addr show "$IFACE_B" 2>/dev/null | awk '{print $3}' || true)
            ok "Iface B: ${IFACE_B} → ${iface_ip}"
        fi
    fi

    echo ""
    echo "Ajuste de MTU:"
    echo "  9000  → Jumbo frames (recomendado para iSCSI)"
    echo "  1500  → MTU estándar"
    read -p "¿MTU? [9000]: " tmp_mtu
    MTU="${tmp_mtu:-9000}"

    if [[ "$MTU" == "9000" ]] && [[ -n "$IFACE_A" ]]; then
        echo ""
        echo -n "¿Aplicar MTU 9000 a ${IFACE_A}? [s/N]: "
        local apply; read apply
        if [[ "$apply" =~ ^[sS]$ ]]; then
            ip link set "$IFACE_A" mtu 9000 2>/dev/null && ok "MTU 9000 aplicado a ${IFACE_A}" || warn "No se pudo aplicar MTU"
        fi
        if [[ -n "$IFACE_B" ]]; then
            echo -n "¿Aplicar MTU 9000 a ${IFACE_B}? [s/N]: "
            read apply
            if [[ "$apply" =~ ^[sS]$ ]]; then
                ip link set "$IFACE_B" mtu 9000 2>/dev/null && ok "MTU 9000 aplicado a ${IFACE_B}" || warn "No se pudo aplicar MTU"
            fi
        fi
    fi
}

# ─── 5. CHAP ──────────────────────────────────────────────────────────────────
step_chap() {
    print_step " PASO 4: Autenticación CHAP (Opcional)"

    echo ""
    echo "Si la cabina Dorado requiere autenticación CHAP, ingresá las credenciales."
    echo "Si no usás CHAP, déjalo en blanco."
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

# ─── 6. Storage ────────────────────────────────────────────────────────────────
step_storage() {
    print_step " PASO 5: Storage en Proxmox VE"

    echo ""
    echo "Configuración del storage iSCSI en Proxmox."
    echo ""

    read -p "Nombre del storage [dorado_shared]: " tmp_st
    STORAGE_NAME="${tmp_st:-dorado_shared}"

    echo ""
    echo "Tipos de contenido:"
    echo "  images,rootdir  → VMs (discos + raíz) — recomendado"
    echo "  images           → solo discos de VMs"
    echo "  iso,backup       → ISOs y backups"
    echo "  images,rootdir,iso,backup,vztmpl → todo"
    read -p "Contenido [images,rootdir,iso,backup,vztmpl]: " tmp_ct
    STORAGE_CONTENT="${tmp_ct:-images,rootdir,iso,backup,vztmpl}"

    ok "Storage: ${STORAGE_NAME}"
    ok "Contenido: ${STORAGE_CONTENT}"

    if ! command -v pvesm &>/dev/null; then
        warn "pvesm no encontrado — no se creará storage."
    fi
}

# ─── 7. Opciones avanzadas ──────────────────────────────────────────────────────
step_advanced() {
    print_step " PASO 6: Opciones Avanzadas"

    echo ""
    read -p "Alias multipath [huawei_dorado]: " tmp_alias
    MULTIPATH_ALIAS="${tmp_alias:-huawei_dorado}"
    read -p "¿Verbose? [N]: " tmp_v
    [[ "$tmp_v" =~ ^[sSyY]$ ]] && VERBOSE=true

    ok "Multipath alias: ${MULTIPATH_ALIAS}"
}

# ─── 8. Resumen ───────────────────────────────────────────────────────────────
step_summary() {
    print_step " RESUMEN ANTES DE INICIAR"

    echo ""
    echo -e "${BOLD}Este nodo:${NC}       ${NODE_LOCAL}"
    echo -e "${BOLD}Cluster nodes:${NC}     ${NODES}"
    echo -e "${BOLD}Cabina:${NC}          Huawei Dorado"
    echo -e "${BOLD}Portal A:${NC}         ${PORTAL_A}:${ISCSI_PORT}"
    echo -e "${BOLD}Portal B:${NC}         ${PORTAL_B:--}"
    echo -e "${BOLD}Target IQN:${NC}       ${TARGET_IQN}"
    echo -e "${BOLD}LUN ID:${NC}           ${LUN_ID}"
    echo -e "${BOLD}Interfaz(es):${NC}    ${IFACE_A:--}${IFACE_B:+, $IFACE_B}"
    echo -e "${BOLD}MTU:${NC}              ${MTU}"
    echo -e "${BOLD}CHAP:${NC}             ${CHAP_USER:--}"
    echo -e "${BOLD}Storage:${NC}          ${STORAGE_NAME} (${STORAGE_CONTENT})"
    echo ""

    echo -e "${YELLOW}${BOLD}Flujo:${NC}"
    echo "  1. Instalar paquetes"
    echo "  2. Configurar IQN de este nodo"
    echo "  3. Crear iface iSCSI"
    echo "  4. Descubrir targets"
    echo "  5. ⬅️  Preparar Host en Dorado con los IQNs"
    echo "  6. Login (aparece el iniciador en Dorado)"
    echo "  7. ⬅️  Autorizar iniciador en Dorado"
    echo "  8. Multipath + WWIDs"
    echo "  9. Crear storage en PVE"
    echo ""

    echo -e "${CYAN}¿Todo correcto?${NC}"
    ask_continue
}

# ─── 9. Instalar paquetes ─────────────────────────────────────────────────────
step_install() {
    print_step " PASO 7: Instalando Paquetes"

    declare -a PKGS=("open-iscsi" "multipath-tools" "lsscsi")
    local missing=()

    for pkg in "${PKGS[@]}"; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "Todos los paquetes ya están instalados"
    else
        echo "Instalando: ${missing[*]}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq "${missing[@]}"
        ok "Paquetes instalados"
    fi
}

# ─── 10. Configurar IQN ──────────────────────────────────────────────────────
step_configure_initiator() {
    print_step " PASO 8: Configurando Iniciador IQN"

    print_substep "Configurando IQN en ${NODE_LOCAL}..."

    local initiator_file="/etc/iscsi/initiatorname.iscsi"
    local current_iqn=""
    current_iqn=$(grep -i "^InitiatorName=" "$initiator_file" 2>/dev/null | cut -d= -f2 || true)

    if [[ -n "$current_iqn" ]]; then
        ok "IQN actual: ${current_iqn}"
        echo -n "¿Usar este IQN? [S/n]: "
        local use_current; read use_current
        if [[ "$use_current" =~ ^[nN]$ ]]; then
            read -p "Nuevo IQN: " new_iqn
            if [[ -n "$new_iqn" ]]; then
                echo "InitiatorName=${new_iqn}" > "$initiator_file"
                chmod 640 "$initiator_file"
                current_iqn="$new_iqn"
                ok "IQN actualizado: ${current_iqn}"
            fi
        fi
    else
        echo "No se detectó IQN."
        read -p "Nuevo IQN: " new_iqn
        if [[ -n "$new_iqn" ]]; then
            echo "InitiatorName=${new_iqn}" > "$initiator_file"
            chmod 640 "$initiator_file"
            current_iqn="$new_iqn"
            ok "IQN configurado: ${current_iqn}"
        fi
    fi

    INITIATOR_IQN="$current_iqn"

    # Guardar IQN de ESTE nodo
    NODE_IQNS["$NODE_LOCAL"]="$current_iqn"

    echo ""
    echo "Este nodo ya tiene su IQN: ${current_iqn}"
    info "Si tenés más nodos en el cluster,"
    info "ejecutá este script en cada uno para generar todos los IQNs."
}

# ─── 11. Crear iface ─────────────────────────────────────────────────────────
step_create_iface() {
    print_step " PASO 9: Creando iface iSCSI"

    print_substep "Creando iface '${INITIATOR_IFACE_NAME}' en ${NODE_LOCAL}..."

    local mac_addr=""
    if [[ -n "$IFACE_A" ]]; then
        mac_addr=$(ip link show "$IFACE_A" 2>/dev/null | grep ether | awk '{print $2}' || true)
    fi

    mkdir -p /etc/iscsi/ifaces
    cat > "/etc/iscsi/ifaces/${INITIATOR_IFACE_NAME}.iface" <<EOF
# Huawei Dorado iSCSI iface
# Nodo: ${NODE_LOCAL}
# Generado: $(date)
iface.iface_name ${INITIATOR_IFACE_NAME}
iface.net_iface_name ${IFACE_A:-auto}
iface.hwaddress ${mac_addr:-auto}
iface.transport_name tcp
iface.initiatorname ${INITIATOR_IQN}
iface.tcp_xmit_wsf_semantics 0
iface.tcp_recv_wsf_semantics 0
iface.iface_num 0
iface.mtu ${MTU}
EOF

    ok "Iface creada: /etc/iscsi/ifaces/${INITIATOR_IFACE_NAME}.iface"
}

# ─── 12. Descubrimiento ───────────────────────────────────────────────────────
step_discovery() {
    print_step " PASO 10: Descubriendo Targets"

    echo "Haciendo descubrimiento en el/los portales Dorado."
    echo ""

    print_substep "Descubriendo en ${PORTAL_A}:${ISCSI_PORT}..."
    local result
    result=$(iscsiadm -m discovery -t st -p "${PORTAL_A}:${ISCSI_PORT}" -I "${INITIATOR_IFACE_NAME}" 2>&1 || true)
    if echo "$result" | grep -qi "empty\|error\|no targets\|auth"; then
        warn "Descubrimiento tuvo problemas (normal si no está autorizado)"
    else
        ok "Descubrimiento exitoso"
    fi

    if [[ -n "$PORTAL_B" ]]; then
        print_substep "Descubriendo en ${PORTAL_B}:${ISCSI_PORT}..."
        result=$(iscsiadm -m discovery -t st -p "${PORTAL_B}:${ISCSI_PORT}" -I "${INITIATOR_IFACE_NAME}" 2>&1 || true)
        ok "Descubrimiento completado"
    fi
}

# ─── 13. Preparación Dorado ──────────────────────────────────────────────────
step_dorado_prep() {
    print_step " ⬅️  PASO 11: PREPARACIÓN EN DORADO"

    echo ""
    echo -e "${BOLD}ANTES del login, creá el Host en Dorado con los IQNs.${NC}"
    echo "Cuando ejecutes este script en cada nodo, vas generando la tabla completa."
    echo ""

    # Mostrar IQNs de todos los nodos conocidos
    if [[ ${#NODE_IQNS[@]} -gt 0 ]]; then
        echo -e "  ┌──────────────────────────────────────────────────────────────────┐"
        printf   "  │ %-20s │ %-52s │\n" "NODO" "IQN DEL INICIADOR"
        echo -e "  ├──────────────────────────────────────────────────────────────────┤"
        for node in "${!NODE_IQNS[@]}"; do
            printf "  │ %-20s │ %-52s │\n" "$node" "${NODE_IQNS[$node]}"
        done
        echo -e "  └──────────────────────────────────────────────────────────────────┘"
        echo ""
    fi

    echo -e "${CYAN}En la consola de Dorado:${NC}"
    echo -e "${BOLD}1.${NC} Configuración > Hosts > Crear Host"
    echo "   Nombre: pve_cluster (o el que prefieras)"
    echo "   Tipo: Host iSCSI"
    echo -e "${BOLD}2.${NC} Añadir los IQNs de arriba al host"
    echo -e "${BOLD}3.${NC} Asociar el host con: ${TARGET_IQN}"
    echo -e "${BOLD}4.${NC} MAPEAR las LUNs al host (LUN ${LUN_ID})"
    echo -e "${BOLD}5.${NC} Guardar"
    echo ""
    echo -e "${YELLOW}Cuando esté listo, presioná ENTER para hacer el login.${NC}"
    echo ""

    press_enter
    ok "Continuando al login..."
}

# ─── 14. Login ──────────────────────────────────────────────────────────────
step_login() {
    print_step " PASO 12: Login a los Targets"

    echo ""
    echo -e "${YELLOW}ATENCIÓN:${NC} Al hacer el login, el iniciador aparecerá en Dorado."
    echo "Después del login tendrás que asociarlo y autorizarlo."
    echo ""

    print_substep "Login en ${PORTAL_A}:${ISCSI_PORT}..."

    # CHAP
    if [[ -n "$CHAP_USER" ]]; then
        iscsiadm -m node -T "${TARGET_IQN}" -p "${PORTAL_A}:${ISCSI_PORT}" -I "${INITIATOR_IFACE_NAME}" \
            -o update -n node.session.auth.authmethod -v CHAP 2>/dev/null || true
        iscsiadm -m node -T "${TARGET_IQN}" -p "${PORTAL_A}:${ISCSI_PORT}" -I "${INITIATOR_IFACE_NAME}" \
            -o update -n node.session.auth.username -v "${CHAP_USER}" 2>/dev/null || true
        iscsiadm -m node -T "${TARGET_IQN}" -p "${PORTAL_A}:${ISCSI_PORT}" -I "${INITIATOR_IFACE_NAME}" \
            -o update -n node.session.auth.password -v "${CHAP_PASS}" 2>/dev/null || true
        ok "CHAP configurado"
    fi

    # Login
    local result
    result=$(iscsiadm -m node -T "${TARGET_IQN}" -p "${PORTAL_A}:${ISCSI_PORT}" -I "${INITIATOR_IFACE_NAME}" --login 2>&1 || true)
    if echo "$result" | grep -qi "login failed\|iscsi_err"; then
        warn "Login tuvo problemas: $result"
    else
        ok "Login enviado"
    fi

    # Persist
    iscsiadm -m node -T "${TARGET_IQN}" -p "${PORTAL_A}:${ISCSI_PORT}" -I "${INITIATOR_IFACE_NAME}" \
        -o update -n node.startup -v automatic 2>/dev/null || true

    # Portal B
    if [[ -n "$PORTAL_B" ]]; then
        print_substep "Login en ${PORTAL_B}:${ISCSI_PORT}..."
        result=$(iscsiadm -m node -T "${TARGET_IQN}" -p "${PORTAL_B}:${ISCSI_PORT}" -I "${INITIATOR_IFACE_NAME}" --login 2>&1 || true)
        ok "Login enviado"
    fi

    echo ""
    echo "Sesiones iSCSI:"
    iscsiadm -m session -P1 2>/dev/null | grep -E "tcp|Portal" | head -20 || echo "   Ninguna visible todavía"
}

# ─── 15. Autorización post-login ──────────────────────────────────────────────
step_authorization() {
    print_step " ⬅️  PASO 13: AUTORIZACIÓN EN DORADO (POST-LOGIN)"

    echo ""
    echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║          ACCIÓN REQUERIDA EN LA CONSOLA DORADO              ║${NC}"
    echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}El login se ejecutó. Ahora asociá y autorizá el iniciador en Dorado:${NC}"
    echo ""

    if [[ -n "${NODE_IQNS[$NODE_LOCAL]:-}" ]]; then
        echo -e "  ┌──────────────────────────────────────────────────────────────────┐"
        printf   "  │ %-20s │ %-52s │\n" "NODO" "IQN DEL INICIADOR"
        echo -e "  ├──────────────────────────────────────────────────────────────────┤"
        for node in "${!NODE_IQNS[@]}"; do
            printf "  │ %-20s │ %-52s │\n" "$node" "${NODE_IQNS[$node]}"
        done
        echo -e "  └──────────────────────────────────────────────────────────────────┘"
        echo ""
    fi

    echo -e "${CYAN}En la consola de Dorado:${NC}"
    echo -e "${BOLD}1.${NC} Buscá el iniciador que apareció en Hosts > pve_cluster > Initiators"
    echo -e "${BOLD}2.${NC} Asociá el/los iniciador/es al host (Enable)"
    echo -e "${BOLD}3.${NC} Autorizá (Allow)"
    echo -e "${BOLD}4.${NC} Verificá que la LUN ${LUN_ID} esté mapeada"
    echo -e "${BOLD}5.${NC} Guardar cambios"
    echo ""
    echo -e "${YELLOW}Cuando esté autorizado, volvé aquí y presioná ENTER.${NC}"
    echo ""

    press_enter

    echo ""
    echo "Esperando a que las LUNs se detecten..."
    local waited=0
    while [[ $waited -lt 120 ]]; do
        echo -n "   Verificando... "
        local lun_count
        lun_count=$(lsblk -d -n -o NAME 2>/dev/null | grep -cE '^sd[a-z]+$|^dm-[0-9]+$' || echo "0")
        if [[ "$lun_count" -gt 0 ]]; then
            ok "LUN visible ($lun_count dispositivos)"
            break
        fi
        waited=$((waited + 10))
        sleep 10
        echo -ne "${YELLOW}Sin LUN (${waited}s). ¿Seguir? [S]: ${NC}"
        local retry; read -t 10 retry || true
        [[ "$retry" =~ ^[nN]$ ]] && break
    done
    ok "Continuando..."
}

# ─── 16. Multipath ───────────────────────────────────────────────────────────
step_multipath() {
    print_step " PASO 14: Configurando Multipath"

    echo ""
    echo "Generando multipath.conf optimizado para Huawei Dorado ALUA..."
    echo ""

    mkdir -p "${BACKUP_DIR}"
    [[ -f /etc/multipath.conf ]] && cp -a /etc/multipath.conf "${BACKUP_DIR}/multipath.conf.bak"

    cat > /etc/multipath.conf <<'EOF'
# /etc/multipath.conf
# Huawei Dorado + Proxmox
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
    systemctl restart multipathd 2>/dev/null && ok "multipathd reiniciado" || warn "Falló reiniciar multipathd"
    systemctl enable multipathd 2>/dev/null
}

# ─── 17. WWIDs ───────────────────────────────────────────────────────────────
step_scan_wwids() {
    print_step " PASO 15: Escaneando LUNs y Detectando WWIDs"

    echo ""
    echo "Rescaneando buses SCSI..."
    for host in /sys/class/scsi_host/host*/scan; do
        echo "- - -" > "$host" 2>/dev/null || true
    done
    sleep 5

    echo ""
    echo -e "${BOLD}Dispositivos detectados:${NC}"
    lsblk -o NAME,SIZE,TYPE,VENDOR,MODEL 2>/dev/null | head -15

    echo ""
    echo "Buscando WWIDs de Dorado..."

    # /dev/disk/by-id
    echo "   [1/4] /dev/disk/by-id/"
    local byid_wwids
    byid_wwids=$(ls -la /dev/disk/by-id/ 2>/dev/null | grep -iE "scsi-.*|naa\.|huawei|dorado" | awk '{print $NF}' | sort -u || true)
    if [[ -n "$byid_wwids" ]]; then
        while IFS= read -r w; do
            [[ -z "$w" ]] && continue
            local base; base=$(basename "$w")
            if [[ ! " ${ALL_WWIDS[*]} " =~ " ${base} " ]]; then
                ALL_WWIDS+=("$base")
                ok "   WWID: $base"
            fi
        done <<< "$byid_wwids"
    else
        info "   No encontrado en by-id"
    fi

    # lsscsi
    echo ""
    echo "   [2/4] lsscsi"
    local lsscsi_out
    lsscsi_out=$(lsscsi 2>/dev/null || true)
    if echo "$lsscsi_out" | grep -qiE "huawei|dorado|oceanstor"; then
        echo "$lsscsi_out" | grep -iE "huawei|dorado|oceanstor" | while read -r line; do
            ok "   $line"
        done
    fi

    # sysfs
    echo ""
    echo "   [3/4] sysfs"
    for block_dev in /sys/block/sd*; do
        [[ ! -e "$block_dev" ]] && continue
        local dev_name; dev_name=$(basename "$block_dev")
        local vendor; vendor=$(cat "${block_dev}/device/vendor" 2>/dev/null | tr -d ' ' || true)
        local wwid; wwid=$(cat "${block_dev}/device/wwid" 2>/dev/null || true)
        if [[ "$vendor" =~ HUAWEI|DORADO|OCEAN || "$wwid" =~ ^naa\. ]]; then
            ok "   /dev/${dev_name} | ${vendor} | WWID: ${wwid}"
            [[ "$wwid" =~ ^naa\. && ! " ${ALL_WWIDS[*]} " =~ " ${wwid} " ]] && ALL_WWIDS+=("$wwid")
        fi
    done

    # multipath -v3
    echo ""
    echo "   [4/4] multipath -v3"
    local mpath_out
    mpath_out=$(multipath -v3 2>&1 | grep -A3 -iE "huawei|dorado|${TARGET_IQN}" | head -20 || true)
    [[ -n "$mpath_out" ]] && echo "$mpath_out" | while read -r line; do
        ok "   $line"
    done

    echo ""
    echo -e "${BOLD}WWIDs detectados: ${#ALL_WWIDS[@]}${NC}"
    for w in "${ALL_WWIDS[@]}"; do
        ok "   → $w"
    done

    if [[ ${#ALL_WWIDS[@]} -eq 0 ]]; then
        warn "No se detectaron WWIDs. ¿LUN no autorizada?"
    fi
}

# ─── 18. Agregar WWIDs al multipath ──────────────────────────────────────────
step_add_wwids() {
    print_step " PASO 16: Agregando WWIDs al Multipath"

    if [[ ${#ALL_WWIDS[@]} -eq 0 ]]; then
        warn "No hay WWIDs detectados. Multipath usará detección automática."
    else
        echo "Agregando ${#ALL_WWIDS[@]} WWIDs al multipath.conf..."

        {
            echo ""
            echo "# WWIDs Dorado - $(date)"
            echo "multipaths {"
            local idx=0
            for wwid in "${ALL_WWIDS[@]}"; do
                [[ -z "$wwid" || "$wwid" == "naa.placeholder" ]] && continue
                local alias_name="${MULTIPATH_ALIAS}"
                [[ ${#ALL_WWIDS[@]} -gt 1 ]] && alias_name="${MULTIPATH_ALIAS}_${idx}"
                cat <<EOF
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
                idx=$((idx + 1))
            done
            echo "}"
        } >> /etc/multipath.conf

        ok "WWIDs agregados al multipath.conf"
    fi

    echo "Recargando multipath..."
    systemctl restart multipathd 2>/dev/null || true
    sleep 3
    multipath -F 2>/dev/null || true
    multipath -v2 2>&1 | head -20 || true

    echo ""
    echo -e "${BOLD}Dispositivos multipath:${NC}"
    multipath -ll 2>/dev/null | head -30 || warn "No hay multipath todavía"
}

# ─── 19. Crear storage ───────────────────────────────────────────────────────
step_create_storage() {
    print_step " PASO 17: Creando Storage en Proxmox VE"

    if ! command -v pvesm &>/dev/null; then
        warn "pvesm no disponible. Omitiendo storage."
        press_enter
        return
    fi

    echo ""
    echo "Creando storage iSCSI en PVE..."
    echo "   Storage:    ${STORAGE_NAME}"
    echo "   Portal:      ${PORTAL_A}"
    echo "   Target:      ${TARGET_IQN}"
    echo "   Nodos:       ${NODES}"
    echo "   Contenido:   ${STORAGE_CONTENT}"
    echo ""

    if pvesm status "${STORAGE_NAME}" &>/dev/null; then
        echo -n "El storage ya existe. ¿Sobrescribir? [s/N]: "
        local overwrite; read overwrite
        if [[ "$overwrite" =~ ^[sS]$ ]]; then
            pvesm remove "${STORAGE_NAME}" 2>/dev/null && ok "Eliminado" || warn "No se pudo eliminar"
        else
            ok "Storage existente mantenido."
            press_enter
            return
        fi
    fi

    mkdir -p "${BACKUP_DIR}"

    local output
    output=$(pvesm add iscsi "${STORAGE_NAME}" \
        --portal "${PORTAL_A}" \
        --target "${TARGET_IQN}" \
        --content "${STORAGE_CONTENT}" \
        --nodes "${NODES}" 2>&1) || true

    if echo "$output" | grep -qi "error\|fail\|unable"; then
        err "Falló: $output"
    else
        ok "Storage '${STORAGE_NAME}' creado"
    fi

    echo ""
    echo "Storages iSCSI:"
    pvesm status 2>/dev/null | grep -i iscsi || echo "   Ninguno"
}

# ─── 20. Habilitar servicios ──────────────────────────────────────────────────
step_enable_services() {
    print_step " PASO 18: Habilitando Servicios"

    print_substep "Habilitando servicios en ${NODE_LOCAL}..."
    systemctl enable open-iscsi 2>/dev/null && ok "open-iscsi: enabled" || warn "open-iscsi: falló"
    systemctl enable multipathd 2>/dev/null && ok "multipathd: enabled" || warn "multipathd: falló"
    systemctl enable iscsid 2>/dev/null && ok "iscsid: enabled" || warn "iscsid: falló"
}

# ─── 21. Verificación ─────────────────────────────────────────────────────────
step_verify() {
    print_step " PASO 19: Verificación"

    echo ""
    echo -e "${BOLD}Nodo local: ${NODE_LOCAL}${NC}"
    echo ""
    echo "Sesiones iSCSI:"
    iscsiadm -m session -P2 2>/dev/null | grep -E "Target|PortalSid|Lun" | head -15 || echo "   Ninguna"

    echo ""
    echo "Multipath:"
    multipath -ll 2>/dev/null | head -25 || echo "   Ninguno"

    echo ""
    echo "WWIDs Dorado:"
    ls -la /dev/disk/by-id/ 2>/dev/null | grep -iE "scsi-|naa\.|huawei" | head -10 || echo "   Ninguno"

    if command -v pvesm &>/dev/null; then
        echo ""
        echo "Storages iSCSI:"
        pvesm status 2>/dev/null | grep iscsi || echo "   Ninguno"
    fi
}

# ─── 22. Final ────────────────────────────────────────────────────────────────
step_final() {
    print_step " ¡CONFIGURACIÓN DE ${NODE_LOCAL} COMPLETADA!"

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║        Nodo ${NODE_LOCAL} configurado exitosamente!          ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    echo -e "${BOLD}Resumen:${NC}"
    echo "   Nodo:          ${NODE_LOCAL}"
    echo "   Cluster:       ${NODES}"
    echo "   Portal A:      ${PORTAL_A}:${ISCSI_PORT}"
    [[ -n "$PORTAL_B" ]] && echo "   Portal B:      ${PORTAL_B}:${ISCSI_PORT}"
    echo "   Target:        ${TARGET_IQN}"
    echo "   LUN ID:        ${LUN_ID}"
    echo "   IQN:           ${INITIATOR_IQN}"
    echo "   WWIDs:         ${#ALL_WWIDS[@]}"
    echo "   Storage:       ${STORAGE_NAME}"
    echo ""

    if [[ ${#NODE_IQNS[@]} -gt 0 ]]; then
        echo -e "${BOLD}IQNs de todos los nodos del cluster:${NC}"
        for n in "${!NODE_IQNS[@]}"; do
            echo -e "   ${n}: ${NODE_IQNS[$n]}"
        done
        echo ""
    fi

    IFS=',' read -ra NODE_ARRAY <<< "$NODES"
    if [[ ${#NODE_ARRAY[@]} -gt 1 ]]; then
        local configured=0
        for n in "${NODE_ARRAY[@]}"; do
            n=$(echo "$n" | tr -d ' ')
            [[ -n "${NODE_IQNS[$n]:-}" ]] && configured=$((configured + 1))
        done
        if [[ $configured -lt ${#NODE_ARRAY[@]} ]]; then
            local remaining=$((${#NODE_ARRAY[@]} - configured))
            echo -e "${YELLOW}${BOLD}⚠ Faltan ${remaining} nodo(s) por configurar:${NC}"
            for n in "${NODE_ARRAY[@]}"; do
                n=$(echo "$n" | tr -d ' ')
                [[ -z "${NODE_IQNS[$n]:-}" ]] && echo -e "   ${n} — ejecutá este script en ese nodo"
            done
            echo ""
        fi
    fi

    echo -e "${BOLD}Comandos de verificación:${NC}"
    echo ""
    echo "   # Ver sesiones iSCSI"
    echo "   iscsiadm -m session -P3"
    echo ""
    echo "   # Ver multipath"
    echo "   multipath -ll"
    echo "   multipath -v3 2>&1 | grep -i dorado"
    echo ""
    echo "   # Ver WWIDs"
    echo "   lsscsi -t"
    echo "   lsblk -o NAME,SIZE,TYPE,HCTL,VENDOR"
    echo "   ls -la /dev/disk/by-id/ | grep -iE 'scsi|naa|huawei'"
    echo ""
    echo "   # Storage"
    echo "   pvesm status"
    echo ""
    echo "   # Logs"
    echo "   journalctl -u multipathd -n 20"
    echo "   tail -f /var/log/syslog | grep -iE 'multipath|iscsi|huawei'"
    echo ""
    echo "   # Descargar este script en otro nodo"
    echo "   curl -LO https://raw.githubusercontent.com/licosta/proxmox/main/scripts/pve_iscsi_dorado.sh"
    echo "   chmod +x pve_iscsi_dorado.sh && ./pve_iscsi_dorado.sh"
    echo ""

    echo -e "${YELLOW}IMPORTANTE:${NC}"
    echo "   • Las sesiones son persistentes (node.startup=automatic)"
    echo "   • Si necesitás desconectar: iscsiadm -m node --logout all"
    echo "   • Ejecutá este script en CADA nodo restante del cluster"
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
    step_configure_initiator
    step_create_iface
    step_discovery
    step_dorado_prep
    step_login
    step_authorization
    step_multipath
    step_scan_wwids
    step_add_wwids
    step_create_storage
    step_enable_services
    step_verify
    step_final
}

main "$@"
