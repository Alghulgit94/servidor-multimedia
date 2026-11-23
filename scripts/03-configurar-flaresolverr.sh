#!/usr/bin/env bash
# =====================================================================
#  Conecta FlareSolverr a Prowlarr (sitios protegidos por Cloudflare)
#  - Crea la etiqueta "flaresolverr" y el proxy en Prowlarr
#  Uso:  sudo bash scripts/03-configurar-flaresolverr.sh
# =====================================================================

source "$(dirname "$0")/lib.sh"

PROWLARR=http://localhost:9696
KEY=$(getkey prowlarr)
api() {
  if [ -n "$3" ]; then
    curl -sS --max-time 90 -X "$1" -H "X-Api-Key: $KEY" -H "Content-Type: application/json" -d "$3" "$PROWLARR$2"
  else
    curl -sS --max-time 90 -X "$1" -H "X-Api-Key: $KEY" "$PROWLARR$2"
  fi
}

info "FlareSolverr"
for i in $(seq 1 60); do curl -s http://localhost:8191 | grep -qi "ready" && break; sleep 3; done
curl -s http://localhost:8191 | grep -qi "ready" && ok "FlareSolverr funcionando" \
  || { err "FlareSolverr no responde. Revisá: sudo docker logs flaresolverr"; exit 1; }

TAG_ID=$(api GET /api/v1/tag | jq '.[] | select(.label=="flaresolverr") | .id')
[ -z "$TAG_ID" ] && TAG_ID=$(api POST /api/v1/tag '{"label":"flaresolverr"}' | jq '.id')
{ [ -n "$TAG_ID" ] && [ "$TAG_ID" != "null" ]; } && ok "Etiqueta flaresolverr" || { err "No se pudo crear la etiqueta"; exit 1; }

if api GET /api/v1/indexerproxy | jq -e '.[] | select(.implementation=="FlareSolverr")' >/dev/null 2>&1; then
  ok "Proxy FlareSolverr ya estaba"
else
  PAYLOAD=$(api GET /api/v1/indexerproxy/schema | jq --argjson t "$TAG_ID" '
    map(select(.implementation=="FlareSolverr"))[0]
    | .name="FlareSolverr" | .tags=[$t]
    | .fields |= map(
        if   .name=="host"           then .value="http://flaresolverr:8191/"
        elif .name=="requestTimeout" then .value=60
        else . end)')
  RESP=$(api POST /api/v1/indexerproxy "$PAYLOAD")
  echo "$RESP" | jq -e '.id' >/dev/null 2>&1 && ok "Proxy FlareSolverr conectado a Prowlarr" \
    || { err "Proxy: $(echo "$RESP" | jq -r '.[0].errorMessage // .message // .' 2>/dev/null | head -c 300)"; exit 1; }
fi
