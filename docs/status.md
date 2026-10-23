# Status

Current state only. The next session starts here. History: `docs/history/status-journal.md`.
Budget 15 KB.

## Where things stand, 2026-10-22

| Thing | State |
|---|---|
| Released | 1.4.5 (`be25c0f`), verified on the marketplace (#11121) |
| `main` on GitHub | 1.5.0, the commit named in issue #12622 |
| Tag `v1.5.0` | On the commit named in #12622 (moved there on 2026-10-22) |
| Marketplace | #12622 `[Verify]` 1.5.0: compatibility and security baseline passed, waiting for a maintainer |
| Installed copy | Runs the 1.5.0 files, copied in for the live check |

## Pending

1. #12622 approved. While it is open, a push makes it stale: edit its body to the new HEAD SHA and watch the bot.
2. After approval, `omarchy plugin update io.github.selfcrypto.power-saving` so the installed copy is clean again.
3. Check what logind does when another program holds a sleep lock: the suspend call is
   interactive and polkit allows ignoring a lock with an admin password, so it may prompt
   instead of being refused. The README claim was removed until this is tested (needs a real
   suspend; mind the short-suspend NVMe issue).
4. Config writes close together can lose the first: `mutateIdleConfig` rebuilds the entry from the
   last file reload, so a second write before the reload (stepper commit, then a switch click on
   another stage within a fraction of a second) overwrites the first. `setGatedStage` already
   writes switch and timeout of one stage together. Fix: keep a pending entry in the service and
   apply each mutation onto it until the reload matches. Found by the Fable review, 2026-10-22.

5. Branch `suspend-then-hibernate` (not pushed): suspend mode (suspend, then hibernate, hibernate). Unit tests,
   lint and the live panel checked; the logind call was dry-run, no real hibernate yet. A real one
   writes RAM to the swapfile on the NVMe: only with Kike's go-ahead, after closing what is open.
   Releases as 1.6.0 after #12622 is approved.

## Standing facts

- The unlock-screen blank delay is in the cloned lock plugin `~/.config/omarchy/plugins/kike.lock`, not here.
- A monitor that reconnects after DPMS off is the MSI OSD "Auto Scan" option, not the plugin.
- Only the keyboard wakes the PC from suspend (kernel USB wakeup, udev rule), not the plugin.

## Done

- **2026-10-23.** Lock fired on an active user: a suspend switch during an idle cycle ended the away
  state but left the lock timer running, so input only closed the screensaver. Now the away state
  is kept and standby/suspend rescheduled (on branch `suspend-then-hibernate`).

- **2026-10-22.** 1.5.0: schedule panel, one-line rows with key caps and −/+ steppers, stage
  order within a group, new preview, em dashes removed, node tests, repo-docs layout.
- **2026-10-22.** Marketplace rejected the first push: `AGENTS.md` was a symlink. Now a file.
- **2026-10-22.** Fable review fixes: a refused stepper write puts the saved value back; steppers
  always include the value they show (times that are not whole minutes); "moved to" only after a
  successful write; the 10 s minimum wins over a neighbour's time set below it by hand.
- **2026-10-22.** Screensaver left on screen after stay awake cancelled the idle cycle: its windows
  were forgotten, so mouse movement did not close it. Windows now stay tracked until they close.
