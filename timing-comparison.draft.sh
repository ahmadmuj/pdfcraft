#!/usr/bin/env bash
# DRAFT ONLY. The future owner reviews the exact candidate before hosted execution.
set -euo pipefail
test "${GITHUB_ACTIONS:-}" = true
test "${GITHUB_REPOSITORY:-}" = ahmadmuj/pdfcraft
test "${GITHUB_REF:-}" = refs/heads/verify/comments-timing-20261031
: "${GITHUB_WORKSPACE:?}" "${RUNNER_TEMP:?}" "${CRAFT_FONTS_DIR:?}"
export CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0 CARGO_PROFILE_DEV_DEBUG=line-tables-only
export RUSTUP_TOOLCHAIN=1.99.1
export PDFCRAFT_ORACLES_REQUIRED=1 CRAFT_FONTS_REQUIRED=1 PDFCRAFT_SYSTEM_FONTS=0
rustc -vV
cargo --version
dpkg-query -W libxkbcommon-dev libwayland-dev libx11-dev libxrandr-dev libxi-dev libgl1-mesa-dev libgtk-3-dev
test "$(git -C "$CRAFT_FONTS_DIR" rev-parse HEAD)" = b076417b5880bd4154bd22f00695b1d28c6bea83
lscpu
df -h "$RUNNER_TEMP"
free -m
printf 'ImageOS=%s ImageVersion=%s RunnerOS=%s\n' "${ImageOS:-unknown}" "${ImageVersion:-unknown}" "${RUNNER_OS:-unknown}"
python3 - <<'PY'
import datetime, hashlib, json, os, pathlib, re, subprocess, sys

root = pathlib.Path(os.environ['GITHUB_WORKSPACE'])
out = pathlib.Path(os.environ['RUNNER_TEMP']) / 'comments-comparison'
out.mkdir(exist_ok=False)
test = 'panels_with_hundreds_of_items_stay_within_the_frame_budget'
pins = {
    'A': ('f137a289baadefbd29e0e46930899896068cc41d', '48431f785a79bf8ea5cb10c259fd561178ca5d67'),
    'B': ('52f729116d0c153644d7560244f77e20c023cbfb', '1a6fe62de459544fe3620cd77c582834b95b9200'),
}
def stamp():
    return {'utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'load': list(os.getloadavg()), 'affinity': sorted(os.sched_getaffinity(0)),
            'proc_loadavg': pathlib.Path('/proc/loadavg').read_text().strip()}

def capture(command, cwd, name, seconds, limit):
    path = out / (name + '.log')
    before = stamp()
    wrapped = ['timeout', '--signal=TERM', '--kill-after=15s', str(seconds) + 's', *command]
    # GNU timeout uses its process group. Do not add --foreground.
    with path.open('wb') as stream:
        p = subprocess.run(wrapped, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT)
    status = p.returncode
    after = stamp()
    size = path.stat().st_size
    with path.open('rb') as stream:
        data = stream.read(limit)
    if size > limit:
        with path.open('r+b') as stream:
            stream.truncate(limit)
    record = {'name': name, 'command': wrapped, 'before': before, 'after': after,
              'exit': status, 'timeout_or_kill': status in (124, 137), 'bytes': size,
              'retained_bytes': len(data), 'output_limit_reached': size > limit}
    print(json.dumps(record), flush=True)
    return record, data

