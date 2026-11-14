#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Dependencies
if [ ! -d Dependencies/Python.xcframework ]; then
  curl -fL --retry 3 'https://github.com/beeware/Python-Apple-support/releases/download/3.13-b18/Python-3.13-iOS-support.b18.tar.gz' -o Dependencies/python.tar.gz
  echo 'd06acf2a9c7964a8689566353a0e707402eff822037de5e29ba0e16040f7047d  Dependencies/python.tar.gz' | shasum -a 256 -c -
  tar -xzf Dependencies/python.tar.gz -C Dependencies
  rm Dependencies/python.tar.gz
fi
python3 -m pip install --disable-pip-version-check --upgrade --target Dependencies/python-packages \
  'yt-dlp==2026.10.26' 'yt-dlp-ejs==0.8.0' 'certifi==2026.10.23'
# The interpreter reads sources directly from the signed bundle.
find Dependencies/python-packages -type d -name __pycache__ -prune -exec rm -rf {} +
