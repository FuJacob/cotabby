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
    @contextlib.contextmanager
    def resolution_fixture(self):
        """A tiny app/native workspace with filesystem changes and a stubbed Git file listing."""
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            paths = ['Cotabby/app.swift', 'CotabbyTests/test.swift', 'Config/Signing.local.xcconfig', 'CotabbyInfo.plist',
                     'native/Package.swift', 'native/source.cpp']
            for name in paths:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(name)
            workspace = root / 'dev.xcworkspace'
            workspace.mkdir()
            (workspace / 'contents.xcworkspacedata').write_text(
                f'<Workspace><FileRef location="absolute:{root / "native"}" /></Workspace>')
            output = root / 'output'
            output.mkdir()
            def names(command, cwd):
                return ('\0'.join(paths[:4] if cwd == root else ['Package.swift', 'source.cpp']) + '\0').encode()
            with mock.patch.object(eval_cli, 'ROOT', root), mock.patch.object(eval_cli, 'DERIVED', root / 'build/DerivedData'), \
                    mock.patch.object(eval_cli.subprocess, 'check_output', side_effect=names):
                yield root, workspace, output

    def test_resolution_accepts_only_generated_or_updated_canonical_locks(self):
        for initial_lock in (None, 'old pins'):
            with self.subTest(initial_lock=initial_lock), self.resolution_fixture() as (root, workspace, output):
                lock = workspace / 'xcshareddata/swiftpm/Package.resolved'
                lock.parent.mkdir(parents=True)
                if initial_lock:
                    lock.write_text(initial_lock)
                before = eval_cli.build_input_snapshot(workspace)
                def resolve(command, log):
                    self.assertIn('-resolvePackageDependencies', command)
                    self.assertEqual(command[command.index('-derivedDataPath') + 1], root / 'build/DerivedData')
                    self.assertEqual(log, output / 'resolution.log')
                    lock.write_text('resolved pins')
                    log.write_text('Resolved source packages')
                with mock.patch.object(eval_cli, 'logged_command', side_effect=resolve):
                    after = eval_cli.prepare_build_inputs(workspace, ['-workspace', workspace], output, skip_build=False)
                self.assertNotEqual(before['sourceSHA256'], after['sourceSHA256'])
                self.assertEqual(before['nonLockSourceSHA256'], after['nonLockSourceSHA256'])
                evidence = json.loads((output / 'resolution-inputs.json').read_text())
                self.assertEqual(evidence, {'before': before, 'after': after, 'status': 'resolved'})
                self.assertEqual(after['sourceSHA256'], eval_cli.build_input_fingerprint(workspace))
                # Lock-only changes are tolerated during resolution, but still invalidate a build.
                lock.write_text('changed after resolution')
                self.assertNotEqual(after['sourceSHA256'], eval_cli.build_input_fingerprint(workspace))

    def test_resolution_rejects_app_test_native_and_config_changes(self):
        for name in ('Cotabby/app.swift', 'CotabbyTests/test.swift', 'native/source.cpp', 'native/Package.swift',
                     'Config/Signing.local.xcconfig', 'CotabbyInfo.plist', 'dev.xcworkspace/contents.xcworkspacedata'):
            with self.subTest(name=name), self.resolution_fixture() as (root, workspace, output):
                def resolve(command, log):
                    with (root / name).open('a') as stream:
                        stream.write('\n<!-- changed -->' if name.endswith('xcworkspacedata') else '\nchanged')
                with mock.patch.object(eval_cli, 'logged_command', side_effect=resolve), \
                        self.assertRaisesRegex(RuntimeError, 'changed during dependency resolution'):
                    eval_cli.prepare_build_inputs(workspace, ['-workspace', workspace], output, skip_build=False)
                self.assertEqual(json.loads((output / 'resolution-inputs.json').read_text())['status'], 'rejected-source-change')

    def test_skip_build_never_resolves_or_changes_dependencies(self):
        with self.resolution_fixture() as (_, workspace, output), mock.patch.object(eval_cli, 'logged_command') as command:
            before = eval_cli.build_input_snapshot(workspace)
            self.assertEqual(eval_cli.prepare_build_inputs(workspace, ['-workspace', workspace], output, skip_build=True), before)
            command.assert_not_called()
            self.assertFalse((output / 'resolution-inputs.json').exists())

    def test_failed_resolution_keeps_evidence_and_does_not_return_compilation_inputs(self):
        with self.resolution_fixture() as (_, workspace, output), \
                mock.patch.object(eval_cli, 'logged_command', side_effect=RuntimeError('resolver failed')):
            with self.assertRaisesRegex(RuntimeError, 'resolver failed'):
                eval_cli.prepare_build_inputs(workspace, ['-workspace', workspace], output, skip_build=False)
            record = json.loads((output / 'resolution-inputs.json').read_text())
            self.assertEqual(record['status'], 'failed')
            self.assertNotIn('after', record)

    def test_failed_post_resolution_snapshot_is_recorded_instead_of_left_resolving(self):
        with self.resolution_fixture() as (_, workspace, output):
            before = eval_cli.build_input_snapshot(workspace)
            def resolve(command, log):
                log.write_text('Resolver exited successfully')
                (workspace / 'contents.xcworkspacedata').write_text('<Workspace>')
            with mock.patch.object(eval_cli, 'logged_command', side_effect=resolve), \
                    self.assertRaises(eval_cli.ET.ParseError):
                eval_cli.prepare_build_inputs(workspace, ['-workspace', workspace], output, skip_build=False)
            record = json.loads((output / 'resolution-inputs.json').read_text())
            self.assertEqual(record['status'], 'failed')
            self.assertEqual(record['before'], before)
            self.assertEqual(record['error']['type'], 'ParseError')
            self.assertTrue(record['error']['message'])
            self.assertNotIn('after', record)

    def test_lock_named_fixture_is_not_exempt_from_source_guard(self):
        with self.resolution_fixture() as (root, workspace, _):
            fixture = root / 'CotabbyTests/Package.resolved'
            fixture.write_text('fixture content')
            def names(command, cwd):
                return b'CotabbyTests/Package.resolved\0' if cwd == root else b'Package.swift\0source.cpp\0'
            with mock.patch.object(eval_cli.subprocess, 'check_output', side_effect=names):
                before = eval_cli.build_input_snapshot(workspace)
                fixture.write_text('edited fixture')
                after = eval_cli.build_input_snapshot(workspace)
                self.assertNotEqual(before['nonLockSourceSHA256'], after['nonLockSourceSHA256'])

    def test_run_records_resolved_inputs_and_still_rejects_changes_during_compilation(self):
        for mutate_build_input in (None, 'source', 'lock'):
            with self.subTest(mutate_build_input=mutate_build_input), self.resolution_fixture() as (root, workspace, _):
                args = argparse.Namespace(mode='word', context='none', workers=1, model=None, workspace=workspace,
                    output=root / 'run', label='test', split='all', split_seed=1337, screen_per_category=20,
                    per_category=None, category=None, phrase=None, limit=None, skip_build=False)
                phrase = {'id': 'science-001', 'category': 'science', 'text': 'Water freezes here.'}
                corpus = root / 'corpus.json'
                corpus.write_text(json.dumps({'phrases': [phrase]}))
                lock = workspace / 'xcshareddata/swiftpm/Package.resolved'
                calls = []
                def command(arguments, log, progress=None):
                    calls.append(arguments[1])
                    log.write_text('Synthetic successful tool output')
                    if arguments[1] == '-resolvePackageDependencies':
                        lock.parent.mkdir(parents=True)
                        lock.write_text('resolved pins')
                    elif arguments[1] == 'build-for-testing':
                        products = eval_cli.DERIVED / 'Build/Products'
                        binary = products / 'Release/Cotabby.app/Contents/MacOS/Cotabby'
                        binary.parent.mkdir(parents=True)
                        binary.write_bytes(b'built app')
                        (products / 'Cotabby_test.xctestrun').write_bytes(eval_cli.plistlib.dumps(
                            {'TestBundlePath': '__TESTHOST__/Contents/PlugIns/CotabbyTests.xctest',
                             'TestHostPath': '__TESTROOT__/Release/Cotabby.app'}))
                        if mutate_build_input:
                            path = root / 'Cotabby/app.swift' if mutate_build_input == 'source' else lock
                            path.write_text('changed during compilation')
                    else:
                        self.assertEqual(arguments[1], 'test-without-building')
                        (args.output / 'report.json').write_text(json.dumps({'metadata': {'workerCount': 1},
                            'phrases': [{'phrase': phrase, 'condition': 'none'}], 'errorCount': 0}))
                        (args.output / 'summary.txt').write_text('Synthetic summary')
                def git_output(*arguments):
                    return ('resolved' if lock.exists() else 'initial') + (' patch' if arguments[0] == 'diff' else '')
                with mock.patch.object(eval_cli, 'CORPUS', corpus), mock.patch.object(eval_cli, 'show_plan', return_value=[phrase]), \
                        mock.patch.object(eval_cli.platform, 'system', return_value='Darwin'), \
                        mock.patch.object(eval_cli.platform, 'platform', return_value='Synthetic macOS'), \
                        mock.patch.object(eval_cli, 'git_output', side_effect=git_output), \
                        mock.patch.object(eval_cli, 'logged_command', side_effect=command), \
                        mock.patch.object(eval_cli, 'sign_test_hosts', return_value=contextlib.nullcontext(root / 'staged/Cotabby.app')), contextlib.redirect_stdout(io.StringIO()):
                    if mutate_build_input:
                        with self.assertRaisesRegex(RuntimeError, 'Source inputs changed during build setup'):
                            eval_cli.run(args)
                        self.assertNotIn('test-without-building', calls)
                        self.assertFalse((eval_cli.DERIVED / 'phrase-eval-build.json').exists())
                    else:
                        eval_cli.run(args)
                        manifest = json.loads((args.output / 'manifest.json').read_text())
                        self.assertEqual(manifest['gitAtStart']['gitCommit'], 'initial')
                        self.assertEqual(manifest['gitCommit'], 'resolved')
                        self.assertEqual((args.output / 'working-tree.patch').read_text(), 'resolved patch')
                        self.assertEqual(manifest['buildInputs']['sourceSHA256'], manifest['build']['sourceSHA256'])
                        self.assertEqual(manifest['build']['sourceSHA256'], eval_cli.build_input_fingerprint(workspace))
                        self.assertEqual(calls, ['-resolvePackageDependencies', 'build-for-testing', 'test-without-building'])

    def test_staging_retargets_library_search_paths_as_well_as_host(self):
        host = pathlib.Path('/private/tmp/example/Cotabby.app')
        target = {'TestHostPath': '__TESTROOT__/Release/Cotabby.app',
            'TestBundlePath': '__TESTHOST__/Contents/PlugIns/CotabbyTests.xctest',
            'DependentProductPaths': ['__TESTROOT__/Release/Cotabby.app'],
            'TestingEnvironmentVariables': {
                'DYLD_FRAMEWORK_PATH': '__TESTROOT__/Release:__TESTROOT__/Release/PackageFrameworks:__PLATFORMS__/Developer/Frameworks',
                '__XPC_DYLD_LIBRARY_PATH': '__TESTROOT__/Release',
                '__XCODE_BUILT_PRODUCTS_DIR_PATHS': '__TESTROOT__/Release'}}
        value = {'TestConfigurations': [{'TestTargets': [target]}]}
        self.assertEqual(eval_cli.retarget_test_host(value, host), 1)
        self.assertEqual(target['TestHostPath'], str(host))
        self.assertEqual(target['TestBundlePath'], '__TESTHOST__/Contents/PlugIns/CotabbyTests.xctest')
        for item in target['TestingEnvironmentVariables'].values():
            self.assertNotIn('__TESTROOT__/Release', item)
        self.assertIn('__PLATFORMS__/Developer/Frameworks', target['TestingEnvironmentVariables']['DYLD_FRAMEWORK_PATH'])

    def test_runtime_checks_require_an_explicit_model_before_any_build(self):
        with self.assertRaisesRegex(ValueError, 'requires --model'):
            eval_cli.run(argparse.Namespace(runtime_checks=True, model=None))

    def test_test_host_signing_is_local_adhoc_and_verified(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            host = root / 'products/Release/Cotabby.app'
            host.mkdir(parents=True)
            output = root / 'output'
            output.mkdir()
            with mock.patch.object(eval_cli, 'logged_command') as command, mock.patch.object(eval_cli.subprocess, 'run') as cleanup:
                with eval_cli.sign_test_hosts(root / 'products', output) as signed:
                    self.assertNotEqual(signed, host)
            calls = [item.args[0] for item in command.call_args_list]
            self.assertEqual(calls[2][calls[2].index('--sign') + 1], '-')
            self.assertEqual(calls[-1], ['codesign', '--verify', '--deep', '--strict', signed])
            self.assertFalse(signed.parent.exists(), 'staged bundles must not accumulate')
            self.assertEqual(cleanup.call_args.args[0][:3], ['pkill', '-TERM', '-f'])
            pattern = cleanup.call_args.args[0][3]
            self.assertIsNotNone(eval_cli.re.search(pattern, str(signed / 'Contents/MacOS/Cotabby') + ' -cotabby-debug'))
            self.assertIsNone(eval_cli.re.search(pattern, '/Applications/Cotabby.app/Contents/MacOS/Cotabby'))
            entitlements = eval_cli.plistlib.loads((output / 'test-host.entitlements').read_bytes())
            self.assertTrue(entitlements['com.apple.security.get-task-allow'])
            self.assertTrue(entitlements['com.apple.security.cs.disable-library-validation'])

    def test_hash_partitions_are_balanced_disjoint_and_result_independent(self):
        args = argparse.Namespace(category=None, phrase=None, limit=None, split='screen', split_seed=1337,
                                  screen_per_category=20, per_category=None)
        corpus, screen = eval_cli.read_selection(args)
        args.split = 'heldout'
        _, heldout = eval_cli.read_selection(args)
        screen_ids, heldout_ids = {p['id'] for p in screen}, {p['id'] for p in heldout}
        self.assertEqual(len(screen_ids), 140)
        self.assertEqual(len(heldout_ids), 1197)
        self.assertFalse(screen_ids & heldout_ids)
        self.assertEqual(screen_ids | heldout_ids, {p['id'] for p in corpus['phrases']})
        self.assertEqual(eval_cli.collections.Counter(p['category'] for p in screen), dict.fromkeys(eval_cli.CATEGORIES, 20))
        args.split = 'screen'
        self.assertEqual({p['id'] for p in eval_cli.partition_phrases(list(reversed(corpus['phrases'])), args)}, screen_ids)
        args.split_seed = 1338
        self.assertNotEqual({p['id'] for p in eval_cli.read_selection(args)[1]}, screen_ids)

    def test_partition_caps_use_hash_order_and_match_native_fixture(self):
        args = argparse.Namespace(category='science', phrase=None, limit=None, per_category=3, split='screen')
        _, phrases = eval_cli.read_selection(args)
        self.assertEqual([p['id'] for p in phrases], ['science-008', 'science-127', 'science-164'])
        args.per_category = 5
        self.assertTrue({p['id'] for p in phrases} < {p['id'] for p in eval_cli.read_selection(args)[1]})
        args.per_category, args.split = 3, 'heldout'
        self.assertEqual([p['id'] for p in eval_cli.read_selection(args)[1]], ['science-101', 'science-135', 'science-163'])
        args.phrase = 'science-008'
        with self.assertRaisesRegex(ValueError, 'No phrases'):
            eval_cli.read_selection(args)

    def test_invalid_partition_controls_fail_before_selection(self):
        for field, value in [('split', 'bad'), ('split_seed', -1), ('split_seed', 2**32),
                             ('screen_per_category', 0), ('screen_per_category', 191)]:
            args = argparse.Namespace(category=None, phrase=None, limit=None)
            setattr(args, field, value)
            with self.assertRaises(ValueError):
                eval_cli.read_selection(args)

    def test_sampler_overrides_preserve_omitted_defaults_and_reject_random_seeds(self):
        self.assertEqual(eval_cli.sampling_overrides(argparse.Namespace()), {})
        accepted = dict(temperature=0, repetition_penalty=1.025, top_k=0, top_p=1, min_p=0, seed=12648430)
        self.assertEqual(eval_cli.sampling_overrides(argparse.Namespace(**accepted)), accepted)
        for field, value in [('temperature', float('nan')), ('temperature', float('inf')), ('temperature', -1),
                             ('repetition_penalty', 0), ('top_k', -1), ('top_k', 2**31), ('top_k', 1.5),
                             ('top_p', 1.1), ('min_p', -0.1), ('seed', 0), ('seed', 2**32 - 1), ('seed', 1.2)]:
            with self.assertRaises(ValueError):
                eval_cli.sampling_overrides(argparse.Namespace(**{field: value}))

    def test_effective_sampling_must_match_request_including_seed(self):
        report = self.report()
        report['metadata']['configuration'] = {'temperature': '0.0', 'repetitionPenalty': '1.025'}
        eval_cli.validate_sampling_report(report, {'temperature': 0, 'repetition_penalty': 1.025, 'seed': 42})
        for overrides in ({'seed': 43}, {'temperature': 0.1}, {'top_k': 20}):
            with self.assertRaisesRegex(RuntimeError, 'does not match'):
                eval_cli.validate_sampling_report(report, overrides)

    def test_build_fingerprint_includes_local_native_sources_and_ignores_run_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'Cotabby').mkdir()
            (root / 'Cotabby/app.swift').write_text('app source')
            native = root / 'native'
            native.mkdir()
            (native / 'Package.swift').write_text('package')
            (native / 'TokenHealing.cpp').write_text('native source')
            workspace = root / 'dev.xcworkspace'
            workspace.mkdir()
            (workspace / 'contents.xcworkspacedata').write_text(f'<Workspace><FileRef location="absolute:{native}" /></Workspace>')
            def names(command, cwd):
                return b'Cotabby/app.swift\0' if cwd == root else b'Package.swift\0TokenHealing.cpp\0'
            with mock.patch.object(eval_cli, 'ROOT', root), mock.patch.object(eval_cli.subprocess, 'check_output', side_effect=names):
                first = eval_cli.build_input_fingerprint(workspace)
                (root / 'run-output.json').write_text('does not affect build')
                self.assertEqual(first, eval_cli.build_input_fingerprint(workspace))
                (native / 'TokenHealing.cpp').write_text('edited native source')
                self.assertNotEqual(first, eval_cli.build_input_fingerprint(workspace))

    def test_build_product_fingerprint_rejects_replaced_test_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / 'Cotabby.xctestrun'
            source.write_bytes(b'configuration')
            executable = root / 'Release/Cotabby.app/Contents/PlugIns/CotabbyTests.xctest/Contents/MacOS/CotabbyTests'
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b'original test code')
            first = eval_cli.build_product_fingerprint(source)
            executable.write_bytes(b'changed test code')
            self.assertNotEqual(first, eval_cli.build_product_fingerprint(source))

    def test_three_worker_progress_combines_out_of_order_results(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory)
            (output / 'metadata.json').write_text(json.dumps({'workerCount': 3}))
            progress = eval_cli.ReplayProgress(output, 6)
            journal = output / 'phrases.jsonl'
            for index, (phrase, condition) in enumerate([
                ('science-003', 'none'), ('science-001', 'none'), ('science-002', 'screen'),
                ('science-001', 'screen'), ('science-003', 'screen'), ('science-002', 'none')
            ]):
                with journal.open('a') as stream:
                    stream.write(json.dumps({'phrase': {'id': phrase}, 'condition': condition, 'observations': [{}]}) + '\n')
                status = progress.status()
                self.assertEqual(progress.completed, index + 1)
                self.assertIn('workers 3', status)
            self.assertIn('100.0%', status)

    def test_worker_count_is_retained_in_baselines_and_does_not_block_accuracy_comparisons(self):
        before = self.report()
        after = copy.deepcopy(before)
        after['metadata']['workerCount'] = 3
        self.assertEqual(len(eval_cli.comparison_rows(before, after)), 3)

    def test_baseline_export_preserves_comparison_without_diagnostic_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / 'run'
            source.mkdir()
            report, manifest = self.baseline_run()
            report['metadata']['workerCount'] = 3
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
                self.assertEqual(saved['metadata']['workerCount'], 3)
                self.assertEqual(json.loads((destination / 'manifest.json').read_text())['workerCount'], 3)
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
