# xdr-boost

Free and open-source XDR brightness booster for MacBook Pro. Like [Vivid](https://www.getvivid.app/), but free.

Unlocks the full brightness of your Liquid Retina XDR display beyond the standard SDR limit. Your MacBook Pro can go up to 1600 nits — this tool lets you use it.

## Features

- Boosts screen brightness beyond the standard 500 nit SDR limit using XDR hardware
- No white tint or washed-out colors — uses multiply compositing to preserve colors perfectly
- Menu bar icon with brightness presets (1.5x, 2.0x, 3.0x, 4.0x)
- Optional gamma-table mode for displays where the multiply overlay does not boost brightness
- Global keyboard shortcut (**Ctrl+Option+Cmd+V**) to toggle from anywhere
- Survives sleep/wake, lid close/open, and lock/unlock — brightness auto-restores
- Starts with XDR off — rebooting always gives you a normal screen
- Emergency kill switch (`xdr-boost --kill`) if anything goes wrong
- Standalone binary or a macOS app bundle, with no third-party runtime dependencies
- Launch agent for auto-start on login

## How it works

MacBook Pro displays can output up to 1600 nits, but macOS caps regular desktop content at ~500 nits. The extra brightness is reserved for HDR content.

xdr-boost creates an invisible Metal overlay using `multiply` compositing with EDR (Extended Dynamic Range) values above 1.0. This triggers the display hardware to boost its backlight, making everything brighter while preserving colors perfectly — no white tint, no washed-out look.

The optional `--gamma` mode presents a small 8×8 EDR trigger and scales the display's captured RGB transfer tables. It writes 256 entries without clamping them to SDR white and saves the full native table for restoration. This mode was tested on a built-in XDR display with macOS 27.0 beta; see [validation notes](docs/gamma-mode.md). The app bundle selects this mode by default on macOS 27 or newer. The command-line binary keeps the original multiply mode as its default.

## Requirements

- MacBook Pro with Liquid Retina XDR display (M1 Pro/Max or later)
- macOS 12.0+

## Install

### Application installer

Open `XDR-Boost.dmg`, drag **XDR Boost.app** into **Applications**, then eject the disk image and open the app. It appears as a sun in the menu bar and starts with boost off. On macOS 27 or newer, start with **1.10 — Low** or **1.25 — Medium**.

To build the installer from source:

```bash
make dmg
```

This produces `.build/XDR Boost.app` and `.build/XDR-Boost.dmg` for the build machine's architecture. `make app` builds just the app. The app targets macOS 12 or newer; runtime validation of gamma mode is limited to the macOS 27 beta noted above.

Builds are ad-hoc signed by default and are not notarized. A downloaded copy may require **System Settings → Privacy & Security → Open Anyway**, following [Apple's instructions](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac). A maintainer can provide `CODE_SIGN_IDENTITY` when building; notarization is a separate release step. Building does not install the app or configure login startup.

### Command-line build

```bash
git clone https://github.com/levelsio/xdr-boost.git
cd xdr-boost
make build
```

The binary will be at `.build/xdr-boost`.

### Install to PATH

```bash
sudo make install
```

### Start on login

```bash
sudo make install
make launch-agent
```

### Uninstall

```bash
make remove-agent
sudo make uninstall
```

## Usage

```bash
# Run with menu bar icon (default 2x boost)
xdr-boost

# Run with custom boost level
xdr-boost 3.0

# Gamma fallback (default gain 1.10)
xdr-boost --gamma

# Gamma fallback with a specific gain
xdr-boost --gamma 1.25
```

Click the **☀** icon in your menu bar to:
- Toggle XDR brightness on/off
- Choose brightness level (1.5x, 2.0x, 3.0x, 4.0x)
- Quit

Gamma mode offers gains of 1.10, 1.25, 1.50, and 1.60. These are transfer-table factors, not calibrated brightness or nits multipliers. Run only one brightness/gamma utility at a time. Gamma mode rejects tables with values already above SDR white and prevents another copy under the same user from taking over its display. Turning it off, quitting, or sending SIGINT/SIGTERM restores the captured native table. If restoration fails, the app keeps the snapshot and retries; it stays open instead of resetting other displays. A forced SIGKILL cannot run cleanup.

### Keyboard shortcut

**Ctrl+Option+Cmd+V** — toggle XDR brightness on/off from anywhere, no need to find the menu bar icon.

### Emergency kill

If something goes wrong and you can't see your screen:

```bash
# From terminal (even blind-type it)
xdr-boost --kill

# Or just
pkill xdr-boost
```

The app always starts with XDR **off** — you have to manually turn it on. So rebooting will always give you a normal screen.

### Sleep, lid close, and lock screen

A common problem with XDR brightness apps is that closing your laptop or locking the screen kills the brightness boost, and it doesn't come back when you return. xdr-boost fixes this with a watchdog that automatically restores your brightness within a few seconds after:

- Closing and reopening the laptop lid
- Locking and unlocking the screen
- Sleep and wake
- Plugging/unplugging external displays

Gamma mode still needs sleep/wake and external-display testing on more hardware.

## License

MIT
