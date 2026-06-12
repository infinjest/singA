#!/bin/sh
# /etc/sing-box/update-rules.sh
# Обновление баз заблокированных ресурсов РКН
# Источник: runetfreedom (обновляется каждые 6 часов из реестра РКН)
# Установка в cron: 0 4 * * * /etc/sing-box/update-rules.sh

SING_BOX_DIR="/etc/sing-box"
mkdir -p "$SING_BOX_DIR"

download_srs() {
    local url="$1" dest="$2" tmp="${2}.tmp.$$"
    echo "Downloading: $(basename "$dest")..."
    curl -sfL --connect-timeout 15 --max-time 90 "$url" -o "$tmp" || {
        echo "ERROR: download failed for $url"
        rm -f "$tmp"; return 1
    }
    if grep -qi "<html" "$tmp"; then
        echo "ERROR: Captive portal or HTML error received instead of SRS"
        rm -f "$tmp"; return 1
    fi
    mv "$tmp" "$dest"
    echo "OK: $(basename "$dest") ($(wc -c < "$dest") bytes)"
}

download_srs \
    "https://github.com/runetfreedom/russia-blocked-geosite/releases/latest/download/ru-blocked.srs" \
    "${SING_BOX_DIR}/ru-blocked.srs"

download_srs \
    "https://github.com/runetfreedom/russia-blocked-geoip/releases/latest/download/ru-blocked.srs" \
    "${SING_BOX_DIR}/geoip-ru-blocked.srs"

if [ -f "${SING_BOX_DIR}/ru-blocked.srs" ] && [ -f "${SING_BOX_DIR}/geoip-ru-blocked.srs" ]; then
    if pidof sing-box > /dev/null 2>&1; then
        echo "Reloading sing-box..."
        /etc/init.d/sing-box reload
    fi
    echo "Done."
else
    echo "WARNING: One or more files missing. Skipping reload."
    exit 1
fi