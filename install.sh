#!/bin/bash
# Baut den Free-Pascal-Jupyter-Kernel und registriert ihn bei Jupyter.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo ">> Pruefe Voraussetzungen..."
command -v fpc >/dev/null 2>&1 || { echo "FEHLER: 'fpc' (Free Pascal Compiler) nicht gefunden. Bitte installieren, z.B.: sudo apt install fpc"; exit 1; }
command -v jupyter >/dev/null 2>&1 || { echo "FEHLER: 'jupyter' nicht gefunden. Bitte installieren, z.B.: pip install jupyterlab"; exit 1; }
ldconfig -p 2>/dev/null | grep -q libzmq || echo "WARNUNG: libzmq scheint nicht installiert zu sein. Ggf.: sudo apt install libzmq5"

echo ">> Kompiliere pascalkernel..."
fpc -Mobjfpc -O2 -Fu~/fpcupdeluxe/fpc/units/x86_64-linux/rtl/ -Fu~/fpcupdeluxe/fpc/units/x86_64-linux/rtl-objpas/ -Fu~/fpcupdeluxe/fpc/units/x86_64-linux/fcl-base/ -Fu~/fpcupdeluxe/fpc/units/x86_64-linux/fcl-process/ -Fu~/fpcupdeluxe/fpc/units/x86_64-linux/fcl-json/ pascalkernel.lpr

BINARY_PATH="$SCRIPT_DIR/pascalkernel"

echo ">> Erzeuge Kernelspec..."
KERNEL_DIR="$SCRIPT_DIR/kernelspec/pascal"
mkdir -p "$KERNEL_DIR"
sed "s#__BINARY_PATH__#$BINARY_PATH#" kernel.json.template > "$KERNEL_DIR/kernel.json"

# Icon fuer den JupyterLab-Launcher (falls vorhanden)
if [ -d "$SCRIPT_DIR/icons" ]; then
  cp "$SCRIPT_DIR/icons/logo-32x32.png" "$KERNEL_DIR/" 2>/dev/null || true
  cp "$SCRIPT_DIR/icons/logo-64x64.png" "$KERNEL_DIR/" 2>/dev/null || true
fi

echo ">> Installiere Kernelspec bei Jupyter (--user)..."
jupyter kernelspec install "$KERNEL_DIR" --user --name pascal --replace

echo ">> Fertig! Kernel 'Free Pascal' ist jetzt in Jupyter/JupyterLab verfuegbar."
echo "   Test: jupyter console --kernel pascal"
echo "   Oder: jupyter lab   (dann im Launcher 'Free Pascal' waehlen)"
