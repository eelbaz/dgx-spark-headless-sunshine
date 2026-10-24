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

install_prerequisites() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v python3 >/dev/null 2>&1 || missing+=(python3)

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Installing prerequisites: ${missing[*]}..."
    apt update -qq
    apt install -y -qq "${missing[@]}"
  fi
}

install_sunshine() {
  local deb_file="/tmp/sunshine-ubuntu-24.04-arm64.deb"

  # Check if Sunshine is already installed
  if command -v sunshine >/dev/null 2>&1; then
    echo "Sunshine is already installed ($(sunshine --version 2>/dev/null || echo 'version unknown'))."
    return 0
  fi

  echo "Installing Sunshine streaming software..."

  local ubuntu_version
  ubuntu_version="$(. /etc/os-release && echo "${VERSION_ID}")"

  # Look up the latest stable release and pick its Ubuntu arm64 .deb from the asset list.
  # Asset names changed in v2026.906 (sunshine-ubuntu-24.04-arm64.deb ->
  # sunshine_<version>-1+ubuntu24.04_arm64.deb), so match either form.
  echo "Fetching latest Sunshine release information..."
  local release_info latest_tag sunshine_url
  release_info=$(curl -fsSL "https://api.github.com/repos/LizardByte/Sunshine/releases/latest" | UBUNTU_VERSION="${ubuntu_version}" python3 -c '
import json, os, re, sys

release = json.load(sys.stdin)
version = re.escape(os.environ["UBUNTU_VERSION"])
pattern = re.compile(rf"^sunshine(-ubuntu-{version}-arm64|_.+\+ubuntu{version}_arm64)\.deb$")
for asset in release["assets"]:
    if pattern.match(asset["name"]):
        print(release["tag_name"], asset["browser_download_url"])
        break
') || true
  read -r latest_tag sunshine_url <<< "${release_info}" || true

  if [[ -z "${latest_tag}" || -z "${sunshine_url}" ]]; then
    echo "Failed to find a Sunshine package for Ubuntu ${ubuntu_version} arm64 in the latest release." >&2
    exit 1
  fi

  echo "Latest Sunshine release: ${latest_tag}"

  # Download Sunshine package
  echo "Downloading Sunshine from ${sunshine_url}..."
  curl -fL --progress-bar -o "${deb_file}" "${sunshine_url}" || {
    echo "Failed to download Sunshine package." >&2
    exit 1
  }

  # Install Sunshine; apt resolves the package's own runtime dependencies
  echo "Installing Sunshine package and dependencies..."
  apt update -qq
  apt install -y -qq "${deb_file}"

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

  GRUB_FILE="${grub_file}" GRUB_FLAGS="${flags[*]}" python3 - <<'PY'
import os, re
from pathlib import Path

grub_path = Path(os.environ["GRUB_FILE"])
text = grub_path.read_text()
match = re.search(r'^GRUB_CMDLINE_LINUX_DEFAULT="([^"]*)"', text, re.MULTILINE)
if not match:
    raise SystemExit(f"Unable to find GRUB_CMDLINE_LINUX_DEFAULT in {grub_path}")

# Append only the missing flags, leaving the existing value exactly as written
cmdline = match.group(1)
missing = [flag for flag in os.environ["GRUB_FLAGS"].split() if flag not in cmdline.split()]
if missing:
    cmdline = " ".join([cmdline, *missing]).strip()
    text = text[:match.start(1)] + cmdline + text[match.end(1):]
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
EndSection

Section "Files"
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
  install_prerequisites
  install_sunshine
  update_grub_cmdline
  write_xorg_config
  configure_gdm
  install_autostart

  cat <<EOM

Configuration complete. Next steps:
  1. Reboot the system so the new GRUB command line and Xorg configuration take effect.
  2. Allow the autologin session to initialize; the GNOME autostart entry will set the 1600x900 mode and launch Sunshine.
  3. Access Sunshine Web UI at: https://$(hostname):47990/ or https://$(hostname -I | awk '{print $1}'):47990/
     IMPORTANT: Use HTTPS (not HTTP) - you will need to accept the self-signed certificate warning.
  4. Set up your Sunshine username and password on first access.
  5. Pair Moonlight with this host using the PIN from https://$(hostname):47990/pin

Note: Automatic login is enabled for user "${TARGET_USER}". Adjust /etc/gdm3/custom.conf if you need different credentials.
EOM
}

main "$@"

