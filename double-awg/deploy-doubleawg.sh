#!/usr/bin/env bash
#
# deploy-doubleawg.sh — развертывание DoubleAWG (каскад из двух VPS) на AmneziaWG, kernel-mode.
#
#   Клиенты ──IPv4──▶ [VPS1: gate1..gateN │ inway] ══IPv6══▶ [VPS2: outway] ──IPv4/NAT──▶ Интернет
#
#   * Канал: inway (VPS1) <-> outway (VPS2). Адреса внутри Канала — IPv6 ULA, транспорт между VPS —
#     IPv6 (если IPv6 нет, скрипт предложит IPv4). Выход в интернет с VPS2 — IPv4 через NAT.
#   * Входные интерфейсы клиентов на VPS1: <префикс>1, <префикс>2, ... Каждый со своей версией AWG,
#     портом, подсетью (любой, /8../30, подсети не обязаны быть смежными) и режимом: listen — клиенты
#     подключаются к серверу, connect — сервер сам подключается к клиенту (у клиента ListenPort).
#   * VPS2 подсети клиентов не знает: соединения из Канала помечаются, NAT и возврат ответов — по метке,
#     поэтому новые входные интерфейсы на VPS1 добавляются без изменений на VPS2.
#   * Версии AmneziaWG: 1 (1.0), 1.5, 2 (2.0), 3 (3.0), 3.1 — отдельно для Канала и каждого входа.
#   * Kill-switch: трафик клиентов уходит только в Канал; если Канал лежит — блокируется.
#   * Split (по желанию, отдельно для каждого входного интерфейса, переключается строками в его .conf):
#     трафик к российским IPv4 напрямую с VPS1, остальное в Канал. Список RU обновляется таймером.
#   * Если для загрузки модуля нужна перезагрузка VPS, скрипт перезагрузит узел (с подтверждением).
#
# На серверах рядом с конфигами (/etc/amnezia/amneziawg) остаются скрипты управления:
#   VPS1: dawg-gate-add.sh, dawg-gate-del.sh, dawg-client-add.sh, dawg-client-del.sh, dawg-channel-del.sh
#   VPS2: dawg-channel-del.sh
#
# Машина запуска: Linux/WSL, bash 4.4+, ssh (доступ к VPS по ключу), wireguard-tools (wg), tar.
# VPS: Ubuntu 24.04, KVM/выделенный сервер (не OpenVZ/LXC), root или sudo.
# Необязательные переменные окружения: ENTRY_SSH, EXIT_SSH, ENTRY_SSH_PORT, EXIT_SSH_PORT, OUT_DIR
#
set -Eeuo pipefail

SCRIPT_VERSION="2.1"
AWG_DIR=/etc/amnezia/amneziawg      # каталог конфигов awg-quick на серверах
RT_BASE=7100                        # таблица маршрутизации входного интерфейса N = RT_BASE + N

# ─────────────────────────────── оформление ───────────────────────────────
if [[ -t 2 ]]; then
  C_R=$'\e[1;31m'; C_G=$'\e[1;32m'; C_Y=$'\e[1;33m'; C_C=$'\e[1;36m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else
  C_R=; C_G=; C_Y=; C_C=; C_B=; C_0=
fi
info() { printf '%s==>%s %s\n' "$C_C" "$C_0" "$*" >&2; }
ok()   { printf '%s[ok]%s %s\n' "$C_G" "$C_0" "$*" >&2; }
warn() { printf '%s[!]%s %s\n'  "$C_Y" "$C_0" "$*" >&2; }
die()  { printf '%s[x]%s %s\n'  "$C_R" "$C_0" "$*" >&2; exit 1; }

ask() {  # ask VAR "вопрос" ["по умолчанию"]
  local __var=$1 __prompt=$2 __def=${3-} __ans=""
  if [[ -n $__def ]]; then
    read -r -p "$__prompt [$__def]: " __ans </dev/tty || true
  else
    read -r -p "$__prompt: " __ans </dev/tty || true
  fi
  [[ -z $__ans ]] && __ans=$__def
  printf -v "$__var" '%s' "$__ans"
}
confirm() {  # confirm "вопрос" [Y|N]
  local def=${2:-Y} a hint="[Y/n]"
  [[ $def == N ]] && hint="[y/N]"
  while :; do
    read -r -p "$1 $hint: " a </dev/tty || true
    a=${a:-$def}
    case ${a,,} in
      y|yes|д|да) return 0 ;;
      n|no|н|нет) return 1 ;;
    esac
  done
}

# ═══════════ общие функции: используются здесь и на серверах (копируются в dawg-lib.sh) ═══════════
rnd() {  # rnd MIN MAX — криптостойкое случайное целое
  local min=$1 max=$2 r
  r=$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n')
  echo $(( min + r % (max - min + 1) ))
}
hexbytes() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }
awg_ver_ok() { case ${1-} in 1|1.5|2|3|3.1) return 0 ;; esac; return 1; }

# gen_obf ВЕРСИЯ [yes|no для I1] — параметры обфускации в переменные O_*; ключ HP берется из $KEYGEN
#   1   : Jc Jmin Jmax S1 S2 H1-H4 (одиночные значения)
#   1.5 : 1 + I1
#   2   : + S3 S4, H1-H4 диапазонами
#   3   : + HeaderProtectionKey, ContentPaddingAddition; S1-S4 >= 12, H1-H4 = 1..4
#   3.1 : 3 + RandomTrailers, DisableCookies
gen_obf() {
  local ver=$1 use_i1=${2:-yes} lo=5 hi=2147483647 band i j tmp blo w s fb
  local -a order=(0 1 2 3) hh=()
  O_JC=$(rnd 4 8); O_JMIN=$(rnd 40 90); O_JMAX=$(rnd $(( O_JMIN + 150 )) 1000)
  O_S1=$(rnd 15 150)
  while :; do O_S2=$(rnd 15 150); [ $(( O_S1 + 148 )) -ne $(( O_S2 + 92 )) ] && break; done
  O_S3=""; O_S4=""; O_I1=""; O_HPK=""; O_CPA=""; O_RT=""; O_DC=""
  case $ver in
    2|3|3.1)
      while :; do
        O_S3=$(rnd 15 150)
        [ $(( O_S3 + 64 )) -ne $(( O_S1 + 148 )) ] && [ $(( O_S3 + 64 )) -ne $(( O_S2 + 92 )) ] && break
      done
      if [ "$ver" = 2 ]; then O_S4=$(rnd 4 16); else O_S4=$(rnd 12 24); fi
      ;;
  esac
  case $ver in
    3|3.1) hh=(1 2 3 4) ;;   # при Header Protection тип сообщения скрыт шифрованием заголовка
    *)
      band=$(( (hi - lo + 1) / 4 ))
      for (( i = 3; i > 0; i-- )); do j=$(rnd 0 "$i"); tmp=${order[i]}; order[i]=${order[j]}; order[j]=$tmp; done
      for i in 0 1 2 3; do
        blo=$(( lo + order[i] * band ))
        if [ "$ver" = 2 ]; then
          w=$(rnd 1000000 50000000); s=$(rnd "$blo" $(( blo + band - w - 1 ))); hh[i]="$s-$(( s + w ))"
        else
          hh[i]=$(rnd "$blo" $(( blo + band - 1 )))
        fi
      done
      ;;
  esac
  O_H1=${hh[0]}; O_H2=${hh[1]}; O_H3=${hh[2]}; O_H4=${hh[3]}
  if [ "$use_i1" = yes ] && [ "$ver" != 1 ]; then
    # CPS-пакет перед рукопожатием: имитация QUIC Initial (long header, v1, DCID 8 байт, 1200 байт)
    fb=$(printf '%02x' "$(rnd 192 207)")
    O_I1="<b 0x${fb}0000000108><r 8><b 0x0000449e><r 1000><r 182>"
  fi
  case $ver in 3|3.1) O_HPK=$($KEYGEN); O_CPA="0-$(rnd 8 32)" ;; esac
  if [ "$ver" = 3.1 ]; then O_RT=on; O_DC=on; fi
}
obf_lines() {
  printf 'Jc = %s\nJmin = %s\nJmax = %s\n' "$O_JC" "$O_JMIN" "$O_JMAX"
  printf 'S1 = %s\nS2 = %s\n' "$O_S1" "$O_S2"
  if [ -n "$O_S3" ]; then printf 'S3 = %s\nS4 = %s\n' "$O_S3" "$O_S4"; fi
  printf 'H1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' "$O_H1" "$O_H2" "$O_H3" "$O_H4"
  if [ -n "$O_I1" ]; then printf 'I1 = %s\n' "$O_I1"; fi
  if [ -n "$O_HPK" ]; then printf 'HeaderProtectionKey = %s\nContentPaddingAddition = %s\n' "$O_HPK" "$O_CPA"; fi
  if [ -n "$O_RT" ]; then printf 'RandomTrailers = %s\nDisableCookies = %s\n' "$O_RT" "$O_DC"; fi
  return 0
}
obf_s4() { echo "${O_S4:-0}"; }

