#!/usr/bin/env bash
set -Eeuo pipefail

#######################################
# OpenClaw + Webinoly Installer
#######################################
#
# USAGE:
#   sudo ./install-openclaw-webinoly.sh
#
#   This script must be run with sudo from a normal user (not root).
#   Example:
#     chmod +x install-openclaw-webinoly.sh
#     sudo ./install-openclaw-webinoly.sh
#
#   Webinoly and Nginx MUST be installed beforehand.
#   This script does NOT install Webinoly or Nginx.
#
# OPTIONAL ENVIRONMENT VARIABLES:
#   DOMAIN               — If set, used without prompting in the terminal.
#   BASIC_AUTH_USER       — If set, used without prompting in the terminal.
#   BASIC_AUTH_PASSWORD   — If set, used without prompting in the terminal.
#   OPENCLAW_API_KEY      — Required only if OPENCLAW_RUN_ONBOARD=true.
#
# To enable automatic onboarding, edit the configuration variables
# inside the script before running it ("Configuration variables" section).
#
#######################################

#######################################
# Configuration variables
#######################################

# 👤 System user who will own OpenClaw
TARGET_USER="${SUDO_USER:-}"

# 🌐 Public domain and local upstream
DOMAIN="${DOMAIN:-}"                               # empty = prompt in terminal
UPSTREAM_HOST="127.0.0.1"
UPSTREAM_PORT="18789"

# 🔐 Basic Auth
BASIC_AUTH_USER="${BASIC_AUTH_USER:-}"              # empty = prompt in terminal
BASIC_AUTH_PASSWORD="${BASIC_AUTH_PASSWORD:-}"      # empty = prompt in terminal

# 🦀 OpenClaw
INSTALL_OPENCLAW="true"
OPENCLAW_RUN_ONBOARD="false"

# Options for non-interactive onboarding (only if OPENCLAW_RUN_ONBOARD=true)
OPENCLAW_AUTH_CHOICE="openai-api-key"   # openai-api-key | anthropic-api-key
OPENCLAW_API_KEY="${OPENCLAW_API_KEY:-}"
OPENCLAW_GATEWAY_BIND="loopback"
OPENCLAW_GATEWAY_PORT="18789"
OPENCLAW_INSTALL_DAEMON="true"
OPENCLAW_SKIP_SKILLS="true"

#######################################
# Colors and utilities
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
  info "Running: $*"
  "$@"
}

