# singA

TProxy шлюз - VPN-клиент для роутеров на OpenWrt. Split tunneling, split-DNS, веб-интерфейс на порту `1104`

```sh
sh -c "$(curl -sL https://raw.githubusercontent.com/infinjest/singA/main/install.sh)"
```

---

## Возможности

**Протоколы**
- AmneziaWG2 — импорт `.vpn` из Amnezia-клиента
- VLESS + Reality + xhttp — импорт по ссылке `vless://`

**Маршрутизация**
- 3 режима (`route_mode`): 1) всё в proxy; 2) всё в proxy, кроме РФ-доменов; 3) обход РКН (дефолт) - в proxy только заблокированное/замедленное в РФ
- Исключения по IP устройства, домену или IP назначения (только в режиме «обход РКН»). Поддержка синтаксиса geosite:<категория>

**DNS**
- Заблокированные домены резолвятся через DoH (Cloudflare, Adguard, Google, свой), остальные — через локальный DNS (Яндекс, Adguard, Google, свой)
- Кастомные DNS-сервера для отдельных доменов (только в режиме «обход РКН»)

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
│   ├── singbox-uninstall
│   ├── singbox-integrity-test
│   └── singbox-compiler-test
├── 📁 libexec/rpcd
│   └── singbox
└── 📁 share/rpcd/acl.d
    └── singbox.json

📁 /www/singbox
└── singbox.html

📁 /var/run
├── 📁 sing-box
│   └── sub_cache
└── sing-box_running.json
```
</details>