#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/FinderTerm.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/FinderTerm "$APP/Contents/MacOS/FinderTerm"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier com.iwama.finderterm "$APP"
echo "Built: $APP"
