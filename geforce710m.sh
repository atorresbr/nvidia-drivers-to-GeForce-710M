#!/usr/bin/env bash
# install-nvidia-710m-popos.sh
# Attempts to install NVIDIA nvidia-driver-390 (GeForce 710M) on Pop!_OS
# Provides fallbacks: graphics-drivers PPA, then legacy PPAs (dtl131, kelebek333)
# IMPORTANT: run as root (sudo). Review before running.

set -euo pipefail
LOG="/tmp/install-nvidia-710m.log"
echo "Log -> $LOG"
exec > >(tee -a "$LOG") 2>&1

# Helpers
die(){ echo "ERROR: $*"; exit 1; }
check_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found."; }

# Required commands
for cmd in lspci apt-get apt-cache uname dkms update-initramfs; do
  check_cmd "$cmd" || true
done

if [[ $EUID -ne 0 ]]; then
  die "Run this script with sudo or as root."
fi

echo "Detecting GPU..."
GPU_LINE=$(lspci -nn | grep -i "vga\|3d" | grep -i nvidia || true)
echo "lspci result: $GPU_LINE"
if [[ -z "$GPU_LINE" ]]; then
  echo "No NVIDIA GPU found by lspci. Proceeding anyway (script will check available packages)."
else
  echo "Detected NVIDIA device: $GPU_LINE"
fi

# Check for Pop!_OS (best-effort)
if grep -qi "pop" /etc/os-release 2>/dev/null; then
  echo "Distribution appears to be Pop!_OS."
else
  echo "Warning: /etc/os-release does not look like Pop!_OS. Script still tries, but results may vary."
fi

# Secure Boot detection
echo "Checking Secure Boot status..."
if [ -f /sys/firmware/efi/efivars/SecureBoot-$(printf '%s' | sed 's/./x/g') ] || [ -d /sys/firmware/efi ]; then
  # Use mokutil if available
  if command -v mokutil >/dev/null 2>&1; then
    if mokutil --sb-state 2>/dev/null | grep -i enabled >/dev/null 2>&1; then
      echo "Secure Boot: ENABLED. This usually prevents unsigned NVIDIA kernel modules from loading."
      echo "You should disable Secure Boot in firmware or prepare to sign modules (MOK)."
    else
      echo "Secure Boot: disabled (mokutil)."
    fi
  else
    echo "Cannot query Secure Boot status (mokutil missing). If Secure Boot is enabled drivers may not load."
  fi
else
  echo "No EFI detected. Secure Boot likely not present."
fi

# Purge previous NVIDIA installations (safe)
echo "Purging previous NVIDIA packages (if any)..."
apt-get remove --purge -y 'nvidia-*' || true
apt-get autoremove -y || true
apt-get update -y

# Install prerequisites
echo "Installing prerequisites (dkms, build-essential, linux-headers)..."
apt-get install -y dkms build-essential linux-headers-$(uname -r) ca-certificates gnupg lsb-release software-properties-common

# Add Graphics Drivers PPA (official/community) - optional but commonly useful
add_graphics_ppa(){
  if ! grep -R "graphics-drivers" /etc/apt/sources.list.d >/dev/null 2>&1; then
    echo "Adding ppa:graphics-drivers/ppa ..."
    add-apt-repository -y ppa:graphics-drivers/ppa
    apt-get update -y
  else
    echo "graphics-drivers PPA already present."
  fi
}

# Try to install nvidia-driver-390 from current repos
apt_cache_has(){
  local pkg=$1
  apt-cache policy "$pkg" | grep -q 'Candidate:' || true
  apt-cache policy "$pkg" | grep -q 'Installed:' && return 0
  apt-cache policy "$pkg" | grep -q 'Candidate:' && return 0
  return 1
}

echo "Looking for package 'nvidia-driver-390' in apt repositories..."
if apt_cache_has nvidia-driver-390; then
  echo "Package nvidia-driver-390 appears available. Installing..."
  apt-get install -y nvidia-driver-390 nvidia-settings || die "Failed to install nvidia-driver-390 from repo."
  INSTALLED=1
else
  echo "nvidia-driver-390 not found in current repos. Will add graphics-drivers PPA and re-check."
  add_graphics_ppa
  if apt_cache_has nvidia-driver-390; then
    echo "Found nvidia-driver-390 after adding graphics-drivers PPA. Installing..."
    apt-get install -y nvidia-driver-390 nvidia-settings || die "Failed to install nvidia-driver-390."
    INSTALLED=1
  else
    echo "Still no nvidia-driver-390 package. Will try legacy community PPAs (dtl131 / kelebek333) as fallback."
    INSTALLED=0
  fi
fi

# Fallback: DTl131 (nvidiaexp) and kelebek333 (nvidia-legacy)
if [[ ${INSTALLED:-0} -eq 0 ]]; then
  echo "Adding fallback PPA: ppa:dtl131/nvidiaexp"
  add-apt-repository -y ppa:dtl131/nvidiaexp || echo "Warning: failed to add dtl131 PPA"
  apt-get update -y || true
  if apt_cache_has nvidia-driver-390; then
    echo "Installing nvidia-driver-390 from dtl131/nvidiaexp..."
    apt-get install -y nvidia-driver-390 nvidia-settings || true
    if dpkg -l | grep -q nvidia-driver-390; then INSTALLED=1; fi
  fi
fi

if [[ ${INSTALLED:-0} -eq 0 ]]; then
  echo "Adding fallback PPA: ppa:kelebek333/nvidia-legacy"
  add-apt-repository -y ppa:kelebek333/nvidia-legacy || echo "Warning: failed to add kelebek333 PPA"
  apt-get update -y || true
  if apt_cache_has nvidia-driver-390; then
    echo "Installing nvidia-driver-390 from kelebek333/nvidia-legacy..."
    apt-get install -y nvidia-driver-390 nvidia-settings || true
    if dpkg -l | grep -q nvidia-driver-390; then INSTALLED=1; fi
  fi
fi

# Final check
if dpkg -l | grep -q nvidia-driver-390; then
  echo "nvidia-driver-390 installed. Configuring..."
  # Blacklist nouveau
  echo "Blacklisting nouveau..."
  cat >/etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
  update-initramfs -u

  echo "Attempting to load the nvidia modules..."
  # try to load modules now
  depmod -a || true
  modprobe nvidia || true

  echo "Installation attempted. Run 'nvidia-smi' to verify (if present)."
  echo "If you have Secure Boot enabled, the module may be blocked. See /var/log/syslog or 'dmesg' for 'nvidia' or 'secureboot' messages."
  echo "Reboot the system now to complete driver installation."
  exit 0
else
  echo "Failed to install nvidia-driver-390 from repos and PPAs."
  echo "Common causes:"
  echo "  * You are running a very new kernel (6.5+) and the 390 driver lacks support without patches."
  echo "  * The distro removed the 390 package from official repos."
  echo
  echo "Suggested next steps (manual):"
  echo "  1) Try an older kernel (e.g. 5.15 or 6.2) and re-run this script."
  echo "  2) Use the patched PPAs (dtl131/kelebek333) but expect breakage on some kernels."
  echo "  3) Consider using Pop!_Shop or 'sudo apt install system76-driver-nvidia' if you prefer System76's driver flow (may use a different driver family)."
  echo
  echo "If you want, re-run script after switching kernel or enabling the appropriate PPA. Check $LOG for details."
  exit 2
fi
