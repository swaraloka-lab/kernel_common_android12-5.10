#!/usr/bin/env bash
# Scalar GKI Kernel Compile Script

set -o pipefail

export ARCH=arm64
export SUBARCH=arm64
export TZ=Asia/Jakarta

KERNEL_DIR="$PWD"
BASE_DIR="$PWD/.."
OUT_DIR="$KERNEL_DIR/out"
LOG_FILE="$OUT_DIR/kernel_compile.log"
CHANGELOG_FILE="$BASE_DIR/kernel_changelog.txt"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
COMMIT=$(git log -1 --format="%s")

# ccache is intentionally skipped for Full LTO builds -- LTO emits LLVM IR
# objects which ccache cannot cache, so it only adds overhead.

K_IMG="$OUT_DIR/arch/arm64/boot/Image"
K_IMG_GZ="$OUT_DIR/arch/arm64/boot/Image.gz"

AK3_DIR="$BASE_DIR/AnyKernel3"
[[ ! -d "$AK3_DIR" ]] && echo "--- ! AnyKernel3 not found at $AK3_DIR ! ---" && exit 1

# Telegram
TELEGRAM_CONFIG="$BASE_DIR/telegram_api"
[[ ! -f "$TELEGRAM_CONFIG" ]] && echo "--- ! telegram_api config not found ! ---" && exit 1
source "$TELEGRAM_CONFIG"
[[ -z "$BOT_TOKEN" || -z "$PRIVATE_ID" || -z "$GROUP_ID" || -z "$CHANNEL_ID" ]] && \
    echo "--- ! Missing Telegram variables ! ---" && exit 1

MSGTARGET="private"
for arg in "$@"; do
    case "$arg" in
        weekly) MSGTARGET="channel" ;;
        group)  MSGTARGET="group" ;;
    esac
done

case "$MSGTARGET" in
    channel) ID="$CHANNEL_ID" ;;
    group)   ID="$GROUP_ID" ;;
    *)       ID="$PRIVATE_ID" ;;
esac

send_msg() {
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$ID" \
        -d text="$1" \
        -d parse_mode=html >/dev/null
}

send_file() {
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendDocument" \
        -F chat_id="$ID" \
        -F document=@"$1" \
        -F caption="$2" >/dev/null
}

send_changelog() {
    [[ ! -f "$CHANGELOG_FILE" ]] && return
    [[ ! -s "$CHANGELOG_FILE" ]] && echo "- Another weekly build" > "$CHANGELOG_FILE"
    local CHANGELOG
    CHANGELOG=$(sed 's/$/%0A/' "$CHANGELOG_FILE" | tr -d '\n')
    send_msg "<b>Changelog:</b>%0A<code>$CHANGELOG</code>"
}

# Toolchain (GKI = Clang only)
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
        send_msg "<b>[FAILED] Scalar Prjkt GKI</b>%0A<b>Branch:</b> <code>$BRANCH</code>%0A<b>Elapsed:</b> <code>$BUILD_TIME</code>"
        send_file "$LOG_FILE" "build log"
        return 1
    fi

    echo "--- Packing zip ---"
    local ZIP_NAME ZIP_PATH ZIP_SIZE
    ZIP_NAME="Scalar-Prjkt-GKI-$(date "+%y%m%d-%H%M").zip"
    ZIP_PATH="$OUT_DIR/$ZIP_NAME"

    cd "$AK3_DIR"
    cp "$K_IMG" Image
    [[ -f "$K_IMG_GZ" ]] && cp "$K_IMG_GZ" Image.gz || true
    zip -r9 "$ZIP_PATH" META-INF tools Image Image.gz anykernel.sh 2>/dev/null
    cd "$KERNEL_DIR"

    ZIP_SIZE=$(du -sh "$ZIP_PATH" | cut -f1)

    send_msg "<b>[SUCCESS] Scalar Prjkt GKI</b>%0A<b>Date:</b> <code>$(date '+%Y-%m-%d %H:%M')</code>%0A<b>Branch:</b> <code>$BRANCH</code>%0A<b>Toolchain:</b> <code>$TC</code>%0A<b>Build time:</b> <code>$BUILD_TIME</code>%0A<b>Size:</b> <code>$ZIP_SIZE</code>%0A<b>Head:</b> <code>$COMMIT</code>"
    send_file "$ZIP_PATH" "$BRANCH"

    [[ "$*" == *changelog* ]] && send_changelog

    echo "--- Done: $ZIP_PATH ($ZIP_SIZE) in $BUILD_TIME ---"
}

build_kernel "$@" || exit 1

echo "--- Build complete ---"