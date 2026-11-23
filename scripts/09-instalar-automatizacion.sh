#!/usr/bin/env bash
# =====================================================================
#  Automatización total del servidor multimedia
#   1. Bazarr avisa a Jellyfin al bajar subtítulos y limpia etiquetas [música]
#   2. Jellyfin revisa la biblioteca cada hora (red de seguridad)
#   3. Instala el "vigilante": revisa y repara todo cada 15 minutos
#  Uso:  sudo bash scripts/09-instalar-automatizacion.sh
# =====================================================================

source "$(dirname "$0")/lib.sh"

JF=http://localhost:8096
BAZARR=http://localhost:6767
CLIENTE='MediaBrowser Client="Script", Device="Servidor", DeviceId="script-config", Version="1.0"'

ok()   { echo -e "  \e[32m✔\e[0m $1"; }
err()  { echo -e "  \e[31m✘\e[0m $1"; }
info() { echo -e "\n\e[1m$1\e[0m"; }

[ "$(id -u)" -ne 0 ] && { echo "Ejecutalo con sudo"; exit 1; }
command -v jq >/dev/null || apt-get install -y jq >/dev/null

[ -z "${JF_USER+x}" ] && read -rp "Usuario de Jellyfin: " JF_USER
[ -z "${JF_PASS+x}" ] && { read -rsp "Contraseña de Jellyfin: " JF_PASS; echo; }

# ---------- Sesión y API key de Jellyfin ----------
info "Jellyfin"
TOKEN=$(curl -s -X POST "$JF/Users/AuthenticateByName" \
  -H "Authorization: $CLIENTE" -H "Content-Type: application/json" \
  -d "$(jq -n --arg u "$JF_USER" --arg p "$JF_PASS" '{Username:$u, Pw:$p}')" | jq -r '.AccessToken // empty')
[ -z "$TOKEN" ] && { err "No se pudo iniciar sesión en Jellyfin"; exit 1; }
AUTH="$CLIENTE, Token=\"$TOKEN\""

jfkey() { curl -s -H "Authorization: $AUTH" "$JF/Auth/Keys" | jq -r --arg a "$1" '.Items[]? | select(.AppName==$a) | .AccessToken' | head -1; }
JF_KEY=$(jfkey Bazarr)
if [ -z "$JF_KEY" ]; then
  curl -s -o /dev/null -X POST -H "Authorization: $AUTH" "$JF/Auth/Keys?app=Bazarr"
  JF_KEY=$(jfkey Bazarr)
fi
[ -n "$JF_KEY" ] && ok "API key para Bazarr" || { err "No se pudo crear la API key"; exit 1; }

# ---------- Escaneo de biblioteca cada hora ----------
TASK_ID=$(curl -s -H "Authorization: $AUTH" "$JF/ScheduledTasks" | jq -r '.[] | select(.Key=="RefreshLibrary") | .Id')
if [ -n "$TASK_ID" ]; then
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Authorization: $AUTH" -H "Content-Type: application/json" \
    -d '[{"Type":"IntervalTrigger","IntervalTicks":36000000000}]' "$JF/ScheduledTasks/$TASK_ID/Triggers")
  [ "$CODE" = "204" ] || [ "$CODE" = "200" ] && ok "Escaneo de biblioteca: cada 1 hora" || err "Escaneo programado (código $CODE)"
else
  err "No se encontró la tarea de escaneo de biblioteca"
fi
curl -s -o /dev/null -X POST -H "Authorization: $AUTH" "$JF/Library/Refresh"
ok "Escaneo inmediato lanzado (para que aparezca el subtítulo de hoy)"

# ---------- Bazarr: avisar a Jellyfin y limpiar subtítulos ----------
info "Bazarr"
BZ_CONF=$(find "$APPDATA/bazarr" -name config.yaml 2>/dev/null | head -1)
BZ_KEY=$(grep -A10 '^auth:' "$BZ_CONF" 2>/dev/null | sed -n 's/^ *apikey: *//p' | tr -d "'\"" | head -1)
if [ -z "$BZ_KEY" ]; then
  err "No se encontró la API key de Bazarr (¿está encendido?)"
else
  CMD="curl -s -X POST http://jellyfin:8096/Library/Refresh?ApiKey=$JF_KEY"
  curl -s -o /dev/null -X POST -H "X-API-KEY: $BZ_KEY" "$BAZARR/api/system/settings" \
    --form-string "settings-general-use_postprocessing=true" \
    --form-string "settings-general-postprocessing_cmd=$CMD" \
    --form-string "settings-general-use_postprocessing_threshold=false" \
    --form-string "settings-general-use_postprocessing_threshold_movie=false" \
    --form-string "subzero-remove_HI=true"
  CONF=$(curl -s -H "X-API-KEY: $BZ_KEY" "$BAZARR/api/system/settings")
  echo "$CONF" | jq -e '.general.use_postprocessing == true' >/dev/null 2>&1 \
    && ok "Al bajar un subtítulo, Jellyfin se actualiza solo" || err "Post-procesamiento no quedó activo"
  echo "$CONF" | jq -e '.general.subzero_mods | index("remove_HI")' >/dev/null 2>&1 \
    && ok "Limpieza automática de etiquetas [música], [risas], etc." || err "Limpieza de etiquetas no quedó activa"
fi

