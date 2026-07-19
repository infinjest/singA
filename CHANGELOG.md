# Changelog

Все значимые изменения фиксируются здесь.

---

## [0.10.5] — 2026-07-16

### Breaking

- `block_dot`: дефолт `1` действует и на апгрейде, не только для новых установок — `uci -q get singbox.main.block_dot || echo 1` трактует отсутствие ключа как «включено». LAN-клиенты, ходившие в публичный DNS-резолвер напрямую, откатятся на обычный DNS. Отключить: `uci set singbox.main.block_dot=0`.
- `block_quic`: дефолт `1` (QUIC заблокирован) действует и на апгрейде — миграция явно прописывает `block_quic=1` в UCI существующих конфигов (в отличие от `block_dot`, здесь это структурное правило в `route.rules` sing-box, а не только nft-надстройка). Приложения, успешно использовавшие QUIC через туннель, откатятся на TCP/HTTP2. Отключить: `uci set singbox.main.block_quic=0`.
- `compiler`: `dns.strategy=ipv4_only` — узел с AAAA-only hostname (без A-записи) перестанет резолвиться; обход — IP-литерал в поле `server`.

### Added

- `compiler`: `dns.strategy=ipv4_only` — nft-маршрутизация IPv4-первична, IPv6-правила best-effort (`|| true`); AAAA-ответ мог увести соединение в обход tproxy незаметно.
- `initd`: `block_dot` (UCI, дефолт `1`) — reject известных публичных DNS-резолверов (Cloudflare/Google/Quad9/AdGuard/OpenDNS/Яндекс/AliDNS/CleanBrowsing/NextDNS) по IP, один nft-сет `known_resolvers_v4`/`_v6` (по образцу `bypass_v4/v6`), правило после bypass-return — LAN/bypass-адреса не блокируются. Режет DoT/DoQ/DoH/любой порт на этих IP независимо от видимости SNI, переживает ECH. `reject`, не `drop` — клиент сразу видит отказ и откатывается на обычный DNS.
- `compiler`/`rpcd`/`www--singbox.html`: `block_quic` (UCI, секция `main`, дефолт `1`) — при включении вставляет `{ protocol = "quic", action = "reject", method = "default" }` в `route.rules` сразу после `{ action = "sniff" }`. Часть QUIC/HTTP3-first клиентов (заметно на Android) плохо переживает QUIC поверх туннеля и подвисает вместо чистого фолбэка на TCP; `reject` (не `drop`) заставляет клиента откатиться сразу. Чекбокс в UI рядом с `dns_remote_detour`; whitelisted в `rpcd.set_settings`.
- `compiler`: `o.packet_encoding = "xudp"` на VLESS-outbound — без этого UDP-relay через узел (не только QUIC) отключён в sing-box по умолчанию и не поднимается вообще. Актуально для любого UDP-трафика через тоннель, и в частности для QUIC, если пользователь отключит `block_quic`. Требует поддержки xudp на сервере (практически все современные Xray-core/sing-box ноды её имеют); альтернатива при отсутствии поддержки — `packetaddr` (IPv4-only, не новое ограничение — проект и так работает с `dns.strategy=ipv4_only`).
- `/usr/sbin/singbox-logtail` (генерируется через `cat << EOF` в `install.sh`, а не отдельным `src`-файлом — см. Fixed ниже): читает stdin построчно, держит кольцевой буфер последних 100 строк вывода sing-box в памяти, на каждой строке перезаписывает `/var/run/sing-box_log.txt` целиком (tmpfs — без износа флэша) и пробрасывает строку дальше на свой stdout без изменений, чтобы `procd` продолжал видеть тот же поток и писать его в syslog как раньше. ANSI escape-коды из логгера sing-box вырезаются только при записи в файл (проброс на stdout остаётся сырым, чтобы не менять поведение logread/syslog). Подключается через `initd` (`... 2>&1 | singbox-logtail`).
- `rpcd`: `get_log` читает `/var/run/sing-box_log.txt` напрямую вместо `logread -e sing-box | tail -50`; fallback на старый `logread`-вариант, если файла ещё нет (сервис только что стартовал) — с той же вырезкой ANSI-кодов.
- `www--singbox.html`: `showLog()` — модальное окно (по образцу `.modal-overlay`/`.modal`, шире, моноширинный `<pre>` на ~100 строк) вместо нативного `alert(r.log)`; кнопки «Обновить» (лог не пушится в реальном времени, только по запросу) и «Скопировать в буфер».
- `compiler`: `dns.independent_cache=true` вместе с `dns.optimistic` при `dns_remote_detour=proxy` — без него гонка кэша между "отдать протухший" и "обновить в фоне".
- `validate.lua`/`compiler`: `host:port` и путь после `/` в адресах DNS-серверов (`custom_dns`, `local_dns`, `dns_rule.server`) — общий парсер `validate.parse_dns_addr`, используется и `rpcd`, и `compiler`.
- `compiler`: `KNOWN_DNS_SNI` — авто-SNI/Host для голых IP нескольких известных резолверов (Yandex/AdGuard/Cloudflare/Google), на случай ручного ввода DoT/DoH-адреса без домена.
- `src/lib--singbox-validate.lua` → `/usr/lib/singbox/validate.lua`: общая валидация (адрес DNS-сервера, список доменов вкл. `geosite:<категория>`, список IP/CIDR, cron-строка); подключена в `rpcd` (`add_rule`, `add_dns_rule`, `set_settings`, `add_node`/`edit_node`) и в `compiler` (defense-in-depth).
- `compiler`: невалидный `source`/`ip` в `custom_rule` пропускается с `logger`-предупреждением вместо падения sing-box при старте.
- `www--singbox.html`: статический список `geosite:<категория>` (~45 популярных) для автодополнения поля «Домены», без обращения к сети.

