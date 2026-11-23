#!/usr/bin/env bash
# =====================================================================
#  Instalador del servidor multimedia automatizado
#  Levanta todos los contenedores y los configura en orden.
#  Uso:  sudo bash install.sh
#  Se puede ejecutar varias veces: lo que ya está hecho se respeta.
# =====================================================================
set -u
cd "$(dirname "$0")"
ROOT=$(pwd)

ok()   { echo -e "  \e[32m✔\e[0m $1"; }
err()  { echo -e "  \e[31m✘\e[0m $1"; }
info() { echo -e "\n\e[1;36m══ $1\e[0m"; }

[ "$(id -u)" -ne 0 ] && { echo "Ejecutalo con sudo:  sudo bash install.sh"; exit 1; }

# ---------- 1. Requisitos ----------
info "1/4  Requisitos"
apt-get update -qq >/dev/null
for p in curl jq; do command -v $p >/dev/null || apt-get install -y -qq $p >/dev/null; done
if ! command -v docker >/dev/null; then
  echo "  Instalando Docker desde los repositorios del sistema..."
  apt-get install -y -qq docker.io >/dev/null
fi
docker compose version >/dev/null 2>&1 || apt-get install -y -qq docker-compose-v2 >/dev/null
systemctl enable --now docker >/dev/null 2>&1
docker compose version >/dev/null 2>&1 && ok "Docker $(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')" \
  || { err "No se pudo instalar Docker Compose"; exit 1; }

# ---------- 2. Configuración (.env) ----------
info "2/4  Configuración"
[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a
if [ -z "${SERVER_IP:-}" ]; then
  SERVER_IP=$(hostname -I | awk '{print $1}')
  sed -i "s/^SERVER_IP=.*/SERVER_IP=$SERVER_IP/" .env
fi
ok "IP del servidor: $SERVER_IP   (carpeta de datos: $DATA_DIR)"

echo
echo "  Elegí los usuarios y contraseñas. Se usan solo durante la instalación"
echo "  y no se guardan en ningún archivo."
read -rp  "  Usuario para qBittorrent: " QB_USER
read -rsp "  Contraseña para qBittorrent: " QB_PASS; echo
read -rp  "  Usuario para Jellyfin (también es el de Seerr y Moonfin): " JF_USER
read -rsp "  Contraseña para Jellyfin: " JF_PASS; echo
echo "  OpenSubtitles.com es opcional pero recomendado (cuenta gratis, NO la de opensubtitles.org)."
read -rp  "  Usuario de OpenSubtitles.com (Enter para omitir): " OS_USER
OS_PASS=""
[ -n "$OS_USER" ] && { read -rsp "  Contraseña de OpenSubtitles.com: " OS_PASS; echo; }
read -rp  "  ¿Instalar el plugin Moonbase para la app Moonfin en la TV? (s/n): " MOON
read -rp  "  ¿Sincronizar tu YouTube Music (Me gusta y playlists)? (s/n): " YTM
export QB_USER QB_PASS JF_USER JF_PASS OS_USER OS_PASS

# ---------- 3. Carpetas y contenedores ----------
info "3/4  Carpetas y contenedores"
mkdir -p "$DATA_DIR"/data/{torrents/{movies,tv,music},media/{movies,tv,music}}
mkdir -p "$DATA_DIR"/AppData/{jellyfin,qbittorrent,prowlarr,radarr,sonarr,lidarr,bazarr,seerr}
chown -R "$PUID:$PGID" "$DATA_DIR/data" "$DATA_DIR/AppData"
ok "Carpetas en $DATA_DIR"
[ -e /dev/dri ] || { sed -i 's#^\(\s*\)- /dev/dri:/dev/dri#\1\# - /dev/dri:/dev/dri#' docker-compose.yml; sed -i 's#^\(\s*\)devices:#\1\# devices:#' docker-compose.yml; }
[[ "${MUSICA:-no}" == si* ]] && export COMPOSE_PROFILES=musica && ok "Música activada (Lidarr)"
echo "  Descargando e iniciando contenedores (la primera vez tarda varios minutos)..."
docker compose up -d >/dev/null 2>&1 && ok "Contenedores iniciados" || { err "Falló docker compose up. Probá: sudo docker compose up -d"; exit 1; }

echo "  Esperando a que todas las apps generen su configuración..."
for i in $(seq 1 60); do
  faltan=0
  APPS="radarr sonarr prowlarr"; [[ "${MUSICA:-no}" == si* ]] && APPS="$APPS lidarr"
  for a in $APPS; do [ -f "$DATA_DIR/AppData/$a/config.xml" ] || faltan=1; done
  curl -s -o /dev/null http://localhost:8096/System/Info/Public || faltan=1
  curl -s -o /dev/null http://localhost:5055/api/v1/status || faltan=1
  [ $faltan -eq 0 ] && break; sleep 5
done
sleep 10
ok "Apps listas"

# ---------- 4. Configuración automática ----------
info "4/4  Configuración automática"
PASOS=(01-configurar-qbittorrent 02-configurar-arr 03-configurar-flaresolverr 04-agregar-indexadores
       05-configurar-jellyfin 06-configurar-seerr 07-configurar-idioma 08-configurar-final
       09-instalar-automatizacion)
[[ "${MOON,,}" == s* ]] && PASOS+=(10-instalar-moonbase)
[[ "${YTM,,}"  == s* ]] && PASOS+=(12-instalar-ytmusic)
for p in "${PASOS[@]}"; do
  echo -e "\n\e[1m▶ $p\e[0m"
  bash "scripts/$p.sh" || err "$p terminó con errores (se puede repetir: sudo bash scripts/$p.sh)"
done
unset QB_PASS JF_PASS OS_PASS

cat << FIN

$(echo -e "\e[1;32m══ Instalación terminada\e[0m")

  Pedir películas y series ...... http://$SERVER_IP:5055   (Seerr)
  Ver ........................... http://$SERVER_IP:8096   (Jellyfin) o la app Moonfin
  Descargas ..................... http://$SERVER_IP:8080   (qBittorrent)
  Películas / Series ............ http://$SERVER_IP:7878 · http://$SERVER_IP:8989
  Indexadores / Subtítulos ...... http://$SERVER_IP:9696 · http://$SERVER_IP:6767

  Radarr, Sonarr, Prowlarr y Bazarr piden crear usuario la primera vez
  que los abrís en el navegador.

  Registro del vigilante:  sudo tail -20 /var/log/media-vigilante.log
  Registro de YT Music:    sudo tail -20 /var/log/ytmusic-sync.log
FIN
