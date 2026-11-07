#!/bin/bash
# Richtet einmalig den Deploy-Key ein, mit dem der Release-Workflow den Homebrew-Tap aktualisiert:
# Schlüssel erzeugen → öffentlicher Teil als Deploy-Key (Schreibrecht) in l151820/homebrew-tap,
# privater Teil als Secret TAP_DEPLOY_KEY in l151820/MacIPMI → lokale Kopie löschen.
set -euo pipefail
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
ssh-keygen -q -t ed25519 -N "" -C "MacIPMI release workflow" -f "$DIR/key"
gh repo deploy-key add "$DIR/key.pub" --repo l151820/homebrew-tap --allow-write --title "MacIPMI release workflow"
gh secret set TAP_DEPLOY_KEY --repo l151820/MacIPMI < "$DIR/key"
echo "Fertig: Deploy-Key angelegt, Secret TAP_DEPLOY_KEY gesetzt, lokale Kopie gelöscht."
