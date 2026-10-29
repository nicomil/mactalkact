#!/bin/bash
# Prepara zip e DMG di una release in build/dist, firmati ad-hoc (per chi scarica l'app).
# Non tocca build/MacTalkAct.app, che resta firmata con il certificato locale: se venisse
# rifirmata ad-hoc, macOS la tratterebbe come un'app nuova e i permessi già concessi
# (Accessibilità, Registrazione schermo) smetterebbero di valere.
# Uso: scripts/package-release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
scripts/build-app.sh

OUT=build/dist
rm -rf "$OUT"
mkdir -p "$OUT/dmg"
ditto build/MacTalkAct.app "$OUT/MacTalkAct.app"
codesign --force --sign - --identifier local.mactalkact "$OUT/MacTalkAct.app"
ditto -c -k --keepParent "$OUT/MacTalkAct.app" "$OUT/MacTalkAct-$VERSION.zip"

ditto "$OUT/MacTalkAct.app" "$OUT/dmg/MacTalkAct.app"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -volname "MacTalkAct $VERSION" -srcfolder "$OUT/dmg" -ov -format UDZO "$OUT/MacTalkAct-$VERSION.dmg" >/dev/null
hdiutil verify "$OUT/MacTalkAct-$VERSION.dmg" >/dev/null
rm -rf "$OUT/dmg" "$OUT/MacTalkAct.app"

echo "Pronti in $OUT:"
(cd "$OUT" && shasum -a 256 MacTalkAct-"$VERSION".zip MacTalkAct-"$VERSION".dmg)
