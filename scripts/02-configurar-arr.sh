#!/usr/bin/env bash
# =====================================================================
#  Autoconfiguración del stack *arr
#  - Conecta qBittorrent a Radarr, Sonarr y Lidarr (con sus categorías)
#  - Crea las carpetas raíz de películas, series y música
#  - Conecta Radarr, Sonarr y Lidarr a Prowlarr
#  Uso:  sudo bash scripts/02-configurar-arr.sh
#  Se puede ejecutar varias veces: lo que ya existe no se duplica.
# =====================================================================

source "$(dirname "$0")/lib.sh"

RADARR=http://localhost:7878
SONARR=http://localhost:8989
LIDARR=http://localhost:8686
PROWLARR=http://localhost:9696

ok()   { echo -e "  \e[32m✔\e[0m $1"; }
err()  { echo -e "  \e[31m✘\e[0m $1"; }
info() { echo -e "\n\e[1m$1\e[0m"; }

# ---------- Requisitos ----------
if ! command -v jq >/dev/null; then
  echo "Instalando jq..."
  apt-get install -y jq >/dev/null || { echo "No se pudo instalar jq"; exit 1; }
fi

getkey() {
  sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$APPDATA/$1/config.xml" 2>/dev/null
}

RADARR_KEY=$(getkey radarr)
SONARR_KEY=$(getkey sonarr)
LIDARR_KEY=$(getkey lidarr)
PROWLARR_KEY=$(getkey prowlarr)

info "API keys encontradas"
for a in RADARR SONARR PROWLARR; do
  k="${a}_KEY"
  if [ -n "${!k}" ]; then ok "$a"; else err "$a (no se encontró config.xml)"; MISSING=1; fi
done
[ -n "$MISSING" ] && { echo "Revisá que todos los contenedores estén corriendo."; exit 1; }
if [ -n "$LIDARR_KEY" ]; then ok "LIDARR"; else echo "  · Lidarr no está activo (opcional): se omite la música"; fi

echo
[ -z "${QB_USER+x}" ] && read -rp "Usuario de qBittorrent: " QB_USER
[ -z "${QB_PASS+x}" ] && { read -rsp "Contraseña de qBittorrent: " QB_PASS; echo; }

api() { # base key método ruta [json]
  if [ -n "$5" ]; then
    curl -sS -X "$3" -H "X-Api-Key: $2" -H "Content-Type: application/json" -d "$5" "$1$4"
  else
    curl -sS -X "$3" -H "X-Api-Key: $2" "$1$4"
  fi
}

result() { # nombre respuesta
  if echo "$2" | jq -e '.id' >/dev/null 2>&1; then ok "$1"
  else err "$1: $(echo "$2" | jq -r '.[0].errorMessage // .message // .' 2>/dev/null | head -c 300)"; fi
}

