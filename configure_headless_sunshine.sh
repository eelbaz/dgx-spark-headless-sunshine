#!/usr/bin/env bash
# Configure a DGX Spark system for headless Sunshine streaming.
# This script must be run as root (e.g. sudo ./configure_headless_sunshine.sh).

set -euo pipefail

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root (try: sudo $0)" >&2
    exit 1
  fi
}

determine_target_user() {
  local user
  user="${TARGET_USER:-${SUDO_USER:-}}"
  if [[ -z "${user}" ]]; then
    echo "Unable to determine the non-root user. Set TARGET_USER=username when invoking this script." >&2
    exit 1
  fi
  if ! id "${user}" >/dev/null 2>&1; then
    echo "User ${user} does not exist on this system." >&2
    exit 1
  fi
  TARGET_USER="${user}"
  TARGET_HOME="$(eval echo "~${TARGET_USER}")"
  TARGET_UID="$(id -u "${TARGET_USER}")"
}

install_sunshine() {
  local sunshine_url="https://github.com/LizardByte/Sunshine/releases/download/v2025.1014.193231/sunshine-ubuntu-24.04-arm64.deb"
  local deb_file="/tmp/sunshine-ubuntu-24.04-arm64.deb"

  # Check if Sunshine is already installed
  if command -v sunshine >/dev/null 2>&1; then
    echo "Sunshine is already installed ($(sunshine --version 2>/dev/null || echo 'version unknown'))."
    return 0
  fi

  echo "Installing Sunshine streaming software..."

  # Download Sunshine package
  echo "Downloading Sunshine from ${sunshine_url}..."
  wget -q --show-progress -O "${deb_file}" "${sunshine_url}" || {
    echo "Failed to download Sunshine package." >&2
    exit 1
  }

  # Install dependencies
  echo "Installing Sunshine dependencies..."
  apt update -qq
  apt install -y -qq \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libswscale-dev \
    libevdev-dev \
    libpulse-dev \
    libopus-dev \
    libxtst-dev \
    libx11-dev \
    libxrandr-dev \
    libxfixes-dev \
    libxcb1-dev \
    libxcb-shm0-dev \
    libxcb-xfixes0-dev \
    libdrm-dev \
    libcap-dev \
    libudev-dev \
    libwayland-dev \
    libinput-dev \
    libcurl4-openssl-dev \
    libssl-dev 2>/dev/null || true

  # Install Sunshine
  echo "Installing Sunshine package..."
  dpkg -i "${deb_file}" 2>/dev/null || {
    echo "Fixing broken dependencies..."
    apt --fix-broken install -y -qq
  }

  # Clean up
  rm -f "${deb_file}"

  # Verify installation
  if command -v sunshine >/dev/null 2>&1; then
    echo "Sunshine installed successfully ($(sunshine --version 2>/dev/null || echo 'installed'))."
  else
    echo "Warning: Sunshine installation may have failed. Please check manually." >&2
  fi
}

update_grub_cmdline() {
  local grub_file="/etc/default/grub"
  local flags=("nvidia-drm.modeset=1" "nvidia.NVreg_UsePageAttributeTable=1")

  python3 - <<'PY'
import re, shlex
from pathlib import Path

grub_path = Path("/etc/default/grub")
text = grub_path.read_text()
match = re.search(r'^GRUB_CMDLINE_LINUX_DEFAULT="([^"]*)"', text, re.MULTILINE)
if not match:
    raise SystemExit("Unable to find GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub")

existing = shlex.split(match.group(1))
desired = ["nvidia-drm.modeset=1", "nvidia.NVreg_UsePageAttributeTable=1"]
for flag in desired:
    if flag not in existing:
        existing.append(flag)

replacement = f'GRUB_CMDLINE_LINUX_DEFAULT="{" ".join(existing)}"'
start, end = match.span()
text = text[:start] + replacement + text[end:]
grub_path.write_text(text)
PY

  echo "Regenerated GRUB command line with NVIDIA DRM modeset flags."
  update-grub
}