# Runs a command as TARGET_USER, passing environment variables securely.
# Usage: run_as_target_user "command" [ENV_VAR=value ...]
run_as_target_user() {
  local cmd="$1"
  shift
  local env_args=()
  for e in "$@"; do
    env_args+=(env "$e")
  done

  info "Running as ${TARGET_USER}: ${cmd}"
  if [[ ${#env_args[@]} -gt 0 ]]; then
    sudo -H -u "${TARGET_USER}" "${env_args[@]}" bash -lc "$cmd"
  else
    sudo -H -u "${TARGET_USER}" bash -lc "$cmd"
  fi
}

trap 'fail "Script stopped at line ${LINENO}. Check the message above."' ERR

#######################################
# Banner
#######################################

clear || true
echo
echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${MAGENTA}║${RESET}  ${CYAN}🦀 OpenClaw + Webinoly Installer${RESET}                        ${MAGENTA}║${RESET}"
echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════╝${RESET}"
echo
echo -e "   ${GREEN}1${RESET}. Verify that Webinoly is already installed 🌐"
echo -e "   ${GREEN}2${RESET}. Install required dependencies 📦"
echo -e "   ${GREEN}3${RESET}. Install OpenClaw 🦀"
echo -e "   ${GREEN}4${RESET}. Create the proxy site in Webinoly 🔁"
echo -e "   ${GREEN}5${RESET}. Enable SSL 🔒"
echo -e "   ${GREEN}6${RESET}. Configure Basic Auth 🔐"
echo

#######################################
# Initial checks
#######################################

step "Checking prerequisites"

[[ $EUID -eq 0 ]] || fail "This script must be run as root or with sudo."
ok "Root privileges detected"

if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
  fail "Could not detect a normal user in SUDO_USER. Run: sudo ./$(basename "$0") from your regular user."
fi

id "${TARGET_USER}" >/dev/null 2>&1 || fail "User TARGET_USER='${TARGET_USER}' does not exist."
ok "System user '${TARGET_USER}' ready to go"

for cmd in curl systemctl sudo; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "Command available: $cmd"
  else
    warn "Cannot find '$cmd' yet; it will be installed with dependencies"
  fi
done

#######################################
# Verify Webinoly and Nginx
#######################################

step "Checking that Webinoly is installed"

command -v site >/dev/null 2>&1 || fail "Cannot find the 'site' command. Install Webinoly first."
command -v httpauth >/dev/null 2>&1 || fail "Cannot find the 'httpauth' command. Install Webinoly first."
ok "Webinoly commands present"

command -v nginx >/dev/null 2>&1 || fail "Cannot find 'nginx'. Webinoly seems incomplete."
ok "Nginx is here"

[[ -d /etc/nginx ]] || fail "/etc/nginx does not exist. Something is wrong with Nginx/Webinoly."
ok "/etc/nginx exists — looking good"

if ! site >/dev/null 2>&1; then
  fail "The 'site' command exists but is not responding. Check your Webinoly installation."
fi
ok "Webinoly is responding correctly"

#######################################
# Interactive prompts for missing values
#######################################

step "Gathering configuration details"

# --- Domain ---
if [[ -z "${DOMAIN}" ]]; then
  echo -e "   ${CYAN}🌐 Where shall the claw reside on the internet?${RESET}"
  echo -e "   ${CYAN}   (e.g. oc.example.com — no https://, just the hostname)${RESET}"
  echo -e "   ${CYAN}   Make sure the DNS A record already points here — SSL won't${RESET}"
  echo -e "   ${CYAN}   negotiate with a domain that ghosts this server. 👻${RESET}"
  read -rp "   🌐 Domain: " DOMAIN
  [[ -n "${DOMAIN}" ]] || fail "A domain is required — the crab needs a home!"
  ok "Domain set: ${DOMAIN}"
else
  ok "Using domain from environment variable: ${DOMAIN}"
fi

# --- Basic Auth user ---
if [[ -z "${BASIC_AUTH_USER}" ]]; then
  echo -e "   ${CYAN}👤 Pick a username for the bouncer at the door (Basic Auth).${RESET}"
  echo -e "   ${CYAN}   Pro tip: 'admin' works, but something memorable is even better.${RESET}"
  read -rp "   👤 Username: " BASIC_AUTH_USER
  [[ -n "${BASIC_AUTH_USER}" ]] || fail "Username cannot be empty — even crabs have names!"
  ok "Username set: ${BASIC_AUTH_USER}"
else
  ok "Using Basic Auth user from environment variable: ${BASIC_AUTH_USER}"
fi

# Validate username (Webinoly/htpasswd restrictions)
if [[ "${BASIC_AUTH_USER}" == *:* ]]; then
  fail "Username cannot contain ':' — htpasswd format restriction."
fi
if [[ "${BASIC_AUTH_USER}" == *,* || "${BASIC_AUTH_USER}" == *]* ]]; then
  fail "Username cannot contain ',' or ']' — Webinoly httpauth parsing limitation."
fi

# --- Basic Auth password ---
if [[ -z "${BASIC_AUTH_PASSWORD}" ]]; then
  echo -e "   ${CYAN}🔑 Now give that bouncer a secret passphrase.${RESET}"
  echo -e "   ${CYAN}   Make it strong — crabs are tough, your password should be too.${RESET}"
  read -rsp "   🔑 Password for '${BASIC_AUTH_USER}': " BASIC_AUTH_PASSWORD
  echo
  read -rsp "   🔁 Type it again (trust issues, sorry): " pw_confirm
  echo
  [[ "${BASIC_AUTH_PASSWORD}" == "${pw_confirm}" ]] || fail "Passwords do not match — the crab is confused."
  unset pw_confirm
  ok "Password captured"
else
  ok "Using password from environment variable"
fi

[[ -n "${BASIC_AUTH_PASSWORD}" ]] || fail "The Basic Auth password cannot be empty."

# Validate password (Webinoly/htpasswd restrictions)
if [[ "${BASIC_AUTH_PASSWORD}" == *:* ]]; then
  fail "Password cannot contain ':' — htpasswd format restriction."
fi
if [[ "${BASIC_AUTH_PASSWORD}" == *,* || "${BASIC_AUTH_PASSWORD}" == *]* ]]; then
  fail "Password cannot contain ',' or ']' — Webinoly httpauth parsing limitation."
fi

#######################################
# Base dependencies
#######################################

step "Installing base dependencies"

export DEBIAN_FRONTEND=noninteractive
run_cmd apt-get update -y
run_cmd apt-get install -y curl ca-certificates gnupg lsb-release sudo dnsutils

ok "Base dependencies ready 📦"

#######################################
# Install OpenClaw
#######################################

if [[ "${INSTALL_OPENCLAW}" == "true" ]]; then
  step "Installing Node.js (OpenClaw requirement)"

  if command -v node >/dev/null 2>&1; then
    node_ver=$(node -v 2>/dev/null || echo "unknown")
    ok "Node.js already installed: ${node_ver}"
  else
    info "Installing Node.js 22.x via NodeSource..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    run_cmd apt-get install -y nodejs
    ok "Node.js installed: $(node -v)"
  fi

  step "Installing OpenClaw 🦀"

  # Ensure the npm-global directory structure exists and npm knows about it
  NPM_GLOBAL_DIR="/home/${TARGET_USER}/.npm-global"
  NPM_GLOBAL_BIN="${NPM_GLOBAL_DIR}/bin"
  sudo -H -u "${TARGET_USER}" mkdir -p "${NPM_GLOBAL_DIR}"/{lib,bin}
  sudo -H -u "${TARGET_USER}" npm config set prefix "${NPM_GLOBAL_DIR}"
  ok "npm global prefix set to ${NPM_GLOBAL_DIR}"

  if [[ -x "${NPM_GLOBAL_BIN}/openclaw" ]]; then
    ok "OpenClaw is already installed — skipping installation"
  else
    # Download the installer first, then run (avoids executing a truncated script)
    local_installer="/tmp/openclaw-install-$$.sh"
    info "Downloading OpenClaw installer..."
    curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh -o "${local_installer}"
    chmod 644 "${local_installer}"
    ok "Installer downloaded"

    info "Running installer as ${TARGET_USER}..."
    sudo -H -u "${TARGET_USER}" bash "${local_installer}" --no-onboard
    rm -f "${local_installer}"
    ok "OpenClaw installed"
  fi

  # Add npm-global/bin to the user's PATH if not already present
  BASHRC="/home/${TARGET_USER}/.bashrc"
  if ! grep -q ".npm-global/bin" "${BASHRC}" 2>/dev/null; then
    info "Adding ${NPM_GLOBAL_BIN} to PATH in .bashrc"
    echo "export PATH=\"${NPM_GLOBAL_BIN}:\$PATH\"" >> "${BASHRC}"
    chown "${TARGET_USER}:${TARGET_USER}" "${BASHRC}"
    ok "PATH updated in .bashrc"
  else
    ok "npm-global/bin is already in .bashrc"
  fi

  # Verify the binary exists (using explicit path because the current shell PATH doesn't have it)
  if [[ -x "${NPM_GLOBAL_BIN}/openclaw" ]]; then
    ok "Binary 'openclaw' verified at ${NPM_GLOBAL_BIN}"
  else
    fail "OpenClaw was installed but the binary was not found at ${NPM_GLOBAL_BIN}."
  fi

  # Linger so the daemon survives logout
  if [[ "${OPENCLAW_INSTALL_DAEMON}" == "true" ]]; then
    step "Enabling linger for ${TARGET_USER}"
    run_cmd loginctl enable-linger "${TARGET_USER}" || fail "Could not enable linger. The daemon will not survive ${TARGET_USER}'s logout."
    ok "Linger enabled — daemon will persist"
  fi

  # Non-interactive onboarding
  if [[ "${OPENCLAW_RUN_ONBOARD}" == "true" ]]; then
    step "Running OpenClaw onboarding"

    [[ -n "${OPENCLAW_API_KEY}" ]] || fail "OPENCLAW_RUN_ONBOARD=true but OPENCLAW_API_KEY is empty."

    # Determine the correct environment variable for the API key
    api_env_var=""
    case "${OPENCLAW_AUTH_CHOICE}" in
      "anthropic-api-key") api_env_var="ANTHROPIC_API_KEY" ;;
      "openai-api-key")    api_env_var="OPENAI_API_KEY" ;;
      *)                   fail "Unsupported OPENCLAW_AUTH_CHOICE: ${OPENCLAW_AUTH_CHOICE}" ;;
    esac

    # Build optional flags
    onboard_flags="--non-interactive --mode local --auth-choice ${OPENCLAW_AUTH_CHOICE} --gateway-port ${OPENCLAW_GATEWAY_PORT} --gateway-bind ${OPENCLAW_GATEWAY_BIND}"
    [[ "${OPENCLAW_INSTALL_DAEMON}" == "true" ]] && onboard_flags+=" --install-daemon"
    [[ "${OPENCLAW_SKIP_SKILLS}" == "true" ]] && onboard_flags+=" --skip-skills"

    # Pass the API key as an environment variable (NOT interpolated in the string)
    run_as_target_user \
      "export PATH=\"/home/${TARGET_USER}/.npm-global/bin:\$PATH\" && openclaw onboard ${onboard_flags}" \
      "${api_env_var}=${OPENCLAW_API_KEY}"

    ok "Onboarding completed 🎉"
  else
    warn "Onboarding skipped (OPENCLAW_RUN_ONBOARD=false)"
    info "To configure manually later:"
    echo -e "      ${CYAN}export PATH=\"/home/${TARGET_USER}/.npm-global/bin:\$PATH\"${RESET}"
    echo -e "      ${CYAN}openclaw onboard --install-daemon${RESET}"
  fi
