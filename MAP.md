# omarchy-power-saving: where each thing is

Paths are relative to this file. Every symbol with its line number: `SYMBOLS.md` (generated,
grep it). This file says what each file is for and where to go for a kind of change.

## I want to change…

| What | Where | Also moves |
|---|---|---|
| When a stage fires, what it does | `Service.qml` (`syncMonitors`, `scheduleAwayStage`, `startIdleCycle`) | README "Behaviour" |
| Suspend and hibernate never both on | `IdleModel.js` (`EXCLUSIVE`, `exclusiveSettings`), `Service.qml` (`mutateIdleConfig`, `setGatedStage`) | `tests/idle-model.test.js` |
| Which stage times are allowed | `IdleModel.js` (`GROUP_ORDER`, `timeoutBounds`), `Service.qml` (`setStageTimeout`, `timeoutWhenEnabled`) | `tests/idle-model.test.js`, README "Order within a group" |
| Switching a stage on or off | `Service.qml` (`setStageEnabled`, `setGatedStage`) | |
| Config keys and their defaults | `Service.qml` (`default*Seconds`), `IdleModel.js` (`STAGE_KEYS`, `mergedStageConfig`) | README "Configuration" |
| An IPC call | `Service.qml` (`IpcHandler`, target `idle`) | README "IPC" |
| The schedule at the top of the panel | `IdleSchedule.qml` | |
| A stage row, the hero, the footer | `Panel.qml` (`StageRow`, `KeyCap`, `PanelHero`) | `preview.png` |
| A panel key | `Panel.qml` (`keyCatcher`) | README "Keys in the panel", footer in `Panel.qml` |
| The minutes stepper | `MinutesField.qml` | |
| The bar icon and its tooltip | `Panel.qml` (`BarIconButton`) | |
| Marketplace text or version | `manifest.json` | `docs/runbooks/release.md` |

## Files

| File | Role |
|---|---|
| `Service.qml` | Loaded once by the shell: idle monitors, stage timers, screensaver, DPMS standby, lock, suspend, hibernate, stay awake, config writes, IPC |
| `Panel.qml` | Bar icon and panel, one per monitor; reads and calls the service only |
| `IdleSchedule.qml` | The stages as dots in firing order; a click switches a stage |
| `MinutesField.qml` | Minutes spin box with −/+ buttons and key-by-key digit entry |
| `IdleModel.js` | Pure helpers: config parsing, stage order and bounds, summaries |
| `tests/idle-model.test.js` | Stage bounds, clamping, summary order |
| `manifest.json` | Plugin id, version, marketplace descriptions, entry points |
| `preview.png` | Marketplace image, 1920×960, made from a screenshot of the panel |
