# Immich's hooks for the chassis core (sourced by run-core.sh). The core
# gives: say, phase, env_get/env_set, rand, compose, in_volume, cname, svc_up,
# state_of, leave_secret, make_backup, record_backup, wait_ready, failed,
# fresh, now, qr_png_b64, for_window, MSG, VAR, APP, LOG, PKG_NAME, PKG_TITLE.
#
# Immich's own API does the work. Your administrator account is made at the
# first start through Immich's admin sign-up, and from that sign-in the
# package keeps an API key of its own (root-only, in .env); your password is
# never stored. The administrator's password is reset with Immich's own
# immich-admin. Photo folders you add are bind-mounted read-only at the path
# they have on the NAS and become Immich external libraries. Machine learning
# is a container of its own, run only while it's switched on.
#
# The package pins one Immich release (below). A package update that pins a
# newer one backs up the database before the new version touches it.

PIN_VERSION=v3.3.1
PIN_SERVER=ghcr.io/immich-app/immich-server:v3.3.1
PIN_ML=ghcr.io/immich-app/immich-machine-learning:v3.3.1
PIN_DB=ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23
PIN_REDIS=docker.io/valkey/valkey:9@sha256:c123e3715db63d06d4ad6964884037aa0d5d4d703939b9929954112889708e1d
SLOTS="1 2 3 4 5"                      # photo folders: LIB<n>_DIR / _SRC / _ID in .env, mounts in compose.yaml
EXCLUDE='["**/@eaDir/**","**/._*","**/#recycle/**","**/#snapshot/**"]'   # DSM's own thumbnails, the recycle bin and snapshots aren't photos
IS=""; IDB=""; IML=""; IM_CODE=0