else
  warn "OpenClaw installation skipped (INSTALL_OPENCLAW=false)"
fi

#######################################
# Port consistency check
#######################################

step "Checking port consistency"

if [[ "${UPSTREAM_PORT}" != "${OPENCLAW_GATEWAY_PORT}" ]]; then
  warn "UPSTREAM_PORT (${UPSTREAM_PORT}) ≠ OPENCLAW_GATEWAY_PORT (${OPENCLAW_GATEWAY_PORT}) — is this intentional?"
else
  ok "Proxy and OpenClaw ports match: ${UPSTREAM_PORT}"
fi

#######################################
# Create reverse proxy site with Webinoly + SSL
#######################################
#
# For SSL on a reverse proxy, Webinoly uses certbot --manual with custom
# hooks. The -root-path indicates where to place the challenge file,
# and the Webinoly hooks temporarily modify nginx to serve it.
#
# The -root-path must be a directory outside /var/www/ (as in the
# documentation example: -root-path=/opt/app/web).
#
#######################################

step "Configuring the site in Webinoly"

# Check if it already exists as a proxy with SSL
if [[ -e "/etc/nginx/sites-enabled/${DOMAIN}" ]]; then
  if grep -q "proxy_pass" "/etc/nginx/sites-enabled/${DOMAIN}" 2>/dev/null && \
     grep -q "ssl_certificate" "/etc/nginx/sites-enabled/${DOMAIN}" 2>/dev/null; then
    ok "Site ${DOMAIN} already exists as a proxy with SSL — nothing to do"
    SKIP_SITE_SETUP="true"
  else
    warn "Site ${DOMAIN} exists but is incomplete — removing to recreate"
    site "${DOMAIN}" -delete-all
    SKIP_SITE_SETUP="false"
  fi
