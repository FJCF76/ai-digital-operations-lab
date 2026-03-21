#!/usr/bin/env bash
set -Eeuo pipefail

#######################################
# OpenClaw + Webinoly Installer
#######################################
#
# USO:
#   sudo ./install-openclaw-webinoly.sh
#
#   El script debe ejecutarse con sudo desde un usuario normal (no root).
#   Ejemplo:
#     chmod +x install-openclaw-webinoly.sh
#     sudo ./install-openclaw-webinoly.sh
#
#   Webinoly y Nginx DEBEN estar instalados previamente.
#   Este script NO instala Webinoly ni Nginx.
#
# VARIABLES DE ENTORNO OPCIONALES:
#   BASIC_AUTH_PASSWORD   — Si se define, se usa sin preguntar por terminal.
#   OPENCLAW_API_KEY      — Requerido solo si OPENCLAW_RUN_ONBOARD=true.
#
# Para habilitar onboarding automático, edita las variables de configuración
# dentro del script antes de ejecutarlo (sección "Variables de configuración").
#
#######################################

#######################################
# Variables de configuración
#######################################

# 👤 Usuario del sistema que será dueño de OpenClaw
TARGET_USER="${SUDO_USER:-}"

# 🌐 Dominio público y upstream local
DOMAIN="app.claw.owncompute.com"
UPSTREAM_HOST="127.0.0.1"
UPSTREAM_PORT="18789"

# 🔐 Basic Auth
BASIC_AUTH_USER="admin"
BASIC_AUTH_PASSWORD="${BASIC_AUTH_PASSWORD:-}"   # vacío = pedir por terminal

# 🦀 OpenClaw
INSTALL_OPENCLAW="true"
OPENCLAW_RUN_ONBOARD="false"

# Opciones para onboarding no interactivo (solo si OPENCLAW_RUN_ONBOARD=true)
OPENCLAW_AUTH_CHOICE="openai-api-key"   # openai-api-key | anthropic-api-key
OPENCLAW_API_KEY="${OPENCLAW_API_KEY:-}"
OPENCLAW_GATEWAY_BIND="loopback"
OPENCLAW_GATEWAY_PORT="18789"
OPENCLAW_INSTALL_DAEMON="true"
OPENCLAW_SKIP_SKILLS="true"

#######################################
# Colores y utilidades
#######################################

GREEN="\033[1;32m"
BLUE="\033[1;34m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
CYAN="\033[1;36m"
MAGENTA="\033[1;35m"
RESET="\033[0m"

step() {
  echo
  echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BLUE}🚀 $*${RESET}"
  echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

info() {
  echo -e "   ${CYAN}→ $*${RESET}"
}

ok() {
  echo -e "   ${GREEN}✅ $*${RESET}"
}

warn() {
  echo -e "   ${YELLOW}⚠️  $*${RESET}"
}

fail() {
  echo -e "\n   ${RED}💀 ERROR: $*${RESET}\n" >&2
  exit 1
}

run_cmd() {
  info "Ejecutando: $*"
  "$@"
}

