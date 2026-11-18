#!/usr/bin/env bash
# Prepara un Debian 13 recién instalado como servidor casero.
#
#   - actualiza el sistema y activa actualizaciones automáticas (reinicia a las 04:30 si hace falta)
#   - SSH solo con clave (si ya copiaste tu clave; si no, avisa y no toca nada)
#   - firewall (ufw): todo cerrado salvo SSH desde la LAN y desde Meshnet
#   - nombre fijo en la LAN (servidor.local, vía mDNS/avahi) aunque el router cambie la IP
#   - sin suspensión ni hibernación
#   - watchdog de hardware: si se congela, se reinicia solo a los 30 s
#   - muestra la salud del disco (SMART)
#
# Uso (en el servidor, desde tu usuario):  sudo bash bootstrap.sh
# Se puede volver a correr sin problema.
set -euo pipefail

RANGO_MESHNET="100.64.0.0/10"
REDES_LAN=("192.168.0.0/16" "10.0.0.0/8" "172.16.0.0/12")

paso()  { printf '\n\e[1;36m==> %s\e[0m\n' "$*"; }
aviso() { printf '\e[1;33m    %s\e[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "Correlo con sudo: sudo bash $0" >&2; exit 1; }
USUARIO="${SUDO_USER:-}"
if [[ -z $USUARIO || $USUARIO == root ]]; then
    echo "Correlo con sudo desde tu usuario normal (no como root directo)." >&2
    exit 1
fi

. /etc/os-release
[[ $ID == debian ]] || aviso "Esto está pensado para Debian (encontré: $PRETTY_NAME)."

# ------------------------------------------------------------------ paquetes
paso "Actualizando el sistema"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y full-upgrade
apt-get install -y --no-install-recommends \
    unattended-upgrades apt-listchanges ufw smartmontools \
    rsync curl ca-certificates unzip htop avahi-daemon

# ------------------------------------------------------------------ actualizaciones automáticas
paso "Actualizaciones automáticas"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/52homeserver <<'EOF'
// Generado por homeserver/bootstrap.sh
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
EOF
systemctl enable --now unattended-upgrades.service >/dev/null

# ------------------------------------------------------------------ energía
paso "Sin suspensión ni hibernación"
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1

# ------------------------------------------------------------------ watchdog
paso "Watchdog de hardware (si se congela, se reinicia solo)"
if ls /dev/watchdog0 >/dev/null 2>&1; then
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/watchdog.conf <<'EOF'
# Generado por homeserver/bootstrap.sh
# Si el sistema deja de responder 30 s, el chipset lo reinicia.
[Manager]
RuntimeWatchdogSec=30s
RebootWatchdogSec=10min
EOF
    systemctl daemon-reexec
    echo "    Activo en $(cat /sys/class/watchdog/watchdog0/identity 2>/dev/null || echo /dev/watchdog0)"
else
    aviso "No hay /dev/watchdog0: este equipo no tiene watchdog de hardware. Se omite."
fi

# ------------------------------------------------------------------ SSH
paso "SSH"
HOME_USUARIO=$(getent passwd "$USUARIO" | cut -d: -f6)
if [[ -s $HOME_USUARIO/.ssh/authorized_keys ]]; then
    cat > /etc/ssh/sshd_config.d/10-homeserver.conf <<'EOF'
# Generado por homeserver/bootstrap.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
    sshd -t
    systemctl reload ssh
    echo "    Solo se entra con clave. Contraseñas desactivadas."
else
    aviso "No hay claves en $HOME_USUARIO/.ssh/authorized_keys: dejo el login con contraseña."
    aviso "Copiá tu clave desde tu PC (ssh-copy-id) y volvé a correr este script."
fi

# ------------------------------------------------------------------ firewall
paso "Firewall: todo cerrado salvo SSH (LAN y Meshnet) y mDNS (LAN)"
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
for red in "${REDES_LAN[@]}" "$RANGO_MESHNET"; do
    ufw allow from "$red" to any port 22 proto tcp comment 'ssh' >/dev/null
done
# mDNS (servidor.local): solo desde la LAN.
for red in "${REDES_LAN[@]}"; do
    ufw allow from "$red" to any port 5353 proto udp comment 'mdns' >/dev/null
done
ufw --force enable >/dev/null
ufw status numbered

# ------------------------------------------------------------------ disco
paso "Salud del disco (SMART)"
smartctl --scan | while read -r disco _; do
    salud=$(smartctl -H "$disco" 2>/dev/null | grep -Ei 'overall-health|health status' | sed 's/.*: *//' || true)
    echo "    $disco: ${salud:-desconocido}"
    smartctl -A "$disco" 2>/dev/null | awk '
        $2 ~ /^(Power_On_Hours|Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable)$/ {
            printf "        %-24s %s\n", $2, $10
        }' || true
done
echo "    (Reallocated / Pending / Uncorrectable deberían ser 0. Si no, ese disco se está muriendo.)"

# ------------------------------------------------------------------ resumen
paso "Listo"
echo "    Hostname: $(hostname)"
echo "    IPs:      $(hostname -I)"
if [[ -f /var/run/reboot-required ]]; then
    aviso "Hay que reiniciar para terminar de aplicar actualizaciones: sudo reboot"
fi
