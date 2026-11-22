#!/usr/bin/env bash
# Corre en TU PC (no en el servidor). Compila el frontend de SJ, sube todo y
# ejecuta instalar.sh en el servidor (te va a pedir la contraseña de sudo de allá).
#
#   services/nosotros/deploy.sh               # instalar / actualizar
#   services/nosotros/deploy.sh --con-datos   # además, llevar el pb_data local (fotos, usuarios…)
#
# Variables opcionales:  HOST (default: servidor, el alias de ~/.ssh/config)
#                        SJ   (default: ~/Projects/SJ)
set -euo pipefail

HOST="${HOST:-servidor}"
SJ="${SJ:-$HOME/Projects/SJ}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REMOTO="homeserver"                       # carpeta en el home del servidor
APP="$REMOTO/services/nosotros/app"

paso() { printf '\n\e[1;36m==> %s\e[0m\n' "$*"; }

CON_DATOS=0
case "${1:-}" in
    "") ;;
    --con-datos) CON_DATOS=1 ;;
    *) echo "Opción desconocida: $1" >&2; exit 1 ;;
esac

[[ -d $SJ/web ]] || { echo "No encuentro el repo SJ en $SJ (usá SJ=/ruta)." >&2; exit 1; }

paso "Compilando el frontend"
( cd "$SJ/web" && pnpm build )

# Caddy con el plugin de DuckDNS, compilado acá con xcaddy (la vía oficial para plugins;
# el servidor de builds de caddyserver.com es solo para descargas a mano).
# Para actualizar: subí estas versiones y volvé a correr deploy.sh.
CADDY_VERSION="v2.11.9"
DUCKDNS_VERSION="v0.5.0"
XCADDY_VERSION="v0.4.7"
CADDY_BIN="$REPO/services/nosotros/caddy/bin/caddy"     # ignorado por git
if ! { [[ -x $CADDY_BIN ]] \
       && "$CADDY_BIN" version | grep -q "^$CADDY_VERSION " \
       && "$CADDY_BIN" list-modules --versions | grep -qx "dns.providers.duckdns $DUCKDNS_VERSION"; }; then
    command -v go >/dev/null || { echo "Falta Go para compilar Caddy (pacman -S go)." >&2; exit 1; }
    paso "Compilando Caddy $CADDY_VERSION + duckdns $DUCKDNS_VERSION"
    mkdir -p "$(dirname "$CADDY_BIN")"
    GOOS=linux GOARCH=amd64 CGO_ENABLED=0 \
        go run "github.com/caddyserver/xcaddy/cmd/xcaddy@$XCADDY_VERSION" build "$CADDY_VERSION" \
        --with "github.com/caddy-dns/duckdns@$DUCKDNS_VERSION" --output "$CADDY_BIN"
fi

paso "Subiendo scripts y app a $HOST:~/$REMOTO"
rsync -az --delete --exclude .git --exclude 'services/nosotros/app/' "$REPO/" "$HOST:$REMOTO/"
ssh "$HOST" "mkdir -p $APP"
rsync -az --delete "$SJ/server/pb_public/"     "$HOST:$APP/pb_public/"
rsync -az --delete "$SJ/server/pb_migrations/" "$HOST:$APP/pb_migrations/"

ARGS=""
if (( CON_DATOS )); then
    if systemctl --user is-active --quiet nosotros 2>/dev/null; then
        paso "Deteniendo el servidor de prueba local (para copiar la base sin corromperla)"
        systemctl --user stop nosotros
    fi
    paso "Subiendo pb_data"
    rsync -az --delete "$SJ/server/pb_data/" "$HOST:$APP/pb_data/"
    ARGS="--datos-desde \$HOME/$APP/pb_data"
fi

paso "Instalando en el servidor"
ssh -t "$HOST" "sudo bash $REMOTO/services/nosotros/instalar.sh $ARGS"

if (( CON_DATOS )); then
    ssh "$HOST" "rm -rf $APP/pb_data"   # la copia temporal; los datos ya están en /srv/nosotros
fi
