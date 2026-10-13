"""Protect translator import boundaries against dropped or mistyped format arguments."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('localization', Path(__file__).parents[1] / 'localization.py')
localization = importlib.util.module_from_spec(spec)
spec.loader.exec_module(localization)


class LocalizationTests(unittest.TestCase):
    def test_reordering_uses_the_correct_argument_types(self):
        localization.check_value('%@ has %lld entries', '%2$lld Einträge für %1$@')
        for bad in ('%@ entries', '%lld has %@ entries', '%1$lld %2$@', '%1$@ %1$lld'):
            with self.assertRaises(ValueError):
                localization.check_value('%@ has %lld entries', bad)

    def test_literal_percent_and_preview_boundary(self):
        localization.check_value('Downloading %lld%%', 'Téléchargement : %lld%%')
        localization.check_value('Hello¦ world\nAgain', 'Bonjour¦ monde\nEncore')
        with self.assertRaises(ValueError):
            localization.check_value('Hello¦ world', 'Bonjour monde')
        with self.assertRaises(ValueError):
            localization.check_value('Downloading %lld%%', 'Téléchargement : %lld%')
        localization.check_value('CPU can exceed 100% across multiple cores.',
                                 'Die CPU kann über mehrere Kerne 100% überschreiten.')

    def test_duplicate_json_keys_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'job.json'
            path.write_text('{"Hello":"Bonjour","Hello":"Salut"}')
            with self.assertRaises(ValueError):
                localization.read_json(path)

    def test_invalid_job_never_partially_changes_catalog(self):
        catalog = {'sourceLanguage': 'en', 'strings': {'Hello': {}, '%lld entries': {}}, 'version': '1.0'}
        before = json.dumps(catalog)
        with self.assertRaises(ValueError):
            localization.merge([(Path('Localizable.xcstrings'), catalog)], 'fr',
                               {'Localizable': {'Hello': 'Bonjour', '%lld entries': 'Entrées'}})
        self.assertEqual(before, json.dumps(catalog))

    def test_generated_project_regions_include_languages_from_every_table(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / 'project.pbxproj'
            project.write_text('header\n\tknownRegions = (\n\t\ten,\n\t);\nfooter\n')
            catalogs = [(Path('Localizable.xcstrings'), {'sourceLanguage': 'en', 'strings': {
                'Hello': {'localizations': {'ja': {}, 'zh-Hans': {}}}}}),
                (Path('Learning.xcstrings'), {'sourceLanguage': 'en', 'strings': {
                    'Learn': {'localizations': {'ar': {}}}}})]
            localization.sync_regions(catalogs, project)
            result = project.read_text()
            self.assertTrue(result.startswith('header\n'))
            self.assertTrue(result.endswith('footer\n'))
            for name in ('Base', 'en', 'ja', 'ar', '"zh-Hans"'):
                self.assertIn('\t\t' + name + ',', result)
            localization.sync_regions(catalogs, project)
            self.assertEqual(result, project.read_text())


if __name__ == '__main__':
    unittest.main()
