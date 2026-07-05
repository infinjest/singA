#!/bin/sh
# ==============================================================================
# singA: Финальный скрипт полного и бесследного удаления (OpenWrt 25.12.4)
# Архитектура: Оптимизировано для MediaTek MT7981 / BusyBox
# ==============================================================================

set -e
echo "[*] Инициализация процесса полного удаления singA..."

# 1. Остановка службы и извлечение из автозапуска
echo "[*] Остановка демона sing-box..."
if [ -x "/etc/init.d/sing-box" ]; then
    /etc/init.d/sing-box stop 2>/dev/null || true
    /etc/init.d/sing-box disable 2>/dev/null || true
    rm -f /etc/init.d/sing-box
fi

# 2. Демонтаж сетевых правил nftables и iproute2
echo "[*] Очистка TProxy маршрутизации..."
nft delete table inet singbox 2>/dev/null || true

# Удаляем все правила, ссылающиеся на таблицу 100 (IPv4 и IPv6)
# Используем тот же синтаксис, что initd — fwmark-based, надёжно на BusyBox iproute2
while ip rule show 2>/dev/null | grep -q "lookup 100"; do
    ip rule del fwmark 0x100 table 100 2>/dev/null || break
done
while ip -6 rule show 2>/dev/null | grep -q "lookup 100"; do
    ip -6 rule del fwmark 0x100 table 100 2>/dev/null || break
done

# Удаляем маршруты внутри таблицы 100
ip route del local default dev lo table 100 2>/dev/null || true
ip -6 route del local default dev lo table 100 2>/dev/null || true

# 3. Очистка подсистемы конфигурации UCI
echo "[*] Удаление конфигурационных блоков UCI..."
if uci -q get uhttpd.singbox >/dev/null 2>&1; then
    uci delete uhttpd.singbox
    uci commit uhttpd
fi
if [ "$1" = "--purge" ]; then
    rm -f /etc/config/singbox
    echo "[*] Конфигурация /etc/config/singbox удалена (--purge)"
else
    echo "[*] Конфигурация /etc/config/singbox сохранена (используйте --purge для полного удаления настроек)"
fi

# 4. Удаление бинарных файлов, плагинов и фронтенда
echo "[*] Удаление исполняемых файлов и Web UI..."
rm -f /usr/bin/sing-box
rm -f /usr/sbin/singbox-compiler
rm -f /usr/sbin/singbox-sub-updater
rm -f /usr/sbin/singbox-integrity-test
rm -f /usr/sbin/singbox-compiler-test
rm -f /usr/libexec/rpcd/singbox
rm -f /usr/share/rpcd/acl.d/singbox.json
rm -rf /www/singbox

# 5. Глубокая очистка директорий кэша и временной памяти (tmpfs)
echo "[*] Зачистка баз данных, подписок и runtime-состояний..."
rm -rf /etc/sing-box
rm -rf /var/run/sing-box
rm -f /var/run/sing-box_running.json
rm -f /var/run/sing-box_tmp_*.json
rm -f /var/run/singbox-sub.lock
rm -f /var/run/singbox_clash.sec
rm -f /var/run/singbox_sub_*.json

# 6. Очистка системного планировщика
echo "[*] Удаление задач из cron..."
if [ -f "/etc/crontabs/root" ]; then
    sed -i '/update-rules.sh/d' /etc/crontabs/root
fi

# 7. Перезапуск затронутых системных служб
echo "[*] Перезапуск uhttpd, rpcd и cron..."
/etc/init.d/uhttpd restart 2>/dev/null || true
/etc/init.d/rpcd restart 2>/dev/null || true
/etc/init.d/cron restart 2>/dev/null || true

# 8. Опциональное удаление пакетов (только если установлены singA-установщиком)
echo "[*] Пакеты lua, luac, libuci-lua, libubus-lua, unzip, kmod-nft-socket"
echo "    могут использоваться другими сервисами."
echo "    Удалить их? [y/N]"
read -r ANSWER
if [ "$ANSWER" = "y" ] || [ "$ANSWER" = "Y" ]; then
    if command -v apk >/dev/null 2>&1; then
        apk del lua luac libuci-lua libubus-lua unzip kmod-nft-socket 2>/dev/null || true
    elif command -v opkg >/dev/null 2>&1; then
        opkg remove lua luac libuci-lua libubus-lua unzip kmod-nft-socket 2>/dev/null || true
    fi
fi

echo "[+] ГОТОВО: Проект singA успешно и полностью удален из системы."

# Самоудаление — скрипт удаляет себя последним действием
rm -f "$0"