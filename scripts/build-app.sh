#!/bin/bash
# Compila MacTalkAct e lo impacchetta in build/MacTalkAct.app.
# Uso: scripts/build-app.sh            (firma ad-hoc)
#      SIGN_IDENTITY="Nome certificato" scripts/build-app.sh   (firma stabile)
set -euo pipefail
cd "$(dirname "$0")/.."

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift build -c release

APP="build/MacTalkAct.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MacTalkAct "$APP/Contents/MacOS/MacTalkAct"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Con la firma ad-hoc ("-") macOS considera ogni build un'app nuova:
# dopo ogni ricompilazione va riattivato il permesso di Accessibilità.
# Se esiste il certificato creato da scripts/setup-signing.sh lo usiamo:
# così il permesso resta valido tra una build e l'altra.
LOCAL_CERT="MacTalkAct Local Signing"
if [ -z "${SIGN_IDENTITY:-}" ] && security find-certificate -c "$LOCAL_CERT" >/dev/null 2>&1; then
    SIGN_IDENTITY="$LOCAL_CERT"
fi
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier local.mactalkact "$APP"
echo "Firmato con: ${SIGN_IDENTITY:-ad-hoc (il permesso di Accessibilità andrà riconcesso a ogni build)}"

echo "Pronto: $APP"
echo "Avvia con: open $APP"
