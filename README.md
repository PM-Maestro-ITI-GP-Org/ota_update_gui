# OTA Update GUI

Qt/QML desktop GUI for the **Hypervisor Management System (HMS)** on the
QNX host. Commands go over **MQTT**, file transfer goes over **SCP**
through the jump server (laptop → server → QNX target, and back).

```
┌──────────────────────┐   MQTT (139.185.38.211:1883)   ┌─────────────────────┐
│  ota_update_gui      │  ────────────────────────────> │   hms (QNX host)    │
│      (Laptop)        │  <── hms/status, hms/cmd ────  │                     │
└──────────────────────┘                                 └─────────────────────┘
     │ scp upload            ▲ scp pull
     ▼                       │
┌──────────────────────────────────────┐
│  server  maxmaster@139.185.38.211    │
│  /home/maxmaster/uploads/            │
└──────────────────────────────────────┘
```

## Features

- MQTT connection with automatic retry and backoff reconnect
- **Guests**: live list of guests on the host, Start (with optional IP),
  Kill (confirmed), Info, jump to Shell, and Create a new guest
- **OTA Update**: pick a replacement for any partition file, then a
  three-step flow shown as a stepper — upload to the server, pull down
  to the host, apply into `/guests/<guest>/` and restart. Also sends
  arbitrary files into a running guest at chosen paths.
- **Shell**: one-shot `exec`, or a persistent interactive session with
  command history
- **Monitor**: host and guest statistics, auto-polling
- **Log**: timestamped, colour-coded, filterable, copyable

## Look and feel

Material Design via `QtQuick.Controls.Material`, light theme by default
with a dark toggle in the header (the ☾/☀ button). All colour, type and
spacing come from `Theme.qml`; there are no hex literals in the pages.
Base font size is 15px.

## Prerequisites

Qt 6.10.2 (gcc_64) and the Paho MQTT C library
(`sudo apt install libpaho-mqtt-dev`). Also needs `ssh`/`scp` on the
PATH and an SSH key at `~/.ssh/id_ed25519` that can log into the server
(`maxmaster@139.185.38.211`).

Without Paho the app still builds and runs — the UI works, but it cannot
talk to HMS and the header shows "Demo mode".

## Build

Point CMake at your Qt with `CMAKE_PREFIX_PATH`. (`Qt6_DIR` used to be
hardcoded to one developer's home directory; it no longer is.)

```bash
cmake -B build -DCMAKE_PREFIX_PATH=$HOME/Qt/6.10.2/gcc_64 -DCMAKE_BUILD_TYPE=Release
cmake --build build --target ota_gui -j$(nproc)
```

Binary: `build/ota_gui`.

## Run

```bash
./build/ota_gui
```

Connects automatically to `tcp://139.185.38.211:1883` on startup and
keeps retrying if the broker is unreachable.

## Usage

1. **Guests** — the table refreshes automatically; use Start/Kill/Info
   on each row. Start asks for an optional IP (persisted to the guest
   conf for SSH).
2. **OTA Update** — choose the target guest, Browse for the package
   (`.tar.gz`, `.tar` or a single file), press **Upload & Deploy** and
   follow the progress. When the package is a tarball it is extracted
   into the guest directory; a single top-level folder inside the
   archive is treated as the payload root.
3. **Remote Shell** — pick a guest, type a command, press Run; output
   appears below (SSH exec).
4. **Log** — everything (commands, responses, SCP progress) is logged
   here; useful when something goes wrong.

## MQTT topics

| Topic | Direction | Format | Description |
|-------|-----------|--------|-------------|
| `hms/cmd` | GUI → HMS | plain text | see below |
| `hms/status` | HMS → GUI | JSON | guest lists, results, exec output, shell stream, OTA progress/result |

Commands sent: `list`, `start`, `kill`, `info`, `exec`, `stats`, `files`,
`fetch`, `apply`, `pushfiles`, `addfile`, `addguest`, `shellopen`,
`shellwrite`, `shellclose`, `ping`.

Status states handled: `guest_list`, `guest_info`, `result`,
`exec_result`, `monitor_stats`, `guest_files`, `ota_progress`,
`ota_result`, `shell_opened`, `shell_out`, `shell_closed`,
`addfile_result`, `addguest_result`, `pong`. Anything else is logged
rather than silently dropped.

Credentials (in `mqttclient.cpp`): user `mqttuser`, password `123456`.

## SCP paths (in `mqttclient.cpp`)

- Server: `maxmaster@139.185.38.211`, upload dir `/home/maxmaster/uploads`
- Key: `~/.ssh/id_ed25519`
- Upload: `scp -C -i ~/.ssh/id_ed25519 <local> maxmaster@139.185.38.211:/home/maxmaster/uploads/`
- Download: `scp -C -i ~/.ssh/id_ed25519 maxmaster@139.185.38.211:<remote> <local>`

## Project structure

- `main.cpp` — entry point; selects the Material style, registers
  `MqttClient` and the `Theme` singleton, and reports QML load failures
  instead of exiting silently with no window
- `main.qml` — window chrome, navigation, shared models, MQTT wiring,
  and the dialogs (file picker, guest browser, guest info)
- `GuestsPage.qml` / `OtaPage.qml` / `ShellPage.qml` /
  `GuestMonitor.qml` / `LogPanel.qml` — the five screens
- `Theme.qml` — the palette, type scale and spacing (singleton)
- `AppCard.qml` / `SectionTitle.qml` / `StatusPill.qml` /
  `FilledButton.qml` — shared building blocks
- `mqttclient.h` / `mqttclient.cpp` — Paho MQTT wrapper, command
  publishing, status parsing, SCP upload/download with progress
- `CMakeLists.txt` — build configuration (Qt 6 + Paho)

## Troubleshooting

### "MQTT not available — running in demo mode"
Paho is missing: `sudo apt install libpaho-mqtt-dev`.

### Connects but no guests appear
The HMS service must be running on the QNX host (`hms` binary from
`src/Hypervisor_Management_System`, see its README). Check the Log tab
for timeouts.

### Upload fails with "Permission denied (publickey)"
The key `~/.ssh/id_ed25519` must be authorized on the server
(`maxmaster@139.185.38.211`).