def binary_hash(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

binaries, hashes = {}, {}
for label, (commit, tree) in pins.items():
    source = root / ('source-' + label)
    target = (pathlib.Path(os.environ['RUNNER_TEMP']) / ('comments-target-' + label)).resolve()
    os.environ['CARGO_TARGET_DIR'] = str(target)
    def git(*args):
        return subprocess.check_output(['git', '-C', str(source), *args], text=True).strip()
    assert git('rev-parse', 'HEAD') == commit
    assert git('rev-parse', 'HEAD^{tree}') == tree
    assert not git('status', '--porcelain', '--untracked-files=all')
    print(json.dumps({'source': label, 'commit': commit, 'tree': tree,
                      'lock_sha256': hashlib.sha256((source / 'Cargo.lock').read_bytes()).hexdigest()}), flush=True)
    cmd = ['cargo', 'test', '--locked', '-p', 'pdfcraft-ui-egui', '--test', 'perf',
           '-j', '2', '--no-run', '--message-format=json']
    record, data = capture(cmd, source, 'build-' + label, 1800, 8 * 1024 * 1024)
    print(data[-16000:].decode(errors='replace'), flush=True)
    if record['exit'] or record['output_limit_reached']:
        print('COMPARISON INCOMPLETE: BUILD_OR_SETUP_ERROR', flush=True)
        sys.exit(2)
    executables = set()
    for line in data.splitlines():
        try:
            event = json.loads(line)
        except (ValueError, UnicodeError):
            continue
        if event.get('reason') == 'compiler-artifact' and event.get('target', {}).get('name') == 'perf' and event.get('executable'):
            executables.add(event['executable'])
    assert len(executables) == 1, 'expected one perf integration executable'
    executable = pathlib.Path(executables.pop())
    assert not executable.is_symlink() and executable.is_file()
    assert executable.resolve().is_relative_to(target)
    binaries[label] = executable
    hashes[label] = binary_hash(executable)
    print('BINARY', label, hashes[label], flush=True)

results = []
for number, label in enumerate(('A', 'B', 'B', 'A'), 1):
    source = root / ('source-' + label)
    os.environ['CARGO_TARGET_DIR'] = str((pathlib.Path(os.environ['RUNNER_TEMP']) / ('comments-target-' + label)).resolve())
    if not binaries[label].is_file() or binaries[label].is_symlink() or binary_hash(binaries[label]) != hashes[label]:
        print('COMPARISON INCOMPLETE: BINARY_CHANGED_BEFORE_SAMPLE', flush=True)
        sys.exit(2)
    command = ['cargo', 'test', '--locked', '--offline', '-p', 'pdfcraft-ui-egui',
               '--test', 'perf', '-j', '2', test, '--', '--exact', '--nocapture', '--test-threads', '1']
    record, data = capture(command, source, f'sample-{number}-{label}', 300, 512 * 1024)
    text = data.decode(errors='replace')
    print(text, flush=True)  # Full bounded sample output, including every timing round.
    one = 'running 1 test' in text
    labels = set(re.findall(r'\bPERF (comments|pages|fields) round [123]:', text))
    unchanged = binaries[label].is_file() and not binaries[label].is_symlink() and binary_hash(binaries[label]) == hashes[label]
    if not unchanged or record['timeout_or_kill'] or record['output_limit_reached'] or not one:
        result = 'INFRASTRUCTURE_OR_MISSING_TEST'
    elif 'PERF skipped:' in text and record['exit'] == 0:
        result = 'LOAD_SKIP'
    elif record['exit'] == 0 and 'test result: ok. 1 passed; 0 failed;' in text and labels == {'comments', 'pages', 'fields'}:
        result = 'MEASURED_PASS'
    elif record['exit'] == 101 and 'test result: FAILED. 0 passed; 1 failed;' in text and 'comments' in labels and re.search(r'(comments|pages|fields): average frame ', text):
        result = 'MEASURED_BUDGET_FAILURE'
    else:
        result = 'INFRASTRUCTURE_OR_UNCLASSIFIED_FAILURE'
    record.update(source=label, commit=pins[label][0], classification=result,
                  expected_binary_sha256=hashes[label], binary_unchanged=unchanged)
    results.append(record)
    (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print('SAMPLE_RESULT', json.dumps(record), flush=True)
    if result not in ('MEASURED_PASS', 'MEASURED_BUDGET_FAILURE'):
        print('COMPARISON INCOMPLETE: STOP; no later sample runs', flush=True)
        sys.exit(2)

for label in pins:
    source = root / ('source-' + label)
    assert subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip() == pins[label][0]
    assert not subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain', '--untracked-files=all'], text=True).strip()
(out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
print('FIXED_COMPARISON_COMPLETE', json.dumps(results), flush=True)
if any(r['classification'] not in ('MEASURED_PASS', 'MEASURED_BUDGET_FAILURE') for r in results):
    sys.exit(2)
sys.exit(1 if any(r['classification'] == 'MEASURED_BUDGET_FAILURE' for r in results) else 0)
PY
