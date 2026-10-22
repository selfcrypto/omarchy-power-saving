# omarchy-power-saving · Omarchy shell plugin with four idle stages

Bar widget and service for the Omarchy shell (Quickshell, QML): screensaver, monitor standby,
lock and suspend, each with its own switch and idle timeout. Published on the Omarchy plugin
marketplace as `io.github.selfcrypto.power-saving` and installed on Kike's desktop, where it
replaces the stock `omarchy.idle` service. A broken `Service.qml` means no lock and no suspend.

Where every file and function is: `MAP.md` (by topic) and `SYMBOLS.md` (every symbol, grep it).
Current state: `docs/status.md`. Why things are the way they are: `docs/decisions.md` (grep its
index). Procedures: `docs/runbooks/`. Reader-facing: `README.md`.

## Parts

| Path | Role |
|---|---|
| `Service.qml` | The service: idle monitors, stage timers, DPMS, suspend, config writes, IPC target `idle` |
| `Panel.qml`, `IdleSchedule.qml`, `MinutesField.qml` | The bar icon and its panel |
| `IdleModel.js` | Pure helpers shared by both, tested with node |
| `tests/` | `node --test tests/` |
| `manifest.json`, `preview.png`, `README.md` | What the marketplace shows |

## Where things run

| Thing | Where |
|---|---|
| Installed copy | `~/.config/omarchy/plugins/io.github.selfcrypto.power-saving`, a clone of this repo |
| Shell | `omarchy-shell` (Quickshell, `/usr/share/omarchy/shell`); log in `journalctl --user` |
| Settings | This plugin's entry in `~/.config/omarchy/shell.json`; screensaver switch in `~/.local/state/omarchy/toggles/screensaver-off` |
| Marketplace | GitHub omacom/omarchy-plugin-marketplace, pinned to one commit per release |

## Rules that apply everywhere

- Colors and sizes come from `qs.Commons` (`Commons.Color`, `Style`); nothing hard-coded.
- Panel keys must keep working: `t`, `1`-`4`, `r` and `o` (both on release), `k`, `s`.
- Within a group the earlier stage never fires after the later one while both are on (`IdleModel.js` `timeoutBounds`).
- No em dashes and no filler in code, docs, manifest, commits or issues.
- Nothing is pushed, tagged or filed on the marketplace without asking first.

## Session protocol

1. Read this file and `docs/status.md`. Open `MAP.md` before grepping; grep `SYMBOLS.md` for a name.
2. Work on a branch in this repo, never in the installed copy.
3. Verify: `node --test tests/`, `qmllint` on changed QML, then the live shell check in `docs/runbooks/testing.md`.
4. Release as in `docs/runbooks/release.md`: version in `manifest.json`, tag, `[Verify]` issue.

After any change, before the work is called done:

- `docs/status.md`: what is now true and what is pending; move stale Done entries to
  `docs/history/status-journal.md`.
- `docs/decisions.md`: append what a future session would otherwise re-litigate.
- `MAP.md`: a new file gets its role line; a moved responsibility moves its row.
- `repo-docs map && repo-docs check`, clean. Commit the docs with the code.

## Keeping these files small

`CLAUDE.md`, `MAP.md` and `docs/status.md` are read at the start of every session, so every line
costs every session. A rule is one line; its story goes to `docs/decisions.md`. A fact that stops
being current is removed, not annotated. Budgets: this file 15 KB, `MAP.md` 12 KB,
`docs/status.md` 15 KB. `SYMBOLS.md` is generated: never edit it, regenerate it.
