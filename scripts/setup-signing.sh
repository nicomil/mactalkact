#!/bin/bash
# Crea un certificato locale per firmare MacTalkAct e lo aggiunge al Portachiavi di login.
#
# Perché: con la firma ad-hoc macOS identifica l'app tramite l'impronta del file,
# che cambia a ogni compilazione, e il permesso di Accessibilità va riconcesso ogni volta.
# Con un certificato stabile l'app viene riconosciuta per nome e certificato:
# il permesso si concede una volta sola.
#
# Il certificato serve solo a firmare questa app sul tuo Mac. Per rimuoverlo:
# Accesso Portachiavi › login › Certificati › «MacTalkAct Local Signing» › Elimina.
set -euo pipefail

NAME="MacTalkAct Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Il certificato «${NAME}» esiste già."
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat > cert.cnf <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = MacTalkAct Local Signing
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# OpenSSL di sistema: le versioni recenti (es. Homebrew) creano file .p12 con
# algoritmi che il Portachiavi non sa leggere («MAC verification failed»).
OPENSSL=/usr/bin/openssl
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
PASS=$("$OPENSSL" rand -hex 12)
"$OPENSSL" pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout "pass:$PASS" -name "$NAME" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

security import id.p12 -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
echo "Certificato importato nel Portachiavi."

# Prova di firma: se macOS non si fida del certificato, chiede di fidarsi (password richiesta).
cp /bin/echo ./probe
if ! codesign --force --sign "$NAME" ./probe 2>/dev/null; then
    echo "Serve impostare la fiducia per la firma del codice: macOS ti chiederà la password."
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" cert.pem
    codesign --force --sign "$NAME" ./probe
fi
echo "Pronto: ora scripts/build-app.sh firma con «${NAME}»."
