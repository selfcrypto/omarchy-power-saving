# Status

Current state only. The next session starts here. History: `docs/history/status-journal.md`.
Budget 15 KB.

## Where things stand, 2026-10-22

| Thing | State |
|---|---|
| Released | 1.4.5 (`be25c0f`), verified on the marketplace (#11121) |
| `main` | 1.5.0: schedule panel, stage order within a group, repo-docs layout |
| Installed copy | Runs the 1.5.0 files, copied in for the live check |
| Marketplace | 1.5.0 needs a `[Verify]` issue on the HEAD of `main` once pushed |

## Pending

1. Push `main`, tag `v1.5.0`, open the `[Verify]` issue (`docs/runbooks/release.md`). Waits on Kike.
2. After approval, `omarchy plugin update io.github.selfcrypto.power-saving` so the installed copy is clean again.

## Standing facts

- The unlock-screen blank delay is in the cloned lock plugin `~/.config/omarchy/plugins/kike.lock`, not here.
- A monitor that reconnects after DPMS off is the MSI OSD "Auto Scan" option, not the plugin.
- Only the keyboard wakes the PC from suspend (kernel USB wakeup, udev rule), not the plugin.

## Done

- **2026-10-22.** 1.5.0: schedule panel, one-line rows with key caps and −/+ steppers, stage
  order within a group, new preview, em dashes removed, node tests, repo-docs layout.