# ── IPv4-подсети ──
ip2int() { local a b c d; IFS=. read -r a b c d <<< "$1"; echo $(( (10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d )); }
int2ip() { local n=$1; echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"; }
cidr_parse() {  # cidr_parse CIDR [MINLEN MAXLEN] -> C_NET C_LAST (целые), C_LEN, C_STR (нормализованная запись)
  local o1 o2 o3 o4 len mask min=${2:-0} max=${3:-32}
  [[ ${1-} =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
  o1=${BASH_REMATCH[1]}; o2=${BASH_REMATCH[2]}; o3=${BASH_REMATCH[3]}; o4=${BASH_REMATCH[4]}; len=$(( 10#${BASH_REMATCH[5]} ))
  [ $(( 10#$o1 )) -le 255 ] && [ $(( 10#$o2 )) -le 255 ] && [ $(( 10#$o3 )) -le 255 ] && [ $(( 10#$o4 )) -le 255 ] || return 1
  [ "$len" -ge "$min" ] && [ "$len" -le "$max" ] || return 1
  mask=$(( (0xffffffff << (32 - len)) & 0xffffffff ))
  C_NET=$(( $(ip2int "$o1.$o2.$o3.$o4") & mask )); C_LEN=$len
  C_LAST=$(( C_NET | (~mask & 0xffffffff) ))
  C_STR="$(int2ip "$C_NET")/$len"
}
cidr_overlap() {  # cidr_overlap A B — 0, если подсети пересекаются
  local n1 l1 n2 l2 l m
  cidr_parse "$1" || return 1; n1=$C_NET; l1=$C_LEN
  cidr_parse "$2" || return 1; n2=$C_NET; l2=$C_LEN
  l=$(( l1 < l2 ? l1 : l2 )); m=$(( (0xffffffff << (32 - l)) & 0xffffffff ))
  [ $(( n1 & m )) -eq $(( n2 & m )) ]
}
net_conflict() {  # net_conflict CIDR "список подсетей" — вывести первую пересекающуюся
  local a
  for a in $2; do
    if cidr_overlap "$1" "$a"; then echo "$a"; return 0; fi
  done
  return 1
}
SHARED_FUNCS="rnd hexbytes awg_ver_ok gen_obf obf_lines obf_s4 ip2int int2ip cidr_parse cidr_overlap net_conflict"

# ─────────────────────────────── локальные утилиты ───────────────────────────────
KEYGEN="wg genkey"
is_ipv4() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_ipv6() { [[ $1 == *:* && $1 =~ ^[0-9A-Fa-f:]+$ ]]; }
is_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_ifname() { [[ ${1-} =~ ^[A-Za-z0-9_=+.-]{1,15}$ ]]; }
is_key() { [[ ${1-} =~ ^[A-Za-z0-9+/]{43}=$ ]]; }
pubkey() { printf '%s' "$1" | wg pubkey; }

WORK=""
declare -A TARGET=() PORT=() INFO=() SUDO_MODE=()
declare -A N_IF4=() N_PUB4=() N_IF6=() N_IP6=() N_MTU4=() N_MTU6=()

cleanup() {
  local n
  if [[ -n $WORK && -d $WORK ]]; then
    for n in entry exit; do
      [[ -n ${TARGET[$n]-} ]] && ssh -O exit -o ControlPath="$WORK/cm-$n" "${TARGET[$n]}" >/dev/null 2>&1 || true
    done
    rm -rf "$WORK"
  fi
}

ssh_cmd() {  # ssh_cmd NODE [-t] команда...
  local n=$1; shift
  local t=()
  if [[ ${1-} == -t ]]; then t=(-t); shift; fi
  ssh -p "${PORT[$n]}" \
      -o ControlMaster=auto -o ControlPath="$WORK/cm-$n" -o ControlPersist=20m \
      -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=20 -o ConnectTimeout=15 \
      ${t[@]+"${t[@]}"} "${TARGET[$n]}" "$@"
}

run_root() {  # run_root NODE ЛОКАЛЬНЫЙ_СКРИПТ — выполнить на узле от root
  local n=$1 file=$2 remote pre cmd
  remote="/tmp/dawg-$(date +%s)-$RANDOM.sh"
  ssh_cmd "$n" "umask 077 && cat > '$remote'" < "$file"
  case ${SUDO_MODE[$n]} in
    root)     pre="" ;;
    nopasswd) pre="sudo -n" ;;
    *)        pre="sudo" ;;
  esac
  cmd="$pre bash '$remote'; rc=\$?; rm -f '$remote'; exit \$rc"
  if [[ ${SUDO_MODE[$n]} == passwd ]]; then ssh_cmd "$n" -t "$cmd"; else ssh_cmd "$n" "$cmd"; fi
}

root_cmd() {  # root_cmd NODE "команда"
  local n=$1 c=$2
  case ${SUDO_MODE[$n]} in
    root)     ssh_cmd "$n" "$c" ;;
    nopasswd) ssh_cmd "$n" "sudo -n sh -c '$c'" ;;
    *)        ssh_cmd "$n" -t "sudo sh -c '$c'" ;;
  esac
}

nfo() { printf '%s' "${INFO[$1.$2]-}"; }

reboot_node() {  # перезагрузить VPS и дождаться ssh
  local n=$1 old new i
  old=$(ssh_cmd "$n" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)
  info "Перезагрузка ${TARGET[$n]}..."
  root_cmd "$n" "systemctl reboot" >/dev/null 2>&1 || true
  ssh -O exit -o ControlPath="$WORK/cm-$n" "${TARGET[$n]}" >/dev/null 2>&1 || true
  sleep 20
  for (( i = 0; i < 60; i++ )); do
    new=$(ssh_cmd "$n" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)
    if [[ -n $new && $new != "$old" ]]; then
      INFO["$n.KERNEL"]=$(ssh_cmd "$n" 'uname -r' 2>/dev/null || true)
      ok "${TARGET[$n]} снова доступен, ядро ${INFO[$n.KERNEL]}"
      sleep 5
      return 0
    fi
    ssh -O exit -o ControlPath="$WORK/cm-$n" "${TARGET[$n]}" >/dev/null 2>&1 || true
    sleep 10
  done
  die "${TARGET[$n]} не вернулся после перезагрузки за 10 минут. Файлы: $OUT — запустите установку заново"
}

deploy_node() {  # deploy_node NODE BUNDLE МЕТКА — код 10 от узла = нужна перезагрузка (не более одной)
  local n=$1 bundle=$2 label=$3 rc reboots=0
  while :; do
    rc=0
    run_root "$n" "$bundle" || rc=$?
    [[ $rc -eq 10 ]] || return "$rc"
    (( reboots == 0 )) || die "$label: модуль не загрузился и после перезагрузки"
    reboots=1
    warn "$label: для загрузки модуля AmneziaWG нужна перезагрузка VPS"
    confirm "Перезагрузить ${TARGET[$n]} сейчас и продолжить установку?" Y \
      || die "Перезагрузите VPS вручную и запустите скрипт заново (будут сгенерированы новые ключи)"
    reboot_node "$n"
  done
}

# ─────────────────────────────── опрос узлов ───────────────────────────────
check_local() {
  local c
  (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || die "Нужен bash 4.4 или новее"
  for c in ssh wg od awk tr mktemp tar; do
    command -v "$c" >/dev/null 2>&1 || die "Не найдена команда '$c' на машине запуска${c/wg/ (установите wireguard-tools)}"
  done
}

write_probe() {
  cat > "$WORK/probe.sh" <<'PROBE'
export LC_ALL=C
. /etc/os-release 2>/dev/null
echo "OS_ID=${ID:-unknown}"
echo "OS_VER=${VERSION_ID:-unknown}"
echo "OS_NAME=${PRETTY_NAME:-unknown}"
echo "KERNEL=$(uname -r)"
v=$(systemd-detect-virt 2>/dev/null); echo "VIRT=${v:-unknown}"
if [ "$(id -u)" -eq 0 ]; then s=root
elif sudo -n true 2>/dev/null; then s=nopasswd
elif command -v sudo >/dev/null 2>&1; then s=passwd
else s=none; fi
echo "SUDO=$s"
defdev() { ip "$1" route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}'; }
if4=$(defdev -4); echo "IF4=$if4"
if [ -n "$if4" ]; then
  echo "IP4=$(ip -4 -o addr show dev "$if4" scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
  echo "MTU4=$(cat "/sys/class/net/$if4/mtu" 2>/dev/null)"
fi
if6=$(defdev -6); echo "IF6=$if6"
if [ -n "$if6" ]; then
  echo "IP6=$(ip -6 -o addr show dev "$if6" scope global 2>/dev/null | awk '!/temporary|deprecated|tentative/ {split($4,a,"/"); if (a[1] !~ /^f[cd]/) {print a[1]; exit}}')"
  echo "MTU6=$(cat "/sys/class/net/$if6/mtu" 2>/dev/null)"
fi
pub=$( { curl -4 -fsS --max-time 6 https://api.ipify.org || curl -4 -fsS --max-time 6 https://ifconfig.me/ip || wget -4 -qO- --timeout=6 https://api.ipify.org; } 2>/dev/null | head -c 64 | tr -d '\r\n')
echo "PUB4=$pub"
echo "MOD_VER=$(modinfo -F version amneziawg 2>/dev/null)"
echo "LINKS=$(ls /sys/class/net 2>/dev/null | tr '\n' ' ')"
echo "ROUTES4=$(ip -4 route show table main 2>/dev/null | awk '$1 != "default" { n = ""; d = "-"; for (i = 1; i <= NF; i++) { if (n == "" && $i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) n = $i; if ($i == "dev") d = $(i + 1) } if (n != "") { if (n !~ /\//) n = n "/32"; print n "@" d } }' | tr '\n' ' ')"h=$(apt-cache policy "linux-headers-$(uname -r)" 2>/dev/null | awk '/Candidate:/ {print $2}')
echo "HEADERS=${h:-none}"
if [ -f /var/run/reboot-required ]; then echo "REBOOT=yes"; else echo "REBOOT=no"; fi
chk='D=/etc/amnezia/amneziawg; if [ -f $D/dawg.env ]; then echo v2; else echo none; fi'
case $s in
  root) p=$(sh -c "$chk") ;;
  nopasswd) p=$(sudo -n sh -c "$chk") ;;
  *) p=unknown ;;
esac
echo "PREV=$p"
PROBE
}

probe_node() {
  local n=$1 out k v
  info "Подключение к ${TARGET[$n]} (порт ${PORT[$n]})..."
  ssh_cmd "$n" true || die "Не удалось подключиться по ssh к ${TARGET[$n]}"
  out=$(ssh_cmd "$n" 'bash -s' < "$WORK/probe.sh") || die "Не удалось опросить ${TARGET[$n]}"
  while IFS='=' read -r k v; do
    case $k in
      OS_ID|OS_VER|OS_NAME|KERNEL|VIRT|SUDO|IF4|IP4|MTU4|IF6|IP6|MTU6|PUB4|MOD_VER|LINKS|ROUTES4|HEADERS|REBOOT|PREV)
        INFO["$n.$k"]=$v ;;
    esac
  done <<< "$out"
}

check_node() {
  local n=$1 label=$2 virt os ver hdr
  virt=$(nfo "$n" VIRT); os=$(nfo "$n" OS_ID); ver=$(nfo "$n" OS_VER); hdr=$(nfo "$n" HEADERS)
  SUDO_MODE[$n]=$(nfo "$n" SUDO)
  case ${SUDO_MODE[$n]} in
    root|nopasswd) ;;
    passwd) warn "$label: sudo требует пароль — его спросят во время установки" ;;
    *) die "$label: пользователь не root и sudo недоступен" ;;
  esac
  case $virt in
    openvz|lxc|lxc-libvirt|systemd-nspawn|docker|podman|rkt|wsl|proot)
      die "$label: контейнерная виртуализация ($virt) — свой модуль ядра загрузить нельзя, kernel-mode невозможен" ;;
  esac
  if [[ $os != ubuntu || $ver != 24.04 ]]; then
    warn "$label: ОС '$(nfo "$n" OS_NAME)', скрипт рассчитан на Ubuntu 24.04"
    confirm "Продолжить на свой страх и риск?" N || exit 1
  fi
  if [[ $hdr == none || $hdr == "(none)" ]]; then
    warn "$label: для ядра $(nfo "$n" KERNEL) нет linux-headers — будет поставлено актуальное ядро и предложена перезагрузка."
  fi
  if [[ $(nfo "$n" REBOOT) == yes ]]; then
    warn "$label: система ждет перезагрузки (/var/run/reboot-required); при необходимости скрипт предложит перезагрузить VPS."
  fi
  case $(nfo "$n" PREV) in
    v2) warn "$label: найдена предыдущая установка DoubleAWG — она будет полностью удалена (вместе с клиентами)."
        confirm "Удалить и установить заново?" N || exit 1 ;;
  esac
}

confirm_node() {
  local n=$1 label=$2 if4 ip4 pub4 if6 ip6 ep4
  if4=$(nfo "$n" IF4); ip4=$(nfo "$n" IP4); pub4=$(nfo "$n" PUB4)
  if6=$(nfo "$n" IF6); ip6=$(nfo "$n" IP6)
  is_ipv4 "$pub4" || pub4=""
  ep4=${pub4:-$ip4}
  printf '\n%s%s — %s%s\n' "$C_B" "$label" "${TARGET[$n]}" "$C_0" >&2
  printf '  ОС / ядро / вирт.:    %s / %s / %s\n' "$(nfo "$n" OS_NAME)" "$(nfo "$n" KERNEL)" "$(nfo "$n" VIRT)" >&2
  printf '  Интерфейс IPv4:       %s\n' "${if4:-не найден}" >&2
  printf '  IPv4 на интерфейсе:   %s\n' "${ip4:-—}" >&2
  printf '  Публичный IPv4:       %s\n' "${pub4:-не определен}" >&2
  printf '  Интерфейс IPv6:       %s\n' "${if6:-нет маршрута IPv6 по умолчанию}" >&2
  printf '  Публичный IPv6:       %s\n' "${ip6:-—}" >&2
  if [[ -n $(nfo "$n" MOD_VER) ]]; then printf '  AmneziaWG (модуль):   %s\n' "$(nfo "$n" MOD_VER)" >&2; fi
  if [[ -n $pub4 && -n $ip4 && $pub4 != "$ip4" ]]; then
    warn "Адрес на интерфейсе ($ip4) отличается от публичного ($pub4) — VPS за NAT, будет использован публичный."
  fi
  if ! confirm "Данные верны?" Y; then
    ask if4 "  Внешний интерфейс IPv4" "$if4"
    ask ep4 "  Публичный IPv4" "$ep4"
    ask if6 "  Внешний интерфейс IPv6 (пусто — IPv6 нет)" "$if6"
    if [[ -n $if6 ]]; then ask ip6 "  Публичный IPv6" "$ip6"; else ip6=""; fi
  fi
  [[ -n $if4 ]] || die "$label: не задан внешний интерфейс IPv4"
  is_ipv4 "$ep4" || die "$label: некорректный IPv4 '$ep4'"
  [[ -z $ip6 ]] || is_ipv6 "$ip6" || die "$label: некорректный IPv6 '$ip6'"
  N_IF4[$n]=$if4; N_PUB4[$n]=$ep4; N_IF6[$n]=$if6; N_IP6[$n]=$ip6
  if [[ $if4 == "$(nfo "$n" IF4)" && -n $(nfo "$n" MTU4) ]]; then N_MTU4[$n]=$(nfo "$n" MTU4); else N_MTU4[$n]=1500; fi
  if [[ -n $if6 && $if6 == "$(nfo "$n" IF6)" && -n $(nfo "$n" MTU6) ]]; then N_MTU6[$n]=$(nfo "$n" MTU6); else N_MTU6[$n]=1500; fi
}

link_on_node() { [[ " $(nfo "$1" LINKS) " == *" $2 "* ]]; }

ask_awg_version() {  # ask_awg_version VAR "вопрос" ПО_УМОЛЧАНИЮ
  local __v=$1 __a
  while :; do
    ask __a "$2" "$3"
    if awg_ver_ok "$__a"; then break; fi
    warn "Допустимо: 1, 1.5, 2, 3, 3.1"
  done
  case $__a in
    3|3.1) warn "AWG $__a: нужны свежие клиенты (AmneziaVPN 5.0.1.5+); многие роутеры и старые приложения поддерживают только до 2.0." ;;
  esac
  printf -v "$__v" '%s' "$__a"
}

