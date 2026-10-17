# xdr-boost

Free and open-source XDR brightness booster for MacBook Pro. Like [Vivid](https://www.getvivid.app/), but free.

Unlocks the full brightness of your Liquid Retina XDR display beyond the standard SDR limit. Your MacBook Pro can go up to 1600 nits — this tool lets you use it.

## Features

- Boosts screen brightness beyond the standard 500 nit SDR limit using XDR hardware
- No white tint or washed-out colors — scales the display's own calibrated gamma table, so colors are preserved
- No flicker when switching Spaces, swiping between desktops, or opening Mission Control
- Screenshots and screen recordings look normal — the boost isn't captured
- Never clips highlights — the boost is capped to the headroom the display actually has at the current brightness
- Menu bar panel with an on/off switch, a 1x–4x slider, presets, and a live headroom meter
- Options: turn on when the app starts, launch at login, only while charging, turn off on low battery
- Remembers your boost level between launches
- Global keyboard shortcut (**Ctrl+Option+Cmd+V**) to toggle from anywhere
- Survives sleep/wake, lid close/open, and lock/unlock — brightness auto-restores
- Starts with XDR off — rebooting always gives you a normal screen
- Emergency kill switch (`xdr-boost --kill`) if anything goes wrong
- Single binary, no dependencies, ~700 lines of Swift
- Launch agent for auto-start on login

## How it works

MacBook Pro displays can output up to 1600 nits, but macOS caps regular desktop content at ~500 nits. The extra brightness is reserved for HDR content.

xdr-boost does two things:

1. A tiny 1×1 pt Metal window with EDR (Extended Dynamic Range) content, tucked under the panel's rounded corner, keeps the display in EDR mode so the backlight can go above the SDR limit.
2. The display's gamma (transfer) table is scaled above 1.0, pushing all desktop content into that extra EDR range — everything gets brighter while colors stay the same.

Because the gamma table is applied by the display pipeline *after* macOS composites the screen, the boost stays steady through Space switches and Mission Control animations (an overlay with a compositing filter drops back to SDR during those). It also doesn't show up in screenshots.

macOS restores the original gamma table automatically whenever xdr-boost exits — even if it crashes or is force-killed — so your screen can never get stuck boosted.

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

# Start with the boost already on
xdr-boost 4.0 --on
```

Click the **☀** icon in your menu bar to open the panel:
- Switch XDR brightness on/off
- Pick a level with the slider or the 1.5x / 2x / 3x / 4x presets
- See how much headroom the display has right now (at high brightness macOS gives less, and the boost is capped to it so highlights never clip)
- Options:
  - **Turn on when the app starts** — no need to switch it on after every login
  - **Launch at login** — writes the launch agent for you (takes effect at the next login)
  - **Only while charging** — pauses on battery, resumes when you plug in
  - **Turn off below 20% battery** — pauses when the battery is low, resumes when you plug in

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

By default the app starts with XDR **off** — you have to manually turn it on. So rebooting will always give you a normal screen (unless you enabled "Turn on when the app starts").

### Sleep, lid close, and lock screen

A common problem with XDR brightness apps is that closing your laptop or locking the screen kills the brightness boost, and it doesn't come back when you return. xdr-boost fixes this with a watchdog that automatically restores your brightness within a few seconds after:

- Closing and reopening the laptop lid
- Locking and unlocking the screen
- Sleep and wake
- Plugging/unplugging external displays

If you turned XDR on, it stays on — no matter what. If macOS resets the gamma table (wake, lock, color profile changes), the watchdog re-applies the boost within a second.

## License

MIT