write_xorg_config() {
  local xorg_path="/etc/X11/xorg.conf"
  if [[ -f "${xorg_path}" && ! -f "${xorg_path}.backup-before-sunshine" ]]; then
    cp "${xorg_path}" "${xorg_path}.backup-before-sunshine"
  fi

  cat <<'EOF' > "${xorg_path}"
# Headless Xorg configuration for NVIDIA GB10 on DGX Spark
Section "ServerLayout"
    Identifier     "Layout0"
    Screen      0  "Screen0" 0 0
    InputDevice    "Keyboard0" "CoreKeyboard"
    InputDevice    "Mouse0" "CorePointer"
EndSection

Section "Files"
EndSection

Section "InputDevice"
    Identifier     "Mouse0"
    Driver         "mouse"
    Option         "Protocol" "auto"
    Option         "Device" "/dev/psaux"
    Option         "Emulate3Buttons" "no"
    Option         "ZAxisMapping" "4 5"
EndSection

Section "InputDevice"
    Identifier     "Keyboard0"
    Driver         "kbd"
EndSection

Section "Monitor"
    Identifier     "Monitor0"
    VendorName     "Virtual"
    ModelName      "Headless"
    Option         "DPMS"
EndSection

Section "Device"
    Identifier     "Device0"
    Driver         "nvidia"
    VendorName     "NVIDIA Corporation"
    BoardName      "NVIDIA GB10"
    Option         "AllowEmptyInitialConfiguration" "True"
    Option         "VirtualHeads" "1"
    Option         "ConnectedMonitor" "DFP-0"
    Option         "Coolbits" "28"
EndSection

Section "Screen"
    Identifier     "Screen0"
    Device         "Device0"
    Monitor        "Monitor0"
    DefaultDepth    24
    Option         "MetaModes" "HDMI-0: 1600x900 +0+0"
    SubSection     "Display"
        Virtual     1920 1080
        Depth       24
    EndSubSection
EndSection
EOF

  echo "Wrote headless Xorg configuration to ${xorg_path}."
}

configure_gdm() {
  AUTLOGIN_USER="${TARGET_USER}" python3 - <<'PY'
from pathlib import Path
from configparser import ConfigParser
import os

path = Path("/etc/gdm3/custom.conf")
parser = ConfigParser(strict=False, allow_no_value=True)
parser.optionxform = str  # Preserve option casing expected by GDM
parser.read(path)

if "daemon" not in parser:
    parser["daemon"] = {}

daemon = parser["daemon"]
for key in list(daemon.keys()):
    if key.lower() in {
        "waylandenable",
        "defaultsession",
        "automaticloginenable",
        "automaticlogin",
    }:
        daemon.pop(key)
daemon["WaylandEnable"] = "false"
daemon["DefaultSession"] = "gnome-xorg.desktop"
daemon["AutomaticLoginEnable"] = "true"
daemon["AutomaticLogin"] = os.environ["AUTLOGIN_USER"]

with path.open("w") as fh:
    parser.write(fh, space_around_delimiters=False)
PY

  echo "Configured GDM for Xorg and autologin (user ${TARGET_USER})."
}

install_autostart() {
  local autostart_dir="${TARGET_HOME}/.config/autostart"
  local desktop_file="${autostart_dir}/headless-xrandr.desktop"
  local xauth="/run/user/${TARGET_UID}/gdm/Xauthority"
  local runtime_dir="/run/user/${TARGET_UID}"

  install -d -m 755 -o "${TARGET_USER}" -g "${TARGET_USER}" "${autostart_dir}"

  cat <<EOF > "${desktop_file}"
[Desktop Entry]
Type=Application
Exec=/bin/sh -c '/usr/bin/xrandr --output HDMI-0 --mode 1600x900; sleep 5; if ! pgrep -x sunshine >/dev/null 2>&1; then DISPLAY=:0 XAUTHORITY=${xauth} XDG_RUNTIME_DIR=${runtime_dir} /usr/bin/sunshine & fi'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=Headless Display Mode
EOF

  chown "${TARGET_USER}:${TARGET_USER}" "${desktop_file}"
  chmod 644 "${desktop_file}"

  echo "Installed GNOME autostart entry to set the dummy display and launch Sunshine."
}

main() {
  require_root
  determine_target_user
  install_sunshine
  update_grub_cmdline
  write_xorg_config
  configure_gdm
  install_autostart

  cat <<EOM

Configuration complete. Next steps:
  1. Reboot the system so the new GRUB command line and Xorg configuration take effect.
  2. Allow the autologin session to initialize; the GNOME autostart entry will set the 1600x900 mode and launch Sunshine.
  3. Pair Moonlight with this host once Sunshine is running.

Note: Automatic login is enabled for user "${TARGET_USER}". Adjust /etc/gdm3/custom.conf if you need different credentials.
EOM
}

main "$@"

