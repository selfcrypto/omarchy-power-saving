# Status

Current state only. The next session starts here. History: `docs/history/status-journal.md`.
Budget 15 KB.

## Where things stand, 2026-10-22

| Thing | State |
|---|---|
| Released | 1.4.5 (`be25c0f`), verified on the marketplace (#11121) |
| `main` on GitHub | 1.5.0, the commit named in issue #12622 |
| Tag `v1.5.0` | On `61ace1e`, the first 1.5.0 push; later fixes (AGENTS.md as a file, Fable review fixes) are after it |
| Marketplace | #12622 `[Verify]` 1.5.0: compatibility and security baseline passed, waiting for a maintainer |
| Installed copy | Runs the 1.5.0 files, copied in for the live check |

## Pending

1. #12622 approved. While it is open, a push makes it stale: edit its body to the new HEAD SHA and watch the bot.
2. Move tag `v1.5.0` to the verified commit, or leave it. Waits on Kike.
3. After approval, `omarchy plugin update io.github.selfcrypto.power-saving` so the installed copy is clean again.
4. Config writes close together can lose the first: `mutateIdleConfig` rebuilds the entry from the
   last file reload, so a second write before the reload (stepper commit, then a switch click on
   another stage within a fraction of a second) overwrites the first. `setGatedStage` already
   writes switch and timeout of one stage together. Fix: keep a pending entry in the service and
   apply each mutation onto it until the reload matches. Found by the Fable review, 2026-10-22.

## Standing facts

- The unlock-screen blank delay is in the cloned lock plugin `~/.config/omarchy/plugins/kike.lock`, not here.
- A monitor that reconnects after DPMS off is the MSI OSD "Auto Scan" option, not the plugin.
- Only the keyboard wakes the PC from suspend (kernel USB wakeup, udev rule), not the plugin.

## Done

- **2026-10-22.** 1.5.0: schedule panel, one-line rows with key caps and −/+ steppers, stage
  order within a group, new preview, em dashes removed, node tests, repo-docs layout.
- **2026-10-22.** Marketplace rejected the first push: `AGENTS.md` was a symlink. Now a file.
- **2026-10-22.** Fable review fixes: a refused stepper write puts the saved value back; steppers
  always include the value they show (times that are not whole minutes); "moved to" only after a
  successful write; the 10 s minimum wins over a neighbour's time set below it by hand.
