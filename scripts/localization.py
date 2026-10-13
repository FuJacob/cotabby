#!/usr/bin/env python3
"""Export translator jobs, merge isolated language JSON, and validate String Catalogs.

The compiler owns source keys and interpolation types. Translators own only values;
this tool checks their payload before changing any catalog so parallel jobs cannot
overwrite each other's language or silently change a format argument.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re

LANGUAGES = ('en', 'zh-Hans', 'zh-Hant', 'ja', 'ko', 'fr', 'de', 'es', 'pt-BR',
             'it', 'ru', 'ar', 'hi', 'id', 'tr')
PLURAL_FORMS = {
    'en': ('one', 'other'), 'zh-Hans': ('other',), 'zh-Hant': ('other',),
    'ja': ('other',), 'ko': ('other',), 'id': ('other',),
    'fr': ('one', 'many', 'other'), 'es': ('one', 'many', 'other'),
    'pt-BR': ('one', 'many', 'other'), 'it': ('one', 'many', 'other'),
    'de': ('one', 'other'), 'hi': ('one', 'other'), 'tr': ('one', 'other'),
    'ru': ('one', 'few', 'many', 'other'),
    'ar': ('zero', 'one', 'two', 'few', 'many', 'other'),
}
FORMAT = re.compile(r'%(?:(\d+)\$)?[-+#0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|ll|h|l|L|z|j|t)?([@diuoxXfFeEgGaAcCsSp])')


def read_json(path):
    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate JSON key: ' + key)
            result[key] = value
        return result
    return json.loads(Path(path).read_text(encoding='utf-8'), object_pairs_hook=unique_pairs)


def write_json(path, value):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n', encoding='utf-8')


def placeholders(value):
    # Escaped percent signs are literals. Positional indices may reorder arguments,
    # but an index must still identify the same source argument and its ABI type.
    value = value.replace('%%', '')
    return [(int(m.group(1)) if m.group(1) else None, (m.group(2) or '') + m.group(3))
            for m in FORMAT.finditer(value)]


def check_value(source, value):
    if not isinstance(value, str) or not value.strip():
        raise ValueError('Translation must be a nonempty string: ' + source)
    expected = placeholders(source)
    received = placeholders(value)
    if Counter(t for _, t in expected) != Counter(t for _, t in received):
        raise ValueError('Format arguments differ: ' + source)
    positions = [p for p, _ in received if p is not None]
    if positions:
        if len(positions) != len(received) or sorted(positions) != list(range(1, len(expected) + 1)):
            raise ValueError('Use unique positional indices for every argument: ' + source)
        for position, kind in received:
            if expected[position - 1][1] != kind:
                raise ValueError('Positional argument type differs: ' + source)
    elif [t for _, t in expected] != [t for _, t in received]:
        raise ValueError('Reordered argument types require positional indices: ' + source)
    if source.count('¦') != value.count('¦'):
        raise ValueError('Preserve the preview boundary marker ¦: ' + source)
    if source.count('\n') != value.count('\n'):
        raise ValueError('Preserve line breaks: ' + source)
    if source.count('%%') != value.count('%%'):
        raise ValueError('Preserve escaped literal percent signs: ' + source)


def translatable(catalog):
    return {k: v for k, v in catalog['strings'].items()
            if v.get('shouldTranslate', True) and v.get('extractionState') != 'stale'}


def english_forms(key, entry):
    plural = entry.get('localizations', {}).get('en', {}).get('variations', {}).get('plural')
    return {form: node['stringUnit']['value'] for form, node in plural.items()} if plural else None


def export_catalogs(catalogs):
    return {path.stem: {key: dict(source=key, comment=entry.get('comment', ''),
                                 **({'plural': english_forms(key, entry)} if english_forms(key, entry) else {}))
                        for key, entry in sorted(translatable(catalog).items())}
            for path, catalog in catalogs}


def unit(value):
    return {'stringUnit': {'state': 'translated', 'value': value}}


def merge(catalogs, language, payload):
    if language not in LANGUAGES or language == 'en':
        raise ValueError('Choose a supported translation language other than en')
    if set(payload) != {p.stem for p, _ in catalogs}:
        raise ValueError('Translation tables differ from selected catalogs')
    # Validate the entire job before writing, so a malformed late entry cannot
    # leave a half-imported language in the earlier catalog.
    changes = []
    for path, catalog in catalogs:
        expected = translatable(catalog)
        translated = payload[path.stem]
        if set(expected) != set(translated):
            missing = set(expected) - set(translated)
            extra = set(translated) - set(expected)
            raise ValueError(f'{path.stem}: missing {len(missing)} keys, extra {len(extra)} keys')
        for key, entry in expected.items():
            value = translated[key]
            if english_forms(key, entry):
                if not isinstance(value, dict) or set(value) != set(PLURAL_FORMS[language]):
                    raise ValueError('Incorrect plural forms: ' + key)
                for text in value.values():
                    check_value(key, text)
                localization = {'variations': {'plural': {f: unit(v) for f, v in value.items()}}}
            else:
                check_value(key, value)
                localization = unit(value)
            changes.append((entry, localization))
    for entry, localization in changes:
        entry.setdefault('localizations', {})[language] = localization
    for path, catalog in catalogs:
        write_json(path, catalog)


def validate(catalogs):
    errors = []
    total = 0
    for path, catalog in catalogs:
        if catalog.get('sourceLanguage') != 'en':
            errors.append(f'{path}: sourceLanguage must be en')
        for key, entry in translatable(catalog).items():
            total += 1
            for language in LANGUAGES[1:]:
                try:
                    node = entry.get('localizations', {}).get(language)
                    if node is None:
                        raise ValueError(f'missing {language}')
                    if english_forms(key, entry):
                        variants = node.get('variations', {}).get('plural', {})
                        if set(variants) != set(PLURAL_FORMS[language]):
                            raise ValueError('incorrect plural variants')
                        nodes = variants.values()
                    else:
                        nodes = [node]
                    for item in nodes:
                        string_unit = item['stringUnit']
                        if string_unit['state'] != 'translated':
                            raise ValueError('translation not complete')
                        check_value(key, string_unit['value'])
                except (ValueError, KeyError) as error:
                    errors.append(f'{path.stem}/{language}/{key}: {error}')
    if errors:
        raise ValueError('\n'.join(errors[:30]) + f'\n{len(errors)} validation errors')
    print(f'Validated {total} source keys across {len(catalogs)} tables and {len(LANGUAGES)} languages.')


def sync_regions(catalogs, project):
    """Bridge XcodeGen's region discovery until it reads xcstrings language entries.

    XcodeGen discovers traditional lproj folders, but our source catalogs compile
    into those folders only at build time. Its supported post-generation hook
    keeps PBXProject metadata reproducible without dummy localization resources.
    """
    regions = {'Base'}
    for _, catalog in catalogs:
        regions.add(catalog['sourceLanguage'])
        for entry in catalog['strings'].values():
            regions.update(entry.get('localizations', {}))
    text = project.read_text(encoding='utf-8')
    pattern = re.compile(r'(?m)^(\s+)knownRegions = \([\s\S]*?^\s+\);')
    def replacement(match):
        indent = match.group(1)
        values = [json.dumps(region) if '-' in region else region for region in sorted(regions)]
        return indent + 'knownRegions = (\n' + ''.join(indent + '\t' + value + ',\n' for value in values) + indent + ');'
    updated, count = pattern.subn(replacement, text)
    if count != 1:
        raise ValueError('Expected exactly one PBXProject knownRegions block')
    project.write_text(updated, encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog', action='append', help='Catalog path; repeat to select multiple tables')
    commands = parser.add_subparsers(dest='command', required=True)
    export = commands.add_parser('export')
    export.add_argument('--output', required=True)
    importer = commands.add_parser('merge')
    importer.add_argument('--language', required=True)
    importer.add_argument('--input', required=True)
    commands.add_parser('validate')
    commands.add_parser('sync-regions')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    paths = [Path(p) for p in args.catalog] if args.catalog else sorted((root / 'Cotabby/Resources').glob('*.xcstrings'))
    catalogs = [(p, read_json(p)) for p in paths]
    if not catalogs:
        parser.error('No String Catalogs found')
    try:
        if args.command == 'export':
            write_json(args.output, export_catalogs(catalogs))
        elif args.command == 'merge':
            merge(catalogs, args.language, read_json(args.input))
        elif args.command == 'sync-regions':
            sync_regions(catalogs, root / 'Cotabby.xcodeproj/project.pbxproj')
        else:
            validate(catalogs)
    except (ValueError, KeyError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
