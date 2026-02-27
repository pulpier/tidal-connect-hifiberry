# Tidal Connect for HiFiBerry OS NG

Turn your HiFiBerry into a Tidal Connect endpoint. Stream from the Tidal app on your phone
directly to your HiFiBerry DAC.

Based on [TonyTromp/tidal-connect-docker](https://github.com/TonyTromp/tidal-connect-docker),
adapted for HiFiBerry OS NG (Debian Trixie, arm64, PipeWire).

## Quick install

```bash
git clone https://github.com/pulpier/tidal-connect-hifiberry.git
cd tidal-connect-hifiberry
sudo ./install.sh
```

The installer will:

1. Install Docker if not present
2. Fix the kernel page size if needed (Pi 5/CM5 only — requires reboot)
3. Build the Docker image (~2 minutes)
4. Install and start systemd services
5. Register the device for mDNS discovery

After installation, open the Tidal app on your phone and look for your device
in the Connect device list.

## Security notice

The Tidal Connect binaries require legacy libraries from **Debian Stretch (2017)**, which is
long end-of-life. The Docker container includes packages with known security vulnerabilities
(OpenSSL 1.0, libcurl3, FFmpeg 3.x). The container runs with `network_mode: host` and access
to `/dev/snd`.

This is acceptable for a dedicated audio appliance on a trusted home network, but you should
be aware of the risk. Do not expose the device directly to the internet.

## Requirements

- HiFiBerry OS NG (Debian Trixie, arm64)
- HiFiBerry DAC (any model)
- Raspberry Pi 3/4/5 or CM4/CM5
- PipeWire with pipewire-pulse running (default on HiFiBerry OS NG)
- hifiberry-audiocontrol >= 0.6.18 (for metadata integration via `players.d/` with custom capabilities)
- Internet connection (for Docker image build and Tidal streaming)

## Configuration

Edit `/opt/tidal-connect/.env` after installation:

```
FRIENDLY_NAME=Living Room     # Name shown in Tidal app
MODEL_NAME=HiFiBerry          # Device model name
MQA_PASSTHROUGH=false          # MQA passthrough (requires compatible DAC)
MQA_CODEC=false                # MQA software decoding
PLAYBACK_DEVICE=default        # ALSA device (leave as default for PipeWire)
```

After changing, restart:

```bash
sudo systemctl restart tidal-connect
```

## Services

| Service | What it does |
|---------|-------------|
| `tidal-connect` | Runs the Docker container with Tidal Connect |
| `tidal-bridge` | Exports metadata to AudioControl (web UI) |
| `tidal-watchdog` | Monitors container health, handles recovery |

```bash
# Status
sudo systemctl status tidal-connect

# Logs
sudo journalctl -u tidal-connect -f

# Stop
sudo systemctl stop tidal-connect tidal-bridge

# Start
sudo systemctl start tidal-connect tidal-bridge
```

## How it works

The Tidal Connect binaries are proprietary 32-bit ARM executables that require legacy
libraries (Debian Stretch era). Docker provides the compatibility environment.

Audio is routed through PipeWire using the PulseAudio protocol:

```
Container: tidal_connect_application -> PortAudio -> ALSA -> libpulse (armhf)
                                                                  |
                                                          Unix socket
                                                                  |
Host:                                                   PipeWire-pulse -> DAC
```

The PulseAudio wire protocol is architecture-independent, so the 32-bit container
client connects to the 64-bit host PipeWire without issues.

## Pi 5 / CM5 note

The Pi 5's default kernel uses 16K memory pages, which is incompatible with the 32-bit
ARM libraries in the Docker container. The installer automatically switches to the
standard aarch64 kernel (`kernel8.img`) with 4K pages. This requires a one-time reboot
and has negligible performance impact for audio use.

## Uninstall

```bash
sudo systemctl stop tidal-connect tidal-bridge tidal-watchdog
sudo systemctl disable tidal-connect tidal-bridge tidal-watchdog
sudo rm /etc/systemd/system/tidal-connect.service
sudo rm /etc/systemd/system/tidal-bridge.service
sudo rm /etc/systemd/system/tidal-watchdog.service
sudo systemctl daemon-reload
sudo docker rmi hifiberry-tidal-connect:latest
sudo rm -rf /opt/tidal-connect
```

## Troubleshooting

**Device not visible in Tidal app**
- Check mDNS: `avahi-browse -t _tidalconnect._tcp`
- Ensure avahi-daemon is running: `systemctl status avahi-daemon`
- Phone and Pi must be on the same network

**No audio**
- Check PipeWire pulse is running: `systemctl --user status pipewire-pulse`
- If stopped: `systemctl --user start pipewire-pulse.socket pipewire-pulse.service`
- Check container logs: `sudo journalctl -u tidal-connect -n 50`

**Container exits immediately**
- Check page size: `getconf PAGESIZE` (must be 4096)
- If 16384: add `kernel=kernel8.img` to `/boot/firmware/config.txt` and reboot

**"Connection refused" in logs**
- PipeWire pulse socket not available
- Restart: `systemctl --user restart pipewire-pulse`

## Technical details

See [PORTING.md](PORTING.md) for detailed design documentation covering all
adaptations from the upstream project.

## Credits

Based on [TonyTromp/tidal-connect-docker](https://github.com/TonyTromp/tidal-connect-docker).

## License

The Tidal Connect binaries and certificates are proprietary (TIDAL).
The Docker packaging, install script, bridge script, and documentation are provided as-is.
