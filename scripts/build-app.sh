#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/FinderTerm.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/FinderTerm "$APP/Contents/MacOS/FinderTerm"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 自己署名証明書があればそれを使う(署名が安定し、再ビルドしてもTCC権限が維持される)。
# なければad-hoc(再ビルドごとにアクセシビリティ許可の再付与が必要)。
IDENTITY="FinderTerm Dev Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" --identifier com.iwama.finderterm "$APP"
else
  codesign --force --sign - --identifier com.iwama.finderterm "$APP"
fi
echo "Built: $APP"
