# singA

TProxy VPN-клиент для роутеров архитектуры arm64 на OpenWrt. Поддержка xhttp и awg2, раздельное туннелирование, гигиена DNS, веб-интерфейс на порту `1104`.

```sh
sh -c "$(curl -sL https://raw.githubusercontent.com/infinjest/singA/main/install.sh)"
```

---

## Возможности

**Протоколы**
- AmneziaWG2 - импорт файла `amnezia_config.vpn`, сгенерированного приложением AmneziaVPN
- vless + xhttp + reality - импорт по ссылке `vless://` (поддерживается основной ключ PaperVPN)

**Маршрутизация**
- 3 режима: 1) всё в proxy; 2) всё в proxy, кроме РФ-доменов; 3) обход РКН (дефолт) - в proxy только заблокированное/замедленное в РФ + исключения
- Исключения по IP устройства, домену или IP назначения, поддержка синтаксиса geosite:<категория> с автодополнением по мере ввода - в режиме «обход РКН»

**DNS**
- Заблокированные домены резолвятся через DoH (из списка или свой), остальные - через локальный DNS (из списка или свой)
- Кастомные DNS-серверы для отдельных доменов - в режиме «обход РКН»

**Совместимость**
- Блокировка QUIC (UDP/443) - часть приложений плохо работает с QUIC поверх туннеля, reject откатывает их на TCP. Включено по умолчанию
- Блокировка прямых запросов к публичным DNS-резолверам - иначе часть клиентов обходила бы правила DNS роутера. Включено по умолчанию

**Логи, автовыбор узла**
- Просмотр 100 последних строк лога sing-box в UI (кнопка «Лог», обновление по кнопке)
- При двух и более активных узлах - автовыбор самого быстрого

---

## Поддерживаемое оборудование

Проект тестируется на Netis NX31 (MT7981, arm64; 256MB RAM, 128MB Flash) на OpenWrt 25.12.4. Ожидается, но не гарантируется работа на других роутерах архитектуры arm64.

---

## Установка

```sh
sh -c "$(curl -sL https://raw.githubusercontent.com/infinjest/singA/main/install.sh)"
```

Установщик разворачивает все компоненты, создаёт UCI-конфиг с дефолтами и регистрирует сервис в procd. Существующая конфигурация не перезаписывается.

После установки:

```sh
sh /usr/sbin/singbox-integrity-test   # интеграционные тесты (после чистой установки)
sh /usr/sbin/singbox-compiler-test    # проверка JSON для всех режимов
sh /etc/sing-box/update-rules.sh      # обновление баз вручную, перезапуск ядра
sh /usr/sbin/singbox-uninstall        # удаление (--purge для удаления UCI-конфига)
```

---

<details>

<summary>Стек</summary>

| Компонент | Роль |
|---|---|
| [sing-box-lx](https://github.com/Leadaxe/sing-box-lx) | ядро (форк sing-box от Leadaxe с поддержкой xhttp и AmneziaWG2) |
| nftables TProxy | перехват трафика |
| RPCD + UCI | API и хранение конфигурации |
| Vanilla JS SPA | веб-интерфейс |
| [runetfreedom](https://github.com/runetfreedom/russia-v2ray-rules-dat) | базы РКН (geosite/geoip .srs) для route_mode=3 (обход РКН-блокировок) |
| [MetaCubeX](https://github.com/MetaCubeX/meta-rules-dat) | база `geosite:ru` для route_mode=2 (всё в proxy кроме РФ-доменов); `geosite:<категория>` для исключений в route_mode=3 |

</details>

<details>

<summary>Назначение файлов обвязки</summary>

| Файл | Путь | Назначение |
|------|------|------------|
| `initd--sing-box.sh` | `/etc/init.d/sing-box` | procd-сервис: создаёт tmpfs-директории, синхронизирует подписки при первом старте, запускает компилятор и sing-box, асинхронно поднимает nftables TProxy |
| `sbin--singbox-compiler.lua` | `/usr/sbin/singbox-compiler` | транслятор UCI → JSON-конфиг sing-box: читает узлы, правила, DNS из UCI/sub_cache, атомарно записывает результат |
| `rpcd--singbox.lua` | `/usr/libexec/rpcd/singbox` | RPCD-плагин, API веб-интерфейса через ubus |
| `lib--singbox-validate.lua` | `/usr/lib/singbox/validate.lua` | общий модуль валидации UCI-полей - используется `rpcd` и `compiler` |
| `sbin--singbox-sub-updater.sh` | `/usr/sbin/singbox-sub-updater` | загрузчик подписок: скачивает VLESS/AWG по URL из UCI, парсит в узлы, кэширует JSON в tmpfs |
| `etc-singbox--update-rules.sh` | `/etc/sing-box/update-rules.sh` | обновление баз: скачивает .srs, перезапускает sing-box; расписание задаётся через cron_schedule |
| `www--singbox.html` | `/www/singbox/singbox.html` | одностраничный UI (порт 1104): авторизация через ubus session.login, управление узлами/правилами/подписками |
| `singbox-logtail` (генерируется в `install.sh`) | `/usr/sbin/singbox-logtail` | отдельный procd-инстанс поверх `logread -f -e sing-box`; кольцевой буфер последних 100 строк в `/var/run/sing-box_log.txt` |

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

<summary>Ссылка на скриншот веб-интерфейса версии 0.10.5</summary>

https://drive.google.com/file/d/1KyIQCVlP4fM_YUPtZOp6N5GML2H4Qiug/view?usp=drive_link

</details>