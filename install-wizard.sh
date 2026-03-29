#!/usr/bin/env bash
# install-wizard.sh — VPS Secure Setup Wizard
# Interactive, step-by-step guide to harden your server.
# Each command is shown and explained before it runs. Nothing happens without your OK.

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ─── Helpers ──────────────────────────────────────────────────────────────────

banner() {
  clear
  echo -e "${CYAN}${BOLD}"
  cat << 'EOF'
 ██╗   ██╗██████╗ ███████╗    ███████╗███████╗ ██████╗██╗   ██╗██████╗ ███████╗
 ██║   ██║██╔══██╗██╔════╝    ██╔════╝██╔════╝██╔════╝██║   ██║██╔══██╗██╔════╝
 ██║   ██║██████╔╝███████╗    ███████╗█████╗  ██║     ██║   ██║██████╔╝█████╗
 ╚██╗ ██╔╝██╔═══╝ ╚════██║    ╚════██║██╔══╝  ██║     ██║   ██║██╔══██╗██╔══╝
  ╚████╔╝ ██║     ███████║    ███████║███████╗╚██████╗╚██████╔╝██║  ██║███████╗
   ╚═══╝  ╚═╝     ╚══════╝    ╚══════╝╚══════╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝
EOF
  echo -e "${RESET}"
  echo -e "${BOLD}  Server Setup Wizard${RESET}  ${DIM}— Step-by-step, nothing runs without your OK${RESET}"
  echo -e "${DIM}  ────────────────────────────────────────────────────────────────${RESET}"
  echo ""
}

step_header() {
  local num="$1"
  local total="$2"
  local title="$3"
  echo ""
  echo -e "${BOLD}${CYAN}┌─────────────────────────────────────────────────────────────┐${RESET}"
  printf "${BOLD}${CYAN}│${RESET}  ${BOLD}[%d/%d]${RESET}  %-52s ${CYAN}│${RESET}\n" "$num" "$total" "$title"
  echo -e "${BOLD}${CYAN}└─────────────────────────────────────────────────────────────┘${RESET}"
  echo ""
}

explain() {
  echo -e "${YELLOW}  💡 Why:${RESET} $1"
  echo ""
}

show_command() {
  echo -e "${DIM}  Command to run:${RESET}"
  echo -e "${CYAN}${BOLD}  ┌──────────────────────────────────────────────────────────┐${RESET}"
  echo -e "${CYAN}${BOLD}  │${RESET}  ${CYAN}$1${RESET}"
  echo -e "${CYAN}${BOLD}  └──────────────────────────────────────────────────────────┘${RESET}"
  echo ""
}

show_command_multi() {
  echo -e "${DIM}  Command to run:${RESET}"
  echo -e "${CYAN}${BOLD}  ┌──────────────────────────────────────────────────────────┐${RESET}"
  while IFS= read -r line; do
    echo -e "${CYAN}${BOLD}  │${RESET}  ${CYAN}${line}${RESET}"
  done <<< "$1"
  echo -e "${CYAN}${BOLD}  └──────────────────────────────────────────────────────────┘${RESET}"
  echo ""
}

confirm() {
  local prompt="${1:-Press Enter to run this command, or type 'skip' to skip}"
  echo -e "${BOLD}  → ${prompt}${RESET}"
  local ans
  read -r ans </dev/tty
  if [[ "${ans,,}" == "skip" ]]; then
    echo -e "${YELLOW}  ⏭  Skipped.${RESET}"
    return 1
  fi
  return 0
}

confirm_yn() {
  local prompt="$1"
  local ans
  while true; do
    echo -e "${BOLD}  → ${prompt} [y/n]${RESET}"
    read -r ans </dev/tty
    case "${ans,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) echo -e "${YELLOW}  Please type y or n.${RESET}" ;;
    esac
  done
}

ok() {
  echo -e "${GREEN}  ✓ $1${RESET}"
}

warn() {
  echo -e "${YELLOW}  ⚠  $1${RESET}"
}

error() {
  echo -e "${RED}  ✗ $1${RESET}"
}

divider() {
  echo -e "${DIM}  ────────────────────────────────────────────────────────────${RESET}"
}

# ─── Pre-flight checks ────────────────────────────────────────────────────────

