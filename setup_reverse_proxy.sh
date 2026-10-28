#!/usr/bin/env bash
# Nginx reverse proxy installer and setup wizard (Ubuntu/Debian/RHEL family)
# Example domains and backend addresses are reserved/sample values.
set -Eeuo pipefail

CONF_FILE=/etc/nginx/conf.d/reverse_proxy.conf
BACKUP_DIR=/etc/nginx/backup

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { printf "${CYAN}%s${NC}\n" "$*"; }
warn() { printf "${YELLOW}%s${NC}\n" "$*" >&2; }
die() { printf "${RED}%s${NC}\n" "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'กรุณารันด้วย sudo: sudo ./setup_reverse_proxy.sh'
command -v systemctl >/dev/null 2>&1 || die 'ไม่พบ systemctl สคริปต์นี้ต้องใช้กับ Linux ที่ใช้ systemd'

# Show the currently active Nginx routing before the wizard changes anything.
show_existing_nginx_config() {
  printf '\nคอนฟิก Nginx ปัจจุบัน:\n'
  if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
    nginx -T 2>/dev/null | awk '
      /^# configuration file / {
        source = $0
        active = (source ~ /^# configuration file \/etc\/nginx\//)
        if (active) { print "\n" source }
        next
      }
      active && /^[[:space:]]*upstream[[:space:]]+[[:alnum:]_-]+[[:space:]]*\{/ {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        print "  " line
        in_upstream = 1
        next
      }
      in_upstream && /^[[:space:]]*server[[:space:]]/ {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        print "    " line
        next
      }
      in_upstream && /^[[:space:]]*}/ { in_upstream = 0; next }
      active && /^[[:space:]]*(listen|server_name|location|proxy_pass|root|ssl_certificate|ssl_certificate_key|upstream)[[:space:]={]/ {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        sub(/\?.*/, "?[query redacted]", line)
        print "  " line
      }
      END { if (!active) print "ไม่พบ active config ใต้ /etc/nginx/" }
    '
  elif [[ -f $CONF_FILE ]]; then
    warn 'คอนฟิกปัจจุบันมี syntax error หรืออ่านผ่าน nginx -T ไม่ได้; แสดงเฉพาะ routing directives ในไฟล์ที่ wizard จัดการ'
    awk '/^[[:space:]]*(listen|server_name|location|proxy_pass|root|ssl_certificate|ssl_certificate_key)[[:space:]={]/ { line=$0; sub(/^[[:space:]]+/, "", line); sub(/\?.*/, "?[query redacted]", line); print "  " line }' "$CONF_FILE"
  else
    printf 'ยังไม่พบ Nginx config ที่ใช้งานได้\n'
  fi
  if [[ -f $CONF_FILE ]]; then printf '\nไฟล์ที่ wizard จะจัดการ: %s\n' "$CONF_FILE"; fi
}
show_existing_nginx_config

# Install Nginx and the port-inspection utility if they are missing.
if [[ -r /etc/os-release ]]; then . /etc/os-release; else die 'ไม่พบ /etc/os-release จึงระบุ Linux distribution ไม่ได้'; fi
if command -v nginx >/dev/null 2>&1 || [[ -d /etc/nginx ]]; then
  printf '\nพบ Nginx เดิม ต้องการสำรองแล้วถอนโปรแกรมและล้าง /etc/nginx ก่อนติดตั้งใหม่หรือไม่? [y/N]: '
  read -r PURGE_CHOICE || true
  if [[ ${PURGE_CHOICE,,} == y || ${PURGE_CHOICE,,} == yes ]]; then
    printf 'พิมพ์ PURGE NGINX เพื่อยืนยันการล้างคอนฟิก: '
    read -r PURGE_CONFIRM || true
    [[ $PURGE_CONFIRM == 'PURGE NGINX' ]] || die 'ยกเลิกการล้าง Nginx'
    PURGE_BACKUP_DIR=/root/nginx-backups
    mkdir -p "$PURGE_BACKUP_DIR"
    PURGE_BACKUP_PATH="$PURGE_BACKUP_DIR/nginx.$(date +%Y%m%d-%H%M%S)"
    if [[ -d /etc/nginx ]]; then cp -a /etc/nginx "$PURGE_BACKUP_PATH"; info "สำรองคอนฟิกเดิมไว้ที่ $PURGE_BACKUP_PATH"; fi
    systemctl stop nginx 2>/dev/null || true
    systemctl disable nginx 2>/dev/null || true
    case ${ID:-unknown} in
      ubuntu|debian|linuxmint|pop)
        mapfile -t NGINX_PACKAGES < <(dpkg-query -W -f='${binary:Package}\n' 'nginx*' 2>/dev/null || true)
        if ((${#NGINX_PACKAGES[@]})); then apt-get purge -y "${NGINX_PACKAGES[@]}"; fi
        ;;
      almalinux|rocky|rhel|centos|fedora|ol)
        if command -v rpm >/dev/null 2>&1; then mapfile -t NGINX_PACKAGES < <(rpm -qa 'nginx*' 2>/dev/null || true); else NGINX_PACKAGES=(); fi
        if ((${#NGINX_PACKAGES[@]})); then
          if command -v dnf >/dev/null 2>&1; then dnf remove -y "${NGINX_PACKAGES[@]}"; else yum remove -y "${NGINX_PACKAGES[@]}"; fi
        fi
        ;;
    esac
    rm -rf /etc/nginx
    info 'ล้างแพ็กเกจและคอนฟิก Nginx เดิมแล้ว; ไม่ลบเว็บคอนเทนต์หรือ Cloudflare Tunnel'
  else
    info 'เก็บ Nginx เดิมไว้ และจะปรับเฉพาะ reverse_proxy.conf ตามขั้นตอนปกติ'
  fi
fi
if ! command -v nginx >/dev/null 2>&1; then
  info "กำลังติดตั้ง Nginx บน ${PRETTY_NAME:-$ID}"
  case ${ID:-unknown} in
    ubuntu|debian|linuxmint|pop)
      command -v apt-get >/dev/null 2>&1 || die 'ไม่พบ apt-get'
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y nginx iproute2
      ;;
    almalinux|rocky|rhel|centos|fedora|ol)
      if command -v dnf >/dev/null 2>&1; then
        dnf install -y nginx iproute
      elif command -v yum >/dev/null 2>&1; then
        if ! yum install -y nginx iproute; then
          if [[ ${ID:-} == centos && ${VERSION_ID:-} == 7* ]]; then
            yum install -y epel-release
            yum install -y nginx iproute
          else
            die 'ติดตั้ง Nginx จาก repository ที่เปิดใช้อยู่ไม่สำเร็จ; ตรวจ repository ของ distribution แล้วลองใหม่'
          fi
        fi
      else
        die 'ไม่พบ dnf/yum; ติดตั้ง Nginx และ iproute ด้วยตนเองแล้วเรียกสคริปต์อีกครั้ง'
      fi
      ;;
    *) die "ยังไม่รองรับการติดตั้งอัตโนมัติบน ${ID:-unknown}; ติดตั้ง Nginx และ systemd ก่อนเรียกสคริปต์" ;;
  esac
fi
command -v nginx >/dev/null 2>&1 || die 'ติดตั้งแล้วแต่ยังไม่พบคำสั่ง nginx'
if ! command -v ss >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get install -y iproute2
  elif command -v dnf >/dev/null 2>&1; then dnf install -y iproute
  elif command -v yum >/dev/null 2>&1; then yum install -y iproute
  fi
fi

read_value() { local prompt=$1 default=${2-} value; read -r -p "$prompt" value || true; REPLY=${value:-$default}; }
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_host() { [[ $1 =~ ^([A-Za-z0-9.-]+|\[[0-9A-Fa-f:.]+\])$ ]]; }
parse_upstream() {
  local value=$1 parsed_port upstream_scheme
  # These are upstream base URLs. Query strings/fragments would be fixed for every
  # request and interfere with Nginx URI-prefix replacement, so reject them here.
  [[ $value != *\?* && $value != *\#* ]] || return 1
  [[ $value =~ ^https?://(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+)(:[0-9]{1,5})?(/[^[:space:]]*)?$ ]] || return 1
  UPSTREAM_HOST=${BASH_REMATCH[1]}
  parsed_port=${BASH_REMATCH[2]#:}
  UPSTREAM_BASE_PATH=${BASH_REMATCH[3]:-/}
  upstream_scheme=${value%%://*}
  if [[ -n $parsed_port ]]; then UPSTREAM_PORT=$parsed_port
  elif [[ $upstream_scheme == https ]]; then UPSTREAM_PORT=443
  else UPSTREAM_PORT=80
  fi
  [[ $UPSTREAM_BASE_PATH == /* ]] || UPSTREAM_BASE_PATH="/$UPSTREAM_BASE_PATH"
  [[ $UPSTREAM_BASE_PATH == */ ]] || UPSTREAM_BASE_PATH="$UPSTREAM_BASE_PATH/"
  if [[ -n $parsed_port ]]; then
    valid_port "$parsed_port" || return 1
  fi
}

find_certificate_pair() {
  local cert key candidate
  local -a candidates=(
    "/etc/letsencrypt/live/$DOMAIN/fullchain.pem|/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    "/etc/letsencrypt/live/$DOMAIN/cert.pem|/etc/letsencrypt/live/$DOMAIN/privkey.pem"
    "/etc/nginx/ssl/$DOMAIN.crt|/etc/nginx/ssl/$DOMAIN.key"
    "/etc/nginx/ssl/$DOMAIN/fullchain.pem|/etc/nginx/ssl/$DOMAIN/privkey.pem"
    "/etc/ssl/certs/$DOMAIN.pem|/etc/ssl/private/$DOMAIN.key"
    "/etc/ssl/certs/$DOMAIN.crt|/etc/ssl/private/$DOMAIN.key"
  )
  for candidate in "${candidates[@]}"; do
    cert=${candidate%%|*}; key=${candidate#*|}
    if [[ -r $cert && -r $key ]] && openssl x509 -in "$cert" -noout >/dev/null 2>&1 && openssl pkey -in "$key" -noout >/dev/null 2>&1; then
      if [[ $DOMAIN =~ ^[0-9.]+$ ]]; then
        openssl x509 -in "$cert" -noout -checkip "$DOMAIN" >/dev/null 2>&1 || continue
      else
        openssl x509 -in "$cert" -noout -checkhost "$DOMAIN" >/dev/null 2>&1 || continue
      fi
      CERT_FILE=$cert; KEY_FILE=$key
      return 0
    fi
  done
  return 1
}

# Allow Nginx to proxy to upstreams under SELinux. Add custom listen ports when semanage exists.
SELINUX_STATE=Disabled
if command -v getenforce >/dev/null 2>&1; then SELINUX_STATE=$(getenforce); fi
if [[ $SELINUX_STATE == Enforcing || $SELINUX_STATE == Permissive ]]; then
  if ! command -v setsebool >/dev/null 2>&1; then
    case ${ID:-unknown} in
      ubuntu|debian|linuxmint|pop) DEBIAN_FRONTEND=noninteractive apt-get install -y policycoreutils || true ;;
      *)
        if command -v dnf >/dev/null 2>&1; then dnf install -y policycoreutils policycoreutils-python-utils || true
        elif command -v yum >/dev/null 2>&1; then yum install -y policycoreutils policycoreutils-python || true
        fi
        ;;
    esac
  fi
  if ! command -v semanage >/dev/null 2>&1 && [[ $ID == almalinux || $ID == rocky || $ID == rhel || $ID == centos || $ID == fedora || $ID == ol ]]; then
    if command -v dnf >/dev/null 2>&1; then dnf install -y policycoreutils-python-utils || true
    elif command -v yum >/dev/null 2>&1; then yum install -y policycoreutils-python || true
    fi
  fi
  if command -v setsebool >/dev/null 2>&1; then
    setsebool -P httpd_can_network_connect 1 || warn 'ตั้ง SELinux boolean ไม่สำเร็จ; ตรวจ httpd_can_network_connect ด้วยตนเอง'
  else
    warn 'พบ SELinux แต่ไม่มี setsebool; อาจต้องติดตั้ง policycoreutils และอนุญาตการเชื่อมต่อ upstream ด้วยตนเอง'
  fi
fi

printf "${CYAN}============================================================${NC}\n"
printf "${GREEN}${BOLD} Nginx Reverse Proxy Setup Wizard${NC}\n"
printf "ตัวอย่างโดเมนใช้ example.com และ IP ใช้ช่วงตัวอย่างเท่านั้น\n"
printf "${CYAN}============================================================${NC}\n\n"

read_value 'โดเมนที่ผู้ใช้จะเปิด (เช่น app.example.com): ' 'app.example.com'
DOMAIN=$REPLY
[[ $DOMAIN =~ ^[A-Za-z0-9*._-]+$ ]] || die 'รูปแบบโดเมนไม่ถูกต้อง'

printf '\nเลือกวิธีรับเว็บ:\n'
printf '  [1] Cloudflare/Tunnel → Nginx HTTP 80 (แนะนำ, ไม่ใช้ certificate ที่เครื่องนี้)\n'
printf '  [2] HTTP ปกติ → Nginx 80\n'
printf '  [3] HTTPS ที่ Nginx 443 (ค้นหา certificate ให้อัตโนมัติ)\n'
printf '  [4] HTTP พอร์ตอื่น เช่น 8080\n'
read_value 'เลือก [1/2/3/4] (ค่าเริ่มต้น 1): ' '1'
case $REPLY in
  1) LISTEN_PORT=80; LISTEN_SCHEME=http; PUBLIC_SCHEME=https; FORWARDED_PROTO_VALUE=https; TLS_MODE=off ;;
  2) LISTEN_PORT=80; LISTEN_SCHEME=http; PUBLIC_SCHEME=http; FORWARDED_PROTO_VALUE='$scheme'; TLS_MODE=off ;;
  3) LISTEN_PORT=443; LISTEN_SCHEME=https; PUBLIC_SCHEME=https; FORWARDED_PROTO_VALUE='$scheme'; TLS_MODE=on ;;
  4) read_value 'ระบุพอร์ต Nginx (ห้ามใช้พอร์ตแอป เช่น 3000 หากแอปใช้พอร์ตนั้น): ' ''; LISTEN_PORT=$REPLY; LISTEN_SCHEME=http; PUBLIC_SCHEME=https; FORWARDED_PROTO_VALUE=https; TLS_MODE=off ;;
  *) die 'ตัวเลือกการเชื่อมต่อไม่ถูกต้อง' ;;
esac
valid_port "$LISTEN_PORT" || die 'พอร์ตต้องเป็นเลข 1 ถึง 65535'
if [[ $LISTEN_PORT != 80 && $LISTEN_PORT != 443 ]] && [[ $SELINUX_STATE == Enforcing || $SELINUX_STATE == Permissive ]]; then
  if command -v semanage >/dev/null 2>&1; then
    semanage port -a -t http_port_t -p tcp "$LISTEN_PORT" 2>/dev/null || semanage port -m -t http_port_t -p tcp "$LISTEN_PORT" || warn "เพิ่มพอร์ต $LISTEN_PORT ใน SELinux ไม่สำเร็จ"
  else
    warn "SELinux เปิดอยู่และพอร์ต $LISTEN_PORT เป็นพอร์ตกำหนดเอง; หาก Nginx bind ไม่ผ่าน ให้ติดตั้ง semanage แล้วเพิ่มพอร์ตนี้ใน http_port_t"
  fi
fi

# Fail before touching configuration if another program owns the port. Existing Nginx
# listeners are expected: this script adds/replaces a virtual host on the same service.
if command -v ss >/dev/null 2>&1; then
  LISTEN_INFO=$(ss -H -ltnp "sport = :$LISTEN_PORT" 2>/dev/null || true)
  if [[ -n $LISTEN_INFO ]]; then
    if printf '%s\n' "$LISTEN_INFO" | grep -qE 'users:\(\("nginx"' && ! printf '%s\n' "$LISTEN_INFO" | grep -vE 'users:\(\("nginx"' >/dev/null; then
      info "พอร์ต $LISTEN_PORT ถูกใช้อยู่โดย Nginx เดิม; จะเพิ่ม/เปลี่ยน virtual host ใน Nginx service เดิม"
    else
      warn "พอร์ต $LISTEN_PORT มี process กำลัง listen อยู่:"
      printf '%s\n' "$LISTEN_INFO"
      die 'เลือกพอร์ต Nginx ใหม่ หรือหยุด service อื่นที่ใช้พอร์ตนี้ก่อน'
    fi
  fi
fi

if [[ $TLS_MODE == on ]]; then
  if command -v openssl >/dev/null 2>&1 && find_certificate_pair; then
    info "พบ certificate ของ $DOMAIN แล้ว: $CERT_FILE"
  else
    warn "ค้นหา certificate ของ $DOMAIN ในตำแหน่งมาตรฐานไม่พบ หรือ certificate ไม่ครอบคลุมชื่อนี้"
    printf 'ระบุพาธ certificate และ private key เอง หรือเลือก HTTPS ผ่าน Cloudflare/Tunnel แทน\n'
    read_value 'พาธ certificate: ' ''
    CERT_FILE=$REPLY
    read_value 'พาธ private key: ' ''
    KEY_FILE=$REPLY
  fi
  [[ -r $CERT_FILE && -r $KEY_FILE ]] || die 'อ่าน certificate หรือ private key ไม่ได้'
fi

printf '\nเว็บหลักที่ /:\n'
printf 'ใส่ URL ของแอปหลังบ้าน (IP/พอร์ตของแอป) ห้ามใส่ IP/พอร์ตของ Nginx เครื่องนี้\n'
printf 'ตัวอย่าง: http://127.0.0.1:3000/app/ หรือ https://portal.example.com/\n'
read_value 'URL เว็บหลัก (ไม่ใส่ query string): ' 'http://127.0.0.1:3000/'
MAIN_URL=$REPLY
parse_upstream "$MAIN_URL" || die 'URL เว็บหลักไม่ถูกต้อง; ใช้ http(s)://host[:port][/base/path/] โดยไม่ใส่ query string หรือ fragment'
MAIN_UPSTREAM_HOST=$UPSTREAM_HOST
MAIN_UPSTREAM_PORT=$UPSTREAM_PORT
MAIN_BASE_PATH=$UPSTREAM_BASE_PATH
if [[ ${MAIN_UPSTREAM_HOST,,} == ${DOMAIN,,} && $MAIN_UPSTREAM_PORT == "$LISTEN_PORT" ]]; then
  die "Upstream ชี้กลับมาที่ Nginx เครื่องนี้ ($DOMAIN:$LISTEN_PORT) กรุณาใส่ IP/พอร์ตของแอปหลังบ้าน เช่น http://127.0.0.1:3000/ หรือ http://10.0.0.20:3000/"
fi

if [[ $MAIN_UPSTREAM_HOST =~ ^[0-9.]+$ || $MAIN_UPSTREAM_HOST == \[*\] ]]; then MAIN_HOST_HEADER='$host'; else MAIN_HOST_HEADER='$proxy_host'; fi
read_value 'ต้องการตั้ง Host header เองหรือไม่? [y/N]: ' 'N'
if [[ ${REPLY,,} == y || ${REPLY,,} == yes ]]; then
  printf '  [1] ส่งโดเมนหน้าบ้าน  [2] ส่งชื่อ upstream  [3] ระบุเอง\n'
  read_value 'เลือก [1/2/3] (ค่าเริ่มต้น 1): ' '1'
  case $REPLY in
    1) MAIN_HOST_HEADER='$host' ;;
    2) MAIN_HOST_HEADER='$proxy_host' ;;
    3) read_value 'Host header (เช่น app.example.com): ' '' ; valid_host "$REPLY" || die 'Host header ไม่ถูกต้อง'; MAIN_HOST_HEADER=$REPLY ;;
    *) die 'ตัวเลือก Host header ไม่ถูกต้อง' ;;
  esac
