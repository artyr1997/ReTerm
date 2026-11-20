#!/bin/sh
# Builds ReTerm.app into build/ and, with --install, puts it next to the other Re apps.
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/ReTerm.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ReTerm "$APP/Contents/MacOS/ReTerm"
cp Info.plist "$APP/Contents/"
cp -R Resources/* "$APP/Contents/Resources/"
# ad-hoc, known by its identifier rather than by this build's hash
codesign --force -s - -r='designated => identifier "com.artursavytskyi.reterm"' "$APP"
if [ "$1" = "--install" ]; then
	DEST=/Applications/ReSpace
	[ -d "$DEST" ] || DEST=/Applications
	osascript -e 'quit app id "com.artursavytskyi.reterm"' 2>/dev/null || true
	sleep 1
	rm -rf "$DEST/ReTerm.app"
	cp -R "$APP" "$DEST/"
fi
