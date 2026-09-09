# Tidal Connect for HiFiBerry OS NG

Turn a HiFiBerry into a Tidal Connect endpoint: pick it in the Tidal app on your phone
and stream straight to the attached DAC.

Packaged as `hifiberry-tidal-connect`, an arm64 Debian package for HiFiBerry OS NG
(Debian Trixie). It ships two pre-built binaries plus the glue that registers Tidal
Connect with the rest of HiFiBerry OS. Nothing is compiled at install time, and there is
no Docker container, no qemu, and no 32-bit chroot in the runtime path.

## Install

From the HiFiBerry Web UI, install the **Tidal Connect** extension. Or, from a shell:

```bash
sudo apt install hifiberry-tidal-connect
```

Then select **Tidal** as the active player in the Web UI, open the Tidal app on a phone
on the same network, and pick the device from the Connect list.

There is no provisioning step — installing the package is all that is required.

## What gets installed

| Path | Purpose |
|---|---|
| `/usr/bin/tdcn` | The device daemon: mDNS discovery, the Tidal Connect protocol, playback |
| `/usr/bin/tdcn-ssl` | Handles the certificate and encryption side; run by `tdcn`, not by you |
| `/etc/tdcn/config.toml` | Device, audio and audiocontrol settings (a conffile) |
| `/usr/lib/systemd/user/tdcn.service` | The systemd **user** unit that runs `tdcn` |
| `/usr/share/hifiberry-tidal-connect/vendor/` | Vendored Tidal Connect binary and certificate bundle, used by `tdcn-ssl` |
| `/usr/share/hifiberry/players.d/tidal.json` | Web UI player registry entry (plus its icon) |
| `/etc/audiocontrol/players.d/tidalconnect.json` | Registers the player with audiocontrol |
| `/etc/configserver/conf.d/tidal-connect.json` | Lets the Web UI start/stop the service |

## How it works

`tdcn` advertises itself over mDNS using its own built-in responder, and runs as an
unprivileged `systemd --user` service, the same as HiFiBerry OS's other
player daemons (Music Assistant/sendspin, Soloist, analog input). It writes to the DAC
directly over ALSA — no PipeWire or PulseAudio in between.

Metadata, transport commands and volume are exchanged with **audiocontrol** over HTTP by
`tdcn`'s own bridge, with no helper scripts involved. `tdcn` posts events
(`song_changed`, `state_changed`, `position_changed`, …) to audiocontrol's generic-player
API on `http://127.0.0.1:1080`, and listens for incoming transport commands on
`http://127.0.0.1:8090/command`.

`tdcn-ssl` handles the certificate and encryption side, using the vendored Tidal Connect
binary and certificate bundle under `/usr/share/hifiberry-tidal-connect/vendor/`. `tdcn`
runs it itself at startup, so there is nothing to configure or set up.

`systemd`'s `Restart=on-failure` handles crash recovery, so there is no external watchdog.

## Configuration

`/etc/tdcn/config.toml` lists every setting tdcn accepts, with each default shown on a
commented-out line — uncomment one to change it, then restart the service. Nothing in it
needs editing for a working device.

The two settings most worth knowing about:

```toml
# Name shown in the Tidal app. Defaults to this machine's "pretty" hostname
# (PRETTY_HOSTNAME in /etc/machine-info, what `hostnamectl set-hostname --pretty`
# writes), falling back to the plain system hostname.
#friendly_name = "Living Room"

# ALSA device. "default" follows the system config, which already points at the DAC.
#device = "default"
```

The only settings with no default are the `[cert]` paths, which the package points at its
vendored files. `model` and `id` default to the ZenStream identity that matches the
shipped certificate bundle, and must be changed together if at all.

Note that unknown keys are ignored rather than rejected, so a misspelled setting silently
leaves the default in place.

## Requirements

- HiFiBerry OS NG (Debian Trixie, arm64)
- A HiFiBerry DAC (any model)
- Raspberry Pi 3/4/5 or CM4/CM5
- `hifiberry-audiocontrol` >= 0.6.18, for metadata and transport integration

## Troubleshooting

Everything below runs as the audio user, since `tdcn` is a user service.

**Device does not appear in the Tidal app**

`tdcn` runs its own mDNS responder and advertises `_tidalconnect._tcp.local.` — it does
not go through `avahi-daemon`. To check that the advertisement is on the wire, browse for
it from another machine (`avahi-browse` from `avahi-utils` is a convenient way):

```bash
avahi-browse -t _tidalconnect._tcp
```

If nothing shows up, check the service log below. The phone and the Pi also have to be on
the same network, and on one that does not block multicast.

**Service is not running**

```bash
systemctl --user status tdcn
journalctl --user -u tdcn -f
```

If `tdcn-ssl` fails, `tdcn` logs its output there too.

**No audio**

```bash
aplay -l                               # does ALSA see the HiFiBerry card?
```

If the card is not the default, set `[audio] device` in `/etc/tdcn/config.toml`.

## Building the package

```bash
sudo apt build-dep .          # or: sudo apt install debhelper libasound2t64
dpkg-buildpackage -us -uc -b
```

The build is glue only: `debian/rules` decompresses the binaries from `vendor/` and
installs them alongside the config, the systemd unit and the integration drop-ins.

## Uninstall

```bash
sudo apt remove hifiberry-tidal-connect
```

The service is stopped on removal, and `/etc/tdcn/config.toml` goes on purge.

## Credits and licensing

The Tidal Connect binary and device certificate under `vendor/` originate from
[TonyTromp/tidal-connect-docker](https://github.com/TonyTromp/tidal-connect-docker) and
remain the property of TIDAL. Third-party license texts bundled with them are shipped
unmodified under `/usr/share/hifiberry-tidal-connect/licenses/`.

The packaging and documentation in this repository are provided as-is under the MIT/Expat
license. See `debian/copyright` for the per-file breakdown.
