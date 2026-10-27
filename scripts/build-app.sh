#!/bin/bash
# Compila MacTalkAct e lo impacchetta in build/MacTalkAct.app.
# Uso: scripts/build-app.sh            (firma ad-hoc)
#      SIGN_IDENTITY="Nome certificato" scripts/build-app.sh   (firma stabile)
set -euo pipefail
cd "$(dirname "$0")/.."

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift build -c release

# Prima di ogni build distribuita (Storia 9.4): instradamento e riconoscimento delle azioni rischiose.
# Senza schermo, quindi sempre. La suite di sicurezza agisce sullo schermo e usa un motore:
# solo con SECURITY_SUITE=1 (e SECURITY_ENGINE=claude|codex|local, predefinito local).
.build/release/MacTalkAct --route-test >/dev/null || { echo "Instradamento: errori critici nel Corpus"; exit 1; }
.build/release/MacTalkAct --security-coverage || { echo "Copertura del riconoscimento sotto il minimo"; exit 1; }
if [ "${SECURITY_SUITE:-0}" = "1" ]; then
    .build/release/MacTalkAct --security-suite --engine "${SECURITY_ENGINE:-local}" || { echo "Suite di sicurezza fallita"; exit 1; }
fi

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
