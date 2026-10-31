#!/usr/bin/env bash
# DRAFT ONLY. Do not run locally. Publication and hosted execution need separate approval.
set -euo pipefail
: "${GITHUB_ACTIONS:?Hosted runner required}"
test "$GITHUB_ACTIONS" = true
: "${HARNESS_DIR:?}" "${SOURCE_DIR:?}" "${EXPECTED_HEAD:?}" "${EXPECTED_TREE:?}" "${PR_NUMBER:?}" "${RUNNER_TEMP:?}"
[[ "$EXPECTED_HEAD" =~ ^[0-9a-f]{40}$ ]]
[[ "$EXPECTED_TREE" =~ ^[0-9a-f]{40}$ ]]
case "$PR_NUMBER" in 2789|3280|3274|3628) ;; *) exit 64;; esac
cd "$SOURCE_DIR"
test "$(git rev-parse HEAD)" = "$EXPECTED_HEAD"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
test -z "$(git status --porcelain --untracked-files=all)"
acceptance_dir=$(mktemp -d "$RUNNER_TEMP/acceptance.XXXXXXXX")
export ACCEPTANCE_DIR="$acceptance_dir"
export CARGO_TARGET_DIR="$RUNNER_TEMP/cargo-target"
export CARGO_BUILD_JOBS=2 CARGO_INCREMENTAL=0 CARGO_PROFILE_DEV_DEBUG=line-tables-only
export PDFCRAFT_ORACLES_REQUIRED=1 CRAFT_FONTS_REQUIRED=1 PDFCRAFT_SYSTEM_FONTS=0
printf 'SOURCE head=%s tree=%s PR=%s\n' "$EXPECTED_HEAD" "$EXPECTED_TREE" "$PR_NUMBER"
git diff --exit-code
gate() {
  local name=$1; shift
  local result=0
  timeout 1800 "$@" 2>&1 | python3 -c '
import sys
remaining = 4 * 1024 * 1024
with open(sys.argv[1], "wb") as stream:
    while chunk := sys.stdin.buffer.read(min(65536, remaining + 1)):
        if len(chunk) > remaining:
            stream.write(chunk[:remaining])
            sys.exit(74)
        stream.write(chunk)
        remaining -= len(chunk)
' "$acceptance_dir/$name.log" || result=$?
  printf 'GATE %s exit=%s\n' "$name" "$result"
  # Only bounded text logs leave the runner. No generated artifact is uploaded.
  tail -c 16000 "$acceptance_dir/$name.log"
  return "$result"
}
# Setup occurs in the reviewed workflow before this script. No secret input or cache is used.
command -v qpdf
command -v pdftoppm
rustc --version
cargo --version
qpdf --version
df -h "$RUNNER_TEMP"
case "$PR_NUMBER" in
  2789|3280)
    gate cli-build cargo build --locked -p pdfcraft-cli -j 2
    export ACCEPTANCE_CLI="$CARGO_TARGET_DIR/debug/pdfcraft-cli"
    ;;
esac
case "$PR_NUMBER" in
  2789)
