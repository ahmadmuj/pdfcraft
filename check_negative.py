"""Accept only the exact assertion difference from one intended negative control."""
import pathlib
import re
import sys

control, filename, status = sys.argv[1:]
assert status == '101', f'wrong exit status: {status}'
log = pathlib.Path(filename).read_text()
name = 'flatten_keeps_no_rotate_placement_and_membership_on_the_same_saved_invocation'
assert f'test {name} ... FAILED' in log
assert '0 passed; 1 failed;' in log
assert 'panicked at crates/edit/tests/flatten_optional_content.rs:155:' in log
assert 'assertion `left == right` failed' in log
assert 'error[E' not in log and 'could not compile' not in log
left = re.search(r'^\s*left: (.+)$', log, re.M).group(1)
right = re.search(r'^\s*right: (.+)$', log, re.M).group(1)
# Rust Debug output comes from the exact derived ObjRef/Object implementations.
ap = 'ObjRef { num: 7, generation: 0 }'
members = [f'Some(Ref(ObjRef {{ num: {n}, generation: 0 }}))' for n in (4, 5)]
flagged = '[0.0, 1.0, -1.0, 0.0, 100.0, 100.0]'
normal = '[1.0, 0.0, 0.0, 1.0, 50.0, 50.0]'
def pair(a, b, first_matrix):
    return f'[({ap}, {a}, {first_matrix}), ({ap}, {b}, {normal})]'
assert right == pair(*members, flagged), right
if control == 'no-rotate':
    assert left == pair(*members, normal), left
elif control == 'membership':
    assert left == pair('None', 'None', flagged), left
else:
    raise AssertionError(control)
print('NEGATIVE PASS', control, 'exact saved-invocation assertion difference; exit=101')
