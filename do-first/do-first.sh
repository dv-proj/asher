#!/usr/bin/env bash
#
# do-first.sh — первичная настройка свежего headless VPS на Ubuntu / Debian.
#
#   Запуск:   sudo bash do-first.sh [--yes] [--dry-run]
#             curl -fsSL https://raw.githubusercontent.com/dv-proj/asher/main/do-first/do-first.sh | sudo bash
#             curl -fsSL URL | sudo bash -s -- --yes        (с переменными окружения для ответов)
#
#   Что делает (по шагам, см. --list): обновление системы, базовые пакеты, пользователь с sudo,
#   SSH-ключ, усиление sshd (отключение паролей, порт), ufw, fail2ban, автообновления, часовой пояс
#   и время, hostname, locale, журналы, swap, sysctl, отключение лишних служб, Docker (по желанию).
#
#   Параметры:
#     --yes, -y   принять ответы по умолчанию, ничего не спрашивать
#     --dry-run   показать действия, ничего не менять (можно и без root)
#     --list      показать шаги и их статус (done/pending)
#     --reset     забыть состояние (выполненные шаги, сохранённые ответы)
#     --resume    служебный: продолжение после перезагрузки (вызывается systemd-юнитом)
#     --help      эта справка
#
#   Все ответы можно задать переменными окружения (см. --help). Состояние хранится в /var/lib/do-first:
#   повторный запуск пропускает уже сделанные шаги и ничего не спрашивает повторно. После
#   перезагрузки (если нужна) настройка продолжается автоматически через systemd-юнит.
#   Лог: /var/log/do-first.log
#
# Требования: root, Ubuntu или Debian с systemd, bash 4.4+.
#
set -Eeuo pipefail

SCRIPT_VERSION="1.0"
SCRIPT_URL_DEFAULT="https://raw.githubusercontent.com/dv-proj/asher/main/do-first/do-first.sh"
SCRIPT_URL=${SCRIPT_URL:-$SCRIPT_URL_DEFAULT}   # откуда перекачать скрипт, если он запущен через curl | bash

LOG=/var/log/do-first.log
STATE_DIR=/var/lib/do-first
DONE_FILE=$STATE_DIR/done
ANSWERS_FILE=$STATE_DIR/answers.env
VERSION_FILE=$STATE_DIR/version
NOTES_FILE=$STATE_DIR/report.txt
REBOOT_FLAG=$STATE_DIR/reboot.flag
BACKUP_DIR=$STATE_DIR/backup
SELF_COPY=$STATE_DIR/do-first.sh
LOCK_FILE=/var/lock/do-first.lock
UNIT_NAME=do-first-resume.service
UNIT_FILE=/etc/systemd/system/$UNIT_NAME

# Базовые пакеты шага packages (переопределяются переменной окружения BASE_PACKAGES).
# Отсутствующие в дистрибутиве пакеты пропускаются без ошибки.
BASE_PACKAGES_DEFAULT="sudo curl wget ca-certificates gnupg git htop ncdu jq tmux vim mc net-tools dnsutils unattended-upgrades fail2ban ufw logrotate"

# Службы шага disable_extra (только Ubuntu, только те, что реально есть; спрашиваем один раз группой).
EXTRA_UNITS="snapd.service snapd.socket snapd.seeded.service apport.service ModemManager.service multipathd.service multipathd.socket lxd-agent.service motd-news.timer"

# ═══════════════════════════ РЕЕСТР ШАГОВ ═══════════════════════════
#
# Как добавить шаг:
#   1. Напишите функцию step_<id>() { ... }. Она должна быть идемпотентной (проверять, нужна ли работа)
#      и завершаться с кодом 0 при успехе; любая ошибка/`die` — шаг считается проваленным.
#      Шаг выполняется в подоболочке: переменные оттуда наружу не попадают. Для отчёта используйте
#      note "текст" / warn_note "текст"; для перезагрузки — request_reboot "причина".
#   2. (Необязательно) функция ask_<id>() { ask ...; ask_yn ...; } — вопросы шага. Вызывается в фазе
#      «сбор ответов», только если шаг ещё не выполнен. Новые ключи ответов добавьте в ANSWER_KEYS.
#   3. Добавьте заголовок: STEP_TITLE[<id>]="...".
#   4. Вставьте <id> в массив STEPS в нужное место (середина или конец — неважно).
# Выполненные шаги учитываются ПО ИМЕНИ (файл done), а не по номеру, поэтому вставка нового шага
# в любое место не ломает сохранённое состояние: на уже настроенном сервере выполнится только он.
#
STEPS=(
  preflight apt_upgrade packages user ssh_key ssh_harden firewall fail2ban unattended
  timezone_time hostname locale journald_logs swap sysctl disable_extra docker cleanup
)
declare -A STEP_TITLE=(
  [preflight]="Проверка системы, сети и текущих настроек SSH"
  [apt_upgrade]="Обновление пакетов (apt update/upgrade)"
  [packages]="Установка базовых утилит"
  [user]="Создание пользователя с sudo"
  [ssh_key]="SSH-ключи пользователя"
  [ssh_harden]="Усиление sshd (пароли, root, порт)"
  [firewall]="Файрвол ufw"
  [fail2ban]="fail2ban для sshd"
  [unattended]="Автоматические обновления безопасности"
  [timezone_time]="Часовой пояс и синхронизация времени"
  [hostname]="Имя хоста"
  [locale]="Локаль (по желанию)"
  [journald_logs]="Журналы: journald и logrotate"
  [swap]="Swap-файл"
  [sysctl]="Безопасные параметры ядра (sysctl)"
  [disable_extra]="Отключение лишних служб (Ubuntu)"
  [docker]="Docker (по желанию)"
  [cleanup]="Очистка и проверка перезагрузки"
)

# Ключи ответов: сохраняются в answers.env (строки KEY='value'), подхватываются из окружения.
ANSWER_KEYS=(
  ALLOW_REBOOT SKIP_STEPS BASE_PACKAGES OLD_SSH_PORTS CLIENT_IP
  NEW_USER SET_PASSWORD USER_PASSWORD SSH_PUBKEY
  DISABLE_PASSWORD_AUTH DISABLE_ROOT_SSH SSH_PORT UFW_EXTRA_PORTS IGNORE_IPS
  AUTO_REBOOT AUTO_REBOOT_TIME UPGRADE_UPDATES
  TIMEZONE HOSTNAME_NEW CONFIGURE_LOCALE LOCALE JOURNAL_MAX SWAP_SIZE DISABLE_EXTRA INSTALL_DOCKER
)
SECRET_KEYS=(USER_PASSWORD)

# ─────────────────────────────── глобальное состояние ───────────────────────────────
ASSUME_YES=0
DRY_RUN=0
RESUME=0
MODE=run
HAVE_TTY=0
KEEP_UNIT=0
LOG_ON=
ERR_SHOWN=0
OS_ID="" OS_LIKE="" OS_CODENAME="" OS_VERSION="" OS_PRETTY=""
SSH_SVC="" SSHD_BIN=/usr/sbin/sshd

# ─────────────────────────────── оформление ───────────────────────────────
if [[ -t 2 ]]; then
  C_R=$'\e[1;31m'; C_G=$'\e[1;32m'; C_Y=$'\e[1;33m'; C_C=$'\e[1;36m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else
  C_R=; C_G=; C_Y=; C_C=; C_B=; C_0=
fi
_log() {  # запись строки в лог без цветов
  if [[ -z $LOG_ON ]]; then return 0; fi
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null || true
}
info() { printf '%s==>%s %s\n' "$C_C" "$C_0" "$*" >&2; _log "INFO  $*"; }
ok()   { printf '%s[ok]%s %s\n' "$C_G" "$C_0" "$*" >&2; _log "OK    $*"; }
warn() { printf '%s[!]%s %s\n'  "$C_Y" "$C_0" "$*" >&2; _log "WARN  $*"; }
die()  { printf '%s[x]%s %s\n'  "$C_R" "$C_0" "$*" >&2; _log "FATAL $*"; exit 1; }
dry()  { printf '%s[dry-run]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
say()  { printf '%s\n' "$*" >&2; _log "$*"; }
note() {  # строка в итоговый отчёт (сохраняется между перезапусками)
  if (( DRY_RUN )); then return 0; fi
  printf '%s\n' "$*" >>"$NOTES_FILE" 2>/dev/null || true
}
warn_note() { warn "$*"; note "[!] $*"; }

# ─────────────────────────────── ввод ───────────────────────────────
is_yes() { case ${1,,} in y|yes|1|true|on|д|да) return 0 ;; esac; return 1; }
is_no()  { case ${1,,} in n|no|0|false|off|н|нет) return 0 ;; esac; return 1; }