# Ejecuta un comando como TARGET_USER pasando variables de entorno de forma segura.
# Uso: run_as_target_user "comando" [ENV_VAR=valor ...]
run_as_target_user() {
  local cmd="$1"
  shift
  local env_args=()
  for e in "$@"; do
    env_args+=(env "$e")
  done

  info "Ejecutando como ${TARGET_USER}: ${cmd}"
  if [[ ${#env_args[@]} -gt 0 ]]; then
    sudo -H -u "${TARGET_USER}" "${env_args[@]}" bash -lc "$cmd"
  else
    sudo -H -u "${TARGET_USER}" bash -lc "$cmd"
  fi
}

trap 'fail "El script se detuvo en la línea ${LINENO}. Revisa el mensaje anterior."' ERR

#######################################
# Banner
#######################################

clear || true
echo
echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${MAGENTA}║${RESET}  ${CYAN}🦀 OpenClaw + Webinoly Installer${RESET}                        ${MAGENTA}║${RESET}"
echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════╝${RESET}"
echo
echo -e "   ${GREEN}1${RESET}. Verificar que Webinoly ya esté instalado 🌐"
echo -e "   ${GREEN}2${RESET}. Instalar dependencias necesarias 📦"
echo -e "   ${GREEN}3${RESET}. Instalar OpenClaw 🦀"
echo -e "   ${GREEN}4${RESET}. Crear el sitio proxy en Webinoly 🔁"
echo -e "   ${GREEN}5${RESET}. Activar SSL 🔒"
echo -e "   ${GREEN}6${RESET}. Configurar Basic Auth 🔐"
echo

#######################################
# Comprobaciones iniciales
#######################################

step "Verificando requisitos previos"

[[ $EUID -eq 0 ]] || fail "Este script debe ejecutarse como root o con sudo."
ok "Privilegios de root detectados"

if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
  fail "No pude detectar un usuario normal en SUDO_USER. Ejecuta: sudo ./$(basename "$0") desde tu usuario habitual."
fi

id "${TARGET_USER}" >/dev/null 2>&1 || fail "El usuario TARGET_USER='${TARGET_USER}' no existe."
ok "Usuario del sistema '${TARGET_USER}' listo para la acción"

for cmd in curl systemctl sudo; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "Comando disponible: $cmd"
  else
    warn "No encuentro '$cmd' todavía; se instalará con las dependencias"
  fi
done

#######################################
# Verificar Webinoly y Nginx
#######################################

step "Comprobando que Webinoly esté en casa"

command -v site >/dev/null 2>&1 || fail "No encuentro el comando 'site'. Instala Webinoly primero."
command -v httpauth >/dev/null 2>&1 || fail "No encuentro el comando 'httpauth'. Instala Webinoly primero."
ok "Comandos de Webinoly presentes"

command -v nginx >/dev/null 2>&1 || fail "No encuentro 'nginx'. Webinoly parece incompleto."
ok "Nginx está aquí"

[[ -d /etc/nginx ]] || fail "No existe /etc/nginx. Algo raro pasa con Nginx/Webinoly."
ok "/etc/nginx existe — todo pinta bien"

if ! site >/dev/null 2>&1; then
  fail "El comando 'site' existe pero no responde. Revisa la instalación de Webinoly."
fi
ok "Webinoly responde correctamente"

#######################################
# Password interactiva si no se definió
#######################################

step "Preparando credenciales de Basic Auth"

if [[ -z "${BASIC_AUTH_PASSWORD}" ]]; then
  read -rsp "   🔑 Contraseña para Basic Auth (${BASIC_AUTH_USER}): " BASIC_AUTH_PASSWORD
  echo
  read -rsp "   🔁 Confirma la contraseña: " pw_confirm
  echo
  [[ "${BASIC_AUTH_PASSWORD}" == "${pw_confirm}" ]] || fail "Las contraseñas no coinciden."
  unset pw_confirm
  ok "Contraseña capturada"
else
  ok "Usando contraseña definida en variable de entorno"
fi

[[ -n "${BASIC_AUTH_PASSWORD}" ]] || fail "La contraseña de Basic Auth no puede estar vacía."

#######################################
# Dependencias base
#######################################

step "Instalando dependencias base"

export DEBIAN_FRONTEND=noninteractive
run_cmd apt-get update -y
run_cmd apt-get install -y curl ca-certificates gnupg lsb-release sudo dnsutils

ok "Dependencias base listas 📦"

#######################################
# Instalar OpenClaw
#######################################

if [[ "${INSTALL_OPENCLAW}" == "true" ]]; then
  step "Instalando Node.js (requisito de OpenClaw)"

  if command -v node >/dev/null 2>&1; then
    node_ver=$(node -v 2>/dev/null || echo "desconocida")
    ok "Node.js ya instalado: ${node_ver}"
  else
    info "Instalando Node.js 22.x via NodeSource..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    run_cmd apt-get install -y nodejs
    ok "Node.js instalado: $(node -v)"
  fi

  step "Instalando OpenClaw 🦀"

  # Asegurar que la estructura de directorios npm-global existe
  NPM_GLOBAL_DIR="/home/${TARGET_USER}/.npm-global"
  NPM_GLOBAL_BIN="${NPM_GLOBAL_DIR}/bin"
  sudo -H -u "${TARGET_USER}" mkdir -p "${NPM_GLOBAL_DIR}"/{lib,bin}

  if [[ -x "${NPM_GLOBAL_BIN}/openclaw" ]]; then
    ok "OpenClaw ya está instalado — saltando instalación"
  else
    # Descargar el instalador primero, luego ejecutar (evita ejecución de script truncado)
    local_installer="/tmp/openclaw-install-$$.sh"
    info "Descargando instalador de OpenClaw..."
    curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh -o "${local_installer}"
    chmod 644 "${local_installer}"
    ok "Instalador descargado"

    info "Ejecutando instalador como ${TARGET_USER}..."
    sudo -H -u "${TARGET_USER}" bash "${local_installer}" --no-onboard
    rm -f "${local_installer}"
    ok "OpenClaw instalado"
  fi

  # Añadir npm-global/bin al PATH del usuario si no está ya
  BASHRC="/home/${TARGET_USER}/.bashrc"
  if ! grep -q ".npm-global/bin" "${BASHRC}" 2>/dev/null; then
    info "Añadiendo ${NPM_GLOBAL_BIN} al PATH en .bashrc"
    echo "export PATH=\"${NPM_GLOBAL_BIN}:\$PATH\"" >> "${BASHRC}"
    chown "${TARGET_USER}:${TARGET_USER}" "${BASHRC}"
    ok "PATH actualizado en .bashrc"
  else
    ok "npm-global/bin ya está en .bashrc"
  fi

  # Verificar que el binario existe (usando la ruta explícita porque el PATH del shell actual no lo tiene)
  if [[ -x "${NPM_GLOBAL_BIN}/openclaw" ]]; then
    ok "Binario 'openclaw' verificado en ${NPM_GLOBAL_BIN}"
  else
    fail "OpenClaw se instaló pero el binario no se encuentra en ${NPM_GLOBAL_BIN}."
  fi

  # Linger para que el daemon sobreviva al logout
  if [[ "${OPENCLAW_INSTALL_DAEMON}" == "true" ]]; then
    step "Habilitando linger para ${TARGET_USER}"
    run_cmd loginctl enable-linger "${TARGET_USER}" || fail "No se pudo habilitar linger. El daemon no sobrevivirá al logout de ${TARGET_USER}."
    ok "Linger habilitado — el daemon persistirá"
  fi

  # Onboarding no interactivo
  if [[ "${OPENCLAW_RUN_ONBOARD}" == "true" ]]; then
    step "Ejecutando onboarding de OpenClaw"

    [[ -n "${OPENCLAW_API_KEY}" ]] || fail "OPENCLAW_RUN_ONBOARD=true pero OPENCLAW_API_KEY está vacío."

    # Determinar la variable de entorno correcta para la API key
    api_env_var=""
    case "${OPENCLAW_AUTH_CHOICE}" in
      "anthropic-api-key") api_env_var="ANTHROPIC_API_KEY" ;;
      "openai-api-key")    api_env_var="OPENAI_API_KEY" ;;
      *)                   fail "OPENCLAW_AUTH_CHOICE no soportado: ${OPENCLAW_AUTH_CHOICE}" ;;
    esac

    # Construir flags opcionales
    onboard_flags="--non-interactive --mode local --auth-choice ${OPENCLAW_AUTH_CHOICE} --gateway-port ${OPENCLAW_GATEWAY_PORT} --gateway-bind ${OPENCLAW_GATEWAY_BIND}"
    [[ "${OPENCLAW_INSTALL_DAEMON}" == "true" ]] && onboard_flags+=" --install-daemon"
    [[ "${OPENCLAW_SKIP_SKILLS}" == "true" ]] && onboard_flags+=" --skip-skills"

    # Pasar la API key como variable de entorno (NO interpolada en el string)
    run_as_target_user \
      "export PATH=\"/home/${TARGET_USER}/.npm-global/bin:\$PATH\" && openclaw onboard ${onboard_flags}" \
      "${api_env_var}=${OPENCLAW_API_KEY}"

    ok "Onboarding completado 🎉"
  else
    warn "Onboarding omitido (OPENCLAW_RUN_ONBOARD=false)"
    info "Para configurar manualmente después:"
    echo -e "      ${CYAN}export PATH=\"/home/${TARGET_USER}/.npm-global/bin:\$PATH\"${RESET}"
    echo -e "      ${CYAN}openclaw onboard --install-daemon${RESET}"
  fi