gate owner-list cargo test --locked -p pdfcraft-cli --test it owner_password -j 2 -- --list
python3 "$HARNESS_DIR/check_registered.py" owner "$acceptance_dir/owner-list.log"
gate owner-password cargo test --locked -p pdfcraft-cli --test it owner_password -j 2
cat > "$acceptance_dir/cli-supported.json" <<'JSON'
[
  {
    "tool": "doc_create",
    "args": {
      "from": "text",
      "text": "RC4 permission roundtrip",
      "name": "permissions"
    }
  },
  {
    "tool": "doc_protect",
    "args": {
      "doc": 1,
      "open_password": "user",
      "permissions_password": "owner",
      "compatibility": "rc4-40",
      "printing": "high",
      "changes": "none",
      "copy": true,
      "accessibility": true
    }
  },
  {
    "tool": "doc_save",
    "args": {
      "doc": 1,
      "path": "supported.pdf"
    }
  },
  {
    "tool": "doc_open",
    "args": {
      "path": "supported.pdf",
      "password": "user"
    }
  },
  {
    "tool": "text_extract",
    "args": {
      "doc": 2
    }
  },
  {
    "tool": "page_render",
    "args": {
      "doc": 2,
      "page": 1,
      "dpi": 72
    },
    "out": "supported.png"
  }
]
JSON
cat > "$acceptance_dir/cli-rejected.json" <<'JSON'
[
  {
    "tool": "doc_create",
    "args": {
      "from": "blank"
    }
  },
  {
    "tool": "doc_protect",
    "args": {
      "doc": 1,
      "permissions_password": "owner",
      "compatibility": "rc4-40",
      "printing": "low",
      "accessibility": true
    }
  }
]
JSON
(ulimit -f 8192; timeout 120 "$ACCEPTANCE_CLI" run --report --script "$acceptance_dir/cli-supported.json" --root "$acceptance_dir" > "$acceptance_dir/cli-supported-result.json" 2> "$acceptance_dir/cli-supported-stderr.log")
set +e
(ulimit -f 8192; timeout 120 "$ACCEPTANCE_CLI" run --report --script "$acceptance_dir/cli-rejected.json" --root "$acceptance_dir" > "$acceptance_dir/cli-rejected-result.json" 2> "$acceptance_dir/cli-rejected-stderr.log")
rejected=$?
set -e
printf '%s\n' "$rejected" > "$acceptance_dir/cli-rejected-exit.txt"
test "$rejected" -eq 1
python3 - "$acceptance_dir" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1])
data=json.loads((root/'cli-supported-result.json').read_text())
assert data['ok'] is True, 'supported CLI reports failure'
steps = data['steps']
assert all(step['status'] == 'ok' for step in steps), 'supported CLI step fails'
text_steps = [step for step in steps if step['tool'] == 'text_extract']
assert len(text_steps) == 1, 'wrong extraction step count'
assert text_steps[0]['result'] == [{'pages': [{'page': 1, 'text': 'RC4 permission roundtrip'}]}], 'wrong extracted text'
assert 'RC4-40 supports only' in (root/'cli-rejected-stderr.log').read_text()+(root/'cli-rejected-result.json').read_text()
PY
(ulimit -f 8192; timeout 60 qpdf --password=user --check "$acceptance_dir/supported.pdf" > "$acceptance_dir/qpdf-check.log" 2>&1)
(ulimit -f 8192; timeout 60 qpdf --password=user --show-encryption "$acceptance_dir/supported.pdf" > "$acceptance_dir/qpdf-show-encryption.log" 2>&1)
python3 - "$acceptance_dir" <<'PYQ'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
actual = (root/'qpdf-show-encryption.log').read_text().splitlines()
expected = ['R = 2', 'P = -44', 'Supplied password is user password',
            'extract for accessibility: allowed', 'extract for any purpose: allowed',
            'print low resolution: allowed', 'print high resolution: allowed',
            'modify document assembly: not allowed', 'modify forms: not allowed',
            'modify annotations: not allowed', 'modify other: not allowed',
            'modify anything: not allowed']
assert all(line in actual for line in expected), 'wrong qpdf permissions'
PYQ
# PNG decoding and nonwhite content are automated checks. Human visual review remains separate.
python3 - "$acceptance_dir/supported.png" <<'PYPNG'
from PIL import Image
import hashlib, sys
from pathlib import Path
path = Path(sys.argv[1])
image = Image.open(path)
assert 0 < image.width <= 4096 and 0 < image.height <= 4096
image = image.convert('RGB')
assert any(pixel != (255, 255, 255) for pixel in image.getdata()), 'blank render'
print('PNG', image.size, hashlib.sha256(path.read_bytes()).hexdigest(), 'human-review=PENDING')
PYPNG
tail -c 16000 "$acceptance_dir/qpdf-show-encryption.log"
;;
3280)
python3 - <<'PYCLI'
from pathlib import Path
import json
import subprocess
import os
import resource

run = Path(os.environ['ACCEPTANCE_DIR'])
root = run / 'refresh-cli-fixtures'
root.mkdir(exist_ok=True)
page = '/Figure <</MCID 0>> BDC 10 10 20 20 re f EMC q /Form Do Q'
form = '/Figure <</MCID 0>> BDC 0 0 5 5 re f EMC'
objects = [
    '<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 5 0 R /MarkInfo << /Marked true >> >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 4 0 R /StructParents 0 /Resources << /XObject << /Form 10 0 R >> >> >>',
    f'<< /Length {len(page)} >>\nstream\n{page}\nendstream',
    '<< /Type /StructTreeRoot /K 6 0 R /ParentTree 9 0 R >>',
    '<< /S /Document /P 5 0 R /K [7 0 R 8 0 R] >>',
    '<< /S /Figure /P 6 0 R /Pg 3 0 R /K 0 /Alt (Page figure) >>',
    '<< /S /Figure /P 6 0 R /Pg 3 0 R /K << /Type /MCR /MCID 0 /Stm 10 0 R /Pg 3 0 R >> /Alt (Form figure) >>',
    '<< /Nums [0 [7 0 R] 1 8 0 R] >>',
    f'<< /Type /XObject /Subtype /Form /BBox [0 0 5 5] /StructParents 1 /Length {len(form)} >>\nstream\n{form}\nendstream',
]
data = bytearray(b'%PDF-1.7\n')
offsets = []
for number, obj in enumerate(objects, 1):
    offsets.append(len(data))
    data.extend(f'{number} 0 obj\n{obj}\nendobj\n'.encode('ascii'))
