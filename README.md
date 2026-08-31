# Omarchy Power Saving

Idle power saving for [Omarchy](https://omarchy.org) in three independent
stages — **screensaver**, **lock** and **suspend** — each with its own on/off
switch and idle timeout, configured from a bar panel.

Omarchy's stock idle service only knows screensaver + lock, cannot switch
either off individually, and never suspends. This plugin replaces it.

## Who it's for

- **Desktop PCs** first of all. A desktop has no lid switch, and stock Omarchy
  has no idle-suspend stage, so it simply never sleeps. This plugin gives it
  the "suspend after N minutes idle" every other desktop OS has.
- **Laptops left open.** Closing the lid already suspends (that's logind, not
  this plugin), but a laptop sitting open on a desk never suspends on idle in
  stock Omarchy either — and there it costs battery. The per-stage switches
  ("screensaver but no lock at home") are useful on any machine.
- Not yet: separate timeouts for battery and mains. One set of timeouts
  applies whatever the power source.

## Preview

![Power Saving panel: three stage rows with minutes and switches](preview.png)

## Features

- Screensaver, lock and suspend as separate stages, each with a switch and a
  timeout in minutes of idle.
- Suspend has its own idle monitor that respects idle inhibitors (a playing
  video keeps the machine awake) and survives the lock.
- "Stay awake" pauses all three stages; it is the same flag as
  `omarchy toggle idle` and the coffee-cup indicator.
- The screensaver switch is Omarchy's own `screensaver-off` toggle, so the
  Omarchy menu and the panel always agree.
- Numpad-safe minutes fields and one settings write per edit.
- Full IPC control.

## Installation

```bash
omarchy plugin add https://github.com/selfcrypto/omarchy-power-saving.git --enable && omarchy plugin disable omarchy.idle && omarchy restart shell
```

Disabling `omarchy.idle` is required: the plugin stays paused (and says so in
the panel and in a notification) while the stock idle service is enabled, so
the screen is never locked twice. Nothing else is touched; your existing
`idle.screensaver` / `idle.lock` values in `shell.json` keep their meaning.

Verify:

```bash
omarchy plugin list
omarchy plugin validate ~/.config/omarchy/plugins/io.github.selfcrypto.power-saving
omarchy-shell idle status
```

Update:

```bash
omarchy plugin update io.github.selfcrypto.power-saving
```

Remove (restores the stock service):

```bash
omarchy plugin remove io.github.selfcrypto.power-saving && omarchy plugin enable omarchy.idle && omarchy restart shell
```

## Usage

- **Left-click** the bar icon: open the panel.
- **Right-click**: toggle *stay awake*.
- In the panel, each stage row has a minutes field and a switch. Keys:
  `t` stay awake, `1`/`2`/`3` toggle a stage, `l` lock now, `s` suspend now.

Suspend always locks first: Omarchy's `omarchy-sleep-lock.service` locks the
session on `PrepareForSleep` whatever the lock stage says, so the machine wakes
to the lock screen.

## Configuration

Everything lives in the `idle` block of `~/.config/omarchy/shell.json` and is
written by the panel; the stock keys keep their stock meaning.

```json
"idle": {
  "screensaver": 300,
  "lock": 1200,
  "suspend": 900,
  "lockEnabled": false,
  "suspendEnabled": true
}
```

| Key | Meaning | Default |
|---|---|---|
| `screensaver`, `lock`, `suspend` | seconds of idle before the stage fires | 150, 300, 1800 |
| `lockEnabled` | lock stage on/off | `true` |
| `suspendEnabled` | suspend stage on/off | `false` |

The screensaver switch is the flag file `~/.local/state/omarchy/toggles/screensaver-off`
(`omarchy toggle screensaver`).

## IPC

The IPC target is `idle`, the same as the stock service, so existing calls
keep working.

```bash
omarchy-shell idle status                       # JSON: stages, monitors, last event
omarchy-shell idle stage suspend on             # on | off | toggle | status
omarchy-shell idle timeout suspend 2400         # seconds (min 10)
omarchy-shell idle timeout suspend ""           # print the current value
omarchy-shell idle suspend                      # suspend now
omarchy-shell idle enable | disable | toggle    # stay-awake, as upstream
```

## Requirements and dependencies

- Omarchy with the Quickshell shell (`omarchy-shell`); no extra packages.
- `systemctl suspend` must be permitted for the session (it is by default).
- No external services. No privileges beyond the user session.

## Notes

- Monitors are never reconfigured, only created and destroyed: Quickshell
  0.3.1 silently breaks an `IdleMonitor` whose timeout changes at runtime.
- Screensaver and lock share one idle monitor, as the stock service does;
  suspend has its own.
- While this plugin replaces `omarchy.idle`, the stock coffee-cup indicator in
  `omarchy.indicators` does nothing (it looks the service up by the stock id);
  use this widget's right-click instead.

## License

MIT — see [LICENSE](LICENSE).
