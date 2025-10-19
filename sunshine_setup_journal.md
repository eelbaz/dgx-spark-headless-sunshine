# DGX Spark Headless Sunshine Setup Journal

**Date:** 2025-10-19
**System:** spark-alpha
**GPU:** NVIDIA GB10 (Blackwell)

## Pre-Configuration Status

### Hardware
- GPU: NVIDIA GB10 (UUID: GPU-ba5e4e08-5084-e65d-cff8-f35f7fbb82e8)
- DRI Devices:
  - `/dev/dri/card0` → simpledrm
  - `/dev/dri/card1` → nvidia-drm
  - `/dev/dri/renderD128` → Render node

### Current Configuration
- GRUB: `GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,921600"`
- Missing: `nvidia-drm.modeset=1` (required for DRM modesetting)
- Xorg: Factory NVIDIA config with `AllowEmptyInitialConfiguration=True`
- GDM: Default config, Wayland potentially enabled

### Sunshine Errors (Pre-Fix)
```
Error: GPU driver doesn't support universal planes: /dev/dri/card1
Error: Couldn't find monitor [23170]
Fatal: Unable to find display or encoder during startup.
```

**Root Cause:** Missing kernel parameter `nvidia-drm.modeset=1` and no virtual display configured.

---

## Sunshine Installation

### Prerequisites
Before configuring displays, Sunshine must be installed on the system.

### Installation Steps

#### Step 1: Download Sunshine Package
```bash
cd /tmp
wget https://github.com/LizardByte/Sunshine/releases/download/v2025.1014.193231/sunshine-ubuntu-24.04-arm64.deb
```

#### Step 2: Install Dependencies
Sunshine requires several system packages to function properly:
```bash
sudo apt update
sudo apt install -y \
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
    libssl-dev
```

#### Step 3: Install Sunshine
```bash
sudo dpkg -i sunshine-ubuntu-24.04-arm64.deb
# Fix any dependency issues if they arise
sudo apt --fix-broken install -y
```

#### Step 4: Enable Sunshine Service (Optional)
```bash
# To enable Sunshine as a systemd user service
systemctl --user enable sunshine
```

#### Step 5: Verify Installation
```bash
# Check if Sunshine is installed
which sunshine
sunshine --version
```

### Configuration Location
- Configuration files: `~/.config/sunshine/`
- Logs: Check with `journalctl --user -u sunshine`

**Note:** Sunshine should NOT be started yet - it requires the display configuration completed by the script below.

---

## Configuration Script Actions

The `configure_headless_sunshine.sh` script will:

1. **Add GRUB kernel parameters** (requires reboot):
   - `nvidia-drm.modeset=1` - Enables DRM modesetting for NVIDIA
   - `nvidia.NVreg_UsePageAttributeTable=1` - Performance optimization

2. **Update `/etc/X11/xorg.conf`**:
   - Creates backup: `/etc/X11/xorg.conf.backup-before-sunshine`
   - Configures virtual display: HDMI-0 at 1600x900
   - Adds `VirtualHeads=1` and `ConnectedMonitor=DFP-0`
   - Adds `Coolbits=28` for GPU control

3. **Configure GDM** (`/etc/gdm3/custom.conf`):
   - Disables Wayland, forces X11
   - Enables autologin for target user

4. **Install autostart entry** (`~/.config/autostart/headless-xrandr.desktop`):
   - Runs `xrandr --output HDMI-0 --mode 1600x900` on login
   - Auto-launches Sunshine with proper environment variables

---

## Execution Steps

### Step 1: Run Configuration Script
The script will automatically:
- Install Sunshine and its dependencies
- Configure GRUB kernel parameters
- Set up Xorg for headless operation
- Configure GDM and autologin
- Install autostart entries

```bash
cd /home/exobit/development/dgx
sudo ./configure_headless_sunshine.sh
```

**Note:** The script checks if Sunshine is already installed and will skip installation if found.

### Step 2: Verify Changes Before Rebooting
```bash
# Check Sunshine was installed
which sunshine
sunshine --version

# Check GRUB was updated
grep nvidia-drm /etc/default/grub

# Verify backup was created
ls -la /etc/X11/xorg.conf*

# Check GDM configuration
grep -A 4 "[daemon]" /etc/gdm3/custom.conf

# Check autostart entry
cat ~/.config/autostart/headless-xrandr.desktop
```

### Step 3: Reboot System
```bash
sudo reboot
```

### Step 4: Verify DRM Modeset After Reboot
```bash
# Check kernel parameter is active
cat /proc/cmdline | grep nvidia-drm.modeset

# Verify modeset enabled (should output: Y)
cat /sys/module/nvidia_drm/parameters/modeset
```

### Step 5: Verify Sunshine Operation
```bash
# Check if Sunshine is running
ps aux | grep sunshine

# Monitor Sunshine logs
journalctl --user -u sunshine -f

# Test from terminal (should work now)
sunshine
```

---

## Rollback Plan

If issues occur, restore original configuration:

```bash
# Restore original xorg.conf
sudo cp /etc/X11/xorg.conf.backup-before-sunshine /etc/X11/xorg.conf

# Remove kernel parameters from GRUB
sudo nano /etc/default/grub
# Remove: nvidia-drm.modeset=1 nvidia.NVreg_UsePageAttributeTable=1
sudo update-grub

# Disable autologin in GDM (optional)
sudo nano /etc/gdm3/custom.conf
# Set: AutomaticLoginEnable=false

# Reboot
sudo reboot
```

---

## Expected Results

After successful configuration:
- NVENC encoder should initialize without errors
- Virtual display (HDMI-0) should be available to Sunshine
- Sunshine should find encoder and display during startup
- Remote streaming via Moonlight should work

---

## Notes

- Script is safe: creates backups before modifications
- Changes take effect after reboot (GRUB parameters)
- Autologin enabled for convenience (adjust if security concern)
- Physical display support may need MetaModes adjustment in xorg.conf

---

## Execution Log

### Script Execution ✅ COMPLETED
**Date:** 2025-10-19 12:13

**Output:**
```
Regenerated GRUB command line with NVIDIA DRM modeset flags.
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-6.11.0-1016-nvidia
Found initrd image: /boot/initrd.img-6.11.0-1016-nvidia
Warning: os-prober will not be executed to detect other bootable partitions.
done
Wrote headless Xorg configuration to /etc/X11/xorg.conf.
Configured GDM for Xorg and autologin (user exobit).
```

**Warning Analysis:**
⚠️ "os-prober will not be executed to detect other bootable partitions"
- **Type:** Informational (NOT an error)
- **Cause:** os-prober disabled by default (standard for single-OS systems)
- **Impact:** None - this is a single-OS DGX workstation
- **Safety:** ✅ Expected and safe

**Verification Results:**
1. ✅ GRUB updated: `nvidia-drm.modeset=1 nvidia.NVreg_UsePageAttributeTable=1`
2. ✅ Xorg config: 1.4K at `/etc/X11/xorg.conf` (backup created)
3. ✅ GDM: Wayland disabled, X11 forced, autologin enabled for `exobit`
4. ✅ Autostart: `~/.config/autostart/headless-xrandr.desktop` created

**Reboot:** [Pending - REQUIRED FOR CHANGES TO TAKE EFFECT]
**Post-Reboot Verification:** [Pending]
**Status:** Ready for reboot