else
  warn "Instalación de OpenClaw omitida (INSTALL_OPENCLAW=false)"
fi

#######################################
# Comprobación de puertos
#######################################

step "Verificando consistencia de puertos"

if [[ "${UPSTREAM_PORT}" != "${OPENCLAW_GATEWAY_PORT}" ]]; then
  warn "UPSTREAM_PORT (${UPSTREAM_PORT}) ≠ OPENCLAW_GATEWAY_PORT (${OPENCLAW_GATEWAY_PORT}) — ¿es intencional?"
else
  ok "Puerto del proxy y de OpenClaw coinciden: ${UPSTREAM_PORT}"
fi

#######################################
# Crear sitio reverse proxy con Webinoly + SSL
#######################################
#
# Para SSL en un reverse proxy, Webinoly usa certbot --manual con hooks
# personalizados. El -root-path indica dónde colocar el challenge file,
# y los hooks de Webinoly modifican nginx temporalmente para servirlo.
#
# El -root-path debe ser un directorio fuera de /var/www/ (como en el
# ejemplo de la documentación: -root-path=/opt/app/web).
#
#######################################

step "Configurando el sitio en Webinoly"

# Comprobar si ya existe como proxy con SSL
if [[ -e "/etc/nginx/sites-enabled/${DOMAIN}" ]]; then
  if grep -q "proxy_pass" "/etc/nginx/sites-enabled/${DOMAIN}" 2>/dev/null && \
     grep -q "ssl_certificate" "/etc/nginx/sites-enabled/${DOMAIN}" 2>/dev/null; then
    ok "El sitio ${DOMAIN} ya existe como proxy con SSL — nada que hacer"
    SKIP_SITE_SETUP="true"
  else
    warn "El sitio ${DOMAIN} existe pero no está completo — eliminando para recrear"
    site "${DOMAIN}" -delete-all
    SKIP_SITE_SETUP="false"
  fi
