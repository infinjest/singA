# singA

TProxy шлюз - VPN-клиент для роутеров на OpenWrt. Раздельное туннелирование, split-DNS, веб-интерфейс на порту `1104`

```sh
sh -c "$(curl -sL https://raw.githubusercontent.com/infinjest/singA/main/install.sh)"
```

---

## Возможности

**Протоколы**
- AmneziaWG2 — импорт файла `amnezia_config.vpn`, генерированного приложением AmneziaVPN
- VLESS + Reality + xhttp — импорт по ссылке `vless://` (поддерживается основной ключ PaperVPN)

**Маршрутизация**
- 3 режима (`route_mode`): 1) всё в proxy; 2) всё в proxy, кроме РФ-доменов; 3) обход РКН (дефолт) - в proxy только заблокированное/замедленное в РФ
- Исключения по IP устройства, домену или IP назначения (только в режиме «обход РКН»). Поддержка синтаксиса geosite:<категория>, с автодополнением по мере ввода
- Блокировка QUIC (UDP/443) по умолчанию (`block_quic`, отключается в настройках) — часть QUIC/HTTP3-зависимых приложений (в т.ч. на Android) плохо переживает QUIC поверх туннеля; reject заставляет клиента сразу откатиться на TCP

**DNS**
- Заблокированные домены резолвятся через DoH (шифрованный, публичный провайдер или свой сервер), остальные — через обычный локальный DNS
- Кастомные DNS-серверы для отдельных доменов (режим «обход РКН»)
- Некоторые приложения и устройства обращаются к публичным DNS напрямую (Google, Cloudflare и т.п.), в обход настроек роутера — это ломает разделение «заблокированное через DoH, остальное напрямую» из пункта выше. singA блокирует такие прямые запросы, чтобы вся сеть резолвила DNS по одной схеме

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
sh /usr/sbin/singbox-integrity-test   # интеграционные тесты (только после чистой установки)
sh /usr/sbin/singbox-compiler-test    # проверка JSON для всех route_mode
sh /etc/sing-box/update-rules.sh      # обновление баз вручную
sh /usr/sbin/singbox-uninstall        # удаление (--purge для удаления UCI-конфига)
```

---

## Стек

| Компонент | Роль |
|---|---|
| [sing-box-lx](https://github.com/Leadaxe/sing-box-lx) | ядро (форк sing-box от Leadaxe с поддержкой xhttp и AmneziaWG2) |
| nftables TProxy | перехват трафика |
| RPCD + UCI | API и хранение конфигурации |
| Vanilla JS SPA | веб-интерфейс |
| [runetfreedom](https://github.com/runetfreedom/russia-v2ray-rules-dat) | базы РКН (geosite/geoip .srs) для route_mode=3 (обход РКН-блокировок) |
| [MetaCubeX](https://github.com/MetaCubeX/meta-rules-dat) | база `geosite:ru` для route_mode=2 (всё в proxy кроме РФ-доменов); `geosite:<категория>` для исключений в route_mode=3 |

---

<details>

<summary>Hазначение файлов обвязки</summary>

| Файл | Путь | Назначение |
|------|------|------------|
| `initd--sing-box.sh` | `/etc/init.d/sing-box` | procd-сервис: создаёт tmpfs-директории, синхронизирует подписки при первом старте, запускает компилятор и sing-box, асинхронно поднимает nftables TProxy |
| `sbin--singbox-compiler.lua` | `/usr/sbin/singbox-compiler` | транслятор UCI → JSON-конфиг sing-box: читает узлы, правила, DNS из UCI/sub_cache, атомарно записывает результат |
| `rpcd--singbox.lua` | `/usr/libexec/rpcd/singbox` | RPCD-плагин, API веб-интерфейса через ubus |
| `lib--singbox-validate.lua` | `/usr/lib/singbox/validate.lua` | общий модуль валидации UCI-полей — используется `rpcd` и `compiler` |
| `sbin--singbox-sub-updater.sh` | `/usr/sbin/singbox-sub-updater` | загрузчик подписок: скачивает VLESS/AWG по URL из UCI, парсит в узлы, кэширует JSON в tmpfs |
| `etc-singbox--update-rules.sh` | `/etc/sing-box/update-rules.sh` | обновление баз: скачивает .srs, перезапускает sing-box; расписание задаётся через cron_schedule |
| `www--singbox.html` | `/www/singbox/singbox.html` | одностраничный UI (порт 1104): авторизация через ubus session.login, управление узлами/правилами/подписками |

</details>

<details>

<summary>Структура файлов на роутере после установки</summary>

```
📁 /etc
├── 📁 config
│   └── singbox
├── 📁 init.d
│   └── sing-box
└── 📁 sing-box
    ├── geoip-ru-blocked.srs   # route_mode=3 (runetfreedom)
    ├── ru-blocked.srs         # route_mode=3 (runetfreedom)
    ├── geosite-ru.srs         # route_mode=2 (MetaCubeX), взаимоисключающе с файлами выше
    ├── rule-sets/             # geosite:<категория> для исключений route_mode=3 (MetaCubeX)
    │   └── geosite-<категория>.srs
    ├── update-rules.sh
    └── sub_cache → /var/run/sing-box/sub_cache

📁 /usr
├── 📁 bin
│   └── sing-box
├── 📁 sbin
│   ├── singbox-compiler
│   ├── singbox-sub-updater
│   ├── singbox-logtail
│   ├── singbox-uninstall
│   ├── singbox-integrity-test
│   └── singbox-compiler-test
├── 📁 libexec/rpcd
│   └── singbox
├── 📁 lib/singbox
│   └── validate.lua
└── 📁 share/rpcd/acl.d
    └── singbox.json

📁 /www/singbox
└── singbox.html

📁 /var/run
├── 📁 sing-box
│   └── sub_cache
├── sing-box_running.json
└── sing-box_log.txt
```
</details>

<details>

<summary>Ссылка на скриншот веб-интерфейса версии 0.10.3</summary>

https://drive.google.com/file/d/1JKJrtnmzuaXDFETNAIkbC4zEYVyKJNV0/view?usp=drive_link

</details>
