#!/usr/bin/env bash
# =====================================================================
#  Sincronización de subtítulos con el audio de la película (Bazarr)
#  - Corrige el corrimiento fijo (subtítulo adelantado o atrasado)
#  - Lo deja activado para todos los subtítulos nuevos
#  - Sincroniza ahora los existentes y muestra cuántos segundos corrigió
#  Uso:  sudo bash scripts/11-sincronizar-subtitulos.sh
# =====================================================================

source "$(dirname "$0")/lib.sh"

BAZARR=http://localhost:6767
BZ_CONF=$(find "$APPDATA/bazarr" -name config.yaml 2>/dev/null | head -1)
BZ_KEY=$(grep -A10 '^auth:' "$BZ_CONF" 2>/dev/null | sed -n 's/^ *apikey: *//p' | tr -d "'\"" | head -1)
[ -z "$BZ_KEY" ] && { err "No se encontró la API key de Bazarr (¿está encendido?)"; exit 1; }
bz() { curl -s -H "X-API-KEY: $BZ_KEY" "$@"; }

# ---------- 1. Sincronización automática: solo corrimiento ----------
info "1. Sincronización automática de subtítulos nuevos"
RESP=$(bz -w "\n%{http_code}" -X POST "$BAZARR/api/system/settings" \
  --form-string "settings-subsync-use_subsync=true" \
  --form-string "settings-subsync-force_audio=true" \
  --form-string "settings-subsync-use_subsync_threshold=false" \
  --form-string "settings-subsync-use_subsync_movie_threshold=false" \
  --form-string "settings-subsync-no_fix_framerate=true" \
  --form-string "settings-subsync-gss=false")
CONF=$(bz "$BAZARR/api/system/settings")
if echo "$CONF" | jq -e '.subsync.use_subsync and .subsync.force_audio and .subsync.no_fix_framerate and (.subsync.gss|not)' >/dev/null 2>&1; then
  ok "Cada subtítulo nuevo se alinea solo con el audio (corrimiento fijo)"
else
  err "No se activó (código $(echo "$RESP" | tail -1)): $(echo "$RESP" | head -1)"; exit 1
fi

# ---------- 2. Sincronizar los existentes ----------
info "2. Sincronizando los subtítulos que ya tenés"
echo "  Cada película puede tardar varios minutos: se analiza el audio completo."
MOVIES=$(bz "$BAZARR/api/movies?start=0&length=-1")
TOTAL=0; BIEN=0
while IFS=$'\t' read -r ID TITULO RUTA HI FORCED; do
  [ -z "$ID" ] && continue
  TOTAL=$((TOTAL+1))
  ANTES=$(bz "$BAZARR/api/movies/history?radarrid=$ID&start=0&length=-1" | jq '[.data[]? | select(.action==5)] | length')
  echo "  … $TITULO"
  bz -o /dev/null -m 1800 -X PATCH "$BAZARR/api/subtitles" \
    --data-urlencode "action=sync" --data-urlencode "language=es" --data-urlencode "path=$RUTA" \
    --data-urlencode "type=movie" --data-urlencode "id=$ID" \
    --data-urlencode "hi=$HI" --data-urlencode "forced=$FORCED" \
    --data-urlencode "gss=False" --data-urlencode "no_fix_framerate=True"
  # Esperar a que aparezca el resultado en el historial (hasta 20 minutos)
  RES=""
  for i in $(seq 1 120); do
    H=$(bz "$BAZARR/api/movies/history?radarrid=$ID&start=0&length=-1")
    if [ "$(echo "$H" | jq '[.data[]? | select(.action==5)] | length')" -gt "${ANTES:-0}" ]; then
      RES=$(echo "$H" | jq -r '[.data[]? | select(.action==5)] | max_by(.timestamp // .parsed_timestamp // 0) | .description')
      break
    fi
    sleep 10
  done
  if [ -n "$RES" ]; then
    SEG=$(echo "$RES" | grep -oE 'offset of -?[0-9.]+' | grep -oE -- '-?[0-9.]+')
    ok "$TITULO: corregido en ${SEG:-?} segundos"
    BIEN=$((BIEN+1))
  else
    err "$TITULO: no se pudo sincronizar. Detalle: sudo docker logs bazarr --tail 40"
  fi
done < <(echo "$MOVIES" | jq -r '.data[]? | . as $m | .subtitles[]?
  | select(.code2=="es" and (.path // "") != "")
  | [$m.radarrId, $m.title, .path, (if .hi then "True" else "False" end), (if .forced then "True" else "False" end)] | @tsv')

[ "$TOTAL" -eq 0 ] && echo "  No hay subtítulos externos en español para sincronizar."
info "Listo: $BIEN de $TOTAL subtítulos sincronizados."
echo "  Cerrá la película si estaba abierta y volvé a reproducirla."
