# xdr-boost

Free and open-source XDR brightness booster for MacBook Pro. Like [Vivid](https://www.getvivid.app/), but free.

Unlocks the full brightness of your Liquid Retina XDR display beyond the standard SDR limit. Your MacBook Pro can go up to 1600 nits — this tool lets you use it.

## Features

- Boosts screen brightness beyond the standard 500 nit SDR limit using XDR hardware
- No white tint or washed-out colors — uses multiply compositing to preserve colors perfectly
- Menu bar icon with brightness presets (1.5x, 2.0x, 3.0x, 4.0x)
- Automation rules for Light/Dark Mode and custom daily time windows
- Global keyboard shortcut (**Cmd+Shift+B**) to toggle from anywhere
- Survives sleep/wake, lid close/open, and lock/unlock — brightness auto-restores
- Starts with XDR off — rebooting always gives you a normal screen
- Emergency kill switch (`xdr-boost --kill`) if anything goes wrong
- Single binary, no dependencies, ~250 lines of Swift
- Launch agent for auto-start on login

## How it works

MacBook Pro displays can output up to 1600 nits, but macOS caps regular desktop content at ~500 nits. The extra brightness is reserved for HDR content.

xdr-boost creates an invisible Metal overlay using `multiply` compositing with EDR (Extended Dynamic Range) values above 1.0. This triggers the display hardware to boost its backlight, making everything brighter while preserving colors perfectly — no white tint, no washed-out look.

## Requirements

- MacBook Pro with Liquid Retina XDR display (M1 Pro/Max or later)
- macOS 12.0+

## Install

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
```

Click the **☀** icon in your menu bar to:
- Toggle XDR brightness on/off
- Choose brightness level (1.5x, 2.0x, 3.0x, 4.0x)
- Configure automation rules for system appearance or a daily schedule
- Quit

### Keyboard shortcut

**Cmd+Shift+B** — toggle XDR brightness on/off from anywhere, no need to find the menu bar icon.

### Emergency kill

If something goes wrong and you can't see your screen:

```bash
# From terminal (even blind-type it)
xdr-boost --kill

# Or just
pkill xdr-boost
```

The app starts with XDR **off** when automation is disabled. If automation is enabled and the current conditions match, XDR can turn on automatically at launch.

### Automation

Open **Automation Settings...** from the menu bar to configure:

- **System Appearance**: turn XDR on only in **Light Mode** or only in **Dark Mode**
- **Time Window**: turn XDR on only during a custom daily time range

If you enable both, **both conditions must match** before XDR turns on.

Automation is checked continuously while the app is running, including after sleep/wake and display changes. Manual toggles still work, but automation will re-apply the configured state on the next check.

### Sleep, lid close, and lock screen

A common problem with XDR brightness apps is that closing your laptop or locking the screen kills the brightness boost, and it doesn't come back when you return. xdr-boost fixes this with a watchdog that automatically restores your brightness within a few seconds after:

- Closing and reopening the laptop lid
- Locking and unlocking the screen
- Sleep and wake
- Plugging/unplugging external displays

If you turned XDR on, it stays on — no matter what.

## License

MIT