else
  SKIP_SITE_SETUP="false"
fi

if [[ "${SKIP_SITE_SETUP}" == "false" ]]; then

  #######################################
  # Verify DNS before enabling SSL
  #######################################

  step "DNS verification"

  SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "<your-ip>")

  echo
  echo -e "   ${YELLOW}┌──────────────────────────────────────────────────────┐${RESET}"
  echo -e "   ${YELLOW}│${RESET}  ${CYAN}📋 ACTION REQUIRED: Create DNS record${RESET}               ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}├──────────────────────────────────────────────────────┤${RESET}"
  echo -e "   ${YELLOW}│${RESET}                                                      ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}  Let's Encrypt requires the domain to resolve        ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}  to this server to issue the SSL certificate.        ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}                                                      ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}  Create this record in your DNS panel:               ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}                                                      ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}    ${GREEN}Type:${RESET}   A                                        ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}    ${GREEN}Name:${RESET}   ${DOMAIN}$(printf '%*s' $((39 - ${#DOMAIN})) '')${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}    ${GREEN}Value:${RESET}  ${SERVER_IP}$(printf '%*s' $((23 - ${#SERVER_IP})) '')${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}    ${GREEN}TTL:${RESET}    300 (or the minimum available)            ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}│${RESET}                                                      ${YELLOW}│${RESET}"
  echo -e "   ${YELLOW}└──────────────────────────────────────────────────────┘${RESET}"
  echo

  # Check if DNS already resolves
  info "Checking if ${DOMAIN} already resolves to ${SERVER_IP}..."
  resolved_ip=$(dig +short A "${DOMAIN}" 2>/dev/null | head -1 || true)

  if [[ "${resolved_ip}" == "${SERVER_IP}" ]]; then
    ok "DNS already resolves correctly: ${DOMAIN} → ${SERVER_IP}"
  else
    if [[ -n "${resolved_ip}" ]]; then
      warn "DNS resolves to ${resolved_ip} instead of ${SERVER_IP}"
    else
      warn "DNS does not resolve yet for ${DOMAIN}"
    fi
    echo
    read -rp "   ⏸️  Press ENTER once you have created the DNS record and it has propagated... " _
    echo

    # Re-check
    resolved_ip=$(dig +short A "${DOMAIN}" 2>/dev/null | head -1 || true)
    if [[ "${resolved_ip}" == "${SERVER_IP}" ]]; then
      ok "DNS confirmed: ${DOMAIN} → ${SERVER_IP}"
    else
      warn "DNS still does not resolve correctly (${resolved_ip:-no response}). SSL may fail."
      read -rp "   Continue anyway? (y/N): " dns_continue
      [[ "${dns_continue}" =~ ^[yY]$ ]] || fail "Aborted. Configure DNS and re-run the script."
    fi
  fi

  #######################################
  # Create reverse proxy
  #######################################

  step "Creating reverse proxy: ${DOMAIN} → ${UPSTREAM_HOST}:${UPSTREAM_PORT}"

  run_cmd site "${DOMAIN}" "-proxy=[${UPSTREAM_HOST}:${UPSTREAM_PORT}]"
  ok "Proxy site created"

  #######################################
  # Enable SSL with root-path for the ACME challenge
  #######################################

  step "Enabling SSL for ${DOMAIN}"

  # Directory outside /var/www/ for the ACME challenge.
  # Webinoly hooks (ex-ssl-authentication / ex-ssl-cleanup)
  # place the challenge here and temporarily modify nginx to serve it.
  SSL_CHALLENGE_DIR="/opt/openclaw/ssl-challenge"
  mkdir -p "${SSL_CHALLENGE_DIR}"
  chown www-data:www-data "${SSL_CHALLENGE_DIR}"

  run_cmd site "${DOMAIN}" -ssl=on -root-path="${SSL_CHALLENGE_DIR}"
  ok "SSL enabled 🔒"

