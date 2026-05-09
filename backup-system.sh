#!/usr/bin/env bash
# ==============================================================================
#  backup-system.sh — Script de backup completo para Linux
#  Autor: generado automáticamente
#  Versión: 1.0.0
#  Descripción: Automatiza backups incrementales con rsync hacia un HDD externo,
#               gestiona retención de 4 copias semanales y registra todo en log.
# ==============================================================================

# ------------------------------------------------------------------------------
# MODO ESTRICTO — detiene el script ante cualquier error, variable no definida
# o fallo en pipelines. Fundamental para scripts de backup seguros.
# ------------------------------------------------------------------------------
set -euo pipefail

# ==============================================================================
#  SECCIÓN 1: VARIABLES CONFIGURABLES
#  Edita esta sección según tu entorno. No toques el resto del script.
# ==============================================================================

# UUID del disco externo (obtén el tuyo con: blkid | grep -i "TYPE=\"ext4\"")
DISK_UUID="template"

# Punto de montaje del disco externo
MOUNT_POINT="/mnt/backups"

# Directorio raíz donde se guardarán los backups dentro del disco
BACKUP_ROOT="${MOUNT_POINT}/backups"

# Nombre de la fecha actual (carpeta del backup de hoy)
BACKUP_DATE="$(date +%Y-%m-%d)"
BACKUP_DIR="${BACKUP_ROOT}/${BACKUP_DATE}"

# Número máximo de backups a conservar (política de retención: 4 semanas)
MAX_BACKUPS=4

# Espacio mínimo requerido en el disco externo antes de iniciar (en MB)
MIN_FREE_SPACE_MB=5120  # 5 GB

# Directorios principales a respaldar
BACKUP_SOURCES=(
    "/home"
    "/etc"
    "/var"
)

# Directorios adicionales opcionales (déjalos vacíos si no aplica)
EXTRA_SOURCES=(
    # "/opt"
    # "/srv"
    # "/root"
)

# Directorios a excluir del backup
EXCLUDES=(
    "/proc"
    "/sys"
    "/dev"
    "/tmp"
    "/run"
    "/mnt"
    "/media"
    "/lost+found"
    "**/.cache"
    "**/Cache"
    "**/.Trash"
    "**/Trash"
    "**/.thumbnails"
    "**/node_modules"
    "**/__pycache__"
    "**/*.log"
    "**/snap/*/common/.cache"
    "**/.steam"
    "**/.local/share/Steam"
    "**/steamapps"
    "**/.local/share/lutris"
    "**/.local/share/heroic"
)

# Archivo de log
LOG_FILE="/var/log/backup-script.log"

# Comando rsync base (sin destino ni fuente, se construye dinámicamente)
# -a = archive (permisos, timestamps, links simbólicos, recursivo)
# -v = verbose
# --delete = elimina en destino archivos que ya no existen en origen
# --numeric-ids = preserva UIDs/GIDs sin traducción de nombres
# --human-readable = tamaños legibles en el log
RSYNC_OPTS=(-aAXv --delete --numeric-ids --human-readable --stats --info=progress2 --no-v)

# ==============================================================================
#  SECCIÓN 2: COLORES PARA TERMINAL
# ==============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ==============================================================================
#  SECCIÓN 3: FUNCIONES DE LOG Y MENSAJES
# ==============================================================================

# Inicializa el archivo de log (crea el directorio si no existe)
init_log() {
    local log_dir
    log_dir="$(dirname "${LOG_FILE}")"
    if [[ ! -d "${log_dir}" ]]; then
        mkdir -p "${log_dir}"
    fi
    # Cabecera del log para esta ejecución
    {
        echo ""
        echo "======================================================================"
        echo "  INICIO BACKUP — $(date '+%Y-%m-%d %H:%M:%S')"
        echo "======================================================================"
    } >> "${LOG_FILE}"
}

# log_info: mensaje informativo (verde en terminal, plano en log)
log_info() {
    local msg="[INFO]  $(date '+%H:%M:%S') — $*"
    echo -e "${GREEN}${msg}${RESET}"
    echo "${msg}" >> "${LOG_FILE}"
}

# log_warn: advertencia (amarillo en terminal)
log_warn() {
    local msg="[WARN]  $(date '+%H:%M:%S') — $*"
    echo -e "${YELLOW}${msg}${RESET}"
    echo "${msg}" >> "${LOG_FILE}"
}

# log_error: error crítico (rojo en terminal)
log_error() {
    local msg="[ERROR] $(date '+%H:%M:%S') — $*"
    echo -e "${RED}${msg}${RESET}" >&2
    echo "${msg}" >> "${LOG_FILE}"
}

# log_step: cabecera de etapa (azul en terminal)
log_step() {
    local msg="[STEP]  $(date '+%H:%M:%S') — $*"
    echo -e "${BLUE}${BOLD}${msg}${RESET}"
    echo "${msg}" >> "${LOG_FILE}"
}

