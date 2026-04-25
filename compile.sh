#!/usr/bin/env bash
# Scalar GKI Kernel Compile Script (5.10)

set -o pipefail

export ARCH=arm64
export SUBARCH=arm64
export TZ=Asia/Jakarta

KERNEL_DIR="$PWD"
BASE_DIR="$PWD/.."
OUT_DIR="$KERNEL_DIR/out"
LOG_FILE="$OUT_DIR/kernel_compile.log"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
COMMIT=$(git log -1 --format="%s")
REMOTE_URL=$(git remote get-url origin | sed 's/\.git$//' | sed 's|git@github.com:|https://github.com/|')

K_IMG="$OUT_DIR/arch/arm64/boot/Image"

AK3_DIR="$BASE_DIR/AnyKernel3"
[[ ! -d "$AK3_DIR" ]] && echo "--- ! AnyKernel3 not found at $AK3_DIR ! ---" && exit 1

TELEGRAM_CONFIG="$BASE_DIR/telegram_api"
[[ ! -f "$TELEGRAM_CONFIG" ]] && echo "--- ! telegram_api config not found ! ---" && exit 1
source "$TELEGRAM_CONFIG"
[[ -z "$BOT_TOKEN" || -z "$PRIVATE_ID" || -z "$GROUP_ID" || -z "$CHANNEL_ID" ]] && \
    echo "--- ! Missing Telegram variables (BOT_TOKEN / PRIVATE_ID / GROUP_ID / CHANNEL_ID) ! ---" && exit 1

# Build list of targets from args.
# Default: private only.
# Pass "group" and/or "weekly" (channel) to broadcast to those as well.
declare -a TARGETS=("$PRIVATE_ID")
for arg in "$@"; do
    case "$arg" in
        weekly) TARGETS+=("$CHANNEL_ID") ;;
        group)  TARGETS+=("$GROUP_ID") ;;
    esac
done

mapfile -t TARGETS < <(printf '%s\n' "${TARGETS[@]}" | sort -u)

_tg_post() {
    local method="$1"; shift
    for id in "${TARGETS[@]}"; do
        curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/${method}" \
            "$@" -d "chat_id=${id}" >/dev/null
    done
}

send_msg() {
    _tg_post sendMessage \
        -d "text=$1" \
        -d "parse_mode=html"
}

send_file() {
    local file="$1" caption="$2"
    for id in "${TARGETS[@]}"; do
        curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument" \
            -F "chat_id=${id}" \
            -F "document=@${file}" \
            -F "caption=${caption}" >/dev/null
    done
}

send_changelog() {
    local LOG entry hash msg author link formatted=""

    while IFS='|' read -r hash msg author; do
        link="${REMOTE_URL}/commit/${hash}"
        entry="• ${msg} — ${author} (<a href=\"${link}\">${hash:0:7}</a>)"
        formatted+="${entry}%0A"
    done < <(git log -10 --pretty=format:"%H|%s|%an" HEAD)

    send_msg "<b>📋 Changelog (last 10 commits):</b>%0A%0A${formatted}"
}

case "$*" in
    *aosp*)    export PATH="$BASE_DIR/toolchains/aosp-clang/bin:$PATH";    TC="AOSP-Clang" ;;
    *neutron*) export PATH="$BASE_DIR/toolchains/neutron-clang/bin:$PATH"; TC="Neutron-Clang" ;;
    *lilium*)  export PATH="$BASE_DIR/toolchains/lilium-clang/bin:$PATH";  TC="Lilium-Clang" ;;
    *)
        if [[ -d "$BASE_DIR/toolchains/llvm-clang" ]]; then
            export PATH="$BASE_DIR/toolchains/llvm-clang/bin:$PATH"
            TC="LLVM-Clang"
        else
            echo "--- ! No toolchain found at $BASE_DIR/toolchains/ ! ---" && exit 1
        fi
        ;;
esac

MAKE_FLAGS=(
    -j"$(nproc)"
    O=out
    CC=clang
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
    LLVM=1
    LLVM_IAS=1
    LD=ld.lld
    AR=llvm-ar
    NM=llvm-nm
    OBJCOPY=llvm-objcopy
    OBJDUMP=llvm-objdump
    STRIP=llvm-strip
)

build_kernel() {
    rm -rf "$OUT_DIR/arch/arm64/boot"
    rm -f "$LOG_FILE"
    mkdir -p "$OUT_DIR"

    echo "--- Configuring (gki_defconfig) ---"
    make "${MAKE_FLAGS[@]}" gki_defconfig 2>&1 | tee -a "$LOG_FILE"

    echo "--- Building ---"
    local START_TIME
    START_TIME=$(date +%s)

    make "${MAKE_FLAGS[@]}" 2>&1 | tee -a "$LOG_FILE"
    local RET=$?

    local ELAPSED BUILD_TIME
    ELAPSED=$(( $(date +%s) - START_TIME ))
    BUILD_TIME="$(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"

    if [[ $RET -ne 0 || ! -f "$K_IMG" ]]; then
        echo "--- ! Build failed after $BUILD_TIME ! ---"
        send_msg \
"<b>❌ [FAILED] Scalar Prjkt GKI</b>
<b>Branch:</b> <code>${BRANCH}</code>
<b>Elapsed:</b> <code>${BUILD_TIME}</code>"
        send_file "$LOG_FILE" "build log"
        return 1
    fi

    echo "--- Packing zip ---"
    local ZIP_NAME ZIP_PATH ZIP_SIZE
    ZIP_NAME="Scalar-Prjkt-GKI-$(date "+%y%m%d-%H%M").zip"
    ZIP_PATH="$OUT_DIR/$ZIP_NAME"

    local TMP_AK3
    TMP_AK3=$(mktemp -d)
    cp -r "$AK3_DIR/META-INF" "$TMP_AK3/"
    cp    "$AK3_DIR/anykernel.sh" "$TMP_AK3/"
    cp    "$K_IMG" "$TMP_AK3/Image"
    [[ -f "$K_IMG_GZ" ]] && cp "$K_IMG_GZ" "$TMP_AK3/Image.gz"

    ( cd "$TMP_AK3" && zip -r9 "$ZIP_PATH" . )
    rm -rf "$TMP_AK3"

    ZIP_SIZE=$(du -sh "$ZIP_PATH" | cut -f1)

    local TARGET_LABEL
    case "${TARGETS[*]}" in
        *"$CHANNEL_ID"*) TARGET_LABEL="Channel" ;;
        *"$GROUP_ID"*)   TARGET_LABEL="Group" ;;
        *)               TARGET_LABEL="Private" ;;
    esac

    send_msg \
"<b>✅ [SUCCESS] Scalar Prjkt GKI</b>
<b>Date:</b>      <code>$(date '+%Y-%m-%d %H:%M')</code>
<b>Branch:</b>    <code>${BRANCH}</code>
<b>Toolchain:</b> <code>${TC}</code>
<b>Build time:</b><code>${BUILD_TIME}</code>
<b>Size:</b>      <code>${ZIP_SIZE}</code>
<b>Head:</b>      <code>${COMMIT}</code>"

    send_file "$ZIP_PATH" "$BRANCH"

    [[ "$*" == *changelog* ]] && send_changelog

    echo "--- Done: $ZIP_PATH ($ZIP_SIZE) in $BUILD_TIME ---"
}

build_kernel "$@" || exit 1
echo "--- Build complete ---"
