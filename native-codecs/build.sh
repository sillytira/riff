#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
RIFF_CODEC_ROOT="$PWD"
RIFF_CODEC_BUILD="$RIFF_CODEC_ROOT/build"
mkdir -p "$RIFF_CODEC_BUILD/sources"

fetch() {
  local name="$1" url="$2" checksum="$3"
  local archive="$RIFF_CODEC_BUILD/sources/$name.tar.gz"
  if [ ! -f "$archive" ]; then curl --fail --location --retry 3 "$url" -o "$archive"; fi
  echo "$checksum  $archive" | shasum -a 256 -c -
  if [ ! -d "$RIFF_CODEC_BUILD/sources/$name" ]; then
    mkdir -p "$RIFF_CODEC_BUILD/sources/$name"
    tar -xzf "$archive" --strip-components=1 -C "$RIFF_CODEC_BUILD/sources/$name"
  fi
}
fetch ffmpeg https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/n8.0.1 679aa13a19415d5ddab91e580084e3ab20c963c8240001e5cbb955a97bdd81b1
fetch lame https://codeload.github.com/lameproject/lame/tar.gz/1f5cc9487284d5950343aa5d4f70de433468070a b6b8a1e8e10a1353966345a5cd5efb10147afd1f26103951aa3dc36f2eb900dd
fetch opus https://codeload.github.com/xiph/opus/tar.gz/refs/tags/v1.5.2 65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1

build_target() {
  local sdk="$1" arch=arm64 minimum compiler sysroot flags prefix work
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  compiler="$(xcrun --sdk "$sdk" --find clang)"
  prefix="$RIFF_CODEC_BUILD/$sdk/install"
  work="$RIFF_CODEC_BUILD/$sdk"
  mkdir -p "$prefix" "$work/lame" "$work/ffmpeg"
  case "$sdk" in
    iphoneos) minimum='-miphoneos-version-min=18.0' ;;
    iphonesimulator) minimum='-mios-simulator-version-min=18.0' ;;
    macosx) minimum='-mmacosx-version-min=14.0' ;;
    *) echo "Unknown SDK $sdk" >&2; exit 1 ;;
  esac
  flags="-arch $arch -isysroot $sysroot $minimum -O2 -fPIC"
  (
    cd "$work/lame"
    CC="$compiler" CFLAGS="$flags" LDFLAGS="$flags" "$RIFF_CODEC_BUILD/sources/lame/configure" \
      --host=aarch64-apple-darwin --prefix="$prefix" --enable-static --disable-shared \
      --disable-frontend --disable-decoder --disable-dependency-tracking
    make -j3
    make install
  )
  local cmake_platform=Darwin
  if [ "$sdk" != macosx ]; then cmake_platform=iOS; fi
  cmake -S "$RIFF_CODEC_BUILD/sources/opus" -B "$work/opus" \
    -DCMAKE_SYSTEM_NAME="$cmake_platform" -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_C_COMPILER="$compiler" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$(if [ "$sdk" = macosx ]; then echo 14.0; else echo 18.0; fi)" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF \
    -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_INSTALL_PKG_CONFIG_MODULE=ON
  cmake --build "$work/opus" --parallel 3
  cmake --install "$work/opus"
  (
    cd "$work/ffmpeg"
    local programs=(--disable-programs --disable-avfilter) cross=(--enable-cross-compile --target-os=darwin --arch=aarch64)
    if [ "$sdk" = macosx ]; then programs=(--enable-ffmpeg --enable-ffprobe --enable-avfilter --enable-filter=abuffer,abuffersink,aformat,aresample,anull,atrim,asetpts); cross=(--target-os=darwin --arch=aarch64); fi
    PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" "$RIFF_CODEC_BUILD/sources/ffmpeg/configure" \
      --prefix="$prefix" --cc="$compiler" --sysroot="$sysroot" "${cross[@]}" \
      --extra-cflags="$flags -I$prefix/include" --extra-ldflags="$flags -L$prefix/lib" \
      --pkg-config-flags=--static --enable-static --disable-shared --enable-pic \
      --disable-autodetect --disable-doc --disable-debug --enable-small \
      --disable-everything --disable-avdevice --disable-swscale \
      "${programs[@]}" --enable-avcodec --enable-avformat --enable-swresample \
      --enable-network --enable-securetransport --enable-libmp3lame --enable-libopus \
      --enable-protocol=file,http,https,tcp,tls,crypto,data \
      --enable-demuxer=mov,mp3,ogg,flac,wav,aac,hls,aiff,matroska,ape,wv,tta,mpc,mpc8,dsf,dsdiff,asf,mpegts \
      --enable-decoder=aac,aac_fixed,aac_latm,mp3,mp3float,flac,opus,vorbis,alac,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f64le,wmav1,wmav2,wavpack,ape,tta,mpc7,mpc8 \
      --enable-parser=aac,aac_latm,flac,mpegaudio,opus,vorbis \
      --enable-encoder=libmp3lame,libopus,aac,flac,pcm_s16le,pcm_s24le,pcm_f32le \
      --enable-muxer=mp3,mp4,ipod,flac,ogg,wav,adts,matroska --enable-bsf=aac_adtstoasc
    make -j3
    make install
  )
  libtool -static -o "$work/libRiffCodecs.a" "$prefix/lib/libavformat.a" "$prefix/lib/libavcodec.a" \
    "$prefix/lib/libswresample.a" "$prefix/lib/libavutil.a" "$prefix/lib/libmp3lame.a" "$prefix/lib/libopus.a"
}

if [ "${1:-all}" = host ]; then
  build_target macosx
  exit
fi
build_target iphoneos
build_target iphonesimulator
rm -rf "$RIFF_CODEC_BUILD/RiffCodecs.xcframework"
xcodebuild -create-xcframework \
  -library "$RIFF_CODEC_BUILD/iphoneos/libRiffCodecs.a" -headers "$RIFF_CODEC_BUILD/iphoneos/install/include" \
  -library "$RIFF_CODEC_BUILD/iphonesimulator/libRiffCodecs.a" -headers "$RIFF_CODEC_BUILD/iphonesimulator/install/include" \
  -output "$RIFF_CODEC_BUILD/RiffCodecs.xcframework"
mkdir -p "$RIFF_CODEC_BUILD/Licenses"
cp "$RIFF_CODEC_BUILD/sources/ffmpeg/COPYING.LGPLv2.1" "$RIFF_CODEC_BUILD/Licenses/FFmpeg-LGPL-2.1.txt"
cp "$RIFF_CODEC_BUILD/sources/lame/COPYING" "$RIFF_CODEC_BUILD/Licenses/LAME-LGPL.txt"
cp "$RIFF_CODEC_BUILD/sources/opus/COPYING" "$RIFF_CODEC_BUILD/Licenses/Opus-BSD.txt"
cp "$RIFF_CODEC_BUILD/iphoneos/ffmpeg/config.h" "$RIFF_CODEC_BUILD/Licenses/ffmpeg-config.h"
cp "$RIFF_CODEC_BUILD/iphoneos/ffmpeg/ffbuild/config.mak" "$RIFF_CODEC_BUILD/Licenses/ffmpeg-config.mak"
