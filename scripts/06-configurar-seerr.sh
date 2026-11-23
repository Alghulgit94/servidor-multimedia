#!/usr/bin/env bash
# =====================================================================
#  Configuración automática de Seerr
#  - Inicia sesión con tu usuario de Jellyfin (primera configuración)
#  - Activa las bibliotecas de Películas y Series
#  - Conecta Radarr y Sonarr (calidad HD-1080p)
#  Uso:  sudo bash scripts/06-configurar-seerr.sh
# =====================================================================

source "$(dirname "$0")/lib.sh"

SEERR=http://localhost:5055
RADARR=http://localhost:7878
SONARR=http://localhost:8989
COOKIES=$(mktemp)
trap 'rm -f "$COOKIES"' EXIT

ok()  { echo -e "  \e[32m✔\e[0m $1"; }
err() { echo -e "  \e[31m✘\e[0m $1"; }

command -v jq >/dev/null || apt-get install -y jq >/dev/null

getkey() { sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$APPDATA/$1/config.xml"; }
RADARR_KEY=$(getkey radarr)
SONARR_KEY=$(getkey sonarr)

s() { # método ruta [json]  (con sesión)
  if [ -n "$3" ]; then
    curl -s -b "$COOKIES" -c "$COOKIES" -X "$1" -H "Content-Type: application/json" -d "$3" "$SEERR$2"
  else
    curl -s -b "$COOKIES" -c "$COOKIES" -X "$1" "$SEERR$2"
  fi
}

PUBLIC=$(curl -s "$SEERR/api/v1/settings/public")
echo "$PUBLIC" | jq -e . >/dev/null 2>&1 || { err "Seerr no responde en $SEERR"; exit 1; }
INICIALIZADO=$(echo "$PUBLIC" | jq -r '.initialized')
ok "Seerr responde"

echo
[ -z "${JF_USER+x}" ] && read -rp "Usuario de Jellyfin: " JF_USER
[ -z "${JF_PASS+x}" ] && { read -rsp "Contraseña de Jellyfin: " JF_PASS; echo; }

# ---------- Iniciar sesión con Jellyfin ----------
echo -e "\nInicio de sesión"
if [ "$INICIALIZADO" != "true" ]; then
  BODY=$(jq -n --arg u "$JF_USER" --arg p "$JF_PASS" '{
    username:$u, password:$p, hostname:"jellyfin", port:8096,
    useSsl:false, urlBase:"", email:"admin@servidor.local", serverType:2 }')
else
  BODY=$(jq -n --arg u "$JF_USER" --arg p "$JF_PASS" '{username:$u, password:$p}')
fi
RESP=$(s POST /api/v1/auth/jellyfin "$BODY")
if echo "$RESP" | jq -e '.id' >/dev/null 2>&1; then
  ok "Sesión iniciada como $JF_USER"
else
  err "No se pudo iniciar sesión: $(echo "$RESP" | jq -r '.message // .' 2>/dev/null)"
  exit 1
fi

# ---------- Bibliotecas ----------
echo -e "\nBibliotecas de Jellyfin"
s POST /api/v1/settings/jellyfin/library/sync >/dev/null
LIBS=$(s GET /api/v1/settings/jellyfin/library)
if echo "$LIBS" | jq -e 'type=="array" and length > 0' >/dev/null 2>&1; then
  echo "$LIBS" | jq -r '.[] | "\(.id)\t\(.name)"' | while IFS=$'\t' read -r ID NOMBRE; do
    s PUT "/api/v1/settings/jellyfin/library/$ID" '{"enabled":true}' >/dev/null
    ok "$NOMBRE activada"
  done
else
  err "No se encontraron bibliotecas (¿Jellyfin terminó de configurarse?)"
fi

# ---------- Perfil de calidad ----------
perfil() { # base key -> {"id":..,"name":..}
  curl -s -H "X-Api-Key: $2" "$1/api/v3/qualityprofile" |
    jq -c '(map(select(.name=="HD-1080p"))[0] // .[0]) | {id, name}'
}

# ---------- Radarr ----------
echo -e "\nRadarr"
if s GET /api/v1/settings/radarr | jq -e 'length > 0' >/dev/null 2>&1; then
  ok "Radarr ya estaba conectado"
else
  P=$(perfil "$RADARR" "$RADARR_KEY")
  RESP=$(s POST /api/v1/settings/radarr "$(jq -n --arg k "$RADARR_KEY" --argjson p "$P" '{
    name:"Radarr", hostname:"radarr", port:7878, apiKey:$k, useSsl:false, baseUrl:"",
    activeProfileId:$p.id, activeProfileName:$p.name, activeDirectory:"/data/media/movies",
    is4k:false, minimumAvailability:"released", tags:[], isDefault:true,
    externalUrl:"", syncEnabled:false, preventSearch:false }')")
  if echo "$RESP" | jq -e '.id != null' >/dev/null 2>&1; then
    ok "Radarr conectado (perfil $(echo "$P" | jq -r .name))"
  else
    err "Radarr: $(echo "$RESP" | jq -r '.message // .' 2>/dev/null | head -c 300)"
  fi
fi

# ---------- Sonarr ----------
echo -e "\nSonarr"
if s GET /api/v1/settings/sonarr | jq -e 'length > 0' >/dev/null 2>&1; then
  ok "Sonarr ya estaba conectado"
else
  P=$(perfil "$SONARR" "$SONARR_KEY")
  RESP=$(s POST /api/v1/settings/sonarr "$(jq -n --arg k "$SONARR_KEY" --argjson p "$P" '{
    name:"Sonarr", hostname:"sonarr", port:8989, apiKey:$k, useSsl:false, baseUrl:"",
    activeProfileId:$p.id, activeProfileName:$p.name, activeDirectory:"/data/media/tv",
    activeAnimeProfileId:null, activeAnimeProfileName:null, activeAnimeDirectory:"",
    seriesType:"standard", animeSeriesType:"anime", tags:[], animeTags:[],
    is4k:false, isDefault:true, enableSeasonFolders:true,
    externalUrl:"", syncEnabled:false, preventSearch:false }')")
  if echo "$RESP" | jq -e '.id != null' >/dev/null 2>&1; then
    ok "Sonarr conectado (perfil $(echo "$P" | jq -r .name))"
  else
    err "Sonarr: $(echo "$RESP" | jq -r '.message // .' 2>/dev/null | head -c 300)"
  fi
fi

# ---------- URL externa de Jellyfin (botón "Reproducir en Jellyfin") ----------
echo -e "\nBotón Reproducir en Jellyfin"
s POST /api/v1/settings/jellyfin "$(jq -n --arg u "http://$SERVER_IP:8096" '{externalHostname:$u}')" >/dev/null
if [ "$(s GET /api/v1/settings/jellyfin | jq -r '.externalHostname')" = "http://$SERVER_IP:8096" ]; then
  ok "Enlaces a Jellyfin usan http://$SERVER_IP:8096"
else
  err "No se pudo guardar la URL externa de Jellyfin"
fi

# ---------- Finalizar ----------
echo -e "\nFinalizando"
if [ "$INICIALIZADO" != "true" ]; then
  s POST /api/v1/settings/initialize '{}' >/dev/null
fi
s POST /api/v1/settings/main '{"locale":"es"}' >/dev/null
ok "Configuración inicial completa"

echo -e "\nListo. Entrá a $SEERR con tu usuario de Jellyfin y pedí tu primera película."
