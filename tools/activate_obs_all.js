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
        for (var j = 0; j < wins.length; j++) {
            var x = wins[j];
            if (x !== obs)
                x.minimized = true;
        }
        workspace.activeWindow = obs;
        obs.keepAbove = true;
    }
}
activateObs();