xref = len(data)
data.extend(f'xref\n0 {len(objects) + 1}\n0000000000 65535 f \n'.encode('ascii'))
for offset in offsets:
    data.extend(f'{offset:010} 00000 n \n'.encode('ascii'))
data.extend(f'trailer << /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode('ascii'))
fixture = root / 'stm-collision.pdf'
fixture.write_bytes(data)
binary = os.environ['ACCEPTANCE_CLI']
for name, tool, args in [
    ('decorative', 'accessibility_set_alt', {'doc': 1, 'figure': 8, 'decorative': True}),
    ('artifact', 'accessibility_mark_tag_artifact', {'doc': 1, 'object': 8, 'generation': 0}),
]:
    script = [
        {'tool': 'doc_open', 'args': {'path': 'stm-collision.pdf'}},
        {'tool': 'doc_info', 'args': {'doc': 1}},
        {'tool': 'accessibility_figures', 'args': {'doc': 1}},
        {'tool': tool, 'args': args},
        {'tool': 'doc_save', 'args': {'doc': 1, 'path': f'{name}.pdf', 'full': True}},
    ]
    path = root / f'{name}.json'
    path.write_text(json.dumps(script, indent=2) + '\n')
    command = [binary, 'run', '--script', str(path), '--root', str(root), '--report']
    with (run / 'refresh-cli-commands.log').open('a') as out:
        out.write(' '.join(command) + '\n')
    def limit_output():
        resource.setrlimit(resource.RLIMIT_FSIZE, (1024 * 1024, 1024 * 1024))
    with (run / f'refresh-cli-{name}.json').open('wb') as stdout, (run / f'refresh-cli-{name}.stderr.log').open('wb') as stderr:
        result = subprocess.run(command, stdout=stdout, stderr=stderr, timeout=120, preexec_fn=limit_output)
    report = json.loads((run / f'refresh-cli-{name}.json').read_bytes())
    assert result.returncode == 1
    assert report['ok'] is False
    assert [s['status'] for s in report['steps']] == ['ok', 'ok', 'ok', 'error', 'skipped']
    assert 'form streams' in report['steps'][3]['error']
    assert not (root / f'{name}.pdf').exists()
    assert fixture.read_bytes() == data
    print(name, 'PASS: real CLI refuses form content with a useful error; later save is skipped')
PYCLI
;;
3274)
export PDFCRAFT_3213_ARTIFACTS="$acceptance_dir/edit"
export PDFCRAFT_3213_WORKFLOW_ARTIFACTS="$acceptance_dir/automation"
mkdir -p "$PDFCRAFT_3213_ARTIFACTS" "$PDFCRAFT_3213_WORKFLOW_ARTIFACTS"
gate edit-list cargo test --locked -p pdfcraft-edit -j 2 --test flatten_optional_content -- --list
grep -Fq 'flatten_keeps_no_rotate_placement_and_membership_on_the_same_saved_invocation: test' "$acceptance_dir/edit-list.log"
test "$(grep -c ': test$' "$acceptance_dir/edit-list.log")" -eq 9
gate automation-list cargo test --locked -p pdfcraft-automation -j 2 --test it flatten_optional_content_3213:: -- --list
grep -Fq 'flatten_optional_content_3213::flatten_tools_keep_membership_bound_to_appearance_after_save_and_reopen: test' "$acceptance_dir/automation-list.log"
test "$(grep -c ': test$' "$acceptance_dir/automation-list.log")" -eq 1
gate edit cargo test --locked -p pdfcraft-edit -j 2 --test flatten_optional_content
gate automation cargo test --locked -p pdfcraft-automation -j 2 --test it flatten_optional_content_3213::
gate edit-pixels python3 "$HARNESS_DIR/check_edit_pixels.py" "$PDFCRAFT_3213_ARTIFACTS"
gate automation-pixels python3 "$HARNESS_DIR/check_automation_pixels.py" "$PDFCRAFT_3213_WORKFLOW_ARTIFACTS"
# Hosted ephemeral cleanup prevents three complete target trees from accumulating.
# This never names or deletes a workspace or local build output.
test "$CARGO_TARGET_DIR" = "$RUNNER_TEMP/cargo-target"
du -sh "$CARGO_TARGET_DIR"
rm -rf -- "$CARGO_TARGET_DIR"
df -h "$RUNNER_TEMP"
# Each disposable clone starts at the same reviewed head. The original checkout is read-only here.
for control in no-rotate membership; do
  mutant="$RUNNER_TEMP/mutant-$control"
  git clone --no-hardlinks --no-checkout "$SOURCE_DIR" "$mutant"
  git -C "$mutant" checkout --detach "$EXPECTED_HEAD"
  test "$(git -C "$mutant" rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
  sha256sum "$HARNESS_DIR/patches/$control.patch"
  git -C "$mutant" apply --check "$HARNESS_DIR/patches/$control.patch"
  git -C "$mutant" apply "$HARNESS_DIR/patches/$control.patch"
  git -C "$mutant" diff --check
  test "$(git -C "$mutant" diff --name-only)" = crates/edit/src/flatten.rs
  git -C "$mutant" diff -- crates/edit/src/flatten.rs
  # Build failure is not negative evidence. Only the intended test assertion is accepted.
  (cd "$mutant"; gate "negative-$control-build" env CARGO_TARGET_DIR="$RUNNER_TEMP/target-$control" cargo test --locked -p pdfcraft-edit -j 2 --test flatten_optional_content --no-run)
  status=0
  (cd "$mutant"; gate "negative-$control" env CARGO_TARGET_DIR="$RUNNER_TEMP/target-$control" cargo test --locked -p pdfcraft-edit -j 2 --test flatten_optional_content flatten_keeps_no_rotate_placement_and_membership_on_the_same_saved_invocation -- --exact --nocapture) || status=$?
  python3 "$HARNESS_DIR/check_negative.py" "$control" "$acceptance_dir/negative-$control.log" "$status"
  du -sh "$RUNNER_TEMP/target-$control"
  rm -rf -- "$RUNNER_TEMP/target-$control"
  df -h "$RUNNER_TEMP"
