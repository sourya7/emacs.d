#!/usr/bin/env python3
"""Isolated regression tests. Never reads or converts the real ideas.org."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name('ideas.py')
spec = importlib.util.spec_from_file_location('ideas', SCRIPT)
ideas = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ideas)
DEFAULT_PLANS = Path.home() / '.pi/agent/skills/plans/scripts/plans.py'
PLANS = Path(os.environ.get('IDEAS_TEST_PLANS', DEFAULT_PLANS))


class IntakeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'checkout'
        self.root.mkdir()
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        self.source = self.root / 'ideas.org'
        self.source.write_text('* Ideas\n** A small idea\nOriginal notes α.\n*** Nested note\nKeep this.\n** Another idea\nUnchanged.\n')
        self.config = self.base / 'config.json'
        self.config.write_text('{}')
        self.common = ['--source', str(self.source), '--root', str(self.root),
                       '--plans', str(PLANS), '--config', str(self.config), '--local']

    def invoke(self, *command, common=None, success=True):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            code = ideas.main((self.common if common is None else common) + list(command))
        result = json.loads(output.getvalue())
        self.assertEqual(code, 0 if success else 1, result)
        return result

    def prepared(self):
        return self.invoke('convert', 'A small idea')

    def draft(self, result):
        path = Path(result['plan_path'])
        text = path.read_text()
        text = text.replace('Describe the intended outcome and why it matters.', 'Make the fixture behavior observable.')
        text = text.replace('- Included:\n- Excluded:', '- Included: fixture work.\n- Excluded: implementation during planning.')
        text = text.replace('- Describe observable completion and required checks.', '- A fixture regression demonstrates the behavior.')
        text = text.replace('** TODO Implement the agreed scope', '** TODO Build the fixture behavior')
        text = text.replace('- Next action: review and approve the plan', '- Next action: review this concrete fixture draft')
        path.write_text(text)
        return path

    def test_list_read_only_and_nested_preservation(self):
        before = self.source.read_bytes()
        result = self.invoke('list')
        self.assertEqual(len(result['ideas']), 2)
        self.assertIsNone(result['ideas'][0]['id'])
        self.assertEqual(before, self.source.read_bytes())
        self.assertFalse(self.source.with_name('.ideas.org.idea-to-plan.lock').exists())
        created = self.prepared()
        after = self.source.read_text()
        self.assertIn('Original notes α.\n*** Nested note\nKeep this.\n', after)
        self.assertTrue(after.endswith('** Another idea\nUnchanged.\n'))
        self.assertEqual(created['outcome'], 'created')
        self.assertIn('#+SOURCE_IDEA_ID: ' + created['idea_id'], Path(created['plan_path']).read_text())

    def test_readable_name_and_title_changes(self):
        created = self.prepared()
        self.assertEqual(Path(created['plan_path']).parent.name, 'a-small-idea')
        self.source.write_text(self.source.read_text().replace('** A small idea\n', '** Renamed idea\n'))
        self.assertEqual(self.invoke('convert', created['idea_id'])['plan_path'], created['plan_path'])
        self.invoke('convert', created['idea_id'], '--plan-id', 'different', success=False)

    def test_explicit_name_and_invalid_names(self):
        for name in ('../escape', 'Uppercase', 'two--hyphens', ''):
            self.invoke('convert', 'A small idea', '--plan-id', name, success=False)
        created = self.invoke('convert', 'A small idea', '--plan-id', 'concise-name')
        self.assertEqual(Path(created['plan_path']).parent.name, 'concise-name')
        self.assertEqual(self.invoke('convert', created['idea_id'], '--plan-id', 'concise-name')['outcome'], 'existing')
        self.invoke('convert', 'Another idea', '--plan-id', 'concise-name', success=False)

    def test_title_collision_with_active_archived_and_partial_paths(self):
        for location in ('active', 'archive', 'partial'):
            with self.subTest(location=location):
                first = self.prepared()
                path = Path(first['plan_path'])
                if location == 'archive':
                    target = path.parent.parent / 'archive' / path.parent.name
                    target.parent.mkdir()
                    path.parent.rename(target)
                elif location == 'partial':
                    path.write_text('')
                # A different idea whose punctuation normalizes to the same slug.
                self.source.write_text('* Ideas\n** A small idea!\n')
                second = self.invoke('convert', 'A small idea!')
                name = Path(second['plan_path']).parent.name
                suffix = ideas.hashlib.sha256(second['idea_id'].encode()).hexdigest()[:8]
                self.assertEqual(name, 'a-small-idea-' + suffix)
                self.assertEqual(self.invoke('convert', second['idea_id'])['plan_path'], second['plan_path'])
                shutil.rmtree(self.root / '.plans')
                self.source.write_text('* Ideas\n** A small idea\n** Another idea\n')

    def test_archive_namespace_and_suffix_collision(self):
        self.invoke('convert', 'A small idea', '--plan-id', 'archive', success=False)
        self.source.write_text('* Ideas\n** Archive\n:PROPERTIES:\n:ID: fixed-source\n:END:\n')
        suffix = ideas.hashlib.sha256(b'fixed-source').hexdigest()
        occupied = self.root / '.plans' / ('archive-' + suffix[:8])
        occupied.mkdir(parents=True)  # Incomplete directory, no record yet.
        created = self.invoke('convert', 'fixed-source')
        self.assertEqual(Path(created['plan_path']).parent.name, 'archive-' + suffix[:12])

    def test_reservation_survives_title_change_and_other_idea_collision(self):
        real_plans = ideas.plans
        def interrupt(args, *command):
            if command[0] == 'new':
                raise OSError('injected creation failure')
            return real_plans(args, *command)
        with patch.object(ideas, 'plans', side_effect=interrupt):
            self.invoke('convert', 'A small idea', success=False)
        entry = ideas.inventory(self.source.read_text())[0]
        self.source.write_text(self.source.read_text().replace('** A small idea\n', '** Changed title\n') + '** A small idea!\n')
        other = self.invoke('convert', 'A small idea!')
        self.assertNotEqual(Path(other['plan_path']).parent.name, 'a-small-idea')
        created = self.invoke('convert', entry['id'])
        self.assertEqual(Path(created['plan_path']).parent.name, 'a-small-idea')

    def test_legacy_uuid_reservation_and_existing_record(self):
        legacy = 'idea-12345678-1234-4234-8234-123456789abc'
        self.source.write_text('* Ideas\n** Legacy\n:PROPERTIES:\n:ID: old-source-id\n:IDEA_PLAN_ID: ' + legacy + '\n:END:\n')
        created = self.invoke('convert', 'Legacy')
        self.assertEqual(Path(created['plan_path']).parent.name, legacy)
        self.assertEqual(self.invoke('convert', 'old-source-id')['plan_path'], created['plan_path'])

    def test_slug_normalization_length_and_empty_fallback(self):
        for title, expected in (('Café / title!', 'cafe-title'), ('🦊', 'plan'),
                                ('word ' * 30, '-'.join(['word'] * 16))):
            with self.subTest(title=title):
                self.source.write_text('* Ideas\n** ' + title.strip() + '\n')
                created = self.invoke('convert', title.strip())
                self.assertEqual(Path(created['plan_path']).parent.name, expected)

    def test_blocks_and_drawers_are_not_headings(self):
        self.source.write_text('* Ideas\n** Actual\n#+begin_src org\n** Fake\n#+end_src\n:LOGBOOK:\nplain\n:END:\n*** Nested\n')
        entries = self.invoke('list')['ideas']
        self.assertEqual([e['title'] for e in entries], ['Actual'])
        text = self.source.read_text()
        changed = ideas.mutate(text, ideas.inventory(text)[0], {'ID': 'existing'}, 'QUEUED')
        self.assertIn('#+begin_src org\n** Fake\n#+end_src', changed)

    def test_reject_ambiguous_structure(self):
        for text in ('* Ideas\n* Ideas\n', '* Ideas\n** X\n#+begin_src x\n',
                     '* Ideas\n** X\n:PROPERTIES:\n:ID: x\n:ID: y\n:END:\n',
                     '* Ideas\n** X\nnotes\n:PROPERTIES:\n:ID: x\n:END:\n',
                     '* Ideas\n#+INCLUDE: other.org\n', '* Ideas\r\n',
                     '* Ideas\n** TODO Existing\n', '* Ideas\n** X\n:LOGBOOK:\n** Oops\n:END:\n'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                ideas.inventory(text)

    def test_duplicate_titles_and_ids(self):
        self.source.write_text('* Ideas\n** Same\n** Same\n')
        self.invoke('convert', 'Same', success=False)
        self.source.write_text('* Ideas\n** X\n:PROPERTIES:\n:ID: duplicate\n:END:\n** Y\n:PROPERTIES:\n:ID: duplicate\n:END:\n')
        self.invoke('list', success=False)

    def test_priority_then_file_order_and_one_only(self):
        self.source.write_text('* Ideas\n** QUEUED [#C] Last\n** QUEUED [#A] First\n** QUEUED [#A] Second\n** Untouched\n')
        first = self.invoke('next', '--unattended')
        self.assertIn('First', Path(first['plan_path']).read_text())
        repeat = self.invoke('next', '--unattended')
        self.assertEqual(repeat['outcome'], 'existing')
        self.assertEqual(first['plan_path'], repeat['plan_path'])
        self.assertEqual(len(list((self.root / '.plans').glob('*/plan.org'))), 1)
        self.assertIn('** QUEUED [#A] Second\n** Untouched\n', self.source.read_text())

    def test_no_work_does_not_assign_ids(self):
        before = self.source.read_bytes()
        self.assertEqual(self.invoke('next', '--unattended')['outcome'], 'no-op')
        self.assertEqual(self.source.read_bytes(), before)

    def test_missing_project_needs_input(self):
        self.source.write_text('* Ideas\n** QUEUED Choose project\n')
        result = self.invoke('next', '--unattended', common=['--source', str(self.source)])
        self.assertEqual(result['outcome'], 'needs-input')
        self.assertEqual(result['state'], 'NEEDS-INPUT')
        self.assertIn('Which execution checkout', self.source.read_text())
        self.assertFalse((self.root / '.plans').exists())

    def test_project_conflict_and_store_switch(self):
        result = self.prepared()
        other = self.base / 'other'
        other.mkdir()
        common = self.common.copy()
        common[common.index('--root') + 1] = str(other)
        self.invoke('convert', result['idea_id'], common=common, success=False)
        store = self.base / 'store'
        store.mkdir()
        self.config.write_text(json.dumps({'store': str(store), 'projects': {'sample': {'checkouts': [str(self.root)]}}}))
        central = self.common[:-1] + ['--project', 'sample']
        self.invoke('convert', result['idea_id'], common=central, success=False)
        self.assertFalse((store / 'projects').exists())

    def test_unwritten_template_and_invalid_plan_never_planned(self):
        result = self.prepared()
        self.invoke('publish', result['idea_id'], '--expect', result['source_sha256'], success=False)
        path = self.draft(result)
        path.write_text(path.read_text().replace('#+PLAN_STATUS: draft', '#+PLAN_STATUS: bogus'))
        self.invoke('publish', result['idea_id'], '--expect', result['source_sha256'], success=False)
        self.assertNotIn('** PLANNED ', self.source.read_text())

    def test_success_publish_and_idempotence(self):
        result = self.prepared()
        self.draft(result)
        published = self.invoke('publish', result['idea_id'], '--expect', result['source_sha256'])
        self.assertEqual(published['state'], 'PLANNED')
        self.assertTrue(published['checks'][0]['valid'])
        before = self.source.read_bytes()
        self.invoke('reconcile', result['idea_id'], '--publish', '--expect', published['source_sha256'])
        self.assertEqual(before, self.source.read_bytes())
        self.assertEqual(self.invoke('next', '--unattended')['outcome'], 'no-op')

    def test_missing_deleted_or_broken_reference_no_requeue(self):
        result = self.prepared()
        path = self.draft(result)
        self.invoke('publish', result['idea_id'], '--expect', result['source_sha256'])
        shutil.rmtree(path.parent)
        self.invoke('convert', result['idea_id'], success=False)
        self.assertNotIn('** QUEUED ', self.source.read_text())

    def test_archived_and_multiple_matches(self):
        result = self.prepared()
        path = Path(result['plan_path'])
        # Simulate an externally archived handoff; a stale path fails visibly.
        target = path.parent.parent / 'archive' / path.parent.name
        target.parent.mkdir()
        path.parent.rename(target)
        self.invoke('reconcile', result['idea_id'], success=False)
        text = self.source.read_text().replace(str(path), str(target / 'plan.org'))
        self.source.write_text(text)
        self.assertEqual(self.invoke('reconcile', result['idea_id'])['outcome'], 'existing')
        duplicate = self.root / '.plans/other/plan.org'
        duplicate.parent.mkdir()
        duplicate.write_text((target / 'plan.org').read_text().replace('#+PLAN_ID: ' + path.parent.name, '#+PLAN_ID: other'))
        self.invoke('convert', result['idea_id'], success=False)

    def test_crash_after_new_before_identity_headers(self):
        real_atomic = ideas.atomic
        def interrupt(path, expected, content, source=False):
            if path.name == 'plan.org':
                raise OSError('injected interruption after new')
            return real_atomic(path, expected, content, source)
        with patch.object(ideas, 'atomic', side_effect=interrupt):
            self.invoke('convert', 'A small idea', success=False)
        entry = ideas.inventory(self.source.read_text())[0]
        retry = self.invoke('convert', entry['id'])
        self.assertEqual(retry['outcome'], 'existing')
        self.assertIn('[idea:' + entry['id'] + ']', Path(retry['plan_path']).read_text())
        self.invoke('reconcile', entry['id'])
        self.assertEqual(len(list((self.root / '.plans').glob('*/plan.org'))), 1)
        self.invoke('publish', entry['id'], '--expect', retry['source_sha256'], success=False)

    def test_crash_after_reservation_before_new(self):
        real_plans = ideas.plans
        def interrupt(args, *command):
            if command[0] == 'new':
                raise OSError('injected creation failure')
            return real_plans(args, *command)
        with patch.object(ideas, 'plans', side_effect=interrupt):
            self.invoke('convert', 'A small idea', success=False)
        entry = ideas.inventory(self.source.read_text())[0]
        self.invoke('reconcile', entry['id'], success=False)
        self.assertEqual(self.invoke('convert', entry['id'])['outcome'], 'created')

    def test_crash_before_source_link(self):
        real_atomic = ideas.atomic
        def interrupt(path, expected, content, source=False):
            if source and ':IDEA_PLAN_FILE:' in content:
                raise OSError('injected source-link failure')
            return real_atomic(path, expected, content, source)
        with patch.object(ideas, 'atomic', side_effect=interrupt):
            self.invoke('convert', 'A small idea', success=False)
        entry = ideas.inventory(self.source.read_text())[0]
        existing = self.invoke('reconcile', entry['id'])
        self.draft(existing)
        published = self.invoke('reconcile', entry['id'], '--publish', '--expect', existing['source_sha256'])
        self.assertEqual(published['state'], 'PLANNED')

    def test_questions_stale_edits_and_editor_locks(self):
        result = self.prepared()
        self.source.write_text(self.source.read_text() + '\n')
        self.invoke('needs-input', result['idea_id'], '--expect', result['source_sha256'], '--question', 'Which API?', success=False)
        current = ideas.digest(self.source.read_text())
        result = self.invoke('needs-input', result['idea_id'], '--expect', current, '--question', 'Which API?')
        self.assertEqual(result['state'], 'NEEDS-INPUT')
        lock = self.source.with_name('.#ideas.org')
        lock.symlink_to('nonexistent-editor-owner')
        self.invoke('list', success=False)
        lock.unlink()
        with self.assertRaises(ValueError):
            ideas.atomic(self.source, 'stale', 'replacement', source=True)

    def test_declined_never_converted(self):
        self.source.write_text('* Ideas\n** DECLINED No thanks\n')
        self.invoke('convert', 'No thanks', success=False)
        self.assertFalse((self.root / '.plans').exists())

    def test_conflicting_source_and_reserved_identity(self):
        result = self.prepared()
        path = Path(result['plan_path'])
        path.write_text(path.read_text().replace('#+SOURCE_IDEA_ID: ' + result['idea_id'], '#+SOURCE_IDEA_ID: alien'))
        self.invoke('reconcile', result['idea_id'], success=False)

    def test_central_store_creation_and_reconciliation(self):
        store = self.base / 'private-store'
        store.mkdir()
        self.config.write_text(json.dumps({'store': str(store), 'projects': {'example': {'checkouts': [str(self.root)]}}}))
        common = self.common[:-1]
        created = self.invoke('convert', 'A small idea', common=common)
        self.assertTrue(Path(created['plan_path']).is_relative_to(store))
        self.draft(created)
        published = self.invoke('publish', created['idea_id'], '--expect', created['source_sha256'], common=common)
        self.assertEqual(published['state'], 'PLANNED')
        self.assertFalse((self.root / '.plans').exists())

    def test_metadata_preserves_properties_planning_blocks_and_tags(self):
        self.source.write_text('* Ideas\n** QUEUED [#A] Existing :tag:\nSCHEDULED: <2026-11-08 Sun>\n:PROPERTIES:\n:ID: established-org-id\n:CUSTOM:  exact spacing  \n:END:\n#+begin_src org\n:PROPERTIES:\n** Not an idea\n#+end_src\n')
        original = self.source.read_text()
        created = self.invoke('convert', 'Existing')
        self.assertEqual(created['idea_id'], 'established-org-id')
        self.assertIn(':CUSTOM:  exact spacing  \n', self.source.read_text())
        self.assertIn(original.split('#+begin_src', 1)[1], self.source.read_text())
        self.assertIn('** QUEUED [#A] Existing :tag:\nSCHEDULED:', self.source.read_text())
        self.draft(created)
        self.invoke('publish', created['idea_id'], '--expect', created['source_sha256'])
        self.assertIn('** PLANNED [#A] Existing :tag:\nSCHEDULED:', self.source.read_text())

    def test_actual_plans_validation_failure_is_retained(self):
        created = self.prepared()
        path = self.draft(created)
        text = path.read_text()
        text = text.replace('#+PLAN_CREATED:', '#+BROKEN_CREATED:')
        path.write_text(text)
        failed = self.invoke('publish', created['idea_id'], '--expect', created['source_sha256'], success=False)
        self.assertIn('missing PLAN_CREATED', failed['error'])
        self.assertTrue(path.exists())
        self.assertNotIn('** PLANNED ', self.source.read_text())

    def test_cancelled_handoff_is_existing_not_requeued(self):
        created = self.prepared()
        path = self.draft(created)
        published = self.invoke('publish', created['idea_id'], '--expect', created['source_sha256'])
        path.write_text(path.read_text().replace('#+PLAN_STATUS: draft', '#+PLAN_STATUS: cancelled').replace('- Plan status: draft', '- Plan status: cancelled') + '\nCancelled explicitly for this fixture.\n')
        existing = self.invoke('convert', created['idea_id'])
        self.assertEqual(existing['outcome'], 'existing')
        self.assertEqual(existing['state'], 'PLANNED')
        self.assertEqual(self.invoke('next', '--unattended')['outcome'], 'no-op')
        self.assertEqual(self.invoke('publish', created['idea_id'], '--expect', published['source_sha256'])['outcome'], 'existing')

    def test_wrong_plan_source_file_cannot_publish(self):
        created = self.prepared()
        path = self.draft(created)
        path.write_text(path.read_text().replace('#+SOURCE_IDEA_FILE: ' + str(self.source), '#+SOURCE_IDEA_FILE: /other/ideas.org'))
        self.invoke('publish', created['idea_id'], '--expect', created['source_sha256'], success=False)

    def test_process_lock_released_on_death_and_competing_conversions(self):
        # Hold a real flock in a separate process, then kill it. Stale metadata
        # is deliberately retained: the kernel lock, not a timestamp, is authority.
        code = "import fcntl,sys,time; f=open(sys.argv[1],'a+'); fcntl.flock(f,fcntl.LOCK_EX); print('locked',flush=True); time.sleep(60)"
        lock = self.source.with_name('.ideas.org.idea-to-plan.lock')
        owner = subprocess.Popen([sys.executable, '-c', code, str(lock)], stdout=subprocess.PIPE, text=True)
        self.addCleanup(lambda: owner.poll() is None and owner.kill())
        self.assertEqual(owner.stdout.readline().strip(), 'locked')
        self.invoke('convert', 'A small idea', success=False)
        owner.kill()
        owner.wait()
        owner.stdout.close()
        commands = [sys.executable, str(SCRIPT)] + self.common + ['convert', 'A small idea']
        workers = [subprocess.Popen(commands, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(2)]
        results = [json.loads(p.communicate(timeout=30)[0]) for p in workers]
        self.assertEqual(sum(r['outcome'] == 'created' for r in results), 1, results)
        self.assertEqual(len(list((self.root / '.plans').glob('*/plan.org'))), 1)
        self.assertEqual(self.invoke('convert', 'A small idea')['outcome'], 'existing')


if __name__ == '__main__':
    unittest.main()
