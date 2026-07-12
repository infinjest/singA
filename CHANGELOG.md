# Changelog

Все значимые изменения фиксируются здесь.

---

## [0.10.3] — 2026-07-11

### Breaking / Removed

- **`route_mode=4` («всё в direct») удалён** — не имел уникальной логики, совпадал с общей веткой `else` (`final=direct`, без доп. правил маршрутизации/DNS). Убран из UI-select (`cfg-route-mode` теперь содержит только `1`/`2`/`3`).
- **Чекбокс «Балансировка URLTest» (`failover`) удалён** — `urltest`-группа (`proxy-auto`) теперь собирается безусловно при 2+ узлах (`#proxy_tags > 1`, без проверки UCI-флага). `install.sh` при апгрейде удаляет `singbox.main.failover` из существующих конфигов.

### Added

- **Тег активной ноды в шапке UI** — `get_active_node` (rpcd) запрашивает Clash API (`/proxies/proxy` через `wget` на `127.0.0.1:9090`).
- **`geosite:<категория>`** в поле доменов «Правила маршрутизации (Исключения)» (`custom_rule`, route_mode=3) — категория скачивается на лету в `add_rule` (rpcd) с `github.com/MetaCubeX/meta-rules-dat` в `/etc/sing-box/rule-sets/geosite-<категория>.srs`; `compiler` транслирует условие в `route.rule_set`/`dns.rule_set` по тегу `geosite-x-<категория>`.
- **Чекбокс «Запрос через прокси» для `dns_rule`** — новое поле `via_proxy`; `detour` персонального DNS-сервера больше не всегда `direct`.
- **`dns_remote_detour`** (UCI/UI, `direct`/`proxy`, дефолт `direct`) для upstream DNS-сервера `dns-remote`.
- **`dns.optimistic=true`** в компиляторе — включается автоматически только при `dns_remote_detour=="proxy"` (сглаживает лишний RTT в туннель при первом резолве).
- **Fallback в `update-rules.sh`**: при неудаче прямой закачки баз (`--local-port 57321-57325`) — повторная попытка через текущий прокси-узел (`--local-port 57330-57334`); правило `source_port_range={"57330:57334"} → outbound=proxy` первым в `route.rules`.
- `sb.route.rule_set` теперь собирается через `table.insert` с дедупликацией по тегу (`rule_set_seen`), а не перезаписывается присваиванием — позволяет одновременно иметь и гео-базу route_mode, и произвольные `geosite:`-категории из `custom_rule`.

### Fixed

- **`custom_rule` с единственным условием `geosite:<категория>`, чей `.srs`-файл отсутствовал на диске на момент компиляции**, превращался в route-правило без единого условия — матчило абсолютно весь трафик. Исправлено: при отсутствующем файле правило корректно пропускается (`logger` warning), `has_cond` не выставляется.
- **DNS-запросы LAN-клиентов к самому роутеру (dnsmasq на LAN-адресе) не перехватывались** — LAN-адрес роутера сам входит в `bypass_v4`/`bypass_v6`, запросы на порт 53 обходили hijack-dns стороной. Добавлен явный перехват `tcp/udp dport 53 → tproxy` в `prerouting`, размещённый до общих правил `daddr @bypass_v4/v6 return`.
- **`dns-remote` был жёстко закреплён на `detour="proxy"`** (`build_dns_server("dns-remote", custom_dns, "proxy", "dns-local")`) — резолвинг всегда шёл через прокси-узел без необходимости. Заменено на параметризуемый `dns_remote_detour` (см. Added), дефолт `direct`.
- **Гонка reload при «горячей» смене `route_mode`**: параллельные вызовы `reload_service()` могли столкнуться за `nftables`/`ip rule` внутри `init_routing()`. Добавлен `flock` (`/var/run/singbox-reload.lock`, неблокирующий `-n`) — параллельный вызов теперь безопасно пропускается вместо гонки за одни и те же nft-цепочки.
- **`.github/workflows/mirror-singbox.yml`**: в шаге «Prune older mirrored releases» после `gh release delete ...` добавлен `|| echo "::warning::Не удалось удалить релиз/тег ${OLD_TAG} (возможно, тег уже отсутствует)"` — ошибка удаления одного устаревшего mirror-релиза больше не роняет весь шаг цикла.
- **`compiler`: `dns_item.rule_set` и `rule_item.rule_set` для нового блока `geosite:`-исключений ссылались на один и тот же Lua-объект** — `json.stringify` (`luci.jsonc`) при повторной встрече уже сериализованной таблицы (сперва в `route.rules`, затем в `dns.rules`) писал `null` вместо массива тегов; DNS-правило теряло условие. Исправлено: `dns_item` получает независимую копию массива тегов (`table.insert` в новый массив вместо присваивания того же `rs_tags`).

### Known issues / требует доработки

- `build_dns_server` не поддерживает `host:port` в адресе DNS-сервера (`local_dns`/`custom_dns`) — понадобится для нестандартных портов (например AdGuard Home на 5353).

---

## [0.10.2] — 2026-07-05

### Breaking / Removed

