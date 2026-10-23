# Decisions

Append-only. One entry per decision a future session would otherwise re-litigate or silently
contradict. Newest last. Navigate by grepping titles or the index; never read this file in full.

Format:

```
## YYYY-MM-DD · short title
**Decision.** What was decided.
**Why.** The reason, briefly. Who asked, if someone did.
**Alternative rejected.** What was not chosen, and what it would have cost.
```

Titles are never changed once cited from another file.

## Index

- `Stage order within a group` · `CLAUDE.md`, `MAP.md`
- `Panel keys: standby on release, lock on k` · `CLAUDE.md`

## 2026-09-04 · Standby drives DPMS itself
**Decision.** The standby stage calls Hyprland's dpms dispatcher on its own idle monitor.
**Why.** Omarchy has no monitor standby; the lock screen's "blank" only lowers one monitor's brightness.
**Alternative rejected.** Reusing the lock blank: one monitor, backlight only.

## 2026-09-04 · Suspend through logind over D-Bus
**Decision.** Suspend is `busctl` to logind, never `systemctl`.
**Why.** The marketplace scanner reads any `systemctl` mention as service management, which blocks a standard-installation listing.
**Alternative rejected.** `systemctl suspend`: same call, failed the scan.

## 2026-09-04 · Panel keys: standby on release, lock on k
**Decision.** The panel has its own key catcher. `o` and `r` run on key release; lock is `k`.
**Why.** `misc.key_press_enables_dpms` woke the monitors on the release of the key that turned them off. The stock catcher turns lowercase `l` into a cursor move.
**Alternative rejected.** Stock `PanelKeyCatcher`: press only, no `l`.

## 2026-09-09 · Settings live on the plugin's bar entry
**Decision.** Stage settings are written to this plugin's entry in `shell.json`; the stock `idle` block is only read.
**Why.** Since Omarchy 4.0.3 a third-party plugin can only write its own bar entry.
**Alternative rejected.** `mutateShellConfig`: reserved for full-bar plugins.

## 2026-10-02 · Stages count from when the user went idle
**Decision.** Idle monitors only mark when the user went idle; stages run on timers from that moment.
**Why.** Hyprland resets idle monitors when the screensaver or lock opens, which pushed later stages back and cancelled standby.
**Alternative rejected.** One idle monitor per stage: reset by the service's own actions.

## 2026-10-14 · Minutes field without an editable text control
**Decision.** The minutes box shows a plain `Text` and takes digits key by key.
**Why.** Marketplace review of 1.4.4 (#11121): letters must reach the panel's shortcuts while the field has focus.
**Alternative rejected.** `TextInput`: swallows panel keys.

## 2026-10-22 · Stage order within a group
**Decision.** While both are on, the screensaver may not come after standby and lock may not come after suspend; equal times are allowed. The service rejects an out-of-order timeout, the steppers stop at the neighbour, and switching a stage on moves its time into range with a note in the panel. Times written to `shell.json` by hand are used as they are.
**Why.** Kike asked that a step's waiting time never be lower than the previous one. Per group, because the defaults put lock (5 min) before standby (10 min) and that order is valid.
**Alternative rejected.** One chain 1 to 4: rejects the defaults and forbids locking before the monitors go off.

## 2026-10-22 · Schedule-first panel shared with WireGuard
**Decision.** The panel opens with the stages as dots in firing order (`IdleSchedule.qml`), evenly spaced; rows are one line with a key cap and a −/+ stepper. The same language (hero, one live card, grouped rows, key-cap footer, theme accent) is used in `omarchy-wireguard`.
**Why.** Kike found the panel plain next to the top marketplace plugins, which each have one visual tied to their subject. Codex (gpt-6-astra) reached the same proposal independently.
**Alternative rejected.** A timeline to scale: short stages bunch up when suspend is far out; the labels carry the minutes.

## 2026-10-22 · Marketplace preview from a real screenshot
**Decision.** `preview.png` is 1920×960: name and three plain lines on the left, a screenshot of the panel on the right, cropped to its border.
**Why.** Matches the layout of the best marketplace previews without showing anything that is not the real panel.
**Alternative rejected.** An HTML mock-up of the panel: drifts from the real one.

## 2026-10-22 · Cancelling the idle cycle keeps the screensaver tracked
**Decision.** `cancelIdleCycle` no longer forgets the screensaver windows; they are forgotten when they close or when the service closes them (`stopScreensaver`, standby, lock).
**Why.** Stay awake switching on while the screensaver was up (Claude's hooks did it every few minutes) cancelled the cycle and forgot windows that stayed on screen. Mouse movement then woke the monitors but left the screensaver, which only a key press closed. The next cycle's launch found it running and added nothing. Reported by Kike twice on 2026-10-22.
**Alternative rejected.** Closing the screensaver when stay awake switches on: hides it from someone who is away for no reason the user caused.

## 2026-10-23 · A standby or suspend change keeps the away state
**Decision.** When only the standby or suspend monitor is re-armed (switched or retimed), the away state is kept and those two stages are rescheduled from `awaySince`. The away state still ends when the cycle monitor changes or nothing is armed.
**Why.** Ending it left the screensaver/lock cycle running with nothing to cancel it: input only closed the screensaver, and the lock fired minutes later while the user was at the machine. Seen on 2026-10-23 when the Claude hook switched suspend on during an idle cycle; any config write does the same.
**Alternative rejected.** Cancelling the cycle with the away state: a config write while the user is away would put the lock back by a full cycle.

## 2026-10-23 · Hibernate is a stage of its own
**Decision.** Hibernate is a fifth stage in its own panel section, with switch, minutes stepper, key `5`, run-now key `h` and a schedule dot. It calls logind's `Hibernate` after locking, and is shown and armed only when `CanHibernate` answers `yes`. No order rule ties it to suspend.
**Why.** Kike asked for hibernation as a section with the same rules as the others. A mode chooser under the suspend row (suspend / then hibernate / hibernate) was built first and rejected as looking botched.
**Alternative rejected.** The mode chooser. Astra (gpt-6-astra) suggested putting Hibernate in the System section; Kike asked for its own section.
