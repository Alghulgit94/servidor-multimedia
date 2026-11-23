#!/usr/bin/env bash
# =====================================================================
#  YouTube Music -> servidor multimedia
#   A. Descarga tus "Me gusta" y las playlists que elijas, en calidad
#      Premium, y crea las mismas playlists en Jellyfin (cada 3 horas)
#   B. Agrega a Lidarr los artistas que más escuchás (discografía)
#  Uso:  sudo bash scripts/12-instalar-ytmusic.sh
#  Se puede ejecutar de nuevo para cambiar playlists o renovar cookies.
# =====================================================================

[ -f "$(dirname "$0")/lib.sh" ] && source "$(dirname "$0")/lib.sh"
DATA_DIR="${DATA_DIR:-/DATA}"; APPDATA="${APPDATA:-$DATA_DIR/AppData}"
PUID="${PUID:-1000}"; PGID="${PGID:-1000}"
YTDIR="$APPDATA/ytmusic"
MUSIC_DIR="$DATA_DIR/data/media/ytmusic"
JF=http://localhost:8096
CLIENTE='MediaBrowser Client="Script", Device="Servidor", DeviceId="script-config", Version="1.0"'

ok()   { echo -e "  \e[32m✔\e[0m $1"; }
err()  { echo -e "  \e[31m✘\e[0m $1"; }
info() { echo -e "\n\e[1m$1\e[0m"; }
[ "$(id -u)" -ne 0 ] && { echo "Ejecutalo con sudo"; exit 1; }

# ---------- 1. Herramientas ----------
info "1. Herramientas (yt-dlp, Deno, ffmpeg)"
apt-get install -y -qq ffmpeg unzip jq curl python3 >/dev/null 2>&1
curl -sL -o /usr/local/bin/yt-dlp https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux \
  && chmod +x /usr/local/bin/yt-dlp
if ! command -v deno >/dev/null; then
  curl -sL -o /tmp/deno.zip https://github.com/denoland/deno/releases/latest/download/deno-x86_64-unknown-linux-gnu.zip \
    && unzip -oq /tmp/deno.zip -d /usr/local/bin && chmod +x /usr/local/bin/deno && rm -f /tmp/deno.zip
fi
/usr/local/bin/yt-dlp --version >/dev/null 2>&1 && ok "yt-dlp $(/usr/local/bin/yt-dlp --version)" || { err "No se pudo instalar yt-dlp"; exit 1; }
command -v deno >/dev/null && ok "Deno $(deno --version | head -1 | awk '{print $2}')" || { err "No se pudo instalar Deno"; exit 1; }
command -v ffmpeg >/dev/null && ok "ffmpeg" || { err "No se pudo instalar ffmpeg"; exit 1; }

mkdir -p "$YTDIR" "$MUSIC_DIR"
chown "$PUID:$PGID" "$MUSIC_DIR"; chmod 700 "$YTDIR"

# ---------- 2. Cookies de YouTube ----------
info "2. Cookies de tu cuenta de YouTube"
COOK="$YTDIR/cookies.txt"
probar_cookies() {
  /usr/local/bin/yt-dlp --cookies "$COOK" --flat-playlist --no-warnings -I 1 --print "%(id)s" \
    "https://music.youtube.com/playlist?list=LM" 2>/dev/null | grep -qE '^[A-Za-z0-9_-]{11}$'
}
if [ -s "$COOK" ] && probar_cookies; then
  ok "Las cookies actuales funcionan"
  read -rp "  ¿Querés reemplazarlas igual? (s/N): " R
else
  R=s
fi
if [[ "${R,,}" == s* ]]; then
  cat << 'TXT'
  Cómo exportarlas (en tu PC, una sola vez):
   1. Instalá la extensión "Get cookies.txt LOCALLY" en Chrome/Edge (o "cookies.txt" en Firefox)
      y permitile funcionar en ventanas de incógnito.
   2. Abrí una ventana de INCÓGNITO e iniciá sesión en https://music.youtube.com
   3. En esa misma pestaña, andá a https://www.youtube.com/robots.txt
   4. Con la extensión, exportá las cookies (formato Netscape) y abrí el archivo con el Bloc de notas.
   5. CERRÁ la ventana de incógnito (así las cookies no vencen enseguida).
  Ahora pegá acá TODO el contenido del archivo, apretá Enter y después Ctrl+D:
TXT
  cat > "$COOK"; chmod 600 "$COOK"
  probar_cookies && ok "Cookies válidas: se pudo leer tu lista de Me gusta" \
    || { err "Las cookies no funcionan. Repetí la exportación desde una ventana de incógnito."; exit 1; }
fi

# ---------- 3. Elegir playlists ----------
info "3. Playlists a sincronizar (además de tus Me gusta)"
echo "  Buscando tus playlists..."
mapfile -t PLS < <(/usr/local/bin/yt-dlp --cookies "$COOK" --flat-playlist --no-warnings \
  --print "%(title)s	%(url)s" "https://www.youtube.com/feed/playlists" 2>/dev/null | grep -v "	$")
PLAYLISTS=$(jq -n '[{name:"Me gusta", url:"https://music.youtube.com/playlist?list=LM"}]')
if [ ${#PLS[@]} -eq 0 ]; then
  echo "  No pude listar tus playlists. Podés pegar enlaces a mano (uno por línea, línea vacía para terminar):"
  while read -rp "  Enlace: " U && [ -n "$U" ]; do
    read -rp "  Nombre para esa playlist: " N
    PLAYLISTS=$(echo "$PLAYLISTS" | jq --arg n "$N" --arg u "$U" '. + [{name:$n, url:$u}]')
  done
else
  for i in "${!PLS[@]}"; do printf "   %2d) %s\n" $((i+1)) "${PLS[$i]%%	*}"; done
  read -rp "  Números de las que querés, separados por espacio (Enter = ninguna): " ELEGIDAS
  for n in $ELEGIDAS; do
    L="${PLS[$((n-1))]}"; [ -z "$L" ] && continue
    PLAYLISTS=$(echo "$PLAYLISTS" | jq --arg n "${L%%	*}" --arg u "${L#*	}" '. + [{name:$n, url:$u}]')
  done
fi
ok "Se sincronizan: $(echo "$PLAYLISTS" | jq -r '[.[].name] | join(", ")')"

# ---------- 4. Jellyfin ----------
info "4. Jellyfin"
[ -z "${JF_USER+x}" ] && read -rp "  Usuario de Jellyfin: " JF_USER
[ -z "${JF_PASS+x}" ] && { read -rsp "  Contraseña de Jellyfin: " JF_PASS; echo; }
LOGIN=$(curl -s -X POST "$JF/Users/AuthenticateByName" -H "Authorization: $CLIENTE" -H "Content-Type: application/json" \
  -d "$(jq -n --arg u "$JF_USER" --arg p "$JF_PASS" '{Username:$u, Pw:$p}')")
TOKEN=$(echo "$LOGIN" | jq -r '.AccessToken // empty'); JF_UID=$(echo "$LOGIN" | jq -r '.User.Id // empty')
[ -z "$TOKEN" ] && { err "No se pudo iniciar sesión en Jellyfin"; exit 1; }
AUTH="$CLIENTE, Token=\"$TOKEN\""
jfkey() { curl -s -H "Authorization: $AUTH" "$JF/Auth/Keys" | jq -r '.Items[]? | select(.AppName=="YTMusic") | .AccessToken' | head -1; }
JF_KEY=$(jfkey); [ -z "$JF_KEY" ] && { curl -s -o /dev/null -X POST -H "Authorization: $AUTH" "$JF/Auth/Keys?app=YTMusic"; JF_KEY=$(jfkey); }
[ -n "$JF_KEY" ] && ok "API key para la sincronización" || { err "No se pudo crear la API key"; exit 1; }

LIB=$(curl -s -H "Authorization: $AUTH" "$JF/Library/VirtualFolders" | jq -r '.[] | select(.CollectionType=="music") | .Name' | head -1)
if [ -z "$LIB" ]; then
  err "No hay biblioteca de música en Jellyfin (ejecutá antes el script de Jellyfin)"; exit 1
elif curl -s -H "Authorization: $AUTH" "$JF/Library/VirtualFolders" | jq -e --arg n "$LIB" '.[] | select(.Name==$n) | .Locations | index("/data/media/ytmusic")' >/dev/null; then
  ok "La biblioteca \"$LIB\" ya incluye la carpeta de YT Music"
else
  curl -s -o /dev/null -X POST -H "Authorization: $AUTH" -H "Content-Type: application/json" \
    -d "$(jq -n --arg n "$LIB" '{Name:$n, PathInfo:{Path:"/data/media/ytmusic"}}')" "$JF/Library/VirtualFolders/Paths?refreshLibrary=false"
  ok "Carpeta de YT Music agregada a la biblioteca \"$LIB\""
fi

# ---------- 5. Lidarr (camino B) ----------
info "5. Artistas a Lidarr (discografías)"
LIDARR_KEY=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$APPDATA/lidarr/config.xml" 2>/dev/null)
LID_ON=false; MIN=3
if [ -n "$LIDARR_KEY" ] && curl -s -o /dev/null -m 10 http://localhost:8686/ping; then
  read -rp "  ¿Con cuántas canciones tuyas se agrega un artista a Lidarr? (Enter = 3, 0 = desactivar): " M
  M=${M:-3}
  if [ "$M" -gt 0 ] 2>/dev/null; then LID_ON=true; MIN=$M; ok "Artistas con $MIN canciones o más se agregan a Lidarr"
  else echo "  · Camino B desactivado"; fi
else
  echo "  · Lidarr no está encendido: el camino B queda desactivado."
  echo "    Para activarlo: encendé Lidarr y volvé a ejecutar este script."
fi

# ---------- 6. Configuración y servicio ----------
info "6. Sincronización automática"
jq -n --arg c "$COOK" --arg md "$MUSIC_DIR" --arg jk "$JF_KEY" --arg ju "$JF_UID" \
      --argjson pl "$PLAYLISTS" --argjson lon "$LID_ON" --argjson min "$MIN" --arg lk "$LIDARR_KEY" \
      --arg pu "$PUID" --arg pg "$PGID" '{
  cookies:$c, music_dir:$md, jellyfin_music_dir:"/data/media/ytmusic",
  jellyfin_url:"http://localhost:8096", jellyfin_key:$jk, jellyfin_user_id:$ju,
  puid:$pu, pgid:$pg, playlists:$pl,
  lidarr:{enabled:$lon, min_songs:$min, url:"http://localhost:8686", key:$lk} }' > "$YTDIR/config.json"
chmod 600 "$YTDIR/config.json"

cat > /usr/local/bin/ytmusic-sync << 'PYEOF'
#!/usr/bin/env python3
"""Sincroniza YouTube Music -> Jellyfin (canciones y playlists) y artistas -> Lidarr.
Lo ejecuta systemd cada 3 horas. Configuración: __CONF__"""
import json, os, re, subprocess, sys, time, urllib.request, urllib.parse, urllib.error
from datetime import datetime

CONF = "__CONF__"
LOG = "/var/log/ytmusic-sync.log"
VIGILANTE_LOG = "/var/log/media-vigilante.log"
YTDLP = "/usr/local/bin/yt-dlp"
ID_RE = re.compile(r"\[([\w-]{11})\]\.[^./]+$")

cfg = json.load(open(CONF))
BASE = os.path.dirname(CONF)
ARCHIVE = os.path.join(BASE, "archive.txt")
STATE_F = os.path.join(BASE, "state.json")
state = json.load(open(STATE_F)) if os.path.exists(STATE_F) else {"songs": {}, "lidarr_added": []}

def log(msg, alerta=False):
    line = f"{datetime.now():%F %T} {msg}"
    print(line, flush=True)
    with open(LOG, "a") as f: f.write(line + "\n")
    if alerta:
        with open(VIGILANTE_LOG, "a") as f: f.write(f"{datetime.now():%F %T} YT Music: {msg}\n")

def save_state():
    json.dump(state, open(STATE_F, "w"), indent=1)

def run(args, timeout=None):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)

