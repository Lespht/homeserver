#!/usr/bin/env bash
# Corre en TU PC (no en el servidor). Compila el frontend de SJ, sube todo y
# ejecuta instalar.sh en el servidor (te va a pedir la contraseña de sudo de allá).
#
#   services/nosotros/deploy.sh               # instalar / actualizar
#   services/nosotros/deploy.sh --con-datos   # además, llevar el pb_data local (fotos, usuarios…)
#   services/nosotros/deploy.sh --claves      # además, reinstalar las claves de avisos (SJ/avisos/.env)
#
# Las claves de avisos se suben solas la primera vez (si el servidor no las tiene);
# después un deploy normal no las toca.
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
CLAVES=0
for opcion in "$@"; do
    case "$opcion" in
        --con-datos) CON_DATOS=1 ;;
        --claves)    CLAVES=1 ;;
        *) echo "Opción desconocida: $opcion" >&2; exit 1 ;;
    esac
done

[[ -d $SJ/web ]] || { echo "No encuentro el repo SJ en $SJ (usá SJ=/ruta)." >&2; exit 1; }
[[ -d $SJ/server/pb_hooks && -f $SJ/avisos/pnpm-lock.yaml ]] \
    || { echo "Faltan SJ/server/pb_hooks o SJ/avisos. ¿Estás en la rama correcta de SJ?" >&2; exit 1; }

# Las mismas claves del PC (la pública va compilada en la app): nunca se generan otras.
ENV_AVISOS="$SJ/avisos/.env"
CLAVES_REMOTO="$REMOTO/.claves-avisos.env"
if (( ! CLAVES )) && ! ssh "$HOST" test -f /etc/nosotros/avisos.env; then
    echo "El servidor todavía no tiene las claves de avisos: se van a instalar."
    CLAVES=1
fi
if (( CLAVES )); then
    [[ -f $ENV_AVISOS ]] || { echo "No existe $ENV_AVISOS." >&2; exit 1; }
    for v in VAPID_PUBLICA VAPID_PRIVADA AVISOS_SECRETO; do
        grep -q "^$v=." "$ENV_AVISOS" || { echo "A $ENV_AVISOS le falta $v." >&2; exit 1; }
    done
fi

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
rsync -az --delete "$SJ/server/pb_hooks/"      "$HOST:$APP/pb_hooks/"

# Servicio de avisos: Node corre el TypeScript directo, no hay compilación. Las dependencias de
# producción se instalan acá desde el lockfile (planas, sin symlinks) y se suben ya resueltas:
# el servidor no necesita pnpm ni salir a npm. web-push es JS puro, sin módulos nativos.
paso "Preparando el servicio de avisos (dependencias de producción)"
AVISOS_TMP="$(mktemp -d)"
trap 'rm -rf "$AVISOS_TMP"' EXIT
cp "$SJ/avisos/package.json" "$SJ/avisos/pnpm-lock.yaml" "$AVISOS_TMP/"
rsync -a --exclude '*.test.ts' "$SJ/avisos/src/" "$AVISOS_TMP/src/"
( cd "$AVISOS_TMP" && pnpm install --prod --frozen-lockfile --ignore-scripts \
      --config.node-linker=hoisted --reporter=silent )
rsync -az --delete "$AVISOS_TMP/" "$HOST:$APP/avisos/"

ARGS=""
if (( CLAVES )); then
    paso "Subiendo las claves de avisos (solo legibles por vos hasta que instalar.sh las mueva)"
    rsync -a --chmod=F0600 "$ENV_AVISOS" "$HOST:$CLAVES_REMOTO"
    ARGS="--claves \$HOME/$CLAVES_REMOTO"
fi
if (( CON_DATOS )); then
    if systemctl --user is-active --quiet nosotros 2>/dev/null; then
        paso "Deteniendo el servidor de prueba local (para copiar la base sin corromperla)"
        systemctl --user stop nosotros
    fi
    paso "Subiendo pb_data"
    rsync -az --delete "$SJ/server/pb_data/" "$HOST:$APP/pb_data/"
    ARGS="$ARGS --datos-desde \$HOME/$APP/pb_data"
fi

paso "Instalando en el servidor"
# Si instalar.sh falla, la copia temporal de las claves se borra igual.
ssh -t "$HOST" "sudo bash $REMOTO/services/nosotros/instalar.sh $ARGS" || {
    (( CLAVES )) && ssh "$HOST" "rm -f $CLAVES_REMOTO"
    exit 1
}

if (( CON_DATOS )); then
    ssh "$HOST" "rm -rf $APP/pb_data"   # la copia temporal; los datos ya están en /srv/nosotros
fi
