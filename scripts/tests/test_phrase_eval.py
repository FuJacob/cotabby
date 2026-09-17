"""Guard selection and comparison integrity without Xcode or a model."""
import argparse
import contextlib
import copy
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'phrase_eval.py'
SPEC = importlib.util.spec_from_file_location('phrase_eval', SCRIPT)
eval_cli = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(eval_cli)


class PhraseEvalCLITests(unittest.TestCase):
    def test_corpus_counts_and_filter_order(self):
        args = argparse.Namespace(category=None, phrase=None, limit=None, mode='word')
        _, phrases = eval_cli.read_selection(args)
        self.assertEqual(len(phrases), 1337)
        self.assertEqual(sum(len(eval_cli.WORD.findall(p['text'])) - 1 for p in phrases), 7437)
        self.assertEqual(sum(sum(map(len, eval_cli.WORD.findall(p['text'])[1:])) for p in phrases), 35378)
        args.category, args.limit = 'science', 2
        _, phrases = eval_cli.read_selection(args)
        self.assertEqual([p['id'] for p in phrases], ['science-001', 'science-002'])

    def test_invalid_selection_does_not_run_a_different_suite(self):
        for phrase, limit in [('nonexistent', None), (None, 0), (None, -1)]:
            args = argparse.Namespace(category=None, phrase=phrase, limit=limit)
            with self.assertRaises(ValueError):
                eval_cli.read_selection(args)

    def test_environment_injection_preserves_existing_values_and_other_targets(self):
        target = {'TestBundlePath': '__TESTROOT__/CotabbyTests.xctest', 'EnvironmentVariables': {'EXISTING': 'yes'}}
        other = {'TestBundlePath': '__TESTROOT__/OtherTests.xctest'}
        for document in [{'CotabbyTests': copy.deepcopy(target), 'Other': copy.deepcopy(other)},
                         {'TestConfigurations': [{'TestTargets': [copy.deepcopy(target), copy.deepcopy(other)]}]}]:
            self.assertEqual(eval_cli.inject_environment(document, {'COTABBY_PHRASE_EVAL': '1'}), 1)
            encoded = json.dumps(document)
            self.assertIn('EXISTING', encoded)
            self.assertEqual(encoded.count('COTABBY_PHRASE_EVAL'), 1)

    def test_comparison_accepts_tuning_but_rejects_different_inputs(self):
        before = self.report()
        after = copy.deepcopy(before)
        after['metadata']['model'] = 'another.gguf'
        after['metadata']['configuration'] = {'temperature': '0.2'}
        self.assertEqual(len(eval_cli.comparison_rows(before, after)), 3)
        for field, value in [('mode', 'character'), ('corpusSHA256', 'other'), ('seed', 43)]:
            after = copy.deepcopy(before)
            after['metadata'][field] = value
            with self.assertRaisesRegex(ValueError, field):
                eval_cli.comparison_rows(before, after)
        after = copy.deepcopy(before)
        after['phrases'][0]['observations'][0]['checkpoint']['prefix'] = 'Different '
        with self.assertRaisesRegex(ValueError, 'checkpoint'):
            eval_cli.comparison_rows(before, after)

    def test_comparison_rejects_partial_or_errored_runs(self):
        before = self.report()
        after = copy.deepcopy(before)
        after['phrases'] = []
        with self.assertRaises(ValueError):
            eval_cli.comparison_rows(before, after)
        after = copy.deepcopy(before)
        after['suite']['all']['errors'] = 1
        with self.assertRaisesRegex(ValueError, 'errors'):
            eval_cli.comparison_rows(before, after)

    def test_comparison_prints_missing_precision_as_unavailable(self):
        report = self.report()
        report['suite']['nextWord'].pop('precisionWhenShown', None)
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'report.json'
            path.write_text(json.dumps(report))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                eval_cli.compare(argparse.Namespace(before=path, after=path))
            self.assertIn('Precision when shown: n/a -> n/a', output.getvalue())

    @staticmethod
    def report():
        metrics = {'accuracy': 0.5, 'coverage': 1, 'precisionWhenShown': 0.5, 'errors': 0}
        return {
            'schemaVersion': 1,
            'metadata': {'corpusSHA256': 'abc', 'mode': 'word', 'seed': 42, 'model': 'test.gguf', 'configuration': {}},
            'suite': {'nextWord': dict(metrics), 'all': dict(metrics)},
            'categories': {'science': {'nextWord': dict(metrics)}},
            'meanCategoryNextWordAccuracy': 0.5,
            'phrases': [{'phrase': {'id': 'science-001', 'category': 'science', 'text': 'Water freezes here.'},
                         'observations': [{'checkpoint': {'prefix': 'Water ', 'expectedWord': 'freezes'}}],
                         'nextWord': dict(metrics)}],
        }


if __name__ == '__main__':
    unittest.main()
