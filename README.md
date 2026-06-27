# singA

```sh
sh -c "$(curl -sL https://raw.githubusercontent.com/infinjest/singA/main/install.sh)"
```

Лёгкий tproxy шлюз и web GUI клиент для роутеров на OpenWrt на базе форка sing-box с поддержкой AmneziaWG2 и xhttp.

---

### Отличие от podkop и других решений: singA = строгая инкапсуляция

Роутер только перенаправляет пакеты в TProxy-порт; вся логика маршрутизации — внутри sing-box, без правок dnsmasq и firewall. DNS-сплит реализован внутри sing-box — не пересекается с системным dnsmasq, совместим с AdGuard Home. UI-бэкенд (RPCD) активируется только при открытии браузера — фонового потребления ОЗУ/CPU нет. Кэш подписок, логи — в tmpfs; базы РКН обновляются раз в неделю — износ флеш пренебрежим.

---

## Возможности

**Маршрутизация**
- Базовый маршрут — прямой; в туннель уходят только ресурсы из баз РКН.
- Приоритетные исключения: конкретный источник (IP устройства, подсеть), домен или IP-адрес → выбранный outbound.

**DNS**
Сплит-резолвинг: заблокированные домены — через DoH внутри туннеля (https://dns.cloudflare.com/dns-query по умолчанию), остальные — через локальный резолвер (77.88.8.8 по умолчанию).

**Импорт**
- Файлы конфигурации amnezia `.vpn` на протоколе AmneziaWG2 (WireGuard с параметрами обфускации `jc/jmin/jmax/s1-s4/h1-h4/psk`).
- Ссылки vless:// (xhttp + reality).

**Управление**
- Одностраничный веб-интерфейс на порту `1104`, без LuCI.
- Backend на RPCD/UCI — нативный стек OpenWrt, без дополнительных демонов.
- Cron-задача для фонового обновления баз РКН.

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
| [sing-box-lx](https://github.com/Leadaxe/sing-box-lx) | ядро (форк sing-box от Leadaxe с поддержкой xhttp и AmneziaWG2) |
| nftables TProxy | перехват трафика |
| RPCD + UCI | API и хранение конфигурации |
| Vanilla JS SPA | веб-интерфейс |
| [runetfreedom/russia-v2ray-rules-dat](https://github.com/runetfreedom/russia-v2ray-rules-dat) | базы блокировок РКН (geosite/geoip .srs) |

---

<details>

<summary>Архитектура: назначение файлов обвязки</summary>

1. initd--sing-box.sh (/etc/init.d/sing-box)
procd-скрипт управления сервисом. При старте создаёт runtime-директории в tmpfs, при первом запуске синхронизирует подписки, вызывает компилятор для генерации JSON-конфига, запускает sing-box под procd с нужными env-переменными совместимости, и асинхронно настраивает nftables TProxy + ip rule/ip route для перехвата трафика.

2. sbin--singbox-compiler.lua (/usr/sbin/singbox-compiler)
транслятор UCI-конфигурации в JSON-конфиг sing-box. Читает узлы, правила, DNS-настройки и подписки из UCI/sub_cache, собирает inbounds/outbounds/route/dns по схеме sing-box 1.13, атомарно записывает результат во временный файл и переименовывает в рабочий конфиг.

3. rpcd--singbox.lua (/usr/libexec/rpcd/singbox)
RPCD-плагин, основное API для веб-интерфейса через ubus. Обрабатывает методы status, get_config, add_node/edit_node/del_node, add_rule/set_rules, add_subscription, apply (перезапуск сервиса) и change_password (смена root-пароля через UCI/shadow). Запускается по запросу, не висит в памяти.

4. sbin--singbox-sub-updater.sh (/usr/sbin/singbox-sub-updater)
загрузчик подписок. Скачивает VLESS/AmneziaWG/WireGuard-подписки по URL из UCI, парсит ссылки/конфиги в узлы, кэширует результат как JSON в sub_cache (tmpfs) для последующей сборки compiler'ом.

5. etc-singbox--update-rules.sh (/etc/sing-box/update-rules.sh)
обновление баз блокировок РКН. Скачивает актуальные geosite-ru-blocked.srs/geoip-ru-blocked.srs (из russia-v2ray-rules-dat), кладёт на флеш, при успехе перезагружает sing-box. Запускается по cron еженедельно.

6. www--singbox.html (/www/singbox/singbox.html)
одностраничный Vanilla JS веб-интерфейс на порту 1104. Авторизация через ubus session.login (системный пароль root), CRUD узлов/правил/подписок и настроек через rpcd--singbox.lua по /ubus-эндпоинту uhttpd.

</details>

<details>

<summary>Структура файлов на роутере после установки</summary>

/etc/
├── config/
│   └── singbox
├── init.d/
│   └── sing-box
└── sing-box/
    ├── geoip-ru-blocked.srs
    ├── ru-blocked.srs
    ├── update-rules.sh
    └── sub_cache → /var/run/sing-box/sub_cache

/usr/
├── bin/
│   └── sing-box
├── sbin/
│   ├── singbox-compiler
│   ├── singbox-sub-updater
│   ├── singbox-uninstall
│   └── test.sh
├── libexec/rpcd/
│   └── singbox
└── share/rpcd/acl.d/
    └── singbox.json

/www/singbox/
└── singbox.html

/var/run/
├── sing-box/          ← tmpfs, пересоздаётся при старте
│   └── sub_cache/
└── sing-box_running.json
	
</details>