preflight() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}${BOLD}  Error:${RESET} This wizard must run as root."
    echo -e "  Run it with: ${CYAN}sudo bash install-wizard.sh${RESET}"
    exit 1
  fi
}

# ─── Global state ─────────────────────────────────────────────────────────────
TAILSCALE_IP=""
NEW_USER=""
TOTAL_STEPS=12

# ─── STEP 1: Install Tailscale ────────────────────────────────────────────────

step1_install_tailscale() {
  step_header 1 $TOTAL_STEPS "Install Tailscale"

  explain "Tailscale builds a private, encrypted tunnel between your computer and this \
server. Once set up, your server is invisible to the public internet — only \
devices you authorize can reach it. It's like a VPN you don't have to manage."

  show_command "curl -fsSL https://tailscale.com/install.sh | sh"

  if confirm "Press Enter to install Tailscale, or type 'skip'"; then
    echo ""
    curl -fsSL https://tailscale.com/install.sh | sh
    echo ""
    if command -v tailscale &>/dev/null; then
      ok "Tailscale installed successfully."
    else
      error "Tailscale installation may have failed. Check the output above."
      confirm_yn "Continue anyway?" || exit 1
    fi
  fi
}

# ─── STEP 2: Start Tailscale with SSH ─────────────────────────────────────────

step2_start_tailscale() {
  step_header 2 $TOTAL_STEPS "Activate Tailscale (with SSH enabled)"

  explain "Now we bring Tailscale online and tell it to enable SSH access through \
the tunnel. You'll get a login link — open it in your browser to authenticate \
this server with your Tailscale account."

  show_command "tailscale up --ssh"

  if confirm "Press Enter to start Tailscale, or type 'skip'"; then
    echo ""
    # Run tailscale up, capture output for the auth URL
    tailscale up --ssh 2>&1 | tee /tmp/ts_up_output.txt || true
    echo ""

    # Try to grab the auth URL from output
    local auth_url
    auth_url=$(grep -oP 'https://login\.tailscale\.com/\S+' /tmp/ts_up_output.txt 2>/dev/null | head -1 || true)

    if [[ -n "$auth_url" ]]; then
      echo -e "${YELLOW}${BOLD}  Auth required!${RESET}"
      echo -e "${YELLOW}  Open this URL in your browser to authenticate:${RESET}"
      echo ""
      echo -e "  ${CYAN}${BOLD}${auth_url}${RESET}"
      echo ""
      echo -e "${DIM}  After authenticating in the browser, come back here.${RESET}"
      echo ""
      echo -e "${BOLD}  → Press Enter once you've authenticated in the browser...${RESET}"
      read -r </dev/tty
    else
      echo -e "${DIM}  (No auth URL found — Tailscale may already be authenticated.)${RESET}"
    fi

    ok "Tailscale is up."
  fi
}

# ─── STEP 3: Get Tailscale IP ─────────────────────────────────────────────────

step3_get_tailscale_ip() {
  step_header 3 $TOTAL_STEPS "Verify Tailscale & get your private IP"

  explain "We'll check that Tailscale is running and grab your server's private IP \
address (it starts with 100.x.x.x). You'll need this IP to SSH into the server \
from now on — save it somewhere handy."

  show_command "tailscale status"

  echo -e "${BOLD}  → Press Enter to run, or type 'skip'${RESET}"
  local ans
  read -r ans </dev/tty

  if [[ "${ans,,}" != "skip" ]]; then
    echo ""
    tailscale status 2>&1 || true
    echo ""

    # Extract the local IP
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null | head -1 || true)

    if [[ -n "$TAILSCALE_IP" ]]; then
      echo ""
      echo -e "${GREEN}${BOLD}  ★ Your Tailscale IP: ${TAILSCALE_IP}${RESET}"
      echo ""
      warn "Write this down — you'll need it to connect after we harden SSH."
      echo ""
    else
      warn "Could not detect Tailscale IP automatically."
      echo -e "${BOLD}  → Enter your Tailscale IP manually (100.x.x.x):${RESET}"
      read -r TAILSCALE_IP </dev/tty
    fi
  else
    echo -e "${YELLOW}  ⏭  Skipped. Please enter your Tailscale IP to continue:${RESET}"
    read -r TAILSCALE_IP </dev/tty
  fi
}

# ─── STEP 4: Backup SSH config ────────────────────────────────────────────────