# ═════════════════════════ скрипты, которые остаются на серверах ═════════════════════════
src_lib() {
  cat <<'LIB'
#!/bin/bash
# DoubleAWG: общие функции и параметры узла. Подключается остальными dawg-*.sh, сам не запускается.
D=${DAWG_DIR:-/etc/amnezia/amneziawg}
KEYGEN="awg genkey"
if [ -f "$D/dawg.env" ]; then . "$D/dawg.env"; fi
OBF_KEYS='Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4|I1|I2|I3|I4|I5|HeaderProtectionKey|ContentPaddingAddition|RandomTrailers|DisableCookies|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts'

_clr() { if [ -t 2 ]; then printf '\033[%sm' "$1"; fi; }
log()  { printf '%s[%s]%s %s\n' "$(_clr '1;36')" "$(hostname)" "$(_clr 0)" "$*" >&2; }
warn() { printf '%s[%s] !%s %s\n' "$(_clr '1;33')" "$(hostname)" "$(_clr 0)" "$*" >&2; }
die()  { printf '%s[%s] ОШИБКА:%s %s\n' "$(_clr '1;31')" "$(hostname)" "$(_clr 0)" "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "нужны права root: sudo $0"; }
need_role() { [ "${DAWG_ROLE:-}" = "$1" ] || die "скрипт для узла '$1', а этот узел: '${DAWG_ROLE:-не настроен}'"; }
has_tty() { { true </dev/tty; } 2>/dev/null; }
ask() {
  local __v=$1 __p=$2 __d=${3-} __a=""
  if has_tty; then
    if [ -n "$__d" ]; then read -r -p "$__p [$__d]: " __a </dev/tty || true
    else read -r -p "$__p: " __a </dev/tty || true; fi
  fi
  [ -z "$__a" ] && __a=$__d
  printf -v "$__v" '%s' "$__a"
}
confirm() {
  local def=${2:-Y} a hint="[Y/n]"
  [ "$def" = N ] && hint="[y/N]"
  if ! has_tty; then [ "$def" = Y ]; return; fi
  while :; do
    read -r -p "$1 $hint: " a </dev/tty || a=""
    a=${a:-$def}
    case ${a,,} in y|yes|д|да) return 0 ;; n|no|н|нет) return 1 ;; esac
  done
}
valid_ifname() { [[ ${1-} =~ ^[A-Za-z0-9_=+.-]{1,15}$ ]]; }
link_exists() { ip link show "$1" >/dev/null 2>&1; }
link_up() { [ -n "$(ip link show "$1" up 2>/dev/null)" ]; }
port_busy() { ss -Hlun 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; }
gates_all() {
  local f
  for f in "$D"/dawg-gates/*.env; do
    [ -e "$f" ] || continue
    f=${f##*/}; echo "${f%.env}"
  done
}
ipt() {  # ipt add|del БИНАРЬ ТАБЛИЦА ЦЕПОЧКА правило...
  local op=$1 bin=$2 tbl=$3 chain=$4; shift 4
  case $op in
    add) "$bin" -t "$tbl" -C "$chain" "$@" 2>/dev/null || "$bin" -t "$tbl" -I "$chain" "$@" ;;
    del) while "$bin" -t "$tbl" -C "$chain" "$@" 2>/dev/null; do "$bin" -t "$tbl" -D "$chain" "$@"; done ;;
  esac
}
ufw_dawg_del() {  # ufw_dawg_del МЕТКА — удалить правила ufw, comment которых начинается с МЕТКИ
  command -v ufw >/dev/null 2>&1 || return 0
  local tag=$1 n l
  if ufw status 2>/dev/null | grep -q '^Status: active'; then
    while n=$(ufw status numbered 2>/dev/null | awk -F'[][]' -v t="# $tag" 'index($0, t) {gsub(/ /, "", $2); print $2; exit}'); [ -n "$n" ]; do
      ufw --force delete "$n" >/dev/null || break
    done
  else
    ufw show added 2>/dev/null | grep -F "'$tag" | while IFS= read -r l; do
      l=${l#ufw }; l=${l% comment *}
      eval "ufw delete $l" >/dev/null 2>&1 || true
    done
  fi
}
ufw_dawg_add() {  # ufw_dawg_add МЕТКА "правило" ... — правила ufw (старые с той же меткой удаляются)
  local tag=$1 r; shift
  if ! command -v ufw >/dev/null 2>&1; then log "ufw не установлен — правила ufw пропущены"; return 0; fi
  ufw_dawg_del "$tag"
  for r in "$@"; do eval "ufw $r" >/dev/null || warn "ufw: не удалось добавить: $r"; done
  log "ufw: правила '${tag% }' добавлены"
}
awg_check_conf() {  # awg_check_conf CONF — принимают ли модуль и awg параметры конфига
  local f=$1 t="dawgchk$$" tmp rc=0
  t=${t:0:15}; tmp=$(mktemp)
  if ! awg-quick strip "$f" 2>/dev/null | grep -v '^ListenPort' > "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! ip link add "$t" type amneziawg 2>/dev/null; then rm -f "$tmp"; warn "не удалось создать тестовый интерфейс amneziawg"; return 1; fi
  awg setconf "$t" "$tmp" 2>"$tmp.err" || rc=1
  ip link del "$t" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then cat "$tmp.err" >&2; fi
  rm -f "$tmp" "$tmp.err"
  return "$rc"
}
# rpf_relax ИНТЕРФЕЙС — выключить rp_filter на интерфейсе Канала.
# У интерфейса Канала нет IPv4-адреса, а через него идут чужие IPv4-источники (клиенты, ответы из
# интернета); ядро отбрасывает такие пакеты даже при rp_filter=2 ("Invalid cross-device link").
# Действующее значение = max(all, интерфейс), поэтому all опускается до 0, а остальным интерфейсам
# (и default — для будущих) выставляется не меньше прежнего all, чтобы их защита не ослабла.
rpf_protect() {  # опустить all до 0, сохранив действующий уровень на всех интерфейсах (кроме $1)
  local base=${RPF_DIR:-/proc/sys/net/ipv4/conf} all f v
  all=$(cat "$base/all/rp_filter" 2>/dev/null || echo 0)
  [ "$all" != 0 ] || return 0
  for f in "$base"/*/rp_filter; do
    case $f in "$base/all/rp_filter"|"$base/${1:-}/rp_filter") continue ;; esac
    v=$(cat "$f" 2>/dev/null || echo 0)
    if [ "$v" -lt "$all" ]; then echo "$all" > "$f" 2>/dev/null || true; fi
  done
  echo 0 > "$base/all/rp_filter"
}
rpf_relax() {
  local base=${RPF_DIR:-/proc/sys/net/ipv4/conf}
  rpf_protect "$1"
  echo 0 > "$base/$1/rp_filter"
}
LIB
  declare -f $SHARED_FUNCS
}

src_entry_hooks() {
  cat <<'HOOKS'
#!/bin/bash
# DoubleAWG: правила входного узла (VPS1).
#   Из PostUp/PostDown:  channel-up | channel-down | gate-up <имя> | gate-down <имя>
#   Вручную:             split-up <имя> | split-down <имя> | split-status [<имя>] | split-update
set -u
. "${DAWG_DIR:-/etc/amnezia/amneziawg}/dawg-lib.sh"
RU_LIST="$D/dawg-ru.txt"            # российские IPv4-подсети (обновляется: split-update, таймер)
RU_EXTRA="$D/dawg-ru-extra.txt"     # свои подсети НАПРЯМУЮ (CIDR по строке)
RU_EXCLUDE="$D/dawg-ru-exclude.txt" # подсети всегда В КАНАЛ, даже российские
RU_SOURCES=(
  "delegated https://ftp.ripe.net/pub/stats/ripencc/delegated-ripencc-latest"
  "ripestat https://stat.ripe.net/data/country-resource-list/data.json?resource=RU&v4_format=prefix"
  "plain https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone"
)

gate_load() {
  [ -f "$D/dawg-gates/$1.env" ] || die "нет входного интерфейса '$1'"
  . "$D/dawg-gates/$1.env"
  TBL=$(( RT_BASE + GATE_NUM )); FLAG="/run/dawg-split.$GATE_NAME"
}
gate_fw() {
  local op=$1 G=$GATE_NAME
  # порядок важен: -I вставляет в начало, DROP добавляется первым и оказывается ниже ACCEPT
  ipt "$op" iptables filter FORWARD -i "$G" -j DROP
  ipt "$op" iptables filter FORWARD -i "$G" -o "$INWAY_IF" -j ACCEPT
  ipt "$op" iptables filter FORWARD -i "$INWAY_IF" -o "$G" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  ipt "$op" iptables mangle FORWARD -o "$G" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  ipt "$op" iptables filter INPUT -p udp --dport "$GATE_PORT" -j ACCEPT
}
gate_rules_del() {
  while ip -4 rule del pref 31000 iif "$GATE_NAME" to "$GATE_NET" lookup main 2>/dev/null; do :; done
  while ip -4 rule del pref 31001 iif "$GATE_NAME" lookup "$TBL" 2>/dev/null; do :; done
}
gate_rules_add() {
  gate_rules_del
  ip -4 rule add pref 31000 iif "$GATE_NAME" to "$GATE_NET" lookup main
  ip -4 rule add pref 31001 iif "$GATE_NAME" lookup "$TBL"
}
gate_table() {
  ip -4 route replace blackhole default metric 4096 table "$TBL"   # kill-switch
  if link_up "$INWAY_IF"; then ip -4 route replace default dev "$INWAY_IF" metric 10 table "$TBL"; fi
}

# ── split: в таблице интерфейса для российских подсетей ставится "throw" — поиск уходит в main ──
split_rules() {
  local op=$1
  ipt "$op" iptables nat    POSTROUTING -s "$GATE_NET" -o "$WAN_IF" -j MASQUERADE
  ipt "$op" iptables filter FORWARD -i "$WAN_IF" -o "$GATE_NAME" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  ipt "$op" iptables filter FORWARD -i "$GATE_NAME" -o "$WAN_IF" -j ACCEPT
}
split_routes_del() {
  ip -4 route show table "$TBL" 2>/dev/null \
    | awk -v t="$TBL" '$1 == "throw" { print "route del throw " $2 " table " t }' \
    | ip -4 -force -batch - 2>/dev/null || true
}
split_off() { split_routes_del; split_rules del; rm -f "$FLAG"; }
split_on() {
  if [ ! -s "$RU_LIST" ]; then
    ru_fetch || { warn "списка RU нет — split на $GATE_NAME НЕ включен (весь трафик идет в Канал)"; return 0; }
  fi
  split_off
  sed -e 's/[[:space:]]//g' -e '/^$/d' -e "s|.*|route replace throw & table $TBL|" "$RU_LIST" \
    | ip -4 -force -batch - || warn "часть маршрутов split не добавилась"
  split_rules add
  touch "$FLAG"
  log "split на $GATE_NAME включен: напрямую $(ip -4 route show table "$TBL" | grep -c '^throw') подсетей"
}
ru_fetch() {
  local tmp src fmt url
  tmp=$(mktemp -d) || return 1
  for src in "${RU_SOURCES[@]}"; do
    fmt=${src%% *}; url=${src#* }
    curl -fsSL --retry 2 --max-time 120 "$url" -o "$tmp/raw" 2>/dev/null || { warn "не скачалось: $url"; continue; }
    if python3 - "$fmt" "$tmp/raw" "$RU_EXTRA" "$RU_EXCLUDE" > "$tmp/list" <<'PY'
import sys, json, ipaddress as ia
fmt, src, extra, excl = sys.argv[1:5]
def rng(a, b):
    return list(ia.summarize_address_range(ia.IPv4Address(a), ia.IPv4Address(b)))
def readlist(path):
    out = []
    try:
        for line in open(path, encoding="utf-8", errors="ignore"):
            line = line.split("#", 1)[0].strip()
            if line:
                out.append(ia.IPv4Network(line, strict=False))
    except FileNotFoundError:
        pass
    return out
nets = []
if fmt == "delegated":          # registry|CC|type|start|count|date|status
    for line in open(src, encoding="utf-8", errors="ignore"):
        p = line.strip().split("|")
        if len(p) >= 7 and p[1] == "RU" and p[2] == "ipv4" and p[6] in ("allocated", "assigned"):
            start = ia.IPv4Address(p[3])
            nets += rng(start, start + int(p[4]) - 1)
elif fmt == "ripestat":
    for r in json.load(open(src))["data"]["resources"]["ipv4"]:
        if "-" in r:
            a, b = r.split("-", 1); nets += rng(a.strip(), b.strip())
        else:
            nets.append(ia.IPv4Network(r, strict=False))
else:
    nets = readlist(src)
if len(nets) < 1000:
    sys.exit("слишком короткий список: %d" % len(nets))
nets = list(ia.collapse_addresses(nets + readlist(extra)))
for e in readlist(excl):
    res = []
    for n in nets:
        if n.subnet_of(e):
            continue
        if e.subnet_of(n):
            res += n.address_exclude(e)
        else:
            res.append(n)
    nets = res
for n in ia.collapse_addresses(nets):
    print(n)
PY
    then
      install -m 600 "$tmp/list" "$RU_LIST"
      log "список RU обновлен ($fmt): $(wc -l < "$RU_LIST") подсетей"
      rm -rf "$tmp"; return 0
    fi
    warn "не удалось разобрать $url"
  done
  rm -rf "$tmp"; return 1
}

cmd=${1:-}; arg=${2:-}
case $cmd in
  channel-up)
    rpf_relax "$INWAY_IF" || warn "не удалось выключить rp_filter на $INWAY_IF — ответы из Канала будут отбрасываться"
    ipt add iptables mangle FORWARD -o "$INWAY_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    for g in $(gates_all); do ( gate_load "$g"; ip -4 route replace default dev "$INWAY_IF" metric 10 table "$TBL" ); done ;;
  channel-down)
    ipt del iptables mangle FORWARD -o "$INWAY_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    for g in $(gates_all); do ( gate_load "$g"; ip -4 route del default dev "$INWAY_IF" metric 10 table "$TBL" 2>/dev/null || true ); done ;;
  gate-up)
    gate_load "$arg"; sysctl -qw net.ipv4.ip_forward=1
    split_off; gate_fw del; gate_fw add; gate_rules_add; gate_table ;;
  gate-down)
    gate_load "$arg"; split_off; gate_fw del; gate_rules_del
    ip -4 route flush table "$TBL" 2>/dev/null || true ;;
  split-up)   gate_load "$arg"; split_on ;;
  split-down) gate_load "$arg"; split_off; log "split на $GATE_NAME выключен" ;;
  split-update)
    ru_fetch || die "ни один источник списка RU не сработал"
    for g in $(gates_all); do ( gate_load "$g"; if [ -e "$FLAG" ]; then split_on; fi ); done ;;
  split-status)
    for g in ${arg:-$(gates_all)}; do
      ( gate_load "$g"
        if [ -e "$FLAG" ]; then echo "$g: split ВКЛЮЧЕН, напрямую $(ip -4 route show table "$TBL" | grep -c '^throw') подсетей"
        else echo "$g: split выключен (весь трафик в Канал)"; fi )
    done
    if [ -s "$RU_LIST" ]; then echo "список RU: $(wc -l < "$RU_LIST") подсетей, обновлен $(date -r "$RU_LIST" '+%F %T')"; fi ;;
  *) sed -n '2,5p' "$0" >&2; exit 1 ;;
esac
exit 0
HOOKS
}

src_exit_hooks() {
  cat <<'HOOKS'
#!/bin/bash
# DoubleAWG: правила выходного узла (VPS2). Вызывается из PostUp/PostDown интерфейса Канала:
#   channel-up | channel-down
#
# Подсети клиентов VPS2 не знает: соединения, пришедшие из Канала, помечаются (CONNMARK),
# по метке делается NAT, а ответы по метке возвращаются в Канал через свою таблицу маршрутизации.
# Поэтому на VPS1 можно добавлять входные интерфейсы с любыми подсетями, не меняя VPS2.
set -u
. "${DAWG_DIR:-/etc/amnezia/amneziawg}/dawg-lib.sh"
MARK=0x444e0000/0xffff0000   # метка соединений из Канала
TBL=7100                     # таблица: default dev $OUTWAY_IF
rules() {
  local op=$1
  ipt "$op" iptables mangle PREROUTING -i "$OUTWAY_IF" -j CONNMARK --set-xmark "$MARK"
  ipt "$op" iptables mangle PREROUTING -i "$WAN_IF" -m connmark --mark "$MARK" -j MARK --set-xmark "$MARK"
  # собственные пакеты VPS2 по этим соединениям (ICMP Time Exceeded для traceroute, ответы на ping
  # публичного IP через Канал) — тоже в Канал, иначе они уходят в eth0 и теряются
  ipt "$op" iptables mangle OUTPUT -m connmark --mark "$MARK" -j MARK --set-xmark "$MARK"
  ipt "$op" iptables nat    POSTROUTING -o "$WAN_IF" -m connmark --mark "$MARK" -j MASQUERADE
  ipt "$op" iptables filter FORWARD -i "$OUTWAY_IF" -o "$WAN_IF" -j ACCEPT
  ipt "$op" iptables filter FORWARD -i "$WAN_IF" -o "$OUTWAY_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  ipt "$op" iptables mangle FORWARD -o "$OUTWAY_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  ipt "$op" "$IPT_IN" filter INPUT -p udp --dport "$OUTWAY_PORT" -j ACCEPT
}
route_del() {
  while ip -4 rule del pref 31000 fwmark "$MARK" lookup "$TBL" 2>/dev/null; do :; done
  ip -4 route flush table "$TBL" 2>/dev/null || true
}
case ${1:-} in
  channel-up)
    sysctl -qw net.ipv4.ip_forward=1
    rpf_relax "$OUTWAY_IF" || warn "не удалось выключить rp_filter на $OUTWAY_IF — трафик клиентов будет отбрасываться"
    rules del; rules add
    route_del
    ip -4 route replace default dev "$OUTWAY_IF" table "$TBL"
    ip -4 rule add pref 31000 fwmark "$MARK" lookup "$TBL" ;;
  channel-down) rules del; route_del ;;
  *) echo "usage: $0 channel-up|channel-down" >&2; exit 1 ;;
esac
exit 0
HOOKS
}

src_gate_add() {
  cat <<'GADD'
#!/bin/bash
# DoubleAWG: добавить входной интерфейс клиентов (VPS1).
#   dawg-gate-add.sh                 — интерактивно
#   dawg-gate-add.sh --awg 2 --mode listen --port 40002 --split yes --yes
# Параметры: --awg 1|1.5|2|3|3.1  --mode listen|connect  --net A.B.C.D/N  --port N  --num N
#            --dns "..."  --split yes|no  --i1 yes|no  --yes (без вопросов, значения по умолчанию)
#   listen  — клиенты подключаются к серверу (у клиента Endpoint сервера)
#   connect — сервер подключается к клиентам (у клиента ListenPort, у сервера Endpoint клиента)
#   --net   — подсеть клиентов (/8../30), не пересекающаяся с другими; адрес сервера — первый в подсети.
#   --mtu   — MTU интерфейса и его клиентов (по умолчанию 1280 — надежно и для мобильных сетей).
# Имя интерфейса: <префикс><номер>.
# Приватный ключ можно передать в переменной GATE_PRIV, иначе генерируется (awg genkey).
set -Eeuo pipefail
. "${DAWG_DIR:-/etc/amnezia/amneziawg}/dawg-lib.sh"
need_root; need_role entry

AWGV=""; MODE=""; PORT=""; NUM=""; DNS=""; SPLIT=""; USE_I1=""; NET=""; MTU=""; YES=no
while [ $# -gt 0 ]; do
  case $1 in
    --awg)   AWGV=${2-};   shift 2 ;;
    --net)   NET=${2-};    shift 2 ;;
    --mtu)   MTU=${2-};    shift 2 ;;
    --mode)  MODE=${2-};   shift 2 ;;
    --port)  PORT=${2-};   shift 2 ;;
    --num)   NUM=${2-};    shift 2 ;;
    --dns)   DNS=${2-};    shift 2 ;;
    --split) SPLIT=${2-};  shift 2 ;;
    --i1)    USE_I1=${2-}; shift 2 ;;
    --yes|-y) YES=yes; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "неизвестный параметр: $1 (см. --help)" ;;
  esac
done

used_nums=" "; used_ports=" "; used_nets=""
for g in $(gates_all); do
  used_nums+="$(. "$D/dawg-gates/$g.env"; echo "$GATE_NUM") "
  used_ports+="$(. "$D/dawg-gates/$g.env"; echo "$GATE_PORT") "
  used_nets+="$(. "$D/dawg-gates/$g.env"; echo "$GATE_NET") "
done
# подсети, уже известные системе (интерфейсы, маршруты), — чтобы не пересечься
sys_nets=$(ip -4 route show table main 2>/dev/null | awk '$1 != "default" { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/) { n = $i; if (n !~ /\//) n = n "/32"; print n; break } }' | tr '\n' ' ' || true)
if [ -z "$NUM" ]; then
  for i in $(seq 1 254); do [[ $used_nums == *" $i "* ]] || { NUM=$i; break; }; done
fi
{ [[ $NUM =~ ^[0-9]+$ ]] && [ "$NUM" -ge 1 ] && [ "$NUM" -le 254 ]; } || die "номер интерфейса: 1..254"
[[ $used_nums != *" $NUM "* ]] || die "номер $NUM уже занят"
NAME="${GATE_PREFIX}${NUM}"
valid_ifname "$NAME" || die "недопустимое имя интерфейса: $NAME"
[ "$NAME" != "$INWAY_IF" ] || die "имя $NAME совпадает с интерфейсом Канала"
! link_exists "$NAME" || die "интерфейс $NAME уже существует"
[ ! -e "$D/$NAME.conf" ] || die "уже есть $D/$NAME.conf"

rand_port() {
  local p
  while :; do
    p=$(rnd 20000 60999)
    port_busy "$p" || [[ $used_ports == *" $p "* ]] || { echo "$p"; return 0; }
  done
}
opt() {  # opt VAR "вопрос" ПО_УМОЛЧАНИЮ — спросить, если значение не задано параметром
  local __v=$1
  [ -n "${!__v}" ] && return 0
  if [ "$YES" = yes ]; then printf -v "$__v" '%s' "$3"; else ask "$__v" "$2" "$3"; fi
}
default_net() {  # первая свободная 10.8.X.0/24, начиная с номера интерфейса
  local x n
  for (( x = NUM; x < NUM + 254; x++ )); do
    n="10.8.$(( (x - 1) % 254 + 1 )).0/24"
    net_conflict "$n" "$used_nets $sys_nets" >/dev/null || { echo "$n"; return 0; }
  done
  echo "10.8.$NUM.0/24"
}
[ "$YES" = yes ] || log "Новый входной интерфейс: $NAME"
opt NET    "  Подсеть клиентов (A.B.C.D/N)" "$(default_net)"
cidr_parse "$NET" 8 30 || die "подсеть '$NET': ожидается A.B.C.D/N, N от 8 до 30"
if [ "$C_STR" != "$NET" ]; then warn "подсеть $NET приведена к $C_STR"; NET=$C_STR; fi
GIP=$(int2ip $(( C_NET + 1 ))); NLEN=$C_LEN
if c=$(net_conflict "$NET" "$used_nets"); then die "подсеть $NET пересекается с подсетью другого входного интерфейса ($c)"; fi
if c=$(net_conflict "$NET" "$sys_nets"); then die "подсеть $NET пересекается с маршрутом на сервере ($c)"; fi
opt AWGV   "  Версия AmneziaWG (1, 1.5, 2, 3, 3.1)" "$CHANNEL_AWG"
awg_ver_ok "$AWGV" || die "версия AWG: 1, 1.5, 2, 3 или 3.1"
opt MODE   "  Режим: listen — клиенты подключаются к серверу; connect — сервер подключается к клиентам" listen
case $MODE in listen|connect) ;; *) die "режим: listen или connect" ;; esac
opt PORT   "  UDP-порт интерфейса" "$(rand_port)"
{ [[ $PORT =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; } || die "некорректный порт: $PORT"
! port_busy "$PORT" || die "порт $PORT/udp уже занят"
[[ $used_ports != *" $PORT "* ]] || die "порт $PORT уже у другого входного интерфейса"
opt DNS    "  DNS для клиентов" "$DEFAULT_DNS"
opt SPLIT  "  Split: российские IP напрямую, остальное в Канал (yes/no)" yes
case ${SPLIT,,} in yes|y|д|да) SPLIT=yes ;; no|n|н|нет) SPLIT=no ;; *) die "split: yes или no" ;; esac
opt USE_I1 "  I1 — имитация QUIC Initial перед рукопожатием (yes/no)" "$DEFAULT_I1"
case ${USE_I1,,} in yes|y|д|да) USE_I1=yes ;; *) USE_I1=no ;; esac

gen_obf "$AWGV" "$USE_I1"
MTU=${MTU:-1280}
{ [[ $MTU =~ ^[0-9]+$ ]] && [ "$MTU" -ge 1280 ]; } || die "MTU: число не меньше 1280"
if [ "$MTU" -gt "$INWAY_MTU" ]; then warn "MTU $MTU больше MTU Канала ($INWAY_MTU) — уменьшено до $INWAY_MTU"; MTU=$INWAY_MTU; fi
PRIV=${GATE_PRIV:-$(awg genkey)}
[[ $PRIV =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "некорректный приватный ключ"
if [ "$MODE" = listen ]; then MT="listen: клиенты подключаются к ${PUB4}:${PORT}"; else MT="connect: сервер подключается к клиентам"; fi
if [ "$SPLIT" = yes ]; then c=""; else c="#"; fi

umask 077
install -d -m 700 "$D/dawg-gates" "$D/clients"
{
  echo "# DoubleAWG / AmneziaWG $AWGV — входной интерфейс $NAME ($MT)"
  echo "[Interface]"
  echo "PrivateKey = $PRIV"
  echo "Address = $GIP/$NLEN"
  echo "ListenPort = $PORT"
  echo "MTU = $MTU"
  obf_lines
  echo "PostUp = $D/dawg-entry.sh gate-up $NAME"
  echo "PostDown = $D/dawg-entry.sh gate-down $NAME"
  echo "#"
  echo "# ── Split ───────────────────────────────────────────────────────────────────"
  echo "# Трафик к российским IP — напрямую с этого VPS, остальное — в Канал."
  echo "# Включить/выключить: раскомментировать/закомментировать ДВЕ строки ниже, затем"
  echo "#   systemctl restart awg-quick@$NAME"
  echo "# Без перезапуска: $D/dawg-entry.sh split-up|split-down|split-status $NAME"
  echo "${c}PostUp = $D/dawg-entry.sh split-up $NAME"
  echo "${c}PostDown = $D/dawg-entry.sh split-down $NAME"
  echo "#"
  echo "# Клиенты: $D/dawg-client-add.sh $NAME <имя>   |   $D/dawg-client-del.sh $NAME <имя>"
} > "$D/$NAME.conf"
printf '%s=%q\n' GATE_NAME "$NAME" GATE_NUM "$NUM" GATE_AWG "$AWGV" GATE_MODE "$MODE" GATE_PORT "$PORT" \
  GATE_NET "$NET" GATE_IP "$GIP" GATE_MTU "$MTU" GATE_DNS "$DNS" > "$D/dawg-gates/$NAME.env"

if ! awg_check_conf "$D/$NAME.conf"; then
  mv -f "$D/$NAME.conf" "$D/$NAME.conf.rejected"; rm -f "$D/dawg-gates/$NAME.env"
  die "AmneziaWG на сервере не принял конфиг версии $AWGV (сохранен как $D/$NAME.conf.rejected)"
fi
ufw_dawg_add "DoubleAWG $NAME " \
  "allow $PORT/udp comment 'DoubleAWG $NAME port'" \
  "route allow in on $NAME out on $INWAY_IF comment 'DoubleAWG $NAME channel'" \
  "route allow in on $NAME out on $WAN_IF comment 'DoubleAWG $NAME split'"
systemctl enable -q "awg-quick@$NAME"
if ! systemctl restart "awg-quick@$NAME"; then
  journalctl -u "awg-quick@$NAME" -n 30 --no-pager || true
  die "не удалось поднять $NAME"
fi
log "Входной интерфейс $NAME: AWG $AWGV, $MODE, порт $PORT/udp, сеть $NET, split=$SPLIT"
log "Добавить клиента: $D/dawg-client-add.sh $NAME <имя>"
GADD
}

src_gate_del() {
  cat <<'GDEL'
#!/bin/bash
# DoubleAWG: удалить входной интерфейс клиентов вместе с его клиентами (VPS1).
#   dawg-gate-del.sh <интерфейс> [--yes]
set -Eeuo pipefail
. "${DAWG_DIR:-/etc/amnezia/amneziawg}/dawg-lib.sh"
need_root; need_role entry
G=${1-}; YES=${2-}
if [ -z "$G" ]; then sed -n '2,3p' "$0"; echo "Входные интерфейсы: $(gates_all | tr '\n' ' ')"; exit 1; fi
[ -f "$D/dawg-gates/$G.env" ] || die "нет входного интерфейса $G (есть: $(gates_all | tr '\n' ' '))"
n=$(grep -c '^# client: ' "$D/$G.conf" 2>/dev/null || true)
if [ "$YES" != --yes ]; then confirm "Удалить входной интерфейс $G и его клиентов (${n:-0})?" N || exit 0; fi
systemctl disable --now "awg-quick@$G" 2>/dev/null || true
if link_exists "$G"; then awg-quick down "$G" 2>/dev/null || ip link del "$G" 2>/dev/null || true; fi
"$D/dawg-entry.sh" gate-down "$G" 2>/dev/null || true   # на случай, если PostDown не отработал
ufw_dawg_del "DoubleAWG $G "
rm -f "$D/$G.conf" "$D/$G.conf".bak-* "$D/$G.conf.rejected" "/run/dawg-split.$G"
rm -rf "${D:?}/clients/$G"
rm -f "$D/dawg-gates/$G.env"
systemctl reset-failed "awg-quick@$G" 2>/dev/null || true
log "Входной интерфейс $G удален"
GDEL
}

src_client_add() {
  cat <<'CADD'
#!/bin/bash
# DoubleAWG: добавить клиента входного интерфейса (VPS1).
#   dawg-client-add.sh <интерфейс> <имя клиента> [--endpoint host:port] [--dns "..."] [--quiet]
#   --endpoint — для интерфейса в режиме connect: адрес и порт, на которых слушает клиент.
# Конфиг клиента сохраняется в /etc/amnezia/amneziawg/clients/<интерфейс>/<имя>.conf и выводится на экран.
# Ключи можно передать в CLIENT_PRIV / CLIENT_PSK, иначе генерируются (awg).
set -Eeuo pipefail
. "${DAWG_DIR:-/etc/amnezia/amneziawg}/dawg-lib.sh"
need_root; need_role entry
if [ $# -lt 2 ]; then sed -n '2,6p' "$0"; echo "Входные интерфейсы: $(gates_all | tr '\n' ' ')"; exit 1; fi
G=$1; CN=$2; shift 2
EP=""; DNS=""; QUIET=no
while [ $# -gt 0 ]; do
  case $1 in
    --endpoint) EP=${2-}; shift 2 ;;
    --dns) DNS=${2-}; shift 2 ;;
    --quiet) QUIET=yes; shift ;;
    *) die "неизвестный параметр: $1" ;;
  esac
done
[ -f "$D/dawg-gates/$G.env" ] || die "нет входного интерфейса $G (есть: $(gates_all | tr '\n' ' '))"
. "$D/dawg-gates/$G.env"
CONF="$D/$G.conf"
[[ $CN =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die "имя клиента: латиница, цифры, _ . - (до 32 символов)"
! grep -qxF "# client: $CN" "$CONF" || die "клиент $CN уже есть на $G"
CLPORT=""
if [ "$GATE_MODE" = connect ]; then
  [ -n "$EP" ] || ask EP "Адрес клиента host:port (сервер будет подключаться к нему)" ""
  [[ $EP =~ ^.+:[0-9]{1,5}$ ]] || die "для режима connect нужен --endpoint host:port"
  CLPORT=${EP##*:}
fi
[ -n "$DNS" ] || DNS=$GATE_DNS

cidr_parse "$GATE_NET" || die "в $D/dawg-gates/$G.env некорректная подсеть: $GATE_NET"
used=" $(sed -n 's/^AllowedIPs[[:space:]]*=[[:space:]]*\([0-9.]*\)\/32.*/\1/p' "$CONF" | tr '\n' ' ') $GATE_IP "
CIP=""
for (( n = C_NET + 1; n < C_LAST; n++ )); do
  a=$(int2ip "$n")
  [[ $used == *" $a "* ]] || { CIP=$a; break; }
done
[ -n "$CIP" ] || die "в подсети $GATE_NET нет свободных адресов"

PRIV=${CLIENT_PRIV:-$(awg genkey)}
PUB=$(printf '%s' "$PRIV" | awg pubkey)
PSK=${CLIENT_PSK:-$(awg genpsk)}
GPUB=$(sed -n 's/^PrivateKey[[:space:]]*=[[:space:]]*//p' "$CONF" | head -n1 | awg pubkey)
OBF=$(grep -E "^($OBF_KEYS)[[:space:]]*=" "$CONF" || true)

umask 077
{
  echo
  echo "[Peer]"
  echo "# client: $CN"
  echo "PublicKey = $PUB"
  echo "PresharedKey = $PSK"
  echo "AllowedIPs = $CIP/32"
  if [ "$GATE_MODE" = connect ]; then
    echo "Endpoint = $EP"
    echo "PersistentKeepalive = 25"
  fi
} >> "$CONF"

install -d -m 700 "$D/clients/$G"
OUTF="$D/clients/$G/$CN.conf"
{
  if [ "$GATE_MODE" = listen ]; then
    echo "# DoubleAWG / AmneziaWG $GATE_AWG — клиент '$CN' интерфейса $G (подключается к ${PUB4}:${GATE_PORT})"
  else
    echo "# DoubleAWG / AmneziaWG $GATE_AWG — клиент '$CN' интерфейса $G (сервер подключается к клиенту на $EP)"
  fi
  echo "[Interface]"
  echo "PrivateKey = $PRIV"
  echo "Address = $CIP/32"
  echo "DNS = $DNS"
  echo "MTU = $GATE_MTU"
  if [ -n "$CLPORT" ]; then echo "ListenPort = $CLPORT"; fi
  echo "$OBF"
  echo
  echo "[Peer]"
  echo "PublicKey = $GPUB"
  echo "PresharedKey = $PSK"
  if [ "$GATE_MODE" = listen ]; then echo "Endpoint = ${PUB4}:${GATE_PORT}"; fi
  echo "AllowedIPs = 0.0.0.0/0, ::/0"
  if [ "$GATE_MODE" = listen ]; then echo "PersistentKeepalive = 25"; fi
} > "$OUTF"

if link_exists "$G"; then
  awg syncconf "$G" <(awg-quick strip "$G") || warn "не удалось применить на лету — выполните: systemctl restart awg-quick@$G"
fi
log "Клиент $CN добавлен на $G (адрес $CIP), конфиг: $OUTF"
if [ "$QUIET" != yes ]; then
  cat "$OUTF"
  if command -v qrencode >/dev/null 2>&1 && [ -t 1 ]; then qrencode -t ansiutf8 < "$OUTF" || true; fi
fi
CADD
}

src_client_del() {
  cat <<'CDEL'
#!/bin/bash
# DoubleAWG: удалить клиента входного интерфейса (VPS1).
#   dawg-client-del.sh <интерфейс> <имя клиента>
set -Eeuo pipefail
. "${DAWG_DIR:-/etc/amnezia/amneziawg}/dawg-lib.sh"
need_root; need_role entry
if [ $# -lt 2 ]; then sed -n '2,3p' "$0"; exit 1; fi
G=$1; CN=$2
CONF="$D/$G.conf"
[ -f "$D/dawg-gates/$G.env" ] || die "нет входного интерфейса $G"
grep -qxF "# client: $CN" "$CONF" || die "на $G нет клиента $CN (есть: $(sed -n 's/^# client: //p' "$CONF" | tr '\n' ' '))"
umask 077
awk -v n="# client: $CN" '
  function flush() { if (!drop) printf "%s", buf; buf = ""; drop = 0 }
  /^\[(Peer|Interface)\]/ { flush() }
  { buf = buf $0 "\n"; if ($0 == n) drop = 1 }
  END { flush() }' "$CONF" > "$CONF.tmp"
mv -f "$CONF.tmp" "$CONF"
if link_exists "$G"; then awg syncconf "$G" <(awg-quick strip "$G") || warn "выполните: systemctl restart awg-quick@$G"; fi
rm -f "$D/clients/$G/$CN.conf"
log "Клиент $CN удален с $G"
CDEL
}

src_channel_del() {
  cat <<'CHDEL'
#!/bin/bash
# DoubleAWG: удалить Канал с этого узла.
#   VPS1: интерфейс Канала, все входные интерфейсы и клиентов, таймер списка RU.
#   VPS2: интерфейс Канала.
# Правила iptables/ip rule снимаются, правила ufw с пометкой DoubleAWG удаляются.
#   dawg-channel-del.sh [--yes] [--purge]   (--purge — удалить и пакеты AmneziaWG, модуль, PPA)
set -Eeuo pipefail
. "${DAWG_DIR:-/etc/amnezia/amneziawg}/dawg-lib.sh"
need_root
YES=no; PURGE=no
for a in "$@"; do
  case $a in --yes|-y) YES=yes ;; --purge) PURGE=yes ;; -h|--help) sed -n '2,7p' "$0"; exit 0 ;; *) die "неизвестный параметр: $a" ;; esac
