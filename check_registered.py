"""Fail when a named contract test is absent from a Rust test listing."""
import json
import pathlib
import sys
key, filename = sys.argv[1:]
manifest = json.loads(pathlib.Path(__file__).with_name('registered-tests.json').read_text())
actual = {line.removesuffix(': test') for line in pathlib.Path(filename).read_text().splitlines() if line.endswith(': test')}
expected = set(manifest[key])
assert expected <= actual, sorted(expected - actual)
if key == 'owner':
    assert len(actual) == len(expected) == 4
print('REGISTERED', key, len(expected), 'named tests')