fi

#######################################
# Enable WebSocket on the Nginx proxy
#######################################
#
# We edit the file in apps.d/ directly because:
#   - WebSocket headers must be inside location /, not at the server level.
#   - custom-nginx.conf (the official customization path) is included at the
#     server level, so it doesn't work for this.
#   - According to Webinoly documentation, files in apps.d/ are NOT
#     overwritten during updates (webinoly -update).
#
# RISK: these changes will be lost if you run:
#   - webinoly -server-reset=nginx
#   - site <domain> -delete followed by site <domain> -proxy=[...]
# In that case, re-run this script.
#

step "Configuring WebSocket on the proxy"

PROXY_CONF="/etc/nginx/apps.d/${DOMAIN}-proxy.conf"
if [[ -f "${PROXY_CONF}" ]]; then
  # Uncomment Upgrade header
  if grep -q '#proxy_set_header Upgrade' "${PROXY_CONF}"; then
    sed -i 's|#proxy_set_header Upgrade $http_upgrade;|proxy_set_header Upgrade $http_upgrade;|' "${PROXY_CONF}"
    ok "Upgrade header enabled"
  else
    ok "Upgrade header was already enabled"
  fi

  # Change Connection from "" to "upgrade"
  if grep -q 'proxy_set_header Connection "";' "${PROXY_CONF}"; then
    sed -i 's|proxy_set_header Connection "";|proxy_set_header Connection "upgrade";|' "${PROXY_CONF}"
    ok "Connection header changed to 'upgrade'"
  else
    ok "Connection header was already configured"
  fi
