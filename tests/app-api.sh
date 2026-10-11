# Immich's CGI checks (sourced by chassis/tests/test-api.sh).
expect "libadd good" 202 "$(post "$me" libadd 'action=libadd&dir=%2Fvolume1%2FFamily%20Photos%2F&owner=0d1c8f3e-5a6b-4c7d-8e9f-a0b1c2d3e4f5')"
request_is "libadd: a folder with spaces travels base64url, the slash at the end dropped" "ACTION='libadd'
LIB_DIR_B64='L3ZvbHVtZTEvRmFtaWx5IFBob3Rvcw'
LIB_OWNER='0d1c8f3e-5a6b-4c7d-8e9f-a0b1c2d3e4f5'
BY='$me'"
expect "libadd no owner" 202 "$(post "$me" libadd 'action=libadd&dir=%2Fvolume1%2Fphoto')"; rm -f "$CHASSIS_VAR/request"
expect "libadd relative" 400 "$(post "$me" libadd 'action=libadd&dir=photo')"
expect "libadd dots" 400 "$(post "$me" libadd 'action=libadd&dir=%2Fvolume1%2F..%2Fetc')"
expect "libadd quote" 400 "$(post "$me" libadd 'action=libadd&dir=%2Fvolume1%2Fa%22b')"
expect "libadd comma" 400 "$(post "$me" libadd 'action=libadd&dir=%2Fvolume1%2Fa%2Cb')"
expect "libadd dollar" 400 "$(post "$me" libadd 'action=libadd&dir=%2Fvolume1%2F%24(id)')"
expect "libadd immich's own /data" 400 "$(post "$me" libadd 'action=libadd&dir=%2Fdata%2Fx')"
expect "libadd bad owner" 400 "$(post "$me" libadd "action=libadd&dir=%2Fvolume1%2Fphoto&owner=x'%3B")"
expect "libscan all" 202 "$(post "$me" libscan 'action=libscan')"; request_is "libscan all request" "ACTION='libscan'
BY='$me'"
expect "libscan one" 202 "$(post "$me" libscan 'action=libscan&id=0d1c8f3e-5a6b-4c7d-8e9f-a0b1c2d3e4f5')"; rm -f "$CHASSIS_VAR/request"
expect "libscan bad id" 400 "$(post "$me" libscan 'action=libscan&id=..%2F..')"
expect "libdel needs an id" 400 "$(post "$me" libdel 'action=libdel')"
expect "ml on" 202 "$(post "$me" ml 'action=ml&on=1')"; request_is "ml request" "ACTION='ml'
ON='1'
BY='$me'"
expect "ml bad" 400 "$(post "$me" ml 'action=ml&on=yes')"
expect "useradd good" 202 "$(post "$me" useradd 'action=useradd&email=alice%40example.com&name=Alice%20O%27Neill&role=user')"
request_is "useradd: the name travels base64url" "ACTION='useradd'
USER_EMAIL='alice@example.com'
USER_NAME_B64='QWxpY2UgTydOZWlsbA'
ROLE='user'
BY='$me'"
expect "useradd bad email" 400 "$(post "$me" useradd 'action=useradd&email=alice&name=Alice&role=user')"
expect "useradd no name" 400 "$(post "$me" useradd 'action=useradd&email=alice%40example.com&name=&role=user')"
expect "useradd bad role" 400 "$(post "$me" useradd 'action=useradd&email=alice%40example.com&name=Alice&role=root')"
expect "adminpw" 202 "$(post "$me" adminpw 'action=adminpw')"; rm -f "$CHASSIS_VAR/request"
expect "folders" 200 "$(get "$me" 'action=folders')"
get "$me" 'action=folders' | tail -n 1 | jq -e '.folders | type == "array"' >/dev/null && { (( pass++ )); echo "  ok   folders is a list"; } || { (( fail++ )); echo "  FAIL folders"; }
expect "viewer folders → 403" 403 "$(CHASSIS_ADMINS=no-such-group get "$me" 'action=folders')"
