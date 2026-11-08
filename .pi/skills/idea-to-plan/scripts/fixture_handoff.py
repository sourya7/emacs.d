#!/usr/bin/env python3
"""Offline runtime fixture driver; only accepts its own disposable project marker.

Scripted provider choices test tool dispatch, not autonomous planning quality.
"""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
root = Path(sys.argv[1]).resolve()
plans = Path(sys.argv[2]).resolve()
assert (root / 'disposable-intake-fixture').read_text() == 'fixture-only\n'
assert (root / 'app.py').read_text() == 'def greet():\n    return "hello"\n'
source = root / 'ideas.org'
config = root / 'plans-config.json'
config.write_text('{}')
spec = importlib.util.spec_from_file_location('ideas', Path(__file__).with_name('ideas.py'))
ideas = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ideas)
common = ['--source', str(source), '--root', str(root), '--plans', str(plans), '--config', str(config), '--local']


def call(*command):
    with contextlib.redirect_stdout(io.StringIO()) as output:
        status = ideas.main(common + list(command))
    result = json.loads(output.getvalue())
    assert status == 0, result
    return result


created = call('next', '--unattended')
assert created['outcome'] == 'created', created
assert call('next', '--unattended')['outcome'] == 'existing'
path = Path(created['plan_path'])
text = path.read_text()
text = text.replace('Describe the intended outcome and why it matters.', 'Add an optional name argument to greet while preserving its default hello response.')
text = text.replace('- Included:\n- Excluded:', '- Included: app.py greet and focused tests.\n- Excluded: implementing this draft, network calls and unrelated changes.')
text = text.replace('- Describe observable completion and required checks.', '- greet() remains hello; greet("Ada") returns hello Ada; focused tests pass.')
text = text.replace('- Note relevant code, constraints and tradeoffs.', '- Inspected app.py: greet currently has no parameters and returns hello. Add an optional argument and preserve the no-argument path.')
text = text.replace('** TODO Implement the agreed scope', '** TODO Add an optional name to greet and focused regression tests')
text = text.replace('- Last verified result: none', '- Last verified result: read app.py; no implementation performed')
text = text.replace('- Next action: review and approve the plan', '- Next action: review this concrete greet draft; request implementation separately')
text += '\n* Source idea\n[[id:' + created['idea_id'] + '][Source idea]]\n'
path.write_text(text)
published = call('publish', created['idea_id'], '--expect', created['source_sha256'])
assert published['state'] == 'PLANNED', published
assert published['checks'][0]['valid']
assert call('next', '--unattended')['outcome'] == 'no-op'
assert call('next', '--unattended')['outcome'] == 'no-op'
assert len(list((root / '.plans').glob('*/plan.org'))) == 1
assert (root / 'app.py').read_text() == 'def greet():\n    return "hello"\n'
assert 'Original idea notes.\n*** Keep nested notes\nNo changes here.\n' in source.read_text()
print(json.dumps(dict(outcome='created', idea_id=created['idea_id'], state='PLANNED',
                      plan_path=str(path), checks='passed; repeat existing; repeated no-op; implementation untouched')))