### Changed

- `compiler`: `local_dns` дефолт Яндекс `77.88.8.8` → Cloudflare `1.1.1.1` (новые установки; существующие конфиги не трогаются — install.sh всегда писал явное значение).
- `compiler`: `dns_remote_detour` остаётся `direct` по умолчанию. В процессе подготовки 0.10.5 рассматривалась смена на `proxy` (провайдеры всё чаще режут сам DoH/DoT-эндпоинт) — решение отменено до релиза: раз `local_dns` теперь тоже Cloudflare, риск блокировки конкретно этого DoH-эндпоинта ниже, а лишний RTT в туннель того не стоит. `dns.optimistic`/`independent_cache` по-прежнему включаются автоматически, если кто-то вручную выставит `proxy`.
- `www--singbox.html`: селект `local_dns` — Cloudflare `1.1.1.1` теперь первая/дефолтная опция; селект `dns_remote_detour` — «Напрямую» теперь первая/дефолтная опция; placeholder custom DNS обновлён под `host:port/path`.
- `www--singbox.html`: placeholder поля «IP назначения» (исключения маршрутизации) → «Пусто, если заданы домены».
- `www--singbox.html`: placeholder поля «Домены» (исключения маршрутизации) → `user.papervpn.lol, geosite:google-gemini`.

### Fixed

