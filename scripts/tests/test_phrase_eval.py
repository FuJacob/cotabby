"""Guard selection and comparison integrity without Xcode or a model."""
import argparse
import contextlib
import copy
import importlib.util
import io
import json
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'phrase_eval.py'
SPEC = importlib.util.spec_from_file_location('phrase_eval', SCRIPT)
eval_cli = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(eval_cli)


class PhraseEvalCLITests(unittest.TestCase):
    def test_baseline_export_preserves_comparison_without_diagnostic_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / 'run'
            source.mkdir()
            report, manifest = self.baseline_run()
            (source / 'report.json').write_text(json.dumps(report))
            (source / 'manifest.json').write_text(json.dumps(manifest))
            (source / 'summary.txt').write_text('Scores\n')
            (source / 'test.log').write_text('local logs')
            args = argparse.Namespace(run=source, name='baseline-v1')
            with mock.patch.object(eval_cli, 'BASELINES', root / 'baselines'), contextlib.redirect_stdout(io.StringIO()):
                eval_cli.save_baseline(args)
                destination = root / 'baselines/baseline-v1'
                saved = json.loads((destination / 'report.json').read_text())
                self.assertEqual(len(eval_cli.comparison_rows(saved, report)), 3)
                self.assertEqual(saved['suite'], report['suite'])
                self.assertEqual(saved['phrases'][0]['nextWord'], report['phrases'][0]['nextWord'])
                self.assertEqual(set(saved['phrases'][0]['observations'][0]), {'checkpoint'})
                self.assertEqual(saved['metadata']['model'], 'test.gguf')
                self.assertEqual({p.name for p in destination.iterdir()}, {'report.json', 'manifest.json', 'summary.txt'})
                with self.assertRaises(FileExistsError):
                    eval_cli.save_baseline(args)

    def test_baseline_export_rejects_invalid_or_incomplete_runs_before_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / 'run'
            source.mkdir()
            report, manifest = self.baseline_run()
            (source / 'manifest.json').write_text(json.dumps(manifest))
            (source / 'summary.txt').write_text('Scores\n')
            invalid = []
            failed = copy.deepcopy(report)
            failed['errorCount'] = 1
            invalid.append(failed)
            missing = copy.deepcopy(report)
            missing['phrases'] = []
            invalid.append(missing)
            partial = copy.deepcopy(report)
            partial['phrases'][0]['observations'].pop()
            invalid.append(partial)
            duplicate = copy.deepcopy(report)
            duplicate['phrases'] *= 2
            invalid.append(duplicate)
            wrong_manifest = copy.deepcopy(report)
            wrong_manifest['metadata']['mode'] = 'character'
            invalid.append(wrong_manifest)
            with mock.patch.object(eval_cli, 'BASELINES', root / 'baselines'):
                for value in invalid:
                    (source / 'report.json').write_text(json.dumps(value))
                    with self.assertRaises(ValueError):
                        eval_cli.save_baseline(argparse.Namespace(run=source, name='invalid'))
                    self.assertFalse((root / 'baselines').exists())
                with self.assertRaises(ValueError):
                    eval_cli.save_baseline(argparse.Namespace(run=source, name='../escape'))

    @classmethod
    def baseline_run(cls):
        report = cls.report()
        report['metadata']['model'] = '/local/models/test.gguf'
        phrase = report['phrases'][0]
        phrase['all'] = {'checkpoints': 2}
        phrase['observations'][0].update({'raw': 'large generated output', 'prompt': 'large prompt'})
        phrase['observations'].append({'checkpoint': {'prefix': 'Water freezes ', 'expectedWord': 'here'}})
        manifest = dict(report['metadata'], startedUTC='20260101T000000Z', label='test', gitCommit='abc123',
                        gitStatus='', phraseIDs=['science-001'], platform='test macOS')
        return report, manifest

    def test_progress_denominator_includes_conditions_and_partial_words(self):
        phrases = [{'category': 'work', 'text': 'Please send the report.'}]
        self.assertEqual(sum(eval_cli.checkpoint_counts(phrases, 'word', 'paired').values()), 6)
        self.assertEqual(sum(eval_cli.checkpoint_counts(phrases, 'character', 'screen').values()), 13)

    def test_progress_tails_complete_records_and_estimates_only_replay_time(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory)
            progress = eval_cli.ReplayProgress(output, 10)
            self.assertIn('0.0%', progress.status())
            self.assertIn('loading model', progress.status())
            metadata = output / 'metadata.json'
            metadata.write_text('{}')
            record = {'phrase': {'id': 'work-001'}, 'condition': 'none', 'observations': [{}, {}]}
            encoded = json.dumps(record).encode()
            journal = output / 'phrases.jsonl'
            journal.write_bytes(encoded[:20])
            with mock.patch.object(eval_cli.time, 'time', return_value=metadata.stat().st_mtime + 4), \
                    mock.patch.object(eval_cli.time, 'monotonic', return_value=100):
                self.assertIn('ETA estimating', progress.status())
                with journal.open('ab') as stream:
                    stream.write(encoded[20:] + b'\n')
                status = progress.status()
                self.assertIn('20.0%', status)
                self.assertIn('ETA 00:00:16', status)
                self.assertEqual(progress.status(), status)  # No double counting on the next poll.
                record['condition'] = 'screen'
                record['observations'] = [{}] * 8
                with journal.open('ab') as stream:
                    stream.write(json.dumps(record).encode() + b'\n')
                self.assertIn('100.0%', progress.status())
                self.assertIn('checking test result', progress.status())

    def test_progress_rejects_duplicate_records(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory)
            record = json.dumps({'phrase': {'id': 'work-001'}, 'condition': 'screen', 'observations': [{}]}) + '\n'
            (output / 'phrases.jsonl').write_text(record * 2)
            with self.assertRaisesRegex(ValueError, 'Duplicate'):
                eval_cli.ReplayProgress(output, 10).status()

    def test_logged_child_streams_progress_and_preserves_log(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory)
            log = output / 'test.log'
            child = '''import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
(p / 'metadata.json').write_text('{}')
(p / 'phrases.jsonl').write_text(json.dumps({'phrase': {'id': 'test'}, 'condition': 'screen', 'observations': [{}]}) + '\\n')
print('native output retained')
'''
            capture = io.StringIO()
            with contextlib.redirect_stdout(capture):
                eval_cli.logged_command([sys.executable, '-c', child, output], log, eval_cli.ReplayProgress(output, 1))
            self.assertIn('0.0%', capture.getvalue())
            self.assertIn('100.0%', capture.getvalue())
            self.assertIn('ETA 00:00:00', capture.getvalue())
            self.assertIn('native output retained', log.read_text())

    def test_logged_child_failure_stays_a_failure(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, 'Command failed \\(3\\)'):
                eval_cli.logged_command([sys.executable, '-c', 'raise SystemExit(3)'], pathlib.Path(directory) / 'test.log')

    def test_corpus_counts_and_filter_order(self):
        args = argparse.Namespace(category=None, phrase=None, limit=None, mode='word')
        _, phrases = eval_cli.read_selection(args)
        self.assertEqual(len(phrases), 1337)
        self.assertEqual(sum(len(eval_cli.WORD.findall(p['text'])) - 1 for p in phrases), 7437)
        self.assertEqual(sum(sum(map(len, eval_cli.WORD.findall(p['text'])[1:])) for p in phrases), 35378)
        args.category, args.limit = 'science', 2
        _, phrases = eval_cli.read_selection(args)
        self.assertEqual([p['id'] for p in phrases], ['science-001', 'science-002'])

    def test_balanced_scenario_selection_and_distinct_screen_inputs(self):
        args = argparse.Namespace(category=None, phrase=None, limit=None, per_category=2)
        _, phrases = eval_cli.read_selection(args)
        self.assertEqual(len(phrases), 14)
        self.assertEqual(len({p['scenario']['screenText'] for p in phrases}), 14)
        self.assertTrue(all(p['scenario']['screenText'] for p in phrases))
        args.per_category = 0
        with self.assertRaises(ValueError):
            eval_cli.read_selection(args)

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
        for field, value in [('mode', 'character'), ('corpusSHA256', 'other'), ('seed', 43), ('contextMode', 'paired')]:
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
        after['errorCount'] = 1
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
            'schemaVersion': 2, 'errorCount': 0,
            'metadata': {'corpusSHA256': 'abc', 'mode': 'word', 'seed': 42, 'contextMode': 'none', 'model': 'test.gguf', 'configuration': {}},
            'suite': {'nextWord': dict(metrics), 'all': dict(metrics)},
            'categories': {'science': {'nextWord': dict(metrics)}},
            'conditions': {'none': {'suite': {'nextWord': dict(metrics)}, 'categories': {'science': {'nextWord': dict(metrics)}}}},
            'meanCategoryNextWordAccuracy': 0.5,
            'phrases': [{'phrase': {'id': 'science-001', 'category': 'science', 'text': 'Water freezes here.'},
                         'condition': 'none', 'observations': [{'checkpoint': {'prefix': 'Water ', 'expectedWord': 'freezes'}}],
                         'nextWord': dict(metrics)}],
        }


if __name__ == '__main__':
    unittest.main()