COMMON = [YTDLP, "--cookies", cfg["cookies"], "--ignore-errors", "--no-warnings"]

# ---------- yt-dlp al día (YouTube cambia seguido) ----------
stamp = os.path.join(BASE, ".ultima_actualizacion")
if not os.path.exists(stamp) or time.time() - os.path.getmtime(stamp) > 86400:
    run([YTDLP, "-U"], timeout=300)
    open(stamp, "w").close()

# ---------- 1. Leer Me gusta y playlists ----------
def playlist_ids(url):
    r = run(COMMON + ["--flat-playlist", "--print", "%(id)s", url], timeout=900)
    ids = [l.strip() for l in r.stdout.splitlines() if re.fullmatch(r"[\w-]{11}", l.strip())]
    return ids, r.stderr

listas = {}
for pl in cfg["playlists"]:
    ids, err = playlist_ids(pl["url"])
    if not ids and re.search(r"sign in|login|cookies|confirm you.re not a bot", err, re.I):
        log("ATENCIÓN: las cookies de YouTube vencieron. Exportalas de nuevo (ver README).", alerta=True)
        sys.exit(1)
    listas[pl["name"]] = ids
    log(f"{pl['name']}: {len(ids)} canciones")

# ---------- Jellyfin: escanear y armar playlists ----------
JF, KEY, UID = cfg["jellyfin_url"], cfg["jellyfin_key"], cfg["jellyfin_user_id"]
def jf(method, path, body=None, **q):
    q["ApiKey"] = KEY
    url = f"{JF}{path}?{urllib.parse.urlencode(q)}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        txt = r.read().decode()
        return json.loads(txt) if txt else None

