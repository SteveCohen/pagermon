#!/usr/bin/env bash
#
# PagerMon client/decoder installer
# =================================
# Interactive setup for the RF -> decode -> POST pipeline that feeds a PagerMon
# server:   rtl_fm (capture) | multimon-ng (decode) | reader.js (POST).
#
# It takes a fresh Debian / Raspberry Pi OS box from "dongle plugged in" to
# "messages flowing into PagerMon", automating the steps (and the gotchas)
# that are easy to miss:
#
#   1. Installs any missing packages: rtl-sdr, multimon-ng, sox, nodejs, npm
#   2. Stops the kernel DVB-T driver (dvb_usb_rtl28xxu) from grabbing the dongle
#   3. Grants the login user USB access (plugdev group + udev reload)
#   4. Installs the client's Node dependencies (npm install)
#   5. Writes config/config.json  (server URL + API key + source identifier)
#   6. Generates reader.sh with YOUR device index / frequency / protocol
#   7. Optionally installs a systemd service so the decoder runs on boot
#   8. Optionally runs the bundled sample decode as an end-to-end test
#
# The decoder and the PagerMon server are independent components that talk over
# HTTP. This configures the decoder side only; the server (e.g. a Docker
# container) just has to be reachable at the URL you give below, and the API
# key here must match one in the server's auth.keys.
#
# Run as your normal login user (NOT root) -- it calls sudo where needed.

set -uo pipefail

# --- logging helpers (everything to stderr so $(...) captures stay clean) ----
section() { printf '\n==> %s\n' "$*" >&2; }
info()    { printf '    %s\n' "$*" >&2; }
warn()    { printf 'WARN: %s\n' "$*" >&2; }
err()     { printf 'ERROR: %s\n' "$*" >&2; }
die()     { err "$*"; exit 1; }

