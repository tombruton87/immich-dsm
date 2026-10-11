# Immich's steps for the chassis harness (chassis/tests/e2e.sh <appdir> act).
# The photo folders are a few small JPEGs (with dates) and a one-second video made on the spot,
# plus a DSM-style @eaDir thumbnail that must not be imported.
# Machine learning stays off unless E2E_ML=1 (it needs 1–2 GB of memory); its switch is checked either way.
PHOTOS=$E2E/photos
make_photos() {   # dir n prefix [video]
  mkdir -p "$1/@eaDir/x.jpg"
  python3 - "$1" "$2" "$3" <<'PY'
import sys, random
from PIL import Image, ImageDraw
d, n, prefix = sys.argv[1], int(sys.argv[2]), sys.argv[3]
for i in range(1, n + 1):
    random.seed(f"{prefix}{i}")
    img = Image.new("RGB", (320, 240), tuple(random.randrange(256) for _ in range(3)))
    dr = ImageDraw.Draw(img)
    for _ in range(12):
        x, y = random.randrange(280), random.randrange(200)
        dr.ellipse([x, y, x + 10 + random.randrange(40), y + 10 + random.randrange(40)], fill=tuple(random.randrange(256) for _ in range(3)))
    ex = img.getexif(); ex.get_ifd(0x8769)[0x9003] = f"2024:0{i % 9 + 1}:1{i % 9} 12:00:00"
    img.save(f"{d}/{prefix}-{i:02d}.jpg", quality=85, exif=ex)
Image.new("RGB", (64, 64), (200, 200, 200)).save(f"{d}/@eaDir/x.jpg/SYNOPHOTO_THUMB_S.jpg")
PY
  [[ -n "${4:-}" ]] && ffmpeg -loglevel error -f lavfi -i testsrc=duration=1:size=320x240:rate=10 -pix_fmt yuv420p -y "$1/$3-clip.mp4" </dev/null
  true
}
b64u() { printf '%s' "$1" | base64 -w0 | tr -d '=' | tr '+/' '-_'; }
app_e2e_answers() {
  [[ -f "$PHOTOS/holiday-01.jpg" ]] || make_photos "$PHOTOS" 4 holiday video
  printf "ADMIN_EMAIL='ada@example.com'\nADMIN_NAME_B64='%s'\nPHOTO_DIR_B64='%s'\nML_ON='0'\n" "$(b64u 'Ada Lovelace')" "$(b64u "$PHOTOS")"
}
wait_for() { local i; for i in $(seq 1 "$2"); do touch "$VAR/watching"; jq -e "$1" "$VAR/status.json" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
secret() { local s; s=$(jq -r 'select(.kind == "users") | .password' "$VAR/secret.json" 2>/dev/null); rm -f "$VAR/secret.json"; printf '%s' "$s"; }
token() { curl -s -X POST "http://127.0.0.1:$PORT/api/auth/login" -H 'Content-Type: application/json' -d "$(jq -cn --arg e "$1" --arg p "$2" '{email: $e, password: $p}')" | jq -r '.accessToken // empty'; }
envv() { docker run --rm -v "$APP:/s:ro" --entrypoint sh immich-setup:local -c "grep -E '^$1=' /s/.env | tail -n 1 | cut -d= -f2-"; }
app_e2e_act() {
  local fail=0 url="http://127.0.0.1:$PORT" pw pw2 tok bob lib2 id n name
  log "immich"
  echo "  (ping: $(curl -s "$url/api/server/ping" | jq -c .), version $(jq -r .version "$VAR/status.json"), memory: $(jq -c .app.memory.containers "$VAR/status.json"))"
  pw=$(secret)
  [[ ${#pw} -ge 20 ]] && echo "  ok   a one-time password was left for the window" || { echo "  FAIL no password secret"; fail=1; }
  tok=$(token ada@example.com "$pw"); [[ -n "$tok" ]] && echo "  ok   ada@example.com signs in with it" || { echo "  FAIL sign-in"; fail=1; }
  [[ "$(curl -s "$url/api/users/me" -H "Authorization: Bearer $tok" | jq -r '.name + "|" + (.isAdmin | tostring)')" == "Ada Lovelace|true" ]] && echo "  ok   …as the administrator, Ada Lovelace (name from the wizard, base64url)" || { echo "  FAIL admin user"; fail=1; }
  [[ -n "$(envv IMMICH_API_KEY)" && -z "$(docker exec immich-server printenv IMMICH_API_KEY)" ]] && echo "  ok   the package's API key is in the root-only .env, not in Immich's environment" || { echo "  FAIL api key placement"; fail=1; }
  # The wizard's photo folder: 4 photos and a video; DSM's @eaDir thumbnail is skipped.
  wait_for '.app.libraries | length == 1 and .[0].photos == 4 and .[0].videos == 1' 180 && echo "  ok   the wizard's photo folder is a library: 4 photos, 1 video (@eaDir skipped)" || { echo "  FAIL library: $(jq -c '.app.libraries' "$VAR/status.json")"; fail=1; }
  docker exec immich-server sh -c "touch '$PHOTOS/x' 2>/dev/null" && { echo "  FAIL the photo folder is writable"; fail=1; } || echo "  ok   …mounted read-only"
  # An upload from "a phone" lands in the photos folder of the shared folder.
  cp "$PHOTOS/holiday-01.jpg" "$E2E/upload.jpg"; python3 -c "from PIL import Image; Image.open('$E2E/upload.jpg').rotate(90).save('$E2E/upload.jpg')"
  [[ "$(curl -s -X POST "$url/api/assets" -H "Authorization: Bearer $tok" -F "assetData=@$E2E/upload.jpg" -F 'fileCreatedAt=2026-05-01T10:00:00.000Z' -F 'fileModifiedAt=2026-05-01T10:00:00.000Z' | jq -r '.status // empty')" == created ]] && echo "  ok   a phone-style upload was taken" || { echo "  FAIL upload"; fail=1; }
  wait_for '.app.stats.photos == 5' 60 && echo "  ok   5 photos in Immich" || { echo "  FAIL stats: $(jq -c .app.stats "$VAR/status.json")"; fail=1; }
  n=$(docker run --rm -v "$APP:/s:ro" --entrypoint sh immich-setup:local -c 'find /s/photos/upload -type f -iname "*.jpg" | wc -l'); [[ "$n" -ge 1 ]] && echo "  ok   …its original is in the shared folder: photos/upload ($n file)" || { echo "  FAIL upload not in the share"; fail=1; }
  # New photos in the folder: a scan finds them.
  make_photos "$PHOTOS" 6 holiday; id=$(jq -r '.app.libraries[0].id' "$VAR/status.json")
  request "ACTION='libscan'" "LIB_ID='$id'" || fail=1
  wait_for '.app.libraries[0].photos == 6' 120 && echo "  ok   two new photos found by Scan now" || { echo "  FAIL rescan: $(jq -c '.app.libraries[0]' "$VAR/status.json")"; fail=1; }
  request "ACTION='libscan'" || fail=1
  # Users: someone new, who must choose their own password.
  request "ACTION='useradd'" "USER_EMAIL='bob@example.com'" "USER_NAME_B64='$(b64u 'Bob Ó Briain')'" "ROLE='user'" || fail=1
  pw2=$(secret); [[ -n "$(token bob@example.com "$pw2")" ]] && echo "  ok   bob signs in with the password shown once" || { echo "  FAIL bob"; fail=1; }
  wait_for '.app.users | map(select(.email == "bob@example.com" and .name == "Bob Ó Briain" and .change == true and .admin == false)) | length == 1' 30 && echo "  ok   Bob Ó Briain is a user who chooses his own password at the first sign-in" || { echo "  FAIL users: $(jq -c .app.users "$VAR/status.json")"; fail=1; }
  request "ACTION='useradd'" "USER_EMAIL='bob@example.com'" "USER_NAME_B64='$(b64u Bob)'" "ROLE='user'" >/dev/null && { echo "  FAIL a second bob"; fail=1; } || echo "  ok   the same email twice is refused: $(jq -r .last.message "$VAR/status.json" | cut -c1-70)"
  # A second photo folder, in Bob's timeline; refused: missing, nested, the same again.
  bob=$(jq -r '.app.users[] | select(.email == "bob@example.com") | .id' "$VAR/status.json")
  make_photos "$E2E/photos2" 2 garden
  request "ACTION='libadd'" "LIB_DIR_B64='$(b64u "$E2E/photos2")'" "LIB_OWNER='$bob'" || fail=1
  wait_for '.app.libraries | map(select(.owner == "Bob Ó Briain" and .photos == 2)) | length == 1' 120 && echo "  ok   a second folder, in Bob's timeline: 2 photos" || { echo "  FAIL libadd: $(jq -c .app.libraries "$VAR/status.json")"; fail=1; }
  request "ACTION='libadd'" "LIB_DIR_B64='$(b64u /volume9/nope)'" >/dev/null && { echo "  FAIL accepted a missing folder"; fail=1; } || echo "  ok   a folder that isn't there is refused"
  [[ ! -e /volume9/nope ]] && echo "  ok   …and isn't created by asking" || { echo "  FAIL /volume9/nope was created"; fail=1; }
  mkdir -p "$PHOTOS/sub"
  request "ACTION='libadd'" "LIB_DIR_B64='$(b64u "$PHOTOS/sub")'" >/dev/null && { echo "  FAIL accepted a nested folder"; fail=1; } || echo "  ok   a folder inside one already read is refused"
  request "ACTION='libadd'" "LIB_DIR_B64='$(b64u "$E2E/photos2/")'" >/dev/null && { echo "  FAIL accepted the same folder twice"; fail=1; } || echo "  ok   the same folder twice is refused"
  lib2=$(jq -r '.app.libraries[] | select(.owner == "Bob Ó Briain") | .id' "$VAR/status.json")
  request "ACTION='libdel'" "LIB_ID='$lib2'" || fail=1
  wait_for '.app.libraries | length == 1' 30 && ! docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' immich-server | grep -q photos2 && [[ -f "$E2E/photos2/garden-01.jpg" ]] \
    && echo "  ok   removed: one library left, the folder unmounted and its files untouched" || { echo "  FAIL libdel"; fail=1; }
  # Machine learning: off here, and everything follows the switch.
  [[ "$(docker exec immich-server printenv IMMICH_MACHINE_LEARNING_ENABLED)" == false && -z "$(docker ps -aq --filter name=^immich-machine-learning$)" ]] \
    && jq -e '.app.ml.on == false and .app.ml.smart_search == false and .app.ml.faces == false' "$VAR/status.json" >/dev/null \
    && echo "  ok   machine learning off: no container, Immich's smart search and faces off" || { echo "  FAIL ml off: $(jq -c .app.ml "$VAR/status.json")"; fail=1; }
  if [[ "${E2E_ML:-0}" == 1 ]]; then
    request "ACTION='ml'" "ON='1'" || fail=1
    wait_for '.app.ml.on and .app.ml.state == "running" and .app.ml.smart_search and .app.ml.faces' 60 && echo "  ok   machine learning on: container running ($(jq -r '.app.memory.containers["machine-learning"]' "$VAR/status.json") MB), smart search and faces on" || { echo "  FAIL ml on: $(jq -c .app.ml "$VAR/status.json")"; fail=1; }
    for n in $(seq 1 90); do sleep 2; docker logs immich-machine-learning 2>&1 | grep -qiE 'loading (visual|textual|detection|recognition) model|Loaded' && break; done
    echo "  (machine learning after a minute's work: $(docker stats --no-stream --format '{{.MemUsage}}' immich-machine-learning))"
    request "ACTION='ml'" "ON='0'" || fail=1
    echo "  (last message: $(jq -r .last.message "$VAR/status.json"))"
    wait_for '.app.ml.on == false and .app.ml.smart_search == false' 60 && [[ -z "$(docker ps -aq --filter name=^immich-machine-learning$)" ]] && echo "  ok   machine learning off again: container gone" || { echo "  FAIL ml off again"; fail=1; }
  else echo "  (E2E_ML=1 also switches it on and off for real)"
  fi
  # The administrator's password, reset with immich-admin.
  request "ACTION='adminpw'" || fail=1
  pw2=$(secret)
  [[ -n "$(token ada@example.com "$pw2")" && -z "$(token ada@example.com "$pw")" ]] && echo "  ok   immich-admin reset ada's password: the new one works, the old one doesn't" || { echo "  FAIL adminpw"; fail=1; }
  wait_for '.app.api_ok == true and (.app.users | length) == 2' 30 && echo "  ok   the package's API key still works" || { echo "  FAIL api after reset"; fail=1; }
  # A database backup, then a change, then the restore takes it back.
  wait_for '.app.stats.photos == 7 and .app.stats.videos == 1' 60 || echo "  (photos before the backup: $(jq -c .app.stats "$VAR/status.json"))"
  request "ACTION='backup'" || fail=1; name=$(jq -r '.backups[0].name' "$VAR/status.json")
  grep -qE '/immich-db\.sql\.gz$' < <(tar -tf "$APP/backups/$name") && grep -q 'PostgreSQL database dump complete' < <(tar -xOf "$APP/backups/$name" --wildcards '*/immich-db.sql.gz' | gzip -dc | tail -n 5) \
    && echo "  ok   $name holds a complete pg_dump of the database" || { echo "  FAIL backup contents"; fail=1; }
  request "ACTION='useradd'" "USER_EMAIL='carol@example.com'" "USER_NAME_B64='$(b64u Carol)'" "ROLE='admin'" || fail=1; secret >/dev/null
  wait_for '.app.users | length == 3' 30 || true
  request "ACTION='restore'" "BACKUP='$name'" || fail=1
  wait_for '(.app.users | map(.email) | sort) == ["ada@example.com", "bob@example.com"] and (.app.libraries | length) == 1 and .app.stats.photos == 7' 60 \
    && echo "  ok   restored: carol is gone; ada, bob, the library and all 7 photos are back" || { echo "  FAIL restore: $(jq -c '{u: [.app.users[]?.email], l: (.app.libraries | length), s: .app.stats}' "$VAR/status.json")"; fail=1; }
  [[ -n "$(token ada@example.com "$pw2")" ]] && echo "  ok   ada signs in after the restore" || { echo "  FAIL sign-in after restore"; fail=1; }
  # The update path: a package that pins a different Immich backs up the database before moving.
  docker run --rm -v "$APP:/s" --entrypoint sh immich-setup:local -c "sed -i 's/^IMMICH_VERSION=.*/IMMICH_VERSION=v3.3.0/' /s/.env"
  down >/dev/null; up >/dev/null || { echo "  FAIL the setup container didn't come back"; fail=1; }
  [[ "$(envv IMMICH_VERSION)" == v3.3.1 ]] && grep -q 'moves Immich from v3.3.0 to v3.3.1' "$VAR/package.log" && ls "$APP"/backups/immich-*-preupdate.tar >/dev/null 2>&1 \
    && echo "  ok   moving from v3.3.0 to v3.3.1: $(basename "$(ls "$APP"/backups/immich-*-preupdate.tar | head -n 1)") was made first" || { echo "  FAIL pin move: $(envv IMMICH_VERSION)"; fail=1; }
  wait_for '.app.moved_from == "v3.3.0"' 30 && echo "  ok   the window says where it moved from" || { echo "  FAIL moved_from"; fail=1; }
  echo "  (memory now: $(jq -c .app.memory.containers "$VAR/status.json"); $(free -m | awk '/^Mem:/ {print $7}') MB available on this box)"
  (( fail )) && { echo "  immich: something FAILED"; return 1; }; echo "  immich: all passed"
}
