# Understanding the Tidal Connect protocol

The Tidal Connect protocol is quite easy to understand once you have a reference to read
against. The best reference is the official controller app itself — the Tidal desktop app
for Windows/macOS.

## Why the desktop app is such a good reference

The Windows and Mac Tidal apps are [Electron](https://www.electronjs.org/) apps: a
JavaScript web app bundled into a native (Chromium + Node.js) runtime. That means the
entire application — including its Tidal Connect device-discovery and control logic — ships
as readable JavaScript, not compiled native code. It's not hard to derive the protocol from
it directly:

1. Locate the app's `app.asar` (Electron's packed source archive) inside the installed
   application (on macOS, under `Contents/Resources/` inside the `.app` bundle).
2. Extract it with the `@electron/asar` tool:
   ```bash
   npx @electron/asar extract app.asar <output-dir>
   ```
3. Read the extracted JavaScript. The Tidal Connect logic is what actually matters here:
   device discovery (mDNS), the WebSocket command/notification shapes it sends and expects,
   and how it talks to the Tidal API for playback tokens.

Reading this source is legitimate reference material for understanding the protocol a
Tidal Connect *device* (like this one) needs to speak — the app is the other end of the
same conversation.

## What to look for

- The mDNS service type and TXT record fields the app expects to discover.
- The WebSocket message envelope, and the specific command/notification JSON shapes for
  session management, queue/transport control, and status.
- How the app resolves streaming URLs and playback tokens via Tidal's API.

Cross-reference what you find against this device's actual behavior (mDNS advertisement,
WebSocket traffic) to confirm — the app is a reference, not a specification.

## Scope of this note

This document is deliberately limited to *how to go find the protocol yourself* — it does
not, and will not, publish the message shapes, endpoints, or other protocol specifics here.
