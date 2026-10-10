(function () {
    var root = document.documentElement;
    var waiting = [];
    var picker = {
        choice: null,
        onChoose: function (fn) {
            if (picker.choice !== null) fn(picker.choice);
            else waiting.push(fn);
        }
    };
    window.NymFirstLang = picker;
    if (!root.classList.contains('nym-first-lang')) return;

    var screen = document.getElementById('firstLangScreen');
    var list = document.getElementById('firstLangList');
    var search = document.getElementById('firstLangSearch');
    var empty = document.getElementById('firstLangEmpty');
    var close = document.getElementById('firstLangClose');
    if (!screen || !list || !search || typeof NYM_TRANSLATE_LANGUAGES === 'undefined') {
        root.classList.remove('nym-first-lang');
        return;
    }

    function nativeName(code) {
        var key = String(code).toLowerCase();
        return NYM_TRANSLATE_LANG_NATIVE[key] || NYM_TRANSLATE_LANG_NAMES[key] || code;
    }

    function englishName(code) {
        return NYM_TRANSLATE_LANG_NAMES[String(code).toLowerCase()] || code;
    }

    function browserDefault() {
        var known = new Map(NYM_TRANSLATE_LANGUAGES.map(function (l) { return [l.code.toLowerCase(), l.code]; }));
        var tags = (navigator.languages && navigator.languages.length) ? navigator.languages : [navigator.language || 'en'];
        for (var i = 0; i < tags.length; i++) {
            var full = String(tags[i] || '').toLowerCase();
            if (!full) continue;
            var base = full.split('-')[0];
            if (base === 'en') return '';
            if (known.has(full)) return known.get(full);
            if (known.has(base)) return known.get(base);
        }
        return '';
    }

    var preset = browserDefault();
    var options = [{ code: '', name: 'English' }].concat(NYM_TRANSLATE_LANGUAGES
        .filter(function (l) { return l.code !== 'en'; })
        .sort(function (a, b) { return a.name.localeCompare(b.name); }));

    var frag = document.createDocumentFragment();
    var active = null;
    options.forEach(function (l) {
        var name = l.code ? nativeName(l.code) : l.name;
        var english = l.code ? englishName(l.code) : '';
        var sub = l.code && name !== english ? english : '';
        var row = document.createElement('button');
        row.type = 'button';
        row.className = 'first-lang-row' + (l.code === preset ? ' is-active' : '');
        row.dataset.lang = l.code;
        row.dataset.name = (l.code ? (l.name + ' ' + name).toLowerCase() : 'english') + ' ' + (l.code || 'en').toLowerCase();
        var label = document.createElement('span');
        label.className = 'first-lang-name';
        label.textContent = name;
        row.appendChild(label);
        if (sub) {
            var subLabel = document.createElement('span');
            subLabel.className = 'first-lang-sub';
            subLabel.textContent = sub;
            row.appendChild(subLabel);
        }
        if (l.code === preset) {
            active = row;
            row.setAttribute('aria-current', 'true');
        }
        frag.appendChild(row);
    });
    list.textContent = '';
    list.appendChild(frag);
    screen.classList.add('is-ready');
    var rows = list.children;

    var done = false;
    function finish(code) {
        if (done) return;
        done = true;
        document.removeEventListener('keydown', onKey, true);
        root.classList.remove('nym-first-lang');
        picker.choice = code;
        waiting.splice(0).forEach(function (fn) { fn(code); });
    }

    search.addEventListener('input', function () {
        var q = search.value.trim().toLowerCase();
        var any = false;
        for (var i = 0; i < rows.length; i++) {
            var hit = !q || rows[i].dataset.name.indexOf(q) !== -1;
            rows[i].classList.toggle('nm-hidden', !hit);
            if (hit) any = true;
        }
        if (empty) empty.classList.toggle('nm-hidden', any);
    });
    list.addEventListener('click', function (e) {
        var row = e.target.closest('.first-lang-row');
        if (row) finish(row.dataset.lang || '');
    });
    if (close) close.addEventListener('click', function () { finish(preset); });

    function stops() {
        var out = close ? [close, search] : [search];
        for (var i = 0; i < rows.length; i++) {
            if (!rows[i].classList.contains('nm-hidden')) out.push(rows[i]);
        }
        return out;
    }

    function typed(e) {
        return !e.ctrlKey && !e.metaKey && !e.altKey && !e.isComposing && /^\S$/u.test(e.key || '');
    }

    function onKey(e) {
        if (e.key === 'Escape') {
            finish(preset);
            return;
        }
        screen.classList.add('is-keyed');
        if (typed(e) && document.activeElement !== search) {
            try { search.focus({ preventScroll: true }); } catch (_) { }
            return;
        }
        if (e.key !== 'Tab') return;
        var items = stops();
        var at = items.indexOf(document.activeElement);
        var wrap = e.shiftKey ? at <= 0 : (at === -1 || at === items.length - 1);
        if (!wrap) return;
        e.preventDefault();
        items[e.shiftKey ? items.length - 1 : 0].focus();
    }
    document.addEventListener('keydown', onKey, true);

    function keyboardFirst() {
        try {
            return window.matchMedia('(pointer: fine)').matches || window.matchMedia('(any-pointer: fine) and (any-hover: hover)').matches;
        } catch (_) {
            return false;
        }
    }

    if (active) list.scrollTop = Math.max(0, active.offsetTop - (list.clientHeight - active.offsetHeight) / 2);
    try {
        if (keyboardFirst()) search.focus({ preventScroll: true });
        else if (active) active.focus({ preventScroll: true });
    } catch (_) { }
})();
