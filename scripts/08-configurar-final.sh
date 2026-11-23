#!/usr/bin/env bash
# =====================================================================
#  Configuración final del servidor multimedia
#   1. Radarr/Sonarr avisan a Jellyfin al importar (aparece al instante)
#   2. Prefiere versiones latinas DUALES (latino + inglés)
#   3. Bazarr: subtítulos en español automáticos
#   4. Jellyfin: audio inglés, subtítulos español en modo Inteligente
#  Uso:  sudo bash scripts/08-configurar-final.sh
#  Se puede ejecutar varias veces sin duplicar nada.
# =====================================================================

source "$(dirname "$0")/lib.sh"

JF=http://localhost:8096
RADARR=http://localhost:7878
SONARR=http://localhost:8989
BAZARR=http://localhost:6767
CLIENTE='MediaBrowser Client="Script", Device="Servidor", DeviceId="script-config", Version="1.0"'

ok()   { echo -e "  \e[32m✔\e[0m $1"; }
err()  { echo -e "  \e[31m✘\e[0m $1"; }
info() { echo -e "\n\e[1m$1\e[0m"; }

command -v jq >/dev/null || apt-get install -y jq >/dev/null
getkey() { sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$APPDATA/$1/config.xml"; }
RADARR_KEY=$(getkey radarr)
SONARR_KEY=$(getkey sonarr)

arr() { # base key método ruta [json]
  if [ -n "$5" ]; then
    curl -sS -X "$3" -H "X-Api-Key: $2" -H "Content-Type: application/json" -d "$5" "$1$4"
  else
    curl -sS -X "$3" -H "X-Api-Key: $2" "$1$4"
  fi
}

[ -z "${JF_USER+x}" ] && read -rp "Usuario de Jellyfin: " JF_USER
[ -z "${JF_PASS+x}" ] && { read -rsp "Contraseña de Jellyfin: " JF_PASS; echo; }
[ -z "${OS_USER+x}" ] && { echo "OpenSubtitles.com es opcional (cuenta gratis). Dejá vacío para omitirlo."; read -rp "Usuario de OpenSubtitles.com: " OS_USER; }
if [ -n "$OS_USER" ] && [ -z "${OS_PASS+x}" ]; then read -rsp "Contraseña de OpenSubtitles: " OS_PASS; echo; fi

# ---------- Sesión en Jellyfin ----------
info "Jellyfin"
LOGIN=$(curl -s -X POST "$JF/Users/AuthenticateByName" \
  -H "Authorization: $CLIENTE" -H "Content-Type: application/json" \
  -d "$(jq -n --arg u "$JF_USER" --arg p "$JF_PASS" '{Username:$u, Pw:$p}')")
TOKEN=$(echo "$LOGIN" | jq -r '.AccessToken // empty')
JF_UID=$(echo "$LOGIN" | jq -r '.User.Id // empty')
[ -z "$TOKEN" ] && { err "No se pudo iniciar sesión en Jellyfin"; exit 1; }
AUTH="$CLIENTE, Token=\"$TOKEN\""
ok "Sesión iniciada"

# =====================================================================
# 1. Avisos de Radarr/Sonarr a Jellyfin
# =====================================================================
info "1. Avisos a Jellyfin"
JF_KEY=$(curl -s -H "Authorization: $AUTH" "$JF/Auth/Keys" | jq -r '.Items[]? | select(.AppName=="Arr") | .AccessToken' | head -1)
if [ -z "$JF_KEY" ]; then
  curl -s -o /dev/null -X POST -H "Authorization: $AUTH" "$JF/Auth/Keys?app=Arr"
  JF_KEY=$(curl -s -H "Authorization: $AUTH" "$JF/Auth/Keys" | jq -r '.Items[]? | select(.AppName=="Arr") | .AccessToken' | head -1)
fi
[ -n "$JF_KEY" ] && ok "API key de Jellyfin para Radarr/Sonarr" || err "No se pudo crear la API key"

add_notif() { # Nombre base key
  if arr "$2" "$3" GET /api/v3/notification | jq -e '.[] | select(.name=="Jellyfin")' >/dev/null 2>&1; then
    ok "$1 ya avisaba a Jellyfin"; return
  fi
  local payload resp
  payload=$(arr "$2" "$3" GET /api/v3/notification/schema | jq --arg k "$JF_KEY" '
    map(select(.implementation=="MediaBrowser"))[0]
    | .name="Jellyfin"
    | reduce ("onDownload","onUpgrade","onRename","onMovieDelete","onMovieFileDelete",
              "onSeriesDelete","onEpisodeFileDelete") as $e (.; if has($e) then .[$e]=true else . end)
    | .fields |= map(
        if   .name=="host"          then .value="jellyfin"
        elif .name=="port"          then .value=8096
        elif .name=="useSsl"        then .value=false
        elif .name=="apiKey"        then .value=$k
        elif .name=="notify"        then .value=false
        elif .name=="updateLibrary" then .value=true
        else . end)')
  resp=$(arr "$2" "$3" POST /api/v3/notification "$payload")
  if echo "$resp" | jq -e '.id' >/dev/null 2>&1; then ok "$1 avisará a Jellyfin al importar"
  else err "$1: $(echo "$resp" | jq -r '.[0].errorMessage // .message // .' 2>/dev/null | head -c 200)"; fi
}
[ -n "$JF_KEY" ] && { add_notif Radarr "$RADARR" "$RADARR_KEY"; add_notif Sonarr "$SONARR" "$SONARR_KEY"; }

# =====================================================================
# 2. Preferir versiones DUALES
# =====================================================================
info "2. Preferir audio dual (latino + inglés)"
add_dual() { # Nombre base key
  local id
  id=$(arr "$2" "$3" GET /api/v3/customformat | jq '.[] | select(.name=="Audio Dual") | .id')
  if [ -z "$id" ]; then
    id=$(arr "$2" "$3" POST /api/v3/customformat "$(jq -n '{
      name:"Audio Dual", includeCustomFormatWhenRenaming:false,
      specifications:[{ name:"Dual/Multi", implementation:"ReleaseTitleSpecification",
        negate:false, required:true, fields:[{name:"value", value:"\\b(dual|multi)\\b"}] }] }')" | jq '.id')
  fi
  if [ -z "$id" ] || [ "$id" = "null" ]; then err "$1: no se pudo crear Audio Dual"; return; fi
  local n=0
  for pid in $(arr "$2" "$3" GET /api/v3/qualityprofile | jq '.[].id'); do
    arr "$2" "$3" GET "/api/v3/qualityprofile/$pid" | jq --argjson d "$id" '
      .formatItems |= map(if .format==$d then .score=50 else . end)
      | .cutoffFormatScore=150 | .upgradeAllowed=true' > /tmp/perfil.json
    arr "$2" "$3" PUT "/api/v3/qualityprofile/$pid" "$(cat /tmp/perfil.json)" | jq -e '.id' >/dev/null 2>&1 && n=$((n+1))
  done
  rm -f /tmp/perfil.json
  ok "$1: Audio Dual (+50) en $n perfiles; latino dual = 150 puntos (la mejor opción)"
}
add_dual Radarr "$RADARR" "$RADARR_KEY"
add_dual Sonarr "$SONARR" "$SONARR_KEY"

# =====================================================================
# 3. Bazarr
# =====================================================================
info "3. Bazarr (subtítulos)"
cd "$ROOT" && docker compose up -d bazarr >/dev/null 2>&1
BZ_CONF=$(find "$APPDATA/bazarr" -name config.yaml 2>/dev/null | head -1)
for i in $(seq 1 40); do
  BZ_CONF=$(find "$APPDATA/bazarr" -name config.yaml 2>/dev/null | head -1)
  [ -n "$BZ_CONF" ] && curl -s -o /dev/null -w "%{http_code}" "$BAZARR" | grep -qE "200|302" && break
  sleep 3
done
BZ_KEY=$(grep -A10 '^auth:' "$BZ_CONF" 2>/dev/null | sed -n 's/^ *apikey: *//p' | tr -d "'\"" | head -1)
if [ -z "$BZ_KEY" ]; then
  err "Bazarr no respondió o no se encontró su API key. Revisá: sudo docker logs bazarr"
else
  ok "Bazarr encendido"
  bz() { curl -s -o /dev/null -w "%{http_code}" -X POST -H "X-API-KEY: $BZ_KEY" "$BAZARR$1" "${@:2}"; }

  # Idioma y perfil "Español"
  PERFIL='[{"profileId":1,"name":"Español","items":[{"id":1,"language":"es","audio_exclude":"False","audio_only_include":"False","hi":"False","forced":"False"}],"cutoff":null,"mustContain":[],"mustNotContain":[],"originalFormat":false,"tag":null}]'
  ARGS=(--form-string "languages-enabled=es" --form-string "languages-profiles=$PERFIL"
        --form-string "settings-general-use_radarr=true"  --form-string "settings-general-use_sonarr=true"
        --form-string "settings-general-movie_default_enabled=true" --form-string "settings-general-movie_default_profile=1"
        --form-string "settings-general-serie_default_enabled=true" --form-string "settings-general-serie_default_profile=1"
        --form-string "settings-radarr-ip=radarr"  --form-string "settings-radarr-port=7878"  --form-string "settings-radarr-apikey=$RADARR_KEY"  --form-string "settings-radarr-base_url=/"
        --form-string "settings-sonarr-ip=sonarr"  --form-string "settings-sonarr-port=8989"  --form-string "settings-sonarr-apikey=$SONARR_KEY"  --form-string "settings-sonarr-base_url=/"
        --form-string "settings-general-enabled_providers=subdivx" --form-string "settings-general-enabled_providers=podnapisi"
        --form-string "settings-subsync-use_subsync=true" --form-string "settings-subsync-force_audio=true"
        --form-string "settings-subsync-use_subsync_threshold=false" --form-string "settings-subsync-use_subsync_movie_threshold=false"
        --form-string "settings-subsync-no_fix_framerate=true" --form-string "settings-subsync-gss=false")
  if [ -n "$OS_USER" ]; then
    ARGS+=(--form-string "settings-general-enabled_providers=opensubtitlescom"
           --form-string "settings-opensubtitlescom-username=$OS_USER" --form-string "settings-opensubtitlescom-password=$OS_PASS")
  fi
  CODE=$(bz /api/system/settings "${ARGS[@]}")

  # Verificación
  CONF=$(curl -s -H "X-API-KEY: $BZ_KEY" "$BAZARR/api/system/settings")
  PERF=$(curl -s -H "X-API-KEY: $BZ_KEY" "$BAZARR/api/system/languages/profiles")
  if echo "$CONF" | jq -e '.general.use_radarr == true and .general.use_sonarr == true' >/dev/null 2>&1; then
    ok "Conectado a Radarr y Sonarr"
  else err "Conexión con Radarr/Sonarr (código $CODE)"; fi
  if echo "$PERF" | jq -e 'map(select(.name=="Español")) | length > 0' >/dev/null 2>&1; then
    ok "Perfil de subtítulos: Español (por defecto en películas y series)"
  else err "No se creó el perfil Español"; fi
  echo "$CONF" | jq -e '.subsync.use_subsync == true' >/dev/null 2>&1 && ok "Subtítulos se sincronizan solos con el audio" || err "Sincronización automática no quedó activa"
  ok "Proveedores: $(echo "$CONF" | jq -r '.general.enabled_providers | join(", ")' 2>/dev/null)"

  # Sincronizar y buscar subtítulos para lo que ya existe
  for t in update_movies update_series wanted_search_missing_subtitles_movies wanted_search_missing_subtitles_series; do
    bz /api/system/tasks -F "taskid=$t" >/dev/null
  done
  ok "Buscando subtítulos para lo que ya tenés"
fi

# =====================================================================
# 4. Preferencias de reproducción en Jellyfin
# =====================================================================
info "4. Preferencias de reproducción ($JF_USER)"
CFG=$(curl -s -H "Authorization: $AUTH" "$JF/Users/$JF_UID" | jq '.Configuration
  | .AudioLanguagePreference="eng"
  | .SubtitleLanguagePreference="spa"
  | .SubtitleMode="Smart"
  | .PlayDefaultAudioTrack=false')
C1=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Authorization: $AUTH" -H "Content-Type: application/json" \
     -d "$CFG" "$JF/Users/Configuration?userId=$JF_UID")
if [ "$C1" != "204" ] && [ "$C1" != "200" ]; then
  C1=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Authorization: $AUTH" -H "Content-Type: application/json" \
       -d "$CFG" "$JF/Users/$JF_UID/Configuration")
fi
if [ "$C1" = "204" ] || [ "$C1" = "200" ]; then
  ok "Audio: inglés | Subtítulos: español | Modo: Inteligente"
else
  err "No se pudieron guardar (código $C1). Se configura a mano en Perfil → Reproducción/Subtítulos"
fi

info "Listo."
echo "  • Las descargas nuevas aparecen solas en Jellyfin."
echo "  • Se prefieren versiones latinas duales (latino + inglés)."
echo "  • Bazarr baja subtítulos en español automáticamente."
echo "  • Al reproducir en inglés, los subtítulos en español se activan solos."
