# singA

```sh
sh -c "$(curl -sL https://raw.githubusercontent.com/infinjest/singA/main/install.sh)"
```

Лёгкий прозрачный шлюз (TProxy) для роутеров OpenWrt на базе [sing-box](https://github.com/SagerNet/sing-box), управляемый через нативный стек UCI/UBUS.

---

## Для чего

singA превращает домашний роутер в автономный прозрачный шлюз: весь трафик локальной сети проксируется без настройки на клиентских устройствах. Базовый маршрут — прямой; в туннель уходят только ресурсы из баз РКН. Маршрутизация и DNS-сплит работают целиком внутри процесса sing-box — без вмешательства в dnsmasq, firewall или ipset.

### Отличие от podkop и других решений

OpenClash и v2rayA требовательны к ОЗУ и часто пишут на флеш (кэш Clash-движка, периодические обновления баз). Podkop и antizapret интегрируются глубже: генерируют nftables/ipset-наборы на тысячи записей и перехватывают dnsmasq, что конфликтует с AdGuard Home и сторонними DNS-фильтрами.

singA — строгая инкапсуляция:

- Роутер только перенаправляет пакеты в TProxy-порт; вся логика маршрутизации — внутри sing-box, без правок dnsmasq и firewall.
- DNS-сплит реализован внутри sing-box — не пересекается с системным dnsmasq, совместим с AdGuard Home.
- UI-бэкенд (RPCD) активируется только при открытии браузера — фонового потребления ОЗУ/CPU нет.
- Базы РКН обновляются на флеш раз в неделю — износ пренебрежим; кэш подписок — в tmpfs.
- Трафик по умолчанию идёт напрямую (`rdbypass`) — нагрузка на VPS минимальна.

---

## Возможности

**Маршрутизация**
- Приоритетные исключения: конкретный источник (IP устройства, подсеть), домен или IP-адрес → выбранный outbound.
- Глобальные списки `force_proxy` / `force_direct` поверх баз РКН.
- Режим `rdbypass`: весь трафик российских адресов идёт напрямую.
- Автоматический failover между outbound-узлами при недоступности.

**DNS**
- Сплит-резолвинг: заблокированные домены — через DoH внутри туннеля, остальные — через локальный резолвер (ISP или свой).
- Защита от DNS-спуфинга провайдера.

**Протоколы**
- VLESS: WebSocket, xHTTP, gRPC, Reality (с `pbk`/`sid`).
- AmneziaWG (с параметрами обфускации `jc/jmin/jmax/s1/s2/h1-h4`).
- WireGuard.

**Импорт**
- Подписки: автоматический разбор VLESS-, WireGuard- и AmneziaWG-ссылок.
- Ручные конфиги `.conf` и `.vpn` (AmneziaWG).
- Ручной ввод узлов через UI.

**Управление**
- Одностраничный веб-интерфейс на порту `1104`, без LuCI.
- Backend на RPCD/UCI — нативный стек OpenWrt, без дополнительных демонов.
- Cron-задача для фонового обновления баз РКН.
- Смена системного пароля root через UI.

---

## Поддерживаемое оборудование

Проект тестируется на Netis NX31 (MT7981, arm64; 256MB RAM, 128MB Flash) на OpenWrt 25.12.4

---

## Установка

```sh
sh -c "$(curl -sL https://raw.githubusercontent.com/infinjest/singA/main/install.sh)"
```

Установщик разворачивает все компоненты, создаёт UCI-конфиг с дефолтами и регистрирует сервис в procd. Существующая конфигурация не перезаписывается.

После установки:

```sh
sh /usr/sbin/test.sh          # интеграционные тесты
sh /usr/sbin/singbox-uninstall  # полное удаление
```

---

## Стек

| Компонент | Роль |
|---|---|
| [sing-box-extended](https://github.com/shtorm-7/sing-box-extended) | ядро (shtorm-7 форк с поддержкой AmneziaWG) |
| nftables TProxy | перехват трафика |
| RPCD + UCI | API и хранение конфигурации |
| Vanilla JS SPA | веб-интерфейс |
| [runetfreedom/russia-v2ray-rules-dat](https://github.com/runetfreedom/russia-v2ray-rules-dat) | базы блокировок РКН (geosite/geoip .srs) |

---

<details>
<summary>Архитектура: назначение файлов обвязки</summary>

1. initd--sing-box.sh (/etc/init.d/sing-box) — procd-скрипт управления сервисом. При старте создаёт runtime-директории в tmpfs, при первом запуске синхронизирует подписки, вызывает компилятор для генерации JSON-конфига, запускает sing-box под procd с нужными env-переменными совместимости, и асинхронно настраивает nftables TProxy + ip rule/ip route для перехвата трафика.
2. sbin--singbox-compiler.lua (/usr/sbin/singbox-compiler) — транслятор UCI-конфигурации в JSON-конфиг sing-box. Читает узлы, правила, DNS-настройки и подписки из UCI/sub_cache, собирает inbounds/outbounds/route/dns по схеме sing-box 1.13, атомарно записывает результат во временный файл и переименовывает в рабочий конфиг.
3. rpcd--singbox.lua (/usr/libexec/rpcd/singbox) — RPCD-плагин, основное API для веб-интерфейса через ubus. Обрабатывает методы status, get_config, add_node/edit_node/del_node, add_rule/set_rules, add_subscription, apply (перезапуск сервиса) и change_password (смена root-пароля через UCI/shadow). Запускается по запросу, не висит в памяти.
4. sbin--singbox-sub-updater.sh (/usr/sbin/singbox-sub-updater) — загрузчик подписок. Скачивает VLESS/AmneziaWG/WireGuard-подписки по URL из UCI, парсит ссылки/конфиги в узлы, кэширует результат как JSON в sub_cache (tmpfs) для последующей сборки compiler'ом.
5. etc-singbox--update-rules.sh (/etc/sing-box/update-rules.sh) — обновление баз блокировок РКН. Скачивает актуальные geosite-ru-blocked.srs/geoip-ru-blocked.srs (из russia-v2ray-rules-dat), кладёт на флеш, при успехе перезагружает sing-box. Запускается по cron еженедельно.
6. www--singbox.html (/www/singbox/singbox.html) — одностраничный Vanilla JS веб-интерфейс на порту 1104. Авторизация через ubus session.login (системный пароль root), CRUD узлов/правил/подписок и настроек через rpcd--singbox.lua по /ubus-эндпоинту uhttpd.

</details>

<details>
<summary>Структура файлов на роутере после установки</summary>

/etc/init.d/sing-box

/etc/config/singbox

/etc/sing-box/

├── ru-blocked.srs

├── geoip-ru-blocked.srs

├── update-rules.sh

└── sub_cache -> /var/run/sing-box/sub_cache
/usr/bin/sing-box

/usr/sbin/singbox-compiler

/usr/sbin/singbox-sub-updater

/usr/sbin/singbox-uninstall

/usr/sbin/test.sh

/usr/libexec/rpcd/singbox

/usr/share/rpcd/acl.d/singbox.json

/www/singbox/singbox.html

/var/run/sing-box_running.json

/var/run/sing-box/          ← tmpfs, пересоздаётся при старте

└── sub_cache/

</details>
