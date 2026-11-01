#!/usr/bin/env bash
#
# ============================================================
# BoxShot 打包脚本
#
# 产出 dist/BoxShot.app —— 可双击、可拖进 /Applications 的原生应用。
#
# 用法：
#   ./build-app.sh                发布构建（release，带图标，ad-hoc 签名）
#   ./build-app.sh --debug        调试构建
#   ./build-app.sh --no-sign      跳过签名
#   ./build-app.sh --no-sandbox   让 swift build 跳过 SwiftPM 自带的沙箱
#   ./build-app.sh --install      构建完装到 /Applications
#   ./build-app.sh --bump         强制版本号 +1（即使源码没变）
#   ./build-app.sh --no-bump      保持版本号不变（指纹照常更新）
#   ./build-app.sh --clean        先清掉 .build 再构建
#
# 版本号：唯一来源是工程根目录的 VERSION 文件（一行，形如 1.0.0）。
#   源码指纹有变 → 补丁位 +1（1.0.0 → 1.0.1）；首次打包不递增。
# ============================================================

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

CONFIGURATION="release"
DO_SIGN=1
DO_INSTALL=0
FORCE_BUMP=0
SKIP_BUMP=0
DO_CLEAN=0
SWIFT_FLAGS=()

for argument in "$@"; do
    case "$argument" in
        --debug)      CONFIGURATION="debug" ;;
        --no-sign)    DO_SIGN=0 ;;
        --no-sandbox) SWIFT_FLAGS+=(--disable-sandbox) ;;
        --install)    DO_INSTALL=1 ;;
        --bump)       FORCE_BUMP=1 ;;
        --no-bump)    SKIP_BUMP=1 ;;
        --clean)      DO_CLEAN=1 ;;
        -h|--help)
            sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "未知参数：${argument}（用 --help 查看用法）" >&2
            exit 1
            ;;
    esac
done

APP_NAME="BoxShot"
DISPLAY_NAME="BoxShot"
DIST_DIR="$PROJECT_ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

# ------------------------------------------------------------
# 0. 版本号
# ------------------------------------------------------------

VERSION_FILE="$PROJECT_ROOT/VERSION"
FINGERPRINT_FILE="$PROJECT_ROOT/VERSION.fingerprint"

SOURCE_INPUTS=(Package.swift build-app.sh Sources Resources)

