#!/usr/bin/env bash
# Corre en TU PC (lo lanza el timer nosotros-backup.timer).
# Trae los backups automáticos de PocketBase del servidor y guarda los últimos $DIAS días.
#
# Variables opcionales:  HOST    (default: servidor, el alias de ~/.ssh/config)
#                        DESTINO (default: ~/Backups/nosotros)
#                        DIAS    (default: 30)
set -euo pipefail

HOST="${HOST:-servidor}"
DESTINO="${DESTINO:-$HOME/Backups/nosotros}"
DIAS="${DIAS:-30}"
ORIGEN="/srv/nosotros/pb_data/backups/"

mkdir -p "$DESTINO"

# BatchMode: si la clave pide contraseña o el servidor no responde, falla en vez de quedarse colgado.
rsync -a --timeout=60 -e "ssh -o BatchMode=yes -o ConnectTimeout=15" "$HOST:$ORIGEN" "$DESTINO/"

# Rotación local: borra zips de más de $DIAS días (rsync -a conserva la fecha original).
find "$DESTINO" -maxdepth 1 -name '*.zip' -mtime +"$DIAS" -delete

TOTAL="$(find "$DESTINO" -maxdepth 1 -name '*.zip' | wc -l)"
RECIENTES="$(find "$DESTINO" -maxdepth 1 -name '*.zip' -mtime -2 | wc -l)"
echo "Backups en $DESTINO: $TOTAL (de las últimas 48 h: $RECIENTES)"

# Si el servidor dejó de generar backups, que el servicio quede en "failed" y se note.
if (( RECIENTES == 0 )); then
    echo "AVISO: no hay ningún backup de las últimas 48 h. ¿Están activados en el panel?" >&2
    exit 1
fi