_read_yn() {  # _read_yn "вопрос" Y|N — только с терминала
  local def=${2:-Y} a hint="[Y/n]"
  if [[ $def == N ]]; then hint="[y/N]"; fi
  while :; do
    if ! read -r -p "$1 $hint: " a </dev/tty; then a=$def; fi
    a=${a:-$def}
    case ${a,,} in
      y|yes|д|да) return 0 ;;
      n|no|н|нет) return 1 ;;
    esac
  done
}
confirm() {  # confirm "вопрос" [Y|N] — при --yes сразу «да»
  if (( ASSUME_YES )); then return 0; fi
  if (( ! HAVE_TTY )); then die "Нет терминала для подтверждения «$1». Запустите с --yes."; fi
  _read_yn "$1" "${2:-Y}"
}
ask() {  # ask VAR "вопрос" ["по умолчанию"] [валидатор] — берёт значение из окружения/ответов, иначе спрашивает
  local __var=$1 __prompt=$2 __def=${3-} __chk=${4:-} __ans=""
  if [[ -v $__var ]]; then
    __ans=${!__var}
    if [[ -n $__chk ]] && ! "$__chk" "$__ans"; then
      die "Недопустимое значение $__var='$__ans' (из окружения или сохранённых ответов)."
    fi
    return 0
  fi
  if (( ASSUME_YES )); then
    __ans=$__def
    if [[ -n $__chk ]] && ! "$__chk" "$__ans"; then
      die "$__var: нет допустимого значения по умолчанию. Задайте переменную окружения $__var."
    fi
  elif (( HAVE_TTY )); then
    while :; do
      if [[ -n $__def ]]; then
        read -r -p "$__prompt [$__def]: " __ans </dev/tty || __ans=$__def
      else
        read -r -p "$__prompt: " __ans </dev/tty || __ans=""
      fi
      if [[ -z $__ans ]]; then __ans=$__def; fi
      if [[ -z $__chk ]] || "$__chk" "$__ans"; then break; fi
      warn "Недопустимое значение, повторите ввод."
    done
  else
    die "Нет терминала для вопроса «$__prompt». Задайте переменную окружения $__var или запустите с --yes."
  fi
  printf -v "$__var" '%s' "$__ans"
  _log "ответ $__var='$__ans'"
}
ask_yn() {  # ask_yn VAR "вопрос" Y|N — в VAR кладёт yes/no
  local __var=$1 __prompt=$2 __def=${3:-Y} __v
  if [[ -v $__var ]]; then
    __v=${!__var}
    if is_yes "$__v"; then __v=yes
    elif is_no "$__v"; then __v=no
    else die "Недопустимое значение $__var='$__v' (ожидается yes/no)."; fi
  elif (( ASSUME_YES )); then
    if [[ $__def == Y ]]; then __v=yes; else __v=no; fi
  elif (( HAVE_TTY )); then
    if _read_yn "$__prompt" "$__def"; then __v=yes; else __v=no; fi
  else
    die "Нет терминала для вопроса «$__prompt». Задайте переменную окружения $__var или запустите с --yes."
  fi
  printf -v "$__var" '%s' "$__v"
  _log "ответ $__var='$__v'"
}
ask_secret() {  # ask_secret VAR "вопрос"
  local __var=$1 __prompt=$2 __a="" __b=""
  if [[ -v $__var ]]; then return 0; fi
  if (( ASSUME_YES || ! HAVE_TTY )); then
    die "Нужен пароль: задайте переменную окружения $__var."
  fi
  while :; do
    read -r -s -p "$__prompt: " __a </dev/tty || __a=""; printf '\n' >&2
    read -r -s -p "Повторите пароль: " __b </dev/tty || __b=""; printf '\n' >&2
    if [[ -z $__a ]]; then warn "Пароль не может быть пустым."; continue; fi
    if [[ $__a != "$__b" ]]; then warn "Пароли не совпадают."; continue; fi
    break
  done
  printf -v "$__var" '%s' "$__a"
}