def actualizar_jellyfin(escanear=True):
    try:
        if escanear:
            jf("POST", "/Library/Refresh")
            time.sleep(15)
            for _ in range(60):
                tareas = jf("GET", "/ScheduledTasks")
                if not any(t.get("Key") == "RefreshLibrary" and t.get("State") == "Running" for t in tareas): break
                time.sleep(10)
        items = jf("GET", "/Items", Recursive="true", IncludeItemTypes="Audio", Fields="Path", UserId=UID)["Items"]
        por_id = {}
        for it in items:
            p = it.get("Path") or ""
            m = ID_RE.search(p)
            if m and p.startswith(cfg["jellyfin_music_dir"]): por_id[m.group(1)] = it["Id"]
        existentes = {p["Name"]: p["Id"] for p in
                      jf("GET", "/Items", Recursive="true", IncludeItemTypes="Playlist", UserId=UID)["Items"]}
        for nombre, ids in listas.items():
            titulo = f"{nombre} (YT Music)"
            deseados = [por_id[i] for i in ids if i in por_id]
            if titulo not in existentes:
                if deseados:
                    jf("POST", "/Playlists", {"Name": titulo, "Ids": deseados, "UserId": UID, "MediaType": "Audio"})
                    log(f"Playlist creada: {titulo} ({len(deseados)} canciones)")
                continue
            pid = existentes[titulo]
            actuales = jf("GET", f"/Playlists/{pid}/Items", UserId=UID)["Items"]
            tiene = {x["Id"] for x in actuales}
            agregar = [d for d in deseados if d not in tiene]
            sacar = [x["PlaylistItemId"] for x in actuales if x["Id"] not in set(deseados)]
            for i in range(0, len(agregar), 50):
                jf("POST", f"/Playlists/{pid}/Items", ids=",".join(agregar[i:i+50]), userId=UID)
            if sacar:
                jf("DELETE", f"/Playlists/{pid}/Items", entryIds=",".join(sacar))
            if agregar or sacar:
                log(f"Playlist {titulo}: +{len(agregar)} / -{len(sacar)}")
    except Exception as e:
        log(f"Error con Jellyfin: {e}")

def registrar_archivos():
    for raiz, _, archivos in os.walk(cfg["music_dir"]):
        for a in archivos:
            m = ID_RE.search(a)
            if m and not a.endswith((".part", ".jpg", ".webp", ".ytdl")):
                rel = os.path.relpath(os.path.join(raiz, a), cfg["music_dir"])
                state["songs"][m.group(1)] = {"artista": rel.split(os.sep)[0], "archivo": os.path.join(raiz, a)}
    save_state()
    subprocess.run(["chown", "-R", f"{cfg['puid']}:{cfg['pgid']}", cfg["music_dir"]])

# ---------- 2. Descargar lo nuevo, por tandas ----------
TANDA = 25
LIMITE = 6 * 3600
inicio = time.time()
registrar_archivos()
todos = list(dict.fromkeys(i for ids in listas.values() for i in ids))
nuevos = [i for i in todos if i not in state["songs"]]
out = cfg["music_dir"] + "/%(artists.0,artist,uploader|Desconocido)s/%(album|Singles)s/%(track,title)s [%(id)s].%(ext)s"
if nuevos:
    log(f"Descargando {len(nuevos)} canciones nuevas en tandas de {TANDA}...")
    lote = os.path.join(BASE, "lote.txt")
    for n in range(0, len(nuevos), TANDA):
        restante = LIMITE - (time.time() - inicio)
        if restante < 300:
            log("Se alcanzó el límite de 6 horas; lo que falta se descarga en la próxima pasada"); break
        tanda = nuevos[n:n + TANDA]
        open(lote, "w").write("\n".join(f"https://music.youtube.com/watch?v={i}" for i in tanda))
        try:
            run(COMMON + [
                "-a", lote, "--download-archive", ARCHIVE, "--no-playlist",
                "-f", "774/251/bestaudio", "-x", "--audio-quality", "0",
                "--replace-in-metadata", "uploader", r" - Topic$", "",
                "--parse-metadata", "%(artists.0,artist,uploader)s:%(meta_album_artist)s",
                "--embed-metadata", "--embed-thumbnail", "--convert-thumbnails", "jpg",
                "--sleep-requests", "1", "--sleep-interval", "3", "--max-sleep-interval", "10",
                "-o", out], timeout=restante)
        except subprocess.TimeoutExpired:
            log("Se alcanzó el límite de 6 horas; lo que falta se descarga en la próxima pasada")
        registrar_archivos()
        hechas = len([i for i in nuevos if i in state["songs"]])
        log(f"Progreso: {hechas} de {len(nuevos)} descargadas")
        actualizar_jellyfin()