# log_done: confirmación de éxito (cian en terminal)
log_done() {
    local msg="[OK]    $(date '+%H:%M:%S') — $*"
    echo -e "${CYAN}${BOLD}${msg}${RESET}"
    echo "${msg}" >> "${LOG_FILE}"
}

# ==============================================================================
#  SECCIÓN 4: FUNCIÓN DE LIMPIEZA (TRAP)
#  Se ejecuta automáticamente al salir del script, con o sin error.
#  Garantiza que el disco siempre sea desmontado.
# ==============================================================================
cleanup() {
    local exit_code=$?
    echo "" >> "${LOG_FILE}"
    if [[ ${exit_code} -ne 0 ]]; then
        log_error "El script terminó con errores (código: ${exit_code})."
    fi

    # Desmontar el disco si está montado
    if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
        log_step "Desmontando disco externo..."
        if umount "${MOUNT_POINT}"; then
            log_done "Disco desmontado correctamente."
        else
            log_error "No se pudo desmontar ${MOUNT_POINT}. Desmonta manualmente: umount ${MOUNT_POINT}"
        fi
    fi

    {
        echo "======================================================================"
        echo "  FIN BACKUP — $(date '+%Y-%m-%d %H:%M:%S') — Código salida: ${exit_code}"
        echo "======================================================================"
        echo ""
    } >> "${LOG_FILE}"
}

# Registra la función cleanup para que se llame siempre al salir
trap cleanup EXIT

# ==============================================================================
#  SECCIÓN 5: VERIFICACIÓN DE DEPENDENCIAS
# ==============================================================================
check_dependencies() {
    log_step "Verificando dependencias..."
    local missing=()
    local deps=("rsync" "blkid" "mountpoint" "df" "umount" "mount" "find" "sort" "du")

    for cmd in "${deps[@]}"; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing+=("${cmd}")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Dependencias faltantes: ${missing[*]}"
        log_error "Instálalas con: sudo apt install rsync util-linux coreutils findutils"
        exit 1
    fi

    log_done "Todas las dependencias están disponibles."
}

# ==============================================================================
#  SECCIÓN 6: VERIFICACIÓN DE PRIVILEGIOS
# ==============================================================================
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "Este script debe ejecutarse como root (o con sudo)."
        exit 1
    fi
    log_done "Ejecutando como root."
}

# ==============================================================================
#  SECCIÓN 7: DETECCIÓN Y MONTAJE DEL DISCO EXTERNO
# ==============================================================================
mount_disk() {
    log_step "Verificando disco externo con UUID: ${DISK_UUID}..."

    # Busca el dispositivo por UUID
    local device
    device="$(blkid --uuid "${DISK_UUID}" 2>/dev/null || true)"

    if [[ -z "${device}" ]]; then
        log_error "No se encontró ningún dispositivo con UUID: ${DISK_UUID}"
        log_error "Conecta el disco externo y verifica con: blkid"
        exit 1
    fi

    log_info "Dispositivo encontrado: ${device}"

    # Crea el punto de montaje si no existe
    if [[ ! -d "${MOUNT_POINT}" ]]; then
        log_info "Creando punto de montaje: ${MOUNT_POINT}"
        mkdir -p "${MOUNT_POINT}"
    fi

    # Si ya está montado, no vuelve a montarlo
    if mountpoint -q "${MOUNT_POINT}"; then
        log_warn "El disco ya está montado en ${MOUNT_POINT}. Continuando..."
        return 0
    fi

    # Monta el disco
    log_info "Montando ${device} en ${MOUNT_POINT}..."
    if mount UUID="${DISK_UUID}" "${MOUNT_POINT}"; then
        log_done "Disco montado correctamente."
    else
        log_error "Falló el montaje del disco."
        exit 1
    fi
}

# ==============================================================================
#  SECCIÓN 8: VERIFICACIÓN DE ESPACIO DISPONIBLE
# ==============================================================================
check_disk_space() {
    log_step "Verificando espacio disponible en ${MOUNT_POINT}..."

    # Espacio libre en MB usando df (bloques de 1M)
    local free_mb
    free_mb="$(df --block-size=1M --output=avail "${MOUNT_POINT}" | tail -1 | tr -d ' ')"

    log_info "Espacio libre disponible: ${free_mb} MB"
    log_info "Espacio mínimo requerido: ${MIN_FREE_SPACE_MB} MB"

    if [[ "${free_mb}" -lt "${MIN_FREE_SPACE_MB}" ]]; then
        log_error "Espacio insuficiente en el disco externo."
        log_error "Disponible: ${free_mb} MB — Requerido: ${MIN_FREE_SPACE_MB} MB"
        exit 1
    fi

    log_done "Espacio suficiente disponible."
}