fi

read_value 'จำนวนเว็บใต้ subpath (เช่น 2; สูงสุด 20): ' '0'
APP_COUNT=$REPLY
[[ $APP_COUNT =~ ^[0-9]{1,2}$ ]] && (( APP_COUNT <= 20 )) || die 'จำนวนเว็บต้องเป็น 0 ถึง 20'

APP_PATHS=(); APP_URLS=(); APP_HOSTS=(); APP_BASE_PATHS=()
APP_ASSET_ORIGINS=()
for ((i=1; i<=APP_COUNT; i++)); do
  printf '\nเว็บลูก #%d\n' "$i"
  read_value '  Path (เช่น report): ' ''
  path=${REPLY#/}; path=${path%/}
  [[ $path =~ ^[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*$ ]] || die 'Path ใช้ได้เฉพาะตัวอักษร/ตัวเลข . _ ~ - และ /'
  for existing in "${APP_PATHS[@]-}"; do [[ $existing != "$path" ]] || die "Path ซ้ำ: /$path/"; done
  read_value '  Upstream base URL (เช่น https://reports.example.net/ หรือ http://192.0.2.20:8080/remote/; ไม่ใส่ ?query): ' ''
  url=$REPLY
  parse_upstream "$url" || die 'Upstream base URL ไม่ถูกต้อง; ใช้ http(s)://host[:port][/base/path/] โดยไม่ใส่ query string หรือ fragment'
  host=$UPSTREAM_HOST
  base_path=$UPSTREAM_BASE_PATH
  # Match Apache ProxyPreserveHost Off: send the upstream's host to the child app.
  # X-Forwarded-Host still carries the public hostname for apps that need it.
  header='$proxy_host'
  APP_PATHS+=("$path"); APP_URLS+=("$url"); APP_HOSTS+=("$header"); APP_BASE_PATHS+=("$base_path")
  scheme=${url%%://*}; authority=${url#*://}; authority=${authority%%/*}
  APP_ASSET_ORIGINS+=("${scheme}://${authority}")
done

printf '\nAsset routing:\n'
printf 'สคริปต์จะสร้าง native-path alias จาก upstream base path และส่ง root-relative requests ตาม Referer ไปยัง upstream ของหน้าที่เรียก\n'
read_value 'เปิด auto-routing สำหรับ root-relative requests (CSS/JS/API ฯลฯ)? [Y/n]: ' 'Y'
ASSET_MODE=${REPLY,,}
AUTO_ASSET_ROUTING=true
if [[ $ASSET_MODE == n || $ASSET_MODE == no ]]; then AUTO_ASSET_ROUTING=false; fi

# Optional explicit path overrides for resources that need a deterministic route.
# Paths may be exact files (/logo.webp) or prefixes (/assets/). They are rewritten
# to the selected app's upstream base path and sent to that app's origin.
CUSTOM_ASSET_PATHS=(); CUSTOM_ASSET_TARGETS=(); CUSTOM_ASSET_EXACT=()
if (( APP_COUNT > 0 )); then
  printf '\nถ้ามีไฟล์/API บาง path ยังไปผิดเว็บ ให้เพิ่ม path บังคับส่งไปยังเว็บลูกได้\n'
  read_value 'จำนวน path เพิ่มเติม (ใส่ 0 ถ้าไม่ต้องเพิ่ม): ' '0'
  CUSTOM_ASSET_COUNT=$REPLY
  [[ $CUSTOM_ASSET_COUNT =~ ^[0-9]{1,2}$ ]] && (( CUSTOM_ASSET_COUNT <= 50 )) || die 'จำนวน path เพิ่มเติมต้องเป็น 0 ถึง 50'
  for ((asset_i=1; asset_i<=CUSTOM_ASSET_COUNT; asset_i++)); do
    printf '\nPath เพิ่มเติม #%d (เช่น /assets/ หรือ /logo.webp)\n' "$asset_i"
    read_value '  Path ที่ browser เรียก: ' ''
    asset_path=${REPLY#/}
    asset_exact=false
    [[ $asset_path == */ ]] || asset_exact=true
    asset_path=${asset_path%/}
    [[ $asset_path =~ ^[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*$ ]] || die 'Path เพิ่มเติมไม่ถูกต้อง; ใช้ตัวอักษร/ตัวเลข . _ ~ - และ / โดยไม่ใส่ query string'
    [[ ! /$asset_path/ =~ /\.\./|/\./ ]] || die 'Path เพิ่มเติมห้ามมี segment . หรือ ..'
    for existing in "${CUSTOM_ASSET_PATHS[@]-}"; do [[ $existing != "$asset_path" ]] || die "Path เพิ่มเติมซ้ำ: /$asset_path"; done
    for existing in "${APP_PATHS[@]}"; do [[ $asset_path != "$existing" ]] || die "Path นี้ชนกับ path เว็บลูก /$existing/; เลือก path ของ asset ที่เฉพาะเจาะจงกว่า"; done
    main_native_check=${MAIN_BASE_PATH#/}; main_native_check=${main_native_check%/}
    [[ -z $main_native_check || $asset_path != "$main_native_check" ]] || die "Path นี้ชนกับ native path เว็บหลัก /$main_native_check/"
    for existing in "${APP_BASE_PATHS[@]}"; do
      existing=${existing#/}; existing=${existing%/}
      [[ -z $existing || $asset_path != "$existing" ]] || die "Path นี้ชนกับ native path ของเว็บลูก /$existing/"
    done
    printf '  เลือกเว็บปลายทาง:\n  [0] เว็บหลัก: %s\n' "$MAIN_URL"
    for ((asset_app=0; asset_app<APP_COUNT; asset_app++)); do printf '  [%d] /%s/ → %s\n' "$((asset_app+1))" "${APP_PATHS[$asset_app]}" "${APP_URLS[$asset_app]}"; done
    read_value "  ส่ง path นี้ไปเว็บหมายเลข [0-$APP_COUNT]: " '0'
    [[ $REPLY =~ ^[0-9]{1,2}$ ]] || die 'หมายเลขเว็บปลายทางไม่ถูกต้อง'
    asset_target=$((10#$REPLY))
    (( asset_target <= APP_COUNT )) || die 'หมายเลขเว็บปลายทางไม่ถูกต้อง'
    CUSTOM_ASSET_PATHS+=("$asset_path"); CUSTOM_ASSET_TARGETS+=("$asset_target"); CUSTOM_ASSET_EXACT+=("$asset_exact")
  done
fi

# Proxy defaults support HTTP/1.1, WebSockets, forwarding headers, and upstream TLS SNI.
proxy_block() {
  local url=$1 host_header=$2 location_name=$3 strip_prefix=${4:-false}
  local native_asset_code=${5-}
  local pass_url=$url
  [[ $strip_prefix == true ]] && pass_url="${url%/}/"
  cat <<BLOCK
    location $location_name {
BLOCK
  if [[ $location_name == '/' && $AUTO_ASSET_ROUTING == true ]]; then
    for ((route_i=0; route_i<APP_COUNT; route_i++)); do
      route_code=$((418+route_i)); route_regex=${APP_PATHS[$route_i]//./\\.}
      printf '        if ($http_referer ~* "/%s(?:/|$)") { return %d; }\n' "$route_regex" "$route_code"
    done
  fi
  if [[ -n $native_asset_code && $AUTO_ASSET_ROUTING == true ]]; then
    # Sec-Fetch-Dest classifies browser resources without guessing their names
    # or directory. Extension matching covers older clients without Fetch Metadata.
    printf '        if ($http_sec_fetch_dest ~* "^(audio|audioworklet|font|image|manifest|object|paintworklet|script|sharedworker|style|track|video|worker|xslt)$") { return %s; }\n' "$native_asset_code"
    printf '        if ($uri ~* "\\.(?:avif|bmp|css|eot|gif|ico|jpe?g|js|map|mjs|otf|png|svg|ttf|wasm|webp|woff2?|mp3|mp4|ogg|webm)$") { return %s; }\n' "$native_asset_code"
  fi
  cat <<BLOCK
        proxy_pass $pass_url;
        proxy_http_version 1.1;
        proxy_set_header Host $host_header;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $FORWARDED_PROTO_VALUE;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_ssl_server_name on;
        proxy_ssl_name \$proxy_host;
        proxy_redirect off;
    }
BLOCK
}

TMP_CONF=$(mktemp /etc/nginx/conf.d/.reverse_proxy.XXXXXX)
OLD_CONF=''
if [[ -e $CONF_FILE ]]; then
  mkdir -p "$BACKUP_DIR"
  OLD_CONF="$BACKUP_DIR/reverse_proxy.conf.$(date +%Y%m%d-%H%M%S).bak"
  cp -a "$CONF_FILE" "$OLD_CONF"
fi
cleanup() { [[ -n ${TMP_CONF:-} && -e $TMP_CONF ]] && rm -f "$TMP_CONF"; }
trap cleanup EXIT

{
  cat <<'HEAD'
# Managed by setup_reverse_proxy.sh. Review before making manual edits.
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
HEAD
  printf '\nserver {\n    listen %s;\n' "$LISTEN_PORT"
  if [[ $TLS_MODE == on ]]; then
    printf '    listen [::]:%s ssl;\n    ssl_certificate %s;\n    ssl_certificate_key %s;\n' "$LISTEN_PORT" "$CERT_FILE" "$KEY_FILE"
  else
    printf '    listen [::]:%s;\n' "$LISTEN_PORT"
  fi
  printf '    server_name %s;\n    server_tokens off;\n    absolute_redirect off;\n\n' "$DOMAIN"
  # Some upstreams (including Google) can return large response headers/cookies.
  # Keep the buffers large enough to avoid intermittent 502 responses.
  cat <<'BUFFERS'
    proxy_buffer_size 16k;
    proxy_buffers 8 16k;
    proxy_busy_buffers_size 32k;

BUFFERS
  if [[ $AUTO_ASSET_ROUTING == true ]]; then
    for ((i=0; i<APP_COUNT; i++)); do
      printf '    error_page %d = @rp_asset_%d;\n' "$((418+i))" "$((i+1))"
      printf '    error_page %d = @rp_asset_native_%d;\n' "$((460+i))" "$((i+1))"
    done
  fi
  proxy_block "$MAIN_URL" "$MAIN_HOST_HEADER" '/' true
  # Also expose the main application's native base path. Apps that emit absolute
  # Root-relative URLs under the app's native base path need a direct alias.
  main_native=${MAIN_BASE_PATH#/}; main_native=${main_native%/}
  if [[ -n $main_native ]]; then
    main_alias_conflict=false
    for configured_path in "${APP_PATHS[@]}"; do
      if [[ $main_native == "$configured_path" || $main_native == "$configured_path/"* || $configured_path == "$main_native/"* ]]; then main_alias_conflict=true; fi
    done
    if [[ $main_alias_conflict == false ]]; then
      # Proxy the exact native URL as-is. Redirecting it to a trailing slash can
      # loop when the upstream app redirects back to its slashless canonical URL.
      main_exact_url=${MAIN_URL%/}
      proxy_block "$main_exact_url" "$MAIN_HOST_HEADER" "= /$main_native" false
      proxy_block "$MAIN_URL" "$MAIN_HOST_HEADER" "^~ /$main_native/" true
    else
      warn "ไม่ได้สร้าง native-path alias เว็บหลัก /$main_native/ เพราะชนกับ path เว็บลูกที่ตั้งไว้"
    fi
  fi
  for ((i=0; i<APP_COUNT; i++)); do
    path=${APP_PATHS[$i]}; url=${APP_URLS[$i]}; header=${APP_HOSTS[$i]}
    printf '\n    location = /%s { return 301 /%s/$is_args$args; }\n' "$path" "$path"
    if [[ $AUTO_ASSET_ROUTING == true ]]; then
      native_asset_code=$((460+i))
    else
      native_asset_code=''
    fi
    proxy_block "$url" "$header" "/$path/" true "$native_asset_code"
    native=${APP_BASE_PATHS[$i]#/}; native=${native%/}
    if [[ -n $native && $native != "$path" ]]; then
      conflict=false
      for ((configured_i=0; configured_i<APP_COUNT; configured_i++)); do
        [[ $configured_i == $i ]] && continue
        configured_path=${APP_PATHS[$configured_i]}
        if [[ $native == "$configured_path" || $native == "$configured_path/"* || $configured_path == "$native/"* ]]; then conflict=true; fi
      done
      if [[ -n ${main_native:-} && ( $native == "$main_native" || $native == "$main_native/"* || $main_native == "$native/"* ) ]]; then
        # The same upstream path can be shared by the main app and a child app.
        # Keep one native alias when both entries target the same URL.
        if [[ $native != "$main_native" || ${MAIN_URL%/} != ${url%/} ]]; then conflict=true; fi
      fi
      for ((other_i=0; other_i<APP_COUNT; other_i++)); do
        [[ $other_i == $i ]] && continue
        other_native=${APP_BASE_PATHS[$other_i]#/}; other_native=${other_native%/}
        if [[ -n $other_native && ( $native == "$other_native" || $native == "$other_native/"* || $other_native == "$native/"* ) ]]; then conflict=true; fi
      done
      if [[ $conflict == false ]]; then
        printf '\n    # Native upstream path alias. A more-specific alias can sit below the public child path.\n'
        # Proxy the exact native URL as-is to avoid a slash redirect loop with apps
        # whose canonical URL omits the trailing slash.
        native_exact_url=${url%/}
        proxy_block "$native_exact_url" "$header" "= /$native" false
        proxy_block "$url" "$header" "^~ /$native/" true
      else
        warn "ไม่ได้สร้าง native-path alias /$native/ เพราะชนกับ path เว็บลูกที่ตั้งไว้"
      fi
    fi
  done
  for ((asset_i=0; asset_i<${#CUSTOM_ASSET_PATHS[@]}; asset_i++)); do
    asset_path=${CUSTOM_ASSET_PATHS[$asset_i]}; asset_target=${CUSTOM_ASSET_TARGETS[$asset_i]}
    if (( asset_target == 0 )); then
      asset_url=$MAIN_URL; asset_header=$MAIN_HOST_HEADER; asset_base_path=$MAIN_BASE_PATH
    else
      asset_index=$((asset_target-1)); asset_url=${APP_URLS[$asset_index]}; asset_header=${APP_HOSTS[$asset_index]}; asset_base_path=${APP_BASE_PATHS[$asset_index]}
    fi
    asset_scheme=${asset_url%%://*}; asset_authority=${asset_url#*://}; asset_authority=${asset_authority%%/*}
    asset_origin="${asset_scheme}://${asset_authority}"
    asset_rewrite_base=${asset_base_path%/}
    if [[ ${CUSTOM_ASSET_EXACT[$asset_i]} == true ]]; then
      printf '\n    location = /%s {\n' "$asset_path"
    else
      printf '\n    location ^~ /%s/ {\n' "$asset_path"
    fi
    if [[ -n $asset_rewrite_base ]]; then printf '        rewrite ^ %s$uri break;\n' "$asset_rewrite_base"; fi
    printf '        proxy_pass %s;\n        proxy_http_version 1.1;\n        proxy_set_header Host %s;\n' "$asset_origin" "$asset_header"
    printf '        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto %s;\n        proxy_set_header X-Forwarded-Host $host;\n        proxy_ssl_server_name on;\n        proxy_ssl_name $proxy_host;\n        proxy_redirect off;\n    }\n' "$FORWARDED_PROTO_VALUE"
  done
  if [[ $AUTO_ASSET_ROUTING == true ]]; then
    cat <<'ASSET'

    # Any root-relative request with an app Referer is sent to that app.
    # Native upstream paths (e.g. /remote/ or /P_Transporter/) have direct aliases above.
ASSET
    for ((i=0; i<APP_COUNT; i++)); do
      code=$((418+i)); origin=${APP_ASSET_ORIGINS[$i]}; header=${APP_HOSTS[$i]}; base_path=${APP_BASE_PATHS[$i]}
      rewrite_base=${base_path%/}
      printf '\n    location @rp_asset_%d {\n' "$((i+1))"
      if [[ -n $rewrite_base ]]; then printf '        rewrite ^ %s$uri break;\n' "$rewrite_base"; fi
      printf '        proxy_pass %s;\n        proxy_http_version 1.1;\n        proxy_set_header Host %s;\n' "$origin" "$header"
      printf '        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto %s;\n        proxy_ssl_server_name on;\n        proxy_ssl_name $proxy_host;\n    }\n' "$FORWARDED_PROTO_VALUE"

      # Browser-classified resources under the public child path keep their URI
      # unchanged. This also covers arbitrary image names and nested asset folders.
      printf '\n    location @rp_asset_native_%d {\n' "$((i+1))"
      printf '        proxy_pass %s;\n        proxy_http_version 1.1;\n        proxy_set_header Host %s;\n' "$origin" "$header"
      printf '        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto %s;\n        proxy_set_header X-Forwarded-Host $host;\n        proxy_ssl_server_name on;\n        proxy_ssl_name $proxy_host;\n        proxy_redirect off;\n    }\n' "$FORWARDED_PROTO_VALUE"
    done
  fi
  printf '}\n'
} > "$TMP_CONF"
chmod 0644 "$TMP_CONF"
mv -f "$TMP_CONF" "$CONF_FILE"
TMP_CONF=''

if ! nginx -t; then
  if [[ -n $OLD_CONF ]]; then
    cp -a "$OLD_CONF" "$CONF_FILE"
  else
    rm -f "$CONF_FILE"
  fi
  die "nginx -t ไม่ผ่าน จึงคืนคอนฟิกเดิมแล้ว: $CONF_FILE (สำรอง: ${OLD_CONF:-ไม่มี})"
fi
systemctl enable nginx
if systemctl is-active --quiet nginx; then systemctl reload nginx; else systemctl start nginx; fi

# Open selected port only if a firewall is already active. Never enable a firewall automatically.
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${LISTEN_PORT}/tcp" >/dev/null
  firewall-cmd --reload >/dev/null
fi
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
  ufw allow "${LISTEN_PORT}/tcp" >/dev/null
fi

printf "\n${GREEN}ตั้งค่า Nginx สำเร็จ${NC}\n"
printf 'URL สำหรับผู้ใช้: %s://%s/\n' "$PUBLIC_SCHEME" "$DOMAIN"
printf 'Nginx รับคำขอที่: %s://127.0.0.1:%s/\n' "$LISTEN_SCHEME" "$LISTEN_PORT"
printf 'เว็บหลัก: %s\n' "$MAIN_URL"
for ((i=0; i<APP_COUNT; i++)); do printf 'เว็บลูก: %s://%s/%s/ → %s\n' "$PUBLIC_SCHEME" "$DOMAIN" "${APP_PATHS[$i]}" "${APP_URLS[$i]}"; done
[[ -n $OLD_CONF ]] && printf 'สำรองคอนฟิกเดิม: %s\n' "$OLD_CONF"
printf '\nถ้าใช้ Cloudflare Tunnel ให้กำหนด ingress service เป็น http://127.0.0.1:%s แล้ว restart cloudflared\n' "$LISTEN_PORT"
printf 'ตรวจ log: sudo journalctl -u nginx -n 50 --no-pager\n'
printf 'คอนฟิก: %s\n' "$CONF_FILE"
printf 'หากต้องแก้คอนฟิกเอง: sudo nano %s\n' "$CONF_FILE"
printf 'หลังแก้คอนฟิก: sudo nginx -t && sudo systemctl reload nginx\n'
printf 'หมายเหตุ: การรัน wizard รอบถัดไปจะสร้างไฟล์คอนฟิกนี้ใหม่ โดยสำรองไฟล์เดิมไว้ใน %s\n' "$BACKUP_DIR"
