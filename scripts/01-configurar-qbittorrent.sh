#!/usr/bin/env bash
# =====================================================================
#  Configuración automática de qBittorrent
#  - Reemplaza la contraseña temporal por tu usuario y contraseña
#  - Carpeta de descargas, cola, límite de compartición, puerto
#  - Dominios permitidos (para que Radarr/Sonarr se conecten por nombre)
#  - Categorías movies, tv y music
#  Uso:  sudo bash scripts/01-configurar-qbittorrent.sh
# =====================================================================

source "$(dirname "$0")/lib.sh"

QB=http://localhost:8080
JAR=$(mktemp); trap 'rm -f "$JAR"' EXIT

[ -z "${QB_USER+x}" ] && read -rp "Usuario nuevo para qBittorrent: " QB_USER
[ -z "${QB_PASS+x}" ] && { read -rsp "Contraseña nueva para qBittorrent: " QB_PASS; echo; }

login() { # usuario contraseña -> 0 si entra
  local code
  code=$(curl -s -c "$JAR" -o /tmp/qb_login -w "%{http_code}" \
    --data-urlencode "username=$1" --data-urlencode "password=$2" "$QB/api/v2/auth/login")
  { [ "$code" = "200" ] || [ "$code" = "204" ]; } && ! grep -qi "fails" /tmp/qb_login
}

info "qBittorrent"
echo "Esperando a que qBittorrent responda..."
for i in $(seq 1 40); do curl -s -o /dev/null "$QB" && break; sleep 3; done

if login "$QB_USER" "$QB_PASS"; then
  ok "Ya estaba configurado con tu usuario"
else
  TMP=""
  for i in $(seq 1 40); do
    TMP=$(docker logs qbittorrent 2>&1 | grep -i "temporary password" | tail -1 | sed 's/.*: *//' | tr -d '[:space:]')
    [ -n "$TMP" ] && break; sleep 3
  done
  if [ -z "$TMP" ] || ! login admin "$TMP"; then
    err "No se pudo entrar a qBittorrent (ni con tu usuario ni con la contraseña temporal)."
    echo "  Si ya tenía otra contraseña, borrá su configuración y reintentá:"
    echo "  sudo docker compose stop qbittorrent && sudo rm -rf $APPDATA/qbittorrent/* && sudo docker compose up -d qbittorrent"
    exit 1
  fi
  ok "Sesión iniciada con la contraseña temporal"
fi

PREFS=$(jq -n --arg u "$QB_USER" --arg p "$QB_PASS" --arg d "localhost;qbittorrent;$SERVER_IP" '{
  web_ui_username:$u, web_ui_password:$p,
  web_ui_host_header_validation_enabled:true, web_ui_domain_list:$d,
  save_path:"/data/torrents", temp_path_enabled:false, auto_tmm_enabled:true,
  listen_port:6881, upnp:false,
  queueing_enabled:true, max_active_downloads:3, max_active_uploads:3, max_active_torrents:5,
  max_ratio_enabled:true, max_ratio:1, max_ratio_act:0 }')
curl -s -b "$JAR" -o /dev/null --data-urlencode "json=$PREFS" "$QB/api/v2/app/setPreferences"

if login "$QB_USER" "$QB_PASS"; then ok "Usuario y contraseña guardados"
else err "No se pudo confirmar el nuevo usuario"; exit 1; fi
ok "Descargas en /data/torrents, máximo 3 a la vez, se pausan al compartir 1:1"
ok "Dominios permitidos: localhost, qbittorrent, $SERVER_IP"

for c in movies tv music; do
  curl -s -b "$JAR" -o /dev/null --data-urlencode "category=$c" --data-urlencode "savePath=/data/torrents/$c" \
    "$QB/api/v2/torrents/createCategory"
done
CATS=$(curl -s -b "$JAR" "$QB/api/v2/torrents/categories" | jq -r 'keys | join(", ")')
ok "Categorías: $CATS"

# Comprobación desde otro contenedor (como lo hará Radarr)
CODE=$(docker exec radarr curl -s -o /dev/null -w "%{http_code}" \
  --data-urlencode "username=$QB_USER" --data-urlencode "password=$QB_PASS" \
  http://qbittorrent:8080/api/v2/auth/login 2>/dev/null)
{ [ "$CODE" = "200" ] || [ "$CODE" = "204" ]; } && ok "Radarr puede conectarse a qBittorrent" \
  || err "Radarr no pudo conectarse a qBittorrent (código $CODE)"