else
  SKIP_SITE_SETUP="false"
fi

if [[ "${SKIP_SITE_SETUP}" == "false" ]]; then

  #######################################
  # Verificar DNS antes de activar SSL
  #######################################

  step "Verificación de DNS"

  SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "<tu-ip>")

  echo
  echo -e "   ${YELLOW}┌──────────────────────────────────────────────────────┐${RESET}"
  echo -e "   ${YELLOW}│${RESET}  ${CYAN}📋 ACCIÓN REQUERIDA: Crear registro DNS${RESET}              ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}├──────────────────────────────────────────────────────┤${RESET}"
  echo -e "   ${YELLOW}│${RESET}                                                      ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}  Let's Encrypt necesita que el dominio resuelva      ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}  a este servidor para emitir el certificado SSL.     ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}                                                      ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}  Crea este registro en tu panel DNS:                 ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}                                                      ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}    ${GREEN}Tipo:${RESET}   A                                        ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}    ${GREEN}Host:${RESET}   app                                      ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}    ${GREEN}Valor:${RESET}  ${SERVER_IP}$(printf '%*s' $((23 - ${#SERVER_IP})) '')${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}    ${GREEN}TTL:${RESET}    300 (o el mínimo disponible)              ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}                                                      ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}└──────────────────────────────────────────────────────┘${RESET}"
  echo

  # Verificar si el DNS ya resuelve
  info "Comprobando si ${DOMAIN} ya resuelve a ${SERVER_IP}..."
  resolved_ip=$(dig +short A "${DOMAIN}" 2>/dev/null | head -1 || true)

  if [[ "${resolved_ip}" == "${SERVER_IP}" ]]; then
    ok "DNS ya resuelve correctamente: ${DOMAIN} → ${SERVER_IP}"
  else
    if [[ -n "${resolved_ip}" ]]; then
      warn "DNS resuelve a ${resolved_ip} en lugar de ${SERVER_IP}"
    else
      warn "DNS no resuelve aún para ${DOMAIN}"
    fi
    echo
    read -rp "   ⏸️  Pulsa ENTER cuando hayas creado el registro DNS y haya propagado... " _
    echo

    # Re-check
    resolved_ip=$(dig +short A "${DOMAIN}" 2>/dev/null | head -1 || true)
    if [[ "${resolved_ip}" == "${SERVER_IP}" ]]; then
      ok "DNS confirmado: ${DOMAIN} → ${SERVER_IP}"
    else
      warn "DNS aún no resuelve correctamente (${resolved_ip:-sin respuesta}). SSL podría fallar."
      read -rp "   ¿Continuar de todas formas? (s/N): " dns_continue
      [[ "${dns_continue}" =~ ^[sS]$ ]] || fail "Abortado. Configura el DNS y vuelve a ejecutar el script."
    fi
  fi

  #######################################
  # Crear reverse proxy
  #######################################

  step "Creando reverse proxy: ${DOMAIN} → ${UPSTREAM_HOST}:${UPSTREAM_PORT}"

  run_cmd site "${DOMAIN}" "-proxy=[${UPSTREAM_HOST}:${UPSTREAM_PORT}]"
  ok "Sitio proxy creado"

  #######################################
  # Activar SSL con root-path para el ACME challenge
  #######################################

  step "Activando SSL para ${DOMAIN}"

  # Directorio fuera de /var/www/ para el ACME challenge.
  # Los hooks de Webinoly (ex-ssl-authentication / ex-ssl-cleanup)
  # colocan el challenge aquí y modifican nginx temporalmente para servirlo.
  SSL_CHALLENGE_DIR="/opt/openclaw/ssl-challenge"
  mkdir -p "${SSL_CHALLENGE_DIR}"
  chown www-data:www-data "${SSL_CHALLENGE_DIR}"

  run_cmd site "${DOMAIN}" -ssl=on -root-path="${SSL_CHALLENGE_DIR}"
  ok "SSL activado 🔒"

