#!/usr/bin/env python3
"""Checks the English table against the code: python3 Sources/Localization/check.py

Lists Russian text in the code that has no English entry, entries no code uses, and Russian text glued to
more text inside Text(…) (SwiftUI shows such a String as it is). Exit status 1 when something is missing.
Keys are the Russian source text; interpolations are compared without their type (%@, %lld, %d, %lf).
"""
import glob, json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CYRILLIC = re.compile('[А-Яа-яЁёІіЇїЄєҐґ«]')
# Literal titles SwiftUI looks up itself, and L(…).
LOOKED_UP = re.compile(r'(\b(Text|Button|Toggle|Label|Section|LabeledContent|Picker|TextField|SecureField|Link|Menu|'
                       r'Stepper|DisclosureGroup|ProgressView|GroupBox|ControlGroup)\(|\.(help|navigationTitle|'
                       r'accessibilityLabel|accessibilityHint)\(|\bL\(|SoundPicker\(title:|Settings(Toggle|Picker|Row|Group)\(|'
                       r'WarningLine\(text:|PairsSection\(title:|\b(subtitle|footer):)\s*$')
PLURAL = re.compile(r'\bcount\([^()]*,\s*$|\bcount\([^()]*,\s*"[^"]*",\s*$|\bcount\([^()]*,\s*"[^"]*",\s*"[^"]*",\s*$')
SPEC = re.compile(r'%(?:lld|ld|d|lf|@)')


def literals(src):
    """(start, end, line, text) of every string literal; interpolations stay as \\(…)."""
    i, n, line = 0, len(src), 1
    while i < n:
        c = src[i]
        if c == '\n':
            line += 1; i += 1; continue
        if src.startswith('//', i):
            j = src.find('\n', i); i = n if j < 0 else j; continue
        if src.startswith('/*', i):
            j = src.find('*/', i); line += src[i:j].count('\n'); i = j + 2; continue
        if c != '"':
            i += 1; continue
        start, first = i, line
        multi = src.startswith('"""', i)
        i += 3 if multi else 1
        body = []
        while i < n:
            if src.startswith('\\(', i):
                depth, j = 1, i + 2
                while j < n and depth:
                    if src[j] == '"':
                        k = j + 1
                        while k < n and src[k] != '"':
                            k += 2 if src[k] == '\\' else 1
                        j = k + 1; continue
                    depth += {'(': 1, ')': -1}.get(src[j], 0)
                    j += 1
                body.append(src[i:j]); i = j; continue
            if src[i] == '\\':
                body.append(src[i:i + 2]); i += 2; continue
            if src.startswith('"""' if multi else '"', i):
                i += 3 if multi else 1; break
            line += src[i] == '\n'
            body.append(src[i]); i += 1
        yield start, i, first, ''.join(body)


def key(text):
    """The lookup key with \\x00 for each interpolation, and Swift escapes resolved."""
    out, i, has = [], 0, '\\(' in text
    while i < len(text):
        if text.startswith('\\(', i):
            depth, j = 1, i + 2
            while depth:
                depth += {'(': 1, ')': -1}.get(text[j], 0); j += 1
            out.append('\x00'); i = j; continue
        if text[i] == '\\':
            nxt = text[i + 1]
            if nxt == 'u':
                end = text.index('}', i); out.append(chr(int(text[i + 3:end], 16))); i = end + 1; continue
            out.append({'n': '\n', 't': '\t', '"': '"', '\\': '\\', "'": "'", '0': '\0'}[nxt]); i += 2; continue
        out.append('%%' if has and text[i] == '%' else text[i]); i += 1
    return ''.join(out)


def main():
    table = os.path.join(ROOT, 'Sources/Localization/en.lproj/Localizable.strings')
    english = json.loads(subprocess.run(['plutil', '-convert', 'json', '-o', '-', table],
                                        capture_output=True, check=True).stdout)
    known = {SPEC.sub('\x00', k): k for k in english}
    used, missing, glued = set(), [], []
    for path in sorted(glob.glob(os.path.join(ROOT, 'Sources/*.swift'))):
        src, name = open(path, encoding='utf-8').read(), os.path.basename(path)
        for start, end, line, text in literals(src):
            if not CYRILLIC.search(text):
                continue
            before = src[max(0, start - 100):start].split('\n')[-1].rstrip()
            if not (LOOKED_UP.search(before) or PLURAL.search(before)):
                continue
            if LOOKED_UP.search(before) and not before.endswith('L(') and re.match(r'\s*\+', src[end:end + 200]):
                glued.append(f'{name}:{line}  {text[:70]}')
            k = key(text)
            if k in known:
                used.add(known[k])
            else:
                missing.append(f'{name}:{line}  {k.replace(chr(0), "%@")[:90]}')
    for title, rows in (('No English for', missing), ('Glued to more text inside Text(…), wrap in L(…)', glued),
                        ('Unused entries', sorted(set(english) - used))):
        if rows:
            print(f'{title} ({len(rows)}):')
            for row in rows:
                print('  ' + row)
    print(f'{len(english)} entries, {len(used)} used, {len(missing)} missing.')
    return 1 if missing or glued else 0


if __name__ == '__main__':
    sys.exit(main())