app_validate() {   # key value → 0 if the value has the key's shape
  case "$1" in
    ADMIN_EMAIL|USER_EMAIL) [[ "$2" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && (( ${#2} <= 120 )) ;;
    ADMIN_NAME_B64|USER_NAME_B64) [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] && (( ${#2} <= 400 )) ;;
    PHOTO_DIR_B64|LIB_DIR_B64) [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] && (( ${#2} <= 700 )) ;;
    ML_ON)    [[ "$2" =~ ^[01]$ ]] ;;
    LIB_OWNER|LIB_ID) [[ "$2" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ;;
    ROLE)     [[ "$2" =~ ^(user|admin)$ ]] ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------ helpers
b64d() { local s=${1//-/+}; s=${s//_//}; while (( ${#s} % 4 )); do s="$s="; done; printf '%s' "$s" | base64 -d 2>/dev/null; }
env_set_q() { local v=${2//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\$/\$\$}; env_set "$1" "\"$v\""; }
env_get_q() { local v; v=$(env_get "$1"); v=${v#\"}; v=${v%\"}; v=${v//\$\$/\$}; v=${v//\\\"/\"}; printf '%s' "${v//\\\\/\\}"; }
strong_password() { echo "$(rand 5)-$(rand 5)-$(rand 5)-$(rand 5)"; }
im_url() { echo "http://127.0.0.1:$(env_get HTTP_PORT)"; }
api() {   # method path [json] → body, as the package (its API key); HTTP code in IM_CODE
  local key out; key=$(env_get IMMICH_API_KEY); [[ -n "$key" ]] || { IM_CODE=0; echo 0 > "$VAR/.im-code"; return 1; }
  out=$(curl -s --max-time 30 -X "$1" "$(im_url)/api/$2" -H "x-api-key: $key" -H 'Accept: application/json' -H 'Content-Type: application/json' ${3:+--data-binary "$3"} -w '\n%{http_code}' 2>/dev/null)
  IM_CODE=${out##*$'\n'}; out=${out%$'\n'*}; printf '%s' "$IM_CODE" > "$VAR/.im-code"   # callers in $( ) can't see IM_CODE: im_code reads it
  printf '%s' "$out"; [[ "$IM_CODE" =~ ^2 ]]
}
api_err() { jq -r '(.message | if type == "array" then join("; ") else . end) // .error // empty' <<< "$1" 2>/dev/null | head -c 200; }
im_code() { cat "$VAR/.im-code" 2>/dev/null || echo "?"; }
public() { curl -s --max-time 10 "$(im_url)/api/$1" 2>/dev/null; }
ml_on() { [[ "$(env_get ML_ENABLED)" == true ]]; }
ml_env() { if [[ "$1" == 1 ]]; then env_set ML_ENABLED true; env_set COMPOSE_PROFILES ml; else env_set ML_ENABLED false; env_set COMPOSE_PROFILES ""; fi; }
pin_env() { env_set IMMICH_VERSION "$PIN_VERSION"; env_set IMMICH_IMAGE "$PIN_SERVER"; env_set ML_IMAGE "$PIN_ML"; env_set DB_IMAGE "$PIN_DB"; env_set REDIS_IMAGE "$PIN_REDIS"; }
pull_image() {   # image → pulled if it isn't here yet, with the phase shown
  docker image inspect "$1" >/dev/null 2>&1 && return 0
  phase "pulling ${1%%@*} (follow it in the log)"
  docker pull "$1" 2>&1 | grep -vE '^\s*$' | tail -n 20 | tee -a "$LOG" >/dev/null || true
  docker image inspect "$1" >/dev/null 2>&1
}
db_ready() { docker exec "$IDB" pg_isready -q -h 127.0.0.1 -p 5432 -U postgres -d immich >/dev/null 2>&1; }   # over TCP: not the first start's temporary server
db_wait() { local i; for i in $(seq 1 "${1:-90}"); do db_ready && return 0; sleep 2; done; return 1; }
mem_mb() {   # docker stats' "123.4MiB / 15GiB" → 123
  awk '{ v = $1; u = v; gsub(/[0-9.]/, "", u); sub(/[A-Za-z]+$/, "", v); m = (u == "GiB" || u == "GB") ? 1024 : (u == "KiB" || u == "kB") ? 1 / 1024 : (u == "B") ? 1 / 1048576 : 1; printf "%d\n", v * m + 0.5 }'
}

# ------------------------------------------------------------ photo folders (read-only, as external libraries)
dir_shape_ok() { [[ "$1" == /* && "$1" != *..* && "$1" != *[,\"\$\\$'\n']* && "$1" != /data* && ${#1} -le 300 && "$1" =~ ^[^[:cntrl:]]+$ ]]; }
# --mount, not -v: -v would quietly create a folder that isn't there.
dir_ok() { dir_shape_ok "$1" && docker run --rm --mount "type=bind,source=$1,target=/m,readonly" --entrypoint sh "$PKG_NAME-setup:local" -c 'test -d /m' >/dev/null 2>&1; }
dir_count() {   # path → photo and video files Immich would read there (DSM's @eaDir thumbnails left out)
  docker run --rm --mount "type=bind,source=$1,target=/m,readonly" --entrypoint sh "$PKG_NAME-setup:local" -c \
    'timeout 120 find /m \( -name "@eaDir" -o -name "#recycle" -o -name "#snapshot" \) -prune -o -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.heic" -o -iname "*.heif" -o -iname "*.webp" -o -iname "*.gif" -o -iname "*.tif" -o -iname "*.tiff" -o -iname "*.avif" -o -iname "*.jxl" -o -iname "*.dng" -o -iname "*.cr2" -o -iname "*.cr3" -o -iname "*.nef" -o -iname "*.arw" -o -iname "*.raf" -o -iname "*.orf" -o -iname "*.rw2" -o -iname "*.mp4" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.3gp" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mts" -o -iname "*.webm" \) -print 2>/dev/null | wc -l' 2>/dev/null | tr -cd '0-9'
}
lib_src() {   # slot → what compose mounts: the folder, or the empty placeholder while it's missing (1 when missing)
  local dir; dir=$(env_get_q "LIB$1_DIR")
  if [[ -z "$dir" ]]; then env_set "LIB$1_SRC" ""; return 0; fi
  if dir_ok "$dir"; then env_set_q "LIB$1_SRC" "$dir"; else env_set "LIB$1_SRC" ./no-library; return 1; fi
}
lib_clear() { env_set "LIB$1_DIR" ""; env_set "LIB$1_SRC" ""; env_set "LIB$1_ID" ""; }
slot_of_id() { local n; for n in $SLOTS; do [[ "$(env_get "LIB${n}_ID")" == "$1" ]] && { echo "$n"; return 0; }; done; return 1; }
admin_id() { api GET users/me | jq -r '.id // empty' 2>/dev/null; }
lib_create() {   # slot [owner id] → an Immich external library reading the slot's folder, scanned at once
  local n=$1 owner=${2:-} dir out id
  dir=$(env_get_q "LIB${n}_DIR"); [[ -n "$owner" ]] || owner=$(admin_id)
  [[ -n "$owner" ]] || { MSG="The package can't reach Immich's API to make the library — see the Users tab."; return 1; }
  out=$(api POST libraries "$(jq -cn --arg o "$owner" --arg n "$(basename "$dir")" --arg d "$dir" --argjson x "$EXCLUDE" '{ownerId: $o, name: $n, importPaths: [$d], exclusionPatterns: $x}')") \
    || { MSG="Immich didn't make the library (HTTP $(im_code)): $(api_err "$out")"; return 1; }
  id=$(jq -r '.id // empty' <<< "$out"); [[ "$id" =~ ^[0-9a-f-]{36}$ ]] || { MSG="Immich's answer had no library in it."; return 1; }
  env_set "LIB${n}_ID" "$id"
  api POST "libraries/$id/scan" >/dev/null || say "the first scan of $dir didn't start (HTTP $(im_code)) — Scan now starts it"
  say "library $(basename "$dir") ($id) reads $dir"
}

# ------------------------------------------------------------ lifecycle hooks
app_first_env() {
  pin_env
  env_set DB_PASSWORD "$(rand 32)"; env_set DB_STORAGE_TYPE HDD; env_set UPLOAD_SRC ./photos
  env_set ADMIN_EMAIL "${ADMIN_EMAIL:-admin@example.com}"
  local name dir; name=$(b64d "${ADMIN_NAME_B64:-}" | tr -d '\000-\037' | cut -c1-60); env_set_q ADMIN_NAME "${name:-Admin}"
  ml_env "${ML_ON:-1}"
  for n in $SLOTS; do lib_clear "$n"; done
  dir=$(b64d "${PHOTO_DIR_B64:-}")
  if [[ -n "$dir" ]]; then if dir_shape_ok "$dir"; then env_set_q LIB1_DIR "$dir"; else say "✗ the photo folder from the wizard ($dir) isn't a folder path — add one on the Photo libraries tab"; fi; fi
  touch "$VAR/.needs-admin"
}
app_load_env() { IS=$(cname server); IDB=$(cname database); IML=$(cname machine-learning); rm -f "$VAR/.status-cache"; }
pin_move() {   # this package pins a different Immich than .env runs: back up the database, then move
  local have; have=$(env_get IMMICH_VERSION)
  [[ "$have" == "$PIN_VERSION" ]] && return 0
  if [[ -n "$have" ]] && docker volume inspect "${PKG_NAME}_db" >/dev/null 2>&1; then
    say "this package moves Immich from $have to $PIN_VERSION — first, a backup of the database as $have left it"
    phase "backing up Immich's database before moving to $PIN_VERSION"
    compose up -d database >> "$LOG" 2>&1 || true
    if db_wait 90 && make_backup preupdate; then record_backup true "$MADE"; say "✓ $MADE holds the database as Immich $have left it"
    else record_backup false ""
      failed "Immich's database couldn't be backed up before moving from $have to $PIN_VERSION, so the move didn't start and Immich $have's data is untouched. The lines above say why; Package Center → Immich → Run tries again."; fi
    printf '%s\n' "$have" > "$VAR/.moved-from"
  fi
  pin_env
}
app_before_up() {
  local n var
  mkdir -p "$APP/photos" "$APP/no-library"
  pin_move
  for var in IMMICH_IMAGE DB_IMAGE REDIS_IMAGE; do pull_image "$(env_get "$var")" || say "✗ $(env_get "$var") couldn't be pulled — the lines above say why"; done
  if ml_on; then pull_image "$(env_get ML_IMAGE)" || say "✗ the machine-learning image couldn't be pulled; Immich starts, and tries again"
  else docker rm -f "$IML" >/dev/null 2>&1 || true; fi
  for n in $SLOTS; do lib_src "$n" || say "✗ the photo folder $(env_get_q "LIB${n}_DIR") isn't there — its photos show as offline in Immich until it's back"; done
}
app_health() { [[ "$(curl -s --max-time 5 "$(im_url)/api/server/ping" 2>/dev/null | jq -r '.res // empty' 2>/dev/null)" == pong ]]; }
app_version() { local v; v=$(curl -s --max-time 5 "$(im_url)/api/server/version" 2>/dev/null | jq -r '"\(.major).\(.minor).\(.patch)"' 2>/dev/null); [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$v" || env_get IMMICH_VERSION | tr -d 'v'; }
app_after_up() { make_admin 120; }
make_admin() {   # [tries] — the first time: your administrator through Immich's admin sign-up, then the package's API key from that sign-in
  [[ -f "$VAR/.needs-admin" ]] || return 0
  local i pw email name out code tok key n
  for i in $(seq 1 "${1:-1}"); do app_health && break; sleep 2; done
  app_health || { say "Immich isn't answering yet — your account is made when it does"; return 0; }
  email=$(env_get ADMIN_EMAIL); name=$(env_get_q ADMIN_NAME)
  if [[ "$(public server/config | jq -r '.isInitialized' 2>/dev/null)" == false ]]; then
    pw=$(strong_password)
    out=$(curl -s --max-time 30 -X POST "$(im_url)/api/auth/admin-sign-up" -H 'Content-Type: application/json' \
          -d "$(jq -cn --arg e "$email" --arg n "$name" --arg p "$pw" '{email: $e, name: $n, password: $p}')" -w '\n%{http_code}' 2>/dev/null)
    code=${out##*$'\n'}; out=${out%$'\n'*}
    [[ "$code" =~ ^2 ]] || { say "✗ Immich didn't make your administrator (HTTP $code): $(api_err "$out") — trying again shortly"; return 0; }
    leave_secret "Immich ($email)" "$pw" users
    say "first start: your Immich administrator $email was made; the password is shown once in the window"
    tok=$(curl -s --max-time 30 -X POST "$(im_url)/api/auth/login" -H 'Content-Type: application/json' -d "$(jq -cn --arg e "$email" --arg p "$pw" '{email: $e, password: $p}')" 2>/dev/null | jq -r '.accessToken // empty')
    key=$(curl -s --max-time 30 -X POST "$(im_url)/api/api-keys" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d '{"name":"DSM package (keep this one)","permissions":["all"]}' 2>/dev/null | jq -r '.secret // empty')
    curl -s --max-time 10 -X POST "$(im_url)/api/auth/logout" -H "Authorization: Bearer $tok" -o /dev/null 2>/dev/null || true
    if [[ "$key" =~ ^[A-Za-z0-9_-]{16,200}$ ]]; then env_set IMMICH_API_KEY "$key"; say "the package's own API key for the window is ready"
    else say "✗ the package's API key couldn't be made — Users → Reset the administrator's password makes one"; fi
  elif api GET users/me >/dev/null; then :
  else say "Immich already has an administrator (an earlier database?) and the package has no key for it — Users → Reset the administrator's password connects it"; fi
  rm -f "$VAR/.needs-admin"
  for n in $SLOTS; do   # the photo folder from the wizard (or one whose library couldn't be made before)
    [[ -n "$(env_get_q "LIB${n}_DIR")" && -z "$(env_get "LIB${n}_ID")" ]] || continue
    if [[ "$(env_get "LIB${n}_SRC")" == ./no-library ]]; then say "✗ the photo folder $(env_get_q "LIB${n}_DIR") isn't there, so no library was made for it — add it on the Photo libraries tab once it is"; lib_clear "$n"; continue; fi
    lib_create "$n" || say "✗ $MSG"
  done
  rm -f "$VAR/.status-cache"
}

# ------------------------------------------------------------ what the window shows
container_mem() {   # → {"server": 412, …} in MB, for the containers that are running
  local names=() s; for s in $SERVICES machine-learning; do svc_up "$s" && names+=("$(cname "$s")"); done
  (( ${#names[@]} )) || { echo "{}"; return 0; }
  docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}' "${names[@]}" 2>/dev/null | while IFS=$'\t' read -r n u; do printf '%s\t%s\n' "${n#"$PKG_NAME"-}" "$(mem_mb <<< "$u")"; done \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber? // 0)}) | from_entries' 2>/dev/null || echo "{}"
}
app_status() {   # the window's view, kept for 30 seconds (an action clears it)
  svc_up server || { echo '{"up": false}'; return 0; }
  if fresh "$VAR/.status-cache" 30 && [[ -s "$VAR/.status-cache" ]]; then cat "$VAR/.status-cache"; return 0; fi
  local users stats libs lstats="{}" id s features queues slots="[]" n mem total avail url qr api_ok=true out
  users=$(api GET admin/users) || { users="[]"; api_ok=false; }
  stats=$(api GET server/statistics) || stats="null"
  libs=$(api GET libraries) || libs="[]"
  for id in $(jq -r '.[]?.id' <<< "$libs" 2>/dev/null); do
    [[ "$id" =~ ^[0-9a-f-]{36}$ ]] || continue; s=$(api GET "libraries/$id/statistics") || continue
    lstats=$(jq -c --arg id "$id" --argjson s "$s" '. + {($id): $s}' <<< "$lstats" 2>/dev/null || echo "$lstats")
  done
  features=$(public server/features); jq -e . >/dev/null 2>&1 <<< "$features" || features="null"
  queues=$(api GET queues | jq -c 'map({key: .name, value: (.statistics + {paused: .isPaused})}) | from_entries' 2>/dev/null); [[ "$queues" == \{* ]] || queues="null"
  for n in $SLOTS; do
    slots=$(jq -c --argjson n "$n" --arg dir "$(env_get_q "LIB${n}_DIR")" --arg id "$(env_get "LIB${n}_ID")" --arg src "$(env_get "LIB${n}_SRC")" \
      '. + [{slot: $n, dir: $dir, id: $id, missing: ($dir != "" and $src == "./no-library")}]' <<< "$slots"); done
  read -r total avail < <(free -m 2>/dev/null | awk '/^Mem:/ {print $2, $7}')
  mem=$(container_mem)
  url=$(env_get APP_URL)
  if [[ "$(cat "$VAR/qr.url" 2>/dev/null)" != "$url" || ! -s "$VAR/qr.b64" ]]; then qr_png_b64 "$url" > "$VAR/qr.b64.tmp" && mv "$VAR/qr.b64.tmp" "$VAR/qr.b64"; printf '%s' "$url" > "$VAR/qr.url"; fi
  qr=$(cat "$VAR/qr.b64" 2>/dev/null)
  out=$(jq -n -c --argjson users "$users" --argjson stats "$stats" --argjson libs "$libs" --argjson lstats "$lstats" --argjson features "$features" --argjson queues "$queues" \
     --argjson slots "$slots" --argjson mem "$mem" --arg total "${total:-0}" --arg avail "${avail:-0}" --argjson api_ok "$api_ok" \
     --arg url "$url" --arg me "$(env_get ADMIN_EMAIL)" --arg qr "$qr" --arg ml "$(env_get ML_ENABLED)" --arg ml_state "$(state_of "$IML" | tail -n 1 | cut -d' ' -f1)" \
     --arg pin "$(env_get IMMICH_VERSION)" --arg latest "$(cat "$VAR/.immich-latest" 2>/dev/null)" --arg moved "$(cat "$VAR/.moved-from" 2>/dev/null)" \
     --arg free_slots "$(for n in $SLOTS; do [[ -z "$(env_get_q "LIB${n}_DIR")" ]] && echo "$n"; done | wc -l | tr -cd '0-9')" \
     '($users | map({key: .id, value: .name}) | from_entries) as $names
      | ((($stats // {}).usageByUser // []) | map({key: .userId, value: .}) | from_entries) as $usage
      | {up: true, url: $url, me: $me, api_ok: $api_ok, qr: $qr, pin: $pin, latest: $latest, moved_from: $moved,
         stats: (if $stats then {photos: $stats.photos, videos: $stats.videos, usage: $stats.usage} else null end),
         users: ($users | map({id, email, name, admin: .isAdmin, status, change: .shouldChangePassword, photos: ($usage[.id].photos // 0), videos: ($usage[.id].videos // 0), usage: ($usage[.id].usage // 0)})),
         libraries: ($libs | map(. as $l | ($slots | map(select(.id == $l.id)) | .[0]) as $s
                       | {id, name, paths: .importPaths, owner: ($names[.ownerId] // "someone"), owner_id: .ownerId, refreshed: .refreshedAt, assets: .assetCount,
                          photos: ($lstats[.id].photos // null), videos: ($lstats[.id].videos // null), slot: ($s.slot // null), missing: ($s.missing // false)})),
         slots: $slots, free_slots: ($free_slots | tonumber),
         ml: {on: ($ml == "true"), state: $ml_state, smart_search: ($features.smartSearch // false), faces: ($features.facialRecognition // false), duplicates: ($features.duplicateDetection // false), ocr: ($features.ocr // false)},
         queues: $queues, memory: {total_mb: ($total | tonumber), available_mb: ($avail | tonumber), containers: $mem}}' 2>/dev/null)
  [[ "$out" == \{* ]] || out='{"up": true}'
  printf '%s' "$out" > "$VAR/.status-cache"; printf '%s' "$out"
}

# ------------------------------------------------------------ updates: the pinned release, and what Immich has out
app_check_updates() {
  local loc tag
  loc=$(curl -sI --max-time 15 https://github.com/immich-app/immich/releases/latest 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1) == "location" {print $2}' | tail -n 1)
  tag=${loc##*/}; [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s\n' "$tag" > "$VAR/.immich-latest"
  # Immich's images are pinned, and come from GitHub's registry: there's no newer image of the same tag to pull. Newer Immich comes with a package update.
  IMAGE_UPDATE=$(jq -n -c --arg img "$(env_get IMMICH_IMAGE)" --argjson at "$(now)" '{checked: $at, image: $img, available: false, pinned: true}')
  rm -f "$VAR/.status-cache"
}

# ------------------------------------------------------------ the loop's own checks
app_tick() {
  local n changed=0
  make_admin 1
  if ! fresh "$VAR/.lib-wait" 600; then   # a photo folder that was missing is back: mount it and read it again
    touch "$VAR/.lib-wait"
    for n in $SLOTS; do [[ "$(env_get "LIB${n}_SRC")" == ./no-library ]] || continue; lib_src "$n" && { say "the photo folder $(env_get_q "LIB${n}_DIR") is there again — Immich is reading it"; changed=1; }; done
    if (( changed )); then compose up -d server >> "$LOG" 2>&1 && wait_ready 300 && for n in $SLOTS; do [[ -n "$(env_get "LIB${n}_ID")" ]] && api POST "libraries/$(env_get "LIB${n}_ID")/scan" >/dev/null; done; rm -f "$VAR/.status-cache"; fi
  fi
  # Machine learning is on but its container has stopped: start it again (at most every 10 minutes).
  if ml_on && ! svc_up machine-learning && ! fresh "$VAR/.ml-restart" 600; then
    touch "$VAR/.ml-restart"; say "the machine-learning container isn't running — starting it again"
    compose up -d machine-learning >> "$LOG" 2>&1 || true
  fi
  return 0
}

# ------------------------------------------------------------ logs, storage, backups, report
app_logs() {
  docker inspect "$IML" >/dev/null 2>&1 || { echo "Machine learning is off: its container isn't running." > "$VAR/logs/machine-learning.log.tmp"; for_window "$VAR/logs/machine-learning.log"; return 0; }
  docker logs --tail 300 "$IML" > "$VAR/logs/machine-learning.log.tmp" 2>&1 || true; for_window "$VAR/logs/machine-learning.log"
}
app_storage() {   # the photos folder in this shared folder, part by part (du has a minute at most)
  local d mb
  for d in library upload thumbs encoded-video profile backups; do
    [[ -d "$APP/photos/$d" ]] || continue
    mb=$(timeout 60 du -sm "$APP/photos/$d" 2>/dev/null | cut -f1); printf '%s\t%s\n' "$d" "${mb:-0}"
  done | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber? // 0)}) | from_entries' 2>/dev/null || echo "{}"
}
app_backup() {   # dir — Immich's database, dumped as Immich documents it (pg_dump --clean --if-exists)
  svc_up database || { compose up -d database >> "$LOG" 2>&1 || true; }
  db_wait 60 || { say "✗ Immich's database isn't answering, so it couldn't be dumped"; return 1; }
  docker exec "$IDB" pg_dump --clean --if-exists --dbname=immich --username=postgres 2>>"$LOG" | gzip > "$1/immich-db.sql.gz" || { say "✗ the database dump didn't finish"; return 1; }
  grep -q 'PostgreSQL database dump complete' < <(gzip -dc "$1/immich-db.sql.gz" 2>/dev/null | tail -n 5) || { say "✗ the database dump is incomplete"; return 1; }
  printf 'immich=%s\n' "$(env_get IMMICH_VERSION)" > "$1/IMMICH"
}
app_restore() {   # dir — the core has stopped the containers. A fresh database, then the dump, as Immich's own restore steps do it.
  local f="$1/immich-db.sql.gz" made
  [[ -s "$f" ]] || { MSG="That backup has no database dump in it."; return 1; }
  grep -q 'PostgreSQL database dump complete' < <(gzip -dc "$f" 2>/dev/null | tail -n 5) || { MSG="That backup's database dump is incomplete, so nothing was restored."; return 1; }
  made=$(sed -n 's/^immich=\(v[0-9][0-9.]*\)$/\1/p' "$1/IMMICH" 2>/dev/null)
  if [[ -n "$made" && "$made" != "$(env_get IMMICH_VERSION)" && "$(printf '%s\n%s\n' "$made" "$(env_get IMMICH_VERSION)" | sort -V | tail -n 1)" == "$made" ]]; then
    MSG="That backup was made by Immich $made, newer than the $(env_get IMMICH_VERSION) this package runs — it can't be restored here."; compose up -d >> "$LOG" 2>&1; return 1; fi
  say "restoring Immich's database (made by Immich ${made:-?}) into a fresh one"
  docker rm -f "$IDB" >> "$LOG" 2>&1 || true
  in_volume db rw -- 'find /vol -mindepth 1 -delete' </dev/null 2>>"$LOG" || { MSG="The old database couldn't be cleared; Immich is left stopped — the log says more."; return 1; }
  compose up -d database >> "$LOG" 2>&1 || { MSG="The database didn't start; Immich is left stopped."; return 1; }
  db_wait 90 || { MSG="The fresh database didn't answer; Immich is left stopped."; return 1; }
  gzip -dc "$f" | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
    | docker exec -i "$IDB" psql -X -q --dbname=immich --username=postgres --single-transaction --set ON_ERROR_STOP=on >/dev/null 2>>"$LOG" \
    || { MSG="The database didn't load (the log says why); Immich is left stopped."; return 1; }
  rm -f "$VAR/.status-cache"
}
app_report() {
  echo "== Immich: pinned $(env_get IMMICH_VERSION), running $(app_version), newest $(cat "$VAR/.immich-latest" 2>/dev/null || echo '?')"
  echo "== machine learning: $(env_get ML_ENABLED) (container $(state_of "$IML" | tail -n 1))"
  echo "== package API key works: $(api GET users/me >/dev/null && echo yes || echo "no (HTTP $(im_code))")"
  echo "== users"; api GET admin/users 2>/dev/null | jq -r '.[] | .email + "  " + (if .isAdmin then "admin" else "user" end) + "  " + (.status // "")'
  echo "== libraries"; api GET libraries 2>/dev/null | jq -r '.[] | .name + "  " + (.importPaths | join(",")) + "  " + (.assetCount | tostring) + " assets, scanned " + (.refreshedAt // "never")'
  local n; for n in $SLOTS; do [[ -n "$(env_get_q "LIB${n}_DIR")" ]] && echo "slot $n: $(env_get_q "LIB${n}_DIR") (mounted: $(env_get_q "LIB${n}_SRC"))"; done
  echo "== statistics"; api GET server/statistics 2>/dev/null | jq -c '{photos, videos, usage}'
  echo "== queues"; api GET queues 2>/dev/null | jq -r '.[] | select(.statistics.active + .statistics.waiting + .statistics.failed > 0) | .name + ": " + (.statistics | tostring)'
  echo "== memory (MB)"; container_mem
  :
}
app_wipe() {
  docker rm -f "$IML" >> "$LOG" 2>&1 || true
  docker image rm "$(env_get ML_IMAGE)" >> "$LOG" 2>&1 || true
}

# ------------------------------------------------------------ the window's actions
ml_config() {   # true|false → Immich's own setting follows the switch (the environment sets only its default)
  local cfg path
  for path in admin/config system-config; do
    cfg=$(api GET "$path") || continue
    [[ "$(jq -r '.machineLearning.enabled' <<< "$cfg" 2>/dev/null)" == "$1" ]] && return 0
    api PUT "$path" "$(jq -c --argjson on "$1" '.machineLearning.enabled = $on' <<< "$cfg")" >/dev/null && return 0
  done
  say "Immich's own machine-learning setting couldn't be changed (HTTP $(im_code)) — Administration → Settings → Machine Learning has it"; return 1
}
reset_admin_pw() {   # → the new password in PW, the administrator's email in WHO, through Immich's own immich-admin
  local out; PW=$(strong_password); WHO=""
  # Its questions need a terminal (piped answers wait for ever): script(1) in the server's image gives it one, and Enter is \r there.
  # Answers typed before a question appears can be dropped, so after the password it gets Enter every two seconds: "Invalidate
  # existing sessions?" defaults to yes. Had the password itself been dropped, Immich picks one and prints it — that's taken instead.
  out=$({ printf '%s\r' "$PW"; for _ in $(seq 1 50); do sleep 2; printf '\r'; done; } 2>/dev/null \
        | timeout 120 docker exec -i "$IS" script -qc "immich-admin reset-admin-password" /dev/null 2>&1 | tr -d '\r' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')
  WHO=$(sed -n 's/^- Email=\(.*\)$/\1/p' <<< "$out" | head -n 1 | tr -cd 'A-Za-z0-9._+@-')
  if grep -q 'admin password has been updated to:' <<< "$out"; then PW=$(sed -n '/has been updated to:/{n;p;q}' <<< "$out" | tr -d '[:space:]'); fi
  if grep -q 'admin password has been updated' <<< "$out" && [[ -n "$PW" ]]; then say "immich-admin reset the password of $WHO"; return 0; fi
  # The terminal echoes what was typed, letter by letter: those lines never go into the log.
  say "immich-admin didn't take it: $(grep -vE '^\s*$|choose a new password' <<< "$out" | grep -vF "$PW" | tail -n 3 | tr '\n' ' ' | cut -c1-300)"
  return 1
}
signin_ok() { [[ -n "$(curl -s --max-time 30 -X POST "$(im_url)/api/auth/login" -H 'Content-Type: application/json' -d "$(jq -cn --arg e "$1" --arg p "$2" '{email: $e, password: $p}')" 2>/dev/null | jq -r '.accessToken // empty')" ]]; }
reconnect() {   # email password → a new API key for the package from that sign-in
  local tok key
  tok=$(curl -s --max-time 30 -X POST "$(im_url)/api/auth/login" -H 'Content-Type: application/json' -d "$(jq -cn --arg e "$1" --arg p "$2" '{email: $e, password: $p}')" 2>/dev/null | jq -r '.accessToken // empty')
  [[ -n "$tok" ]] || return 1
  key=$(curl -s --max-time 30 -X POST "$(im_url)/api/api-keys" -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' -d '{"name":"DSM package (keep this one)","permissions":["all"]}' 2>/dev/null | jq -r '.secret // empty')
  curl -s --max-time 10 -X POST "$(im_url)/api/auth/logout" -H "Authorization: Bearer $tok" -o /dev/null 2>/dev/null || true
  [[ "$key" =~ ^[A-Za-z0-9_-]{16,200}$ ]] || return 1
  env_set IMMICH_API_KEY "$key"; say "the package has a new API key for the window"
}
app_act() {   # action (request vars are set)
  local dir n m free="" count owner out name pw was id
  rm -f "$VAR/.status-cache"
  case "$1" in
    libadd)
      dir=$(b64d "${LIB_DIR_B64:-}"); dir=${dir%/}
      dir_shape_ok "$dir" || { MSG="A folder on the NAS, like /volume1/photo."; return 1; }
      for n in $SLOTS; do m=$(env_get_q "LIB${n}_DIR")
        if [[ -z "$m" ]]; then [[ -n "$free" ]] || free=$n; continue; fi
        [[ "$m" == "$dir" ]] && { MSG="Immich already reads $dir."; return 1; }
        [[ "$dir" == "$m"/* || "$m" == "$dir"/* ]] && { MSG="$dir and $m are one inside the other — Immich would read those photos twice. Use one of them."; return 1; }
      done
      [[ -n "$free" ]] || { MSG="All five photo folders are in use — remove one first."; return 1; }
      dir_ok "$dir" || { MSG="There's no folder $dir on this Synology (it looks like /volume1/photo)."; return 1; }
      owner=${LIB_OWNER:-$(admin_id)}
      name=$(api GET "admin/users/$owner" | jq -r '.name // .email // empty') || { MSG="Pick someone from the users list to own these photos."; return 1; }
      count=$(dir_count "$dir")
      env_set_q "LIB${free}_DIR" "$dir"; lib_src "$free"
      if ! { compose up -d server >> "$LOG" 2>&1 && wait_ready 300; }; then lib_clear "$free"; compose up -d server >> "$LOG" 2>&1; MSG="Immich didn't come back with the folder mounted — see the log."; return 1; fi
      lib_create "$free" "$owner" || { lib_clear "$free"; compose up -d server >> "$LOG" 2>&1; wait_ready 300; return 1; }
      MSG="Immich now shows the photos in $dir (${count:-0} photo and video files) to ${name:-its owner}, read-only. It's reading them now; thumbnails follow." ;;
    libscan)
      if [[ -n "${LIB_ID:-}" ]]; then api POST "libraries/$LIB_ID/scan" >/dev/null || { MSG="Immich didn't start the scan (HTTP $(im_code))."; return 1; }; MSG="Immich is looking for new and changed photos in that library."
      else n=0; for id in $(api GET libraries | jq -r '.[]?.id' 2>/dev/null); do [[ "$id" =~ ^[0-9a-f-]{36}$ ]] && api POST "libraries/$id/scan" >/dev/null && n=$(( n + 1 )); done
        (( n )) || { MSG="There's no library to scan yet — add a photo folder first."; return 1; }; MSG="Immich is looking for new and changed photos in $n $( (( n == 1 )) && echo library || echo libraries)."; fi ;;
    libdel)
      out=$(api GET "libraries/$LIB_ID") || { MSG="There's no such library."; return 1; }
      name=$(jq -r '.name' <<< "$out")
      api DELETE "libraries/$LIB_ID" >/dev/null || { MSG="Immich didn't remove it (HTTP $(im_code))."; return 1; }
      if n=$(slot_of_id "$LIB_ID"); then dir=$(env_get_q "LIB${n}_DIR"); lib_clear "$n"
        compose up -d server >> "$LOG" 2>&1 && wait_ready 300 || { MSG="The library is gone, but Immich didn't come back — see the log."; return 1; }; fi
      MSG="The library $name is removed from Immich, and its photos leave the timeline. ${dir:+The folder $dir is untouched — Immich only ever read it.}" ;;
    ml)
      if [[ "${ON:-0}" == 1 ]]; then
        ml_on && svc_up machine-learning && { MSG="Machine learning is already on."; return 0; }
        pull_image "$(env_get ML_IMAGE)" || { MSG="The machine-learning image couldn't be pulled — see the log. Nothing changed."; return 1; }
        ml_env 1
        if ! { compose up -d >> "$LOG" 2>&1 && wait_ready 300; }; then   # back as it was
          ml_env 0; docker rm -f "$IML" >> "$LOG" 2>&1; compose up -d >> "$LOG" 2>&1; wait_ready 300
          MSG="Machine learning didn't start, so it's off again — see the log."; return 1; fi
        ml_config true
        for m in smartSearch faceDetection; do api PUT "jobs/$m" '{"command":"start","force":false}' >/dev/null || true; done   # the photos already in Immich
        MSG="Machine learning is on: smart search and face recognition. Photos already in Immich are being analysed now — the first time downloads its models (about 1 GB), then they come and go from memory as they're needed."
      else
        was=$(container_mem | jq -r '."machine-learning" // empty' 2>/dev/null)
        ml_env 0; docker rm -f "$IML" >> "$LOG" 2>&1 || true
        compose up -d >> "$LOG" 2>&1 && wait_ready 300 || { MSG="Immich didn't come back — see the log."; return 1; }
        ml_config false
        MSG="Machine learning is off${was:+ — its container was using $was MB}. Smart search and face recognition are off too; uploads, the timeline, albums, sharing and the map work as before."
      fi ;;
    useradd)
      name=$(b64d "${USER_NAME_B64:-}" | tr -d '\000-\037' | cut -c1-60); [[ -n "$name" ]] || name=${USER_EMAIL%@*}
      pw=$(strong_password)
      out=$(api POST admin/users "$(jq -cn --arg e "$USER_EMAIL" --arg n "$name" --arg p "$pw" --argjson a "$([[ "${ROLE:-user}" == admin ]] && echo true || echo false)" '{email: $e, name: $n, password: $p, isAdmin: $a, shouldChangePassword: true}')") \
        || { MSG="Immich didn't add $USER_EMAIL (HTTP $(im_code)): $(api_err "$out")"; return 1; }
      leave_secret "Immich ($USER_EMAIL)" "$pw" users
      MSG="$name ($USER_EMAIL) can sign in now with the password below, shown once; Immich asks them to choose their own at the first sign-in." ;;
    adminpw)
      reset_admin_pw || { MSG="Immich's immich-admin couldn't reset the password — see the log."; return 1; }
      signin_ok "$WHO" "$PW" || { MSG="The password was reset, but signing in with it didn't work — see the log."; return 1; }
      api GET users/me >/dev/null || reconnect "$WHO" "$PW" || say "✗ the package couldn't make a new API key"
      leave_secret "Immich ($WHO)" "$PW" users
      MSG="The password of Immich's administrator ($WHO) is reset — the new one is below, shown once. Everyone signed in as $WHO is signed out." ;;
    *) MSG="Unknown request."; return 1 ;;
  esac
}
