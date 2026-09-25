"""Model-free contracts for the local catalog campaign and diagnostic reports."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('supported_model_eval', Path(__file__).resolve().parents[1] / 'supported_model_eval.py')
eval_cli = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(eval_cli)


class SupportedModelEvalTests(unittest.TestCase):
    def test_catalog_is_exact_and_missing_model_fails_before_execution(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            catalog = root / 'models.swift'
            catalog.write_text('case "a.gguf": return "Nano"\nfilename: "a.gguf"\nfilename: "b.gguf"')
            (root / 'a.gguf').write_bytes(b'GGUF')
            (root / 'unrelated.gguf').write_bytes(b'GGUF')
            with patch.object(eval_cli, 'CATALOG', catalog):
                with self.assertRaisesRegex(ValueError, 'b.gguf'):
                    eval_cli.installed_models(root)
                (root / 'b.gguf').write_bytes(b'GGUF')
                models = eval_cli.installed_models(root)
                self.assertEqual([m['name'] for m in models], ['Nano', 'b.gguf'])
                self.assertEqual([m['bytes'] for m in models], [4, 4])

    def test_accuracy_does_not_hide_suppressed_or_failed_predictions(self):
        def observation(typed, correct, shown, suppression=None, error=None, latency=10):
            return dict(checkpoint=dict(typedCharacters=typed), correct=correct, wasShown=shown,
                        suppression=suppression, error=error, latencyMilliseconds=latency)
        report = dict(phrases=[dict(condition='none', observations=[
            observation(0, True, True), observation(0, False, False, 'committed-typo-gate', latency=0),
            observation(1, False, True), observation(1, False, False, error='decode failure')])])
        metrics = eval_cli.metrics(report)['none']
        self.assertEqual(metrics['nextWordAccuracy'], .5)
        self.assertEqual(metrics['partialWordAccuracy'], 0)
        self.assertEqual(metrics['coverage'], .5)
        self.assertEqual(metrics['precisionWhenShown'], .5)
        self.assertEqual(metrics['errors'], 1)
        self.assertEqual(metrics['suppressions'], {'committed-typo-gate': 1})

    def test_regression_corpus_is_accepted_only_when_explicit_and_rejects_answer_leakage(self):
        import argparse
        spec = importlib.util.spec_from_file_location('phrase_cli', eval_cli.ROOT / 'scripts/phrase_eval.py')
        phrase_cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(phrase_cli)
        args = argparse.Namespace(corpus=eval_cli.REGRESSIONS, category=None, phrase=None, limit=None)
        corpus, phrases = phrase_cli.read_selection(args)
        self.assertEqual(len(phrases), 14)
        self.assertEqual(sum(phrase_cli.checkpoint_counts(phrases, 'character', 'none').values()), 322)
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'leaked.json'
            corpus['phrases'][0]['scenario']['documentPrefix'] = corpus['phrases'][0]['text']
            path.write_text(json.dumps(corpus))
            args.corpus = path
            with self.assertRaisesRegex(ValueError, 'leaked'):
                phrase_cli.read_selection(args)

    def test_validation_selects_disjoint_split_and_keeps_regressions_separate(self):
        screen = dict(eval_cli.workloads('screen'))
        validate = dict(eval_cli.workloads('validate'))
        self.assertIn('screen', screen['word'])
        self.assertIn('heldout', validate['word'])
        self.assertEqual(screen['regressions'], validate['regressions'])
        self.assertIn('character', validate['character'])

    def test_incomplete_campaign_never_looks_complete(self):
        with tempfile.TemporaryDirectory() as root:
            output = Path(root)
            campaign = dict(status='incomplete', runs=[dict(model='Nano', variant='production',
                workload='word', directory='nano-word', status='failed')])
            eval_cli.save(output, campaign)
            self.assertIn('**failed**', (output / 'report.md').read_text())
            self.assertEqual(json.loads((output / 'campaign.json').read_text())['status'], 'incomplete')


if __name__ == '__main__': unittest.main()
