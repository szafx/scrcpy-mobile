#!/bin/bash

set -e;
set -x;

porting_root=$(pwd);
output_dir=$(cd "$output_dir" && pwd);
vncclient_source=$(cd "../external/" && pwd)/libvncserver;

[[ -d "$vncclient_source" ]] || {
  echo "❌ ERROR: Cannot find libvncserver source at $vncclient_source";
  echo "- Please make sure you have executed 'git submodule update --init --recursive' before running this script.";
  exit 1;
}

# Extract target and platform
# shellcheck disable=SC2154
target_name=$(echo "$target" | cut -d: -f1);
platform=$(echo "$target" | cut -d: -f2);

echo "Compiling target $target_name for vncclinet ..";
target_dir="$output_dir/$target_name";
[[ ! -d "$target_dir" ]] && mkdir -pv "$target_dir";
target_dir=$(cd "$target_dir" && pwd);

cd "$vncclient_source" || exit;

[[ -d build ]] && rm -rfv build;
mkdir -pv build;
cd build || exit;

cp -av "$porting_root/cmake/CMakeLists.vncserver.txt" "$vncclient_source/CMakeLists.txt";
# ★ 关键：必须显式关掉这些「可选依赖」，否则 CMake 会在 **runner 本机** 找到它们
#   （brew 装的 gcrypt / jpeg / lzo 都是 macOS x86_64/arm64 的 dylib，根本不能链进 iOS），
#   于是 libvncclient.a 里留下 _gcry_* / _jpeg_* / _lzo1x_* 一堆未定义符号，
#   最后 App 链接阶段才炸：ld: symbol(s) not found for architecture arm64。
#   - WITH_GCRYPT=OFF → 退回 OpenSSL 后端（crypto_openssl.c，由 make openssl 出的 iOS 库满足）
#   - WITH_JPEG=OFF  → 不再编 common/turbojpeg.c
#   - WITH_LZO=OFF   → 改用自带的 common/minilzo.c，不依赖系统 lzo
cmake -DCMAKE_BUILD_TYPE=Debug .. -DCMAKE_TOOLCHAIN_FILE="$porting_root/../ios-cmake/ios.toolchain.cmake" \
  -DPLATFORM="$platform" -DWITH_OPENSSL=ON -DWITH_GNUTLS=OFF \
  -DWITH_GCRYPT=OFF -DWITH_JPEG=OFF -DWITH_LZO=OFF -DWITH_SASL=OFF \
  -DWITH_PNG=OFF -DWITH_SDL=OFF -DWITH_GTK=OFF -DWITH_LIBSSH2=OFF \
  -DWITH_FFMPEG=OFF -DWITH_SYSTEMD=OFF -DWITH_EXAMPLES=OFF -DWITH_TESTS=OFF;

cmake --build . --target vncclient;

cp -av rfb "$output_dir/include/";
cp -av "$vncclient_source/rfb" "$output_dir/include/";
cp -av libvncclient.a "$target_dir/";

echo "✅ Done.";