else:
    log("No hay canciones nuevas")
    actualizar_jellyfin(escanear=False)

# ---------- 4. Lidarr: artistas que más escuchás ----------
L = cfg.get("lidarr") or {}
if L.get("enabled"):
    try:
        def lid(method, path, body=None, **q):
            url = f"{L['url']}{path}" + (f"?{urllib.parse.urlencode(q)}" if q else "")
            data = json.dumps(body).encode() if body is not None else None
            req = urllib.request.Request(url, data=data, method=method,
                                         headers={"X-Api-Key": L["key"], "Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=120) as r:
                txt = r.read().decode(); return json.loads(txt) if txt else None
        conteo = {}
        for s in state["songs"].values():
            a = (s.get("artista") or "").strip()
            if a and a != "Desconocido": conteo[a] = conteo.get(a, 0) + 1
        candidatos = [a for a, n in sorted(conteo.items(), key=lambda x: -x[1])
                      if n >= L.get("min_songs", 3) and a not in state["lidarr_added"]]
        if candidatos:
            ya = {x["artistName"].lower() for x in lid("GET", "/api/v1/artist")}
            raiz = lid("GET", "/api/v1/rootfolder")[0]
            for a in candidatos:
                if a.lower() in ya:
                    state["lidarr_added"].append(a); continue
                res = lid("GET", "/api/v1/artist/lookup", term=a) or []
                match = next((r for r in res if r.get("artistName", "").lower() == a.lower()), None)
                if not match:
                    log(f"Lidarr: no encontré a '{a}' (se reintenta en la próxima pasada)"); continue
                match.update({"qualityProfileId": raiz["defaultQualityProfileId"],
                              "metadataProfileId": raiz["defaultMetadataProfileId"],
                              "rootFolderPath": raiz["path"], "monitored": True, "monitorNewItems": "all",
                              "addOptions": {"monitor": "all", "searchForMissingAlbums": True}})
                lid("POST", "/api/v1/artist", match)
                state["lidarr_added"].append(a)
                log(f"Lidarr: agregado {a} ({conteo[a]} canciones tuyas)")
            save_state()
    except Exception as e:
        log(f"Lidarr no disponible o con error: {e}")

log("Sincronización terminada")
PYEOF
sed -i "s#__CONF__#$YTDIR/config.json#g" /usr/local/bin/ytmusic-sync
chmod +x /usr/local/bin/ytmusic-sync

cat > /etc/systemd/system/ytmusic-sync.service << 'UNIT'
[Unit]
Description=Sincronización de YouTube Music con Jellyfin y Lidarr
After=docker.service network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ytmusic-sync
Nice=10
UNIT
cat > /etc/systemd/system/ytmusic-sync.timer << 'UNIT'
[Unit]
Description=Sincroniza YouTube Music cada 3 horas

[Timer]
OnBootSec=10min
OnUnitActiveSec=3h
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now ytmusic-sync.timer >/dev/null 2>&1
systemctl is-active --quiet ytmusic-sync.timer && ok "Se sincroniza sola cada 3 horas" || err "El temporizador no quedó activo"
systemctl start --no-block ytmusic-sync.service
ok "Primera sincronización iniciada en segundo plano"

info "Listo."
echo "  La primera vez puede tardar bastante (descarga todo de cero)."
echo "  • Ver el progreso:        sudo tail -f /var/log/ytmusic-sync.log   (Ctrl+C para salir)"
echo "  • Sincronizar ya:         sudo systemctl start ytmusic-sync"
echo "  • Cambiar playlists o renovar cookies: volvé a ejecutar este script"
echo "  Las playlists aparecen en Jellyfin como \"Nombre (YT Music)\"."
