// syntax-highlight.js - Tiny built-in code highlighter for fenced markdown blocks.
// Tokens: comment, string, number, keyword, builtin, type, function.

(function () {
    const KW = {
        js: ['async','await','break','case','catch','class','const','continue','debugger','default','delete','do','else','export','extends','finally','for','from','function','if','import','in','instanceof','let','new','null','of','return','static','super','switch','this','throw','true','false','try','typeof','undefined','var','void','while','with','yield'],
        py: ['False','None','True','and','as','assert','async','await','break','class','continue','def','del','elif','else','except','finally','for','from','global','if','import','in','is','lambda','nonlocal','not','or','pass','raise','return','try','while','with','yield','match','case'],
        rs: ['as','async','await','break','const','continue','crate','dyn','else','enum','extern','false','fn','for','if','impl','in','let','loop','match','mod','move','mut','pub','ref','return','self','Self','static','struct','super','trait','true','type','unsafe','use','where','while','yield','box'],
        go: ['break','case','chan','const','continue','default','defer','else','fallthrough','for','func','go','goto','if','import','interface','map','package','range','return','select','struct','switch','type','var','true','false','nil','iota'],
        java: ['abstract','assert','boolean','break','byte','case','catch','char','class','const','continue','default','do','double','else','enum','extends','final','finally','float','for','goto','if','implements','import','instanceof','int','interface','long','native','new','null','package','private','protected','public','return','short','static','strictfp','super','switch','synchronized','this','throw','throws','transient','try','void','volatile','while','true','false'],
        c: ['auto','break','case','char','const','continue','default','do','double','else','enum','extern','float','for','goto','if','inline','int','long','register','restrict','return','short','signed','sizeof','static','struct','switch','typedef','union','unsigned','void','volatile','while','_Bool','_Complex','_Imaginary','bool','true','false','NULL','nullptr'],
        cpp: ['alignas','alignof','and','asm','auto','bool','break','case','catch','char','class','co_await','co_return','co_yield','const','constexpr','const_cast','continue','decltype','default','delete','do','double','dynamic_cast','else','enum','explicit','export','extern','false','final','float','for','friend','goto','if','inline','int','long','mutable','namespace','new','noexcept','not','nullptr','operator','or','override','private','protected','public','register','reinterpret_cast','return','short','signed','sizeof','static','static_cast','struct','switch','template','this','thread_local','throw','true','try','typedef','typeid','typename','union','unsigned','using','virtual','void','volatile','while','xor'],
        sh: ['if','then','else','elif','fi','for','in','do','done','while','until','case','esac','function','return','break','continue','exit','export','local','readonly','set','unset','source','alias','declare','typeset','true','false'],
        sql: ['SELECT','FROM','WHERE','INSERT','UPDATE','DELETE','CREATE','DROP','ALTER','TABLE','INDEX','VIEW','JOIN','LEFT','RIGHT','INNER','OUTER','FULL','ON','AS','AND','OR','NOT','NULL','IS','IN','LIKE','BETWEEN','GROUP','BY','ORDER','HAVING','LIMIT','OFFSET','UNION','ALL','DISTINCT','INTO','VALUES','SET','PRIMARY','KEY','FOREIGN','REFERENCES','DEFAULT','UNIQUE','CHECK','CASE','WHEN','THEN','ELSE','END','WITH','RETURNING','BEGIN','COMMIT','ROLLBACK','TRANSACTION','IF','EXISTS','TRUE','FALSE']
    };
    KW.ts = KW.js.concat(['any','as','boolean','declare','enum','interface','is','keyof','module','namespace','never','number','readonly','satisfies','string','symbol','type','unique','unknown','infer','public','private','protected','abstract','implements']);
    KW.jsx = KW.js;
    KW.tsx = KW.ts;

    const BUILTINS = {
        js: ['console','window','document','globalThis','Math','JSON','Object','Array','String','Number','Boolean','Date','Map','Set','Promise','RegExp','Symbol','BigInt','Error','fetch','setTimeout','setInterval','clearTimeout','clearInterval','queueMicrotask','structuredClone'],
        py: ['print','len','range','int','str','float','bool','list','dict','tuple','set','frozenset','bytes','bytearray','open','input','type','isinstance','enumerate','zip','map','filter','sorted','sum','min','max','abs','round','any','all','self','cls','__init__','__name__','super'],
        rs: ['Vec','String','Option','Result','Box','Rc','Arc','HashMap','HashSet','BTreeMap','Some','None','Ok','Err','println','print','format','vec','assert','assert_eq','assert_ne','panic','dbg','todo','unimplemented','unreachable','i8','i16','i32','i64','i128','u8','u16','u32','u64','u128','f32','f64','bool','char','str','isize','usize'],
        go: ['append','cap','close','copy','delete','len','make','new','panic','print','println','recover','complex','imag','real','string','int','int8','int16','int32','int64','uint','uint8','uint16','uint32','uint64','uintptr','byte','rune','float32','float64','bool','error'],
        ts: ['console','window','document','globalThis','Math','JSON','Object','Array','String','Number','Boolean','Date','Map','Set','Promise','RegExp','Symbol','BigInt','Error','fetch','Partial','Readonly','Record','Pick','Omit','Required','Exclude','Extract','ReturnType','Parameters'],
        sh: ['echo','cat','grep','sed','awk','cd','ls','rm','cp','mv','mkdir','rmdir','touch','chmod','chown','find','xargs','curl','wget','tar','gzip','gunzip','zip','unzip','ps','kill','top','df','du','wc','sort','uniq','head','tail','tr','tee','printf','read','test','sleep','date','env','which']
    };
    BUILTINS.tsx = BUILTINS.jsx = BUILTINS.ts;
    BUILTINS.c = BUILTINS.cpp = ['printf','scanf','fprintf','sprintf','snprintf','malloc','calloc','realloc','free','memcpy','memset','memcmp','strlen','strcpy','strncpy','strcmp','strncmp','strcat','strncat','strchr','strstr','fopen','fclose','fread','fwrite','fgets','fputs','exit','abort','assert','sizeof','NULL','stdin','stdout','stderr','std','cout','cin','cerr','endl','vector','string','map','unordered_map','set','unordered_set','pair','make_pair','shared_ptr','unique_ptr'];

    const LANG_ALIAS = {
        javascript: 'js', node: 'js', nodejs: 'js',
        typescript: 'ts',
        python: 'py', python3: 'py',
        rust: 'rs',
        golang: 'go',
        bash: 'sh', shell: 'sh', zsh: 'sh', sh: 'sh',
        'c++': 'cpp', cxx: 'cpp',
        'objective-c': 'c', objc: 'c',
        html: 'xml', svg: 'xml', xhtml: 'xml',
        yml: 'yaml'
    };

    function escapeHtml(s) {
        return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    function tok(cls, text) {
        return '<span class="hl-' + cls + '">' + escapeHtml(text) + '</span>';
    }

    function highlightJsonLike(src) {
        let out = '';
        const re = /"(?:\\.|[^"\\])*"|true|false|null|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|[{}\[\],:]|\s+|[^\s{}\[\],:"]+/g;
        let m;
        while ((m = re.exec(src)) !== null) {
            const t = m[0];
            if (t[0] === '"') {
                const afterIdx = re.lastIndex;
                const next = src.slice(afterIdx).match(/^\s*:/);
                out += next ? tok('key', t) : tok('string', t);
            } else if (t === 'true' || t === 'false' || t === 'null') out += tok('keyword', t);
            else if (/^-?\d/.test(t)) out += tok('number', t);
            else if (/^\s+$/.test(t)) out += escapeHtml(t);
            else out += escapeHtml(t);
        }
        return out;
    }

    function highlightXml(src) {
        let out = '';
        const re = /<!--[\s\S]*?-->|<\/?[A-Za-z][\w:-]*|\/?>|"[^"]*"|'[^']*'|[A-Za-z_:][\w:.-]*=|[^<"'>]+/g;
        let m;
        while ((m = re.exec(src)) !== null) {
            const t = m[0];
            if (t.startsWith('<!--')) out += tok('comment', t);
            else if (/^<\/?[A-Za-z]/.test(t)) out += tok('keyword', t);
            else if (t === '>' || t === '/>') out += tok('keyword', t);
            else if (t[0] === '"' || t[0] === "'") out += tok('string', t);
            else if (/=$/.test(t)) out += tok('builtin', t);
            else out += escapeHtml(t);
        }
        return out;
    }

    function highlightCss(src) {
        let out = '';
        const re = /\/\*[\s\S]*?\*\/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|--[\w-]+|@[\w-]+|#[0-9a-fA-F]{3,8}\b|-?\d+(?:\.\d+)?(?:px|em|rem|vh|vw|%|s|ms|deg|fr)?|[\w-]+\s*(?=:)|[{}();:,]|[\w-]+|\s+|./g;
        let m;
        while ((m = re.exec(src)) !== null) {
            const t = m[0];
            if (t.startsWith('/*')) out += tok('comment', t);
            else if (t[0] === '"' || t[0] === "'") out += tok('string', t);
            else if (t[0] === '@' || t.startsWith('--')) out += tok('keyword', t);
            else if (/^#[0-9a-fA-F]{3,8}$/.test(t)) out += tok('number', t);
            else if (/^-?\d/.test(t)) out += tok('number', t);
            else if (/\w/.test(t) && /:\s*$/.test(src.slice(m.index, m.index + t.length + 4))) out += tok('builtin', t.trim()) + (t.match(/\s+$/) ? t.match(/\s+$/)[0] : '');
            else out += escapeHtml(t);
        }
        return out;
    }

    function highlightGeneric(src, lang) {
        const kws = new Set(KW[lang] || []);
        const builtins = new Set(BUILTINS[lang] || []);
        const isShell = lang === 'sh';
        const lineComment = (lang === 'py' || lang === 'sh' || lang === 'yaml' || lang === 'rb')
            ? /^#.*/
            : /^\/\/.*/;
        const blockComment = (lang === 'py') ? null : /^\/\*[\s\S]*?\*\//;
        const pyDocstring = (lang === 'py') ? /^("""[\s\S]*?"""|'''[\s\S]*?''')/ : null;

        let out = '';
        let i = 0;
        const n = src.length;

        while (i < n) {
            const rest = src.slice(i);

            if (pyDocstring) {
                const m = rest.match(pyDocstring);
                if (m) { out += tok('comment', m[0]); i += m[0].length; continue; }
            }
            if (blockComment) {
                const m = rest.match(blockComment);
                if (m) { out += tok('comment', m[0]); i += m[0].length; continue; }
            }
            const lc = rest.match(lineComment);
            if (lc) { out += tok('comment', lc[0]); i += lc[0].length; continue; }

            const ch = src[i];
            if (ch === '"' || ch === "'" || ch === '`') {
                let j = i + 1;
                while (j < n) {
                    if (src[j] === '\\') { j += 2; continue; }
                    if (src[j] === ch) { j++; break; }
                    if (src[j] === '\n' && ch !== '`') { break; }
                    j++;
                }
                out += tok('string', src.slice(i, j));
                i = j;
                continue;
            }

            const numMatch = rest.match(/^(?:0x[0-9a-fA-F_]+|0b[01_]+|0o[0-7_]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)[fFuUlLnN]*/);
            if (numMatch && (i === 0 || !/[A-Za-z_$]/.test(src[i - 1]))) {
                out += tok('number', numMatch[0]);
                i += numMatch[0].length;
                continue;
            }

            const idMatch = rest.match(/^[A-Za-z_$][\w$]*/);
            if (idMatch) {
                const id = idMatch[0];
                if (kws.has(id)) out += tok('keyword', id);
                else if (builtins.has(id)) out += tok('builtin', id);
                else {
                    const after = src.slice(i + id.length).match(/^\s*\(/);
                    if (after && !isShell) out += tok('function', id);
                    else if (isShell && i === 0) out += tok('function', id);
                    else out += escapeHtml(id);
                }
                i += id.length;
                continue;
            }

            out += escapeHtml(ch);
            i++;
        }
        return out;
    }

    function normalizeLang(lang) {
        if (!lang) return null;
        const l = String(lang).toLowerCase().trim();
        if (LANG_ALIAS[l]) return LANG_ALIAS[l];
        if (KW[l] || BUILTINS[l]) return l;
        if (l === 'json' || l === 'jsonc') return 'json';
        if (l === 'xml' || l === 'html') return 'xml';
        if (l === 'css' || l === 'scss' || l === 'less') return 'css';
        return null;
    }

    function highlight(code, lang) {
        const l = normalizeLang(lang);
        if (!l) return escapeHtml(code);
        if (l === 'json') return highlightJsonLike(code);
        if (l === 'xml') return highlightXml(code);
        if (l === 'css') return highlightCss(code);
        return highlightGeneric(code, l);
    }

    // Attach to whichever global is available so the same code runs both on the
    // main thread (window) and inside the highlight Web Worker (self).
    (typeof self !== 'undefined' ? self : window).NymHighlight = { highlight: highlight, normalize: normalizeLang };
})();
