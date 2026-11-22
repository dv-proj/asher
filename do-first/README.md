# do-first — первичная настройка VPS

[RUS](README.md) [ENG](README-EN.md)

`do-first.sh` настраивает свежий headless-сервер на Ubuntu или Debian: обновляет систему, создаёт пользователя, закрывает SSH, включает firewall и автообновления. Скрипт запускается на самом сервере от root.

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/dv-proj/asher/main/do-first/do-first.sh | sudo bash
```

Вопросы скрипт задаёт через терминал (`/dev/tty`), поэтому запуск через конвейер работает. Чтобы сначала прочитать скрипт:

```bash
curl -fsSLO https://raw.githubusercontent.com/dv-proj/asher/main/do-first/do-first.sh
sudo bash do-first.sh
```

Без вопросов, с заранее заданными ответами:

```bash
curl -fsSL https://raw.githubusercontent.com/dv-proj/asher/main/do-first/do-first.sh | sudo NEW_USER=admin USER_PASSWORD=... SSH_PUBKEY=github:myname TIMEZONE=Europe/Moscow bash -s -- --yes
```

## Шаги

| Шаг | Что делает |
|---|---|
| `preflight` | проверяет root, ОС, сеть, текущие настройки SSH |
| `apt_upgrade` | `apt update/upgrade`; при необходимости перезагрузка |
| `packages` | базовые утилиты (список в `BASE_PACKAGES`) |
| `user` | пользователь с sudo, пароль для нового пользователя запрашивается всегда |
| `ssh_key` | ключ(и) в `authorized_keys`: строка, `github:<user>` или URL |
| `ssh_harden` | отключение входа по паролю, по желанию — входа root и смена порта |
| `firewall` | ufw: запрет входящих, SSH с лимитом, свои порты |
| `fail2ban` | защита sshd от перебора |
| `unattended` | автообновления безопасности, по желанию автоперезагрузка |
| `timezone_time` | часовой пояс и синхронизация времени |
| `hostname` | имя хоста, `/etc/hosts`, cloud-init |
| `locale` | по желанию |
| `journald_logs` | лимит журнала, logrotate |
| `swap` | swap-файл, если swap нет (размер запрашивается, по умолчанию 512M) |
| `sysctl` | безопасные параметры ядра (`ip_forward` и `rp_filter` не трогаются — VPN настраивается отдельно) |
| `disable_extra` | отключение лишних служб Ubuntu (snapd и др.) |
| `docker` | по желанию, из официального репозитория |
| `cleanup` | `autoremove`, `clean`, проверка перезагрузки |

Список шагов и их статус: `do-first.sh --list`.

## Безопасность SSH

- Вход по паролю отключается, только если у пользователя есть валидный ключ, работает sudo и права на `authorized_keys` правильные. Иначе скрипт предупреждает и пропускает изменение.
- Конфиг пишется в `/etc/ssh/sshd_config.d/99-do-first.conf`, проверяется `sshd -t` и `sshd -T`; при ошибке бэкапы восстанавливаются.
- При смене порта он сначала открывается в ufw. Старый порт остаётся открытым, пока вы не проверите вход.
- **Не закрывайте текущую сессию, пока не проверите вход новым пользователем во второй.**

## Перезапуск и перезагрузка

Состояние лежит в `/var/lib/do-first/`: выполненные шаги (по ID) и сохранённые ответы (права 600). Повторный запуск продолжает с первого невыполненного шага и ничего не спрашивает повторно. Если нужна перезагрузка, скрипт ставит одноразовый systemd-юнит `do-first-resume.service`, и настройка продолжается после загрузки. Лог: `/var/log/do-first.log`.

## Параметры

| Параметр | Значение |
|---|---|
| `--yes`, `-y` | принять значения по умолчанию |
| `--dry-run` | показать действия, ничего не менять |
| `--list` | показать шаги и статус |
| `--reset` | забыть состояние |
| `--help` | справка |

Переменные окружения (ответы на вопросы):

- пользователь и SSH: `NEW_USER`, `USER_PASSWORD`, `SET_PASSWORD` (только для существующего пользователя), `SSH_PUBKEY`, `DISABLE_PASSWORD_AUTH`, `DISABLE_ROOT_SSH`, `SSH_PORT`
- firewall и fail2ban: `UFW_EXTRA_PORTS`, `IGNORE_IPS`
- автообновления: `AUTO_REBOOT`, `AUTO_REBOOT_TIME`, `UPGRADE_UPDATES`
- система: `TIMEZONE`, `HOSTNAME_NEW`, `CONFIGURE_LOCALE`, `LOCALE`, `JOURNAL_MAX`, `SWAP_SIZE`, `DISABLE_EXTRA`, `INSTALL_DOCKER`
- прочее: `ALLOW_REBOOT`, `BASE_PACKAGES`, `SKIP_STEPS`, `SCRIPT_URL`

## Как добавить свой шаг

Напишите функцию `step_<id>` и вставьте `<id>` в массив `STEPS` в нужное место. Выполненные шаги отслеживаются по ID, поэтому вставка в середину не ломает состояние. Подробности — в комментарии у реестра шагов в скрипте.

## Ограничения

- Docker публикует порты в обход ufw.
- Скрипт проверен на синтаксис и в режиме `--dry-run`; на реальных серверах проверьте его на тестовой машине.

## Ответственность

Скрипт меняет настройки SSH и firewall. Проверьте его на тестовой машине, прежде чем запускать на рабочей.
