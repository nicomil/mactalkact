#!/bin/bash
# Compila MacTalkAct e lo impacchetta in build/MacTalkAct.app.
# Uso: scripts/build-app.sh            (firma ad-hoc)
#      SIGN_IDENTITY="Nome certificato" scripts/build-app.sh   (firma stabile)
set -euo pipefail
cd "$(dirname "$0")/.."

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift build -c release
mkdir -p build

# Prima di ogni build distribuita (Storia 9.4): instradamento e riconoscimento delle azioni rischiose.
# Senza schermo, quindi sempre. La suite di sicurezza agisce sullo schermo e usa un motore:
# solo con SECURITY_SUITE=1 (e SECURITY_ENGINE=claude|codex|local, predefinito local).
# Il modello sul dispositivo appena dopo la compilazione può essere freddo: un secondo tentativo,
# e in caso di errore le ultime righe del resoconto.
if ! .build/release/MacTalkAct --route-test > build/route-test.log 2>&1 && ! .build/release/MacTalkAct --route-test > build/route-test.log 2>&1; then
    tail -n 25 build/route-test.log; echo "Instradamento: errori critici nel Corpus"; exit 1
fi
.build/release/MacTalkAct --security-coverage || { echo "Copertura del riconoscimento: sotto il minimo, falsi allarmi o pulsanti non classificati"; exit 1; }
.build/release/MacTalkAct --selftest || { echo "Selftest fallito"; exit 1; }
if [ "${SECURITY_SUITE:-0}" = "1" ]; then
    .build/release/MacTalkAct --security-suite --engine "${SECURITY_ENGINE:-local}" || { echo "Suite di sicurezza fallita"; exit 1; }
else
    echo "ATTENZIONE: suite di sicurezza saltata. Per una build da distribuire: SECURITY_SUITE=1 scripts/build-app.sh (agisce sullo schermo)."
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