done
[ -n "${DAWG_ROLE:-}" ] || die "не найден $D/dawg.env — DoubleAWG на этом узле не установлен"
if [ "$DAWG_ROLE" = entry ]; then
  what="Канал ($INWAY_IF) и входные интерфейсы: $(gates_all | tr '\n' ' ')"
else
  what="Канал ($OUTWAY_IF)"
fi
if [ "$YES" != yes ]; then confirm "Удалить с этого узла: $what?" N || exit 0; fi

if [ "$DAWG_ROLE" = entry ]; then
  for g in $(gates_all); do "$D/dawg-gate-del.sh" "$g" --yes || warn "не удалось удалить $g"; done
  systemctl disable --now "awg-quick@$INWAY_IF" 2>/dev/null || true
  if link_exists "$INWAY_IF"; then awg-quick down "$INWAY_IF" 2>/dev/null || ip link del "$INWAY_IF" 2>/dev/null || true; fi
  "$D/dawg-entry.sh" channel-down 2>/dev/null || true
  systemctl disable --now dawg-ru-update.timer 2>/dev/null || true
  rm -f /etc/systemd/system/dawg-ru-update.service /etc/systemd/system/dawg-ru-update.timer
  systemctl daemon-reload
  rm -f "$D/$INWAY_IF.conf" "$D/$INWAY_IF.conf".bak-* "$D"/dawg-ru*.txt /run/dawg-split.*
  rm -rf "${D:?}/dawg-gates" "${D:?}/clients"
  systemctl reset-failed "awg-quick@$INWAY_IF" 2>/dev/null || true
