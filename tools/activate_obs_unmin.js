function activateObs() {
    var wins = (typeof workspace.windowList === 'function')
        ? workspace.windowList()
        : workspace.clientList();
    var obs = null;
    for (var i = 0; i < wins.length; i++) {
        var w = wins[i];
        var caption = ((w.caption || '') + ' ' + (w.resourceName || '')).toLowerCase();
        if (caption.indexOf('obs') >= 0)
            obs = w;
    }
    if (obs) {
        obs.minimized = false;
        obs.keepAbove = true;
        workspace.activeWindow = obs;
    }
}
activateObs();
