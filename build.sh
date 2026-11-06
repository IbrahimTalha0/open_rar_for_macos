#!/bin/zsh
# RarAc.app uygulamasını build/ altına derler. Kullanım: ./build.sh
set -euo pipefail
cd "${0:A:h}"

TARGET=arm64-apple-macos13.0
BUILD=build
OBJ=$BUILD/obj
APP=$BUILD/RarAc.app
UNRAR=vendor/unrar
mkdir -p "$OBJ"

# UnRAR makefile'ındaki kitaplık nesneleriyle aynı liste.
UNRAR_SOURCES=(rar strlist strfn pathfn smallfn global file filefn filcreat archive arcread
  unicode system crypt crc rawread encname resource match timefn rdwrfn consio options errhnd
  rarvm secpassword rijndael getbits sha1 sha256 blake2s hash extinfo extract volume list find
  unpack headers threadpool rs16 cmddata ui largepage filestr scantree dll qopen)

CXXFLAGS=(-target $TARGET -std=c++11 -O3 -DRARDLL -DRAR_SMP -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE
  -fvisibility=hidden -ffunction-sections -fdata-sections
  -Wno-logical-op-parentheses -Wno-switch -Wno-dangling-else -Wno-deprecated-declarations)

# UnRAR yalnızca ilk derlemede derlenir, sonraki derlemeler hızlı olur.
if [[ ! -f $OBJ/libunrar.a ]]; then
  echo "UnRAR derleniyor…"
  print -l $UNRAR_SOURCES | xargs -P "$(sysctl -n hw.ncpu)" -I{} \
    clang++ $CXXFLAGS -c "$UNRAR/{}.cpp" -o "$OBJ/{}.o"
  libtool -static -o "$OBJ/libunrar.a" "$OBJ"/*.o 2>/dev/null
fi

echo "Köprü ve uygulama derleniyor…"
clang++ $CXXFLAGS -I"$UNRAR" -ISources/CRarAc -c Sources/CRarAc/rarac_shim.cpp -o "$BUILD/rarac_shim.o"

SWIFT_FLAGS=(-target $TARGET -swift-version 5 -O -whole-module-optimization
  -import-objc-header Sources/CRarAc/rarac_shim.h)
LINK_FLAGS=("$BUILD/rarac_shim.o" "$OBJ/libunrar.a" -lc++ -Xlinker -dead_strip)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc $SWIFT_FLAGS Sources/App/*.swift $LINK_FLAGS -o "$APP/Contents/MacOS/RarAc"
strip -x "$APP/Contents/MacOS/RarAc"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$UNRAR/license.txt" "$APP/Contents/Resources/unrar-license.txt"

if [[ ! -f $BUILD/AppIcon.icns ]]; then
  echo "Simge oluşturuluyor…"
  swiftc -O scripts/make-icon.swift -o "$BUILD/make-icon"
  "$BUILD/make-icon" "$BUILD/icon-1024.png"
  rm -rf "$BUILD/AppIcon.iconset"
  mkdir "$BUILD/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$BUILD/icon-1024.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$BUILD/icon-1024.png" --out "$BUILD/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
fi
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Apple Silicon her uygulamada ücretsiz yerel imza ister; geliştirici hesabı gerekmez.
codesign --force --sign - "$APP"

echo "Hazır: $APP ($(du -sh "$APP" | cut -f1))"
