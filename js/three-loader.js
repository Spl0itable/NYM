// Loads three.js (UMD build) followed by three-globe
(function () {
    'use strict';

    window.threeGlobeReady = new Promise(function (resolve, reject) {
        var threeScript = document.createElement('script');
        threeScript.src = 'https://cdn.jsdelivr.net/npm/three@0.160.0/build/three.min.js';
        threeScript.onload = function () {
            // three.js UMD has now set window.THREE.
            var globeScript = document.createElement('script');
            globeScript.src = 'https://unpkg.com/three-globe@2.31.0/dist/three-globe.min.js';
            globeScript.onload = function () { resolve(); };
            globeScript.onerror = function (e) { reject(e); };
            document.head.appendChild(globeScript);
        };
        threeScript.onerror = function (e) { reject(e); };
        document.head.appendChild(threeScript);
    });
})();
