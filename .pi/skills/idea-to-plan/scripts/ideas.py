#!/usr/bin/env python3
"""Recoverable, single-idea Org intake. Python 3.9+, Git and Unix flock."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid

STATES = {'IDEA', 'QUEUED', 'NEEDS-INPUT', 'PLANNED', 'DECLINED'}
HEADING = re.compile(r'^(\*+) (.*)\n?$')
PROPERTY = re.compile(r'^:([A-Za-z0-9_]+):[ \t]*(.*?)\n?$')


def now():
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


def digest(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def inventory(text):
    """Bounded Org subset: LF, ordinary headings, drawers and balanced blocks.

    Ignore headings inside blocks/drawers; refuse ambiguous or unsupported syntax
    instead of guessing. Offsets are Python character offsets, not UTF-8 bytes.
    """
    if '\r' in text or '\x00' in text or (text and not text.endswith('\n')):
        raise ValueError('Source requires LF text with a final newline and no NUL')
    lines = text.splitlines(keepends=True)
    heads, block, drawer, offset = [], None, None, 0
    property_drawers = []
    for line in lines:
        stripped = line.strip()
        begin = re.match(r'^#\+begin_(\w+)\b', stripped, re.I)
        end = re.match(r'^#\+end_(\w+)\s*$', stripped, re.I)
        if block:
            if end and end[1].lower() == block:
                block = None
        elif drawer:
            if stripped.upper() == ':END:':
                drawer = None
            elif HEADING.match(line):
                raise ValueError('Heading in an unterminated drawer')
        elif begin:
            block = begin[1].lower()
        elif end:
            raise ValueError('Unmatched block end')
        elif re.match(r'^#\+(?:BEGIN:|END:|INCLUDE:|TODO:|SEQ_TODO:)', stripped, re.I):
            if not re.fullmatch(r'#\+(?:TODO|SEQ_TODO):\s*IDEA QUEUED NEEDS-INPUT \| PLANNED DECLINED', stripped, re.I):
                raise ValueError('Unsupported dynamic block, include or intake TODO declaration')
        elif re.fullmatch(r':[A-Za-z0-9_@#%]+:', stripped):
            if stripped.upper() == ':END:':
                raise ValueError('Unmatched drawer end')
            drawer = stripped
            if stripped.upper() == ':PROPERTIES:':
                property_drawers.append(offset)
        else:
            match = HEADING.match(line)
            if match:
                heads.append((len(match[1]), match[2], offset, offset + len(line)))
        offset += len(line)
    if block or drawer:
        raise ValueError('Unterminated block or drawer')
    parents = [i for i, h in enumerate(heads) if h[0] == 1 and h[1] == 'Ideas']
    if len(parents) != 1:
        raise ValueError('Expected exactly one top-level Ideas heading')
    parent = parents[0]
    result = []
    for i in range(parent + 1, len(heads)):
        depth, raw, start, body_start = heads[i]
        if depth == 1:
            break
        if depth != 2:
            continue
        stop = next((h[2] for h in heads[i + 1:] if h[0] <= 2), len(text))
        first = raw.split(' ', 1)[0]
        state = first if first in STATES else 'IDEA'
        title = raw[len(first) + 1:] if first in STATES else raw
        if first in {'TODO', 'DONE', 'IN-PROGRESS', 'BLOCKED'}:
            raise ValueError('Unsupported TODO state in Ideas')
        priority = re.match(r'^\[#([A-Z])\] ', title)
        display = title[5:] if priority else title
        display = re.sub(r'\s+:[\w@#%:]+:\s*$', '', display)
        props, positions = {}, {}
        pstart = body_start
        planning = re.match(r'(?:(?:SCHEDULED|DEADLINE|CLOSED):[^\n]*\n)', text[pstart:stop])
        if planning:
            pstart += planning.end()
        pend = pstart
        if text.startswith(':PROPERTIES:\n', pstart):
            cursor = pstart + len(':PROPERTIES:\n')
            for line in text[cursor:stop].splitlines(keepends=True):
                if line == ':END:\n':
                    pend = cursor + len(line)
                    break
                prop = PROPERTY.fullmatch(line)
                if not prop or prop[1].upper() in props:
                    raise ValueError('Malformed or duplicate idea property')
                key = prop[1].upper()
                props[key] = prop[2]
                positions[key] = (cursor, cursor + len(line))
                cursor += len(line)
            else:
                raise ValueError('Unterminated property drawer')
        first_child = next((h[2] for h in heads[i + 1:] if h[0] > 2 and h[2] < stop), stop)
        if any(pend <= pos < first_child for pos in property_drawers):
            raise ValueError('Misplaced property drawer')
        result.append(dict(id=props.get('ID'), state=state, title=display,
                           priority=priority[1] if priority else None,
                           start=start, body_start=body_start, end=stop,
                           raw=raw, props=props, positions=positions,
                           pstart=pstart, pend=pend))
    ids = [e['id'] for e in result if e['id']]
    if len(ids) != len(set(ids)):
        raise ValueError('Duplicate idea IDs')
    return result


def mutate(text, entry, properties=None, state=None, note=None):
    edits = []
    missing = []
    for key, value in (properties or {}).items():
        if not re.fullmatch(r'[A-Z_]+', key) or any(c in value for c in '\n\r\x00'):
            raise ValueError('Invalid property')
        line = f':{key}: {value}\n'
        if key in entry['positions']:
            a, b = entry['positions'][key]
            edits.append((a, b, line))
        else:
            missing.append(line)
    if missing:
        if entry['pend'] > entry['pstart']:
            pos = entry['pend'] - len(':END:\n')
            edits.append((pos, pos, ''.join(missing)))
        else:
            edits.append((entry['pstart'], entry['pstart'], ':PROPERTIES:\n' + ''.join(missing) + ':END:\n'))
    if state and state != entry['state']:
        raw = entry['raw']
        if raw.split(' ', 1)[0] in STATES:
            raw = raw.split(' ', 1)[1]
        edits.append((entry['start'], entry['body_start'], f'** {state} {raw}\n'))
    if note:
        # Escape Org structural markers: notes are always a single plain line.
        note = ' '.join(note.split())
        edits.append((entry['end'], entry['end'], f'- Planning [{now()}]: {note}\n'))
    # Equal-position insertions are applied in reverse request order, so a
    # newly created drawer precedes the note even for an empty final idea.
    for _, (a, b, replacement) in sorted(enumerate(edits),
                                        key=lambda item: (item[1][0], item[1][1], item[0]),
                                        reverse=True):
        text = text[:a] + replacement + text[b:]
    inventory(text)
    return text


def editor_guard(path):
    for other in (path.with_name('.#' + path.name), path.with_name('#' + path.name + '#')):
        if os.path.lexists(other):
            raise ValueError(f'Editor lock/autosave conflict: {other}; save and resolve explicitly')
    if path.is_symlink() or not path.is_file():
        raise ValueError('Source must be a regular non-symlink file')


def read_source(path):
    editor_guard(path)
    return path.read_bytes().decode('utf-8')


def atomic(path, expected, content, source=False):
    if path.is_symlink():
        raise ValueError('Refusing symlink publication')
    if source:
        editor_guard(path)
    if path.read_bytes().decode('utf-8') != expected:
        raise ValueError('Stale content; reread and reconcile before retrying')
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='') as stream:
            os.fchmod(stream.fileno(), path.stat().st_mode & 0o777)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        if source:
            editor_guard(path)
        if path.read_bytes().decode('utf-8') != expected:
            raise ValueError('Stale content during publication')
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


@contextmanager
def locked(source):
    # Never unlink this persistent inode: unlinking a flock file can split locks.
    path = source.with_name('.' + source.name + '.idea-to-plan.lock')
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'r+') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError(f'Conversion busy: {path}; inspect the owning process, do not delete the lock')
        stream.seek(0)
        stream.truncate()
        stream.write(json.dumps(dict(pid=os.getpid(), source=str(source), started=now())))
        stream.flush()
        yield


def plans(args, *command):
    argv = [sys.executable, str(args.plans), '--json', '--root', str(args.root)]
    if args.config:
        argv += ['--config', str(args.config)]
    if args.local:
        argv += ['--local']
    if args.project:
        argv += ['--project', args.project]
    proc = subprocess.run(argv + list(command), text=True, capture_output=True)
    if proc.returncode:
        raise ValueError('Plans helper failed: ' + (proc.stderr.strip() or proc.stdout.strip()))
    return json.loads(proc.stdout)


def select(entries, selector):
    matches = [e for e in entries if e['id'] == selector or e['title'] == selector]
    if len(matches) != 1:
        raise ValueError(f'Expected one idea for {selector!r}; found {len(matches)}')
    return matches[0]


def outcome(kind, source, text, entry=None, plan=None, **extra):
    return dict(outcome=kind, source=str(source), source_sha256=digest(text),
                idea_id=entry['id'] if entry else None,
                state=entry['state'] if entry else None,
                plan_path=plan['path'] if plan else None, **extra)


def selected_store(args, entry):
    # Delegate storage policy, including worktrees/conflicts, to the installed
    # plans helper. These two inspected APIs are required; do not fork policy.
    spec = importlib.util.spec_from_file_location('idea_plans_helper', args.plans)
    if not spec or not spec.loader:
        raise ValueError('Cannot load plans helper storage API')
    module = importlib.util.module_from_spec(spec)
    previous_bytecode = sys.dont_write_bytecode
    try:
        sys.dont_write_bytecode = True
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = previous_bytecode
    if not hasattr(module, 'root_path') or not hasattr(module, 'storage_path'):
        raise ValueError('Unsupported plans helper: missing storage resolution APIs')
    base = module.storage_path(module.root_path(str(args.root)), args).resolve()
    previous = entry['props'].get('IDEA_PLAN_STORE')
    if previous and previous != str(base):
        raise ValueError('Authoritative plan store changed; reconcile the stored location explicitly')
    return str(base)


def matching(args, entry):
    selected_store(args, entry)
    records = plans(args, 'list', '--all')
    found = []
    ident = entry['id']
    for record in records:
        text = Path(record['path']).read_text(encoding='utf-8')
        source_ids = re.findall(r'^#\+SOURCE_IDEA_ID: (.+)$', text, re.M)
        marker = f'[idea:{ident}]'
        if ident in source_ids or marker in (record['title'] or ''):
            if source_ids and source_ids != [ident]:
                raise ValueError('Conflicting source identities in plan')
            found.append(record)
    if len(found) > 1:
        raise ValueError('Multiple plans claim the source idea, including archive; inspect manually')
    reserved = entry['props'].get('IDEA_PLAN_ID')
    by_id = [r for r in records if r['id'] == reserved] if reserved else []
    if reserved and by_id != found and (by_id or found):
        raise ValueError('Reserved plan ID and source identity disagree')
    reference = entry['props'].get('IDEA_PLAN_FILE')
    if reference and (not found or Path(reference) != Path(found[0]['path'])):
        raise ValueError('Broken/moved plan reference; inspect archive and repair explicitly')
    if entry['state'] == 'PLANNED' and not found:
        raise ValueError('PLANNED idea has no matching plan; no implicit requeue')
    return found[0] if found else None


def handoff(args, source, text, entry):
    if entry['state'] == 'DECLINED':
        raise ValueError('DECLINED idea requires explicit user requeue before conversion')
    ident = entry['id'] or str(uuid.uuid4())
    # Validate IDs before using them in a deterministic plan ID or identity marker.
    try:
        canonical = str(uuid.UUID(ident))
    except ValueError:
        # Existing standard Org IDs may be arbitrary strings. Do not rewrite them.
        canonical = str(uuid.uuid5(uuid.NAMESPACE_URL, ident))
    if not ident or any(c in ident for c in '\n\r[]'):
        raise ValueError('Unsupported Org ID syntax')
    root = str(args.root) if args.root else entry['props'].get('IDEA_PROJECT')
    if not root:
        changed = mutate(text, entry, {'ID': ident}, 'NEEDS-INPUT',
                         'Which execution checkout should own this plan? Set IDEA_PROJECT to its absolute path or supply --root.')
        atomic(source, text, changed, source=True)
        return outcome('needs-input', source, changed, select(inventory(changed), ident),
                       next_action='Supply an execution checkout, then explicitly convert this idea.')
    path = Path(root).expanduser()
    if not path.is_absolute() or not path.is_dir():
        raise ValueError('IDEA_PROJECT/--root must be an existing absolute execution checkout')
    args.root = path.resolve()
    recorded_root = entry['props'].get('IDEA_PROJECT')
    if recorded_root and Path(recorded_root).expanduser().resolve() != args.root:
        raise ValueError('Conflicting execution project; resolve explicitly')
    # Read inventory before any creation, including archived records.
    entry = dict(entry, id=ident)
    record = matching(args, entry)
    if record:
        return outcome('existing', source, text, entry, record,
                       next_action='Inspect/reconcile this existing handoff; do not create another plan.')
    if args.command == 'reconcile':
        raise ValueError('No matching plan exists; retained reservation is provisional. Explicit convert is required to create it.')
    reserved = entry['props'].get('IDEA_PLAN_ID') or 'idea-' + canonical
    changed = mutate(text, entry, {'ID': ident, 'IDEA_PROJECT': str(args.root),
                                   'IDEA_PLAN_ID': reserved,
                                   'IDEA_PLAN_STORE': selected_store(args, entry)})
    atomic(source, text, changed, source=True)
    record = plans(args, 'new', '--id', reserved, '--title', entry['title'] + f' [idea:{ident}]')
    # new's initial title carries identity even if this process stops here.
    plan_path = Path(record['path'])
    original = plan_path.read_text(encoding='utf-8')
    updated = original.replace('#+TITLE: ' + record['title'], '#+TITLE: ' + entry['title'], 1)
    updated += f'\n#+SOURCE_IDEA_ID: {ident}\n#+SOURCE_IDEA_FILE: {source}\n'
    atomic(plan_path, original, updated)
    current = select(inventory(changed), ident)
    linked = mutate(changed, current, {'IDEA_PLAN_FILE': str(plan_path)},
                    note='Provisional draft created; research, draft and validate it before publication. ' + str(plan_path))
    atomic(source, changed, linked, source=True)
    return outcome('created', source, linked, select(inventory(linked), ident), record,
                   next_action='Draft this record using the plans skill, then publish with this source_sha256.')


def publish(args, source, text, entry):
    if not args.root:
        root = entry['props'].get('IDEA_PROJECT')
        if not root:
            raise ValueError('Missing execution project')
        args.root = Path(root).resolve()
    recorded = entry['props'].get('IDEA_PROJECT')
    if recorded and Path(recorded).resolve() != args.root:
        raise ValueError('Conflicting execution project')
    record = matching(args, entry)
    if not record:
        raise ValueError('No matching plan; reconcile before publication')
    if entry['state'] == 'DECLINED':
        raise ValueError('Cannot publish a DECLINED idea')
    path = Path(record['path'])
    plan_text = path.read_text(encoding='utf-8')
    if record['archived'] or record['status'] != 'draft':
        if entry['state'] == 'PLANNED':
            return outcome('existing', source, text, entry, record, next_action='Handoff already recorded; implementation lifecycle is separate.')
        raise ValueError('Existing non-draft/archived handoff requires explicit human reconciliation, not automatic PLANNED')
    if f'#+SOURCE_IDEA_ID: {entry["id"]}\n' not in plan_text:
        raise ValueError('Provisional identity remains in title; add SOURCE_IDEA_ID and SOURCE_IDEA_FILE before publishing')
    source_fields = re.findall(r'^#\+SOURCE_IDEA_FILE: (.+)$', plan_text, re.M)
    if source_fields != [str(source)]:
        raise ValueError('Plan source file does not match this intake')
    template = args.plans.resolve().parent.parent / 'assets' / 'plan.org'
    if not template.is_file():
        raise ValueError('Plans template unavailable; cannot verify drafting guardrails')
    # The plans checker validates structure, not meaningful drafting.
    boilerplate = template.read_text(encoding='utf-8')
    for section in ('Goal', 'Scope', 'Acceptance criteria', 'Tasks', 'Checkpoint'):
        pattern = r'^\* ' + section + r'\n(.*?)(?=^\* |\Z)'
        old = re.search(pattern, boilerplate, re.M | re.S)
        new = re.search(pattern, plan_text, re.M | re.S)
        if not new or not new[1].strip() or (old and old[1].strip() == new[1].strip()):
            raise ValueError('Undrafted or missing plan section: ' + section)
    checks = plans(args, 'check', record['id'])
    if not checks or not all(item['valid'] for item in checks):
        raise ValueError('Plan validation did not succeed')
    if path.read_text(encoding='utf-8') != plan_text:
        raise ValueError('Plan changed during validation')
    if entry['state'] == 'PLANNED':
        return outcome('existing', source, text, entry, record, checks=checks, next_action='Review the existing draft; do not implement without authorization.')
    changed = mutate(text, entry, {'IDEA_PLAN_ID': record['id'], 'IDEA_PLAN_FILE': str(path)},
                     'PLANNED', 'Validated draft handoff: ' + str(path) + '; implementation requires separate approval.')
    atomic(source, text, changed, source=True)
    return outcome('existing', source, changed, select(inventory(changed), entry['id']), record,
                   checks=checks, next_action='Review the draft; planning does not authorize implementation.')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path, help='saved runtime-accessible Org file')
    parser.add_argument('--root', type=Path, help='absolute execution checkout, never the plans store')
    parser.add_argument('--plans', type=Path, default=Path.home() / '.pi/agent/skills/plans/scripts/plans.py')
    parser.add_argument('--config', type=Path)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--local', action='store_true')
    group.add_argument('--project')
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('list')
    for command in ('convert', 'publish', 'reconcile', 'needs-input'):
        cmd = sub.add_parser(command)
        cmd.add_argument('selector')
        if command in {'publish', 'needs-input'}:
            cmd.add_argument('--expect', required=True, help='source_sha256 from inventory/prepare')
        if command == 'reconcile':
            cmd.add_argument('--expect', help='required with --publish')
            cmd.add_argument('--publish', action='store_true')
        if command == 'needs-input':
            cmd.add_argument('--question', required=True)
    cmd = sub.add_parser('next')
    cmd.add_argument('--unattended', required=True, action='store_true')
    args = parser.parse_args(argv)
    try:
        # Do not resolve a symlink before checking it.
        source = args.source.expanduser().absolute()
        editor_guard(source)
        source = source.resolve()
        if args.root:
            if not args.root.is_absolute() or not args.root.is_dir():
                raise ValueError('--root must be an existing absolute execution checkout')
            args.root = args.root.resolve()
        if args.command == 'list':
            text = read_source(source)
            result = dict(outcome='inventory', source=str(source), source_sha256=digest(text),
                          ideas=[{k: e[k] for k in ('id', 'state', 'title', 'priority', 'props')}
                                 for e in inventory(text)])
        else:
            with locked(source):
                text = read_source(source)
                entries = inventory(text)
                expected = getattr(args, 'expect', None)
                if expected and expected != digest(text):
                    raise ValueError('Stale source digest; reread and reconcile')
                if args.command == 'next':
                    queued = [e for e in entries if e['state'] == 'QUEUED']
                    queued.sort(key=lambda e: (e['priority'] or 'B', e['start']))
                    entry = queued[0] if queued else None
                else:
                    entry = select(entries, args.selector)
                    if args.command in {'publish', 'reconcile'} and not entry['id']:
                        raise ValueError('No stable idea ID; use explicit convert first')
                if entry is None:
                    result = outcome('no-op', source, text, next_action='No explicitly QUEUED ideas; nothing changed.')
                elif args.command == 'needs-input':
                    if not args.question.strip():
                        raise ValueError('NEEDS-INPUT requires an actionable nonempty question')
                    if entry['state'] in {'PLANNED', 'DECLINED'}:
                        raise ValueError('Terminal intake state cannot become NEEDS-INPUT implicitly')
                    ident = entry['id'] or str(uuid.uuid4())
                    changed = mutate(text, entry, {'ID': ident}, 'NEEDS-INPUT', args.question)
                    atomic(source, text, changed, source=True)
                    result = outcome('needs-input', source, changed, select(inventory(changed), ident),
                                     next_action=args.question)
                elif args.command == 'publish' or (args.command == 'reconcile' and args.publish):
                    if not expected:
                        raise ValueError('--expect is required to publish reconciliation')
                    result = publish(args, source, text, entry)
                else:
                    result = handoff(args, source, text, entry)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (ValueError, OSError, UnicodeError) as error:
        print(json.dumps(dict(outcome='conflict/failure', error=str(error),
                              next_action='Inspect source and existing plans; fix the conflict explicitly. No automatic retry.')))
        return 1


if __name__ == '__main__':
    sys.exit(main())
