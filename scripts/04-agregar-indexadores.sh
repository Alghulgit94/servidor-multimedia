#!/usr/bin/env bash
# =====================================================================
#  Agrega automáticamente indexadores públicos de torrents a Prowlarr
#  - Borra los indexadores ya configurados que no sirven (sin películas o de anime)
#  - Solo agrega indexadores con películas, que no sean de anime
#  - Prioriza idioma español, después inglés
#  - Prueba cada uno y agrega solo los que responden bien
#  Uso:  sudo bash scripts/04-agregar-indexadores.sh
# =====================================================================

source "$(dirname "$0")/lib.sh"

OBJETIVO=${1:-${INDEXADORES:-8}}    # cuántos indexadores querés (se puede pasar como argumento)
MAX_INTENTOS=80     # cuántos probar como máximo
PROWLARR=http://localhost:9696
KEY=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' $APPDATA/prowlarr/config.xml)

ok()  { echo -e "  \e[32m✔\e[0m $1"; }
err() { echo -e "  \e[90m✘ $1\e[0m"; }
del() { echo -e "  \e[33m🗑\e[0m $1"; }

command -v jq >/dev/null || apt-get install -y jq >/dev/null
[ -z "$KEY" ] && { echo "No se encontró la API key de Prowlarr"; exit 1; }

api() { # método ruta [json]
  if [ -n "$3" ]; then
    curl -sS --max-time 90 -X "$1" -H "X-Api-Key: $KEY" -H "Content-Type: application/json" -d "$3" "$PROWLARR$2"
  else
    curl -sS --max-time 90 -X "$1" -H "X-Api-Key: $KEY" "$PROWLARR$2"
  fi
}

api_code() { # método ruta json -> solo el código HTTP
  curl -s --max-time 90 -o /dev/null -w "%{http_code}" -X "$1" \
    -H "X-Api-Key: $KEY" -H "Content-Type: application/json" -d "$3" "$PROWLARR$2"
}

# Filtro común: ¿sirve para películas y no es de anime?
FILTRO='
  def tiene_peliculas: any(.capabilities.categories[]?; (.id >= 2000 and .id < 3000));
  def es_anime: ((.name + " " + (.description // "")) | test("anime|anidex|bangumi|nyaa|hentai|manga"; "i"));
  def excluido: (.name | test("^Internet Archive$"; "i"));
  def sirve: tiene_peliculas and (es_anime | not) and (excluido | not);
'

echo "Leyendo configuración de Prowlarr..."
APP_PROFILE=$(api GET /api/v1/appprofile | jq '.[0].id')
# Si existe la etiqueta "flaresolverr", se aplica a los indexadores nuevos
TAGS=$(api GET /api/v1/tag | jq -c '[.[] | select(.label=="flaresolverr") | .id]')
[ "$TAGS" != "[]" ] && echo "FlareSolverr detectado: se usará para sitios con Cloudflare"

# ---------- Limpieza de indexadores inútiles ----------
echo -e "\nRevisando indexadores ya configurados..."
INDEXADORES=$(api GET /api/v1/indexer)
while IFS=$'\t' read -r ID NOMBRE; do
  [ -z "$ID" ] && continue
  api DELETE "/api/v1/indexer/$ID" >/dev/null
  del "Borrado: $NOMBRE (no sirve para películas)"
done < <(echo "$INDEXADORES" | jq -r "$FILTRO"'.[] | select(sirve | not) | "\(.id)\t\(.name)"')

EXISTENTES=$(api GET /api/v1/indexer | jq '[.[].name]')
TIENE=$(echo "$EXISTENTES" | jq 'length')
echo "Indexadores útiles configurados: $TIENE"
[ "$TIENE" -ge "$OBJETIVO" ] && { echo "Ya tenés $TIENE, no hace falta agregar más."; exit 0; }

# ---------- Búsqueda de nuevos ----------
echo -e "\nDescargando catálogo de indexadores..."
CANDIDATOS=$(api GET /api/v1/indexer/schema | jq -c --argjson ex "$EXISTENTES" "$FILTRO"'
  map(select(.protocol=="torrent" and .privacy=="public" and sirve
             and ((.name) as $n | $ex | index($n) | not)))
  | sort_by(
      ((.language // "") | ascii_downcase) as $l
      | if ($l | startswith("es")) then 0 elif ($l | startswith("en")) then 1 else 2 end)
  | .[]')

TOTAL=$(echo "$CANDIDATOS" | grep -c . )
echo "Candidatos con películas: $TOTAL"
echo -e "Probando indexadores (puede tardar unos minutos)...\n"

INTENTOS=0
while IFS= read -r item; do
  [ -z "$item" ] && continue
  [ "$TIENE" -ge "$OBJETIVO" ] && break
  [ "$INTENTOS" -ge "$MAX_INTENTOS" ] && break
  INTENTOS=$((INTENTOS+1))

  NOMBRE=$(echo "$item" | jq -r '.name')
  IDIOMA=$(echo "$item" | jq -r '.language // "?"')
  PAYLOAD=$(echo "$item" | jq --argjson ap "$APP_PROFILE" --argjson tags "$TAGS" '
    . as $i
    | .appProfileId=$ap | .enable=true | .priority=25 | .tags=$tags
    | .fields |= map(
        if .name=="baseUrl" and ((.value // "") == "")
        then .value=($i.indexerUrls[0]) else . end)')

  CODE=$(api_code POST /api/v1/indexer/test "$PAYLOAD")
  if [ "$CODE" = "200" ]; then
    if api POST /api/v1/indexer "$PAYLOAD" | jq -e '.id' >/dev/null 2>&1; then
      TIENE=$((TIENE+1))
      ok "$NOMBRE [$IDIOMA]  ($TIENE/$OBJETIVO)"
    else
      err "$NOMBRE (pasó la prueba pero no se pudo guardar)"
    fi
  else
    err "$NOMBRE [$IDIOMA] (no responde)"
  fi
done <<< "$CANDIDATOS"

echo
echo "Sincronizando con Radarr, Sonarr y Lidarr..."
api POST /api/v1/command '{"name":"ApplicationIndexerSync"}' >/dev/null
echo -e "\nListo: $TIENE indexadores útiles funcionando."
[ "$TIENE" -lt "$OBJETIVO" ] && echo "No se llegó al objetivo. Muchos sitios populares requieren FlareSolverr (Cloudflare)."
