# Free Pascal Kernel für Jupyter / IPython

Ein einfacher, eigenständiger Jupyter-Kernel, komplett in **Free Pascal**
geschrieben — ohne Python-Wrapper. Er spricht das Jupyter-Messaging-Protokoll
(Version 5.3) direkt über ZeroMQ.

Jede Code-Zelle wird als eigenständiges Pascal-Programm behandelt: der Kernel
schreibt den Zelleninhalt in eine `.pas`-Datei, kompiliert sie mit `fpc` und
führt das entstandene Programm aus. `stdout`/`stderr` werden an den
Jupyter-Client zurückgestreamt, Kompilierfehler als `error`-Nachricht mit
Traceback.

## Funktionsumfang

- Vollständige Socket-Architektur: `shell`, `iopub`, `stdin`, `control`, `heartbeat`
- Nachrichtentypen: `kernel_info_request`, `execute_request`, `is_complete_request`,
  `complete_request` (Tab-Vervollständigung), `shutdown_request`
- Nachrichten-Signierung per HMAC-SHA256 (selbst implementiert, keine externen
  Krypto-Bibliotheken nötig)
- ZeroMQ-Anbindung per dynamischem Laden von `libzmq` (kein Linken gegen eine
  `.pas`-Bindungsbibliothek nötig, funktioniert mit jeder installierten
  libzmq-Version)
- Heartbeat läuft in einem eigenen Thread
- **Rich-Output statt nur Text:** Nach dem Ausführen einer Zelle durchsucht der
  Kernel das Arbeitsverzeichnis des Programms nach Dateien mit bekanntem
  MIME-Typ (`.png`, `.jpg`/`.jpeg`, `.gif`, `.bmp`, `.svg`, `.html`/`.htm`) und
  veröffentlicht sie als `display_data`-Nachricht — Bilder/HTML erscheinen so
  direkt im Notebook, zusätzlich zum normalen `stdout`/`stderr`-Text. Das ist
  bewusst generisch gehalten und nicht an den `fpc`-Aufruf gebunden: jede
  Datei, die das ausgeführte Programm ablegt, wird erkannt — unabhängig davon,
  wie sie erzeugt wurde.
- **Auto-Vervollständigung (`complete_request`):** Der Kernel schlägt beim
  Drücken von Tab passende Pascal-Schlüsselwörter, gängige RTL-Bezeichner
  (`WriteLn`, `Integer`, `TStringList`, ...) sowie bereits im aktuellen
  Zelleninhalt verwendete eigene Bezeichner (Variablen-, Typ-, Prozedurnamen)
  vor. Es handelt sich um eine einfache Präfix-Suche ohne semantische
  Analyse — für einen "simplen" Kernel bewusst so gehalten.
- **Sauberer Interrupt ("Stop"-Knopf in Jupyter/JupyterLab):** Der Kernel
  installiert einen `SIGINT`-Handler. Klickt man in Jupyter/JupyterLab auf
  "Interrupt Kernel" (z. B. bei einer Endlosschleife), wird **nur** der
  gerade laufende Compiler- oder Programmprozess beendet — der Kernel selbst
  bleibt aktiv und ist sofort für die nächste Zelle bereit, statt komplett
  abzustürzen.
- **Kernel-Icon** für den JupyterLab-Launcher (`icons/logo-32x32.png`,
  `icons/logo-64x64.png`), wird von `install.sh` automatisch mit registriert.

Was absichtlich **nicht** enthalten ist (das würde den Rahmen eines "simplen"
Kernels sprengen): Introspektion (`inspect_request`, z. B. Doku-Popups),
persistenter Zustand zwischen Zellen (jede Zelle ist ein komplett neues
Programm, so wie es normalerweise mit Pascal üblich ist), Kommunikation über
`stdin` (z. B. für `ReadLn`-Eingaben aus dem Notebook), semantisch korrekte
Vervollständigung (z. B. nur Methoden einer bestimmten Klasse anzeigen).

## Dateien

