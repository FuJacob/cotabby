#!/usr/bin/env python3
"""Evaluate every installed catalog model through Cotabby's real Swift replay.

This local-only orchestrator owns model discovery and campaign/report lifetime; phrase_eval.py
owns verified builds and Swift owns prompting, inference, display eligibility and scoring.
No downloads, network inference, app preference writes, or automatic catalog promotion occur.
"""
import argparse
import collections
import json
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / 'Cotabby/Models/Runtime/LlamaRuntimeModels.swift'
REGRESSIONS = ROOT / 'CotabbyTests/Fixtures/supported-model-regressions.json'
DEFAULT_MODELS = Path.home() / 'Library/Application Support/Cotabby McHamster/LlamaRuntime'


def installed_models(directory):
    # Read the shipping catalog instead of maintaining a second list that can silently drift.
    source = CATALOG.read_text()
    filenames = re.findall(r'filename:\s*"([^"\n]+\.gguf)"', source)
    names = dict(re.findall(r'case "([^"\n]+\.gguf)":\s*return "([^"]+)"', source))
    if not filenames or len(set(filenames)) != len(filenames):
        raise ValueError('Could not read a unique supported model catalog')
    models = []
    for filename in filenames:
        path = directory / filename
        if not path.is_file():
            raise ValueError(f'Supported model missing: {path}. This harness never downloads weights.')
        models.append({'name': names.get(filename, filename), 'path': str(path.resolve()), 'bytes': path.stat().st_size})
    return models


def workloads(stage):
    # Select by a fixed hash split, never by which examples a model answered correctly.
    # Regression cases are diagnostic/development data and cannot establish general quality.
    split = 'screen' if stage == 'screen' else 'heldout'
    return [
        ('word', ['--split', split, '--per-category', '5' if stage == 'screen' else '15', '--mode', 'word', '--context', 'paired']),
        ('character', ['--split', split, '--per-category', '2' if stage == 'screen' else '5', '--mode', 'character', '--context', 'paired']),
        ('regressions', ['--corpus', str(REGRESSIONS), '--mode', 'character', '--context', 'none']),
        ('runtime', ['--limit', '1', '--context', 'none', '--runtime-checks']),
    ]


