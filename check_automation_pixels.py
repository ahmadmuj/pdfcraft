"""External renderer checks of contributor-original automation output; read no renderer source."""
import json
import resource
import sys
import subprocess
from pathlib import Path
import pymupdf

# These limits affect only this disposable observer and its renderer children.
resource.setrlimit(resource.RLIMIT_AS, (2 * 1024**3, 2 * 1024**3))
resource.setrlimit(resource.RLIMIT_FSIZE, (16 * 1024**2, 16 * 1024**2))
root = Path(sys.argv[1])
assert pymupdf.VersionBind == '1.28.2'
rows = []
names = {'off', 'on', 'ocmd', 'direct_ocmd', 'independent_ap', 'visible', 'hidden_flag'}
stages = {'before', 'saved', 'reopened'}
inputs = sorted(root.glob('*-before.pdf')) + sorted(root.glob('*-saved.pdf')) + sorted(root.glob('*-reopened.pdf'))
assert len(inputs) == 21, f'expected 21 workflow inputs, found {len(inputs)}'
assert {p.stem for p in inputs} == {f'{name}-{stage}' for name in names for stage in stages}
for path in inputs:
    name = path.name.rsplit('-', 1)[0]
    stage = path.stem.rsplit('-', 1)[1]
    for annotation_on in [False, True]:
        for appearance_on in [False, True]:
            source = pymupdf.open(path)
            identities = {entry['name']: number for number, entry in source.get_ocgs().items()}
            assert set(identities) == {'Hidden layer', 'Shown layer'}
            groups = {identities['Hidden layer']: annotation_on, identities['Shown layer']: appearance_on}
            source.set_layer(-1, basestate='OFF', on=[n for n, enabled in groups.items() if enabled], off=[n for n, enabled in groups.items() if not enabled])
            state_path = root / f'{path.stem}-a{int(annotation_on)}-p{int(appearance_on)}.pdf'
            state_path.write_bytes(source.tobytes())
            source.close()
            reopened = pymupdf.open(state_path)
            expected = {
                'off': annotation_on,
                'on': appearance_on,
                'ocmd': annotation_on,
                'direct_ocmd': annotation_on,
                'independent_ap': annotation_on and appearance_on,
                'visible': True,
                'hidden_flag': False,
            }[name] * 5000
            pix = reopened[0].get_pixmap(matrix=pymupdf.Matrix(1, 1), alpha=False)
            prefix = state_path.with_suffix('')
            with (root / 'pdftoppm.stderr.log').open('wb') as errors:
                subprocess.run(['pdftoppm', '-r', '72', '-singlefile', '-png', str(state_path), str(prefix)], stdout=subprocess.DEVNULL, stderr=errors, check=True, timeout=60)
            for renderer, image in [('PyMuPDF', pix), ('Poppler', pymupdf.Pixmap(str(prefix) + '.png'))]:
                samples = image.samples
                red = 0
                for y in range(100, 150):
                    for x in range(50, 150):
                        i = (y * image.width + x) * image.n
                        red += samples[i] > 200 and samples[i + 1] < 50 and samples[i + 2] < 50
                # PyMuPDF ignores this OCMD in both original annotations and flattened
                # marked content. Poppler supplies all OCMD pixel assertions.
                # Both viewers ignore independent AP OC before flatten only.
                limitation = (renderer == 'PyMuPDF' and name in ('ocmd', 'direct_ocmd')) or (stage == 'before' and name == 'independent_ap')
                rows.append(dict(file=path.name, annotation_group_on=annotation_on, appearance_group_on=appearance_on,
                                 renderer=renderer, red=red, expected=expected, known_oracle_limitation=limitation))
            reopened.close()
(root / 'pixels.json').write_text(json.dumps({'pymupdf': pymupdf.VersionBind, 'results': rows}, indent=2) + '\n')
assert len(rows) == 168, f'expected 168 renderer observations, found {len(rows)}'
assert sum(r['known_oracle_limitation'] for r in rows) == 32, 'unexpected oracle limitation coverage'
mismatches = [r for r in rows if not r['known_oracle_limitation'] and r['red'] != r['expected']]
print(json.dumps(mismatches, indent=2))
assert not mismatches, 'renderer mismatches; see pixels.json'
print(f'PASS: {len(rows)} renderer/state observations; {sum(r["known_oracle_limitation"] for r in rows)} known baseline oracle limitations')