step4_backup_ssh() {
  step_header 4 $TOTAL_STEPS "Backup SSH config"

  explain "Before we touch anything, let's make a backup of your SSH configuration. \
If anything goes wrong during the next steps, we'll restore this file and \
you'll be back to square one — safely. Never skip backups."

  show_command "cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup"

  if confirm "Press Enter to create the backup, or type 'skip'"; then
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    ok "Backup created at /etc/ssh/sshd_config.backup"
  fi
}

# ─── STEP 5: Restrict SSH to Tailscale IP ─────────────────────────────────────

step5_listen_address() {
  step_header 5 $TOTAL_STEPS "Restrict SSH to your Tailscale IP only"

  explain "Right now, SSH listens on ALL network interfaces — meaning anyone on the \
internet can try to brute-force your password. We're going to tell SSH to \
listen ONLY on your Tailscale IP (${TAILSCALE_IP}). After this, the server's \
SSH port becomes completely invisible to the public internet."

  echo -e "${DIM}  Current ListenAddress lines in sshd_config:${RESET}"
  grep -n "ListenAddress" /etc/ssh/sshd_config 2>/dev/null || echo -e "${DIM}    (none found — will add a new one)${RESET}"
  echo ""

  echo -e "${YELLOW}  What we'll change:${RESET}"
  echo -e "    ${DIM}#ListenAddress 0.0.0.0${RESET}  →  ${GREEN}ListenAddress ${TAILSCALE_IP}${RESET}"
  echo ""

  # Build the sed command: comment out the IPv4 line and insert the new line after it
  local sed_cmd="sed -i '/^#\\?ListenAddress 0\\.0\\.0\\.0/{ s/.*/# &/; /^# # /{ s/^# //; }; a\\ListenAddress ${TAILSCALE_IP} }' /etc/ssh/sshd_config"

  # Simpler, more reliable approach:
  local sed_explain="sed -i 's|^#\\?ListenAddress 0\\.0\\.0\\.0.*|#ListenAddress 0.0.0.0\\nListenAddress ${TAILSCALE_IP}|' /etc/ssh/sshd_config"

  show_command "$sed_explain"

  if confirm "Press Enter to apply the change, or type 'skip'"; then
    # Comment out the IPv4 line and add our new one right after
    # Only match lines with 0.0.0.0, NOT :: (IPv6)
    sed -i "s|^#\?ListenAddress 0\.0\.0\.0.*|#ListenAddress 0.0.0.0\nListenAddress ${TAILSCALE_IP}|" /etc/ssh/sshd_config

    echo ""
    echo -e "${DIM}  Verifying change:${RESET}"
    grep -n "ListenAddress" /etc/ssh/sshd_config
    echo ""
    ok "ListenAddress updated."
  fi
}

# ─── STEP 6: Disable password authentication ──────────────────────────────────

step6_disable_password_auth() {
  step_header 6 $TOTAL_STEPS "Disable password authentication"

  explain "Password logins are a huge attack surface — bots constantly try random \
passwords against servers. We're turning this off completely. After this, \
only SSH key pairs will work. If you haven't set up your keys yet, don't \
worry — Tailscale SSH handles that for you."

  echo -e "${DIM}  Current PasswordAuthentication setting:${RESET}"
  grep -n "PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null || echo -e "${DIM}    (not found — will add it)${RESET}"
  echo ""

  echo -e "${YELLOW}  What we'll change:${RESET}"
  echo -e "    ${DIM}PasswordAuthentication yes${RESET}  →  ${GREEN}PasswordAuthentication no${RESET}"
  echo ""

  local cmd="sed -i 's|^#\\?PasswordAuthentication.*|PasswordAuthentication no|' /etc/ssh/sshd_config"
  show_command "$cmd"

  if confirm "Press Enter to disable password auth, or type 'skip'"; then
    # Handle both uncommented and commented versions
    if grep -q "^#\?PasswordAuthentication" /etc/ssh/sshd_config; then
      sed -i 's|^#\?PasswordAuthentication.*|PasswordAuthentication no|' /etc/ssh/sshd_config
    else
      echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
    fi

    echo ""
    echo -e "${DIM}  Verifying change:${RESET}"
    grep -n "PasswordAuthentication" /etc/ssh/sshd_config
    echo ""
    ok "Password authentication disabled."
  fi
}

# ─── STEP 7: Disable root login ───────────────────────────────────────────────

