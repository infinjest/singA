#!/bin/sh
# /etc/sing-box/update-rules.sh
# Обновление баз правил маршрутизации.
# Поведение определяется singbox.main.route_mode:
#   Режим 2 → geosite-ru.srs (MetaCubeX), удалить файлы режима 3
#   Режим 3 → ru-blocked.srs + geoip-ru-blocked.srs (runetfreedom), удалить файлы режима 2
#   Режим 1, 4 → SRS не нужны, удалить все
#
# ВАЖНО: все загрузки идут через temp-файл + проверку размера, и только потом
# atomic mv поверх боевого пути. Если загрузка не прошла проверку — рабочий
# файл НЕ трогается (compiler.lua продолжит использовать старую, но валидную
# базу, вместо того чтобы получить битый rule_set и уронить sing-box).

SING_BOX_DIR="/etc/sing-box"
# Файлы режима 3 (runetfreedom)
MODE3_FILES="ru-blocked.srs geoip-ru-blocked.srs"
MODE3_ZIP_URL="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/sing-box.zip"
# Файл режима 2 (MetaCubeX geosite:ru).
# ВАЖНО: файл в репозитории называется category-ru.srs, а не ru.srs —
# "ru.srs" отдаёт 404 (страница github, а не сам файл), из-за чего с -f
# curl падал (exit 22), а без -f молча сохранял мусор поверх рабочего файла.
MODE2_FILE="geosite-ru.srs"
MODE2_URL="https://github.com/MetaCubeX/meta-rules-dat/raw/sing/geo/geosite/category-ru.srs"

TMP_ZIP="/tmp/sb-rules.$$.zip"
TMP_DIR="/tmp/sb-rules.$$"
TMP_SRS="/tmp/sb-rules.$$.srs"
trap "rm -rf '$TMP_ZIP' '$TMP_DIR' '$TMP_SRS'" EXIT

mkdir -p "$SING_BOX_DIR"
ROUTE_MODE=$(uci -q get singbox.main.route_mode 2>/dev/null || echo "3")
echo "route_mode=${ROUTE_MODE}"

# Проверка валидности .srs — по magic-байтам ("SRS" в начале файла), а не по
# размеру. Легитимные geosite-категории могут весить всего несколько КБ
# (например category-ru.srs ~7.5KB), так что порог по размеру либо пропускает
# мусор, либо ложно бракует маленькие, но настоящие базы.
# ВАЖНО: используем `head -c`, а не `od` — BusyBox od на роутере даёт другой
# формат вывода (`-An -c -N3` не работает так же, как в GNU coreutils),
# из-за чего сравнение магии всегда проваливалось бы, даже на валидном файле.
check_srs_valid() {
    f="$1"
    [ -s "$f" ] || return 1
    magic=$(head -c 3 "$f" 2>/dev/null)
    [ "$magic" = "SRS" ] || return 1
    return 0
}

# Проверка валидности .zip — по magic-байтам ("PK").
check_zip_valid() {
    f="$1"
    [ -s "$f" ] || return 1
    magic=$(head -c 2 "$f" 2>/dev/null)
    [ "$magic" = "PK" ] || return 1
    return 0
}

# ── Режим 2: geosite:ru (все в proxy кроме РУ) ────────────────────────────────
if [ "$ROUTE_MODE" = "2" ]; then
    # Удалить файлы режима 3, если они остались
    for f in $MODE3_FILES; do
        rm -f "${SING_BOX_DIR}/${f}" && echo "Removed: ${f}"
    done

    echo "Downloading geosite-ru.srs (MetaCubeX)..."
    if curl -fsL --connect-timeout 15 --max-time 60 "$MODE2_URL" -o "$TMP_SRS"; then
        if check_srs_valid "$TMP_SRS"; then
            sz=$(wc -c < "$TMP_SRS")
            mv "$TMP_SRS" "${SING_BOX_DIR}/${MODE2_FILE}"
            echo "OK: ${MODE2_FILE} (${sz} bytes)"
        else
            sz=$( [ -f "$TMP_SRS" ] && wc -c < "$TMP_SRS" || echo 0 )
            echo "ERROR: downloaded ${MODE2_FILE} is not a valid SRS file (${sz} bytes, bad magic). Keeping previous file untouched."
            exit 1
        fi
    else
        echo "ERROR: download failed for $MODE2_URL (curl exit $?). Keeping previous file untouched."
        exit 1
    fi

# ── Режим 3: ru-blocked (дефолт, обход РКН) ───────────────────────────────────
elif [ "$ROUTE_MODE" = "3" ]; then
    # Удалить файл режима 2, если остался
    rm -f "${SING_BOX_DIR}/${MODE2_FILE}" && echo "Removed: ${MODE2_FILE}"

    echo "Downloading sing-box.zip (runetfreedom)..."
    if ! curl -fsL --connect-timeout 15 --max-time 180 "$MODE3_ZIP_URL" -o "$TMP_ZIP"; then
        echo "ERROR: download failed for $MODE3_ZIP_URL. Keeping previous files untouched."
        exit 1
    fi
    if ! check_zip_valid "$TMP_ZIP"; then
        echo "ERROR: downloaded sing-box.zip looks invalid (bad magic). Keeping previous files untouched."
        exit 1
    fi

    mkdir -p "$TMP_DIR"
    if ! unzip -o -q "$TMP_ZIP" \
        "rule-set-geosite/geosite-ru-blocked.srs" \
        "rule-set-geoip/geoip-ru-blocked.srs" \
        -d "$TMP_DIR"; then
        echo "ERROR: unzip failed. Keeping previous files untouched."
        exit 1
    fi

    NEW_GEOSITE="$TMP_DIR/rule-set-geosite/geosite-ru-blocked.srs"
    NEW_GEOIP="$TMP_DIR/rule-set-geoip/geoip-ru-blocked.srs"

    if check_srs_valid "$NEW_GEOSITE" && check_srs_valid "$NEW_GEOIP"; then
        mv "$NEW_GEOSITE" "${SING_BOX_DIR}/ru-blocked.srs"
        mv "$NEW_GEOIP"   "${SING_BOX_DIR}/geoip-ru-blocked.srs"
        for f in $MODE3_FILES; do
            echo "OK: ${f} ($(wc -c < "${SING_BOX_DIR}/${f}") bytes)"
        done
    else
        echo "ERROR: extracted SRS files are not valid (bad magic). Keeping previous files untouched."
        exit 1
    fi

# ── Режимы 1 и 4: SRS не нужны ────────────────────────────────────────────────
else
    echo "route_mode=${ROUTE_MODE}: no SRS files needed"
    for f in $MODE3_FILES $MODE2_FILE; do
        rm -f "${SING_BOX_DIR}/${f}" && echo "Removed: ${f}"
    done
fi

# ── Перезагрузить sing-box если запущен ───────────────────────────────────────
if pidof sing-box > /dev/null 2>&1; then
    echo "Reloading sing-box..."
    /etc/init.d/sing-box reload
fi
echo "Done."