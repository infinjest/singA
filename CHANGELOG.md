# Changelog

Все значимые изменения фиксируются здесь.

---

## [0.10.1] — 2026-06-28

### Breaking

- Ядро заменено: **shtorm-7/sing-box-extended → Leadaxe/sing-box-lx** (v1.13.13-lx.15).  
  Причина: extended некорректно обрабатывал H1–H4 как Range — при генерации ответного handshake
  сервер выбирал случайное значение из диапазона, клиент ожидал фиксированное начало диапазона →
  `received invalid response message`, туннель не поднимался.  

### Fixed

- `compiler`: AmneziaWG-блок переписан под плоскую схему sing-box-lx (поля `jc/jmin/jmax/s1/s2/h1–h4` напрямую на endpoint, без вложенного `amnezia: {}`).
- `compiler`: `system: false` — при vanilla wireguard в ядре `system: true` передавал AWG-параметры через UAPI в ядро, ядро их игнорировало, обфускация не работала.
- `compiler`: `h1–h4` передаются строками-диапазонами (`"N-M"`) — lx принимает нативно.
- `compiler`: добавлен `detour: "direct"` на AWG endpoint — UDP уходит через WAN, не заворачивается в TPROXY.
- `compiler`: добавлен `route.auto_detect_interface: true` — устраняет `override-gateway: invalid IP`.
- `rpcd`: `add_node` / `edit_node` — поля `s3`, `s4`, `pre_shared_key` добавлены в `allowed`; ранее молча выбрасывались при сохранении в UCI.
- `rpcd`: `apply` при `enabled=0` — теперь останавливает sing-box вместо reload; ранее сервис оставался жить со старым конфигом.
- `install`: убран `iproute2-ss` из `PKGS` — пакет отсутствует в arm64 apk-репозитории.
- `install`: обновлён `TARBALL_URL` под именование lx-архивов (без суффикса `-compressed`).
- `mirror workflow`: обновлён upstream `shtorm-7/sing-box-extended → Leadaxe/sing-box-lx`; именование ассетов приведено в соответствие; расписание сокращено с каждые 6 ч до раз в сутки; убран `linux-armv7` из списка архитектур.

### Added

- `compiler`: поля `s3`, `s4` (AWG 2.0 — junk-padding для cookie-reply и transport-сообщений).
- `compiler`: поля `i1–i5` (CPS decoy packets, AWG 2.0).
- `compiler`: `pre_shared_key` в `peers[0]` — поддержка PSK из UCI.
- `singbox.html`: импорт `.vpn` — парсинг `S3`/`S4` из `awg.S3`/`awg.S4`; `pre_shared_key` из `last_config.psk_key`.
- `singbox.html`: импорт `.conf` — парсинг `s3`, `s4`, `PresharedKey`.
- `singbox.html`: edit-модал — поля `s3`, `s4`, `Pre-Shared Key`.

### Changed
- `README`: переписан и сокращен для лучшей читаемости.

---

## [0.10.0] — 2026-06-ХХ

> **Breaking:** требует sing-box-extended ≥ 1.13.0

### Fixed
- `compiler`: убраны deprecated-поля `sniff`/`sniff_override_destination` из inbound (удалены в 1.13), action = "sniff" добавлен в route.rules
- `compiler`: убран outbound `dns-out` (удалён в 1.13); DNS-перехват переведён на `action = "hijack-dns"`
- `compiler`: `log.level = "disabled"` → `"info"` (значение "disabled" удалено в 1.13)
- `compiler`: добавлен `x_padding_bytes = "100-1000"` для xhttp-транспорта (обязательно в 1.13)
- `initd`: `procd_set_param env` — объединены три ENABLE_DEPRECATED_* в один вызов (множественные вызовы перезатирают друг друга в procd)
- `install`: debug-вывод curl убран, восстановлен `curl -sL ... || die`
- `install`: добавлен `touch /etc/config/singbox` перед `uci batch` (без файла UCI возвращает "Entry not found")
- `install`: `uhttpd.singbox.ubus_prefix='/ubus'` — без этого SPA получала 404 на `/ubus`
- `install`: `LAN_IP` — добавлен `cut -d/ -f1` (uci возвращал адрес с маской)
- `update-rules.sh`: полностью переписан — upstream прекратил публикацию `.srs` напрямую; теперь скачивается `sing-box.zip` из `runetfreedom/russia-v2ray-rules-dat`, нужные файлы извлекаются через `unzip`

### Added
- `install`: зависимости `kmod-nft-socket lua luac libuci-lua libubus-lua unzip` (без них проект не функционировал на apk-сборках)
- `test`: проверка `kmod-nft-socket`
- `src/www--singbox.html`: фикс импорта `.vpn` — поддержка base64url + deflate/deflate-raw (формат AmneziaVPN)
- `uninstall`: добавлен опциональный блок удаления пакетов, установленных singA (`lua`, `luac`, `libuci-lua`, `libubus-lua`, `unzip`, `kmod-nft-socket`)

### Changed
- `README`: таблица оборудования — убрана, добавлена информация о целевом железе и ПО
- `README`: исправлена неверная формулировка про tmpfs-хранение баз РКН
- `README`: добавлен источник правил (`runetfreedom/russia-v2ray-rules-dat`) в таблицу стека
- `README`: секция "Отличие от podkop" — убраны недоказуемые claims (ТСПУ-эвристика, "Полная совместимость")
- `README`: добавлены `<details>`-блоки с архитектурой и структурой файлов

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