fi

#######################################
# Habilitar WebSocket en el proxy de Nginx
#######################################
#
# Editamos directamente el archivo en apps.d/ porque:
#   - Los headers WebSocket deben estar dentro de location /, no a nivel server.
#   - custom-nginx.conf (la vía oficial de personalización) se incluye a nivel
#     server, así que no sirve para esto.
#   - Según la documentación de Webinoly, los archivos en apps.d/ NO se
#     sobreescriben durante actualizaciones (webinoly -update).
#
# RIESGO: se perderán si ejecutas:
#   - webinoly -server-reset=nginx
#   - site <dominio> -delete seguido de site <dominio> -proxy=[...]
# En ese caso, vuelve a ejecutar este script.
#

step "Configurando WebSocket en el proxy"

PROXY_CONF="/etc/nginx/apps.d/${DOMAIN}-proxy.conf"
if [[ -f "${PROXY_CONF}" ]]; then
  # Descomentar Upgrade header
  if grep -q '#proxy_set_header Upgrade' "${PROXY_CONF}"; then
    sed -i 's|#proxy_set_header Upgrade $http_upgrade;|proxy_set_header Upgrade $http_upgrade;|' "${PROXY_CONF}"
    ok "Header Upgrade habilitado"
  else
    ok "Header Upgrade ya estaba habilitado"
  fi

  # Cambiar Connection de "" a "upgrade"
  if grep -q 'proxy_set_header Connection "";' "${PROXY_CONF}"; then
    sed -i 's|proxy_set_header Connection "";|proxy_set_header Connection "upgrade";|' "${PROXY_CONF}"
    ok "Header Connection cambiado a 'upgrade'"
  else
    ok "Header Connection ya estaba configurado"
  fi
