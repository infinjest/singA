# Changelog

Все значимые изменения фиксируются здесь.

---

## [0.9.10] — 2026-06-13

### Fixed
- **initd:** `/var/run/sing-box/sub_cache` создаётся в `start_service()` — после перезагрузки симлинк `sub_cache → tmpfs` не висит в воздухе
- **initd:** `reload_service` переписан: `procd_send_signal HUP` заменён на встроенный рестарт procd — sing-box не поддерживает горячую перезагрузку по SIGHUP
- **initd:** `init_routing` вызывается асинхронно (`&`) — ожидание порта не блокирует загрузку системы
- **initd:** `_port_bound` использует `grep -qE ":${1}[^0-9]"` — корректно парсит IPv6-формат вывода `ss` в BusyBox
- **compiler:** генерация блока `rule_set` пропускается если `ru-blocked.srs` отсутствует на диске — устраняет падение ядра при `rdbypass=1` до первого запуска `update-rules.sh`
- **compiler:** `bootstrap_address = "local_dns"` добавлен к серверу `dns-remote` — устраняет дедлок резолвинга при перехвате DNS провайдером
- **rpcd:** `echo` заменён на `printf 'root:%s\n'` в `change_password` — `echo` в BusyBox интерпретирует `-e`/`-n` как флаги, обрезая пароль
- **install:** проверка свободного места в `/overlay` перед скачиванием бинарника (минимум 30 MB)
- **install:** `rm -rf` перед `ln -sf` для симлинка `sub_cache` — при переустановке симлинк корректно заменяется, а не вкладывается внутрь существующей директории
- **install:** создание директорий `/var/run/sing-box/…` убрано — ответственность делегирована в `initd`
- **install:** симлинк для `rules` убран — SRS-базы остаются в `/etc/sing-box/` напрямую (перезапись раз в неделю, износ Flash пренебрежим)
- **uninstall:** `ip rule del fwmark 0x100 table 100` вместо `ip rule del table 100` — зеркалит синтаксис `initd`, надёжно работает на BusyBox iproute2
- **uninstall:** `ip route del local default dev lo table 100` — точный синтаксис вместо обобщённого
- **uninstall:** путь Web UI исправлен: `rm -rf /www/singbox` вместо `rm -f /www/singbox.html`
- **uninstall:** добавлено самоудаление скрипта (`rm -f "$0"`)
- **test:** `local_dns` добавлен в список проверяемых UCI-ключей

### Added
- `uninstall.sh` — полное бесследное удаление: nftables, iproute2, UCI, бинарники, Web UI, cron
- `CHANGELOG.md`
- `.github/ISSUE_TEMPLATE/bug_report.yml` и `feature_request.yml` — GitHub Forms для issues

---

## [0.9.9] — 2026-06-12

### Fixed
- **acl:** `edit_node` добавлен в write-права RPcd ACL — `toggleNode`/`saveEditNode` тихо отклонялись
- **spa:** CSS-класс `.toggle-off` корректно применяется к кнопке отключённого узла (был пустой класс)
- **spa:** `openEditModal` заполняет поля `jc/jmin/jmax/s1/s2/h1–h4` для AmneziaWG-узлов — без этого `save` стирал параметры обфускации через `uci:delete`
- **spa:** блок `edit-amnezia-params` скрывается для узлов типа `wireguard` в edit-модале
- **spa+uci:** поле Local DNS добавлено в форму настроек; значение сохраняется в UCI (`singbox.main.local_dns`); дефолт добавлен в UCI-defaults в `install.sh`
- **compiler:** PID читается через `awk '/^Pid:/'` из `/proc/self/status` вместо subshell `echo $$`
- **sub-updater:** wireguard-узлы не получают AWG-поля (`jc/jmin/jmax` и др.) в JSON-кеше
- **install:** `SB_REPO` заменён на зеркало `infinjest/singA`
- **install:** суффикс `-compressed` добавлен в `TARBALL_URL` (формат архива зеркала)