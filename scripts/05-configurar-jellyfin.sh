#!/usr/bin/env bash
# =====================================================================
#  Configuración automática de Jellyfin
#  - Completa el asistente inicial (español, tu usuario administrador)
#  - Crea las bibliotecas de Películas, Series y Música
#  Uso:  sudo bash scripts/05-configurar-jellyfin.sh
# =====================================================================

source "$(dirname "$0")/lib.sh"

JF=http://localhost:8096
CLIENTE='MediaBrowser Client="Script", Device="Servidor", DeviceId="script-config", Version="1.0"'

ok()  { echo -e "  \e[32m✔\e[0m $1"; }
err() { echo -e "  \e[31m✘\e[0m $1"; }

command -v jq >/dev/null || apt-get install -y jq >/dev/null

echo "Esperando a que Jellyfin responda..."
for i in $(seq 1 30); do
  curl -s "$JF/System/Info/Public" | jq -e '.Version' >/dev/null 2>&1 && break
  sleep 2
done
INFO=$(curl -s "$JF/System/Info/Public")
echo "$INFO" | jq -e '.Version' >/dev/null 2>&1 || { err "Jellyfin no responde en $JF"; exit 1; }
ok "Jellyfin $(echo "$INFO" | jq -r '.Version')"

echo
[ -z "${JF_USER+x}" ] && read -rp "Usuario para Jellyfin: " JF_USER
[ -z "${JF_PASS+x}" ] && { read -rsp "Contraseña para Jellyfin: " JF_PASS; echo; }

# ---------- Asistente inicial ----------
if [ "$(echo "$INFO" | jq -r '.StartupWizardCompleted')" != "true" ]; then
  echo -e "\nAsistente inicial"
  curl -s -X POST "$JF/Startup/Configuration" -H "Content-Type: application/json" \
    -d '{"UICulture":"es","MetadataCountryCode":"PY","PreferredMetadataLanguage":"es"}' >/dev/null
  curl -s "$JF/Startup/User" >/dev/null
  curl -s -X POST "$JF/Startup/User" -H "Content-Type: application/json" \
    -d "$(jq -n --arg u "$JF_USER" --arg p "$JF_PASS" '{Name:$u, Password:$p}')" >/dev/null
  curl -s -X POST "$JF/Startup/RemoteAccess" -H "Content-Type: application/json" \
    -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null
  curl -s -X POST "$JF/Startup/Complete" >/dev/null
  ok "Idioma español y usuario $JF_USER creados"
else
  echo -e "\nEl asistente inicial ya estaba completo, uso el usuario existente."
fi

# ---------- Iniciar sesión ----------
TOKEN=$(curl -s -X POST "$JF/Users/AuthenticateByName" \
  -H "Authorization: $CLIENTE" -H "Content-Type: application/json" \
  -d "$(jq -n --arg u "$JF_USER" --arg p "$JF_PASS" '{Username:$u, Pw:$p}')" | jq -r '.AccessToken // empty')
[ -z "$TOKEN" ] && { err "No se pudo iniciar sesión: revisá usuario y contraseña"; exit 1; }
AUTH="$CLIENTE, Token=\"$TOKEN\""
ok "Sesión iniciada"

# ---------- Bibliotecas ----------
echo -e "\nBibliotecas"
EXISTENTES=$(curl -s -H "Authorization: $AUTH" "$JF/Library/VirtualFolders" | jq '[.[].Name]')

add_lib() { # nombre tipo ruta
  if echo "$EXISTENTES" | jq -e --arg n "$1" 'index($n)' >/dev/null; then
    ok "$1 ya existía"; return
  fi
  local nombre_url code
  nombre_url=$(jq -rn --arg s "$1" '$s|@uri')
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "$JF/Library/VirtualFolders?name=$nombre_url&collectionType=$2&refreshLibrary=false" \
    -H "Authorization: $AUTH" -H "Content-Type: application/json" \
    -d "$(jq -n --arg p "$3" '{LibraryOptions:{
          PathInfos:[{Path:$p}],
          PreferredMetadataLanguage:"es",
          MetadataCountryCode:"PY",
          EnableRealtimeMonitor:true }}')")
  if [ "$code" = "204" ] || [ "$code" = "200" ]; then ok "$1 → $3"
  else err "$1 (código $code)"; fi
}

add_lib "Películas" movies  /data/media/movies
add_lib "Series"    tvshows /data/media/tv
add_lib "Música"    music   /data/media/music

curl -s -X POST -H "Authorization: $AUTH" "$JF/Library/Refresh" >/dev/null
ok "Escaneo de bibliotecas iniciado"

echo -e "\nListo. Entrá a $JF desde el navegador con tu usuario."
echo "Guardá el usuario y la contraseña: los vas a usar para entrar a Seerr."
