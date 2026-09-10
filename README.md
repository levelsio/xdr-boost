# xdr-boost

`xdr-boost` increases display brightness above the standard dynamic range (SDR) limit.
It uses the Liquid Retina XDR display in a MacBook Pro.

## Requirements

- MacBook Pro with a Liquid Retina XDR display
- macOS 12 or later
- Apple Command Line Tools to build from source

## Build from source

Run these commands in Terminal:

```sh
git clone https://github.com/levelsio/xdr-boost.git
cd xdr-boost
make build
```

The executable is `.build/xdr-boost`.

## Install the app

To build the disk image, run:

```sh
make dmg
```

1. Open `.build/XDR-Boost.dmg`.
2. Drag **XDR Boost.app** to **Applications**.
3. Eject the disk image.
4. Open **XDR Boost** from **Applications**.
5. Select the sun icon in the menu bar.
6. Select **Turn On**.

The app starts with the brightness boost off.
Each build uses the processor architecture of the build Mac.
Use `make app` to build only the app.

The default build uses a local signature.
Apple notarisation is not part of this build.
If macOS blocks the app, refer to [Apple's instructions](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac).

To start the app at login, add it to **Login Items** in **System Settings**.

## Select a mode

Multiply mode uses a Metal overlay to increase brightness.
Gamma mode changes the gamma table that controls red, green and blue output.
The app saves the initial table.
It puts this table back when you stop the boost.

The app uses gamma mode on macOS 27 or later.
On earlier macOS versions, it uses multiply mode.
The executable uses multiply mode by default.

| Mode | Menu values | Default value |
| --- | --- | --- |
| Multiply | 1.5, 2.0, 3.0, 4.0 | 2.0 |
| Gamma | 1.10, 1.25, 1.50, 1.60 | 1.10 |

Gamma values are control factors.
They do not show brightness in nits.

To start multiply mode from Terminal, run:

```sh
./.build/xdr-boost
```

To start gamma mode at 1.25, run:

```sh
./.build/xdr-boost --gamma 1.25
```

Run only one brightness utility at a time.

## Stop the boost

Press **Ctrl+Option+Cmd+V** to switch the boost on or off.
Select **Quit** in the sun menu to close the app.

To stop the app from Terminal, run:

```sh
./.build/xdr-boost --kill
```

This command sends SIGTERM to the current user's app processes.
Gamma mode puts the initial table back before the app stops.
If this step fails, the app stays open and tries again.
With SIGKILL, the app cannot put the initial table back.

## Install the terminal command

Run:

```sh
sudo make install
```

The command is available as `xdr-boost`.

To remove the terminal command, run:

```sh
make remove-agent
sudo make uninstall
```

## Tests

Run:

```sh
make test
```

All 19 tests pass.
Hardware tests used one built-in XDR display with macOS 27.0 beta.
Tests for sleep, wake and other displays are still necessary.
The [test report](docs/gamma-mode.md) gives the results and limits.

## Licence

[MIT](LICENSE).
