# Testing

Unit tests for the pure helpers:

```bash
node --test tests/
```

Lint the QML (the warnings about unqualified access and `QObject` members are the baseline; look for new ones):

```bash
/usr/lib/qt6/bin/qmllint -I ~/.local/share/qml-imports -I /usr/lib/qt6/qml *.qml
```

`~/.local/share/qml-imports/qs` is a link to `/usr/share/omarchy/shell`, so `qs.Commons` and `qs.Ui` resolve.

Live check in the shell. Copy the files into the installed clone, restart the shell, open the panel:

```bash
P=~/.config/omarchy/plugins/io.github.selfcrypto.power-saving
cp *.qml IdleModel.js "$P"/
omarchy restart shell
omarchy-shell io.github.selfcrypto.power-saving open
journalctl --user --since "-2 min" | grep -i power-saving
```

The hot reload keeps the old compiled QML, so the restart is needed. Restart only while
`omarchy-shell idle status` shows `"away": false` and no screensaver windows: a restart under a
running screensaver draws the bar over it. The panel opens on the monitor
whose bar answers the IPC. Stay awake is on while an agent works; `omarchy-shell idle enable` shows
the schedule live and `omarchy-shell idle disable` turns stay awake back on.

Stage order through IPC. With standby on, this is refused with the allowed range; with standby
off it is accepted, so note the old values first and put them back:

```bash
omarchy-shell idle status
omarchy-shell idle timeout screensaver 99999
```

Put the installed copy back to the released version:

```bash
git -C "$P" checkout -- . && git -C "$P" clean -fd && omarchy restart shell
```