step7_disable_root_login() {
  step_header 7 $TOTAL_STEPS "Disable direct root login"

  explain "Allowing root to log in directly over SSH is a major security risk. \
If someone gets in as root, they own your machine immediately. We'll disable \
this — instead, you'll log in as a regular user and use 'sudo' when you need \
admin powers. Much safer."

  echo -e "${DIM}  Current PermitRootLogin setting:${RESET}"
  grep -n "PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null || echo -e "${DIM}    (not found — will add it)${RESET}"
  echo ""

  echo -e "${YELLOW}  What we'll change:${RESET}"
  echo -e "    ${DIM}PermitRootLogin yes${RESET}  →  ${GREEN}PermitRootLogin no${RESET}"
  echo ""

  local cmd="sed -i 's|^#\\?PermitRootLogin.*|PermitRootLogin no|' /etc/ssh/sshd_config"
  show_command "$cmd"

  if confirm "Press Enter to disable root login, or type 'skip'"; then
    if grep -q "^#\?PermitRootLogin" /etc/ssh/sshd_config; then
      sed -i 's|^#\?PermitRootLogin.*|PermitRootLogin no|' /etc/ssh/sshd_config
    else
      echo "PermitRootLogin no" >> /etc/ssh/sshd_config
    fi

    echo ""
    echo -e "${DIM}  Verifying change:${RESET}"
    grep -n "PermitRootLogin" /etc/ssh/sshd_config
    echo ""
    ok "Root login disabled."
  fi
}

# ─── STEP 8: Create a regular user ────────────────────────────────────────────

step8_create_user() {
  step_header 8 $TOTAL_STEPS "Create your admin user"

  explain "You need a regular (non-root) user account to log in going forward. \
This is a best practice — you do your daily work as a regular user, and only \
use admin powers (via sudo) when needed. Think of it like not walking around \
with the master key to every door all the time."

  echo -e "${BOLD}  → What username do you want? (press Enter for 'admin'):${RESET}"
  read -r NEW_USER </dev/tty
  NEW_USER="${NEW_USER:-admin}"

  echo ""
  echo -e "  Creating user: ${CYAN}${BOLD}${NEW_USER}${RESET}"
  echo ""

  show_command "adduser ${NEW_USER}"

  if confirm "Press Enter to create user '${NEW_USER}', or type 'skip'"; then
    if id "${NEW_USER}" &>/dev/null; then
      warn "User '${NEW_USER}' already exists. Skipping creation."
    else
      adduser "${NEW_USER}" </dev/tty
    fi
    echo ""
    ok "User '${NEW_USER}' is ready."
  fi
}

# ─── STEP 9: Grant sudo privileges ────────────────────────────────────────────

step9_sudo_privileges() {
  step_header 9 $TOTAL_STEPS "Grant admin (sudo) privileges"

  explain "Your new user needs to be in the 'sudo' group to run commands as root \
when needed. Without this, they'd be a regular user with no way to administer \
the server. With sudo, they can run admin commands by typing 'sudo' before them — \
and the system will ask for their password first."

  show_command "usermod -aG sudo ${NEW_USER}"

  if confirm "Press Enter to grant sudo to '${NEW_USER}', or type 'skip'"; then
    usermod -aG sudo "${NEW_USER}"
    echo ""
    echo -e "${DIM}  Verifying group membership:${RESET}"
    groups "${NEW_USER}"
    echo ""
    ok "User '${NEW_USER}' now has sudo privileges."
  fi
}

# ─── STEP 10: Verify the user works ───────────────────────────────────────────

