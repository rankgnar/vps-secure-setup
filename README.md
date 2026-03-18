# OpenClaw Secure Setup

A guided interactive wizard that secures your VPS and installs OpenClaw step by step.

No guesswork, no manual config — just answer a few prompts and you're done.

## What It Does

The wizard walks you through 4 steps:

1. **Install & authenticate Tailscale** — connects your VPS to your private network
2. **Harden SSH** — restricts access to your Tailscale IP, disables password auth, disables root login
3. **Create a non-root sudo user** — sets up a safe account with SSH keys copied from root
4. **Install OpenClaw** — runs the official OpenClaw installer for your new user

## Safety Features

- Confirmation prompt before every critical change
- Automatic rollback if SSH validation fails or you can't reconnect
- Verification prompts after SSH hardening and user creation — you confirm it works before moving on
- Idempotent: safe to re-run if a step was already completed

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/rankgnar/openclaw-secure-setup/main/install-wizard.sh | sudo bash
```

Or clone and run locally:

```bash
git clone https://github.com/rankgnar/openclaw-secure-setup.git
cd openclaw-secure-setup
sudo bash install-wizard.sh
```

## Requirements

- Fresh VPS running **Ubuntu** or **Debian**
- Root access (run with `sudo`)
- A Tailscale account (free at [tailscale.com](https://tailscale.com))

## License

MIT