read_version_file() {
    if [[ ! -f "$VERSION_FILE" ]]; then
        echo "错误：缺少 VERSION 文件（应包含一行形如 1.0.0 的版本号）" >&2
        exit 1
    fi
    local value
    value="$(tr -d '[:space:]' < "$VERSION_FILE")"
    if [[ ! "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "错误：VERSION 内容不合法：「${value}」。要求形如 1.0.0（三段数字）。" >&2
        exit 1
    fi
    printf '%s' "$value"
}

bump_patch_version() {
    local major minor patch
    IFS='.' read -r major minor patch <<< "$1"
    printf '%s.%s.%s' "$major" "$minor" "$((patch + 1))"
}

build_number_of() {
    local major minor patch
    IFS='.' read -r major minor patch <<< "$1"
    printf '%s' "$((major * 10000 + minor * 100 + patch))"
}

compute_source_fingerprint() {
    local records=()
    local path entry digest
    for path in ${SOURCE_INPUTS[@]+"${SOURCE_INPUTS[@]}"}; do
        [[ -e "$PROJECT_ROOT/$path" ]] || continue
        if [[ -d "$PROJECT_ROOT/$path" ]]; then
            while IFS= read -r -d '' entry; do
                digest="$(shasum -a 256 "$entry" | awk '{print $1}')"
                records+=("${entry#$PROJECT_ROOT/}:$digest")
            done < <(find "$PROJECT_ROOT/$path" -type f ! -name '.DS_Store' -print0)
        else
            digest="$(shasum -a 256 "$PROJECT_ROOT/$path" | awk '{print $1}')"
            records+=("${path}:$digest")
        fi
    done
    printf '%s\0' ${records[@]+"${records[@]}"} \
        | LC_ALL=C sort -z \
        | shasum -a 256 | awk '{print $1}'
}

CURRENT_VERSION="$(read_version_file)"
CURRENT_FINGERPRINT="$(compute_source_fingerprint)"

STORED_FINGERPRINT=""
if [[ -f "$FINGERPRINT_FILE" ]]; then
    STORED_FINGERPRINT="$(tr -d '[:space:]' < "$FINGERPRINT_FILE")"
fi

if [[ "$FORCE_BUMP" == "1" ]]; then
    APP_VERSION="$(bump_patch_version "$CURRENT_VERSION")"
    VERSION_REASON="--bump 强制递增"
elif [[ ! -f "$FINGERPRINT_FILE" ]]; then
    APP_VERSION="$CURRENT_VERSION"
    VERSION_REASON="首次打包，沿用 VERSION 里的初版号"
elif [[ "$SKIP_BUMP" == "1" ]]; then
    APP_VERSION="$CURRENT_VERSION"
    VERSION_REASON="--no-bump 保持版本号"
elif [[ "$CURRENT_FINGERPRINT" != "$STORED_FINGERPRINT" ]]; then
    APP_VERSION="$(bump_patch_version "$CURRENT_VERSION")"
    VERSION_REASON="源码有改动"
else
    APP_VERSION="$CURRENT_VERSION"
    VERSION_REASON="源码未变，沿用当前版本"
fi
APP_BUILD_NUMBER="$(build_number_of "$APP_VERSION")"

echo "${DISPLAY_NAME} 打包（${APP_NAME}）"
echo "────────────────────────────────────────────────────"
echo "  版本号：${APP_VERSION}（构建号 ${APP_BUILD_NUMBER}）· ${VERSION_REASON}"
echo "  构建配置：${CONFIGURATION}"
echo "  输出位置：${APP_DIR}"
echo ""

# ------------------------------------------------------------
# 1. 编译
# ------------------------------------------------------------
if [[ "$DO_CLEAN" == "1" ]]; then
    echo "▶ 清理 .build…"
    rm -rf "$PROJECT_ROOT/.build"
fi

echo "▶ 编译（${CONFIGURATION}）…"
swift build -c "$CONFIGURATION" --product "$APP_NAME" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"}

BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"})/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "错误：没有找到可执行文件 ${BIN_PATH}" >&2
    exit 1
fi
echo "  ✓ 可执行文件：${BIN_PATH}"

# ------------------------------------------------------------
# 2. 自检
#
# ⚠️ 铁律：自检**只能**跑 .build 下的裸产物，绝不 exec .app 内的二进制
#    （macOS 26 上那样做会让 bundle id 的状态栏登记永久失效）。
# ------------------------------------------------------------
echo "▶ 核心自检…"
if "$BIN_PATH" --selftest > /tmp/boxshot-selftest.log 2>&1; then
    grep -E '^✓' /tmp/boxshot-selftest.log | sed 's/^/  /' || true
else
    echo "  ✗ 自检未通过，停止打包。完整输出：/tmp/boxshot-selftest.log" >&2
    tail -20 /tmp/boxshot-selftest.log | sed 's/^/    /' >&2
    exit 1
fi

# ------------------------------------------------------------
# 3. 图标
#
# 母版 = Resources/icon-master.png（用户提供的应用图标图）。
# 每次打包都从母版重新生成 iconset → icns，确定性：同母版同字节。
# ------------------------------------------------------------
echo "▶ 生成图标…"
ICON_TMP="$(mktemp -d)"
ICONSET_DIR="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
ICON_OK=1
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    size="${spec%% *}"; name="${spec##* }"
    sips -s format png -z "$size" "$size" "$PROJECT_ROOT/Resources/icon-master.png" \
        --out "$ICONSET_DIR/${name}.png" > /dev/null 2>&1 || ICON_OK=0
done
if [[ "$ICON_OK" == "1" ]] && iconutil -c icns "$ICONSET_DIR" -o "$ICON_TMP/AppIcon.icns" 2>/dev/null; then
    ICON_READY=1
else
    ICON_READY=0
fi

# ------------------------------------------------------------
# 4. 组装 bundle
# ------------------------------------------------------------
echo "▶ 组装应用包…"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
printf 'APPL????' > "$CONTENTS/PkgInfo"

sed -e "s/__BOXSHOT_VERSION__/$APP_VERSION/g" \
    -e "s/__BOXSHOT_BUILD__/$APP_BUILD_NUMBER/g" \
    "$PROJECT_ROOT/Resources/Info.plist" > "$CONTENTS/Info.plist"

if grep -q '__BOXSHOT_' "$CONTENTS/Info.plist"; then
    echo "错误：Info.plist 里仍有未替换的占位符，版本注入不完整。" >&2
    exit 1
fi
plutil -lint "$CONTENTS/Info.plist" > /dev/null
echo "  ✓ Info.plist（版本 ${APP_VERSION} · 构建 ${APP_BUILD_NUMBER}）"

if [[ "$ICON_READY" == "1" ]]; then
    cp "$ICON_TMP/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
    echo "  ✓ AppIcon.icns"
else
    echo "  ⚠ 图标生成失败，使用系统默认图标（不影响功能）"
fi
rm -rf "$ICON_TMP"

xattr -cr "$APP_DIR" 2>/dev/null || true

# ------------------------------------------------------------
# 5. 签名（ad-hoc；不附加任何受限授权，AMFI 会拒）
# ------------------------------------------------------------
# 🔴 铁律：优先用固定的本机自签名身份，找不到才退回 ad-hoc。
#
# 系统记住 TCC 授权（屏幕录制 / 辅助功能 / 输入监控）时，存的是代码的
# **指定要求（designated requirement）**：
#   · ad-hoc  → 只能钉 `cdhash H"…"`，重新编译哈希就变，授权立刻对不上；
#   · 证书    → `identifier "…" and certificate root = H"…"`，跨版本稳定。
# 所以「能签名就用证书」不是好看，而是决定用户要不要每次更新重授一次权。
#
# 身份由 Tools/setup-signing-identity.sh 建立（不需要 sudo / 开发者账号）。
SIGNING_IDENTITY_NAME="FastFind Local Signing"

detect_signing_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep "$SIGNING_IDENTITY_NAME" | head -1 | awk '{print $2}'
}

SIGNING_IDENTITY=""
if [[ "$DO_SIGN" == "1" ]]; then
    SIGNING_IDENTITY="$(detect_signing_identity || true)"
fi

if [[ "$DO_SIGN" == "1" ]]; then
    if [[ -n "$SIGNING_IDENTITY" ]]; then
        echo "▶ 代码签名（${SIGNING_IDENTITY_NAME}）…"
        codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_DIR" 2>&1 | sed 's/^/  /' || {
            echo "  ⚠ 签名失败，应用仍可运行，但权限记忆可能不稳定" >&2
        }
    else
        echo "▶ 代码签名（ad-hoc）…"
        echo "  ⚠ 没找到「${SIGNING_IDENTITY_NAME}」身份，本次退回临时签名。"
        echo "    临时签名会让 TCC 授权在每次更新后失效；"
        echo "    跑一次 Tools/setup-signing-identity.sh 即可建立固定身份（不需要 sudo）。"
        codesign --force --sign - --timestamp=none "$APP_DIR" 2>&1 | sed 's/^/  /' || {
            echo "  ⚠ 签名失败，应用仍可运行，但权限记忆可能不稳定" >&2
        }
    fi
    if codesign --verify --deep --strict "$APP_DIR" 2>/dev/null; then
        echo "  ✓ 签名校验通过"
    else
        echo "  ⚠ 签名校验未通过（改用 --no-sign 可跳过这一步）" >&2
    fi

    # 把指定要求打出来：它是「下次更新后授权还在不在」的唯一判据，
    # 与其让用户猜，不如每次构建就摆在眼前。
    DESIGNATED_REQUIREMENT="$(codesign -d -r- "$APP_DIR" 2>&1 | sed -n 's/^designated => //p')"
    if [[ -n "$DESIGNATED_REQUIREMENT" ]]; then
        echo "  · 指定要求：${DESIGNATED_REQUIREMENT}"
        case "$DESIGNATED_REQUIREMENT" in
            cdhash*)
                echo "    ⚠ 这是临时签名的形态（钉死二进制哈希），更新一次就要重授一次。" >&2
                ;;
        esac
    fi