def metrics(report):
    """Summarize actual Swift observations without rescoring their correctness in Python."""
    result = {}
    for condition in sorted({p['condition'] for p in report['phrases']}):
        observations = [o for p in report['phrases'] if p['condition'] == condition for o in p['observations']]
        boundary = [o for o in observations if o['checkpoint']['typedCharacters'] == 0]
        partial = [o for o in observations if o['checkpoint']['typedCharacters'] > 0]
        def accuracy(items):
            return sum(o['correct'] for o in items) / len(items) if items else None
        shown = [o for o in observations if o['wasShown']]
        latencies = sorted(o['latencyMilliseconds'] for o in observations if o['latencyMilliseconds'] > 0)
        result[condition] = dict(checkpoints=len(observations), nextWordAccuracy=accuracy(boundary),
            partialWordAccuracy=accuracy(partial), coverage=len(shown) / len(observations),
            precisionWhenShown=accuracy(shown), errors=sum(o.get('error') is not None for o in observations),
            p50ms=latencies[(len(latencies)-1)//2] if latencies else None,
            p95ms=latencies[min(len(latencies)-1, int(len(latencies)*.95))] if latencies else None,
            suppressions=dict(collections.Counter(o.get('suppression') for o in observations if o.get('suppression'))))
    return result


def save(output, campaign):
    (output / 'campaign.json').write_text(json.dumps(campaign, indent=2) + '\n')
    lines = ['# Supported model evaluation', '',
        'Local Release replay, one inference worker, fixed seed 42, synthetic English profile (Alex).',
        'Exact intended-word match is not a semantic quality rating; plausible alternatives count as misses.',
        'Final-generation latency excludes model load, keyboard debounce and Accessibility/overlay work.',
        'Completion length: ' + campaign.get('wordCountPreset', 'product default') + ' words.', '',
        '| Model | Prompt | Workload | Context | Next word | Partial word | Shown | Precision | p50 / p95 ms | Errors |',
        '|---|---|---|---|---:|---:|---:|---:|---:|---:|']
    def pct(value): return '—' if value is None else f'{100*value:.1f}%'
    def ms(value): return '—' if value is None else f'{value:.0f}'
    for run in campaign['runs']:
        if run['status'] != 'complete':
            lines.append(f"\n{run['model']} / {run['variant']} / {run['workload']}: **{run['status']}**. See `{run['directory']}.log`.\n")
            continue
        for condition, m in run['metrics'].items():
            lines.append(f"| {run['model']} | {run['variant']} | {run['workload']} | {condition} | {pct(m['nextWordAccuracy'])} | {pct(m['partialWordAccuracy'])} | {pct(m['coverage'])} | {pct(m['precisionWhenShown'])} | {ms(m['p50ms'])} / {ms(m['p95ms'])} | {m['errors']} |")
    lines += ['', 'Status: ' + campaign['status'] + '.', '',
        'Raw prompts, completions, source/binary/model hashes and per-case suppressions are in each replay directory.',
        'The word and character samples overlap; do not pool them as independent evidence. Regression cases are development examples.',
        'Use a held-out validation campaign after choosing a fix. No model is automatically declared usable from a small sample.']
    (output / 'report.md').write_text('\n'.join(lines) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--models-dir', type=Path, default=DEFAULT_MODELS)
    parser.add_argument('--model', action='append', help='Optional catalog name suffix (nano, mini, base, pro); repeat to select several')
    parser.add_argument('--workspace', type=Path, default=ROOT / 'build/cotabby-dependencies/Cotabby.xcworkspace')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--word-count', choices=('2-4', '4-7', '7-12', '12-20'), default='4-7')
    parser.add_argument('--stage', choices=('screen', 'validate'), default='screen')
    parser.add_argument('--variants', nargs='+', choices=('production', 'content-only', 'compact-surface', 'compact-language'), default=['production'])
    parser.add_argument('--workloads', nargs='+', choices=('word', 'character', 'regressions', 'runtime'), default=['word', 'character', 'regressions', 'runtime'])
    parser.add_argument('--plan', action='store_true')
    parser.add_argument('--timeout-seconds', type=float, default=1800, help='Maximum seconds per build/replay; interrupted results remain incomplete')
    parser.add_argument('--skip-build', action='store_true', help='Require a verified existing phrase-eval build')
    args = parser.parse_args()
    if not 0 < args.timeout_seconds < float("inf"):
        parser.error("--timeout-seconds must be finite and positive")
    models = installed_models(args.models_dir)
    if args.model:
        requested = {name.casefold() for name in args.model}
        available = {m['name'].split()[-1].casefold() for m in models}
        if not requested <= available:
            parser.error('Unknown catalog model: ' + ', '.join(sorted(requested - available)))
        models = [m for m in models if m['name'].split()[-1].casefold() in requested]
    jobs = [(m, v, w, flags) for m in models for v in dict.fromkeys(args.variants)
            for w, flags in workloads(args.stage) if w in args.workloads and (w != 'runtime' or v == args.variants[0])]
    campaign = dict(status='planned', stage=args.stage, wordCountPreset=args.word_count, models=models, runs=[], jobCount=len(jobs))
    if args.plan:
        print(json.dumps(campaign | {'workloads': workloads(args.stage), 'variants': args.variants}, indent=2))
        return
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    campaign['status'] = 'running'
    save(output, campaign)
    reuse = args.skip_build
    try:
        for index, (model, variant, workload, flags) in enumerate(jobs):
            slug = model['name'].lower().replace(' ', '-')
            directory = output / f'{slug}-{variant}-{workload}'
            log = output / f'{directory.name}.log'
            run = dict(model=model['name'], variant=variant, workload=workload, directory=directory.name, status='running')
            campaign['runs'].append(run)
            save(output, campaign)
            command = [sys.executable, str(ROOT / 'scripts/phrase_eval.py'), 'run', '--model', model['path'],
                '--workspace', str(args.workspace.resolve()), '--output', str(directory), '--workers', '1',
                '--profile', 'personalized', '--prompt-variant', variant, '--word-count', args.word_count, '--label', f'{args.stage}-{directory.name}', *flags]
            if reuse: command.append('--skip-build')
            print(f'[{index+1}/{len(jobs)}] {model["name"]}: {variant}, {workload}. Log: {log}', flush=True)
            start = time.monotonic()
            with log.open('w') as stream:
                # The child CLI tears down its Xcode process group on SIGINT. Inherit our process
                # group so terminal interruption reaches both orchestrator and replay.
                process = subprocess.Popen(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
                try:
                    code = process.wait(timeout=args.timeout_seconds)
                except BaseException:
                    process.send_signal(2)
                    try: process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                    raise
            run['elapsedSeconds'] = time.monotonic() - start
            if code:
                run['status'] = 'failed'
                raise RuntimeError(f'Replay failed: {log}')
            report = json.loads((directory / 'report.json').read_text())
            if Path(report['metadata']['model']).resolve() != Path(model['path']).resolve():
                raise RuntimeError('Test host loaded a different model than requested')
            config = report['metadata']['configuration']
            if config.get('promptVariant') != variant or config.get('profile') != 'personalized' or config.get('wordCountPreset') != args.word_count:
                raise RuntimeError('Test host ignored prompt/profile controls; rebuild')
            run.update(metrics=metrics(report), metadata=report['metadata'])
            if workload == 'runtime':
                # The replay copies a newly created staged artifact into this run, never a
                # shared per-model filename that could belong to an older campaign.
                typing = json.loads((directory / 'typing.json').read_text())
                if typing['modelFilename'] != Path(model['path']).name:
                    raise RuntimeError('Typing report used a different model')
                if typing.get('wordCountPreset') != args.word_count:
                    raise RuntimeError('Typing report did not honor the selected word-count preset')
                run['typingReport'] = directory.name + '/typing.json'
                run['typingWordCountPreset'] = args.word_count
            run['status'] = 'complete'
            reuse = True
            save(output, campaign)
        campaign['status'] = 'complete'
    except BaseException as error:
        campaign['status'] = 'incomplete'
        if campaign['runs'] and campaign['runs'][-1]['status'] == 'running':
            campaign['runs'][-1]['status'] = 'interrupted' if isinstance(error, KeyboardInterrupt) else 'failed'
        if campaign['runs']:
            campaign['runs'][-1]['error'] = str(error)
        raise
    finally:
        save(output, campaign)
    print(f'Report: {output / "report.md"}', flush=True)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        sys.exit('Interrupted; partial results remain in the campaign directory.')
    except (ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        sys.exit(str(error))