- **`initd`: кнопка «Выключить прокси» могла не выключать прокси, а включение/переключение узла — не применяться.** `sing-box` запускался обёрнутым в `sh -c "... | singbox-logtail"`, из-за чего `procd` трекал PID шелл-обёртки, а не сам `sing-box`; при потере сигнала оба процесса могли пережить `stop`/`restart` осиротевшими и продолжать маршрутизировать трафик в обход выключенного через UI прокси. **Исправлено:** `sing-box` теперь запускается напрямую под `procd`, без пайпа; `singbox-logtail` вынесен в отдельный независимый procd-инстанс, а `stop_service` дополнительно подчищает осиротевшие процессы по обеим известным командным строкам. Подробности и обоснование — в комментариях `initd--sing-box.sh` (`start_service`/`stop_service`).
- `singbox-logtail`/`rpcd.get_log`: `strip_ansi` вырезал только SGR/цветовые коды вида `ESC[<цифры/;>m` — курсорные и erase-line последовательности (`ESC[?25l`/`ESC[?25h`, `ESC[2K` и т.п.), которые sing-box шлёт вокруг стартового баннера даже при запуске с `--disable-color`, проходили насквозь и оседали мусором в `/var/run/sing-box_log.txt` и в модалке лога. Паттерн заменён на разбор общей грамматики CSI-последовательностей (`ESC '[' <параметры 0-9;:<=>?> <финальная буква>`), плюс вырезаются одиночные `\r`, оставшиеся от erase-line-редроу. Поскольку доверять `--disable-color` в источнике нельзя, вырезка теперь безусловная на стороне логтейла/rpcd независимо от того, что реально прислал sing-box.
- `install.sh`/`initd`: `src/sbin--singbox-logtail.lua` убран как отдельный файл — генерируется через `cat << EOF` прямо в `install.sh` (шаг «[4/8]», рядом с остальными `deploy_utility`), тем же способом, что уже применялся для RPCD ACL и UCI-дефолтов ниже по файлу. Меньше файлов, которые надо синхронизировать между `src/`, GitHub raw-фолбэком в `deploy_utility` и локальным чекаутом. Заодно (см. пункт выше про orphan-процессы) сменил источник данных: раньше сидел в stdout самого `sing-box`, теперь — отдельный procd-инстанс поверх `logread -f -e sing-box`.
- `www--singbox.html`: `showLog()` показывал лог нативным браузерным `alert()` — малоинформативно и не копируется. Заменён на модальное окно, см. Added.
- `www--singbox.html`: `addDnsRule` не проверял ответ `add_dns_rule` на ошибку — показывал «добавлено» даже при отклонении.
- `www--singbox.html`: `saveSettings` игнорировал ошибку `set_settings` и всё равно вызывал `apply` — невалидный ввод молча отбрасывался, а UI сообщал об успехе.
- `compiler`: `build_dns_server` молча отбрасывал путь после `/` в адресе DNS-сервера — совпадало с дефолтным путём sing-box только случайно. Переиспользует `validate.parse_dns_addr` вместо второго парсера того же формата.
- `compiler`: закомментирован `e.detour = "direct"` для amneziawg-эндпоинта — на железе с ним sing-box падал с `outbound detour not found: direct`, узел не поднимался.
- Финальная вычитка перед пушем: TLS-проверка сертификата при скачивании подписок (`sub-updater` больше не ходит с `curl -k`), полное экранирование JSON-полей в парсере подписок, `compiler-test.sh` больше не триггерит реальный reload с тестовыми узлами на уже запущенном роутере (`update-rules.sh --no-reload`), `install.sh` честно требует arm64 вместо тихого падения на amd64/armv7, плюс мелкая правка `uninstall.sh`/`update-rules.sh`.

### Removed

- `rpcd`/`compiler`: `set_rules` (`force_proxy`/`force_direct`) — не имел UI, нигде не документировался и не пересекался корректно с `geosite:`-категориями. Функциональность полностью покрывается `custom_rule` (маршрутизация route_mode=3).

---

## [0.10.4] — 2026-07-12

### Fixed

