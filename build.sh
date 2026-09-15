#!/bin/bash
# 编译并组装 Claude Session Search.app（universal2：Apple Silicon + Intel）
#
# app 名字统一用英文（菜单栏 / Dock / Finder）。界面语言在 app 内切换，
# 与 bundle 名无关。
#
# 只需 Command Line Tools，不需要完整 Xcode。
#   ./build.sh            双架构构建 + 组装 .app
#   ./build.sh --fast     只构建当前架构（开发迭代用，快很多）
#   ./build.sh --install  装到 /Applications（已装则原地更新）
#   ./build.sh --run      构建后直接启动（配合 --install 则启动已安装的那份）

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Claude Session Search"
BINARY_NAME="ClaudeSessionSearch"
BUNDLE_ID="com.aaron.claude-session-search"
VERSION="1.0"
DIST="dist"
APP="$DIST/$APP_NAME.app"

FAST=false
RUN=false
INSTALL=false
for arg in "$@"; do
  case "$arg" in
    --fast)    FAST=true ;;
    --run)     RUN=true ;;
    --install) INSTALL=true ;;
  esac
done

INSTALL_DIR="/Applications"
INSTALLED="$INSTALL_DIR/$APP_NAME.app"

# app 曾用中文名。改名后旧 bundle 不会被覆盖，安装时要主动清掉，
# 否则 /Applications 里会同时留着两个。
LEGACY_NAMES=("Claude 会话搜索")

MIN_MACOS="14.0"

echo "▸ 编译"
if $FAST; then
  swift build -c release
  BIN=".build/release/$BINARY_NAME"
else
  # SwiftPM 的 --arch 双架构模式要走 xcbuild（需完整 Xcode），
  # 而 --triple 只依赖 Command Line Tools。分别构建再 lipo 合成。
  for arch in arm64 x86_64; do
    echo "  · $arch"
    swift build -c release --triple "$arch-apple-macosx$MIN_MACOS" >/dev/null
  done
  BIN="$DIST/$BINARY_NAME-universal"
  mkdir -p "$DIST"
  lipo -create -output "$BIN" \
    ".build/arm64-apple-macosx/release/$BINARY_NAME" \
    ".build/x86_64-apple-macosx/release/$BINARY_NAME"
fi

echo "▸ 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 别让构建产物出现在 Spotlight 里 —— 否则搜 app 名字会同时命中 dist/ 里的
# 中间产物和 /Applications 里装好的那份，分不清该点哪个。
touch "$DIST/.metadata_never_index"

# 曾用名留下的构建产物也清掉（app 改过名，旧 bundle 不会被覆盖）
for legacy in "${LEGACY_NAMES[@]}"; do
  [ -d "$DIST/$legacy.app" ] && rm -rf "$DIST/$legacy.app"
done
cp "$BIN" "$APP/Contents/MacOS/$BINARY_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$BINARY_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- 纯本地只读工具，不需要沙箱外的任何权限声明 -->
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSSupportsAutomaticTermination</key><true/>
</dict>
</plist>
PLIST

# 图标：用系统自带的 SF Symbol 渲不出来，这里用 Core Graphics 画一个简单的
echo "▸ 生成图标"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
PNG="$DIST/icon-1024.png"

python3 - "$PNG" <<'PY'
import sys, zlib, struct, math

SIZE = 1024
# 深蓝到青的对角渐变 + 中间一个放大镜轮廓
px = bytearray()
cx, cy, R, TH = SIZE*0.45, SIZE*0.45, SIZE*0.24, SIZE*0.055

def blend(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))

for y in range(SIZE):
    px.append(0)  # PNG 每行的 filter byte
    for x in range(SIZE):
        t = (x + y) / (2 * SIZE)
        r, g, b = blend((32, 58, 120), (24, 154, 180), t)

        d = math.hypot(x - cx, y - cy)
        # 镜圈
        if abs(d - R) < TH / 2:
            r, g, b = 245, 248, 252
        # 镜柄：从右下角伸出的一段粗线
        else:
            hx, hy = cx + R*0.72, cy + R*0.72
            ex, ey = cx + R*1.75, cy + R*1.75
            vx, vy = ex - hx, ey - hy
            L2 = vx*vx + vy*vy
            s = ((x - hx)*vx + (y - hy)*vy) / L2
            if 0 <= s <= 1:
                px_, py_ = hx + s*vx, hy + s*vy
                if math.hypot(x - px_, y - py_) < TH * 0.62:
                    r, g, b = 245, 248, 252
        px += bytes((r, g, b))

def chunk(tag, data):
    c = struct.pack(">I", len(data)) + tag + data
    return c + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(bytes(px), 9))
       + chunk(b"IEND", b""))
open(sys.argv[1], "wb").write(png)
PY

for s in 16 32 64 128 256 512; do
  sips -z $s $s "$PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
cp "$PNG" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" "$PNG"

# 临时签名：未签名的 .app 在 macOS 上双击会被 Gatekeeper 直接拦掉
echo "▸ 签名"
codesign --force --deep --sign - "$APP" 2>/dev/null

$FAST || rm -f "$DIST/$BINARY_NAME-universal"

echo
echo "✅ $APP"
lipo -info "$APP/Contents/MacOS/$BINARY_NAME" | sed 's/^/   /'
du -sh "$APP" | sed 's/^/   /'

TARGET="$APP"
if $INSTALL; then
  echo
  echo "▸ 安装到 $INSTALL_DIR"
  # 覆盖前先退掉正在运行的那份，否则替换掉正在执行的二进制会让它崩。
  # 连旧名字那份一起退，它跑的是同一个 bundle id。
  pkill -f "$BINARY_NAME" 2>/dev/null || true
  sleep 1
  # 先原子换入新版本，再把旧版本挪去垃圾桶。
  # 刻意不用 rm -rf 删应用目录：真要写错路径，那是不可逆的。
  ditto "$APP" "$INSTALLED.new"
  if [ -d "$INSTALLED" ]; then
    TRASH="$HOME/.Trash/$APP_NAME-$(date +%Y%m%d%H%M%S).app"
    mv "$INSTALLED" "$TRASH"
    echo "   旧版本已移到垃圾桶"
  fi
  mv "$INSTALLED.new" "$INSTALLED"

  # 清掉曾用名留下的 bundle
  for legacy in "${LEGACY_NAMES[@]}"; do
    OLD="$INSTALL_DIR/$legacy.app"
    if [ -d "$OLD" ]; then
      mv "$OLD" "$HOME/.Trash/$legacy-$(date +%Y%m%d%H%M%S).app"
      echo "   已清理曾用名: $legacy.app"
    fi
  done

  # 装好后就把构建产物挪走。留着它 Spotlight 会同时命中两份同名 app，
  # 分不清该点哪个 —— 而 .metadata_never_index 对已索引的条目不追溯生效。
  # 移到垃圾桶而非直接删：这个脚本删的是目录树，写错路径不可逆。
  mv "$APP" "$HOME/.Trash/$APP_NAME-build-$(date +%Y%m%d%H%M%S).app"

  TARGET="$INSTALLED"
  echo "   $INSTALLED"
fi

if $RUN; then
  echo "▸ 启动"
  open "$TARGET"
fi
