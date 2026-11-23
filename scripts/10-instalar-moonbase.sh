#!/usr/bin/env bash
# =====================================================================
#  (Opcional) Instala el plugin Moonbase en Jellyfin, necesario para
#  pedir películas desde la app Moonfin en la TV con avisos de "disponible".
#  La configuración del plugin se hace en el panel (ver README).
#  Uso:  sudo bash scripts/10-instalar-moonbase.sh
# =====================================================================

source "$(dirname "$0")/lib.sh"

JF=http://localhost:8096
CLIENTE='MediaBrowser Client="Script", Device="Servidor", DeviceId="script-config", Version="1.0"'
REPO_URL="https://raw.githubusercontent.com/Moonfin-Client/Plugin/refs/heads/master/manifest.json"
GUID="8c5d0e91-4f2a-4b6d-9e3f-1a7c8d9e0f2b"

[ -z "${JF_USER+x}" ] && read -rp "Usuario de Jellyfin: " JF_USER
[ -z "${JF_PASS+x}" ] && { read -rsp "Contraseña de Jellyfin: " JF_PASS; echo; }

TOKEN=$(curl -s -X POST "$JF/Users/AuthenticateByName" -H "Authorization: $CLIENTE" -H "Content-Type: application/json" \
  -d "$(jq -n --arg u "$JF_USER" --arg p "$JF_PASS" '{Username:$u, Pw:$p}')" | jq -r '.AccessToken // empty')
[ -z "$TOKEN" ] && { err "No se pudo iniciar sesión en Jellyfin"; exit 1; }
AUTH="$CLIENTE, Token=\"$TOKEN\""
jf() { curl -s -H "Authorization: $AUTH" -H "Content-Type: application/json" "$@"; }

info "Moonbase (plugin de Moonfin)"
estado() { jf "$JF/Plugins" | jq -r '.[] | select(.Name=="Moonbase") | .Status' | head -1; }
if [ -n "$(estado)" ]; then
  ok "Ya instalado (estado: $(estado))"; exit 0
fi

REPOS=$(jf "$JF/Repositories")
if ! echo "$REPOS" | jq -e --arg u "$REPO_URL" '.[] | select(.Url==$u)' >/dev/null 2>&1; then
  jf -X POST -d "$(echo "$REPOS" | jq --arg u "$REPO_URL" '. + [{Name:"Moonfin", Url:$u, Enabled:true}]')" "$JF/Repositories" -o /dev/null
fi
ok "Repositorio de Moonfin agregado"

jf -X POST -o /dev/null "$JF/Packages/Installed/Moonbase?assemblyGuid=$GUID&repositoryUrl=$(jq -rn --arg u "$REPO_URL" '$u|@uri')"
echo "  Instalando y reiniciando Jellyfin..."
sleep 15
jf -X POST -o /dev/null "$JF/System/Restart"
for i in $(seq 1 40); do sleep 3; curl -s "$JF/System/Info/Public" | jq -e '.Version' >/dev/null 2>&1 && break; done
sleep 5
TOKEN=$(curl -s -X POST "$JF/Users/AuthenticateByName" -H "Authorization: $CLIENTE" -H "Content-Type: application/json" \
  -d "$(jq -n --arg u "$JF_USER" --arg p "$JF_PASS" '{Username:$u, Pw:$p}')" | jq -r '.AccessToken // empty')
AUTH="$CLIENTE, Token=\"$TOKEN\""
E=$(estado)
if [ "$E" = "Active" ]; then ok "Moonbase activo"
else err "Estado de Moonbase: ${E:-no aparece}. Revisá Panel de control → Plugins."; fi
echo "  Falta configurarlo en el panel: ver README → 'Moonfin en la TV'."
