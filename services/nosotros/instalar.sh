#!/usr/bin/env bash
# Instala o actualiza "Nosotros" (PocketBase) como servicio del sistema.
#
# Normalmente no se corre a mano: lo llama deploy.sh desde tu PC, que primero sube
# el frontend y las migraciones a ./app/ (al lado de este script).
#
#   sudo bash instalar.sh                         # instalar / actualizar
#   sudo bash instalar.sh --datos-desde DIR       # además, importar un pb_data existente
#   sudo bash instalar.sh --desinstalar           # quita servicio y firewall (NO borra datos)
#
# Todo vive en /srv/nosotros. Los datos (/srv/nosotros/pb_data) nunca se borran.
set -euo pipefail

VERSION="0.40.6"
PUERTO=8090
DESTINO="/srv/nosotros"
USUARIO_SRV="nosotros"
RANGO_MESHNET="100.64.0.0/10"

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$AQUI/app"            # lo llena deploy.sh: pb_public/ y pb_migrations/
EXE="$DESTINO/pocketbase"
DATOS="$DESTINO/pb_data"

paso()  { printf '\n\e[1;36m==> %s\e[0m\n' "$*"; }
aviso() { printf '\e[1;33m    %s\e[0m\n' "$*"; }
error() { printf '\e[1;31m%s\e[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || error "Correlo con sudo."

DATOS_DESDE=""
case "${1:-}" in
    "") ;;
    --datos-desde) DATOS_DESDE="${2:?Falta la carpeta de datos}" ;;
    --desinstalar)
        paso "Quitando servicio y regla de firewall"
        systemctl disable --now nosotros.service 2>/dev/null || true
        rm -f /etc/systemd/system/nosotros.service
        systemctl daemon-reload
        ufw delete allow from "$RANGO_MESHNET" to any port "$PUERTO" proto tcp >/dev/null 2>&1 || true
        echo "Listo. Los archivos en $DESTINO (incluidos los datos) se mantienen."
        exit 0 ;;
    *) error "Opción desconocida: $1" ;;
esac

# ------------------------------------------------------------------ comprobaciones
[[ -f $APP/pb_public/index.html ]] || error "No existe $APP/pb_public/index.html. Usá deploy.sh desde tu PC."
[[ -d $APP/pb_migrations ]]         || error "No existe $APP/pb_migrations. Usá deploy.sh desde tu PC."
if [[ -n $DATOS_DESDE && ! -f $DATOS_DESDE/data.db ]]; then
    error "No hay data.db en '$DATOS_DESDE'."
fi
command -v rsync >/dev/null && command -v unzip >/dev/null || error "Faltan rsync/unzip. ¿Corriste bootstrap.sh?"

# ------------------------------------------------------------------ usuario y carpetas
if ! id "$USUARIO_SRV" &>/dev/null; then
    paso "Creando usuario de sistema '$USUARIO_SRV'"
    useradd --system --home-dir "$DESTINO" --shell /usr/sbin/nologin "$USUARIO_SRV"
fi
install -d -m 0750 -o "$USUARIO_SRV" -g "$USUARIO_SRV" "$DESTINO" "$DATOS"

if systemctl is-active --quiet nosotros.service; then
    paso "Deteniendo la instancia actual"
    systemctl stop nosotros.service
fi

# ------------------------------------------------------------------ PocketBase
ACTUAL=""
[[ -x $EXE ]] && ACTUAL="$("$EXE" --version | awk '{print $NF}')"
if [[ $ACTUAL != "$VERSION" ]]; then
    paso "Descargando PocketBase v$VERSION"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    BASE="https://github.com/pocketbase/pocketbase/releases/download/v$VERSION"
    ZIP="pocketbase_${VERSION}_linux_amd64.zip"
    curl -fsSL -o "$TMP/$ZIP" "$BASE/$ZIP"
    curl -fsSL -o "$TMP/checksums.txt" "$BASE/checksums.txt"
    ( cd "$TMP" && grep -E "[[:space:]]$ZIP\$" checksums.txt | sha256sum --check --status ) \
        || error "El SHA-256 no coincide. Se cancela."
    echo "    SHA-256 verificado"
    unzip -q -o "$TMP/$ZIP" pocketbase -d "$TMP"
    install -m 0755 "$TMP/pocketbase" "$EXE"
else
    paso "PocketBase v$VERSION ya instalado"
fi

# ------------------------------------------------------------------ frontend + migraciones
paso "Copiando frontend y migraciones"
for carpeta in pb_public pb_migrations; do
    rsync -a --delete --chown=root:"$USUARIO_SRV" --chmod=D0750,F0640 "$APP/$carpeta/" "$DESTINO/$carpeta/"
done

# ------------------------------------------------------------------ datos existentes (opcional)
if [[ -n $DATOS_DESDE ]]; then
    if [[ -f $DATOS/data.db ]]; then
        RESPALDO="$DATOS.antes-$(date +%Y%m%d-%H%M%S)"
        paso "Ya había datos: se mueven a $RESPALDO"
        mv "$DATOS" "$RESPALDO"
    fi
    paso "Importando datos desde $DATOS_DESDE"
    rsync -a "$DATOS_DESDE/" "$DATOS/"
fi
chown -R "$USUARIO_SRV:$USUARIO_SRV" "$DATOS"

paso "Aplicando migraciones"
runuser -u "$USUARIO_SRV" -- "$EXE" migrate up --dir "$DATOS" --migrationsDir "$DESTINO/pb_migrations"

# ------------------------------------------------------------------ servicio
paso "Servicio systemd"
sed -e "s|@DESTINO@|$DESTINO|g" -e "s|@PUERTO@|$PUERTO|g" -e "s|@USUARIO@|$USUARIO_SRV|g" \
    "$AQUI/nosotros.service" > /etc/systemd/system/nosotros.service
systemctl daemon-reload
systemctl enable --now nosotros.service >/dev/null 2>&1

# ------------------------------------------------------------------ firewall
paso "Firewall: puerto $PUERTO solo desde Meshnet ($RANGO_MESHNET)"
ufw allow from "$RANGO_MESHNET" to any port "$PUERTO" proto tcp comment 'nosotros' >/dev/null

# ------------------------------------------------------------------ comprobación
paso "Comprobando que responde"
for _ in $(seq 15); do
    if curl -fsS "http://127.0.0.1:$PUERTO/api/health" >/dev/null 2>&1; then OK=1; break; fi
    sleep 1
done
[[ ${OK:-0} == 1 ]] || error "PocketBase no responde. Mirá los logs: journalctl -u nosotros -e"

IP_MESH="$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep '^100\.' | head -n1 || true)"
printf '\n\e[1;32mListo! Nosotros corre y arranca solo con el sistema.\e[0m\n'
if [[ -n $IP_MESH ]]; then
    echo "  App:    http://$IP_MESH:$PUERTO"
    echo "  Panel:  http://$IP_MESH:$PUERTO/_/"
else
    aviso "Meshnet todavía no está activo: la app solo responde en este equipo."
fi
echo "  Logs:   journalctl -u nosotros -f"
if [[ -z $DATOS_DESDE ]]; then
    echo
    echo "Si es una instalación nueva (sin datos importados), creá el superusuario con:"
    echo "  sudo -u $USUARIO_SRV $EXE superuser upsert TU_EMAIL 'TU_CONTRASEÑA' --dir $DATOS"
fi