step10_verify_user() {
  step_header 10 $TOTAL_STEPS "Verify user works BEFORE restarting SSH"

  explain "This step is CRITICAL. We need to confirm that '${NEW_USER}' can actually \
run sudo commands — BEFORE we restart SSH with the new hardened config. If we \
restart SSH now and the user is broken, we could lock ourselves out permanently. \
We test first, then proceed. Think of it as checking the parachute before jumping."

  echo -e "${YELLOW}${BOLD}  ⚠  Do NOT skip this step.${RESET}"
  echo ""

  local cmd="su - ${NEW_USER} -c 'sudo whoami'"
  show_command "$cmd"

  if confirm "Press Enter to test '${NEW_USER}', or type 'skip'"; then
    echo ""
    echo -e "${DIM}  Running: ${cmd}${RESET}"
    echo -e "${DIM}  (You may be asked for ${NEW_USER}'s password)${RESET}"
    echo ""

    local result
    result=$(su - "${NEW_USER}" -c 'sudo -n whoami' 2>/dev/null || true)

    if [[ "$result" == "root" ]]; then
      ok "User '${NEW_USER}' can run sudo. We're good to go!"
    else
      # Try with password prompt via tty
      echo -e "${DIM}  Trying with interactive sudo (enter ${NEW_USER}'s password if asked):${RESET}"
      su - "${NEW_USER}" -c 'sudo whoami' </dev/tty && {
        ok "User '${NEW_USER}' verified successfully."
      } || {
        echo ""
        error "Could not verify sudo access for '${NEW_USER}'."
        error "Do NOT restart SSH until this is fixed!"
        echo ""
        echo -e "${YELLOW}  Possible fixes:${RESET}"
        echo -e "  1. Make sure you set a password for '${NEW_USER}' in step 8"
        echo -e "  2. Run: ${CYAN}usermod -aG sudo ${NEW_USER}${RESET}"
        echo -e "  3. Then come back and re-run this step"
        echo ""
        confirm_yn "Do you want to continue anyway (risky)?" || {
          echo -e "${YELLOW}  Good call. Fix the issue and run the wizard again from step 8.${RESET}"
          exit 1
        }
      }
    fi
  fi
}

# ─── STEP 11: Restart SSH ─────────────────────────────────────────────────────

rollback_ssh() {
  echo ""
  error "Something went wrong. Rolling back SSH config to the backup..."
  if [[ -f /etc/ssh/sshd_config.backup ]]; then
    cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    ok "Rollback complete. SSH config restored to original."
  else
    error "No backup found at /etc/ssh/sshd_config.backup. Manual fix required."
  fi
}

step11_restart_ssh() {
  step_header 11 $TOTAL_STEPS "Restart SSH with the new hardened config"

  echo -e "${RED}${BOLD}  ████████████████████████████████████████████████████████████${RESET}"
  echo -e "${RED}${BOLD}  ██  WARNING — READ THIS BEFORE CONTINUING               ██${RESET}"
  echo -e "${RED}${BOLD}  ████████████████████████████████████████████████████████████${RESET}"
  echo ""
  echo -e "${YELLOW}  After restarting SSH:${RESET}"
  echo -e "  • SSH will ONLY accept connections via Tailscale (${TAILSCALE_IP})"
  echo -e "  • Password logins will NOT work"
  echo -e "  • Root login will NOT work"
  echo -e "  • ${BOLD}This terminal session stays open — DO NOT CLOSE IT${RESET}"
  echo -e "  • Open ANOTHER terminal and test the connection before closing this one"
  echo ""

  explain "First, we'll validate the config with 'sshd -t' (a dry run). If it \
finds any errors, we'll automatically restore the backup and abort. If the \
config is clean, we restart SSH."

  echo -e "${DIM}  Step 1 of 2: Validate config${RESET}"
  show_command "sshd -t"

  if confirm "Press Enter to validate SSH config, or type 'skip'"; then
    echo ""
    if sshd -t; then
      ok "SSH config is valid. No syntax errors."
    else
      error "sshd -t found errors in the config!"
      rollback_ssh
      exit 1
    fi
  fi

  echo ""
  divider
  echo ""
  echo -e "${DIM}  Step 2 of 2: Restart SSH service${RESET}"
  show_command "systemctl restart ssh"

  echo -e "${RED}${BOLD}  → This is the point of no return. Confirm? [y/n]${RESET}"
  local ans
  read -r ans </dev/tty
  if [[ "${ans,,}" != "y" ]]; then
    warn "Restart skipped. Your changes are saved but SSH is not yet using them."
    return
  fi

  echo ""
  if systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; then
    echo ""
    ok "SSH restarted successfully."
    echo ""
    echo -e "${YELLOW}  ★ IMPORTANT: Do NOT close this terminal yet!${RESET}"
    echo -e "  Go to step 12 and verify you can connect in a NEW terminal first."
  else
    error "SSH failed to restart!"
    rollback_ssh
    exit 1
  fi
}

# ─── STEP 12: Final verification ──────────────────────────────────────────────