# ---------- El vigilante ----------
info "Vigilante (revisión cada 15 minutos)"
cat > /usr/local/bin/media-vigilante.sh << 'VIG'
#!/usr/bin/env bash
# Vigilante del servidor multimedia. Lo ejecuta systemd cada 15 minutos.
LOG=/var/log/media-vigilante.log
STATE=/var/lib/media-vigilante
APPDATA=__APPDATA__
mkdir -p "$STATE"
[ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 1048576 ] && tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
getkey() { sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$APPDATA/$1/config.xml" 2>/dev/null; }

# 1. Contenedores que deben estar siempre encendidos
SERVICIOS="__SERVICIOS__"
for c in $SERVICIOS; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != "true" ]; then
    docker start "$c" >/dev/null 2>&1 && log "Contenedor $c estaba apagado: encendido"
  fi
done

# 2. Servicios que no responden (2 fallos seguidos = reinicio)
check() { # nombre url
  local code f="$STATE/$1.fallos"
  code=$(curl -s -o /dev/null -m 60 -w "%{http_code}" "$2")
  if [ "$code" = "000" ]; then
    echo $(( $(cat "$f" 2>/dev/null || echo 0) + 1 )) > "$f"
    if [ "$(cat "$f")" -ge 2 ]; then
      docker restart "$1" >/dev/null 2>&1; echo 0 > "$f"; log "$1 no respondía: reiniciado"
    fi
  else
    echo 0 > "$f"
  fi
}
check jellyfin     http://localhost:8096/System/Info/Public
check qbittorrent  http://localhost:8080
check prowlarr     http://localhost:9696/ping
check radarr       http://localhost:7878/ping
check sonarr       http://localhost:8989/ping
check seerr        http://localhost:5055/api/v1/status
check bazarr       http://localhost:6767
check flaresolverr http://localhost:8191
echo " $SERVICIOS " | grep -q " lidarr " && check lidarr http://localhost:8686/ping

# 3. Reactivar indexadores desactivados por fallos
reactivar() { # nombre base key version
  local st ids
  st=$(curl -s -m 30 -H "X-Api-Key: $3" "$2/api/$4/indexerstatus")
  ids=$(echo "$st" | jq -r --arg now "$(date -u +%FT%T)" '.[]? | select((.disabledTill // "") > $now) | .indexerId' 2>/dev/null)
  for id in $ids; do
    local def code
    def=$(curl -s -m 30 -H "X-Api-Key: $3" "$2/api/$4/indexer/$id")
    code=$(curl -s -m 180 -o /dev/null -w "%{http_code}" -X POST -H "X-Api-Key: $3" \
           -H "Content-Type: application/json" -d "$def" "$2/api/$4/indexer/test")
    [ "$code" = "200" ] && log "$1: indexador $(echo "$def" | jq -r .name) reactivado" \
                        || log "$1: indexador $(echo "$def" | jq -r .name) sigue fallando (código $code)"
  done
}
reactivar Prowlarr http://localhost:9696 "$(getkey prowlarr)" v1
reactivar Radarr   http://localhost:7878 "$(getkey radarr)"   v3
reactivar Sonarr   http://localhost:8989 "$(getkey sonarr)"   v3

# 4. Búsqueda nocturna de pendientes y mejoras (una vez entre 04:00 y 04:14)
if [ "$(date +%H)" = "04" ] && [ "$(date +%M)" -lt 15 ]; then
  RK=$(getkey radarr); SK=$(getkey sonarr)
  for cmd in MissingMoviesSearch CutOffUnmetMoviesSearch; do
    curl -s -m 30 -o /dev/null -X POST -H "X-Api-Key: $RK" -H "Content-Type: application/json" \
      -d "{\"name\":\"$cmd\"}" http://localhost:7878/api/v3/command
  done
  for cmd in MissingEpisodeSearch CutoffUnmetEpisodeSearch; do
    curl -s -m 30 -o /dev/null -X POST -H "X-Api-Key: $SK" -H "Content-Type: application/json" \
      -d "{\"name\":\"$cmd\"}" http://localhost:8989/api/v3/command
  done
  log "Búsqueda nocturna de pendientes y mejoras lanzada"
fi

# 5. Espacio en disco
LIBRE=$(df -BG --output=avail __DATA_DIR__ | tail -1 | tr -dc '0-9')
[ "$LIBRE" -lt 20 ] && log "ATENCIÓN: quedan solo ${LIBRE} GB libres en disco"
exit 0
VIG
SERVICIOS="jellyfin qbittorrent prowlarr radarr sonarr seerr flaresolverr bazarr"
[[ "${MUSICA:-no}" == si* ]] && SERVICIOS="$SERVICIOS lidarr"
sed -i "s#__APPDATA__#$APPDATA#; s#__DATA_DIR__#$DATA_DIR#; s#__SERVICIOS__#$SERVICIOS#" /usr/local/bin/media-vigilante.sh
chmod +x /usr/local/bin/media-vigilante.sh

cat > /etc/systemd/system/media-vigilante.service << 'UNIT'
[Unit]
Description=Vigilante del servidor multimedia
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/media-vigilante.sh
UNIT

cat > /etc/systemd/system/media-vigilante.timer << 'UNIT'
[Unit]
Description=Ejecuta el vigilante del servidor multimedia cada 15 minutos

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now media-vigilante.timer >/dev/null 2>&1
if systemctl is-active --quiet media-vigilante.timer; then
  ok "Vigilante instalado y activo"
  systemctl start media-vigilante.service
  ok "Primera revisión ejecutada"
else
  err "El temporizador no quedó activo"
fi

info "Listo."
echo "  • Ver lo que hizo el vigilante:   sudo tail -20 /var/log/media-vigilante.log"
echo "  • Ver cuándo vuelve a correr:     systemctl list-timers media-vigilante.timer"