# ==============================================================================
#  SECCIÓN 9: POLÍTICA DE RETENCIÓN
#  Elimina el backup más antiguo si ya existen MAX_BACKUPS copias.
# ==============================================================================
apply_retention_policy() {
    log_step "Aplicando política de retención (máximo ${MAX_BACKUPS} copias)..."

    # Lista los directorios de backup ordenados por nombre (fecha YYYY-MM-DD = orden cronológico)
    local backups
    mapfile -t backups < <(find "${BACKUP_ROOT}" -maxdepth 1 -mindepth 1 -type d | sort)

    local count=${#backups[@]}
    log_info "Backups existentes: ${count}"

    # Elimina los más antiguos hasta que queden MAX_BACKUPS - 1 (para dejar espacio al nuevo)
    while [[ "${count}" -ge "${MAX_BACKUPS}" ]]; do
        local oldest="${backups[0]}"
        log_warn "Eliminando backup antiguo: ${oldest}"
        rm -rf "${oldest}"
        log_done "Backup eliminado: ${oldest}"
        # Actualiza la lista
        mapfile -t backups < <(find "${BACKUP_ROOT}" -maxdepth 1 -mindepth 1 -type d | sort)
        count=${#backups[@]}
    done

    log_done "Política de retención aplicada."
}

# ==============================================================================
#  SECCIÓN 10: CONSTRUCCIÓN DE ARGUMENTOS DE EXCLUSIÓN PARA RSYNC
# ==============================================================================
build_exclude_args() {
    EXCLUDE_ARGS=()
    for excl in "${EXCLUDES[@]}"; do
        EXCLUDE_ARGS+=("--exclude=${excl}")
    done
}

# ==============================================================================
#  SECCIÓN 11: EJECUCIÓN DEL BACKUP CON RSYNC
# ==============================================================================
run_backup() {
    log_step "Iniciando backup hacia: ${BACKUP_DIR}"

    # Crea el directorio de destino con la fecha de hoy
    mkdir -p "${BACKUP_DIR}"

    # Combina fuentes principales y extras
    local all_sources=("${BACKUP_SOURCES[@]}" "${EXTRA_SOURCES[@]}")

    # Construye argumentos de exclusión
    build_exclude_args

    for source in "${all_sources[@]}"; do
        if [[ ! -d "${source}" ]]; then
            log_warn "Directorio fuente no existe, omitiendo: ${source}"
            continue
        fi

        log_info "Respaldando: ${source} → ${BACKUP_DIR}${source}"

        # Crea el directorio espejo en destino
        mkdir -p "${BACKUP_DIR}${source}"

        # Ejecuta rsync con las opciones definidas
        # La barra final en "${source}/" copia el CONTENIDO del directorio, no el directorio en sí
        if rsync "${RSYNC_OPTS[@]}" \
                 "${EXCLUDE_ARGS[@]}" \
                 "${source}/" \
                 "${BACKUP_DIR}${source}/" \
                 2>> "${LOG_FILE}"; then
            log_done "Backup completado: ${source}"
        else
            log_error "Rsync falló para: ${source} (código: $?)"
            # No interrumpe — intenta respaldar el siguiente directorio
        fi
    done

    log_done "Proceso de backup finalizado. Destino: ${BACKUP_DIR}"
}

# ==============================================================================
#  SECCIÓN 12: RESUMEN FINAL
# ==============================================================================
print_summary() {
    local backup_size
    backup_size="$(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1 || echo 'desconocido')"

    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║           RESUMEN DEL BACKUP                 ║${RESET}"
    echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════╣${RESET}"
    echo -e "${BOLD}${CYAN}║${RESET} Fecha:      ${BACKUP_DATE}"
    echo -e "${BOLD}${CYAN}║${RESET} Destino:    ${BACKUP_DIR}"
    echo -e "${BOLD}${CYAN}║${RESET} Tamaño:     ${backup_size}"
    echo -e "${BOLD}${CYAN}║${RESET} Log:        ${LOG_FILE}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${RESET}"
    echo ""

    {
        echo "RESUMEN:"
        echo "  Fecha:   ${BACKUP_DATE}"
        echo "  Destino: ${BACKUP_DIR}"
        echo "  Tamaño:  ${backup_size}"
    } >> "${LOG_FILE}"
}

# ==============================================================================
#  SECCIÓN 13: FUNCIÓN PRINCIPAL
# ==============================================================================
main() {
    init_log
    log_step "=== BACKUP DEL SISTEMA INICIADO ==="

    check_root
    check_dependencies
    mount_disk
    check_disk_space

    # Crea el directorio raíz de backups si no existe
    mkdir -p "${BACKUP_ROOT}"

    apply_retention_policy
    run_backup
    print_summary

    log_step "=== BACKUP COMPLETADO EXITOSAMENTE ==="
}

# Punto de entrada
main "$@"