| Datei | Zweck |
|---|---|
| `pascalkernel.lpr` | Hauptprogramm des Kernels |
| `uzmq.pas` | ZeroMQ-Bindings (dynamisches Laden via `DynLibs`) |
| `usha256.pas` | SHA-256 / HMAC-SHA256 (für die Nachrichtensignatur) |
| `kernel.json.template` | Vorlage für die Jupyter-Kernelspec |
| `icons/logo-32x32.png`, `icons/logo-64x64.png` | Icon für den JupyterLab-Launcher |
| `install.sh` | Baut den Kernel und registriert ihn (inkl. Icon) bei Jupyter |

## Voraussetzungen

- Free Pascal Compiler (`fpc`), getestet mit Version 3.2.2
- `libzmq` (Version 4/5), z. B. `sudo apt install libzmq5`
- Jupyter/JupyterLab (`pip install jupyterlab`)
- Linux (macOS sollte mit kleinen Anpassungen der `zmq_pollitem_t`-Struktur
  ebenfalls funktionieren; Windows wird derzeit nicht unterstützt, da der
  `fd`-Typ in `zmq_pollitem_t` dort abweicht, `cthreads` nicht verwendet wird
  und die Interrupt-Behandlung auf POSIX-Signalen basiert)

## Installation

```bash
chmod +x install.sh
./install.sh
```

Das Skript kompiliert `pascalkernel.lpr` und registriert den Kernel unter dem
Namen `pascal` bei Jupyter (`jupyter kernelspec install ... --user`).

Danach steht der Kernel in Jupyter Notebook/Lab als **"Free Pascal"** zur
Auswahl, oder testweise direkt in der Konsole:

```bash
jupyter console --kernel pascal
```

```bash
jupyter lab
```

## Manuelle Kompilierung (ohne install.sh)

```bash
fpc -Mobjfpc -O2 pascalkernel.lpr
```

Das erzeugt die ausführbare Datei `pascalkernel`. Jupyter startet sie
automatisch mit dem Pfad zur Connection-Datei als einzigem Argument, wie in
`kernel.json` festgelegt.

## Beispielzellen

Text:

```pascal
program hello;
begin
  writeln('Hallo aus Free Pascal!');
  writeln(2 + 2);
end.
```

Ergebnis im Notebook:

```
Hallo aus Free Pascal!
4
```

Bild (SVG) — jede Datei, die das Programm im Arbeitsverzeichnis ablegt und
einen bekannten MIME-Typ hat, wird automatisch angezeigt:

```pascal
program svgtest;
uses SysUtils;
var
  f: TextFile;
begin
  Assign(f, 'bild.svg');
  Rewrite(f);
  WriteLn(f, '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">');
  WriteLn(f, '<circle cx="50" cy="50" r="40" fill="blue" />');
  WriteLn(f, '</svg>');
  Close(f);
  WriteLn('SVG-Datei erzeugt');
end.
```

Ergebnis im Notebook: der Text "SVG-Datei erzeugt" **und** der blaue Kreis
als gerendertes Bild, beide aus derselben Zelle.

Auto-Vervollständigung: im Notebook `Tab` nach einem Präfix wie `wri` oder
einem selbst deklarierten Variablennamen drücken, um Vorschläge zu erhalten.

## Funktionsweise (Kurzüberblick)

1. Jupyter startet den Kernel mit dem Pfad zu einer JSON-"Connection-Datei"
   (Ports, IP, HMAC-Schlüssel).
2. Der Kernel bindet fünf ZeroMQ-Sockets an die angegebenen Ports.
3. Ein Heartbeat-Thread beantwortet Pings auf dem `hb`-Socket (einfaches Echo).
4. In der Hauptschleife wird per `zmq_poll` auf `shell`- und
   `control`-Nachrichten gewartet.
5. Jede eingehende Nachricht wird gemäß dem Jupyter-Wire-Protokoll geparst
   (`<IDS|MSG>`-Trenner, HMAC-Prüfsumme, Header/Parent/Metadata/Content als
   JSON), verarbeitet und die Antwort im selben Format zurückgesendet.
6. Jede Anfrage wird auf iopub mit einem `status: busy` / `status: idle`
   Paar eingerahmt (siehe Hinweis zu JupyterLab unten).
