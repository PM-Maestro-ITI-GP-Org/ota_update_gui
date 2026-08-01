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

- MQTT connection with automatic retry / reconnect
- **Guests** tab: live list of guests on the host (auto-refresh every
  10 s), Start (with optional IP), Kill, Info (full details dialog)
- **OTA Update** tab: pick a package on the laptop, upload it to the
  server with SCP (progress %), then deploy — HMS pulls it from the
  server, applies it into `/guests/<guest>/` and restarts the guest
  (progress stages: download → extract → apply → restart)
- **Download** helper: pull any file from the server to the laptop
- **Remote Shell** tab: run commands inside a running guest over SSH
- **Log** tab: timestamped, color-coded log of everything

## Prerequisites

Same as the motor recorder GUI: Qt 6.10.2 (gcc_64) installed at
`/home/gemy/Qt/6.10.2/gcc_64` and the Paho MQTT C library
(`sudo apt install libpaho-mqtt-dev`). Also needs `ssh`/`scp` on the
PATH and an SSH key at `~/.ssh/id_ed25519` that can log into the server
(`maxmaster@139.185.38.211`).

## Build

```bash
cd /media/gemy/Extra/ITI_GP/ota_update_gui
cmake -B build -DCMAKE_PREFIX_PATH=/home/gemy/Qt/6.10.2/gcc_64 -DCMAKE_BUILD_TYPE=Release
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
| `hms/cmd` | GUI → HMS | plain text | `list`, `start <guest> [ip]`, `kill <guest>`, `info <guest>`, `exec <guest> <cmd>`, `ota <guest> <remote_path>`, `ping` |
| `hms/status` | HMS → GUI | JSON | guest lists, results, exec output, OTA progress/result |

Credentials (in `mqttclient.cpp`): user `mqttuser`, password `123456`.

## SCP paths (in `mqttclient.cpp`)

- Server: `maxmaster@139.185.38.211`, upload dir `/home/maxmaster/uploads`
- Key: `~/.ssh/id_ed25519`
- Upload: `scp -C -i ~/.ssh/id_ed25519 <local> maxmaster@139.185.38.211:/home/maxmaster/uploads/`
- Download: `scp -C -i ~/.ssh/id_ed25519 maxmaster@139.185.38.211:<remote> <local>`

## Project structure

- `main.cpp` — entry point, registers the `MqttClient` QML type
- `main.qml` — UI (guests, OTA, shell, log; in-window file picker)
- `LogPanel.qml` — reusable log view
- `mqttclient.h` / `mqttclient.cpp` — Paho MQTT wrapper, command
  publishing, status parsing, SCP upload/download with progress
- `CMakeLists.txt` — build configuration (Qt 6.10.2 + Paho)

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
