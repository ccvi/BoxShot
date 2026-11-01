#!/usr/bin/env bash
#
# ============================================================
# 建立一份固定的本机代码签名证书
# ============================================================
#
# 【这是全家桶共用的那一张证书】
#
# 证书名固定为「FastFind Local Signing」，所有自研 macOS 应用都用它签名。
# 互不干扰：TCC 的授权条目是按 `identifier`（bundle id）+ 证书根一起认的，
# bundle id 不同就是不同应用，同一张证书不会把它们的权限搞混。
#
# 【为什么需要这个脚本】
#
# 系统记住一份「完全磁盘访问权限 / 辅助功能」授权时，存下来的不是应用的名字，
# 而是这份代码的**指定要求（designated requirement）**。而指定要求长什么样，
# 完全取决于签名方式：
#
#   临时签名（codesign -s -，也就是 ad-hoc）
#       指定要求只能写成 `cdhash H"…"` —— 也就是**钉死二进制的哈希**。
#       每重新编译一次，哈希就变一次，前面授的权立刻对不上。
#       用户看到的现象：更新一次应用，就得重新授权一次。
#
#   用证书签名
#       指定要求写成 `identifier "com.pcxx.fastfindmac" and
#                    certificate root = H"<证书哈希>"`。
#       它只跟 bundle id 和证书有关，**与二进制内容无关** ——
#       从此重新编译多少次，授权都还在。
#
# 本脚本做的就是造一份这样的证书：一张自签名的代码签名证书，
# 装进**登录钥匙串**，并在**用户域**里把它标成受信任的根。
#
# 全程不需要 sudo，也不需要 Apple 开发者账号。
# 唯一可能需要用户点一下的是钥匙串授权提示（如果出现，选「始终允许」）。
#
# 【它是幂等的】
#
# 已经有同名身份时直接退出，不会重复创建。想重来就先删掉：
#     security delete-identity -c "FastFind Local Signing"
#
# 用法：
#     Tools/setup-signing-identity.sh
# ============================================================

set -euo pipefail

IDENTITY_NAME="FastFind Local Signing"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

echo "本机固定代码签名身份（FastFind Local Signing）"
echo "────────────────────────────────────────────────────"

# ------------------------------------------------------------
# 0. 已经建过就直接收工
# ------------------------------------------------------------
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
    EXISTING="$(security find-identity -v -p codesigning 2>/dev/null \
                | grep "$IDENTITY_NAME" | head -1 \
                | awk '{print $2}')"
    echo "  ✓ 已存在：${IDENTITY_NAME}（${EXISTING}）"
    echo ""
    echo "不需要重复创建。打包时 build-app.sh 会自动用它签名。"
    exit 0
fi

for tool in openssl security codesign; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "错误：缺少命令 ${tool}" >&2
        exit 1
    fi
done

WORK_DIR="$(mktemp -d /tmp/local-signing.XXXXXX)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# ------------------------------------------------------------
# 1. 自签名的代码签名证书
#
# extendedKeyUsage 必须是 codeSigning，否则 codesign 根本不认这份身份。
# basicConstraints 标成 CA:false：它只用来签这一份应用，不是要当根 CA 用。
# 有效期给 10 年——授权是跟着这张证书走的，证书一过期授权也就没了。
# ------------------------------------------------------------
echo "▶ 生成自签名证书…"
cat > "$WORK_DIR/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = FastFind Local Signing
O  = FastFind
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" \
    -days 3650 -config "$WORK_DIR/cert.cnf" > /dev/null 2>&1

# OpenSSL 3 默认用 AES-256 + SHA-256 打包 p12，而 macOS 的 security 读不了。
# 必须显式退回兼容参数，否则会得到那句极具误导性的
# 「MAC verification failed during PKCS12 import (wrong password?)」——
# 密码是对的，是算法不兼容。
openssl pkcs12 -export -out "$WORK_DIR/identity.p12" \
    -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" \
    -passout pass:fastfind -legacy \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 > /dev/null 2>&1 \
  || openssl pkcs12 -export -out "$WORK_DIR/identity.p12" \
    -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" \
    -passout pass:fastfind \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 > /dev/null 2>&1

if [[ ! -s "$WORK_DIR/identity.p12" ]]; then
    echo "错误：p12 打包失败" >&2
    exit 1
fi
echo "  ✓ 证书已生成"

# ------------------------------------------------------------
# 2. 装进登录钥匙串
#
# 装登录钥匙串而不是自己新建一个专用钥匙串，是因为 codesign 只会去
# 「钥匙串搜索列表」里找身份，而新建的钥匙串默认不在那个列表里——
# 要么每次构建前改用户的搜索列表（动用户的配置，不好），
# 要么用 --keychain 参数（实测对自签名身份无效，只会报 no identity found）。
# 装进登录钥匙串则是零配置。
#
# -A：允许任何程序使用这份私钥而不弹窗。
#     这里可以接受——私钥只用于本机给自己签个本地应用，不是分发用的身份。
# ------------------------------------------------------------
echo "▶ 导入登录钥匙串…"
security import "$WORK_DIR/identity.p12" -k "$LOGIN_KEYCHAIN" \
    -P fastfind -T /usr/bin/codesign -A > /dev/null
echo "  ✓ 已导入"

# ------------------------------------------------------------
# 3. 标成受信任（用户域，不需要 sudo）
#
# 不加 -d 就是用户域。加 -d 会写系统域的信任设置，那需要管理员权限，
# 而这个场景完全不必——这台机器上的这个用户信任它自己造的证书就够了。
# ------------------------------------------------------------
echo "▶ 标记为受信任（用户域）…"
if security add-trusted-cert -r trustRoot -k "$LOGIN_KEYCHAIN" "$WORK_DIR/cert.pem" 2>&1; then
    echo "  ✓ 已信任"
else
    echo "  ⚠ 信任设置没写成功。若下面找不到身份，请到「钥匙串访问」里" >&2
    echo "    把「FastFind Local Signing」的信任改成「始终信任」。" >&2
fi

# ------------------------------------------------------------
# 4. 验收
# ------------------------------------------------------------
echo ""
IDENTITY_HASH="$(security find-identity -v -p codesigning 2>/dev/null \
                 | grep "$IDENTITY_NAME" | head -1 | awk '{print $2}')"

if [[ -z "$IDENTITY_HASH" ]]; then
    echo "错误：身份没有出现在 codesign 的可用列表里。" >&2
    echo "可以在「钥匙串访问 → 登录 → 我的证书」里手动把它的信任设为「始终信任」。" >&2
    echo "" >&2
    exit 1
fi

echo "────────────────────────────────────────────────────"
echo "完成。"
echo "  身份名称：${IDENTITY_NAME}"
echo "  身份指纹：${IDENTITY_HASH}"
echo ""
echo "以后每次 ./build-app.sh 都会自动用它签名。"
echo "授权（完全磁盘访问 / 辅助功能）只要授一次，之后重新构建也不会失效——"
echo "因为系统记住的是「${IDENTITY_NAME} 签的那个 bundle id」，"
echo "而不是某一版二进制的哈希。"
echo ""
echo "想确认签名结果，构建完跑："
echo "  codesign -d -r- dist/<应用名>.app"
echo "应该看到 identifier 加上 certificate root 的形式，而不是 cdhash H\"...\"。"
