#!/bin/sh
# ==============================================================================
# singA: Final script for complete, traceless removal (OpenWrt 25.12.4)
# Architecture: optimized for MediaTek MT7981 / BusyBox
# ==============================================================================

set -e
echo "[*] Starting full removal of singA..."

# 1. Stop the service and remove it from autostart
echo "[*] Stopping the sing-box daemon..."
if [ -x "/etc/init.d/sing-box" ]; then
    /etc/init.d/sing-box stop 2>/dev/null || true
    /etc/init.d/sing-box disable 2>/dev/null || true
    rm -f /etc/init.d/sing-box
fi

# 2. Tear down nftables and iproute2 network rules
echo "[*] Cleaning up TProxy routing..."
nft delete table inet singbox 2>/dev/null || true

# Remove all rules referencing table 100 (IPv4 and IPv6)
# Uses the same syntax as initd — fwmark-based, reliable on BusyBox iproute2
while ip rule show 2>/dev/null | grep -q "lookup 100"; do
    ip rule del fwmark 0x100 table 100 2>/dev/null || break
done
while ip -6 rule show 2>/dev/null | grep -q "lookup 100"; do
    ip -6 rule del fwmark 0x100 table 100 2>/dev/null || break
done

# Remove routes inside table 100
ip route del local default dev lo table 100 2>/dev/null || true
ip -6 route del local default dev lo table 100 2>/dev/null || true

# 3. Clean up the UCI configuration
echo "[*] Removing UCI configuration blocks..."
if uci -q get uhttpd.singbox >/dev/null 2>&1; then
    uci delete uhttpd.singbox
    uci commit uhttpd
fi
if [ "$1" = "--purge" ]; then
    rm -f /etc/config/singbox
    echo "[*] /etc/config/singbox configuration removed (--purge)"
else
    echo "[*] /etc/config/singbox configuration kept (use --purge to remove settings too)"
fi

# 4. Remove binaries, plugins, and the frontend
echo "[*] Removing executables and the Web UI..."
rm -f /usr/bin/sing-box
rm -f /usr/sbin/singbox-compiler
rm -f /usr/sbin/singbox-sub-updater
rm -f /usr/sbin/singbox-logtail
rm -f /usr/sbin/singbox-integrity-test
rm -f /usr/sbin/singbox-compiler-test
rm -f /usr/libexec/rpcd/singbox
rm -f /usr/share/rpcd/acl.d/singbox.json
rm -rf /www/singbox

# 5. Deep clean of cache directories and tmpfs state
echo "[*] Clearing databases, subscriptions, and runtime state..."
rm -rf /etc/sing-box
rm -rf /var/run/sing-box
rm -f /var/run/sing-box_running.json
rm -f /var/run/sing-box_tmp_*.json
rm -f /var/run/sing-box_log.txt
rm -f /var/run/singbox-sub.lock
rm -f /var/run/singbox_clash.sec
rm -f /var/run/singbox_sub_*.json

# 6. Clean up the system scheduler
echo "[*] Removing cron jobs..."
if [ -f "/etc/crontabs/root" ]; then
    sed -i '/update-rules.sh/d' /etc/crontabs/root
fi

# 7. Restart affected system services
echo "[*] Restarting uhttpd, rpcd, and cron..."
/etc/init.d/uhttpd restart 2>/dev/null || true
/etc/init.d/rpcd restart 2>/dev/null || true
/etc/init.d/cron restart 2>/dev/null || true

# 8. Optional package removal (only if installed by the singA installer)
echo "[*] Packages lua, luac, libuci-lua, libubus-lua, unzip, kmod-nft-socket"
echo "    may be used by other services."
echo "    Remove them? [y/N]"
read -r ANSWER || ANSWER="N"
if [ "$ANSWER" = "y" ] || [ "$ANSWER" = "Y" ]; then
    if command -v apk >/dev/null 2>&1; then
        apk del lua luac libuci-lua libubus-lua unzip kmod-nft-socket 2>/dev/null || true
    elif command -v opkg >/dev/null 2>&1; then
        opkg remove lua luac libuci-lua libubus-lua unzip kmod-nft-socket 2>/dev/null || true
    fi
fi

echo "[+] DONE: singA has been fully removed from the system."

# Self-delete — the script removes itself as the last action
rm -f "$0"
