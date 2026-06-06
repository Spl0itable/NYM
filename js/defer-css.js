// Promote non-render-blocking stylesheets (preloaded with data-defer-style)
(function () {
    var links = document.querySelectorAll('link[rel="preload"][data-defer-style]');
    for (var i = 0; i < links.length; i++) {
        links[i].rel = 'stylesheet';
    }
})();
