# vendor/

Files this package needs but doesn't build itself.

## Binaries (`bin/`)

- **`tdcn`** — the Tidal Connect device daemon. Handles the Tidal Connect protocol:
  discovery, streaming, playback.
- **`tdcn-ssl`** — handles SSL certificate setup for this device, based on the
  original Tidal Connect binary and the supplied device certificate (see below).
  `tdcn` runs this itself at every startup (see `debian/tdcn-config.toml`'s `[cert]`
  section) — nothing else in this package invokes it.

Pre-built arm64 binaries, gzipped. `debian/rules` decompresses and installs them.

## Proprietary binary + certificate

- `tidal_connect_application.gz` — the original Tidal Connect binary.
- `certificate.dat.gz` — this device's certificate bundle.
- `ids.txt` — device id reference.
- `licenses/` — third-party license texts for the original binary.
