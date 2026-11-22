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
# HTTPS (Caddy con el plugin de DuckDNS). El token y el dominio los cargás a mano: ver README.
CADDY_EXE="/usr/local/bin/caddy"
CADDY_ENV="/etc/caddy/duckdns.env"

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$AQUI/app"            # lo llena deploy.sh: pb_public/ y pb_migrations/
EXE="$DESTINO/pocketbase"
DATOS="$DESTINO/pb_data"
CADDY_NUEVO="$AQUI/caddy/bin/caddy"    # lo compila y sube deploy.sh

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
        paso "Quitando Caddy y su regla de firewall"
        systemctl disable --now caddy.service 2>/dev/null || true
        rm -f /etc/systemd/system/caddy.service "$CADDY_EXE" /etc/caddy/Caddyfile
        systemctl daemon-reload
        ufw delete allow from "$RANGO_MESHNET" to any port 443 proto tcp >/dev/null 2>&1 || true
        echo "Listo. Los archivos en $DESTINO (incluidos los datos) se mantienen."
        echo "También quedan $CADDY_ENV y los certificados en /var/lib/caddy."
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
# HTTPS es la única entrada (PocketBase solo escucha en localhost): sin token no se sigue.
[[ -f $CADDY_ENV ]] || error "Falta $CADDY_ENV (dominio y token de DuckDNS). Ver README, sección HTTPS."
# Solo se lee el dominio; el token no pasa por este script.
DOMINIO="$(sed -n 's/^DOMINIO=//p' "$CADDY_ENV" | head -n1)"
[[ -n $DOMINIO ]] || error "$CADDY_ENV no tiene la línea DOMINIO=..."
[[ -f $CADDY_NUEVO ]] || error "No existe $CADDY_NUEVO. Usá deploy.sh desde tu PC."

# Se mira antes de importar o migrar: decide si al final se avisa de crear el superusuario.
HABIA_DATOS=0
[[ -f $DATOS/data.db ]] && HABIA_DATOS=1

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