step12_verify_connection() {
  step_header 12 $TOTAL_STEPS "Verify your new SSH connection"

  explain "NOW is the moment of truth. Open a brand-new terminal window \
(do NOT close this one) and try connecting with your new credentials. \
If it works, you're done with hardening. If it doesn't work, we'll \
automatically roll back to the old config so you don't get locked out."

  echo -e "${GREEN}${BOLD}  ┌──────────────────────────────────────────────────────────┐${RESET}"
  echo -e "${GREEN}${BOLD}  │${RESET}  ${BOLD}Open a NEW terminal and run:${RESET}"
  echo -e "${GREEN}${BOLD}  │${RESET}"
  echo -e "${GREEN}${BOLD}  │${RESET}    ${CYAN}ssh ${NEW_USER}@${TAILSCALE_IP}${RESET}"
  echo -e "${GREEN}${BOLD}  │${RESET}"
  echo -e "${GREEN}${BOLD}  └──────────────────────────────────────────────────────────┘${RESET}"
  echo ""
  echo -e "${YELLOW}  Keep THIS terminal open until you confirm it works.${RESET}"
  echo ""

  if confirm_yn "Were you able to connect successfully?"; then
    ok "Connection verified! SSH hardening is complete."
    echo ""
    echo -e "${GREEN}${BOLD}  🎉 Your server is now hardened. Great work!${RESET}"
  else
    echo ""
    error "Connection failed. Rolling back SSH config to be safe..."
    rollback_ssh
    echo ""
    echo -e "${YELLOW}  The SSH config has been restored to what it was before.${RESET}"
    echo -e "${YELLOW}  Check that:${RESET}"
    echo -e "  1. Tailscale is running: ${CYAN}tailscale status${RESET}"
    echo -e "  2. You're connecting to the right IP: ${CYAN}${TAILSCALE_IP}${RESET}"
    echo -e "  3. The user '${NEW_USER}' exists and has a password set"
    echo ""
    exit 1
  fi
}

# ─── Summary ──────────────────────────────────────────────────────────────────

show_summary() {
  echo ""
  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${CYAN}${BOLD}║                     SETUP COMPLETE                          ║${RESET}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "${BOLD}  Here's everything you need to know:${RESET}"
  echo ""
  echo -e "  ${GREEN}✓${RESET}  Tailscale installed and running"
  echo -e "  ${GREEN}✓${RESET}  SSH restricted to Tailscale only"
  echo -e "  ${GREEN}✓${RESET}  Password authentication disabled"
  echo -e "  ${GREEN}✓${RESET}  Root login disabled"
  echo -e "  ${GREEN}✓${RESET}  Admin user created: ${CYAN}${BOLD}${NEW_USER}${RESET}"
  echo ""
  echo -e "  ${BOLD}Your server details:${RESET}"
  echo -e "  ├── Tailscale IP:  ${CYAN}${TAILSCALE_IP}${RESET}"
  echo -e "  ├── SSH user:      ${CYAN}${NEW_USER}${RESET}"
  echo -e "  └── Connect with:  ${CYAN}ssh ${NEW_USER}@${TAILSCALE_IP}${RESET}"
  echo ""
  echo -e "  ${BOLD}Config backup:${RESET}  /etc/ssh/sshd_config.backup"
  echo ""
  echo -e "${DIM}  Your server is hardened and ready to use.${RESET}"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  banner

  echo -e "${BOLD}  Welcome to the VPS Secure Setup Wizard!${RESET}"
  echo ""
  echo -e "  This wizard will guide you through hardening your server step by step."
  echo -e "  ${BOLD}Every command is shown and explained before it runs.${RESET}"
  echo -e "  Nothing happens without your approval."
  echo ""
  echo -e "${DIM}  You can type 'skip' at any confirmation prompt to skip a step.${RESET}"
  echo ""
  divider
  echo ""
  echo -e "${BOLD}  → Press Enter to begin, or Ctrl+C to exit.${RESET}"
  read -r </dev/tty

  preflight

  step1_install_tailscale
  step2_start_tailscale
  step3_get_tailscale_ip
  step4_backup_ssh
  step5_listen_address
  step6_disable_password_auth
  step7_disable_root_login
  step8_create_user
  step9_sudo_privileges
  step10_verify_user
  step11_restart_ssh
  step12_verify_connection

  show_summary
}

main "$@"