- **`rdbypass` (бинарный флаг обхода) заменён на `route_mode` (1–4)**: 1 — всё в proxy, 2 — всё в proxy кроме РФ-доменов (`geosite-ru.srs`, MetaCubeX), 3 — обход РКН-блокировок (`ru-blocked.srs` + `geoip-ru-blocked.srs`, runetfreedom, дефолт), 4 — всё в direct. `install.sh` мигрирует существующие конфиги (`rdbypass=1` → `route_mode=3`, иначе → `route_mode=4`).
- **Смена пароля роутера (`change_password`) удалена** — как из `rpcd--singbox.lua` (RPC-метод и ACL), так и из `www--singbox.html` (карточка «Смена пароля шлюза»).
- **Вкладка «Дашборд» (iframe) удалена** из `www--singbox.html`.
- **`test.sh` разделён на `integrity-test.sh` и `compiler-test.sh`**, устанавливаются как `/usr/sbin/singbox-integrity-test` и `/usr/sbin/singbox-compiler-test`.

### Added

- **DNS-правила по доменам** (`dns_rule` в uci) — привязка кастомного DNS-сервера к конкретным доменам (например `tls://xbox-dns.ru` для `gemini.google.com`), применяется только в `route_mode=3`.
- **Кастомные исключения маршрутизации** (`custom_rule` в uci) — ручной override `outbound` (proxy/direct) по source/domain/ip, применяется только в `route_mode=3`.
- **Cron-расписание обновления баз** (`cron_schedule` в uci) — выбор из UI вместо свободного ввода cron-строки.
- Новые RPC-методы в `rpcd--singbox.lua`: `add_dns_rule`/`del_dns_rule`, `get_log`, `get_running_config`, `check_connectivity`.
- `status`: возвращает версию sing-box и дату последнего обновления баз (зависит от `route_mode`) — отображается в шапке UI.
- `uninstall.sh`: флаг `--purge` для полного удаления UCI-конфига (по умолчанию конфиг теперь сохраняется).
- UI: тосты на добавление/удаление правил и DNS-записей; выбор DNS/cron через select вместо свободного текста; кнопки «Проверить связь», «Скачать конфиг», «Лог»; viewport meta для мобильных экранов.

### Fixed

- **Режим 3, ложные срабатывания geoip-катча**: правило `{ rule_set = {"geosite-blocked","geoip-blocked"}, outbound="proxy" }` матчило по OR — легитимные российские домены (подтверждено на `vk.com`), чей резолвленный IP пересекается с диапазонами `geoip-ru-blocked.srs`, ошибочно уходили в proxy. Исправлено: правило разбито на два — `geosite-blocked` матчит по домену как раньше; `geoip-blocked` теперь оформлено как `logical`/`and` с `protocol = {tls,http,quic}, invert=true`, то есть срабатывает только когда sniff не смог опознать домен. Решение использует исключительно данные runetfreedom, без данных MetaCubeX/режима 2. Подтверждено через Clash API (`/connections`, поле `chains`) на нескольких доменах.
- `update-rules.sh` полностью переписан: атомарная загрузка через temp-файл, валидация по magic-байтам (`SRS`/`PK` через `head -c`, не `od` — BusyBox даёт другой вывод), никогда не затирает рабочий файл при неудачной загрузке. Устранён краш-луп sing-box в режиме 2 («TProxy port not bound»), вызванный битым/HTML-мусором вместо `.srs` из-за отсутствия `-f` в curl. Исправлен неверный URL режима 2: файл называется `category-ru.srs`, а не `ru.srs` (404).
- `compiler`: legacy DNS-формат → новый формат sing-box 1.12+ (`dns.servers[].type/server`).
- `compiler`: deprecated outbound DNS rule item → `route.default_domain_resolver`.
- `compiler`: убрана мёртвая переменная `rdbypass`.
- `compiler`: `db_mtime`/`db_label` зависят от route_mode, берутся через `date -r` вместо несуществующего `geoip.db`.
- `compiler`: исправлен Lua multi-return баг в `gsub()` без скобок, из-за которого `add_dns_rule` падал без ответа.
- `compiler`: DNS-правило для `gemini.google.com` — протокол исправлен на `tls://` вместо `https://.../dns-query`.
- `compiler`: `custom_rule`/`dns_rule` гарантированно применяются только при `route_mode=3` (устранено расхождение backend/UI).
- `rpcd`: `set_settings` — allowlist разрешённых ключей вместо записи произвольных полей из запроса.
- `rpcd`: `update_sub` — сброс DNS-кэша (`dnsmasq restart`) после обновления, иначе правила по `domain_suffix` не применяются к уже закэшированным резолвам.
- UI: кнопка dirty-state — `loadData()` вызывала не ту функцию, оставалась оранжевой при загрузке.
- UI: автофокус на поле пароля.
- UI: карточка «Правила маршрутизации (Исключения)» скрыта при `route_mode ≠ 3`.
- `check_connectivity`: BusyBox `wget -q` глушил вывод — переписано на проверку exit-кода.
- `compiler-test.sh` проходит 4/4 (фикс detour DNS-серверов, порядок режимов в тесте 1→2→4→3).

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