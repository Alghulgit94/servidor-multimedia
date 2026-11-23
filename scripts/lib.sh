#!/usr/bin/env bash
# Funciones y variables comunes. Lo cargan todos los scripts.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi
DATA_DIR="${DATA_DIR:-/DATA}"
APPDATA="$DATA_DIR/AppData"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
SERVER_IP="${SERVER_IP:-$(hostname -I | awk '{print $1}')}"

ok()   { echo -e "  \e[32m✔\e[0m $1"; }
err()  { echo -e "  \e[31m✘\e[0m $1"; }
info() { echo -e "\n\e[1m$1\e[0m"; }

if [ "$(id -u)" -ne 0 ]; then echo "Ejecutá este script con sudo"; exit 1; fi
command -v jq   >/dev/null || apt-get install -y jq   >/dev/null
command -v curl >/dev/null || apt-get install -y curl >/dev/null

getkey() { sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$APPDATA/$1/config.xml" 2>/dev/null; }