else
  warn "No se encontró ${PROXY_CONF} — configura WebSocket manualmente"
fi

step "Configurando Basic Auth"

# Usar los comandos de Webinoly exclusivamente — no mezclar con htpasswd manual.
# httpauth crea y gestiona su propio .htpasswd.
info "Creando usuario '${BASIC_AUTH_USER}' en ${DOMAIN} vía httpauth"
run_cmd httpauth "${DOMAIN}" "-add=[${BASIC_AUTH_USER},${BASIC_AUTH_PASSWORD}]"
ok "Usuario Basic Auth creado"

info "Protegiendo el sitio completo con Basic Auth"
run_cmd httpauth "${DOMAIN}" -path=/
ok "Basic Auth activado para ${DOMAIN}"

#######################################
# Validación y recarga
#######################################

step "Validando y recargando Nginx"

run_cmd nginx -t
ok "Configuración de Nginx válida"

run_cmd systemctl reload nginx
ok "Nginx recargado"


#######################################
# Resumen final
#######################################

echo
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}║${RESET}  ${CYAN}🎉 ¡Configuración completada con éxito!${RESET}                  ${GREEN}║${RESET}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo
echo -e "   ${BLUE}🌐 Dominio:${RESET}       https://${DOMAIN}"
echo -e "   ${BLUE}🔁 Proxy:${RESET}         https://${DOMAIN} → http://${UPSTREAM_HOST}:${UPSTREAM_PORT}"
echo -e "   ${BLUE}🔐 Basic Auth:${RESET}    ${BASIC_AUTH_USER}"
echo -e "   ${BLUE}🦀 OpenClaw:${RESET}      usuario=${TARGET_USER}  puerto=${OPENCLAW_GATEWAY_PORT}  bind=${OPENCLAW_GATEWAY_BIND}"
echo
echo -e "   ${YELLOW}📝 Pasos siguientes (como ${TARGET_USER}):${RESET}"
echo
echo -e "   ${GREEN}1.${RESET} Ejecutar onboarding de OpenClaw:"
echo -e "      ${CYAN}openclaw onboard --install-daemon${RESET}"
echo
echo -e "   ${GREEN}2.${RESET} Configurar allowed origins para el dashboard:"
echo -e "      ${CYAN}openclaw config set gateway.controlUi.allowedOrigins '[\"https://${DOMAIN}\"]'${RESET}"
echo -e "      ${CYAN}openclaw gateway restart${RESET}"
echo
echo -e "   ${GREEN}3.${RESET} Obtener token del dashboard:"
echo -e "      ${CYAN}openclaw dashboard --no-open${RESET}"
echo
echo -e "   ${GREEN}4.${RESET} Abrir ${CYAN}https://${DOMAIN}${RESET} en el navegador."
echo -e "      Pegar el token y pulsar Conectar."
echo
echo -e "   ${GREEN}5.${RESET} Aprobar el dispositivo desde la terminal:"
echo -e "      ${CYAN}openclaw devices list${RESET}"
echo -e "      ${CYAN}openclaw devices approve <request-id>${RESET}"
echo
echo -e "   ${YELLOW}⚠️  Notas:${RESET}"
echo -e "      • Webinoly gestiona reverse proxy, SSL y Basic Auth."
echo -e "      • OpenClaw escucha solo en ${UPSTREAM_HOST} — no expongas el puerto ${UPSTREAM_PORT}."
echo
echo -e "   ${GREEN}🚀 Todo listo. ¡A pinchar! 🦞${RESET}"
echo
