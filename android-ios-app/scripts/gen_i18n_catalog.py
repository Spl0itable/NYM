#!/usr/bin/env python3
"""Extract every static string passed to tr(...) / '...'.tr() across lib/ and
emit a Dart catalog so the app can pre-translate its entire UI in the
background. Only PURE string literals (no $-interpolation) are captured; a
tr(variable) call is skipped."""
import os, re, sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(REPO, 'lib')
OUT = os.path.join(REPO, 'lib/features/i18n/app_strings_catalog.dart')

# One Dart string literal (single or double quoted) with escapes.
STR = r"'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\""
# Adjacent-concatenated run of literals (whitespace/newlines allowed between).
RUN = r"(?:%s)(?:\s*(?:%s))*" % (STR, STR)

# tr( <literal run> ...   — function form. Negative lookbehind avoids attr(, substr(, etc.
RX_FN = re.compile(r"(?<![\w.$])tr\s*\(\s*(%s)" % RUN)
# <literal run> .tr(      — extension form.
RX_EXT = re.compile(r"(%s)\s*\.tr\s*\(" % RUN)

# Display-oriented named arguments whose STRING-LITERAL values are shown to the
# user — captured so strings that reach tr() indirectly (via tr(variable), e.g.
# the tutorial steps `TutorialStep(title:…, body:…)` and option-record
# `label:`s displayed through tr(label)) are also swept. Values already written
# as `arg: tr('…')` are NOT matched (a `tr(` follows the colon, not a quote), so
# this only adds the plain-literal ones. A named arg guarantees UI intent, so
# over-capture is negligible; any spurious entry just caches an unused
# translation.
_NAMED = (
    r"label|title|body|hint|hintText|tooltip|message|okLabel|cancelLabel|"
    r"placeholder|helperText|errorText|semanticLabel|subtitle|heading|"
    r"buttonLabel|emptyText|warning|amberHint|confirmLabel|actionLabel"
)
RX_NAMED = re.compile(r"(?<![\w.$])(?:%s)\s*:\s*(%s)" % (_NAMED, RUN))

# Individual literal within a run.
RX_ONE = re.compile(STR)

ESC = {'n': '\n', 't': '\t', 'r': '\r', "'": "'", '"': '"', '\\': '\\', '$': '$', 'b': '\b', 'f': '\f'}


def unescape(lit: str) -> str:
    # lit includes surrounding quotes.
    body = lit[1:-1]
    out = []
    i = 0
    while i < len(body):
        ch = body[i]
        if ch == '\\' and i + 1 < len(body):
            nxt = body[i + 1]
            if nxt == 'u':
                # \uXXXX or \u{XXXX}
                if i + 2 < len(body) and body[i + 2] == '{':
                    j = body.find('}', i + 2)
                    if j != -1:
                        try:
                            out.append(chr(int(body[i + 3:j], 16)))
                            i = j + 1
                            continue
                        except ValueError:
                            pass
                else:
                    hexs = body[i + 2:i + 6]
                    try:
                        out.append(chr(int(hexs, 16)))
                        i += 6
                        continue
                    except ValueError:
                        pass
                out.append(nxt)
                i += 2
                continue
            out.append(ESC.get(nxt, nxt))
            i += 2
            continue
        out.append(ch)
        i += 1
    return ''.join(out)


def has_interpolation(lit: str) -> bool:
    # An unescaped $ means Dart interpolation → not a static literal.
    body = lit[1:-1]
    i = 0
    while i < len(body):
        if body[i] == '\\':
            i += 2
            continue
        if body[i] == '$':
            return True
        i += 1
    return False


def joined(run: str):
    parts = []
    for m in RX_ONE.finditer(run):
        lit = m.group(0)
        if has_interpolation(lit):
            return None  # bail: the run isn't a static literal
        parts.append(unescape(lit))
    return ''.join(parts) if parts else None


def collect():
    strings = set()
    for root, _dirs, files in os.walk(LIB):
        for fn in files:
            if not fn.endswith('.dart'):
                continue
            path = os.path.join(root, fn)
            if os.path.abspath(path) == os.path.abspath(OUT):
                continue
            src = open(path, encoding='utf-8').read()
            for rx in (RX_FN, RX_EXT, RX_NAMED):
                for m in rx.finditer(src):
                    s = joined(m.group(1))
                    if s and s.strip():
                        strings.add(s)
    return strings


def dart_literal(s: str) -> str:
    s = s.replace('\\', '\\\\').replace("'", "\\'").replace('$', '\\$')
    s = s.replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t')
    return "'" + s + "'"


def main():
    strings = sorted(collect())
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write("// GENERATED — do not edit by hand.\n")
        f.write("// Regenerate with scripts/gen_i18n_catalog.py after adding or\n")
        f.write("// changing tr(...) UI strings. Lists every static string the app\n")
        f.write("// passes to tr(), so the localizer can pre-translate the whole UI\n")
        f.write("// in the background once a language is chosen (see\n")
        f.write("// LocalizationService.sweep / boot_gate + language_select).\n\n")
        f.write("const List<String> kAppStringsCatalog = <String>[\n")
        for s in strings:
            f.write("  " + dart_literal(s) + ",\n")
        f.write("];\n")
    print(f"wrote {len(strings)} strings to {OUT}")


if __name__ == '__main__':
    main()