# ─────────────────────────────── валидаторы ───────────────────────────────
v_user()     { [[ -z $1 ]] && return 0; [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ && $1 != root ]]; }
v_port()     { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
v_hostname() {
  [[ ${#1} -ge 1 && ${#1} -le 253 ]] || return 1
  [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}
v_timezone() {
  [[ -n $1 ]] || return 1
  if command -v timedatectl >/dev/null 2>&1; then
    local l; l=$(timedatectl list-timezones 2>/dev/null || true)
    if [[ -n $l ]]; then grep -qxF -- "$1" <<<"$l"; return; fi
  fi
  [[ -f /usr/share/zoneinfo/$1 ]]
}
v_size_journal() { [[ $1 =~ ^[0-9]+[KMGkmg]$ ]]; }
v_size_swap()    { [[ ${1,,} =~ ^([0-9]+[mg]|0|no|none|off|нет)$ ]]; }
v_time()         { [[ $1 =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }
v_locale()       { [[ $1 =~ ^[A-Za-z]{2,3}(_[A-Za-z0-9]+)?(\.[A-Za-z0-9-]+)?(@[A-Za-z0-9]+)?$ ]]; }
v_ips() {
  local t
  [[ -z $1 ]] && return 0
  for t in ${1//,/ }; do [[ $t =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || return 1; done
  return 0
}
v_ports_extra() {  # 80,443/tcp 8000:8010/tcp 51820/udp
  local t
  [[ -z $1 ]] && return 0
  for t in ${1//,/ }; do
    [[ $t =~ ^[0-9]{1,5}(:[0-9]{1,5})?(/(tcp|udp))?$ ]] || return 1
    if [[ $t == *:* && $t != */* ]]; then return 1; fi   # для диапазона ufw требует протокол
  done
  return 0
}

# ─────────────────────────────── выполнение команд ───────────────────────────────
run() {  # run КОМАНДА... — вывод в лог; при --dry-run только печатает
  if (( DRY_RUN )); then dry "$*"; return 0; fi
  _log "\$ $*"
  "$@" </dev/null >>"$LOG" 2>&1
}
aptg() {  # неинтерактивный apt-get
  run env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -y \
    -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=600 "$@"
}
put_file() {  # put_file ПУТЬ [РЕЖИМ] <<<ТЕКСТ — идемпотентная запись файла
  local path=$1 mode=${2:-644} content tmp
  content=$(cat)
  if (( DRY_RUN )); then dry "записать $path (режим $mode)"; return 0; fi
  mkdir -p "$(dirname "$path")"
  if [[ -f $path && "$(cat "$path")" == "$content" ]]; then
    chmod "$mode" "$path"
    return 0
  fi
  tmp=$(mktemp "$path.XXXXXX")
  printf '%s\n' "$content" >"$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$path"
  _log "записан файл $path"
}
pkg_installed() { [[ $(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null || true) == ii* ]]; }
pkg_available() {
  local c; c=$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2}' || true)
  [[ -n $c && $c != "(none)" ]]
}
ensure_pkgs() {  # ensure_pkgs пакет... — ставит недостающие, отсутствующие в репозитории пропускает
  local p miss=() skip=()
  for p in "$@"; do
    if pkg_installed "$p"; then continue; fi
    if pkg_available "$p"; then miss+=("$p"); else skip+=("$p"); fi
  done
  if (( ${#skip[@]} )); then warn "Нет в репозитории, пропускаю: ${skip[*]}"; fi
  if (( ${#miss[@]} )); then
    info "Устанавливаю: ${miss[*]}"
    aptg install "${miss[@]}"
  fi
}
fetch_url() {  # fetch_url URL — содержимое в stdout
  if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 30 "$1" </dev/null
  elif command -v wget >/dev/null 2>&1; then wget -qO- --timeout=30 "$1" </dev/null
  else return 127; fi
}
in_container() { systemd-detect-virt --container --quiet 2>/dev/null; }
reboot_required() { [[ -f /var/run/reboot-required ]]; }

# ─────────────────────────────── состояние ───────────────────────────────
step_is_done()    { [[ -f $DONE_FILE ]] && grep -qxF -- "$1" "$DONE_FILE"; }
step_is_skipped() { local s; for s in ${SKIP_STEPS-}; do if [[ $s == "$1" ]]; then return 0; fi; done; return 1; }
step_pending()    { ! step_is_done "$1" && ! step_is_skipped "$1"; }
mark_done() {
  if (( DRY_RUN )); then return 0; fi
  if ! step_is_done "$1"; then printf '%s\n' "$1" >>"$DONE_FILE"; fi
}
state_init() {
  if (( DRY_RUN )); then return 0; fi
  install -d -m 755 "$STATE_DIR"
  install -d -m 700 "$BACKUP_DIR"
  touch "$DONE_FILE" "$NOTES_FILE"
  printf '%s\n' "$SCRIPT_VERSION" >"$VERSION_FILE"
}
load_answers() {  # значения из окружения приоритетнее сохранённых
  [[ -r $ANSWERS_FILE ]] || return 0
  local saved line k
  saved=$(
    for k in "${ANSWER_KEYS[@]}"; do unset "$k"; done
    # shellcheck disable=SC1090
    source "$ANSWERS_FILE"
    for k in "${ANSWER_KEYS[@]}"; do
      if [[ -v $k ]]; then printf '%s=%q\n' "$k" "${!k}"; fi
    done
  ) || true
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    k=${line%%=*}
    if [[ ! -v $k ]]; then eval "$line"; fi
  done <<<"$saved"
}
save_answers() {
  if (( DRY_RUN )); then return 0; fi
  local k tmp
  tmp=$(mktemp "$STATE_DIR/answers.XXXXXX")
  chmod 600 "$tmp"
  for k in "${ANSWER_KEYS[@]}"; do
    if [[ -v $k ]]; then printf '%s=%q\n' "$k" "${!k}" >>"$tmp"; fi
  done
  mv -f "$tmp" "$ANSWERS_FILE"
}
scrub_answer() {  # удалить ключ из answers.env (пароль после использования)
  if (( DRY_RUN )); then return 0; fi
  if [[ -f $ANSWERS_FILE ]]; then sed -i "/^$1=/d" "$ANSWERS_FILE"; fi
}

# ─────────────────────────────── перезагрузка и возобновление ───────────────────────────────
remove_resume_unit() {
  if [[ -f $UNIT_FILE ]]; then
    systemctl disable "$UNIT_NAME" >/dev/null 2>&1 || true
    rm -f "$UNIT_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}
save_self() {  # сохраняет копию скрипта в $SELF_COPY (из файла или скачиванием по SCRIPT_URL)
  local src=${BASH_SOURCE[0]:-} tmp
  mkdir -p "$STATE_DIR"
  if [[ -n $src && -f $src ]]; then
    if [[ $(readlink -f "$src") != "$(readlink -f "$SELF_COPY")" ]]; then
      install -m 700 "$src" "$SELF_COPY"
    fi
    return 0
  fi
  info "Скрипт запущен из pipe — скачиваю копию для продолжения после перезагрузки: $SCRIPT_URL"
  tmp=$(mktemp)
  if ! fetch_url "$SCRIPT_URL" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    die "Не удалось скачать скрипт с $SCRIPT_URL — продолжение после перезагрузки невозможно. Сохраните скрипт в файл и запустите его локально либо задайте SCRIPT_URL."
  fi
  if ! head -n1 "$tmp" | grep -q '^#!.*bash' || ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    die "Скачанное с $SCRIPT_URL не похоже на скрипт do-first.sh. Задайте SCRIPT_URL или запустите скрипт из файла."
  fi
  install -m 700 "$tmp" "$SELF_COPY"
  rm -f "$tmp"
}
install_resume_unit() {
  put_file "$UNIT_FILE" 644 <<EOF
[Unit]
Description=do-first: продолжение первичной настройки сервера после перезагрузки
After=network-online.target cloud-final.service
Wants=network-online.target
ConditionPathExists=$SELF_COPY

[Service]
Type=oneshot
Environment=HOME=/root
ExecStart=/bin/bash $SELF_COPY --resume --yes
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
  run systemctl daemon-reload
  run systemctl enable "$UNIT_NAME"
}
request_reboot() {  # request_reboot "причина" — вызывается из шага; перезагрузка — после отметки шага выполненным
  local why=${1:-нужна перезагрузка}
  if ! is_yes "${ALLOW_REBOOT-yes}"; then
    warn_note "Нужна перезагрузка ($why), но ALLOW_REBOOT=no — перезагрузите сервер вручную позже."
    return 0
  fi
  if (( DRY_RUN )); then dry "запросил бы перезагрузку: $why"; return 0; fi
  save_self
  install_resume_unit
  printf '%s\n' "$why" >"$REBOOT_FLAG"
}
reboot_if_requested() {  # вызывается движком после mark_done
  [[ -f $REBOOT_FLAG ]] || return 0
  local why; why=$(<"$REBOOT_FLAG")
  rm -f "$REBOOT_FLAG"
  info "Нужна перезагрузка: $why"
  if (( ! ASSUME_YES && ! HAVE_TTY )); then
    warn_note "Перезагрузка не выполнена: нет терминала и не указан --yes. Перезагрузите сервер вручную и запустите скрипт снова."
    remove_resume_unit
    return 0
  fi
  if confirm "Перезагрузить сервер сейчас? После загрузки настройка продолжится автоматически." Y; then
    KEEP_UNIT=1
    say "Перезагрузка... Ход продолжения: tail -f $LOG (после загрузки подключитесь заново)."
    sync
    if reboot; then
      sleep 300
      KEEP_UNIT=0
      warn "Перезагрузка не наступила за 5 минут."
    else
      KEEP_UNIT=0
      warn_note "Команда reboot не выполнилась — перезагрузите сервер вручную."
    fi
  else
    warn_note "Перезагрузка отложена по вашему выбору ($why)."
  fi
  remove_resume_unit
}

# ─────────────────────────────── обнаружение окружения ───────────────────────────────
detect_os() {
  [[ -r /etc/os-release ]] || die "Нет /etc/os-release — не удалось определить ОС."
  eval "$(
    # shellcheck disable=SC1091
    . /etc/os-release
    printf 'OS_ID=%q OS_LIKE=%q OS_CODENAME=%q OS_VERSION=%q OS_PRETTY=%q UB_CODENAME=%q' \
      "${ID-}" "${ID_LIKE-}" "${VERSION_CODENAME-}" "${VERSION_ID-}" "${PRETTY_NAME-}" "${UBUNTU_CODENAME-}"
  )"
  case $OS_ID in
    ubuntu|debian) ;;
    *)
      if [[ " $OS_LIKE " == *" ubuntu "* ]]; then OS_ID=ubuntu; OS_CODENAME=${UB_CODENAME:-$OS_CODENAME}
      elif [[ " $OS_LIKE " == *" debian "* ]]; then OS_ID=debian
      else die "Поддерживаются только Ubuntu и Debian (найдено: ${OS_PRETTY:-$OS_ID})."; fi ;;
  esac
  if [[ -z $OS_CODENAME ]] && command -v lsb_release >/dev/null 2>&1; then
    OS_CODENAME=$(lsb_release -cs 2>/dev/null || true)
  fi
  [[ -d /run/systemd/system ]] || die "Нужен systemd (PID 1)."
}
cur_ssh_ports() {  # текущие порты sshd (по эффективной конфигурации), через пробел
  local p=""
  if [[ -x $SSHD_BIN ]]; then
    p=$("$SSHD_BIN" -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -un | tr '\n' ' ' || true)
  fi
  p=${p%% }
  echo "${p:-22}"
}
detect_ssh() {
  SSHD_BIN=$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)
  if systemctl cat ssh.service >/dev/null 2>&1; then SSH_SVC=ssh
  elif systemctl cat sshd.service >/dev/null 2>&1; then SSH_SVC=sshd
  else SSH_SVC=""; fi
  if [[ ! -v CLIENT_IP ]]; then
    CLIENT_IP=""
    if [[ -n ${SSH_CONNECTION-} ]]; then CLIENT_IP=${SSH_CONNECTION%% *}; fi
    if [[ -z $CLIENT_IP ]]; then
      CLIENT_IP=$(who -m 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p' || true)
    fi
    if [[ -n $CLIENT_IP ]] && ! v_ips "$CLIENT_IP"; then CLIENT_IP=""; fi
  fi
  if [[ ! -v OLD_SSH_PORTS ]]; then
    local ports conn=""
    ports=$(cur_ssh_ports)
    if [[ -n ${SSH_CONNECTION-} ]]; then
      read -r _ _ _ conn <<<"$SSH_CONNECTION" || true
    fi
    if [[ $conn =~ ^[0-9]+$ && " $ports " != *" $conn "* ]]; then ports="$ports $conn"; fi
    OLD_SSH_PORTS=$ports
  fi
}

# ─────────────────────────────── интерфейс: справка, список, сброс ───────────────────────────────
usage() {
  cat <<'EOF'
do-first.sh — первичная настройка свежего VPS (Ubuntu/Debian).

Использование:
  sudo bash do-first.sh [параметры]
  curl -fsSL URL | sudo bash -s -- [параметры]

Параметры:
  --yes, -y    принять значения по умолчанию, ничего не спрашивать
  --dry-run    показать, что будет сделано, ничего не меняя (работает и без root)
  --list       список шагов и их статус
  --reset      забыть состояние (выполненные шаги, сохранённые ответы)
  --help, -h   эта справка

Ответы можно задать переменными окружения (тогда вопрос не задаётся):
  NEW_USER              имя нового пользователя (пусто — не создавать)
  SET_PASSWORD          yes/no — сменить пароль существующему пользователю (для нового пароль обязателен)
  USER_PASSWORD         пароль пользователя (после создания удаляется из сохранённых ответов)
  SSH_PUBKEY            публичные ключи: строки ключей, github:<user> или https://github.com/<user>.keys
  DISABLE_PASSWORD_AUTH yes/no — отключить вход по паролю (только если проверки пройдены)
  DISABLE_ROOT_SSH      yes/no — запретить вход root по SSH
  SSH_PORT              порт SSH (по умолчанию текущий)
  UFW_EXTRA_PORTS       доп. порты ufw, напр. "80,443/tcp"
  IGNORE_IPS            белый список fail2ban (по умолчанию — IP вашей SSH-сессии)
  AUTO_REBOOT           yes/no — автоперезагрузка после автообновлений
  AUTO_REBOOT_TIME      время автоперезагрузки (HH:MM, по умолчанию 04:00)
  UPGRADE_UPDATES       yes/no — автообновления также из -updates (по умолчанию no)
  TIMEZONE              часовой пояс, напр. Europe/Moscow
  HOSTNAME_NEW          новое имя хоста
  CONFIGURE_LOCALE      yes/no; LOCALE — локаль (по умолчанию en_US.UTF-8)
  JOURNAL_MAX           лимит журнала journald (по умолчанию 200M)
  SWAP_SIZE             размер swap (1G, 512M; 0/no — не создавать)
  DISABLE_EXTRA         yes/no — отключить лишние службы (Ubuntu)
  INSTALL_DOCKER        yes/no — установить Docker
  ALLOW_REBOOT          yes/no — разрешить перезагрузки (по умолчанию yes)
  BASE_PACKAGES         список базовых пакетов вместо стандартного
  SKIP_STEPS            идентификаторы шагов, которые пропустить (через пробел)
  SCRIPT_URL            откуда скачать скрипт для продолжения после перезагрузки при запуске через curl | bash

Состояние: /var/lib/do-first. Лог: /var/log/do-first.log.
Пример без вопросов:
  curl -fsSL URL | sudo NEW_USER=admin SSH_PUBKEY=github:myname USER_PASSWORD=... bash -s -- --yes
EOF
}
list_steps() {
  local id st
  printf 'Шаги do-first (состояние: %s):\n' "$STATE_DIR"
  for id in "${STEPS[@]}"; do
    if step_is_done "$id"; then st="done   "
    elif step_is_skipped "$id"; then st="skipped"
    else st="pending"; fi
    printf '  [%s] %-14s %s\n' "$st" "$id" "${STEP_TITLE[$id]-?}"
  done
}
do_reset() {
  if ! confirm "Забыть состояние do-first (выполненные шаги и сохранённые ответы)?" N; then
    info "Отменено."
    return 0
  fi
  remove_resume_unit
  rm -f "$DONE_FILE" "$ANSWERS_FILE" "$VERSION_FILE" "$NOTES_FILE" "$REBOOT_FLAG" "$SELF_COPY"
  ok "Состояние сброшено. Бэкапы конфигов остались в $BACKUP_DIR"
}

# ─────────────────────────────── фаза вопросов ───────────────────────────────
ask_user() {
  ask NEW_USER "Имя нового пользователя с sudo (пусто — не создавать)" "" v_user
  if [[ -z $NEW_USER ]]; then return 0; fi
  if id "$NEW_USER" >/dev/null 2>&1; then
    info "Пользователь $NEW_USER уже существует — создавать не буду."
    ask_yn SET_PASSWORD "Сменить пароль пользователю $NEW_USER?" N
  else
    SET_PASSWORD=yes   # для нового пользователя пароль обязателен
  fi
  if is_yes "$SET_PASSWORD"; then ask_secret USER_PASSWORD "Пароль нового пользователя $NEW_USER"; fi
}
ask_ssh_key() {
  [[ -n ${NEW_USER-} ]] || return 0
  local raw="" line keys
  if [[ -v SSH_PUBKEY ]]; then
    raw=$SSH_PUBKEY
  elif (( ! ASSUME_YES && HAVE_TTY )); then
    info "Публичный SSH-ключ для $NEW_USER: вставьте строку ключа, github:<user> или https-ссылку на .keys."
    info "Можно несколько, по одному в строке; пустая строка — конец ввода."
    while :; do
      read -r -p "  ключ: " line </dev/tty || line=""
      [[ -n $line ]] || break
      if [[ -n $(resolve_keys <<<"$line") ]]; then raw+=$line$'\n'; else warn "Ключ не распознан, попробуйте ещё раз."; fi
    done
  fi
  keys=$(resolve_keys <<<"$raw" || true)
  if [[ -z $keys ]]; then
    warn "SSH-ключ не задан: вход по паролю отключён НЕ будет (проверка в шаге ssh_harden)."
  fi
  SSH_PUBKEY=$keys
}
ask_ssh_harden() {
  ask_yn DISABLE_PASSWORD_AUTH "Отключить вход по паролю в SSH (только если есть ключ и sudo)?" Y
  ask_yn DISABLE_ROOT_SSH "Запретить вход root по SSH?" N
  local cur; cur=$(cur_ssh_ports)
  ask SSH_PORT "Порт SSH" "${cur%% *}" v_port
}
ask_firewall() { ask UFW_EXTRA_PORTS "Дополнительные порты ufw (например 80,443/tcp; пусто — нет)" "" v_ports_extra; }
ask_fail2ban() { ask IGNORE_IPS "IP/подсети в белый список fail2ban (через пробел; сейчас ваш IP)" "${CLIENT_IP-}" v_ips; }
ask_unattended() {
  ask_yn AUTO_REBOOT "Автоматически перезагружать сервер после обновлений ядра?" Y
  if is_yes "$AUTO_REBOOT"; then ask AUTO_REBOOT_TIME "Время автоперезагрузки (HH:MM)" "04:00" v_time; fi
  ask_yn UPGRADE_UPDATES "Ставить автоматически и обычные обновления (-updates), не только безопасность?" N
}
ask_timezone_time() {
  local cur
  cur=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)
  ask TIMEZONE "Часовой пояс" "$cur" v_timezone
}
ask_hostname() { ask HOSTNAME_NEW "Имя хоста" "$(hostname)" v_hostname; }
ask_locale() {
  ask_yn CONFIGURE_LOCALE "Настроить локаль (locale)?" N
  if is_yes "$CONFIGURE_LOCALE"; then ask LOCALE "Локаль" "en_US.UTF-8" v_locale; fi
}
ask_journald_logs() { ask JOURNAL_MAX "Максимальный размер журнала journald" "200M" v_size_journal; }
ask_swap() {
  if in_container; then return 0; fi
  if [[ -n $(swapon --noheadings --show 2>/dev/null || true) ]]; then return 0; fi
  ask SWAP_SIZE "Размер swap-файла, например 512M или 2G (0 или no — не создавать)" "512M" v_size_swap
}
present_extra_units() {  # выводит найденные службы из EXTRA_UNITS
  local u out=()
  for u in $EXTRA_UNITS; do
    if [[ -n $(systemctl list-unit-files --no-legend "$u" 2>/dev/null || true) ]]; then
      if [[ $u == multipathd.* ]] && [[ -n $(multipath -ll 2>/dev/null || true) ]]; then continue; fi
      out+=("$u")
    fi
  done
  echo "${out[*]-}"
}
ask_disable_extra() {
  [[ $OS_ID == ubuntu ]] || return 0
  local l; l=$(present_extra_units)
  [[ -n $l ]] || return 0
  ask_yn DISABLE_EXTRA "Отключить ненужные службы: $l (snapd: snap-пакеты перестанут работать)?" Y
}
ask_docker() { ask_yn INSTALL_DOCKER "Установить Docker?" N; }

show_summary() {
  local k v
  say ""
  say "Параметры настройки:"
  for k in "${ANSWER_KEYS[@]}"; do
    [[ -v $k ]] || continue
    v=${!k}
    case $k in
      USER_PASSWORD) v="(задан)" ;;
      SSH_PUBKEY) v="ключей: $(grep -c . <<<"$v" || true)" ;;
      BASE_PACKAGES|OLD_SSH_PORTS|CLIENT_IP|SKIP_STEPS) continue ;;
    esac
    say "  $k = ${v:-(пусто)}"
  done
  say ""
}
collect_answers() {
  local id pend=()
  for id in "${STEPS[@]}"; do
    if step_pending "$id"; then pend+=("$id"); fi
  done
  if (( ${#pend[@]} == 0 )); then return 0; fi
  if [[ ! -v BASE_PACKAGES ]]; then BASE_PACKAGES=$BASE_PACKAGES_DEFAULT; fi
  if step_pending apt_upgrade || step_pending cleanup; then
    ask_yn ALLOW_REBOOT "Разрешить перезагрузку сервера, если она понадобится (новое ядро)?" Y
  fi
  for id in "${pend[@]}"; do
    if declare -F "ask_$id" >/dev/null; then "ask_$id"; fi
  done
  if (( ! RESUME )); then
    show_summary
    if (( ! DRY_RUN )); then
      confirm "Всё верно, начинаем?" Y || die "Отменено пользователем."
    fi
  fi
  save_answers
}

# ─────────────────────────────── движок шагов ───────────────────────────────
on_step_err() {  # on_step_err СТРОКА "КОМАНДА" — один раз показывает, что упало
  local rc=$?
  if (( ERR_SHOWN )); then return 0; fi
  ERR_SHOWN=1
  warn "Команда завершилась с кодом $rc: $2 (строка $1)"
  if [[ -n $LOG_ON ]]; then tail -n 8 "$LOG" 2>/dev/null | sed 's/^/    | /' >&2 || true; fi
}
run_steps() {
  local id rc n=0 total=0
  for id in "${STEPS[@]}"; do if step_pending "$id"; then total=$((total + 1)); fi; done
  for id in "${STEPS[@]}"; do
    if step_is_skipped "$id" && ! step_is_done "$id"; then info "Шаг $id пропущен (SKIP_STEPS)."; fi
    step_pending "$id" || continue
    declare -F "step_$id" >/dev/null || die "Шаг '$id' есть в STEPS, но функции step_$id нет."
    n=$((n + 1))
    printf '\n%s[%d/%d] %s%s\n' "$C_B" "$n" "$total" "${STEP_TITLE[$id]-$id}" "$C_0" >&2
    _log "=== шаг $id: ${STEP_TITLE[$id]-} ==="
    set +e
    (
      trap 'on_step_err $LINENO "$BASH_COMMAND"' ERR
      set -e
      "step_$id"
    )
    rc=$?
    set -e
    if (( rc != 0 )); then
      printf '%s[x]%s Шаг «%s» (%s) завершился с ошибкой (код %d).\n' "$C_R" "$C_0" "${STEP_TITLE[$id]-$id}" "$id" "$rc" >&2
      _log "FATAL шаг $id провален (код $rc)"
      say "Устраните причину и запустите скрипт снова — он продолжит с этого шага. Лог: $LOG"
      exit "$rc"
    fi
    mark_done "$id"
    ok "Шаг «$id» выполнен"
    reboot_if_requested
  done
}

# ═══════════════════════════ ШАГИ ═══════════════════════════

step_preflight() {
  info "ОС: ${OS_PRETTY:-$OS_ID} (${OS_CODENAME:-?}), виртуализация: $(systemd-detect-virt 2>/dev/null || echo неизвестно)"
  info "SSH: служба=${SSH_SVC:-не найдена}, порты: ${OLD_SSH_PORTS}, ваш IP: ${CLIENT_IP:-не определён}"
  if [[ -z $SSH_SVC ]]; then warn "Служба sshd не найдена — шаг ssh_harden будет пропущен."; fi
  info "Проверяю доступность репозиториев apt..."
  aptg update || die "apt недоступен: проверьте сеть, DNS и /etc/apt/sources.list."
  ok "Сеть и apt в порядке"
}

step_apt_upgrade() {
  aptg update
  aptg upgrade
  if reboot_required; then
    request_reboot "после обновления пакетов требуется перезагрузка (ядро/библиотеки)"
  fi
}

step_packages() {
  local pk
  aptg update
  read -r -a pk <<<"${BASE_PACKAGES:-$BASE_PACKAGES_DEFAULT}"
  ensure_pkgs "${pk[@]}"
  ok "Базовые пакеты на месте"
}

step_user() {
  local u=${NEW_USER-} created=0 tmp
  if [[ -z $u ]]; then info "Пользователь не задан — шаг пропущен."; return 0; fi
  ensure_pkgs sudo
  if id "$u" >/dev/null 2>&1; then
    ok "Пользователь $u уже существует"
  else
    run adduser --disabled-password --gecos "" "$u"
    created=1
    ok "Пользователь $u создан"
  fi
  if is_yes "${SET_PASSWORD-no}"; then
    [[ -n ${USER_PASSWORD-} ]] || die "Пароль для $u не задан (USER_PASSWORD)."
    if (( DRY_RUN )); then dry "chpasswd для $u"; else printf '%s:%s\n' "$u" "$USER_PASSWORD" | chpasswd; fi
    scrub_answer USER_PASSWORD
    ok "Пароль $u установлен"
  fi
  if ! getent group sudo >/dev/null 2>&1; then run groupadd sudo; fi
  run usermod -aG sudo "$u"
  if ! is_yes "${SET_PASSWORD-no}" && (( created )); then
    tmp=$(mktemp)
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$u" >"$tmp"
    if (( DRY_RUN )); then
      dry "создать /etc/sudoers.d/90-do-first-$u (NOPASSWD)"
    else
      if ! visudo -cf "$tmp" >/dev/null 2>&1; then rm -f "$tmp"; die "visudo отклонил sudoers-файл для $u."; fi
      install -m 440 -o root -g root "$tmp" "/etc/sudoers.d/90-do-first-$u"
    fi
    rm -f "$tmp"
    note "Пользователь $u: пароля нет, sudo без пароля (вход только по ключу)."
  elif ! is_yes "${SET_PASSWORD-no}"; then
    warn "У существующего $u пароль не менялся; если пароля нет, sudo может быть недоступен."
  fi
  note "Пользователь $u в группе sudo."
}

key_blob() { awk '{for(i=1;i<=NF;i++) if($i ~ /^(ssh-|ecdsa-|sk-)/){print $(i+1); exit}}' <<<"$1"; }
valid_key() {
  local t rc=0
  t=$(mktemp)
  printf '%s\n' "$1" >"$t"
  ssh-keygen -lf "$t" >/dev/null 2>&1 || rc=$?
  rm -f "$t"
  return "$rc"
}
resolve_keys() {  # stdin: строки (ключ | github:user | https://...); stdout: валидные ключи
  local line src content l
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    if [[ -z $line || $line == \#* ]]; then continue; fi
    case $line in
      github:*)       src="https://github.com/${line#github:}.keys" ;;
      http://*|https://*) src=$line ;;
      *)              src="" ;;
    esac
    if [[ -n $src ]]; then
      if ! content=$(fetch_url "$src" 2>/dev/null); then warn "Не удалось получить ключи: $src"; continue; fi
      while IFS= read -r l || [[ -n $l ]]; do
        if [[ $l =~ ^(ssh-|ecdsa-|sk-) ]] && valid_key "$l"; then printf '%s\n' "$l"; fi
      done <<<"$content"
    elif valid_key "$line"; then
      printf '%s\n' "$line"
    else
      warn "Некорректный ключ пропущен: ${line:0:40}..."
    fi
  done
}

step_ssh_key() {
  local u=${NEW_USER-} home grp ak key blob added=0 k
  if [[ -z $u ]]; then info "Пользователь не задан — шаг пропущен."; return 0; fi
  if ! id "$u" >/dev/null 2>&1; then
    if (( DRY_RUN )); then dry "ключи для $u (пользователь ещё не создан)"; return 0; fi
    die "Пользователь $u не существует."
  fi
  home=$(getent passwd "$u" | cut -d: -f6)
  grp=$(id -gn "$u")
  ak=$home/.ssh/authorized_keys
  if [[ -z ${SSH_PUBKEY-} ]]; then
    k=$(ssh-keygen -lf "$ak" 2>/dev/null | grep -c '^[0-9]' || true)
    if (( ${k:-0} >= 1 )); then
      ok "Новых ключей нет, но в $ak уже есть ключи ($k)"
    else
      warn_note "SSH-ключ для $u не задан и не найден: вход по паролю отключён не будет."
    fi
    return 0
  fi
  if (( DRY_RUN )); then dry "добавить ключи в $ak"; return 0; fi
  install -d -m 700 -o "$u" -g "$grp" "$home/.ssh"
  touch "$ak"
  chmod 600 "$ak"
  chown "$u:$grp" "$ak"
  while IFS= read -r key; do
    [[ -n $key ]] || continue
    blob=$(key_blob "$key")
    if [[ -n $blob ]] && grep -qF -- "$blob" "$ak"; then continue; fi
    if [[ -s $ak && -n $(tail -c1 "$ak") ]]; then printf '\n' >>"$ak"; fi
    printf '%s\n' "$key" >>"$ak"
    added=$((added + 1))
  done <<<"$SSH_PUBKEY"
  ok "Ключей добавлено: $added (файл $ak)"
  note "SSH-ключи пользователя $u: добавлено $added."
}

# --- ssh_harden: вспомогательные функции ---
SSH_DROPIN=/etc/ssh/sshd_config.d/99-do-first.conf
SSH_CFG=/etc/ssh/sshd_config
SSH_BACKUPS=()
SSH_DROPIN_NEW=0
ssh_backup() {
  local f=$1 b
  if (( DRY_RUN )); then dry "бэкап $f"; return 0; fi
  b=$BACKUP_DIR/$(tr '/' '_' <<<"${f#/}").$(date +%Y%m%d-%H%M%S)
  cp -a "$f" "$b"
  SSH_BACKUPS+=("$f|$b")
  _log "бэкап $f -> $b"
}
ssh_rollback() {
  local e
  warn "Откатываю изменения конфигурации sshd."
  for e in "${SSH_BACKUPS[@]}"; do cp -a "${e#*|}" "${e%%|*}"; done
  if (( SSH_DROPIN_NEW )); then rm -f "$SSH_DROPIN"; fi
}
ssh_reload_quiet() { systemctl restart "$SSH_SVC" >/dev/null 2>&1 || true; }
ssh_ensure_include() {
  if grep -qE '^[[:space:]]*Include[[:space:]].*sshd_config\.d' "$SSH_CFG"; then return 0; fi
  info "Добавляю Include /etc/ssh/sshd_config.d/*.conf в начало sshd_config"
  if (( DRY_RUN )); then dry "вставить Include в начало $SSH_CFG"; return 0; fi
  ssh_backup "$SSH_CFG"
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$SSH_CFG"
}
ssh_neutralize() {  # ssh_neutralize ФАЙЛ СТОП_НА_INCLUDE(0|1) КЛЮЧИ,ЧЕРЕЗ,ЗАПЯТУЮ — sshd: побеждает первое значение
  local f=$1 stop=$2 keys=$3 tmp
  tmp=$(mktemp)
  awk -v keys="$keys" -v stop="$stop" '
    BEGIN { n = split(keys, a, ","); for (i = 1; i <= n; i++) k[tolower(a[i])] = 1 }
    {
      if (!done) {
        f = tolower($1); sub(/=.*$/, "", f)
        if (f == "match") done = 1
        else if (stop == 1 && f == "include") done = 1
        else if (f in k) { print "# do-first: " $0; next }
      }
      print
    }' "$f" >"$tmp"
  if cmp -s "$f" "$tmp"; then rm -f "$tmp"; return 0; fi
  info "Комментирую конфликтующие директивы в $f (бэкап в $BACKUP_DIR)"
  if (( DRY_RUN )); then dry "закомментировать директивы ($keys) в $f"; rm -f "$tmp"; return 0; fi
  ssh_backup "$f"
  cat "$tmp" >"$f"
  rm -f "$tmp"
}
ssh_write_dropin() {  # ssh_write_dropin ИМЯ_ДИРЕКТИВЫ_KBD
  local kbd=$1
  put_file "$SSH_DROPIN" 644 < <(
    printf '%s\n' "# Управляется do-first.sh. Первое значение директивы в sshd побеждает, поэтому конфликтующие"
    printf '%s\n' "# строки в других файлах закомментированы (бэкапы: $BACKUP_DIR)."
    if (( WANT_PW_OFF )); then printf 'PasswordAuthentication no\n%s no\n' "$kbd"; fi
    if [[ -n $ROOT_VAL ]]; then printf 'PermitRootLogin %s\n' "$ROOT_VAL"; fi
    if (( PORT_NEW )); then printf 'Port %s\n' "$WANT_PORT"; fi
  )
}
ssh_wait_port() {
  local p=$1 i
  command -v ss >/dev/null 2>&1 || return 0
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [[ -n $(ss -H -ltn "sport = :$p" 2>/dev/null || true) ]]; then return 0; fi
    sleep 1
  done
  return 1
}
user_login_ok() {  # безопасно ли закрывать пароль/root: у пользователя есть ключ, sudo, он пройдёт по sshd
  local u=${1-} home ak n bad=0 eff pk au ag g perm own
  if [[ -z $u ]]; then warn "Пользователь не задан."; return 1; fi
  if ! id "$u" >/dev/null 2>&1; then warn "Пользователь $u не существует."; return 1; fi
  home=$(getent passwd "$u" | cut -d: -f6)
  ak=$home/.ssh/authorized_keys
  n=$(ssh-keygen -lf "$ak" 2>/dev/null | grep -c '^[0-9]' || true)
  if (( ${n:-0} < 1 )); then warn "У $u нет валидного ключа в $ak."; bad=1
  else
    own=$(stat -c %U "$ak" 2>/dev/null || echo ?)
    if [[ $own != "$u" ]]; then warn "Владелец $ak — $own, а не $u (sshd отвергнет ключи)."; bad=1; fi
    perm=$(stat -c %a "$home" 2>/dev/null || echo 700)
    if (( (8#$perm & 8#022) != 0 )); then warn "Домашний каталог $home доступен на запись группе/всем — sshd (StrictModes) отвергнет ключи."; bad=1; fi
  fi
  if ! { id -nG "$u" | tr ' ' '\n' | grep -xE 'sudo|admin|wheel' >/dev/null; } \
     && [[ ! -f /etc/sudoers.d/90-do-first-$u ]] \
     && ! sudo -n -l -U "$u" >/dev/null 2>&1; then
    warn "У $u нет прав sudo."; bad=1
  fi
  eff=$("$SSHD_BIN" -T 2>/dev/null || true)
  if [[ -n $eff ]]; then
    pk=$(awk '$1=="pubkeyauthentication"{print $2}' <<<"$eff")
    if [[ $pk != yes ]]; then warn "В sshd отключена PubkeyAuthentication."; bad=1; fi
    au=$(awk '$1=="allowusers"{$1=""; print}' <<<"$eff")
    if [[ -n $au && " $au " != *" $u "* ]]; then warn "AllowUsers в sshd не содержит $u: вход этого пользователя может быть запрещён."; bad=1; fi
    ag=$(awk '$1=="allowgroups"{$1=""; print}' <<<"$eff")
    if [[ -n $ag ]]; then
      local okg=0
      for g in $(id -nG "$u"); do if [[ " $ag " == *" $g "* ]]; then okg=1; fi; done
      if (( ! okg )); then warn "AllowGroups в sshd не включает группы $u."; bad=1; fi
    fi
  fi
  return "$bad"
}

step_ssh_harden() {
  local u=${NEW_USER-} cur_ports eff login_ok=0 root_has_key=0 kbd=KbdInteractiveAuthentication keys f svc=$SSH_SVC
  WANT_PW_OFF=0; ROOT_VAL=""; PORT_NEW=0; WANT_PORT=""
  if [[ -z $svc || ! -x $SSHD_BIN ]]; then warn_note "sshd не найден — усиление SSH пропущено."; return 0; fi
  cur_ports=$(cur_ssh_ports)
  WANT_PORT=${SSH_PORT:-${cur_ports%% *}}
  if [[ " $cur_ports " != *" $WANT_PORT "* ]]; then PORT_NEW=1; fi   # порт уже слушается — не трогаем

  if is_yes "${DISABLE_PASSWORD_AUTH-yes}" || is_yes "${DISABLE_ROOT_SSH-no}"; then
    if user_login_ok "$u"; then login_ok=1; fi
  fi
  if is_yes "${DISABLE_PASSWORD_AUTH-yes}"; then
    if (( login_ok )); then WANT_PW_OFF=1
    else warn_note "Вход по паролю НЕ отключён: проверки безопасности не пройдены (нужны ключ и sudo у пользователя). Исправьте и повторите шаг: sudo sed -i '/^ssh_harden\$/d' $DONE_FILE && sudo bash $SELF_COPY"; fi
  fi
  if [[ -s /root/.ssh/authorized_keys ]] && grep -qE '^[^#[:space:]]' /root/.ssh/authorized_keys; then root_has_key=1; fi
  if is_yes "${DISABLE_ROOT_SSH-no}"; then
    if (( login_ok )); then ROOT_VAL=no
    else warn_note "Вход root по SSH НЕ запрещён: у обычного пользователя нет ключа/sudo."; fi
  elif (( WANT_PW_OFF && root_has_key )); then
    ROOT_VAL=prohibit-password
  fi

  if (( ! WANT_PW_OFF )) && [[ -z $ROOT_VAL ]] && (( ! PORT_NEW )); then
    info "Изменения sshd не требуются."
    return 0
  fi

  keys=""
  if (( WANT_PW_OFF )); then keys="PasswordAuthentication,KbdInteractiveAuthentication,ChallengeResponseAuthentication"; fi
  if [[ -n $ROOT_VAL ]]; then keys="${keys:+$keys,}PermitRootLogin"; fi
  if (( PORT_NEW )); then keys="${keys:+$keys,}Port"; fi

  run mkdir -p /run/sshd /etc/ssh/sshd_config.d
  ssh_ensure_include
  for f in /etc/ssh/sshd_config.d/*.conf; do
    [[ -f $f && $f != "$SSH_DROPIN" ]] || continue
    ssh_neutralize "$f" 0 "$keys"
  done
  ssh_neutralize "$SSH_CFG" 1 "$keys"
  if [[ -f $SSH_DROPIN ]]; then ssh_backup "$SSH_DROPIN"; else SSH_DROPIN_NEW=1; fi
  ssh_write_dropin "$kbd"

  if (( ! DRY_RUN )); then
    if ! "$SSHD_BIN" -t 2>>"$LOG"; then
      if (( WANT_PW_OFF )); then   # старый OpenSSH знает только ChallengeResponseAuthentication
        kbd=ChallengeResponseAuthentication
        ssh_write_dropin "$kbd"
      fi
      if ! "$SSHD_BIN" -t 2>>"$LOG"; then
        ssh_rollback
        die "sshd -t отклонил конфигурацию (см. $LOG); изменения откатены, sshd не перезапускался."
      fi
    fi
    eff=$("$SSHD_BIN" -T 2>/dev/null || true)
    if (( WANT_PW_OFF )) && [[ $(awk '$1=="passwordauthentication"{print $2}' <<<"$eff") != no ]]; then
      ssh_rollback
      die "Эффективная конфигурация всё ещё разрешает пароли (перебивает другой файл). Изменения откатены."
    fi
    if (( PORT_NEW )) && [[ $(awk '$1=="port"{print $2}' <<<"$eff" | tr '\n' ' ') != "$WANT_PORT " ]]; then
      ssh_rollback
      die "Эффективный порт sshd не совпал с запрошенным $WANT_PORT. Изменения откатены."
    fi
    if [[ -n $ROOT_VAL && $(awk '$1=="permitrootlogin"{print $2}' <<<"$eff") != "$ROOT_VAL" ]]; then
      warn "PermitRootLogin в эффективной конфигурации не $ROOT_VAL — проверьте вручную: sshd -T | grep permitroot"
    fi
  fi

  if (( PORT_NEW )) && command -v ufw >/dev/null 2>&1; then
    info "Открываю новый порт $WANT_PORT в ufw до перезапуска sshd (старый порт остаётся открытым)"
    run ufw limit "$WANT_PORT/tcp"
  fi

  if (( PORT_NEW )); then
    if systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
      info "ssh.socket игнорирует Port из sshd_config — перевожу sshd на обычный запуск службы"
      run systemctl disable --now ssh.socket
      run systemctl enable "$svc"
    fi
    run systemctl restart "$svc" || { ssh_rollback; ssh_reload_quiet; die "Не удалось перезапустить $svc; конфигурация откачена."; }
    if (( ! DRY_RUN )) && ! ssh_wait_port "$WANT_PORT"; then
      ssh_rollback
      ssh_reload_quiet
      die "sshd не слушает порт $WANT_PORT после перезапуска; конфигурация откачена."
    fi
  else
    run systemctl reload "$svc" || run systemctl restart "$svc"
  fi
  ok "sshd применил настройки"

  if (( WANT_PW_OFF )); then note "SSH: вход по паролю отключён (drop-in $SSH_DROPIN)."; fi
  if [[ -n $ROOT_VAL ]]; then note "SSH: PermitRootLogin $ROOT_VAL."; fi
  if (( PORT_NEW )); then note "SSH: порт изменён ${cur_ports} -> $WANT_PORT. Старый порт ещё открыт в ufw."; fi
}

step_firewall() {
  local p ports=() seen=" " t extra
  ensure_pkgs ufw
  for p in $(cur_ssh_ports) ${SSH_PORT-} ${OLD_SSH_PORTS-}; do
    if [[ $seen != *" $p "* ]]; then ports+=("$p"); seen+="$p "; fi
  done
  run ufw default deny incoming
  run ufw default allow outgoing
  for p in "${ports[@]}"; do run ufw limit "$p/tcp"; done
  if grep -q '^IPV6=' /etc/default/ufw 2>/dev/null; then
    if (( DRY_RUN )); then dry "IPV6=yes в /etc/default/ufw"; else sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw; fi
  else
    if (( DRY_RUN )); then dry "добавить IPV6=yes в /etc/default/ufw"; else printf 'IPV6=yes\n' >>/etc/default/ufw; fi
  fi
  extra=${UFW_EXTRA_PORTS-}
  for t in ${extra//,/ }; do run ufw allow "$t"; done
  run ufw --force enable
  run ufw reload
  ok "ufw включён; SSH-порты: ${ports[*]}"
  note "ufw: deny incoming; открыто (SSH, с лимитом): ${ports[*]}${extra:+; дополнительно: $extra}."
}

step_fail2ban() {
  local ign p ports=() seen=" " i
  ensure_pkgs fail2ban
  for p in $(cur_ssh_ports) ${SSH_PORT-} ${OLD_SSH_PORTS-}; do
    if [[ $seen != *" $p "* ]]; then ports+=("$p"); seen+="$p "; fi
  done
  ign="127.0.0.1/8 ::1 ${IGNORE_IPS//,/ }"
  put_file /etc/fail2ban/jail.d/do-first.local 644 <<EOF
# Управляется do-first.sh
[sshd]
enabled = true
port = $(IFS=,; echo "${ports[*]}")
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 5
ignoreip = ${ign}
EOF
  run systemctl enable fail2ban
  run systemctl restart fail2ban
  if (( DRY_RUN )); then return 0; fi
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if fail2ban-client status sshd >/dev/null 2>&1; then
      ok "fail2ban: jail sshd активен"
      note "fail2ban: sshd, бан 1h после 5 попыток за 10m; белый список: $ign."
      return 0
    fi
    sleep 1
  done
  warn_note "fail2ban не поднял jail sshd — проверьте: journalctl -u fail2ban -n 30"
}

step_unattended() {
  local origins
  ensure_pkgs unattended-upgrades
  put_file /etc/apt/apt.conf.d/20auto-upgrades 644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  put_file /etc/apt/apt.conf.d/52do-first-unattended 644 < <(
    printf '%s\n' "// Управляется do-first.sh. Дополняет стандартный 50unattended-upgrades (он не меняется)."
    printf '%s\n' 'Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";'
    printf '%s\n' 'Unattended-Upgrade::Remove-Unused-Dependencies "true";'
    if is_yes "${AUTO_REBOOT-yes}"; then
      printf '%s\n' 'Unattended-Upgrade::Automatic-Reboot "true";'
      printf 'Unattended-Upgrade::Automatic-Reboot-Time "%s";\n' "${AUTO_REBOOT_TIME:-04:00}"
      printf '%s\n' 'Unattended-Upgrade::Automatic-Reboot-WithUsers "true";'
    else
      printf '%s\n' 'Unattended-Upgrade::Automatic-Reboot "false";'
    fi
    printf '%s\n' 'Unattended-Upgrade::Allowed-Origins {'
    if [[ $OS_ID == ubuntu ]]; then
      printf '%s\n' '    "${distro_id}:${distro_codename}-security";'
      if is_yes "${UPGRADE_UPDATES-no}"; then printf '%s\n' '    "${distro_id}:${distro_codename}-updates";'; fi
    else
      printf '%s\n' '    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";'
      if is_yes "${UPGRADE_UPDATES-no}"; then printf '%s\n' '    "origin=Debian,codename=${distro_codename}-updates";'; fi
    fi
    printf '%s\n' '};'
  )
  if (( ! DRY_RUN )); then
    if timeout 180 unattended-upgrade --dry-run >>"$LOG" 2>&1 </dev/null; then
      ok "unattended-upgrade --dry-run прошёл"
    else
      warn "unattended-upgrade --dry-run завершился с ошибкой (не критично, см. $LOG)"
    fi
  fi
  if is_yes "${AUTO_REBOOT-yes}"; then origins="автоперезагрузка в ${AUTO_REBOOT_TIME:-04:00}"; else origins="автоперезагрузка выключена"; fi
  note "Автообновления: security${UPGRADE_UPDATES:+ (+updates: $UPGRADE_UPDATES)}, $origins."
}

step_timezone_time() {
  local cur i tz=${TIMEZONE-}
  if [[ -n $tz ]]; then
    cur=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    if [[ $cur != "$tz" ]]; then run timedatectl set-timezone "$tz"; ok "Часовой пояс: $tz"; else ok "Часовой пояс уже $tz"; fi
  fi
  if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null || true) == yes ]]; then
    ok "Время синхронизировано"
    return 0
  fi
  if ! systemctl list-unit-files --no-legend systemd-timesyncd.service 2>/dev/null | grep . >/dev/null \
     && ! systemctl is-active --quiet chrony 2>/dev/null && ! systemctl is-active --quiet chronyd 2>/dev/null; then
    ensure_pkgs systemd-timesyncd
  fi
  run systemctl enable --now systemd-timesyncd || true
  run timedatectl set-ntp true || true
  if (( DRY_RUN )); then return 0; fi
  for i in $(seq 1 30); do
    if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null || true) == yes ]]; then ok "Время синхронизировано"; return 0; fi
    sleep 1
  done
  warn_note "Время пока не синхронизировано (проверьте: timedatectl status)."
}

step_hostname() {
  local new=${HOSTNAME_NEW-} cur short line tmp hline
  cur=$(hostname)
  if [[ -z $new ]]; then new=$cur; fi
  short=${new%%.*}
  if [[ $cur != "$new" ]]; then
    run hostnamectl set-hostname "$new"
    ok "Имя хоста: $new"
    note "Hostname: $cur -> $new."
  else
    ok "Имя хоста уже $new"
  fi
  line=$(awk '$1=="127.0.1.1"{print; exit}' /etc/hosts 2>/dev/null || true)
  if [[ -n $line ]]; then
    if ! awk -v n="$new" -v s="$short" '$1=="127.0.1.1"{for(i=2;i<=NF;i++) if($i==n||$i==s) f=1} END{exit !f}' /etc/hosts; then
      info "Исправляю строку 127.0.1.1 в /etc/hosts"
      if (( DRY_RUN )); then dry "заменить 127.0.1.1 на «$new $short»"; else
        tmp=$(mktemp)
        hline="127.0.1.1 $new"
        if [[ $new != "$short" ]]; then hline+=" $short"; fi
        awk -v nl="$hline" '!d && $1=="127.0.1.1"{print nl; d=1; next} {print}' /etc/hosts >"$tmp"
        cp -a /etc/hosts "$BACKUP_DIR/etc_hosts.$(date +%Y%m%d-%H%M%S)"
        cat "$tmp" >/etc/hosts
        rm -f "$tmp"
      fi
    fi
  elif ! getent hosts "$short" >/dev/null 2>&1; then
    info "Добавляю 127.0.1.1 в /etc/hosts"
    if (( DRY_RUN )); then dry "добавить «127.0.1.1 $new» в /etc/hosts"; else
      if [[ $new == "$short" ]]; then printf '127.0.1.1 %s\n' "$new" >>/etc/hosts; else printf '127.0.1.1 %s %s\n' "$new" "$short" >>/etc/hosts; fi
    fi
  fi
  if [[ -f /etc/cloud/cloud.cfg ]] && ! grep -rEq '^[[:space:]]*preserve_hostname:[[:space:]]*true' /etc/cloud/cloud.cfg /etc/cloud/cloud.cfg.d/ 2>/dev/null; then
    info "cloud-init: preserve_hostname: true (иначе имя вернётся после перезагрузки)"
    put_file /etc/cloud/cloud.cfg.d/99-do-first.cfg 644 <<'EOF'
# Управляется do-first.sh
preserve_hostname: true
EOF
  fi
  if grep -Eq '^[[:space:]]*manage_etc_hosts:[[:space:]]*true' /etc/cloud/cloud.cfg 2>/dev/null; then
    warn "cloud-init управляет /etc/hosts (manage_etc_hosts) — правки могут перезаписаться."
  fi
}

step_locale() {
  local loc=${LOCALE:-en_US.UTF-8} cs re
  if ! is_yes "${CONFIGURE_LOCALE-no}"; then info "Настройка локали не запрошена."; return 0; fi
  ensure_pkgs locales
  cs=UTF-8
  if [[ $loc == *.* ]]; then cs=${loc#*.}; cs=${cs%%@*}; fi
  re=${loc//./\\.}
  if (( DRY_RUN )); then dry "включить $loc $cs в /etc/locale.gen, locale-gen, update-locale LANG=$loc"; return 0; fi
  touch /etc/locale.gen
  if ! grep -Eq "^${re}[[:space:]]+${cs}" /etc/locale.gen; then
    if grep -Eq "^#[[:space:]]*${re}[[:space:]]+${cs}" /etc/locale.gen; then
      sed -i -E "s/^#[[:space:]]*(${re}[[:space:]]+${cs})/\1/" /etc/locale.gen
    else
      printf '%s %s\n' "$loc" "$cs" >>/etc/locale.gen
    fi
  fi
  run locale-gen
  run update-locale "LANG=$loc"
  ok "Локаль: $loc"
  note "Локаль: LANG=$loc (применится в новых сессиях)."
}

step_journald_logs() {
  local max=${JOURNAL_MAX:-200M}
  put_file /etc/systemd/journald.conf.d/99-do-first.conf 644 <<EOF
# Управляется do-first.sh
[Journal]
SystemMaxUse=$max
SystemMaxFileSize=20M
MaxRetentionSec=1month
EOF
  run systemctl restart systemd-journald
  run journalctl --vacuum-size="$max"
  ensure_pkgs logrotate
  put_file /etc/logrotate.d/do-first 644 <<'EOF'
/var/log/do-first.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF
  ok "journald ограничен $max; ротация лога do-first настроена"
}

step_swap() {
  local size=${SWAP_SIZE-} mb avail
  if in_container; then
    info "Контейнер ($(systemd-detect-virt -c 2>/dev/null || echo ?)) — swap настраивается хостом, пропускаю."
    return 0
  fi
  if [[ -n $(swapon --noheadings --show 2>/dev/null || true) ]]; then
    ok "Swap уже активен — создавать не нужно"
    swap_swappiness
    return 0
  fi
  if [[ -z $size ]] || [[ ${size,,} =~ ^(0|no|none|off|нет)$ ]]; then
    info "Swap не нужен по вашему выбору."
    return 0
  fi
  size=${size^^}
  case $size in
    *G) mb=$(( ${size%G} * 1024 )) ;;
    *M) mb=${size%M} ;;
  esac
  avail=$(df --output=avail -BM / 2>/dev/null | tail -n1 | tr -dc '0-9' || true)
  if [[ -n $avail ]] && (( avail < mb + 1024 )); then
    warn_note "Мало места на диске ($avail МБ) для swap $size — swap не создан."
    return 0
  fi
  if (( DRY_RUN )); then dry "создать /swapfile $size, mkswap, swapon, запись в fstab"; return 0; fi
  if [[ -e /swapfile ]]; then warn "/swapfile существует, но не активен — пересоздаю."; rm -f /swapfile; fi
  if ! fallocate -l "$size" /swapfile 2>>"$LOG"; then
    info "fallocate не поддерживается — создаю через dd (медленнее)"
    run dd if=/dev/zero of=/swapfile bs=1M count="$mb" status=none
  fi
  chmod 600 /swapfile
  run mkswap /swapfile
  if ! swapon /swapfile 2>>"$LOG"; then   # fallocate-файл может не подойти для swap на некоторых ФС
    info "swapon не принял файл, пересоздаю через dd"
    rm -f /swapfile
    run dd if=/dev/zero of=/swapfile bs=1M count="$mb" status=none
    chmod 600 /swapfile
    run mkswap /swapfile
    swapon /swapfile
  fi
  if ! grep -Eq '^[^#]*[[:space:]]/swapfile[[:space:]]' /etc/fstab; then
    printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
  fi
  ok "Swap $size создан и подключён"
  note "Swap: /swapfile $size."
  swap_swappiness
}
swap_swappiness() {
  if [[ -z $(swapon --noheadings --show 2>/dev/null || true) ]]; then return 0; fi
  put_file /etc/sysctl.d/99-do-first-swap.conf 644 <<'EOF'
# Управляется do-first.sh
vm.swappiness=10
EOF
  run sysctl -w vm.swappiness=10
}

step_sysctl() {
  local kv key conf=() skipped=()
  local list=(
    net.ipv4.tcp_syncookies=1
    net.ipv4.conf.all.accept_redirects=0
    net.ipv4.conf.default.accept_redirects=0
    net.ipv6.conf.all.accept_redirects=0
    net.ipv6.conf.default.accept_redirects=0
    net.ipv4.conf.all.send_redirects=0
    net.ipv4.conf.default.send_redirects=0
    net.ipv4.conf.all.accept_source_route=0
    net.ipv4.conf.default.accept_source_route=0
    net.ipv4.icmp_echo_ignore_broadcasts=1
    net.ipv4.icmp_ignore_bogus_error_responses=1
  )
  for kv in "${list[@]}"; do
    key=${kv%%=*}
    if [[ -e /proc/sys/${key//.//} ]]; then conf+=("$kv"); else skipped+=("$key"); fi
  done
  put_file /etc/sysctl.d/99-do-first.conf 644 < <(
    printf '%s\n' "# Управляется do-first.sh. Только безопасные значения."
    printf '%s\n' "# net.ipv4.ip_forward и rp_filter НЕ трогаем: VPN (AmneziaWG/WireGuard) настраивается отдельно."
    printf '%s\n' "${conf[@]}"
  )
  if (( ${#skipped[@]} )); then info "Нет в этом ядре/контейнере, пропущено: ${skipped[*]}"; fi
  run sysctl --system || warn "sysctl --system сообщил об ошибках (в контейнерах это нормально)"
  ok "Параметры ядра применены (${#conf[@]})"
}

step_disable_extra() {
  local u units
  if [[ $OS_ID != ubuntu ]]; then info "Не Ubuntu — шаг пропущен."; return 0; fi
  if ! is_yes "${DISABLE_EXTRA-no}"; then info "Отключение служб не запрошено."; return 0; fi
  units=$(present_extra_units)
  if [[ -z $units ]]; then ok "Лишних служб не найдено"; return 0; fi
  for u in $units; do
    if ! run systemctl disable --now "$u"; then warn "Не удалось отключить $u"; continue; fi
    case $u in
      snapd.*) run systemctl mask "$u" || true ;;
    esac
  done
  if [[ -f /etc/default/motd-news ]]; then
    if (( DRY_RUN )); then dry "ENABLED=0 в /etc/default/motd-news"; else sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news; fi
  fi
  if [[ -f /etc/default/apport ]]; then
    if (( DRY_RUN )); then dry "enabled=0 в /etc/default/apport"; else sed -i 's/^enabled=.*/enabled=0/' /etc/default/apport; fi
  fi
  ok "Отключены: $units"
  note "Отключены службы: $units (snapd замаскирован, пакеты не удалялись)."
}

step_docker() {
  local u=${NEW_USER-} arch
  if ! is_yes "${INSTALL_DOCKER-no}"; then info "Docker не запрошен."; return 0; fi
  [[ -n $OS_CODENAME ]] || die "Не удалось определить кодовое имя релиза для репозитория Docker."
  if [[ ! -e /etc/docker/daemon.json ]]; then
    put_file /etc/docker/daemon.json 644 <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
  fi
  if pkg_installed docker-ce; then
    ok "docker-ce уже установлен"
  else
    if pkg_installed docker.io; then warn "Установлен docker.io (конфликтует с docker-ce): удалите вручную при проблемах."; fi
    ensure_pkgs ca-certificates curl gnupg
    run install -m 0755 -d /etc/apt/keyrings
    run curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" -o /etc/apt/keyrings/docker.asc
    run chmod a+r /etc/apt/keyrings/docker.asc
    arch=$(dpkg --print-architecture)
    put_file /etc/apt/sources.list.d/docker.list 644 <<EOF
deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$OS_ID $OS_CODENAME stable
EOF
    aptg update
    aptg install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  run systemctl enable --now docker
  if [[ -n $u ]] && { id "$u" >/dev/null 2>&1 || (( DRY_RUN )); }; then
    run usermod -aG docker "$u"
    note "Пользователь $u добавлен в группу docker (войдите заново, чтобы применилось)."
  fi
  note "ВНИМАНИЕ: Docker публикует порты в обход ufw (-p 80:80 открыт всему интернету). Привязывайте к 127.0.0.1 или правьте цепочку DOCKER-USER."
  ok "Docker установлен"
}

step_cleanup() {
  aptg autoremove --purge
  aptg clean
  if reboot_required; then
    request_reboot "требуется перезагрузка для применения обновлений"
  fi
}

# ═══════════════════════════ итоговый отчёт ═══════════════════════════
final_report() {
  local id ip4 ip6 port u=${NEW_USER-} line p old
  ip4=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ' || true)
  ip6=$(ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ' || true)
  port=${SSH_PORT:-$(cur_ssh_ports)}
  say ""
  say "════════════════════ ИТОГ do-first $SCRIPT_VERSION ════════════════════"
  say "Шаги:"
  for id in "${STEPS[@]}"; do
    if step_is_done "$id"; then say "  [готово]  $id — ${STEP_TITLE[$id]-}"
    elif step_is_skipped "$id"; then say "  [пропуск] $id — ${STEP_TITLE[$id]-}"
    else say "  [ожидает] $id — ${STEP_TITLE[$id]-}"; fi
  done
  if [[ -s $NOTES_FILE ]]; then
    say ""
    say "Что сделано / замечания:"
    while IFS= read -r line; do say "  $line"; done <"$NOTES_FILE"
  fi
  say ""
  say "Хост:       $(hostname)"
  say "IPv4:       ${ip4:-нет}"
  say "IPv6:       ${ip6:-нет}"
  say "Пользователь: ${u:-(не создавался)}"
  say "Порт SSH:   ${port%% *}"
  old=""
  for p in ${OLD_SSH_PORTS-}; do if [[ " ${port} " != *" $p "* ]]; then old+="$p "; fi; done
  if [[ -n $old ]]; then
    say "Старые порты SSH ещё открыты в ufw: ${old}. После проверки нового входа закройте:"
    for p in $old; do say "    sudo ufw delete limit $p/tcp"; done
  fi
  say ""
  say "ВАЖНО: НЕ закрывайте эту сессию, пока не проверите вход во ВТОРОЙ сессии:"
  say "    ssh -p ${port%% *} ${u:-ПОЛЬЗОВАТЕЛЬ}@${ip4%% *}"
  say "Если вход не работает — исправьте через текущую сессию (бэкапы конфигов: $BACKUP_DIR)."
  if is_yes "${INSTALL_DOCKER-no}"; then say "Docker публикует порты в обход ufw — см. замечание выше."; fi
  if reboot_required; then
    say "Перезагрузка: ТРЕБУЕТСЯ (/var/run/reboot-required: $(tr '\n' ' ' </var/run/reboot-required 2>/dev/null))"
  else
    say "Перезагрузка: не требуется"
  fi
  say "Лог: $LOG"
}

# ═══════════════════════════ точка входа ═══════════════════════════
parse_args() {
  while (( $# )); do
    case $1 in
      -y|--yes)   ASSUME_YES=1 ;;
      --dry-run)  DRY_RUN=1 ;;
      -h|--help)  MODE=help ;;
      --list)     MODE=list ;;
      --reset)    MODE=reset ;;
      --resume)   RESUME=1; ASSUME_YES=1 ;;
      *) die "Неизвестный параметр: $1 (см. --help)" ;;
    esac
    shift
  done
}
check_root() {
  if (( EUID == 0 )); then return 0; fi
  if (( DRY_RUN )); then warn "Запуск не от root: --dry-run только показывает действия."; return 0; fi
  die "Скрипт нужно запускать от root: sudo bash $0 ...  (или curl -fsSL URL | sudo bash)"
}
init_log() {
  if (( DRY_RUN )); then LOG=/dev/null; LOG_ON=""; return 0; fi
  touch "$LOG"
  chmod 640 "$LOG"
  LOG_ON=1
  _log "──────── запуск do-first $SCRIPT_VERSION ($(date)) аргументы: ${ARGS_FOR_LOG-} ────────"
}
on_exit() {
  if (( DRY_RUN )); then return 0; fi
  if (( ! KEEP_UNIT )); then
    remove_resume_unit
    rm -f "$REBOOT_FLAG"
  fi
}
main() {
  ARGS_FOR_LOG="$*"
  parse_args "$@"
  case $MODE in
    help) usage; exit 0 ;;
    list) list_steps; exit 0 ;;
  esac
  check_root
  init_log
  if [[ $MODE == reset ]]; then
    if { true </dev/tty; } 2>/dev/null; then HAVE_TTY=1; fi
    do_reset
    exit 0
  fi
  if (( ! DRY_RUN )); then
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "do-first уже запущен (блокировка $LOCK_FILE)."
  fi
  if (( ! RESUME )) && { true </dev/tty; } 2>/dev/null; then HAVE_TTY=1; fi
  if (( RESUME )); then info "Продолжение настройки после перезагрузки (без вопросов)."; fi
  detect_os
  load_answers
  detect_ssh
  state_init
  trap on_exit EXIT
  collect_answers
  run_steps
  final_report
  if (( RESUME )); then _log "возобновлённая настройка завершена"; fi
}

if [[ -z ${DO_FIRST_LIB-} ]]; then   # DO_FIRST_LIB=1 — только загрузить функции (для тестов)
  main "$@"
  exit 0
fi