done
;;
3628)
# Full crate suites preserve all registered S1-S3, CropBox, ActualText, UI, and saved-output controls.
gate scoped-tests cargo test --locked -p pdfcraft-render -p pdfcraft-automation -p pdfcraft-engine -p pdfcraft-ui-egui -j 2
# Explicit listings prevent an absent or unregistered suite from becoming an empty success.
gate ui-list cargo test --locked -p pdfcraft-ui-egui --test it redact::query_redaction_includes_clipped_copies_in_the_saved_document -- --list
grep -Fq 'redact::query_redaction_includes_clipped_copies_in_the_saved_document: test' "$acceptance_dir/ui-list.log"
gate ui-query cargo test --locked -p pdfcraft-ui-egui --test it redact::query_redaction_includes_clipped_copies_in_the_saved_document -- --exact
gate render-list cargo test --locked -p pdfcraft-render --lib text::tests -- --list
gate automation-list cargo test --locked -p pdfcraft-automation --test it form_bounds:: -- --list
grep -Fq 'form_bounds::form_bounds_survive_extraction_find_export_and_save: test' "$acceptance_dir/automation-list.log"
grep -Fq 'form_bounds::query_redaction_removes_clipped_copies_without_polluting_find: test' "$acceptance_dir/automation-list.log"
grep -Fq 'form_bounds::redaction_verification_rejects_retained_clipped_text_under_a_mark: test' "$acceptance_dir/automation-list.log"
python3 "$HARNESS_DIR/check_registered.py" render "$acceptance_dir/render-list.log"
python3 "$HARNESS_DIR/check_registered.py" automation "$acceptance_dir/automation-list.log"
gate render-contract cargo test --locked -p pdfcraft-render --lib text::tests -j 2
gate automation-contract cargo test --locked -p pdfcraft-automation --test it form_bounds -j 2
# The amended contract retains historical red proof. These are current exact-head green checks.
;;
esac
# Ordinary exact-head CI provides the other quality gates. This extra run does not replace CI.
git diff --exit-code
git diff --cached --exit-code
test "$(git rev-parse HEAD)" = "$EXPECTED_HEAD"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
test -z "$(git status --porcelain --untracked-files=all)"
printf 'AUTOMATED CASE COMPLETE head=%s tree=%s; human/readiness gates remain separate\n' "$EXPECTED_HEAD" "$EXPECTED_TREE"
