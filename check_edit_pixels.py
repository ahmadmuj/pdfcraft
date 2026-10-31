"""Verify synthetic saved output with Poppler as a separate process."""
import json
import resource
import subprocess
import sys
from pathlib import Path
import pymupdf

# These limits affect only this disposable observer and its renderer children.
resource.setrlimit(resource.RLIMIT_AS, (2 * 1024**3, 2 * 1024**3))
resource.setrlimit(resource.RLIMIT_FSIZE, (16 * 1024**2, 16 * 1024**2))
root = Path(sys.argv[1])
names = {'off', 'on', 'ocmd', 'direct_ocmd', 'shared', 'independent_ap', 'ocmd_ve', 'visible', 'hidden_flag'}
inputs = sorted(root.glob('*-flat.pdf'))
assert {p.stem.removesuffix('-flat') for p in inputs} == names
assert len(inputs) == 9
assert pymupdf.VersionBind == '1.28.2'
rows = []
for path in inputs:
    case = path.stem.removesuffix('-flat')
    for state, on, off in [('default', None, None), ('on', [4, 5], []), ('off', [], [4, 5]), ('mixed', [4], [5])]:
        source = path
        if on is not None:
            with pymupdf.open(path) as doc:
                doc.set_layer(-1, basestate='OFF', on=on, off=off)
                source = root / f'{case}-{state}.pdf'
                doc.save(source)
        prefix = root / f'{case}-{state}'
        with (root / 'pdftoppm.stderr.log').open('wb') as errors:
            subprocess.run(['pdftoppm', '-r', '72', '-singlefile', '-png', str(source), str(prefix)], check=True, stdout=subprocess.DEVNULL, stderr=errors, timeout=60)
        pix = pymupdf.Pixmap(str(prefix) + '.png')
        samples = pix.samples
        red = sum(samples[(y * pix.width + x) * pix.n] > 200 and samples[(y * pix.width + x) * pix.n + 1] < 50 for y in range(100, 150) for x in range(50, 150))
        expected = None
        if case in ['off', 'ocmd', 'direct_ocmd', 'shared']:
            expected = 5000 if state in ['on', 'mixed'] else 0
        elif case == 'on':
            expected = 5000 if state in ['default', 'on'] else 0
        elif case == 'independent_ap':
            expected = 5000 if state == 'on' else 0
        elif case == 'ocmd_ve':
            expected = 5000 if state == 'mixed' else 0
        elif case == 'visible':
            expected = 5000
        elif case == 'hidden_flag':
            expected = 0
        rows.append({'case': case, 'state': state, 'red': red, 'expected': expected})
(root / 'poppler-pixels.json').write_text(json.dumps(rows, indent=2) + '\n')
for row in rows:
    print(row)
assert len(rows) == 36, f'expected 36 edit observations, found {len(rows)}'
assert all(row['expected'] is not None and row['red'] == row['expected'] for row in rows), 'pixel behavior differs'
