#!/usr/bin/env bash
# =============================================================================
# OpenClaw VPS Install Wizard
# =============================================================================
# Interactive step-by-step installer for OpenClaw on a clean VPS.
# Idempotent: safe to re-run if a step was already completed.
#
# Steps:
#   1. Install Tailscale + authenticate
#   2. Harden SSH (restrict to Tailscale IP)
#   3. Create a non-root sudo user
#   4. Install OpenClaw
#
# Usage:
#   sudo bash install-wizard.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors & formatting
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

ok()      { echo -e "${GREEN}${BOLD}  ✔  $*${RESET}"; }
info()    { echo -e "${CYAN}  ➜  $*${RESET}"; }
warn()    { echo -e "${YELLOW}  ⚠  $*${RESET}"; }
err()     { echo -e "${RED}${BOLD}  ✖  $*${RESET}" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"; \
            echo -e "${BOLD}${CYAN}  $*${RESET}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"; }
hr()      { echo -e "${CYAN}──────────────────────────────────────────────────${RESET}"; }

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
print_banner() {
  clear
  echo -e "${BOLD}${CYAN}"
  cat << 'EOF'
   ____                  _____ _
  / __ \                / ____| |
 | |  | |_ __   ___ _ | |    | | __ ___      __
 | |  | | '_ \ / _ \ '_ \  / / |/ _` \ \ /\ / /
 | |__| | |_) |  __/ | | |/ /| | (_| |\ V  V /
  \____/| .__/ \___|_| |_/_/ |_|\__,_| \_/\_/
        | |         Installer Wizard
        |_|
EOF
  echo -e "${RESET}"
  echo -e "${BOLD}  Welcome to the OpenClaw VPS Setup Wizard${RESET}"
  echo -e "  This wizard will guide you through a secure, step-by-step"
  echo -e "  installation of OpenClaw on your VPS."
  hr
  echo ""
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Prompt yes/no — default is $2 (y or n). Returns 0 for yes, 1 for no.
confirm() {
  local prompt="$1"
  local default="${2:-y}"
  local yn_label
  if [[ "$default" == "y" ]]; then
    yn_label="[Y/n]"
  else
    yn_label="[y/N]"
  fi

  while true; do
    read -rp "$(echo -e "${YELLOW}  ? ${prompt} ${yn_label}: ${RESET}")" answer
    answer="${answer:-$default}"
    case "$answer" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *)     warn "Please answer y or n." ;;
    esac
  done
}

# Pause and wait for the user to press Enter.
press_enter() {
  read -rp "$(echo -e "${CYAN}  Press [Enter] to continue...${RESET}")"
}

# Check whether a command exists.
has_cmd() { command -v "$1" &>/dev/null; }

# Return the Tailscale IP (100.x.x.x) or empty string.
get_tailscale_ip() {
  tailscale ip -4 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Guard: must run as root
# ---------------------------------------------------------------------------
check_root() {
  if [[ $EUID -ne 0 ]]; then
    err "This wizard must be run as root."
    echo -e "  Try:  ${BOLD}sudo bash $0${RESET}"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# STEP 1 — Install Tailscale
# ---------------------------------------------------------------------------
step_tailscale() {
  step "STEP 1 of 4 — Install & Authenticate Tailscale"

  # Check if already installed and connected.
  if has_cmd tailscale; then
    local ts_ip
    ts_ip="$(get_tailscale_ip)"
    if [[ -n "$ts_ip" ]]; then
      ok "Tailscale is already installed and authenticated (IP: ${ts_ip})."
      TAILSCALE_IP="$ts_ip"
      return 0
    else
      warn "Tailscale is installed but not authenticated yet."
    fi
  else
    info "Tailscale is not installed. Installing now..."
    if ! confirm "Install Tailscale?"; then
      err "Tailscale is required. Aborting."
      exit 1
    fi

    echo ""
    info "Running Tailscale installer..."
    curl -fsSL https://tailscale.com/install.sh | sh
    echo ""
    ok "Tailscale installed."
  fi

  # Bring Tailscale up with SSH enabled.
  info "Starting Tailscale with SSH enabled..."
  echo ""
  info "Running: tailscale up --ssh"
  tailscale up --ssh || true
  echo ""

  echo -e "${YELLOW}  ────────────────────────────────────────────────────${RESET}"
  echo -e "${YELLOW}  ACTION REQUIRED:${RESET}"
  echo -e "  1. Copy the login URL printed above."
  echo -e "  2. Open it in your browser and log in with your Tailscale account."
  echo -e "  3. Authorize this machine in the Tailscale admin console if prompted."
  echo -e "${YELLOW}  ────────────────────────────────────────────────────${RESET}"
  echo ""

  press_enter

  # Wait until the machine gets a Tailscale IP.
  info "Verifying Tailscale authentication..."
  local retries=0
  local max_retries=12   # 12 × 5 s = 60 s timeout
  while true; do
    TAILSCALE_IP="$(get_tailscale_ip)"
    if [[ -n "$TAILSCALE_IP" ]]; then
      break
    fi
    retries=$((retries + 1))
    if [[ $retries -ge $max_retries ]]; then
      err "Tailscale is still not authenticated after 60 seconds."
      err "Please ensure you visited the login URL and approved the device."
      exit 1
    fi
    warn "Not authenticated yet — waiting 5 s... (attempt ${retries}/${max_retries})"
    sleep 5
  done

  echo ""
  tailscale status
  echo ""
  ok "Tailscale authenticated. Your Tailscale IP: ${BOLD}${TAILSCALE_IP}${RESET}"
}

# ---------------------------------------------------------------------------
# STEP 2 — Harden SSH
# ---------------------------------------------------------------------------
step_ssh_hardening() {
  step "STEP 2 of 4 — Harden SSH"

  local sshd_config="/etc/ssh/sshd_config"
  local backup="${sshd_config}.backup-$(date +%Y%m%d-%H%M%S)"

  echo ""
  echo -e "  ${RED}${BOLD}⚠  WARNING — THIS IS THE MOST CRITICAL STEP  ⚠${RESET}"
  echo ""
  echo -e "  ${BOLD}What this step will change in ${sshd_config}:${RESET}"
  echo ""
  echo -e "    ${BOLD}1. ListenAddress${RESET}"
  echo -e "       Before: 0.0.0.0 (anyone on the internet can try to connect)"
  echo -e "       After:  ${GREEN}${TAILSCALE_IP}${RESET} (only reachable via Tailscale)"
  echo ""
  echo -e "    ${BOLD}2. PasswordAuthentication${RESET}"
  echo -e "       Before: yes (passwords accepted)"
  echo -e "       After:  ${GREEN}no${RESET} (SSH keys only)"
  echo ""
  echo -e "    ${BOLD}3. PermitRootLogin${RESET}"
  echo -e "       Before: yes (root can SSH in)"
  echo -e "       After:  ${GREEN}no${RESET} (must use a regular user)"
  echo ""
  hr
  echo -e "  ${RED}${BOLD}RISK: If something goes wrong, you could lose SSH access.${RESET}"
  echo -e "  ${YELLOW}${BOLD}SAFETY NET: Keep this terminal session open. Do NOT close it${RESET}"
  echo -e "  ${YELLOW}${BOLD}until you have verified you can reconnect in a new terminal.${RESET}"
  hr
  echo ""

  # Detect whether SSH is already hardened (idempotency).
  local already_hardened=true
  if ! grep -qE "^ListenAddress\s+${TAILSCALE_IP}" "$sshd_config" 2>/dev/null; then
    already_hardened=false
  fi
  if ! grep -qE "^PasswordAuthentication\s+no" "$sshd_config" 2>/dev/null; then
    already_hardened=false
  fi
  if ! grep -qE "^PermitRootLogin\s+no" "$sshd_config" 2>/dev/null; then
    already_hardened=false
  fi

  if [[ "$already_hardened" == "true" ]]; then
    ok "SSH is already hardened with these settings. Skipping."
    return 0
  fi

  # Show current values so user sees the real "before"
  echo -e "  ${BOLD}Current values in your sshd_config:${RESET}"
  echo -e "    ListenAddress:        $(grep -E '^#?ListenAddress' "$sshd_config" | head -1 || echo '(not set — defaults to 0.0.0.0)')"
  echo -e "    PasswordAuthentication: $(grep -E '^#?PasswordAuthentication' "$sshd_config" | head -1 || echo '(not set — defaults to yes)')"
  echo -e "    PermitRootLogin:      $(grep -E '^#?PermitRootLogin' "$sshd_config" | head -1 || echo '(not set — defaults to yes)')"
  echo ""

  if ! confirm "Do you want to apply these SSH changes? A backup will be created first"; then
    warn "Skipping SSH hardening. Your server remains accessible from the public internet."
    return 0
  fi

  # Backup original config.
  info "Creating backup: ${backup}"
  cp "$sshd_config" "$backup"
  ok "Backup saved: ${backup}"
  echo -e "  ${CYAN}(If anything breaks, restore with: cp ${backup} ${sshd_config})${RESET}"
  echo ""

  # Apply settings — update or append each directive.
  apply_sshd_setting() {
    local key="$1"
    local value="$2"
    if grep -qE "^#?${key}\b" "$sshd_config"; then
      sed -i -E "s|^#?${key}.*|${key} ${value}|" "$sshd_config"
    else
      echo "${key} ${value}" >> "$sshd_config"
    fi
  }

  info "Setting ListenAddress → ${TAILSCALE_IP}"
  apply_sshd_setting "ListenAddress" "$TAILSCALE_IP"

  info "Setting PasswordAuthentication → no"
  apply_sshd_setting "PasswordAuthentication" "no"

  info "Setting PermitRootLogin → no"
  apply_sshd_setting "PermitRootLogin" "no"

  # Show the diff so user sees exactly what changed
  echo ""
  echo -e "  ${BOLD}Changes applied (diff):${RESET}"
  diff --color=always "$backup" "$sshd_config" || true
  echo ""

  # Validate the config before restarting.
  info "Validating new SSH configuration with sshd -t..."
  if ! sshd -t; then
    err "SSH config validation FAILED! Restoring backup automatically..."
    cp "$backup" "$sshd_config"
    ok "Original config restored. Nothing was changed."
    err "Please review ${sshd_config} manually or re-run this wizard."
    exit 1
  fi
  ok "SSH config syntax is valid."
  echo ""

  # Final confirmation before the point of no return
  echo -e "  ${RED}${BOLD}FINAL CONFIRMATION before restarting SSH:${RESET}"
  echo -e "  ${YELLOW}After restart, SSH will ONLY listen on ${TAILSCALE_IP}${RESET}"
  echo -e "  ${YELLOW}Public IP access will be cut off immediately.${RESET}"
  echo ""
  if ! confirm "Restart SSH now? (keep this terminal open as safety net!)"; then
    warn "SSH config was changed but NOT restarted."
    warn "Changes will take effect next time SSH restarts."
    warn "To apply manually: systemctl restart ssh"
    warn "To undo: cp ${backup} ${sshd_config}"
    SSH_BACKUP="$backup"
    return 0
  fi

  # Restart SSH daemon.
  info "Restarting SSH service..."
  if systemctl is-active --quiet sshd 2>/dev/null; then
    systemctl restart sshd
  elif systemctl is-active --quiet ssh 2>/dev/null; then
    systemctl restart ssh
  else
    service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || {
      err "Could not restart SSH service. Restart it manually."
    }
  fi

  echo ""
  ok "SSH restarted successfully."
  echo ""
  echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════${RESET}"
  echo -e "  ${GREEN}${BOLD}  VERIFY NOW — Open a NEW terminal and run:${RESET}"
  echo -e "  ${GREEN}${BOLD}    ssh root@${TAILSCALE_IP}${RESET}"
  echo -e "  ${GREEN}${BOLD}  If it connects, everything is working.${RESET}"
  echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════${RESET}"
  echo ""
  warn "DO NOT close this terminal until you verify the new connection works!"
  echo ""

  if ! confirm "Were you able to connect in a new terminal?"; then
    echo ""
    err "Rolling back SSH changes..."
    cp "$backup" "$sshd_config"
    if systemctl is-active --quiet sshd 2>/dev/null; then
      systemctl restart sshd
    elif systemctl is-active --quiet ssh 2>/dev/null; then
      systemctl restart ssh
    else
      service ssh restart 2>/dev/null || service sshd restart 2>/dev/null
    fi
    ok "SSH config restored to original. You're safe."
    echo ""
    warn "Please check your Tailscale connection and try again."
    exit 1
  fi

  ok "SSH hardening verified and complete!"
  echo ""

  SSH_BACKUP="$backup"
}

# ---------------------------------------------------------------------------
# STEP 3 — Create non-root sudo user
# ---------------------------------------------------------------------------
step_create_user() {
  step "STEP 3 of 4 — Create Non-Root Sudo User"

  echo ""
  echo -e "  ${RED}${BOLD}⚠  THIS STEP IS CRUCIAL FOR YOUR ACCESS  ⚠${RESET}"
  echo ""
  echo -e "  Since we disabled root login in the previous step, you ${BOLD}NEED${RESET}"
  echo -e "  a regular user with sudo to access this server."
  echo ""
  echo -e "  ${BOLD}What this step does:${RESET}"
  echo -e "    1. Creates a new user with the name you choose"
  echo -e "    2. Gives it sudo (admin) privileges"
  echo -e "    3. Copies your SSH keys so you can log in"
  echo -e "    4. ${RED}Verifies the user works BEFORE continuing${RESET}"
  echo ""

  # Ask for username.
  read -rp "$(echo -e "${YELLOW}  ? Username to create [openclaw]: ${RESET}")" NEW_USER
  NEW_USER="${NEW_USER:-openclaw}"

  # Validate username format.
  if ! [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    err "Invalid username '${NEW_USER}'. Use lowercase letters, digits, underscores, hyphens (max 32 chars)."
    exit 1
  fi

  echo ""

  # Check if user already exists.
  if id "$NEW_USER" &>/dev/null; then
    ok "User '${NEW_USER}' already exists. Skipping creation."

    # Ensure the user is in the sudo group.
    if ! groups "$NEW_USER" | grep -qw "sudo"; then
      info "Adding '${NEW_USER}' to sudo group..."
      usermod -aG sudo "$NEW_USER"
      ok "'${NEW_USER}' added to sudo group."
    else
      ok "'${NEW_USER}' is already in the sudo group."
    fi

    CREATED_USER="$NEW_USER"
    return 0
  fi

  echo -e "  ${BOLD}Will create user:${RESET} ${GREEN}${NEW_USER}${RESET}"
  echo -e "  ${BOLD}With privileges:${RESET} sudo (admin)"
  echo ""
  if ! confirm "Create user '${NEW_USER}'?"; then
    warn "Skipping user creation."
    warn "⚠  Without a user, you may not be able to SSH in (root login is disabled)!"
    CREATED_USER=""
    return 0
  fi

  info "Creating user '${NEW_USER}'... You'll be asked to set a password."
  echo ""
  adduser --gecos "" "$NEW_USER"

  info "Adding '${NEW_USER}' to sudo group..."
  usermod -aG sudo "$NEW_USER"

  # Verify sudo group membership
  if ! groups "$NEW_USER" | grep -qw "sudo"; then
    err "Failed to add '${NEW_USER}' to sudo group. This is a problem."
    exit 1
  fi
  ok "User '${NEW_USER}' created and has sudo privileges."

  # Copy authorized_keys from root (if any) so the user can SSH in.
  local root_keys="/root/.ssh/authorized_keys"
  local user_ssh_dir="/home/${NEW_USER}/.ssh"
  if [[ -f "$root_keys" ]]; then
    echo ""
    info "Copying SSH keys from root to ${NEW_USER} so you can log in..."
    mkdir -p "$user_ssh_dir"
    cp "$root_keys" "${user_ssh_dir}/authorized_keys"
    chown -R "${NEW_USER}:${NEW_USER}" "$user_ssh_dir"
    chmod 700 "$user_ssh_dir"
    chmod 600 "${user_ssh_dir}/authorized_keys"
    ok "SSH keys copied to '${NEW_USER}'."
  else
    warn "No SSH keys found for root."
    warn "You will need to set up SSH keys manually for '${NEW_USER}'."
    echo -e "  ${BOLD}  ssh-copy-id ${NEW_USER}@${TAILSCALE_IP}${RESET}"
  fi

  # CRITICAL: Verify the user can actually log in before continuing
  echo ""
  echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════${RESET}"
  echo -e "  ${GREEN}${BOLD}  VERIFY NOW — Open a NEW terminal and run:${RESET}"
  echo -e "  ${GREEN}${BOLD}    ssh ${NEW_USER}@${TAILSCALE_IP}${RESET}"
  echo -e "  ${GREEN}${BOLD}  Then test sudo:${RESET}"
  echo -e "  ${GREEN}${BOLD}    sudo whoami${RESET}"
  echo -e "  ${GREEN}${BOLD}  It should respond: root${RESET}"
  echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════${RESET}"
  echo ""
  warn "DO NOT continue until you verify the user works!"
  echo ""

  if ! confirm "Did you verify that '${NEW_USER}' can SSH in and use sudo?"; then
    echo ""
    warn "User was created but not verified."
    warn "Please test the connection before closing this terminal:"
    echo -e "  ${BOLD}  ssh ${NEW_USER}@${TAILSCALE_IP}${RESET}"
    echo ""
    warn "If it doesn't work, you can still fix things from this terminal."
    press_enter
  else
    ok "User '${NEW_USER}' verified and working!"
  fi

  CREATED_USER="$NEW_USER"
  echo ""
  ok "User setup complete."
}

# ---------------------------------------------------------------------------
# STEP 4 — Install OpenClaw
# ---------------------------------------------------------------------------
step_install_openclaw() {
  step "STEP 4 of 4 — Install OpenClaw"

  echo -e "  OpenClaw will be installed for user '${BOLD}${CREATED_USER:-$(whoami)}${RESET}'."
  echo ""

  # Check if OpenClaw is already installed.
  local oc_bin
  if [[ -n "${CREATED_USER:-}" ]]; then
    oc_bin="$(su - "$CREATED_USER" -c "command -v openclaw 2>/dev/null" || true)"
  else
    oc_bin="$(command -v openclaw 2>/dev/null || true)"
  fi

  if [[ -n "$oc_bin" ]]; then
    ok "OpenClaw is already installed (${oc_bin}). Skipping."
    return 0
  fi

  echo -e "${YELLOW}  ────────────────────────────────────────────────────${RESET}"
  echo -e "${YELLOW}  IMPORTANT — Reconnect before installing OpenClaw${RESET}"
  echo -e "${YELLOW}  ────────────────────────────────────────────────────${RESET}"
  echo ""
  echo -e "  OpenClaw should be installed as the non-root user."
  echo -e "  Please open a ${BOLD}NEW terminal${RESET} and reconnect:"
  echo ""
  echo -e "  ${BOLD}  ssh ${CREATED_USER:-openclaw}@${TAILSCALE_IP}${RESET}"
  echo ""
  echo -e "  Then run:"
  echo -e "  ${BOLD}  curl -fsSL https://openclaw.ai/install.sh | bash${RESET}"
  echo ""

  if confirm "Install OpenClaw now in this session (as root — not recommended)?"; then
    warn "Installing as root. For production use, install as a regular user."
    echo ""
    info "Running OpenClaw installer..."
    curl -fsSL https://openclaw.ai/install.sh | bash
    echo ""
    ok "OpenClaw installer finished."
  else
    info "Skipping automatic install. Run the command above after reconnecting."
    OPENCLAW_MANUAL_INSTALL=true
  fi
}

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
print_summary() {
  echo ""
  step "🎉  Setup Complete — Summary"

  echo -e "  ${BOLD}Tailscale${RESET}"
  echo -e "    IP Address : ${GREEN}${TAILSCALE_IP:-unknown}${RESET}"
  echo ""

  echo -e "  ${BOLD}SSH${RESET}"
  if [[ -n "${SSH_BACKUP:-}" ]]; then
    echo -e "    Hardened   : ${GREEN}Yes${RESET}"
    echo -e "    Backup     : ${CYAN}${SSH_BACKUP}${RESET}"
    echo -e "    ListenAddr : ${GREEN}${TAILSCALE_IP:-unknown}${RESET} (Tailscale only)"
    echo -e "    Password   : ${GREEN}Disabled${RESET}"
    echo -e "    Root login : ${GREEN}Disabled${RESET}"
  else
    echo -e "    Hardened   : ${YELLOW}Skipped / already done${RESET}"
  fi
  echo ""

  echo -e "  ${BOLD}User${RESET}"
  if [[ -n "${CREATED_USER:-}" ]]; then
    echo -e "    Username   : ${GREEN}${CREATED_USER}${RESET}"
    echo -e "    Sudo       : ${GREEN}Yes${RESET}"
  else
    echo -e "    User       : ${YELLOW}Not created / skipped${RESET}"
  fi
  echo ""

  echo -e "  ${BOLD}OpenClaw${RESET}"
  if [[ "${OPENCLAW_MANUAL_INSTALL:-false}" == "true" ]]; then
    echo -e "    Status     : ${YELLOW}Pending manual install${RESET}"
    echo -e "    Next step  :"
    echo ""
    echo -e "    ${BOLD}1. Reconnect:${RESET}"
    echo -e "       ssh ${CREATED_USER:-openclaw}@${TAILSCALE_IP:-<tailscale-ip>}"
    echo ""
    echo -e "    ${BOLD}2. Install OpenClaw:${RESET}"
    echo -e "       curl -fsSL https://openclaw.ai/install.sh | bash"
  else
    echo -e "    Status     : ${GREEN}Installed${RESET}"
  fi

  hr
  echo ""
  echo -e "  ${BOLD}${GREEN}Your VPS is ready!${RESET}"
  echo ""
  if [[ -n "${TAILSCALE_IP:-}" && -n "${CREATED_USER:-}" ]]; then
    echo -e "  Connect via Tailscale:"
    echo -e "  ${BOLD}  ssh ${CREATED_USER}@${TAILSCALE_IP}${RESET}"
    echo ""
  fi
  echo -e "  Need help? → ${CYAN}https://openclaw.ai/docs${RESET}"
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  # Global state variables (populated during each step).
  TAILSCALE_IP=""
  SSH_BACKUP=""
  CREATED_USER=""
  OPENCLAW_MANUAL_INSTALL=false

  print_banner

  check_root

  echo -e "  This wizard will guide you through ${BOLD}4 steps${RESET}:"
  echo -e "    1. Install & authenticate Tailscale"
  echo -e "    2. Harden SSH (restrict to Tailscale network)"
  echo -e "    3. Create a non-root sudo user"
  echo -e "    4. Install OpenClaw"
  echo ""
  echo -e "  ${YELLOW}You will be asked for confirmation before any critical changes.${RESET}"
  echo ""

  if ! confirm "Ready to begin?"; then
    echo ""
    info "Wizard cancelled. Run this script again whenever you're ready."
    exit 0
  fi

  # Run each step.
  step_tailscale
  step_ssh_hardening
  step_create_user
  step_install_openclaw

  print_summary
}

main "$@"
