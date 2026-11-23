#!/usr/bin/env bash
# =====================================================================
#  Prioriza audio en español latino en Radarr y Sonarr
#  - Crea los Custom Formats "Audio Latino" y "Audio Español"
#  - Ajusta los perfiles de calidad (preferir o exigir latino)
#  - Busca versiones latinas para lo que ya tenés descargado
#  Uso:  sudo bash scripts/07-configurar-idioma.sh
#  Se puede ejecutar de nuevo para cambiar de modo.
# =====================================================================

source "$(dirname "$0")/lib.sh"

ok()  { echo -e "  \e[32m✔\e[0m $1"; }
err() { echo -e "  \e[31m✘\e[0m $1"; }

command -v jq >/dev/null || apt-get install -y jq >/dev/null
getkey() { sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$APPDATA/$1/config.xml"; }

case "${AUDIO_MODO:-}" in exigir) MODO=2;; preferir) MODO=1;; esac
if [ -z "${MODO+x}" ]; then
echo "¿Cómo querés manejar el audio en español latino?"
echo "  1) Preferir latino: baja lo mejor disponible ya y lo reemplaza cuando aparezca latino (recomendado)"
echo "  2) Exigir latino: solo descarga versiones con audio latino (puede tardar mucho o no llegar)"
read -rp "Elegí 1 o 2: " MODO
fi
[ "$MODO" = "2" ] && MIN_SCORE=100 || MIN_SCORE=0

# Puntajes: Latino vale más; español (castellano) sirve de segunda opción
REGEX_LATINO='\b(latino|lat|latam|spa[ ._-]?lat|esp[ ._-]?lat)\b'
REGEX_ESPANOL='\b(español|espanol|castellano|spanish|esp|spa)\b'

api() { # base key método ruta [json]
  if [ -n "$5" ]; then
    curl -sS -X "$3" -H "X-Api-Key: $2" -H "Content-Type: application/json" -d "$5" "$1$4"
  else
    curl -sS -X "$3" -H "X-Api-Key: $2" "$1$4"
  fi
}

crear_cf() { # base key nombre regex -> id
  local base=$1 key=$2 nombre=$3 regex=$4 id
  id=$(api "$base" "$key" GET /api/v3/customformat | jq --arg n "$nombre" '.[] | select(.name==$n) | .id')
  if [ -n "$id" ]; then echo "$id"; return; fi
  api "$base" "$key" POST /api/v3/customformat "$(jq -n --arg n "$nombre" --arg r "$regex" '{
    name:$n, includeCustomFormatWhenRenaming:false,
    specifications:[{ name:$n, implementation:"ReleaseTitleSpecification",
      negate:false, required:true, fields:[{name:"value", value:$r}] }] }')" | jq '.id'
}

configurar() { # Nombre base key comando_busqueda
  local app=$1 base=$2 key=$3 cmd=$4
  echo -e "\n$app"
  local LAT ESP
  LAT=$(crear_cf "$base" "$key" "Audio Latino" "$REGEX_LATINO")
  ESP=$(crear_cf "$base" "$key" "Audio Español" "$REGEX_ESPANOL")
  if [ -z "$LAT" ] || [ "$LAT" = "null" ] || [ -z "$ESP" ] || [ "$ESP" = "null" ]; then
    err "No se pudieron crear los Custom Formats"; return
  fi
  local DUAL
  DUAL=$(crear_cf "$base" "$key" "Audio Dual" '\b(dual|multi)\b')
  ok "Custom Formats: Audio Latino (+100), Audio Español (+25) y Audio Dual (+50)"

  # Id del idioma "Any" (solo Radarr tiene idioma en el perfil)
  local ANY
  ANY=$(api "$base" "$key" GET /api/v3/language | jq -c '[.[] | select(.name=="Any")][0] // empty')

  api "$base" "$key" GET /api/v3/qualityprofile | jq -c '.[]' | while read -r perfil; do
    local id nombre nuevo resp
    id=$(echo "$perfil" | jq '.id'); nombre=$(echo "$perfil" | jq -r '.name')
    nuevo=$(echo "$perfil" | jq --argjson lat "$LAT" --argjson esp "$ESP" \
            --argjson dual "${DUAL:-0}" --argjson min "$MIN_SCORE" --arg any "$ANY" '
      .formatItems |= map(
          if .format==$lat then .score=100
          elif .format==$esp then .score=25
          elif .format==$dual then .score=50
          else . end)
      | .minFormatScore=$min
      | .cutoffFormatScore=150
      | .upgradeAllowed=true
      | if (has("language") and $any != "") then .language=($any|fromjson) else . end')
    resp=$(api "$base" "$key" PUT "/api/v3/qualityprofile/$id" "$nuevo")
    if echo "$resp" | jq -e '.id' >/dev/null 2>&1; then ok "Perfil $nombre actualizado"
    else err "Perfil $nombre: $(echo "$resp" | jq -r '.[0].errorMessage // .message // .' 2>/dev/null | head -c 200)"; fi
  done

  api "$base" "$key" POST /api/v3/command "{\"name\":\"$cmd\"}" >/dev/null
  ok "Buscando versiones en latino para lo que ya tenés"
}

configurar Radarr http://localhost:7878 "$(getkey radarr)" CutOffUnmetMoviesSearch
configurar Sonarr http://localhost:8989 "$(getkey sonarr)" CutoffUnmetEpisodeSearch

echo
if [ "$MIN_SCORE" = "100" ]; then
  echo "Modo: EXIGIR latino. Solo se descargan versiones con audio latino."
else
  echo "Modo: PREFERIR latino. Se baja lo mejor disponible y se reemplaza al aparecer latino."
fi
echo "Podés cambiar de modo ejecutando este script otra vez."
