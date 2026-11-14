#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo 'Install XcodeGen: brew install xcodegen' >&2; exit 1; }
xcodegen generate
xcodebuild -project Riff.xcodeproj -scheme Riff -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
mkdir -p build/package/Payload
cp -R build/Build/Products/Release-iphoneos/Riff.app build/package/Payload/
(cd build/package && zip -qr ../Riff-unsigned.ipa Payload)
echo "Unsigned IPA: $PWD/build/Riff-unsigned.ipa (requires sideload signing)"