else
  systemctl disable --now "awg-quick@$OUTWAY_IF" 2>/dev/null || true
  if link_exists "$OUTWAY_IF"; then awg-quick down "$OUTWAY_IF" 2>/dev/null || ip link del "$OUTWAY_IF" 2>/dev/null || true; fi
  "$D/dawg-exit.sh" channel-down 2>/dev/null || true
  rm -f "$D/$OUTWAY_IF.conf" "$D/$OUTWAY_IF.conf".bak-*
  systemctl reset-failed "awg-quick@$OUTWAY_IF" 2>/dev/null || true
fi
ufw_dawg_del "DoubleAWG"
rm -f /etc/sysctl.d/99-doubleawg.conf
sysctl -qw "net.ipv4.conf.all.rp_filter=$(cat /proc/sys/net/ipv4/conf/default/rp_filter 2>/dev/null || echo 2)" || true
rm -f "$D"/dawg-*.sh "$D"/dawg-*.sh.bak-* "$D/dawg.env" "$D/dawg.env".bak-*
if [ "$PURGE" = yes ]; then
  log "Удаление пакетов AmneziaWG"
  modprobe -r amneziawg 2>/dev/null || warn "модуль занят другими интерфейсами — выгрузится после перезагрузки"
  apt-get -y -q purge amneziawg amneziawg-tools || true
  add-apt-repository -y --remove ppa:amnezia/ppa || true
fi
log "DoubleAWG удален с узла. net.ipv4.ip_forward остается включенным до перезагрузки."
CHDEL
}

# ═════════════════════════ установочные части для узлов ═════════════════════════
emit_head() {
  cat <<'HEAD'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
D=/etc/amnezia/amneziawg
H=$(hostname)
log()  { printf '\033[1;36m[%s]\033[0m %s\n' "$H" "$*"; }
warn() { printf '\033[1;33m[%s] !\033[0m %s\n' "$H" "$*"; }
die()  { printf '\033[1;31m[%s] ОШИБКА:\033[0m %s\n' "$H" "$*" >&2; exit 1; }
need_reboot() { warn "$*"; warn "ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА"; exit 10; }   # код 10: локальный скрипт перезагрузит VPS
start_iface() {
  log "Запуск awg-quick@$1"
  systemctl daemon-reload
  systemctl enable -q "awg-quick@$1"
  if ! systemctl restart "awg-quick@$1"; then journalctl -u "awg-quick@$1" -n 40 --no-pager || true; die "не удалось поднять $1"; fi
}
APT="apt-get -y -q -o DPkg::Lock::Timeout=600"
. /etc/os-release
[ "${ID:-}" = ubuntu ] || die "ожидается Ubuntu, обнаружено: ${PRETTY_NAME:-?}"
HEAD
}

emit_cleanup() {
  cat <<'CLEAN'
# ── предыдущие установки ──
if [ -f "$D/dawg.env" ] && [ -x "$D/dawg-channel-del.sh" ]; then
  log "Удаление предыдущей установки DoubleAWG"
  "$D/dawg-channel-del.sh" --yes || warn "предыдущая установка удалена не полностью"
fi
for i in $IFACES; do
  if ip link show "$i" >/dev/null 2>&1; then
    log "Останавливаю существующий интерфейс $i"
    systemctl disable --now "awg-quick@$i" 2>/dev/null || true
    if ip link show "$i" >/dev/null 2>&1; then awg-quick down "$i" 2>/dev/null || ip link del "$i" 2>/dev/null || true; fi
  fi
done
CLEAN
}

