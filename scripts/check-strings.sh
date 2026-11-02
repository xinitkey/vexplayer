#!/bin/bash
# Lists interface strings that have no translation yet. Usage: scripts/check-strings.sh [language, default ru]
# English is the development language: the strings in the source are the keys of
# Resources/Localization/<language>.lproj/Localizable.strings.
set -euo pipefail
cd "$(dirname "$0")/.."

LANG_CODE="${1:-ru}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# The compiler writes every LocalizedStringKey / String(localized:) literal it sees, with the exact
# format specifiers (%@, %lld) the lookup will use.
swift build --product VexPlayer -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null
plutil -convert json -o "$OUT/table.json" "Resources/Localization/$LANG_CODE.lproj/Localizable.strings"

python3 -I - "$OUT" "$PWD/Sources/VexPlayer/" <<'EOF'
import glob, json, os, re, sys
data_dir, src_root = sys.argv[1:3]
known = json.load(open(os.path.join(data_dir, 'table.json')))
missing = {}
for path in glob.glob(os.path.join(data_dir, '*.stringsdata')):
    d = json.load(open(path))
    if src_root not in d.get('source', ''):
        continue
    for e in d['tables'].get('Localizable', []):
        key = e['key']
        # Keys without words (numbers, symbols, format-only) need no translation.
        if key in known or not re.search('[A-Za-z]{2}', re.sub(r'%[@\w.$]+', '', key)):
            continue
        missing.setdefault(key, '%s:%d' % (os.path.relpath(d['source']), e['location']['startingLine']))
for key, where in sorted(missing.items(), key=lambda kv: kv[1]):
    print('%s\t"%s"' % (where, key))
print('%d untranslated' % len(missing), file=sys.stderr)
EOF
