// KWin script: activate the OBS window.
//
// Usage:
//   qdbus6 org.kde.KWin /Scripting \
//     org.kde.kwin.Scripting.loadScript \
//     /home/demo/Загрузки/sega/karabas-go-core-sega/tools/activate_obs.js
//   qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.start
//   sleep 1
//   spectacle -a -b -n -o docs/captures/obs_now.png
//
// KWin 6 uses workspace.windowList(); older KWin uses workspace.clientList().

function activateObs() {
    var wins = (typeof workspace.windowList === 'function')
        ? workspace.windowList()
        : workspace.clientList();

    for (var i = 0; i < wins.length; i++) {
        var w = wins[i];
        var caption = (w.caption || w.resourceName || '').toLowerCase();
        if (caption.indexOf('obs') >= 0) {
            workspace.activeWindow = w;
            return;
        }
    }
}

activateObs();