# ---------- qBittorrent como cliente de descargas ----------
add_qbit() { # app base key versión campo_categoría categoría
  local app=$1 base=$2 key=$3 ver=$4 catfield=$5 cat=$6
  if api "$base" "$key" GET "/api/$ver/downloadclient" | jq -e '.[] | select(.name=="qBittorrent")' >/dev/null 2>&1; then
    ok "$app: qBittorrent ya estaba configurado"; return
  fi
  local payload resp
  payload=$(api "$base" "$key" GET "/api/$ver/downloadclient/schema" | jq \
    --arg u "$QB_USER" --arg p "$QB_PASS" --arg cf "$catfield" --arg c "$cat" '
    map(select(.implementation=="QBittorrent"))[0]
    | .name="qBittorrent" | .enable=true | .priority=1
    | .fields |= map(
        if   .name=="host"     then .value="qbittorrent"
        elif .name=="port"     then .value=8080
        elif .name=="username" then .value=$u
        elif .name=="password" then .value=$p
        elif .name==$cf        then .value=$c
        else . end)')
  resp=$(api "$base" "$key" POST "/api/$ver/downloadclient" "$payload")
  result "$app: qBittorrent (categoría $cat)" "$resp"
}

# ---------- Carpetas raíz ----------
add_root() { # app base key ruta
  if api "$2" "$3" GET "/api/v3/rootfolder" | jq -e --arg p "$4" '.[] | select(.path==$p)' >/dev/null 2>&1; then
    ok "$1: carpeta $4 ya estaba"; return
  fi
  result "$1: carpeta $4" "$(api "$2" "$3" POST "/api/v3/rootfolder" "$(jq -n --arg p "$4" '{path:$p}')")"
}

add_root_lidarr() {
  local path=/data/media/music
  if api "$LIDARR" "$LIDARR_KEY" GET "/api/v1/rootfolder" | jq -e --arg p "$path" '.[] | select(.path==$p)' >/dev/null 2>&1; then
    ok "Lidarr: carpeta $path ya estaba"; return
  fi
  local qp mp
  qp=$(api "$LIDARR" "$LIDARR_KEY" GET "/api/v1/qualityprofile" | jq '.[0].id')
  mp=$(api "$LIDARR" "$LIDARR_KEY" GET "/api/v1/metadataprofile" | jq '(map(select(.name=="Standard"))[0] // .[0]).id')
  result "Lidarr: carpeta $path" "$(api "$LIDARR" "$LIDARR_KEY" POST "/api/v1/rootfolder" "$(jq -n \
    --arg p "$path" --argjson qp "$qp" --argjson mp "$mp" '{
      name:"Musica", path:$p, defaultQualityProfileId:$qp, defaultMetadataProfileId:$mp,
      defaultMonitorOption:"all", defaultNewItemMonitorOption:"all", defaultTags:[] }')")"
}

# ---------- Apps en Prowlarr ----------
add_app() { # Nombre puerto key
  local name=$1 port=$2 key=$3 host
  host=$(echo "$name" | tr '[:upper:]' '[:lower:]')
  if api "$PROWLARR" "$PROWLARR_KEY" GET "/api/v1/applications" | jq -e --arg n "$name" '.[] | select(.name==$n)' >/dev/null 2>&1; then
    ok "Prowlarr: $name ya estaba conectado"; return
  fi
  local payload
  payload=$(api "$PROWLARR" "$PROWLARR_KEY" GET "/api/v1/applications/schema" | jq \
    --arg n "$name" --arg url "http://$host:$port" --arg k "$key" '
    map(select(.implementation==$n))[0]
    | .name=$n | .syncLevel="fullSync"
    | .fields |= map(
        if   .name=="prowlarrUrl" then .value="http://prowlarr:9696"
        elif .name=="baseUrl"     then .value=$url
        elif .name=="apiKey"      then .value=$k
        else . end)')
  result "Prowlarr: $name" "$(api "$PROWLARR" "$PROWLARR_KEY" POST "/api/v1/applications" "$payload")"
}

# ---------- Ejecución ----------
info "Radarr (películas)"
add_root  Radarr "$RADARR" "$RADARR_KEY" /data/media/movies
add_qbit  Radarr "$RADARR" "$RADARR_KEY" v3 movieCategory movies

info "Sonarr (series)"
add_root  Sonarr "$SONARR" "$SONARR_KEY" /data/media/tv
add_qbit  Sonarr "$SONARR" "$SONARR_KEY" v3 tvCategory tv

if [ -n "$LIDARR_KEY" ]; then
  info "Lidarr (música)"
  add_root_lidarr
  add_qbit  Lidarr "$LIDARR" "$LIDARR_KEY" v1 musicCategory music
fi

info "Prowlarr"
add_app Radarr 7878 "$RADARR_KEY"
add_app Sonarr 8989 "$SONARR_KEY"
[ -n "$LIDARR_KEY" ] && add_app Lidarr 8686 "$LIDARR_KEY"

info "Listo."
echo "  Siguiente paso: scripts/03-configurar-flaresolverr.sh"