- `initd`: `reload` мог не перезапускать sing-box — `procd` сравнивал только параметры инстанса (не меняются между reload'ами), оставляя старый процесс со старым конфигом в памяти. Добавлен `procd_set_param file "$RUN_CONFIG"` — procd отслеживает сам файл.
- `initd`: самоподдерживающаяся цепочка reload'ов — `start_service()` форкала фоновый `(sub-updater; reload)` при тёплом кэше, а `reload_service()` сама вызывает `start_service()`, порождая новый job на каждый reload. Ограничено флагом `/var/run/singbox-bg-synced`.

### Added

- `www--singbox.html`: кнопка «Включить/выключить все узлы» на вкладке «Узлы и Подписки».

### Changed

- `www--singbox.html`: режим 1 — блок «Обновление баз» скрыт (geosite/geoip не используются), уведомление без упоминания баз.
- `www--singbox.html`: таблица узлов — колонка «Тип» → «Протокол» (`amneziawg`→`amneziaWG2`, `vless`→`vless-<transport>-<security>`); 2-й и 3-й октет IP сервера маскируются звёздочками; длинный тег обрезается до хвоста после `#`/`@`.
- `www--singbox.html`: кнопка «Поделиться» — убрана попытка записи в буфер обмена (`navigator.clipboard` требует HTTPS, UI отдаётся по HTTP — не работало, хотя заявлялось); теперь только скачивание файла.

### Removed

- `www--singbox.html`: мёртвый код колонки Latency (`latencyBadge`, `refreshLatencyInTable`, `latencyMap`) — значение всегда было заглушкой «—».

---

## [0.10.3] — 2026-07-11

### Breaking

- `compiler`/`www--singbox.html`: `route_mode=4` («всё в direct») удалён — совпадал с общей веткой `else`; UI-select теперь только 1/2/3.
- `compiler`/`install`: чекбокс «Балансировка URLTest» (`failover`) удалён — `urltest`-группа собирается безусловно при 2+ узлах; апгрейд удаляет `singbox.main.failover` из существующих конфигов.

### Added

- `rpcd`/`www--singbox.html`: тег активной ноды в шапке UI — `get_active_node` запрашивает Clash API (`/proxies/proxy`, `127.0.0.1:9090`).
- `rpcd`/`compiler`: `geosite:<категория>` в доменах исключений (`custom_rule`, route_mode=3) — категория скачивается на лету в `add_rule` из `MetaCubeX/meta-rules-dat`, транслируется в `route.rule_set`/`dns.rule_set`.
- `rpcd`/`www--singbox.html`: чекбокс «Запрос через прокси» для `dns_rule` (`via_proxy`) — detour персонального DNS-сервера больше не всегда `direct`.
- `compiler`: `dns_remote_detour` (UCI/UI, `direct`/`proxy`, дефолт `direct`) для upstream `dns-remote`.
- `compiler`: `dns.optimistic=true`, включается только при `dns_remote_detour=proxy`.
- `update-rules.sh`/`compiler`: fallback при неудаче прямой закачки баз — повтор через прокси-узел (`--local-port 57330-57334`), правило `source_port_range` первым в `route.rules`.
- `compiler`: `sb.route.rule_set` собирается через `table.insert` с дедупликацией по тегу вместо перезаписи — совместимо с одновременной гео-базой route_mode и произвольными `geosite:`-категориями.

### Fixed

- `compiler`: `custom_rule` с единственным условием `geosite:<категория>`, чей `.srs` отсутствовал на диске, матчил весь трафик — теперь пропускается с `logger`-предупреждением.
- `initd`: DNS-запросы LAN-клиентов к самому роутеру не перехватывались (LAN-адрес роутера входит в `bypass_v4/v6`) — добавлен явный `tcp/udp dport 53 → tproxy` до bypass-правил.
- `compiler`: `dns-remote` был жёстко закреплён на `detour=proxy` — заменено параметризуемым `dns_remote_detour`.
- `initd`: гонка reload при смене `route_mode` — добавлен неблокирующий `flock` (`/var/run/singbox-reload.lock`).
- `.github/workflows/mirror-singbox.yml`: ошибка `gh release delete` для одного устаревшего релиза роняла весь шаг — добавлен `|| echo "::warning::..."`.
- `compiler`: `dns_item.rule_set`/`rule_item.rule_set` ссылались на один Lua-объект — `json.stringify` писал `null` при повторной сериализации, DNS-правило теряло условие. `dns_item` получает независимую копию массива тегов.

### Known issues

- `compiler`: `build_dns_server` не поддерживал `host:port` в адресе DNS-сервера (например, AdGuard Home на `5353`) — решено в 0.10.5.

---

## [0.10.2] — 2026-07-05

### Breaking

- `compiler`/`install`: `rdbypass` (бинарный флаг) заменён на `route_mode` (1–4): 1 — всё в proxy, 2 — всё в proxy кроме РФ-доменов (`geosite-ru.srs`), 3 — обход РКН (`ru-blocked.srs`+`geoip-ru-blocked.srs`, дефолт), 4 — всё в direct. Апгрейд мигрирует `rdbypass=1→route_mode=3`, иначе `→route_mode=4`.
- `rpcd`/`www--singbox.html`: смена пароля роутера (`change_password`) удалена (RPC-метод, ACL, карточка UI).
- `www--singbox.html`: вкладка «Дашборд» (iframe) удалена.
- `test`: `test.sh` разделён на `integrity-test.sh`/`compiler-test.sh` (`/usr/sbin/singbox-integrity-test`, `/usr/sbin/singbox-compiler-test`).

### Added

- `compiler`/`rpcd`/`www--singbox.html`: DNS-правила по доменам (`dns_rule`) — кастомный DNS-сервер для конкретных доменов (route_mode=3).
- `compiler`/`rpcd`/`www--singbox.html`: кастомные исключения маршрутизации (`custom_rule`) — override `outbound` по source/domain/ip (route_mode=3).
- `www--singbox.html`: cron-расписание обновления баз (`cron_schedule`) — выбор из UI вместо свободного ввода.
- `rpcd`: новые методы `add_dns_rule`/`del_dns_rule`, `get_log`, `get_running_config`, `check_connectivity`.
- `rpcd`/`www--singbox.html`: `status` возвращает версию sing-box и дату обновления баз — в шапке UI.
- `uninstall`: флаг `--purge` для удаления UCI-конфига (по умолчанию конфиг сохраняется).
- `www--singbox.html`: тосты на добавление/удаление правил и DNS-записей; select вместо свободного текста для DNS/cron; кнопки «Проверить связь»/«Скачать конфиг»/«Лог»; viewport meta для мобильных экранов.

### Fixed

- `compiler`: режим 3, ложные срабатывания geoip — правило матчило по OR, легитимные РФ-домены (напр. `vk.com`) с IP, пересекающимся с `geoip-ru-blocked.srs`, ошибочно уходили в proxy. Разбито на два правила: `geosite-blocked` по домену как раньше, `geoip-blocked` — `logical`/`and` c `protocol=invert` (срабатывает только когда sniff не опознал домен). Подтверждено через Clash API (`/connections`, `chains`).
- `update-rules.sh`: переписан — атомарная загрузка через temp-файл, валидация по magic-байтам (`head -c`, не `od`), никогда не затирает рабочий файл при неудаче. Устранён краш-луп sing-box в режиме 2; исправлен URL (`category-ru.srs`, не `ru.srs`, 404).
- `compiler`: legacy DNS-формат → sing-box 1.12+ (`dns.servers[].type/server`); deprecated outbound DNS rule → `route.default_domain_resolver`; убрана мёртвая `rdbypass`; `db_mtime`/`db_label` через `date -r`; multi-return баг в `gsub()` без скобок (падал `add_dns_rule`); DNS-правило `gemini.google.com` — `tls://` вместо `https://.../dns-query`; `custom_rule`/`dns_rule` гарантированно применяются только при `route_mode=3`.
- `rpcd`: `set_settings` — allowlist разрешённых ключей вместо записи произвольных полей; `update_sub` — сброс DNS-кэша (`dnsmasq restart`) после обновления баз.
- `www--singbox.html`: кнопка dirty-state вызывала не ту функцию; автофокус на поле пароля; карточка исключений скрыта при `route_mode≠3`.
- `rpcd`: `check_connectivity` — BusyBox `wget -q` глушил вывод, переписано на проверку exit-кода.
- `test`: `compiler-test.sh` проходит 4/4 (detour DNS-серверов, порядок режимов в тесте 1→2→4→3).

---

## [0.10.1] — 2026-06-28

### Breaking

- Ядро заменено: `shtorm-7/sing-box-extended` → `Leadaxe/sing-box-lx` (v1.13.13-lx.15) — extended некорректно обрабатывал H1–H4 как Range (сервер выбирал случайное значение из диапазона при handshake, клиент ожидал фиксированное начало), туннель не поднимался.

### Added

- `compiler`: поля `s3`, `s4` (AWG 2.0 — junk-padding для cookie-reply и transport-сообщений).
- `compiler`: поля `i1–i5` (CPS decoy packets, AWG 2.0).
- `compiler`: `pre_shared_key` в `peers[0]` — поддержка PSK из UCI.
- `www--singbox.html`: импорт `.vpn` — парсинг `S3`/`S4` из `awg.S3`/`awg.S4`, `pre_shared_key` из `last_config.psk_key`.
- `www--singbox.html`: импорт `.conf` — парсинг `s3`, `s4`, `PresharedKey`.
- `www--singbox.html`: edit-модал — поля `s3`, `s4`, Pre-Shared Key.

### Changed

- `README`: переписан и сокращён для лучшей читаемости.

### Fixed

- `compiler`: AmneziaWG-блок переписан под плоскую схему sing-box-lx (`jc/jmin/jmax/s1/s2/h1–h4` напрямую на endpoint, без вложенного `amnezia: {}`).
- `compiler`: `system: false` — при vanilla wireguard в ядре `system: true` передавал AWG-параметры через UAPI в ядро, ядро их игнорировало, обфускация не работала.
- `compiler`: `h1–h4` передаются строками-диапазонами (`"N-M"`) — lx принимает нативно.
- `compiler`: добавлен `detour: "direct"` на AWG endpoint — UDP уходил через WAN, не заворачивался в TPROXY.
- `compiler`: добавлен `route.auto_detect_interface: true` — устраняет `override-gateway: invalid IP`.
- `rpcd`: `add_node`/`edit_node` — поля `s3`, `s4`, `pre_shared_key` добавлены в `allowed`; ранее молча отбрасывались при сохранении в UCI.
- `rpcd`: `apply` при `enabled=0` — теперь останавливает sing-box вместо reload; ранее сервис оставался жить со старым конфигом.
- `install`: убран `iproute2-ss` из `PKGS` — пакет отсутствует в arm64 apk-репозитории.
- `install`: обновлён `TARBALL_URL` под именование lx-архивов (без суффикса `-compressed`).
- `.github/workflows/mirror-singbox.yml`: обновлён upstream `shtorm-7/sing-box-extended` → `Leadaxe/sing-box-lx`; именование ассетов приведено в соответствие; расписание сокращено с раз в 6ч до раз в сутки; убран `linux-armv7` из архитектур.

---

## [0.10.0] — 2026-06-17

### Breaking

- Требует `sing-box-extended` ≥ 1.13.0.

### Fixed

- `compiler`: убраны deprecated-поля `sniff`/`sniff_override_destination` из inbound (удалены в 1.13), `action="sniff"` добавлен в `route.rules`.
- `compiler`: убран outbound `dns-out` (удалён в 1.13); DNS-перехват переведён на `action="hijack-dns"`.
- `compiler`: `log.level="disabled"` → `"info"` (значение `disabled` удалено в 1.13).
- `compiler`: добавлен `x_padding_bytes="100-1000"` для xhttp-транспорта (обязательно в 1.13).
- `initd`: `procd_set_param env` — объединены три `ENABLE_DEPRECATED_*` в один вызов (множественные вызовы перезатирают друг друга в procd).
- `install`: debug-вывод curl убран, восстановлен `curl -sL ... || die`.
- `install`: добавлен `touch /etc/config/singbox` перед `uci batch` (без файла UCI возвращает "Entry not found").
- `install`: `uhttpd.singbox.ubus_prefix='/ubus'` — без этого SPA получала 404 на `/ubus`.
- `install`: `LAN_IP` — добавлен `cut -d/ -f1` (uci возвращал адрес с маской).
- `update-rules.sh`: полностью переписан — upstream прекратил публикацию `.srs` напрямую; теперь скачивается `sing-box.zip` из `runetfreedom/russia-v2ray-rules-dat`, нужные файлы извлекаются через `unzip`.

### Added

- `install`: зависимости `kmod-nft-socket lua luac libuci-lua libubus-lua unzip` (без них проект не функционировал на apk-сборках).
- `test`: проверка `kmod-nft-socket`.
- `www--singbox.html`: фикс импорта `.vpn` — поддержка base64url + deflate/deflate-raw (формат AmneziaVPN).
- `uninstall`: опциональный блок удаления пакетов, установленных singA (`lua`, `luac`, `libuci-lua`, `libubus-lua`, `unzip`, `kmod-nft-socket`).

### Changed

- `README`: таблица оборудования убрана, добавлена информация о целевом железе и ПО.
- `README`: исправлена неверная формулировка про tmpfs-хранение баз РКН.
- `README`: добавлен источник правил (`runetfreedom/russia-v2ray-rules-dat`) в таблицу стека.
- `README`: секция "Отличие от podkop" — убраны недоказуемые claims (ТСПУ-эвристика, "Полная совместимость").
- `README`: добавлены `<details>`-блоки с архитектурой и структурой файлов.

---

## [0.9.10] — 2026-06-13

### Fixed

- `initd`: `/var/run/sing-box/sub_cache` создаётся в `start_service()` — после перезагрузки симлинк `sub_cache → tmpfs` не висел в воздухе.
- `initd`: `reload_service` переписан — `procd_send_signal HUP` заменён на встроенный рестарт procd (sing-box не поддерживает горячую перезагрузку по SIGHUP).
- `initd`: `init_routing` вызывается асинхронно (`&`) — ожидание порта не блокирует загрузку системы.
- `initd`: `_port_bound` использует `grep -qE ":${1}[^0-9]"` — корректно парсит IPv6-формат вывода `ss` в BusyBox.
- `compiler`: генерация блока `rule_set` пропускается, если `ru-blocked.srs` отсутствует на диске — устраняет падение ядра при `rdbypass=1` до первого запуска `update-rules.sh`.
- `compiler`: `bootstrap_address="local_dns"` добавлен к серверу `dns-remote` — устраняет дедлок резолвинга при перехвате DNS провайдером.
- `rpcd`: `echo` заменён на `printf 'root:%s\n'` в `change_password` — `echo` в BusyBox интерпретирует `-e`/`-n` как флаги, обрезая пароль.
- `install`: проверка свободного места в `/overlay` перед скачиванием бинарника (минимум 30 MB).
- `install`: `rm -rf` перед `ln -sf` для симлинка `sub_cache` — при переустановке симлинк корректно заменяется, а не вкладывается внутрь существующей директории.
- `install`: создание директорий `/var/run/sing-box/…` убрано — ответственность делегирована `initd`.
- `install`: симлинк для `rules` убран — SRS-базы остаются в `/etc/sing-box/` напрямую (перезапись раз в неделю, износ Flash пренебрежим).
- `uninstall`: `ip rule del fwmark 0x100 table 100` вместо `ip rule del table 100` — зеркалит синтаксис `initd`, надёжно работает на BusyBox iproute2.
- `uninstall`: `ip route del local default dev lo table 100` — точный синтаксис вместо обобщённого.
- `uninstall`: путь Web UI исправлен — `rm -rf /www/singbox` вместо `rm -f /www/singbox.html`.
- `uninstall`: добавлено самоудаление скрипта (`rm -f "$0"`).
- `test`: `local_dns` добавлен в список проверяемых UCI-ключей.

### Added

- `uninstall.sh` — полное бесследное удаление: nftables, iproute2, UCI, бинарники, Web UI, cron.
- `CHANGELOG.md`.
- `.github/ISSUE_TEMPLATE/bug_report.yml` и `feature_request.yml` — GitHub Forms для issues.

---

## [0.9.9] — 2026-06-12

### Fixed

- `install`/`rpcd`: `edit_node` добавлен в write-права RPCD ACL — `toggleNode`/`saveEditNode` тихо отклонялись.
- `www--singbox.html`: CSS-класс `.toggle-off` корректно применяется к кнопке отключённого узла (был пустой класс).
- `www--singbox.html`: `openEditModal` заполняет поля `jc/jmin/jmax/s1/s2/h1–h4` для AmneziaWG-узлов — без этого `save` стирал параметры обфускации через `uci:delete`.
- `www--singbox.html`: блок `edit-amnezia-params` скрывается для узлов типа `wireguard` в edit-модале.
- `www--singbox.html`/`install`: поле Local DNS добавлено в форму настроек; значение сохраняется в UCI (`singbox.main.local_dns`); дефолт добавлен в UCI-defaults в `install.sh`.
- `compiler`: PID читается через `awk '/^Pid:/'` из `/proc/self/status` вместо subshell `echo $$`.
- `sub-updater`: wireguard-узлы не получают AWG-поля (`jc/jmin/jmax` и др.) в JSON-кеше.
- `install`: `SB_REPO` заменён на зеркало `infinjest/singA`.
- `install`: суффикс `-compressed` добавлен в `TARBALL_URL` (формат архива зеркала).