emit_install() {
  cat <<'INSTALL'
# ── установка AmneziaWG ──
log "Обновление списка пакетов"
$APT update
KREL=$(uname -r)
FLAVOUR=${KREL#*-*-}
PKGS="software-properties-common python3 python3-launchpadlib gnupg2 iptables curl dkms"
if apt-cache show "linux-headers-$FLAVOUR" >/dev/null 2>&1; then PKGS="$PKGS linux-headers-$FLAVOUR"; fi
KERNEL_SWITCH=0
if apt-cache show "linux-headers-$KREL" >/dev/null 2>&1; then
  PKGS="$PKGS linux-headers-$KREL"
else
  apt-cache show "linux-$FLAVOUR" >/dev/null 2>&1 \
    || die "для ядра $KREL нет linux-headers и мета-пакета linux-$FLAVOUR — ядро не из репозитория Ubuntu"
  warn "для работающего ядра $KREL нет linux-headers — ставлю актуальное ядро linux-$FLAVOUR"
  PKGS="$PKGS linux-$FLAVOUR"
  KERNEL_SWITCH=1
fi
log "Установка зависимостей"
# shellcheck disable=SC2086
$APT install $PKGS
if ! grep -rqs 'amnezia/ppa' /etc/apt/sources.list.d/; then
  log "Подключение PPA amnezia/ppa"
  add-apt-repository -y ppa:amnezia/ppa
fi
$APT update
log "Установка/обновление AmneziaWG (DKMS kernel module + tools)"
$APT install amneziawg amneziawg-tools
NEWEST=$(ls -1 /lib/modules | sort -V | tail -n1)
if [ "$KERNEL_SWITCH" = 1 ] || ! modinfo amneziawg >/dev/null 2>&1; then
  if [ "$NEWEST" != "$KREL" ] && modinfo -k "$NEWEST" amneziawg >/dev/null 2>&1; then
    need_reboot "модуль собран для ядра $NEWEST, а работает $KREL"
  fi
  die "модуль amneziawg не собран (см. 'dkms status' и /var/lib/dkms/amneziawg/*/build/make.log)"
fi
avail=$(modinfo -F version amneziawg 2>/dev/null || true)
loaded=$(cat /sys/module/amneziawg/version 2>/dev/null || true)
if [ -n "$loaded" ] && [ "$loaded" != "$avail" ]; then
  if [ -z "$(awg show interfaces 2>/dev/null)" ] && modprobe -r amneziawg 2>/dev/null; then
    log "Модуль обновлен в памяти: $loaded -> $avail"
  else
    need_reboot "в памяти старый модуль $loaded (установлен $avail), выгрузить его без перезагрузки нельзя"
  fi
fi
if ! modprobe amneziawg 2>/tmp/dawg-modprobe.err; then
  if grep -qiE 'key was rejected|required key not available|lockdown' /tmp/dawg-modprobe.err \
     || dmesg 2>/dev/null | tail -n 50 | grep -qiE 'lockdown|module verification failed'; then
    die "ядро отклонило неподписанный модуль (Secure Boot). Отключите Secure Boot в панели VPS или зарегистрируйте ключ DKMS через mokutil"
  fi
  die "не удалось загрузить модуль amneziawg: $(cat /tmp/dawg-modprobe.err)"
fi
if [ "$NEWEST" != "$KREL" ] && ! modinfo -k "$NEWEST" amneziawg >/dev/null 2>&1; then
  warn "установлено ядро $NEWEST, но модуль под него не собран — после перезагрузки VPN не поднимется (см. 'dkms status')"
fi
command -v awg-quick >/dev/null || die "не найден awg-quick (amneziawg-tools)"
log "AmneziaWG: модуль $(modinfo -F version amneziawg), $(awg --version 2>/dev/null | head -n1)"
INSTALL
}

emit_file() {  # emit_file УДАЛЕННЫЙ_ПУТЬ РЕЖИМ ЛОКАЛЬНЫЙ_ФАЙЛ
  local path=$1 mode=$2 src=$3
  printf 'install -d -m 700 %q\n' "$(dirname "$path")"
  printf 'if [ -f %q ]; then cp -a %q %q.bak-$(date +%%Y%%m%%d-%%H%%M%%S); fi\n' "$path" "$path" "$path"
  printf "cat > %q <<'__DAWG_EOF__'\n" "$path"
  cat "$src"
  printf '__DAWG_EOF__\nchmod %s %q\n' "$mode" "$path"
}

emit_after_files() {  # общее после записи файлов: lib, проверка конфига Канала, sysctl
  cat <<'AFTER'
. "$D/dawg-lib.sh"
CH_IF=${INWAY_IF:-${OUTWAY_IF:-}}
log "Проверка конфига Канала $CH_IF (AWG $CHANNEL_AWG)"
awg_check_conf "$D/$CH_IF.conf" || die "AmneziaWG на сервере не принял конфиг Канала версии $CHANNEL_AWG"
# rp_filter: all=0 (на интерфейсах Канала нет IPv4-адреса), остальные интерфейсы сохраняют свой уровень
rpf_protect
printf '%s\n' "# DoubleAWG: форвардинг; rp_filter выключается только на интерфейсах Канала (см. dawg-lib.sh rpf_relax)," \
  "# поэтому общий all = 0, а уровень проверки задается на каждом интерфейсе (default — для новых)" \
  "net.ipv4.ip_forward = 1" "net.ipv4.conf.all.rp_filter = 0" > /etc/sysctl.d/99-doubleawg.conf
sysctl -q -p /etc/sysctl.d/99-doubleawg.conf
AFTER
}

# ═════════════════════════ генерация локальных файлов ═════════════════════════
gen_all() {
  OUTWAY_PRIV=$(wg genkey); OUTWAY_PUB=$(pubkey "$OUTWAY_PRIV")
  INWAY_PRIV=$(wg genkey);  INWAY_PUB=$(pubkey "$INWAY_PRIV")
  PSK_CH=$(wg genpsk)
  local k i
  for k in OUTWAY_PRIV OUTWAY_PUB INWAY_PRIV INWAY_PUB PSK_CH; do is_key "${!k}" || die "wg сгенерировал некорректный ключ ($k)"; done
  for (( i = 1; i <= NG; i++ )); do
    G_PRIV[i]=$(wg genkey); G_PUB[i]=$(pubkey "${G_PRIV[i]}")
    C_PRIV[i]=$(wg genkey); C_PUB[i]=$(pubkey "${C_PRIV[i]}"); C_PSK[i]=$(wg genpsk)
    for k in "${G_PRIV[i]}" "${G_PUB[i]}" "${C_PRIV[i]}" "${C_PUB[i]}" "${C_PSK[i]}"; do is_key "$k" || die "wg сгенерировал некорректный ключ"; done
  done

  gen_obf "$CH_AWG" "$USE_I1"
  local b; b=$(hexbytes 5)
  ULA_NET="fd${b:0:2}:${b:2:4}:${b:6:4}:1"
  OUTWAY_IP6="${ULA_NET}::1"; INWAY_IP6="${ULA_NET}::2"
  local m1 m2 s4; s4=$(obf_s4)
  if [[ $TRANSPORT == 6 ]]; then
    CH_ENDPOINT="[${N_IP6[exit]}]:${OUTWAY_PORT}"
    m1=${N_MTU6[entry]}; m2=${N_MTU6[exit]}; OVERHEAD=80
  else
    CH_ENDPOINT="${N_PUB4[exit]}:${OUTWAY_PORT}"
    m1=${N_MTU4[entry]}; m2=${N_MTU4[exit]}; OVERHEAD=60
  fi
  WAN_MTU=$(( m1 < m2 ? m1 : m2 ))
  CH_MTU=$(( (WAN_MTU - OVERHEAD - s4) / 8 * 8 ))
  (( CH_MTU >= 1280 )) || warn "MTU Канала получился $CH_MTU (< 1280) — проверьте MTU внешних интерфейсов"
}

write_local_files() {
  local de="$OUT/servers/entry" dx="$OUT/servers/exit"
  mkdir -p "$de" "$dx"

  # ── VPS2 ──
  {
    echo "# DoubleAWG / AmneziaWG $CH_AWG — выход из Канала (VPS2 ${TARGET[exit]})"
    echo "[Interface]"
    echo "PrivateKey = $OUTWAY_PRIV"
    echo "Address = ${OUTWAY_IP6}/64"
    echo "ListenPort = $OUTWAY_PORT"
    echo "MTU = $CH_MTU"
    echo "Table = off"
    obf_lines
    echo "PostUp = $AWG_DIR/dawg-exit.sh channel-up"
    echo "PostDown = $AWG_DIR/dawg-exit.sh channel-down"
    echo
    echo "[Peer]"
    echo "# $INWAY_IF @ VPS1 (${TARGET[entry]})"
    echo "PublicKey = $INWAY_PUB"
    echo "PresharedKey = $PSK_CH"
    echo "AllowedIPs = ${INWAY_IP6}/128, 0.0.0.0/0"
  } > "$dx/$OUTWAY_IF.conf"
  {
    echo "# DoubleAWG: параметры выходного узла (deploy-doubleawg.sh v$SCRIPT_VERSION, $(date '+%F %T'))"
    printf '%s=%q\n' DAWG_ROLE exit OUTWAY_IF "$OUTWAY_IF" WAN_IF "${N_IF4[exit]}" \
      OUTWAY_PORT "$OUTWAY_PORT" IPT_IN "$([[ $TRANSPORT == 6 ]] && echo ip6tables || echo iptables)" CHANNEL_AWG "$CH_AWG"
  } > "$dx/dawg.env"
  src_lib         > "$dx/dawg-lib.sh"
  src_exit_hooks  > "$dx/dawg-exit.sh"
  src_channel_del > "$dx/dawg-channel-del.sh"

  # ── VPS1 ──
  {
    echo "# DoubleAWG / AmneziaWG $CH_AWG — вход в Канал (VPS1 ${TARGET[entry]})"
    echo "[Interface]"
    echo "PrivateKey = $INWAY_PRIV"
    echo "Address = ${INWAY_IP6}/64"
    echo "MTU = $CH_MTU"
    echo "Table = off"
    obf_lines
    echo "PostUp = $AWG_DIR/dawg-entry.sh channel-up"
    echo "PostDown = $AWG_DIR/dawg-entry.sh channel-down"
    echo
    echo "[Peer]"
    echo "# $OUTWAY_IF @ VPS2 (${TARGET[exit]})"
    echo "PublicKey = $OUTWAY_PUB"
    echo "PresharedKey = $PSK_CH"
    echo "Endpoint = $CH_ENDPOINT"
    echo "AllowedIPs = 0.0.0.0/0, ${OUTWAY_IP6}/128"
    echo "PersistentKeepalive = 25"
  } > "$de/$INWAY_IF.conf"
  {
    echo "# DoubleAWG: параметры входного узла (deploy-doubleawg.sh v$SCRIPT_VERSION, $(date '+%F %T'))"
    printf '%s=%q\n' DAWG_ROLE entry INWAY_IF "$INWAY_IF" WAN_IF "${N_IF4[entry]}" PUB4 "${N_PUB4[entry]}" \
      CHANNEL_AWG "$CH_AWG" INWAY_MTU "$CH_MTU" GATE_PREFIX "$GATE_PREFIX" \
      RT_BASE "$RT_BASE" PEER6 "$OUTWAY_IP6" DEFAULT_DNS "$CLIENT_DNS" DEFAULT_I1 "$USE_I1"
  } > "$de/dawg.env"
  src_lib         > "$de/dawg-lib.sh"
  src_entry_hooks > "$de/dawg-entry.sh"
  src_gate_add    > "$de/dawg-gate-add.sh"
  src_gate_del    > "$de/dawg-gate-del.sh"
  src_client_add  > "$de/dawg-client-add.sh"
  src_client_del  > "$de/dawg-client-del.sh"
  src_channel_del > "$de/dawg-channel-del.sh"
  chmod 600 "$de"/* "$dx"/*
  chmod 700 "$de"/*.sh "$dx"/*.sh
}

build_bundles() {
  local i
  # ── VPS2 ──
  {
    echo '#!/bin/bash'
    printf 'IFACES=%q\n' "$OUTWAY_IF"
    emit_head; emit_cleanup; emit_install
    emit_file "$AWG_DIR/dawg-lib.sh"         700 "$OUT/servers/exit/dawg-lib.sh"
    emit_file "$AWG_DIR/dawg.env"            600 "$OUT/servers/exit/dawg.env"
    emit_file "$AWG_DIR/dawg-exit.sh"        700 "$OUT/servers/exit/dawg-exit.sh"
    emit_file "$AWG_DIR/dawg-channel-del.sh" 700 "$OUT/servers/exit/dawg-channel-del.sh"
    emit_file "$AWG_DIR/$OUTWAY_IF.conf"     600 "$OUT/servers/exit/$OUTWAY_IF.conf"
    emit_after_files
    cat <<'X'
ufw_dawg_add "DoubleAWG $OUTWAY_IF " \
  "allow $OUTWAY_PORT/udp comment 'DoubleAWG $OUTWAY_IF port'" \
  "route allow in on $OUTWAY_IF out on $WAN_IF comment 'DoubleAWG $OUTWAY_IF internet'"
if [ "$IPT_IN" = ip6tables ] && command -v ufw >/dev/null 2>&1 && ! grep -qs '^IPV6=yes' /etc/default/ufw; then
  warn "в /etc/default/ufw IPV6 не yes — правило ufw для IPv6-транспорта не применится (поставьте IPV6=yes и ufw reload)"
fi
start_iface "$OUTWAY_IF"
awg show "$OUTWAY_IF" | sed 's/^/    /'
log "Выходной узел готов"
X
  } > "$WORK/bundle-exit.sh"

  # ── VPS1 ──
  {
    echo '#!/bin/bash'
    local ifs="$INWAY_IF" confs=""
    for (( i = 1; i <= NG; i++ )); do ifs+=" ${GATE_PREFIX}$i"; confs+=" ${GATE_PREFIX}$i.conf"; done
    printf 'IFACES=%q\nRUNID=%q\nGATE_CONFS=%q\n' "$ifs" "$RUNID" "${confs# }"
    emit_head; emit_cleanup; emit_install
    local f
    for f in dawg-lib.sh dawg-entry.sh dawg-gate-add.sh dawg-gate-del.sh dawg-client-add.sh dawg-client-del.sh dawg-channel-del.sh; do
      emit_file "$AWG_DIR/$f" 700 "$OUT/servers/entry/$f"
    done
    emit_file "$AWG_DIR/dawg.env"        600 "$OUT/servers/entry/dawg.env"
    emit_file "$AWG_DIR/$INWAY_IF.conf"  600 "$OUT/servers/entry/$INWAY_IF.conf"
    emit_after_files
    cat <<'X'
log "Split: файлы списков и таймер обновления"
if [ ! -e "$D/dawg-ru-extra.txt" ]; then
  printf '%s\n' "# Свои IPv4-подсети, которые идут НАПРЯМУЮ (как российские). Одна CIDR в строке." \
                "# После правки: $D/dawg-entry.sh split-update" > "$D/dawg-ru-extra.txt"
fi
if [ ! -e "$D/dawg-ru-exclude.txt" ]; then
  printf '%s\n' "# IPv4-подсети, которые всегда идут В КАНАЛ, даже если они российские. Одна CIDR в строке." \
                "# После правки: $D/dawg-entry.sh split-update" > "$D/dawg-ru-exclude.txt"
fi
chmod 600 "$D/dawg-ru-extra.txt" "$D/dawg-ru-exclude.txt"
cat > /etc/systemd/system/dawg-ru-update.service <<UNIT
[Unit]
Description=DoubleAWG: update list of Russian IPv4 networks for split routing
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$D/dawg-entry.sh split-update
UNIT
cat > /etc/systemd/system/dawg-ru-update.timer <<'UNIT'
[Unit]
Description=DoubleAWG: weekly update of Russian IPv4 networks

[Timer]
OnCalendar=weekly
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable -q --now dawg-ru-update.timer
log "Загрузка списка российских подсетей"
"$D/dawg-entry.sh" split-update || warn "список не загрузился — повторите позже: $D/dawg-entry.sh split-update"

start_iface "$INWAY_IF"
log "Проверка Канала $INWAY_IF -> $PEER6"
ping -6 -c 3 -W 2 -I "$INWAY_IF" "$PEER6" >/dev/null 2>&1 || true
hs=0
for _ in $(seq 1 20); do
  hs=$(awg show "$INWAY_IF" latest-handshakes 2>/dev/null | awk '{print $2; exit}')
  [ "${hs:-0}" -gt 0 ] 2>/dev/null && break
  sleep 1
done
CH_OK=0
if [ "${hs:-0}" -gt 0 ] 2>/dev/null && ping -6 -c 3 -W 2 -I "$INWAY_IF" "$PEER6" >/dev/null 2>&1; then
  CH_OK=1; log "Канал работает (рукопожатие есть, ping6 $PEER6 проходит)"
else
  warn "Канал не поднялся: нет рукопожатия или ping6 не проходит"
fi
X
    for (( i = 1; i <= NG; i++ )); do
      printf 'log %q\n' "Входной интерфейс ${GATE_PREFIX}$i"
      printf 'GATE_PRIV=%q "$D/dawg-gate-add.sh" --num %q --awg %q --mode %q --net %q --port %q --split %q --i1 %q --dns %q --yes\n' \
        "${G_PRIV[i]}" "$i" "${G_AWG[i]}" "${G_MODE[i]}" "${G_NET[i]}" "${G_PORT[i]}" "${G_SPLIT[i]}" "$USE_I1" "$CLIENT_DNS"
      if [[ ${G_MODE[i]} == connect ]]; then
        printf 'CLIENT_PRIV=%q CLIENT_PSK=%q "$D/dawg-client-add.sh" %q %q --endpoint %q --quiet\n' \
          "${C_PRIV[i]}" "${C_PSK[i]}" "${GATE_PREFIX}$i" "${G_CLIENT[i]}" "${G_CEP[i]}"
      else
        printf 'CLIENT_PRIV=%q CLIENT_PSK=%q "$D/dawg-client-add.sh" %q %q --quiet\n' \
          "${C_PRIV[i]}" "${C_PSK[i]}" "${GATE_PREFIX}$i" "${G_CLIENT[i]}"
      fi
    done
    cat <<'X'
"$D/dawg-entry.sh" split-status | sed 's/^/    /' || true
awg show | sed 's/^/    /'
OUTTAR="/tmp/dawg-out-$RUNID.tar.gz"
# shellcheck disable=SC2086
( cd "$D" && tar -czf "$OUTTAR" clients $GATE_CONFS )
chmod 600 "$OUTTAR"
chown "${SUDO_USER:-$(id -un)}" "$OUTTAR" 2>/dev/null || true
log "Входной узел готов"
[ "$CH_OK" = 1 ] || exit 3
X
  } > "$WORK/bundle-entry.sh"
}

fetch_entry_files() {
  local tgz="$WORK/out.tgz" x="$WORK/x" i g f
  if ! ssh_cmd entry "cat '/tmp/dawg-out-$RUNID.tar.gz' && rm -f '/tmp/dawg-out-$RUNID.tar.gz'" > "$tgz"; then
    warn "Не удалось забрать конфиги с VPS1 — они остались на сервере в $AWG_DIR/clients/"
    return 0
  fi
  mkdir -p "$x"; tar -xzf "$tgz" -C "$x" || { warn "Архив с VPS1 поврежден"; return 0; }
  for (( i = 1; i <= NG; i++ )); do
    g="${GATE_PREFIX}$i"
    if [[ -f $x/$g.conf ]]; then install -m 600 "$x/$g.conf" "$OUT/servers/entry/$g.conf"; fi
    f="$x/clients/$g/${G_CLIENT[i]}.conf"
    if [[ -f $f ]]; then install -m 600 "$f" "$OUT/$g-${G_CLIENT[i]}.conf"; fi
  done
}

obf_from_conf() {  # строки обфускации из конфига
  grep -E '^(Jc|Jmin|Jmax|S[1-4]|H[1-4]|I[1-5]|HeaderProtectionKey|ContentPaddingAddition|RandomTrailers|DisableCookies|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts)[[:space:]]*=' "$1" 2>/dev/null || true
}

write_result() {
  local f="$OUT/doubleawg-result.txt" tr i g gc cc
  if [[ $TRANSPORT == 6 ]]; then tr="IPv6"; else tr="IPv4"; fi
  {
    echo "######################################################################"
    echo "#  DoubleAWG на AmneziaWG — результат развертывания"
    echo "#  Дата: $(date '+%Y-%m-%d %H:%M:%S %z')   скрипт v$SCRIPT_VERSION"
    echo "#  ВНИМАНИЕ: файл содержит приватные ключи. Храните его в безопасном месте."
    echo "######################################################################"
    echo
    echo "=== СХЕМА ==="
    echo "Клиенты --IPv4--> VPS1 [${GATE_PREFIX}1..${GATE_PREFIX}$NG | $INWAY_IF] --$tr--> VPS2 [$OUTWAY_IF] --IPv4/NAT--> Интернет"
    echo
    echo "=== УЗЛЫ ==="
    echo "[VPS1 вход]  ssh ${TARGET[entry]} (порт ${PORT[entry]}); $(nfo entry OS_NAME), ядро $(nfo entry KERNEL)"
    echo "[VPS1 вход]  WAN ${N_IF4[entry]} ${N_PUB4[entry]}; IPv6 ${N_IF6[entry]:-—} ${N_IP6[entry]:-—}"
    echo "[VPS2 выход] ssh ${TARGET[exit]} (порт ${PORT[exit]}); $(nfo exit OS_NAME), ядро $(nfo exit KERNEL)"
    echo "[VPS2 выход] WAN ${N_IF4[exit]} ${N_PUB4[exit]}; IPv6 ${N_IF6[exit]:-—} ${N_IP6[exit]:-—}"
    echo
    echo "=== КАНАЛ (AmneziaWG $CH_AWG) ==="
    echo "[$OUTWAY_IF @ VPS2]  адрес ${OUTWAY_IP6}/64, UDP-порт $OUTWAY_PORT, MTU $CH_MTU"
    echo "[$INWAY_IF @ VPS1]   адрес ${INWAY_IP6}/64, Endpoint $CH_ENDPOINT, MTU $CH_MTU"
    echo "Транспорт между VPS: $tr; адреса внутри Канала: IPv6 ULA ${ULA_NET}::/64"
    echo "VPS2 не знает подсетей клиентов: соединения из Канала помечаются (CONNMARK 0x444e0000), NAT и возврат — по метке."
    echo "[$OUTWAY_IF] PrivateKey   = $OUTWAY_PRIV"
    echo "[$OUTWAY_IF] PublicKey    = $OUTWAY_PUB"
    echo "[$INWAY_IF]  PrivateKey   = $INWAY_PRIV"
    echo "[$INWAY_IF]  PublicKey    = $INWAY_PUB"
    echo "[$INWAY_IF<->$OUTWAY_IF] PresharedKey = $PSK_CH"
    echo "--- Обфускация Канала (одинаковая на $INWAY_IF и $OUTWAY_IF) ---"
    obf_lines | sed "s/^/[obf $INWAY_IF\/$OUTWAY_IF] /"
    echo
    echo "=== ВХОДНЫЕ ИНТЕРФЕЙСЫ (VPS1) ==="
    for (( i = 1; i <= NG; i++ )); do
      g="${GATE_PREFIX}$i"; gc="$OUT/servers/entry/$g.conf"; cc="$OUT/$g-${G_CLIENT[i]}.conf"
      echo "--- $g: AmneziaWG ${G_AWG[i]}, режим ${G_MODE[i]}, UDP-порт ${G_PORT[i]}, сеть ${G_NET[i]}, MTU 1280, split ${G_SPLIT[i]} ---"
      if [[ ${G_MODE[i]} == listen ]]; then
        echo "    клиенты подключаются к ${N_PUB4[entry]}:${G_PORT[i]}"
      else
        echo "    сервер подключается к клиентам (у клиента ListenPort, у сервера Endpoint клиента)"
      fi
      echo "[$g] PrivateKey = ${G_PRIV[i]}"
      echo "[$g] PublicKey  = ${G_PUB[i]}"
      if [[ -f $gc ]]; then
        obf_from_conf "$gc" | sed "s/^/[obf $g] /"
      else
        echo "[obf $g] (конфиг не получен с сервера — см. $AWG_DIR/$g.conf на VPS1)"
      fi
      echo "[${G_CLIENT[i]}@$g] PrivateKey   = ${C_PRIV[i]}"
      echo "[${G_CLIENT[i]}@$g] PublicKey    = ${C_PUB[i]}"
      echo "[${G_CLIENT[i]}@$g] PresharedKey = ${C_PSK[i]}"
      if [[ ${G_MODE[i]} == connect ]]; then echo "[${G_CLIENT[i]}@$g] Endpoint клиента (сервер подключается) = ${G_CEP[i]}"; fi
      if [[ -f $cc ]]; then echo "[${G_CLIENT[i]}@$g] конфиг: $cc"; fi
    done
    echo
    echo "=== СКРИПТЫ НА СЕРВЕРАХ ($AWG_DIR, запуск через sudo) ==="
    echo "VPS1  dawg-gate-add.sh                         — добавить входной интерфейс (интерактивно или --help)"
    echo "VPS1  dawg-gate-del.sh <интерфейс>             — удалить входной интерфейс и его клиентов"
    echo "VPS1  dawg-client-add.sh <интерфейс> <имя>     — добавить клиента (конфиг в clients/<интерфейс>/<имя>.conf)"
    echo "      (для режима connect: --endpoint host:port — где слушает клиент)"
    echo "VPS1  dawg-client-del.sh <интерфейс> <имя>     — удалить клиента"
    echo "VPS1  dawg-entry.sh split-up|split-down|split-status <интерфейс>, split-update"
    echo "VPS1  dawg-channel-del.sh [--purge]            — удалить Канал, все входные интерфейсы, таймер"
    echo "VPS2  dawg-channel-del.sh [--purge]            — удалить Канал"
    echo "      Ключи новых интерфейсов и клиентов генерирует сервер (awg genkey)."
    echo
    echo "=== SPLIT (VPS1) ==="
    echo "Трафик к российским IPv4 — напрямую через ${N_IF4[entry]} (${N_PUB4[entry]}), остальное — в Канал."
    echo "Включается отдельно для каждого входного интерфейса строками в его .conf:"
    echo "  PostUp = $AWG_DIR/dawg-entry.sh split-up <интерфейс>"
    echo "  PostDown = $AWG_DIR/dawg-entry.sh split-down <интерфейс>"
    echo "  и systemctl restart awg-quick@<интерфейс>"
    echo "Список RU: $AWG_DIR/dawg-ru.txt (таймер dawg-ru-update.timer раз в неделю)"
    echo "Свои напрямую: dawg-ru-extra.txt; всегда в Канал: dawg-ru-exclude.txt; затем split-update"
    echo
    echo "=== FIREWALL ==="
    echo "iptables — в PostUp/PostDown (dawg-entry.sh, dawg-exit.sh); ufw (если установлен) — правила с пометкой 'DoubleAWG <интерфейс>'."
    echo "Внешний firewall провайдера не настраивается: откройте UDP $OUTWAY_PORT на VPS2 и порты входных интерфейсов на VPS1."
    echo
    echo "=== ВЕРСИИ AmneziaWG ==="
    echo "1 — Jc/Jmin/Jmax, S1-S2, H1-H4 одиночными значениями; 1.5 — + I1; 2 — + S3-S4, H1-H4 диапазонами;"
    echo "3 — + HeaderProtectionKey, ContentPaddingAddition (S1-S4 >= 12, H1-H4 = 1..4); 3.1 — + RandomTrailers, DisableCookies."
    echo "Параметры обфускации (кроме Jc/Jmin/Jmax/I1) должны совпадать у сервера и клиента."
  } > "$f"
  chmod 600 "$f"
  RESULT_FILE=$f
}

# ═════════════════════════════════ основной сценарий ═════════════════════════════════
main() {
  printf '\n%sDoubleAWG на AmneziaWG (kernel-mode) — развертывание v%s%s\n\n' "$C_B" "$SCRIPT_VERSION" "$C_0" >&2
  check_local
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/dawg.XXXXXX"); chmod 700 "$WORK"
  trap cleanup EXIT
  trap 'die "Прервано"' INT TERM
  umask 077

  # ── 1. Доступ по ssh ──
  local e x ep xp
  ask e  "SSH входного VPS1 (user@host)"  "${ENTRY_SSH-}"
  ask ep "  SSH-порт"                      "${ENTRY_SSH_PORT:-22}"
  ask x  "SSH выходного VPS2 (user@host)" "${EXIT_SSH-}"
  ask xp "  SSH-порт"                      "${EXIT_SSH_PORT:-22}"
  [[ $e =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || die "Ожидается формат user@host: '$e'"
  [[ $x =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || die "Ожидается формат user@host: '$x'"
  { is_port "$ep" && is_port "$xp"; } || die "Некорректный SSH-порт"
  [[ "${e#*@}:$ep" != "${x#*@}:$xp" ]] || die "Вход и выход должны быть разными серверами"
  TARGET[entry]=$e; PORT[entry]=$ep
  TARGET[exit]=$x;  PORT[exit]=$xp

  # ── 2. Опрос узлов ──
  write_probe
  probe_node entry
  probe_node exit
  check_node entry "VPS1"
  check_node exit  "VPS2"
  confirm_node entry "ВХОДНОЙ VPS1"
  confirm_node exit  "ВЫХОДНОЙ VPS2"
  [[ ${N_PUB4[entry]} != "${N_PUB4[exit]}" ]] || die "У входа и выхода одинаковый публичный IPv4"

  # ── 3. Транспорт между VPS ──
  TRANSPORT=6
  if [[ -z ${N_IP6[exit]} || -z ${N_IF6[entry]} ]]; then
    warn "IPv6 недоступен (у VPS2 нет публичного IPv6 или у VPS1 нет маршрута IPv6 по умолчанию)."
    if confirm "Использовать IPv4 для транспорта между VPS (адреса внутри Канала останутся IPv6)?" Y; then
      TRANSPORT=4
    else
      die "Настройте IPv6 на VPS и запустите скрипт снова"
    fi
  else
    info "Проверка IPv6-связности VPS1 -> VPS2 (${N_IP6[exit]})..."
    if ssh_cmd entry "ping -6 -c 2 -W 3 '${N_IP6[exit]}' >/dev/null 2>&1"; then
      ok "IPv6 между узлами работает"
    else
      warn "ping6 до ${N_IP6[exit]} с VPS1 не прошел (ICMP может быть закрыт)."
      if confirm "Переключить транспорт между VPS на IPv4?" N; then TRANSPORT=4; fi
    fi
  fi

  # ── 4. Имена интерфейсов ──
  printf '\n%sИмена интерфейсов%s\n' "$C_B" "$C_0" >&2
  ask OUTWAY_IF   "Выход из Канала на VPS2"                    "outway"
  ask INWAY_IF    "Вход в Канал на VPS1"                       "inway"
  ask GATE_PREFIX "Префикс входных интерфейсов клиентов (VPS1)" "gate"
  valid_ifname "$OUTWAY_IF" || die "Имя '$OUTWAY_IF': до 15 символов, латиница, цифры, _ = + . -"
  valid_ifname "$INWAY_IF"  || die "Имя '$INWAY_IF': до 15 символов, латиница, цифры, _ = + . -"
  [[ $GATE_PREFIX =~ ^[A-Za-z_][A-Za-z0-9_=+.-]{0,11}$ ]] || die "Префикс '$GATE_PREFIX': до 12 символов, начинается с буквы"
  [[ ! $INWAY_IF =~ ^${GATE_PREFIX//./\\.}[0-9]+$ ]] || die "Имя '$INWAY_IF' пересекается с именами входных интерфейсов ${GATE_PREFIX}N"
  if link_on_node exit "$OUTWAY_IF" && [[ $(nfo exit PREV) != v2 ]]; then
    warn "На VPS2 уже есть интерфейс $OUTWAY_IF — он будет остановлен и перезаписан."
    confirm "Продолжить?" N || exit 1
  fi
  if link_on_node entry "$INWAY_IF" && [[ $(nfo entry PREV) != v2 ]]; then
    warn "На VPS1 уже есть интерфейс $INWAY_IF — он будет остановлен и перезаписан."
    confirm "Продолжить?" N || exit 1
  fi

  # ── 5. Параметры Канала ──
  printf '\n%sКанал%s\n' "$C_B" "$C_0" >&2
  ask_awg_version CH_AWG "Версия AmneziaWG для Канала (1, 1.5, 2, 3, 3.1)" "2"
  ask OUTWAY_PORT "UDP-порт $OUTWAY_IF на VPS2" "$(rnd 20000 60999)"
  is_port "$OUTWAY_PORT" || die "Некорректный UDP-порт"
  ask CLIENT_DNS "DNS для клиентов" "1.1.1.1, 1.0.0.1"
  USE_I1=no
  if confirm "Добавлять I1 (имитация QUIC Initial перед рукопожатием; для версий 1.5+)?" Y; then USE_I1=yes; fi

  # ── 6. Входные интерфейсы ──
  declare -ga G_AWG=() G_MODE=() G_PORT=() G_NET=() G_SPLIT=() G_CLIENT=() G_CEP=() G_PRIV=() G_PUB=() C_PRIV=() C_PUB=() C_PSK=()
  NG=0
  local used=" $OUTWAY_PORT " p name r sys_nets="" new_nets="" net c x
  # маршруты VPS1, кроме тех, что исчезнут при установке (интерфейсы, которые будут пересозданы или удалены)
  for r in $(nfo entry ROUTES4); do
    case ${r#*@} in
      "$INWAY_IF"|"$GATE_PREFIX"[0-9]*) continue ;;
    esac
    sys_nets+="${r%@*} "
  done
  while :; do
    NG=$(( NG + 1 ))
    name="${GATE_PREFIX}$NG"
    valid_ifname "$name" || die "Имя '$name' недопустимо"
    printf '\n%sВходной интерфейс %s%s\n' "$C_B" "$name" "$C_0" >&2
    net=""
    for (( x = NG; x < NG + 254; x++ )); do
      c="10.8.$(( (x - 1) % 254 + 1 )).0/24"
      net_conflict "$c" "$new_nets $sys_nets" >/dev/null || { net=$c; break; }
    done
    while :; do
      ask "G_NET[$NG]" "  Подсеть клиентов (A.B.C.D/N)" "$net"
      if ! cidr_parse "${G_NET[NG]}" 8 30; then warn "Ожидается A.B.C.D/N, N от 8 до 30"; continue; fi
      if [[ $C_STR != "${G_NET[NG]}" ]]; then warn "Подсеть приведена к $C_STR"; G_NET[NG]=$C_STR; fi
      if c=$(net_conflict "${G_NET[NG]}" "$new_nets"); then warn "Пересекается с подсетью другого входного интерфейса ($c)"; continue; fi
      if c=$(net_conflict "${G_NET[NG]}" "$sys_nets"); then
        warn "Пересекается с маршрутом на VPS1 ($c) — установка на сервере будет остановлена."
        continue
      fi
      break
    done
    new_nets+="${G_NET[NG]} "
    if link_on_node entry "$name" && [[ $(nfo entry PREV) != v2 ]]; then
      warn "На VPS1 уже есть интерфейс $name — он будет остановлен и перезаписан."
    fi
    ask_awg_version "G_AWG[$NG]" "  Версия AmneziaWG (1, 1.5, 2, 3, 3.1)" "$CH_AWG"
    while :; do
      ask "G_MODE[$NG]" "  Режим: listen — клиенты подключаются к серверу; connect — сервер подключается к клиенту" "listen"
      [[ ${G_MODE[NG]} == listen || ${G_MODE[NG]} == connect ]] && break
      warn "Допустимо: listen или connect"
    done
    p=$(rnd 20000 60999); while [[ $used == *" $p "* ]]; do p=$(rnd 20000 60999); done
    ask "G_PORT[$NG]" "  UDP-порт $name" "$p"
    is_port "${G_PORT[NG]}" || die "Некорректный UDP-порт"
    [[ $used != *" ${G_PORT[NG]} "* ]] || die "Порт ${G_PORT[NG]} уже используется"
    used+="${G_PORT[NG]} "
    G_SPLIT[NG]=no
    if confirm "  Split: российские IP напрямую с VPS1, остальное в Канал?" Y; then G_SPLIT[NG]=yes; fi
    ask "G_CLIENT[$NG]" "  Имя первого клиента" "client1"
    [[ ${G_CLIENT[NG]} =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die "Имя клиента: латиница, цифры, _ . -"
    G_CEP[NG]=""
    if [[ ${G_MODE[NG]} == connect ]]; then
      ask "G_CEP[$NG]" "  Адрес клиента host:port (белый IP/DNS-имя и порт, на котором он слушает)" ""
      [[ ${G_CEP[NG]} =~ ^.+:[0-9]{1,5}$ ]] || die "Ожидается host:port"
      warn "  Клиент должен принимать входящий UDP на ${G_CEP[NG]##*:} (firewall/проброс порта на его стороне)."
    fi
    confirm "Добавить еще один входной интерфейс?" N || break
  done

  # ── 7. Генерация ──
  RUNID="$(date +%s)$RANDOM"
  gen_all
  OUT=${OUT_DIR:-"$PWD/doubleawg-$(date +%Y%m%d-%H%M%S)"}
  mkdir -p "$OUT"; chmod 700 "$OUT"
  write_local_files
  write_result
  build_bundles
  ok "Ключи, параметры и конфиги сохранены: $OUT"

  local trs i; [[ $TRANSPORT == 6 ]] && trs="IPv6" || trs="IPv4"
  printf '\n%sИтог%s\n' "$C_B" "$C_0" >&2
  printf '  Канал: %s (VPS1) -> %s (VPS2) %s, AWG %s, транспорт %s, MTU %s\n' "$INWAY_IF" "$OUTWAY_IF" "$CH_ENDPOINT" "$CH_AWG" "$trs" "$CH_MTU" >&2
  printf '  Выход в интернет: %s через %s (NAT)\n' "${N_PUB4[exit]}" "${N_IF4[exit]}" >&2
  for (( i = 1; i <= NG; i++ )); do
    printf '  %s: AWG %s, %s, порт %s, сеть %s, split %s, клиент %s%s\n' "${GATE_PREFIX}$i" "${G_AWG[i]}" "${G_MODE[i]}" \
      "${G_PORT[i]}" "${G_NET[i]}" "${G_SPLIT[i]}" "${G_CLIENT[i]}" "${G_CEP[i]:+ (${G_CEP[i]})}" >&2
  done
  echo >&2
  confirm "Установить AmneziaWG и применить конфигурацию на обоих VPS?" Y || { warn "Отменено. Файлы остались в $OUT"; exit 0; }

  # ── 8. Развертывание: сначала выход, затем вход ──
  info "Развертывание VPS2 ${TARGET[exit]}"
  deploy_node exit "$WORK/bundle-exit.sh" "VPS2" || die "Ошибка на VPS2. Файлы: $OUT"
  ok "VPS2 настроен"

  info "Развертывание VPS1 ${TARGET[entry]}"
  local rc=0
  deploy_node entry "$WORK/bundle-entry.sh" "VPS1" || rc=$?
  case $rc in
    0|3) fetch_entry_files ;;
  esac
  write_result
  case $rc in
    0) ok "VPS1 настроен, Канал работает" ;;
    3) warn "VPS1 настроен, но Канал не поднялся. Проверьте firewall провайдера (UDP $OUTWAY_PORT на $CH_ENDPOINT) и 'sudo awg show' на обоих узлах." ;;
    *) die "Ошибка на VPS1 (код $rc). Файлы: $OUT" ;;
  esac

  # ── 9. Итог ──
  printf '\n%sГотово.%s\n' "$C_G" "$C_0" >&2
  printf '  Результат (ключи, параметры): %s\n' "$RESULT_FILE" >&2
  for (( i = 1; i <= NG; i++ )); do
    printf '  Клиент %-24s %s\n' "${G_CLIENT[i]}@${GATE_PREFIX}$i:" "$OUT/${GATE_PREFIX}$i-${G_CLIENT[i]}.conf" >&2
  done
  printf '  Управление на VPS1: sudo %s/dawg-client-add.sh <интерфейс> <имя>, dawg-gate-add.sh и др. (см. файл результата)\n' "$AWG_DIR" >&2
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
