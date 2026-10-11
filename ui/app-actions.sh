# Immich's actions, validated by the CGI before they become a request file.
# Free text (folder paths, people's names) travels base64url-encoded.
b64u() { printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
uuid_ok() { [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; }
app_cgi_get() {   # action query → replies, or returns for "unknown"
  case "$1" in
    folders)   # the shared folders on this Synology, to pick from (names only; nothing is read inside them)
      local list; list=$(for d in /volume[0-9]*/*/; do d=${d%/}; n=${d##*/}; [[ -d "$d" && "$n" != @* && "$n" != \#* && "$n" != .* && "$n" =~ ^[^[:cntrl:]\"\\]+$ ]] && printf '%s\n' "$d"; done 2>/dev/null | grep -vE '^/volume[0-9]+/(immich|docker|homes|web_packages|NetBackup)$' | head -n 200 | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null)
      reply "200 OK" application/json "{\"folders\":${list:-[]}}" ;;
  esac
}
app_cgi_post() {   # action body → sets $lines, or error
  local a=$1 body=$2 v dir id e name role
  case "$a" in
    libadd) dir=$(decode "$(param dir "$body")"); dir=${dir%/}; id=$(param owner "$body")
      [[ "$dir" == /* && "$dir" != *..* && ${#dir} -le 300 && "$dir" =~ ^[^[:cntrl:]\",\$\\]+$ && "$dir" != /data* ]] || error "400 Bad Request" "A folder on the NAS, like /volume1/photo."
      [[ -z "$id" ]] || uuid_ok "$id" || error "400 Bad Request" "Pick who owns these photos."
      lines="ACTION='libadd'
LIB_DIR_B64='$(b64u "$dir")'"
      [[ -n "$id" ]] && lines="$lines
LIB_OWNER='$id'" ;;
    libscan) id=$(param id "$body"); [[ -z "$id" ]] || uuid_ok "$id" || error "400 Bad Request" "Pick a library."
      lines="ACTION='libscan'"; [[ -n "$id" ]] && lines="$lines
LIB_ID='$id'" ;;
    libdel) id=$(param id "$body"); uuid_ok "$id" || error "400 Bad Request" "Pick a library."
      lines="ACTION='libdel'
LIB_ID='$id'" ;;
    ml) v=$(param on "$body"); [[ "$v" =~ ^[01]$ ]] || error "400 Bad Request" "On or off."
      lines="ACTION='ml'
ON='$v'" ;;
    useradd) e=$(decode "$(param email "$body")"); name=$(decode "$(param name "$body")"); role=$(param role "$body")
      [[ "$e" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ && ${#e} -le 120 ]] || error "400 Bad Request" "An email address, like alice@example.com — it's how they sign in."
      [[ -n "$name" && ${#name} -le 60 && "$name" =~ ^[^[:cntrl:]]+$ ]] || error "400 Bad Request" "Their name, up to 60 characters."
      [[ "$role" =~ ^(user|admin)$ ]] || error "400 Bad Request" "User or administrator."
      lines="ACTION='useradd'
USER_EMAIL='$e'
USER_NAME_B64='$(b64u "$name")'
ROLE='$role'" ;;
    adminpw) lines="ACTION='adminpw'" ;;
  esac
}
