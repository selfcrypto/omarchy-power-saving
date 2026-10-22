# Status

Current state only. The next session starts here. History: `docs/history/status-journal.md`.
Budget 15 KB.

## Where things stand, 2026-10-22

| Thing | State |
|---|---|
| Released | 1.4.5 (`be25c0f`), verified on the marketplace (#11121) |
| `main` | 1.5.0 pushed and tagged `v1.5.0` at `61ace1e` |
| Installed copy | Runs the 1.5.0 files, copied in for the live check |
| Marketplace | `[Verify]` issue #12622 for `61ace1e`, waiting for the bot and a maintainer |

## Pending

1. #12622 approved. Until then push nothing: a new commit makes the issue stale. This status
   update is committed locally only.
2. After approval, `omarchy plugin update io.github.selfcrypto.power-saving` so the installed copy is clean again.

## Standing facts

- The unlock-screen blank delay is in the cloned lock plugin `~/.config/omarchy/plugins/kike.lock`, not here.
- A monitor that reconnects after DPMS off is the MSI OSD "Auto Scan" option, not the plugin.
- Only the keyboard wakes the PC from suspend (kernel USB wakeup, udev rule), not the plugin.

## Done

- **2026-10-22.** 1.5.0: schedule panel, one-line rows with key caps and −/+ steppers, stage
  order within a group, new preview, em dashes removed, node tests, repo-docs layout.
