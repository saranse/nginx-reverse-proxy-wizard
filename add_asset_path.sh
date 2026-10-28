#!/usr/bin/env bash
# Add one explicit asset/API path route to an existing wizard-managed Nginx config.
set -Eeuo pipefail

CONF_FILE=/etc/nginx/conf.d/reverse_proxy.conf
BACKUP_DIR=/etc/nginx/backup
BEGIN_MARKER='# BEGIN OPTIONAL ASSET PATH ROUTES (managed by add_asset_path.sh)'
END_MARKER='# END OPTIONAL ASSET PATH ROUTES'

die() { printf 'ผิดพลาด: %s\n' "$*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'กรุณารันด้วย sudo: sudo ./add_asset_path.sh'
command -v nginx >/dev/null 2>&1 || die 'ไม่พบคำสั่ง nginx'
command -v systemctl >/dev/null 2>&1 || die 'ไม่พบ systemctl'
[[ -f $CONF_FILE ]] || die "ไม่พบไฟล์ $CONF_FILE"
begin_count=$(grep -Fxc "    $BEGIN_MARKER" "$CONF_FILE" || true)
end_count=$(grep -Fxc "    $END_MARKER" "$CONF_FILE" || true)
if [[ $begin_count != 0 || $end_count != 0 ]]; then
  [[ $begin_count == 1 && $end_count == 1 ]] || die 'marker ในคอนฟิกไม่ครบหรือซ้ำ; ตรวจไฟล์ก่อนเพิ่ม path'
fi

read -r -p 'Path ที่ browser เรียก (เช่น /assets/ หรือ /logo.webp): ' public_path
public_path=${public_path#/}
is_exact=false
[[ $public_path == */ ]] || is_exact=true
public_path=${public_path%/}
[[ $public_path =~ ^[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*$ ]] || die 'Path ไม่ถูกต้อง; ห้ามใส่ query string และใช้ได้เฉพาะตัวอักษร/ตัวเลข . _ ~ - และ /'
[[ ! /$public_path/ =~ /\.\./|/\./ ]] || die 'Path ห้ามมี segment . หรือ ..'

if [[ $is_exact == true ]]; then
  location_line="    location = /$public_path {"
else
  location_line="    location ^~ /$public_path/ {"
fi
if grep -Fqx "$location_line" "$CONF_FILE"; then die "มี location นี้อยู่แล้ว: /$public_path"; fi

read -r -p 'Upstream URL ของเว็บปลายทาง (เช่น http://127.0.0.1:3000/app/): ' upstream_url
[[ $upstream_url != *\?* && $upstream_url != *\#* ]] || die 'Upstream ห้ามมี query string หรือ fragment'
[[ $upstream_url =~ ^(https?)://(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+)(:[0-9]{1,5})?(/[^[:space:]]*)?$ ]] || die 'รูปแบบ upstream ไม่ถูกต้อง; ใช้ http(s)://host[:port][/base/path/]'
scheme=${BASH_REMATCH[1]}
authority=${BASH_REMATCH[2]}${BASH_REMATCH[3]}
base_path=${BASH_REMATCH[4]:-/}
[[ $base_path == /* ]] || base_path="/$base_path"
[[ $base_path == */ ]] || base_path="$base_path/"
rewrite_base=${base_path%/}
origin="$scheme://$authority"

tmp_block=$(mktemp)
tmp_base=$(mktemp)
tmp_conf=$(mktemp "${CONF_FILE}.XXXXXX")
backup_file=''
cleanup() { rm -f "${tmp_block:-}" "${tmp_base:-}" "${tmp_conf:-}"; }
trap cleanup EXIT

{
  if [[ $is_exact == true ]]; then printf '    location = /%s {\n' "$public_path"; else printf '    location ^~ /%s/ {\n' "$public_path"; fi
  if [[ -n $rewrite_base ]]; then printf '        rewrite ^ %s$uri break;\n' "$rewrite_base"; fi
  cat <<BLOCK
        proxy_pass $origin;
        proxy_http_version 1.1;
        proxy_set_header Host \$proxy_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_ssl_server_name on;
        proxy_ssl_name \$proxy_host;
        proxy_redirect off;
    }
BLOCK
} > "$tmp_block"

mkdir -p "$BACKUP_DIR"
backup_file="$BACKUP_DIR/reverse_proxy.conf.$(date +%Y%m%d-%H%M%S).bak"
cp -a "$CONF_FILE" "$backup_file"
source_conf=$CONF_FILE
if [[ $begin_count == 0 && $end_count == 0 ]]; then
  # Older Wizard configs have one generated server block but no custom-route markers.
  # Insert the managed area before that server block's closing brace.
  if ! awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
    /^[[:space:]]*server[[:space:]]*\{/ { servers++; in_server=1; depth=0 }
    {
      line=$0
      if (in_server) {
        scan=line
        sub(/#.*/, "", scan)
        opens=gsub(/\{/, "{", scan)
        closes=gsub(/\}/, "}", scan)
        depth += opens - closes
        if (depth == 0) {
          print "    " begin
          print "    " end
          in_server=0
          if (servers > 1) bad=1
        }
      }
      print line
    }
    END { if (servers != 1 || in_server || bad) exit 2 }
  ' "$CONF_FILE" > "$tmp_base"; then
    die 'ไม่สามารถระบุตำแหน่ง server block เดียวใน config เก่าได้; คอนฟิกเดิมยังอยู่'
  fi
  source_conf=$tmp_base
fi
awk -v end="$END_MARKER" -v snippet="$tmp_block" '
  $0 == "    " end {
    while ((getline line < snippet) > 0) print line
    close(snippet)
    found_end = 1
  }
  { print }
  END { if (!found_end) exit 2 }
' "$source_conf" > "$tmp_conf" || die 'แทรก path ไม่สำเร็จ; คอนฟิกเดิมยังอยู่'
chmod --reference="$CONF_FILE" "$tmp_conf"
mv -f "$tmp_conf" "$CONF_FILE"
tmp_conf=''

if ! nginx -t; then
  cp -a "$backup_file" "$CONF_FILE"
  die "nginx -t ไม่ผ่าน; คืนคอนฟิกเดิมแล้ว (สำรองไว้ที่ $backup_file)"
fi
if ! systemctl reload nginx; then
  cp -a "$backup_file" "$CONF_FILE"
  nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
  die "reload ไม่สำเร็จ; คืนคอนฟิกเดิมแล้ว (สำรองไว้ที่ $backup_file)"
fi

printf 'เพิ่ม path สำเร็จ: %s → %s\n' "$location_line" "$origin$base_path"
printf 'สำรองคอนฟิกเดิม: %s\n' "$backup_file"
printf 'ตำแหน่งคอนฟิก: %s\n' "$CONF_FILE"
