#!/bin/sh
# /etc/sing-box/update-rules.sh
# Обновление баз заблокированных ресурсов РКН
# Источник: runetfreedom/russia-v2ray-rules-dat (sing-box.zip, готовые .srs)
# Установка в cron: 0 4 * * 1 /etc/sing-box/update-rules.sh

SING_BOX_DIR="/etc/sing-box"
ZIP_URL="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/sing-box.zip"
TMP_ZIP="/tmp/sb-rules.$$.zip"
TMP_DIR="/tmp/sb-rules.$$"

mkdir -p "$SING_BOX_DIR"
trap "rm -rf '$TMP_ZIP' '$TMP_DIR'" EXIT

echo "Downloading sing-box.zip..."
curl -sfL --connect-timeout 15 --max-time 180 "$ZIP_URL" -o "$TMP_ZIP" || {
    echo "ERROR: download failed for $ZIP_URL"
    exit 1
}

mkdir -p "$TMP_DIR"
unzip -o -q "$TMP_ZIP" \
    "rule-set-geosite/geosite-ru-blocked.srs" \
    "rule-set-geoip/geoip-ru-blocked.srs" \
    -d "$TMP_DIR" || {
    echo "ERROR: unzip failed"
    exit 1
}

mv "$TMP_DIR/rule-set-geosite/geosite-ru-blocked.srs" "${SING_BOX_DIR}/ru-blocked.srs"
mv "$TMP_DIR/rule-set-geoip/geoip-ru-blocked.srs"     "${SING_BOX_DIR}/geoip-ru-blocked.srs"

if [ -s "${SING_BOX_DIR}/ru-blocked.srs" ] && [ -s "${SING_BOX_DIR}/geoip-ru-blocked.srs" ]; then
    echo "OK: ru-blocked.srs ($(wc -c < "${SING_BOX_DIR}/ru-blocked.srs") bytes)"
    echo "OK: geoip-ru-blocked.srs ($(wc -c < "${SING_BOX_DIR}/geoip-ru-blocked.srs") bytes)"
    if pidof sing-box > /dev/null 2>&1; then
        echo "Reloading sing-box..."
        /etc/init.d/sing-box reload
    fi
    echo "Done."
else
    echo "WARNING: One or more files missing. Skipping reload."
    exit 1
fi