# ------------------------------------------------------------------ copia antes de migrar
# El servicio ya está detenido, así que copiar el archivo es seguro. Las fotos no se
# copian: las migraciones no las tocan. Se guardan las últimas $COPIAS_A_GUARDAR.
# Van fuera de pb_data para que no entren en los backups zip de PocketBase.
COPIAS_A_GUARDAR=5
ANTES_MIGRAR="$DESTINO/antes-migrar"
if [[ -f $DATOS/data.db ]]; then
    COPIA="$ANTES_MIGRAR/data-$(date +%Y%m%d-%H%M%S).db"
    paso "Copiando la base antes de migrar"
    install -d -m 0750 -o "$USUARIO_SRV" -g "$USUARIO_SRV" "$ANTES_MIGRAR"
    for sufijo in "" -wal -shm; do
        [[ -f $DATOS/data.db$sufijo ]] || continue
        install -m 0640 -o "$USUARIO_SRV" -g "$USUARIO_SRV" "$DATOS/data.db$sufijo" "$COPIA$sufijo"
    done
    echo "    Copia en $COPIA"
    shopt -s nullglob
    copias=("$ANTES_MIGRAR"/data-*.db)     # orden alfabético = cronológico
    shopt -u nullglob
    if (( ${#copias[@]} > COPIAS_A_GUARDAR )); then
        for vieja in "${copias[@]:0:${#copias[@]}-COPIAS_A_GUARDAR}"; do
            rm -f -- "$vieja" "$vieja-wal" "$vieja-shm"
        done
    fi
fi

paso "Aplicando migraciones"
# Desde un directorio al que el usuario del servicio pueda entrar (si no, avisa
# "Failed to retrieve the current working directory").
cd "$DESTINO"
runuser -u "$USUARIO_SRV" -- "$EXE" migrate up --dir "$DATOS" --migrationsDir "$DESTINO/pb_migrations"

# ------------------------------------------------------------------ servicio
paso "Servicio systemd"
sed -e "s|@DESTINO@|$DESTINO|g" -e "s|@PUERTO@|$PUERTO|g" -e "s|@USUARIO@|$USUARIO_SRV|g" \
    "$AQUI/nosotros.service" > /etc/systemd/system/nosotros.service
systemctl daemon-reload
systemctl enable --now nosotros.service >/dev/null 2>&1

# ------------------------------------------------------------------ firewall
# PocketBase solo escucha en 127.0.0.1: se entra por HTTPS (Caddy). Se quita la regla vieja del 8090.
ufw delete allow from "$RANGO_MESHNET" to any port "$PUERTO" proto tcp >/dev/null 2>&1 || true

# ------------------------------------------------------------------ comprobación
paso "Comprobando que responde"
for _ in $(seq 15); do
    if curl -fsS "http://127.0.0.1:$PUERTO/api/health" >/dev/null 2>&1; then OK=1; break; fi
    sleep 1
done
[[ ${OK:-0} == 1 ]] || error "PocketBase no responde. Mirá los logs: journalctl -u nosotros -e"

# ------------------------------------------------------------------ HTTPS (Caddy)
chown root:root "$CADDY_ENV"; chmod 0600 "$CADDY_ENV"

if ! id caddy &>/dev/null; then
    paso "Creando usuario de sistema 'caddy'"
    useradd --system --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy
fi

if [[ -x $CADDY_EXE ]] && cmp -s "$CADDY_NUEVO" "$CADDY_EXE"; then
    paso "Caddy ya instalado ($("$CADDY_EXE" version | awk '{print $1}'))"
else
    paso "Instalando Caddy"
    chmod 0755 "$CADDY_NUEVO"
    "$CADDY_NUEVO" list-modules | grep -qx 'dns.providers.duckdns' \
        || error "El binario subido no trae dns.providers.duckdns."
    install -m 0755 "$CADDY_NUEVO" "$CADDY_EXE"
    echo "    $("$CADDY_EXE" version | awk '{print $1}')"
fi

paso "Configurando Caddy para $DOMINIO"
install -D -m 0644 "$AQUI/caddy/Caddyfile" /etc/caddy/Caddyfile
install -m 0644 "$AQUI/caddy/caddy.service" /etc/systemd/system/caddy.service
if ! SALIDA="$("$CADDY_EXE" validate --config /etc/caddy/Caddyfile --adapter caddyfile --envfile "$CADDY_ENV" 2>&1)"; then
    printf '%s\n' "$SALIDA" | tail -n 5 >&2
    error "El Caddyfile no es válido."
fi
systemctl daemon-reload
systemctl enable caddy.service >/dev/null 2>&1
systemctl restart caddy.service

paso "Firewall: puerto 443 solo desde Meshnet ($RANGO_MESHNET)"
ufw allow from "$RANGO_MESHNET" to any port 443 proto tcp comment 'nosotros https' >/dev/null

paso "Comprobando HTTPS (la primera vez sacar el certificado puede tardar un par de minutos)"
OK_HTTPS=0
for _ in $(seq 60); do
    if curl -fsS --resolve "$DOMINIO:443:127.0.0.1" "https://$DOMINIO/api/health" >/dev/null 2>&1; then
        OK_HTTPS=1; break
    fi
    sleep 3
done
(( OK_HTTPS )) || aviso "HTTPS todavía no responde. Mirá los logs: journalctl -u caddy -e"

printf '\n\e[1;32mListo! Nosotros corre y arranca solo con el sistema.\e[0m\n'
echo "  App:    https://$DOMINIO   (solo con Meshnet activo)"
echo "  Panel:  https://$DOMINIO/_/"
echo "  Logs:   journalctl -u nosotros -f   ·   journalctl -u caddy -f"
if [[ $HABIA_DATOS == 0 && -z $DATOS_DESDE ]]; then
    echo
    echo "Instalación nueva: falta crear el superusuario. Desde el panel (recomendado):"
    echo "  PocketBase deja en el log un enlace de instalación de un solo uso:"
    echo "    journalctl -u nosotros | grep pbinstal"
    echo "  Abrilo cambiando http://127.0.0.1:$PUERTO por https://$DOMINIO y creá el usuario ahí."
    echo "  Si el enlace venció, 'sudo systemctl restart nosotros' genera uno nuevo."
    echo "Alternativa por consola (la contraseña queda en el historial del shell):"
    echo "  sudo -u $USUARIO_SRV $EXE superuser upsert TU_EMAIL 'TU_CONTRASEÑA' --dir $DATOS"
fi