else
    echo "▶ 已跳过签名（--no-sign）"
fi

# ------------------------------------------------------------
# 6. 版本号落盘（放最后：中途失败不该吃掉一个版本号）
# ------------------------------------------------------------
printf '%s\n' "$APP_VERSION" > "$VERSION_FILE"
printf '%s\n' "$CURRENT_FINGERPRINT" > "$FINGERPRINT_FILE"

# ------------------------------------------------------------
# 7. 完成
# ------------------------------------------------------------
echo ""
echo "────────────────────────────────────────────────────"
echo "打包完成：${APP_DIR}"
echo "版本号：${APP_VERSION}（构建号 ${APP_BUILD_NUMBER}）"
echo ""
du -sh "$APP_DIR" | sed 's/^/  体积 /'

if [[ "$DO_INSTALL" == "1" ]]; then
    echo ""
    echo "▶ 安装到 /Applications…"
    INSTALLED_APP="/Applications/$APP_NAME.app"
    DIST_CDHASH="$(codesign -dvvv "$APP_DIR" 2>&1 | awk -F= '/^CDHash=/ {print $2; exit}')"
    rm -rf "$INSTALLED_APP"

    # 🔴 用 ditto 复制，**复制后绝不重新签名**。
    # 这里曾经是「cp -R + codesign --force --sign -」：那句话会把打包时签好的
    # 证书覆盖成临时签名，cdhash 一变，用户此前授的权当场作废 ——
    # 症状是「装完看着一切正常，功能一条都不触发」。
    # ditto 能保留权限位与扩展属性；xattr 不在签名封存范围里，清隔离属性是安全的。
    ditto "$APP_DIR" "$INSTALLED_APP"
    xattr -cr "$INSTALLED_APP" 2>/dev/null || true

    if ! codesign --verify --deep --strict "$INSTALLED_APP" 2>/dev/null; then
        echo "  ✗ 安装副本签名校验失败：${INSTALLED_APP}" >&2
        exit 1
    fi

    # 装完立刻比对 cdhash —— 这是「有没有被谁偷偷重签」的硬证据。
    INSTALLED_CDHASH="$(codesign -dvvv "$INSTALLED_APP" 2>&1 | awk -F= '/^CDHash=/ {print $2; exit}')"
    if [[ -z "$DIST_CDHASH" || "$DIST_CDHASH" != "$INSTALLED_CDHASH" ]]; then
        echo "  ✗ cdhash 不一致：dist=${DIST_CDHASH:-?} / 安装=${INSTALLED_CDHASH:-?}" >&2
        echo "    说明安装过程改动了签名封存，此前的授权会失效。" >&2
        exit 1
    fi
    echo "  ✓ 已安装：${INSTALLED_APP}（cdhash ${INSTALLED_CDHASH}）"
fi

cat <<'TIPS'

首次使用
────────────────────────────────────────────────────
1) 启动
     双击 dist/BoxShot.app。菜单栏常驻（不占 Dock），
     启动后看菜单栏多出来的相机图标。
     从别人机器拷来的副本第一次打开请右键 → 打开。

2) 权限
     第一次截图 / 录屏 / 用 OCR 时，系统会弹「屏幕录制」授权，
     允许并重启应用即可。录屏开声音 / 摄像头会再弹对应授权。

3) 快捷键（默认，可在「设置 → 快捷键」改）
     F7 开始截图    F8 截图 OCR    （F 键直接注册为全局热键）

4) 自检 / 诊断
     ⚠️ 不要直接执行 .app 里的二进制（Contents/MacOS/BoxShot）！
     用 .build 下的裸产物：
        .build/release/BoxShot --selftest
     打包后的 .app 请双击启动（经 LaunchServices）。
TIPS