# --- prompt helpers ----------------------------------------------------------
ask() {  # ask "Question" ["default"] -> echoes the answer on stdout
  local prompt="$1" default="${2-}" reply
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " reply
    printf '%s' "${reply:-$default}"
  else
    read -r -p "$prompt: " reply
    printf '%s' "$reply"
  fi
}
ask_required() {  # loops until something non-empty is entered
  local prompt="$1" val=""
  while [ -z "$val" ]; do
    val="$(ask "$prompt")"
    [ -z "$val" ] && warn "A value is required here."
  done
  printf '%s' "$val"
}
confirm() {  # confirm "Question" ["Y"|"N"] -> exit status 0 = yes
  local prompt="$1" default="${2:-Y}" reply hint="[Y/n]"
  [ "$default" = "N" ] && hint="[y/N]"
  read -r -p "$prompt $hint " reply
  reply="${reply:-$default}"
  case "$reply" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# --- preflight ---------------------------------------------------------------
section "PagerMon decoder installer"

[ "$(id -u)" -eq 0 ] && die "Run as your normal login user, not root (the script uses sudo itself)."
command -v sudo >/dev/null 2>&1 || die "sudo is required but not installed."

CLIENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$CLIENT_DIR" || die "Cannot cd to $CLIENT_DIR"
[ -f "$CLIENT_DIR/reader.js" ] || die "reader.js not found in $CLIENT_DIR -- run this from the PagerMon client/ directory."

TARGET_USER="$(id -un)"
REBOOT_NEEDED=0
INSTALL_SERVICE=n

info "Client directory : $CLIENT_DIR"
info "Service user     : $TARGET_USER"
info "This will install packages and change USB driver/permission settings via sudo."
confirm "Continue?" "Y" || die "Aborted."

info "Priming sudo (you may be asked for your password)..."
sudo -v || die "sudo authentication failed."

# --- 1. packages -------------------------------------------------------------
section "Checking system packages"
PKGS=()
command -v rtl_fm      >/dev/null 2>&1 || PKGS+=(rtl-sdr)
command -v multimon-ng >/dev/null 2>&1 || PKGS+=(multimon-ng)
command -v sox         >/dev/null 2>&1 || PKGS+=(sox)
command -v node        >/dev/null 2>&1 || PKGS+=(nodejs)
command -v npm         >/dev/null 2>&1 || PKGS+=(npm)

if [ "${#PKGS[@]}" -gt 0 ]; then
  info "Installing: ${PKGS[*]}"
  sudo apt-get update || die "apt-get update failed."
  sudo apt-get install -y "${PKGS[@]}" || die "Package install failed."
else
  info "All required tools are already installed."
fi

# --- 2. stop the DVB-T driver claiming the dongle ----------------------------
section "RTL-SDR kernel driver"
BLACKLIST=/etc/modprobe.d/blacklist-rtl.conf
if [ -f "$BLACKLIST" ] && grep -q 'dvb_usb_rtl28xxu' "$BLACKLIST"; then
  info "Blacklist already present: $BLACKLIST"
else
  info "Writing $BLACKLIST to stop the DVB-T driver claiming the dongle..."
  echo 'blacklist dvb_usb_rtl28xxu' | sudo tee "$BLACKLIST" >/dev/null
fi

if lsmod | grep -qE '^(dvb_usb_rtl28xxu|rtl2832)'; then
  info "Unloading DVB modules now (best effort)..."
  sudo modprobe -r dvb_usb_rtl28xxu 2>/dev/null || true
  if lsmod | grep -qE '^(dvb_usb_rtl28xxu|rtl2832)'; then
    warn "DVB modules are still loaded; a reboot is required to release the dongle."
    REBOOT_NEEDED=1
  else
    info "DVB modules unloaded."
  fi
fi

# --- 3. USB permissions ------------------------------------------------------
section "USB device permissions"
if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx plugdev; then
  info "$TARGET_USER is already in the plugdev group."
else
  info "Adding $TARGET_USER to the plugdev group..."
  sudo usermod -aG plugdev "$TARGET_USER"
  warn "Group membership only applies after a reboot (or full re-login)."
  REBOOT_NEEDED=1
fi
sudo udevadm control --reload-rules 2>/dev/null || true
sudo udevadm trigger 2>/dev/null || true

# --- 4. node dependencies ----------------------------------------------------
section "Node dependencies"
info "Running npm install in $CLIENT_DIR ..."
npm install || die "npm install failed."
[ -d "$CLIENT_DIR/node_modules/nconf" ] || die "npm install did not produce node_modules/nconf."
info "Dependencies installed."

# --- 5. client config --------------------------------------------------------
section "Client configuration (config/config.json)"
WRITE_CONFIG=y
if [ -f config/config.json ]; then
  confirm "config/config.json exists -- update its server/apikey/identifier?" "Y" || WRITE_CONFIG=n
fi
if [ "$WRITE_CONFIG" = "y" ]; then
  IDENTIFIER="$(ask "Source identifier (appears in PagerMon's 'source' column)" "$(hostname)")"
  SERVER_HOST="$(ask "PagerMon server URL" "http://127.0.0.1:3000")"
  API_KEY="$(ask_required "API key (must match an entry in the server's auth.keys)")"
  PM_APIKEY="$API_KEY" PM_HOST="$SERVER_HOST" PM_ID="$IDENTIFIER" node -e '
    const fs = require("fs");
    const base = fs.existsSync("config/config.json") ? "config/config.json" : "config/default.json";
    const cfg = JSON.parse(fs.readFileSync(base, "utf8"));
    cfg.apikey = process.env.PM_APIKEY;
    cfg.hostname = process.env.PM_HOST;
    cfg.identifier = process.env.PM_ID;
    fs.writeFileSync("config/config.json", JSON.stringify(cfg, null, 2));
  ' || die "Failed to write config/config.json"
  info "Wrote config/config.json"
else
  info "Leaving existing config/config.json untouched."
fi

# --- 6. generate reader.sh ---------------------------------------------------
section "Decoder pipeline (reader.sh)"
info "These are the values that bite people -- set them for YOUR hardware/area."
DEV="$(ask "RTL-SDR device index (-d), usually 0 for a single dongle" "0")"
FREQ="$(ask_required "Frequency to tune (-f), e.g. 148.5875M or 148540000")"
PROTO="$(ask "multimon-ng protocol (-a): POCSAG512 / POCSAG1200 / POCSAG2400 / FLEX" "POCSAG512")"
SQUELCH="$(ask "Squelch (-l), 0 disables it (recommended for paging)" "0")"
GAIN="$(ask "Tuner gain (-g) in dB, blank = automatic" "")"

RTL_OPTS="-d $DEV -E dc -F 0"
[ -n "$SQUELCH" ] && RTL_OPTS="$RTL_OPTS -l $SQUELCH"
[ -n "$GAIN" ]    && RTL_OPTS="$RTL_OPTS -g $GAIN"
RTL_OPTS="$RTL_OPTS -A fast -f $FREQ -s22050"

if [ -f reader.sh ]; then
  cp reader.sh "reader.sh.bak.$(date +%Y%m%d%H%M%S)"
  info "Backed up existing reader.sh"
fi

cat > reader.sh <<EOF
#!/bin/bash
# Generated by install.sh on $(date)
# Pipeline: rtl_fm (capture) | multimon-ng (decode) | reader.js (POST to server)
# Re-run install.sh to regenerate, or edit the flags below by hand.
#   multimon-ng flags below assume POCSAG; FLEX/EAS users may need to adjust
#   (-b/-f), see the command examples in the repo README.
rtl_fm $RTL_OPTS - |
multimon-ng -q -b1 -c -a $PROTO -f alpha -t raw /dev/stdin |
node reader.js
EOF
chmod +x reader.sh
info "Wrote reader.sh:"
info "  rtl_fm $RTL_OPTS - | multimon-ng ... -a $PROTO ... | node reader.js"

# --- 7. systemd service ------------------------------------------------------
section "Run on boot (systemd service)"
if confirm "Install a systemd service to run the decoder automatically on boot?" "Y"; then
  INSTALL_SERVICE=y
  sudo tee /etc/systemd/system/pagermon-reader.service >/dev/null <<EOF
[Unit]
Description=PagerMon decoder (rtl_fm | multimon-ng | reader.js)
After=network-online.target docker.service
Wants=network-online.target

[Service]
User=$TARGET_USER
WorkingDirectory=$CLIENT_DIR
ExecStart=/bin/bash $CLIENT_DIR/reader.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable pagermon-reader >/dev/null 2>&1 || true
  info "Service installed and enabled (will start on boot)."
else
  info "Skipping systemd service -- run ./reader.sh by hand when you want to decode."
fi

# --- 8. finish: reboot if needed, otherwise offer to verify/start ------------
section "Done"
if [ "$REBOOT_NEEDED" -eq 1 ]; then
  warn "A reboot is required to free the dongle from the DVB driver and/or apply group membership."
  [ "$INSTALL_SERVICE" = "y" ] && info "After reboot, the pagermon-reader service starts automatically."
  if confirm "Reboot now?" "N"; then
    sudo reboot
  else
    info "Reboot later with: sudo reboot"
  fi
else
  info "No reboot needed."
  if confirm "Run a quick rtl_test (~4s) to confirm the dongle opens?" "Y"; then
    info "Expect device info and 'Reading samples'..."
    timeout 4 rtl_test 2>&1 || true
  fi
  if confirm "Run the bundled sample decode now? (POSTs 6 test messages to your server)" "N"; then
    info "Decoding samples/sample-2017-06-01.wav -> reader.js ..."
    multimon-ng -b2 -q -c -t wav -a POCSAG512 -f alpha samples/sample-2017-06-01.wav | node ./reader.js || true
    info "Check your PagerMon web UI for the DAILY TEST messages."
  fi
  if [ "$INSTALL_SERVICE" = "y" ]; then
    if confirm "Start the pagermon-reader service now?" "Y"; then
      sudo systemctl start pagermon-reader
      info "Service started. Follow logs with: journalctl -u pagermon-reader -f"
      warn "Don't run ./reader.sh by hand while the service is running -- they share the one dongle."
    else
      info "Start later with: sudo systemctl start pagermon-reader"
    fi
  fi
fi

section "Summary"
info "Decoder configured in : $CLIENT_DIR"
info "Run by hand           : ./reader.sh   (only when the service is stopped)"
if [ "$INSTALL_SERVICE" = "y" ]; then
  info "Service control       : sudo systemctl {start,stop,status} pagermon-reader"
  info "Service logs          : journalctl -u pagermon-reader -f"
fi
info "Reminder: the dongle can only be used by ONE process at a time (service OR manual)."
