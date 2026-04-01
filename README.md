# xdr-boost

Free and open-source XDR brightness booster for MacBook Pro. Like [Vivid](https://www.getvivid.app/), but free.

Unlocks the full brightness of your Liquid Retina XDR display beyond the standard SDR limit. Your MacBook Pro can go up to 1600 nits — this tool lets you use it.

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

The app always starts with XDR **off** — you have to manually turn it on. So rebooting will always give you a normal screen.

The app automatically handles sleep/wake and lid close/open — your brightness setting is restored when you come back.

## License

MIT