else
  warn "${PROXY_CONF} not found — configure WebSocket manually"
fi

step "Configuring Basic Auth"

# Use Webinoly commands exclusively — do not mix with manual htpasswd.
# httpauth creates and manages its own .htpasswd.
info "Creating user '${BASIC_AUTH_USER}' on ${DOMAIN} via httpauth"
run_cmd httpauth "${DOMAIN}" "-add=[${BASIC_AUTH_USER},${BASIC_AUTH_PASSWORD}]"
ok "Basic Auth user created"

info "Protecting the entire site with Basic Auth"
run_cmd httpauth "${DOMAIN}" -path=/
ok "Basic Auth enabled for ${DOMAIN}"

#######################################
# Validation and reload
#######################################

step "Validating and reloading Nginx"

run_cmd nginx -t
ok "Nginx configuration is valid"

run_cmd systemctl reload nginx
ok "Nginx reloaded"


#######################################
# Final summary
#######################################

echo
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}║${RESET}  ${CYAN}🎉 Configuration completed successfully!${RESET}                  ${GREEN}║${RESET}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo
echo -e "   ${BLUE}🌐 Domain:${RESET}        https://${DOMAIN}"
echo -e "   ${BLUE}🔁 Proxy:${RESET}         https://${DOMAIN} → http://${UPSTREAM_HOST}:${UPSTREAM_PORT}"
echo -e "   ${BLUE}🔐 Basic Auth:${RESET}    ${BASIC_AUTH_USER}"
echo -e "   ${BLUE}🦀 OpenClaw:${RESET}      user=${TARGET_USER}  port=${OPENCLAW_GATEWAY_PORT}  bind=${OPENCLAW_GATEWAY_BIND}"
echo
echo -e "   ${YELLOW}📝 Next steps (as ${TARGET_USER}):${RESET}"
echo
echo -e "   ${GREEN}1.${RESET} Run OpenClaw onboarding:"
echo -e "      ${CYAN}openclaw onboard --install-daemon${RESET}"
echo
echo -e "   ${GREEN}2.${RESET} Configure allowed origins for the dashboard:"
echo -e "      ${CYAN}openclaw config set gateway.controlUi.allowedOrigins '[\"https://${DOMAIN}\"]'${RESET}"
echo -e "      ${CYAN}openclaw gateway restart${RESET}"
echo
echo -e "   ${GREEN}3.${RESET} Get the dashboard token:"
echo -e "      ${CYAN}openclaw dashboard --no-open${RESET}"
echo
echo -e "   ${GREEN}4.${RESET} Open ${CYAN}https://${DOMAIN}${RESET} in the browser."
echo -e "      Paste the token and click Connect."
echo
echo -e "   ${GREEN}5.${RESET} Approve the device from the terminal:"
echo -e "      ${CYAN}openclaw devices list${RESET}"
echo -e "      ${CYAN}openclaw devices approve <request-id>${RESET}"
echo
echo -e "   ${YELLOW}⚠️  Notes:${RESET}"
echo -e "      • Webinoly manages the reverse proxy, SSL, and Basic Auth."
echo -e "      • OpenClaw listens only on ${UPSTREAM_HOST} — do not expose port ${UPSTREAM_PORT}."
echo
echo -e "   ${GREEN}🚀 All set. Let's go! 🦞${RESET}"
echo
