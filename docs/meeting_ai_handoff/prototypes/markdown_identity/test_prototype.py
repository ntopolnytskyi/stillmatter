"""Behavioral tests of the disposable ticket-04 contract (not production tests)."""
import copy
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from prototype import (CanonicalWorkspace, Conflict, Interrupted, Journal, adopt,
                       dumps, legacy_reviews, parse_items, parse_transcript_text,
                       plan_legacy, reconcile_transcript, transcript_text)

DOORWAY = '''---
schema_version: 1
type: meeting
title: Планування
started_at: 2026-01-01T00:00:00Z
capture_session_id: fixture-ready
capture: stopped
---
# Планування

## Processing

- [x] Capture stopped

## Live notes

Залишити мої слова. English too.
- [ ] Надіслати підсумок #робота
- [ ] Надіслати підсумок #робота

## Related

[[Projects/General]]
'''
TODO = '''# Todos

## Queue

- [ ] Edited recap due: 2026-01-10 [[Meetings/ready/summary#My action items|ref]]
  Keep the user's comment.
- [B] Blocked personal task

## Done

- [x] Finished recap done: 2026-01-02 [[Meetings/ready/summary#My action items|ref]]
'''
EXTRACTION = {
    'schema_version': 1, 'meeting': 'Meetings/ready/meeting.md',
    'transcript': 'Meetings/ready/transcript.json', 'decisions': [],
    'my_action_items': [
        {'id': 'send-recap', 'text': 'Original generated recap',
         'citations': [{'segment_id': 's1', 'start_seconds': 4, 'end_seconds': 5}]},
        {'id': 'pending', 'text': 'Unreviewed task', 'citations': []},
        {'id': 'dismiss', 'text': 'Rejected task', 'citations': []}],
    'other_action_items': [], 'open_questions': [],
}
TRANSCRIPT = {
    'schema_version': 1, 'capture_session_id': 'fixture-ready',
    'meeting_relative_path': 'Meetings/ready/meeting.md',
    'language': 'en', 'detected_languages': ['uk', 'en'],
    'engine': 'fixture', 'model': 'fixture', 'generated_at': '2026-01-01T00:00:00Z',
    'audio_sources': [], 'diagnostics': [],
    'segments': [
        {'id': 's1', 'start': 4.125, 'end': 5.225, 'text': 'Підсумок\tplease.\nNew line',
         'language': 'uk', 'track': 'microphone', 'speaker': 'Me'},
        {'id': 's2', 'start': 4.5, 'end': 7, 'text': 'Так, домовились.',
         'language': 'uk', 'track': 'system-audio', 'speaker': 'Олена'},
    ],
}


class WorkspaceCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='stillmatter-prototype-04-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'workspace'
        self.support = Path(self.temporary.name) / 'support'
        self.root.mkdir()
        self.support.mkdir()
        self.workspace = CanonicalWorkspace(self.root, self.support)

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def seed_legacy(self):
        self.write('Meetings/ready/meeting.md', DOORWAY)
        self.write('Todos/todo.md', TODO)
        self.write('Meetings/ready/archive.json', '{"archived":true}')
        self.write('Meetings/ready/summary-extraction.json', dumps(EXTRACTION))
        self.write('Meetings/ready/transcript.json', dumps(TRANSCRIPT))
        self.write('Meetings/ready/transcript.md', '# Transcript\n\nLegacy plain text.\n')
        db = self.support / 'operational.sqlite'
        with closing(sqlite3.connect(db)) as connection:
            # Exact proposal_reviews fields from TasksInbox.migrate().
            connection.execute('''CREATE TABLE proposal_reviews (
                proposal_id TEXT PRIMARY KEY NOT NULL, state TEXT NOT NULL,
                suppression_key TEXT NOT NULL, source_ref TEXT NOT NULL,
                title TEXT NOT NULL, updated_at TEXT NOT NULL)''')
            for suffix, state, title in (
                    ('send-recap', 'accepted', 'Original generated recap'),
                    ('pending', 'pending', 'Edited pending task'),
                    ('dismiss', 'dismissed', 'Rejected task'),
                    ('reference', 'referenceOnly', 'Other person task'),
                    ('merged', 'merged', 'Previously merged task')):
                proposal = 'meeting-action:fixture-ready:' + suffix
                connection.execute('INSERT INTO proposal_reviews VALUES (?,?,?,?,?,?)',
                                   (proposal, state, proposal,
                                    '[[Meetings/ready/summary#My action items|ref]]', title,
                                    '2026-01-02T00:00:00Z'))
            connection.commit()
        return db


class CanonicalIdentityTests(WorkspaceCase):
    def test_unicode_duplicate_text_has_distinct_stable_ids_after_text_and_line_edits(self):
        text = adopt('Проза\n- [ ] Підсумок #робота\n- [ ] Підсумок #робота\n')
        items = parse_items(text)
        self.assertNotEqual(items[0]['meta']['id'], items[1]['meta']['id'])
        self.assertEqual(adopt(text), text)
        externally_edited = '# External heading\n' + text.replace('Підсумок', 'Reworded')
        revised = parse_items(externally_edited)
        self.assertEqual([item['meta']['id'] for item in items], [item['meta']['id'] for item in revised])
        self.assertEqual(revised[0]['tags'], ['#робота'])
        self.assertEqual(revised[0]['meta']['review'], 'approved')
        self.assertEqual(revised[0]['meta']['owner'], 'me')

    def test_projection_edit_completion_reassignment_and_removal_use_same_checkbox(self):
        path = self.write('Meetings/one/my-notes.md', adopt('- [ ] Task #work\n'))
        item_id = parse_items(path.read_text())[0]['meta']['id']
        ids = [item_id]
        self.workspace.edit(item_id, path.read_text(), text='Edited task #work #review', marker='x')
        meeting, todo = self.workspace.meeting_view(ids), self.workspace.todo_view(ids)
        self.assertEqual(meeting, todo)
        self.assertEqual(todo[0]['marker'], 'x')
        self.assertIn('Edited task', path.read_text())
        self.assertEqual(len(self.workspace.catalog()), 1)
        self.workspace.edit(item_id, path.read_text(), owner='person-Олена')
        self.assertEqual(self.workspace.todo_view(ids), [])
        self.assertEqual(self.workspace.meeting_view(ids)[0]['meta']['owner'], 'person-Олена')
        path.write_text('Task explicitly removed by external editor.\n')
        self.assertEqual(self.workspace.meeting_view(ids), [])
        self.assertEqual(self.workspace.todo_view(ids), [])

    def test_identity_resolves_after_meeting_folder_title_rename_without_alias(self):
        path = self.write('Meetings/old/my-notes.md', adopt('- [ ] One\n'))
        item_id = parse_items(path.read_text())[0]['meta']['id']
        path.parent.rename(path.parent.with_name('Новий-title'))
        self.assertFalse(path.exists())
        self.workspace.edit(item_id, self.workspace.catalog()[item_id][0].read_text(), marker='x')
        self.assertEqual(self.workspace.todo_view([item_id])[0]['marker'], 'x')

    def test_tags_cannot_grant_pending_generated_item_approval(self):
        path = self.write('Meetings/one/action-items.md', adopt('- [ ] Unconfirmed #ai-gen #need-approve\n', origin='generated'))
        item_id = parse_items(path.read_text())[0]['meta']['id']
        path.write_text(path.read_text().replace(' #need-approve', ''))
        self.assertEqual(self.workspace.todo_view([item_id]), [])
        self.assertEqual(self.workspace.meeting_view([item_id])[0]['meta']['review'], 'pending')

    def test_malformed_metadata_and_duplicate_ids_do_not_silently_repair(self):
        text = adopt('- [ ] One\n')
        with self.assertRaises(ValueError):
            parse_items(text + text)
        with self.assertRaises(ValueError):
            parse_items('- [ ] One <!-- sm-item:broken\n')
        with self.assertRaises(json.JSONDecodeError):
            parse_items('- [ ] One <!-- sm-item:broken -->\n')
        self.write('one.md', text)
        self.write('two.md', text)
        with self.assertRaises(ValueError):
            self.workspace.catalog()

    def test_conflict_preserves_external_file_base_and_local_draft_across_reopen(self):
        path = self.write('Meetings/one/my-notes.md', adopt('Проза\n- [ ] Task #work\n'))
        base = path.read_text()
        item_id = parse_items(base)[0]['meta']['id']
        external = base.replace('Проза', 'External prose').replace('#work', '#external')
        path.write_text(external)
        with self.assertRaises(Conflict) as raised:
            self.workspace.edit(item_id, base, text='Unsaved local task #local')
        reopened = CanonicalWorkspace(self.root, self.support)
        self.assertEqual(path.read_text(), external)
        record = json.loads(Path(str(raised.exception)).read_text())
        self.assertEqual(record['external'], external)
        self.assertEqual(record['base'], base)
        self.assertIn('Unsaved local task #local', record['draft'])
        self.assertIn('External prose', reopened.catalog()[item_id][0].read_text())

    def test_markdown_unicode_separators_and_crlf_survive_adoption_and_edit(self):
        raw = 'Проза\u2028рядок\u2029\r\n- [ ] Task\u2028continued\u2029 #робота\r\n'
        adopted = adopt(raw)
        self.assertTrue(adopted.startswith('Проза\u2028рядок\u2029\r\n'))
        self.assertEqual(adopted.count('\r\n'), 2)
        self.assertEqual(adopt(adopted), adopted)
        item = parse_items(adopted)[0]
        self.assertEqual(item['text'], 'Task\u2028continued\u2029 #робота')
        path = self.write('Meetings/one/my-notes.md', adopted)
        self.workspace.edit(item['meta']['id'], adopted, marker='x')
        actual = path.read_bytes().decode('utf-8')
        self.assertEqual(actual.count('\r\n'), 2)
        self.assertEqual(parse_items(actual)[0]['text'], item['text'])
        self.assertEqual(parse_items(actual)[0]['meta']['id'], item['meta']['id'])

    def test_conflict_draft_keeps_base_text_owner_and_state_without_external_merge(self):
        path = self.write('Meetings/one/my-notes.md', adopt('- [ ] Local base #work\n'))
        base = path.read_text()
        item_id = parse_items(base)[0]['meta']['id']
        self.workspace.edit(item_id, base, text='External task #external', marker='x', owner='person-external')
        external = path.read_text()
        with self.assertRaises(Conflict) as raised:
            self.workspace.edit(item_id, base, text='Unsaved local task #local')
        record = json.loads(Path(str(raised.exception)).read_text())
        local = parse_items(record['draft'])[0]
        self.assertEqual(local['text'], 'Unsaved local task #local')
        self.assertEqual(local['marker'], ' ')
        self.assertEqual(local['meta']['owner'], 'me')
        self.assertEqual(record['external'], external)
        self.assertEqual(path.read_text(), external)

    def test_external_checkbox_or_file_deletion_preserves_unsaved_draft(self):
        for delete_file in (False, True):
            with self.subTest(delete_file=delete_file):
                relative = 'Meetings/one/my-notes.md'
                path = self.write(relative, adopt('- [ ] Local base\n'))
                base = path.read_text()
                item_id = parse_items(base)[0]['meta']['id']
                if delete_file:
                    path.unlink()
                else:
                    path.write_text('External removal of checkbox.\n')
                with self.assertRaises(Conflict) as raised:
                    self.workspace.edit(item_id, base, text='Unsaved draft', relative_path=relative)
                record = json.loads(Path(str(raised.exception)).read_text())
                self.assertEqual(parse_items(record['draft'])[0]['text'], 'Unsaved draft')
                self.assertEqual(record['base'], base)
                self.assertEqual(record['external'], None if delete_file else 'External removal of checkbox.\n')
                self.assertEqual(path.exists(), not delete_file)

    def test_read_does_not_invent_ids_or_write_files_and_adoption_keeps_prose(self):
        raw = '  Prose  \n\n* [B] Task\n'
        path = self.write('Meetings/one/my-notes.md', raw)
        self.assertEqual(parse_items(raw)[0]['meta']['id'], None)
        self.assertEqual(self.workspace.catalog(), {})
        self.assertEqual(path.read_text(), raw)
        changed = adopt(raw)
        self.assertTrue(changed.startswith('  Prose  \n\n* [B]'))
        self.assertEqual(parse_items(changed)[0]['marker'], 'b')


class MigrationTests(WorkspaceCase):
    def plan(self, **kwargs):
        db = self.seed_legacy()
        return plan_legacy(self.root, 'Meetings/ready/meeting.md', legacy_reviews(db), EXTRACTION, **kwargs)

    def test_migration_preserves_edited_completed_accepted_todos_notes_and_review_history(self):
        outputs = self.plan()
        journal = Journal(self.root, self.support)
        journal.prepare(outputs)
        journal.commit()
        actions_path = self.root / 'Meetings/ready/action-items.md'
        actions = parse_items(actions_path.read_text())
        self.assertEqual([item['marker'] for item in actions], [' ', 'x', ' '])
        self.assertIn('Edited recap due: 2026-01-10', actions[0]['text'])
        self.assertIn("Keep the user's comment.", actions_path.read_text())
        self.assertIn('Finished recap done: 2026-01-02', actions[1]['text'])
        self.assertEqual(actions[2]['text'], 'Edited pending task #ai-gen #need-approve')
        notes = (self.root / 'Meetings/ready/my-notes.md').read_text()
        self.assertIn('Залишити мої слова. English too.', notes)
        self.assertEqual(len(parse_items(notes)), 2)
        self.assertIn('## Related\n\n[[Projects/General]]', (self.root / 'Meetings/ready/meeting.md').read_text())
        todo = (self.root / 'Todos/todo.md').read_text()
        self.assertIn('- [B] Blocked personal task', todo)
        self.assertNotIn('- [ ] Edited recap', todo)
        for item in actions[:2]:
            self.assertIn('[[item:' + item['meta']['id'], todo)
            self.assertEqual(item['meta']['review'], 'approved')
            self.assertEqual(item['meta']['source_refs'], ['Meetings/ready/summary#My action items|ref'])
        history = json.loads((self.root / 'Meetings/ready/legacy-review-history.json').read_text())
        self.assertEqual({row['state'] for row in history}, {'accepted', 'pending', 'dismissed', 'referenceOnly', 'merged'})
        self.assertEqual(history[0]['outcome']['citations'][0]['segment_id'], 's1')
        self.assertIn('unresolved', history[0])
        self.assertEqual(len(history[0]['candidate_item_ids']), 2)
        metadata = json.loads((self.root / 'Meetings/ready/meeting-metadata.json').read_text())
        self.assertTrue(metadata['archived'])
        self.assertIsNone(metadata['archived_at'])
        self.assertFalse(metadata['evidence_cleanup_eligible'])
        self.assertTrue(metadata['archive_date_requires_review'])
        self.assertEqual((self.root / 'Meetings/ready/archive.json').read_text(), '{"archived":true}')

    def test_explicit_legacy_binding_preserves_same_item_id_without_text_matching(self):
        outputs = self.plan(confirmed_bindings={'meeting-action:fixture-ready:send-recap': 4})
        history = json.loads(outputs['Meetings/ready/legacy-review-history.json'])
        actions = parse_items(outputs['Meetings/ready/action-items.md'])
        self.assertEqual(history[0]['canonical_item_id'], actions[0]['meta']['id'])
        self.assertNotIn('unresolved', history[0])
        self.assertNotEqual(actions[0]['text'], history[0]['title'])
        self.assertEqual(len(actions), 3)

    def test_every_between_file_crash_recovers_same_outputs_and_no_duplicate_checkboxes(self):
        outputs = self.plan()
        journal = Journal(self.root, self.support)
        journal.prepare(outputs)
        originals = {entry['path']: entry['old'] for entry in json.loads(journal.path.read_text())['entries']}
        for crash_after in range(1, len(outputs) + 1):
            # Simulated new process reads only durable journal; never reruns ID allocation.
            with self.assertRaises(Interrupted):
                Journal(self.root, self.support).commit(interrupt_after=crash_after)
            self.assertFalse(Journal(self.root, self.support).visible_new())
            manifest = json.loads(journal.path.read_text())
            self.assertEqual({entry['path']: entry['old'] for entry in manifest['entries']}, originals)
        Journal(self.root, self.support).commit()
        self.assertTrue(Journal(self.root, self.support).visible_new())
        for relative, expected in outputs.items():
            self.assertEqual((self.root / relative).read_text(), expected)
        before = {relative: (self.root / relative).read_bytes() for relative in outputs}
        Journal(self.root, self.support).commit()
        self.assertEqual(before, {relative: (self.root / relative).read_bytes() for relative in outputs})
        catalog = self.workspace.catalog()
        self.assertEqual(len(catalog), 5)

    def test_interrupted_migration_can_restore_exact_legacy_bytes(self):
        outputs = self.plan()
        journal = Journal(self.root, self.support)
        journal.prepare(outputs)
        with self.assertRaises(Interrupted):
            journal.commit(interrupt_after=3)
        Journal(self.root, self.support).rollback()
        self.assertEqual((self.root / 'Meetings/ready/meeting.md').read_text(), DOORWAY)
        self.assertEqual((self.root / 'Todos/todo.md').read_text(), TODO)
        self.assertFalse((self.root / 'Meetings/ready/my-notes.md').exists())
        self.assertFalse(journal.visible_new())
        with self.assertRaises(ValueError):
            journal.commit()

    def test_external_source_edits_or_created_output_invalidate_plan_before_prepare(self):
        self.seed_legacy()
        for relative in ('Todos/todo.md', 'Meetings/ready/meeting.md',
                         'Meetings/ready/archive.json', 'Meetings/ready/my-notes.md'):
            with self.subTest(relative=relative):
                outputs = plan_legacy(self.root, 'Meetings/ready/meeting.md', [], EXTRACTION)
                planned = dict(outputs)
                path = self.root / relative
                original = path.read_bytes() if path.exists() else b''
                external = original + b'\nExternal edit after planning\n'
                path.write_bytes(external)
                journal = Journal(self.root, self.support)
                before = {str(file.relative_to(self.root)): file.read_bytes()
                          for file in self.root.rglob('*') if file.is_file()}
                with self.assertRaisesRegex(Conflict, 'plan is stale'):
                    journal.prepare(outputs)
                self.assertFalse(journal.path.exists())
                self.assertFalse(journal.visible_new())
                self.assertEqual(dict(outputs), planned)  # Caller retains complete intended draft.
                self.assertEqual(before, {str(file.relative_to(self.root)): file.read_bytes()
                                         for file in self.root.rglob('*') if file.is_file()})
                if relative == 'Meetings/ready/my-notes.md':
                    path.unlink()
                else:
                    path.write_bytes(original)

    def test_non_output_archive_dependency_change_after_prepare_blocks_commit(self):
        outputs = self.plan()
        journal = Journal(self.root, self.support)
        journal.prepare(outputs)
        archive = self.root / 'Meetings/ready/archive.json'
        archive.write_text('{"archived":false}')
        with self.assertRaisesRegex(Conflict, 'dependency changed'):
            journal.commit()
        self.assertFalse(journal.visible_new())
        self.assertEqual(archive.read_text(), '{"archived":false}')
        self.assertEqual((self.root / 'Todos/todo.md').read_text(), TODO)
        self.assertEqual((self.root / 'Meetings/ready/meeting.md').read_text(), DOORWAY)

    def test_crlf_legacy_files_rollback_byte_exact_after_reopen(self):
        self.seed_legacy()
        originals = {}
        for relative in ('Meetings/ready/meeting.md', 'Todos/todo.md'):
            path = self.root / relative
            original = path.read_text().replace('\n', '\r\n').encode('utf-8')
            path.write_bytes(original)
            originals[relative] = original
        outputs = plan_legacy(self.root, 'Meetings/ready/meeting.md', [], EXTRACTION)
        self.assertIn('Залишити мої слова.', outputs['Meetings/ready/my-notes.md'])
        self.assertEqual(len(parse_items(outputs['Meetings/ready/my-notes.md'])), 2)
        journal = Journal(self.root, self.support)
        journal.prepare(outputs)
        with self.assertRaises(Interrupted):
            journal.commit(interrupt_after=3)
        Journal(self.root, self.support).rollback()
        for relative, original in originals.items():
            self.assertEqual((self.root / relative).read_bytes(), original)

    def test_external_edit_during_partial_migration_blocks_retry_preserving_all_versions(self):
        outputs = self.plan()
        journal = Journal(self.root, self.support)
        journal.prepare(outputs)
        with self.assertRaises(Interrupted):
            journal.commit(interrupt_after=1)
        path = self.root / 'Meetings/ready/meeting.md'
        external = path.read_text() + '\nExternal concurrent edit\n'
        path.write_text(external)
        with self.assertRaises(Conflict):
            Journal(self.root, self.support).commit()
        self.assertEqual(path.read_text(), external)
        entry = json.loads(journal.path.read_text())['entries'][0]
        self.assertEqual(entry['old'], DOORWAY)
        self.assertEqual(entry['new'], outputs['Meetings/ready/meeting.md'])
        with self.assertRaises(Conflict):
            journal.rollback()
        self.assertFalse(journal.visible_new())

    def test_scoped_sqlite_reader_never_imports_another_workspace_or_unowned_reviews(self):
        db = self.seed_legacy()
        prefix = 'owner:' + str(self.root.resolve()).encode().hex() + ':'
        other = 'owner:' + str(self.root.parent / 'other').encode().hex() + ':'
        with closing(sqlite3.connect(db)) as connection:
            for owner in (prefix, other):
                connection.execute('INSERT INTO proposal_reviews VALUES (?,?,?,?,?,?)',
                                   (owner + 'one', 'accepted', 'one', '[[source]]', 'Scoped', 'now'))
            connection.commit()
        self.assertEqual(len(legacy_reviews(db)), 5)
        scoped = legacy_reviews(db, workspace=self.root)
        self.assertEqual([row['proposal_id'] for row in scoped], ['one'])

    def test_nested_tasks_do_not_silently_flatten_or_lose_children(self):
        self.seed_legacy()
        path = self.root / 'Todos/todo.md'
        path.write_text(TODO.replace("  Keep the user's comment.", '  - [ ] Child task'))
        with self.assertRaisesRegex(ValueError, 'Nested task block'):
            plan_legacy(self.root, 'Meetings/ready/meeting.md', [], EXTRACTION)
        self.assertIn('Child task', path.read_text())

    def test_journal_rejects_paths_outside_disposable_workspace(self):
        with self.assertRaisesRegex(ValueError, 'escapes workspace'):
            Journal(self.root, self.support).prepare({'../outside': 'bad'})
        self.assertFalse((self.root.parent / 'outside').exists())


class TranscriptTests(WorkspaceCase):
    def test_old_json_new_text_round_trip_keeps_original_fractional_timing_overlap_unicode(self):
        text = transcript_text(TRANSCRIPT)
        self.assertIn('Так, домовились.', text)
        self.assertEqual(parse_transcript_text(text), TRANSCRIPT)
        self.assertEqual(transcript_text(parse_transcript_text(text)), text)
        self.assertEqual(parse_transcript_text(text)['segments'][0]['start'], 4.125)

    def test_unicode_line_and_paragraph_separators_round_trip_inside_cells_and_metadata(self):
        document = copy.deepcopy(TRANSCRIPT)
        document['diagnostics'] = ['Metadata line\u2028separator and paragraph\u2029separator']
        document['segments'][0]['text'] = 'Text line\u2028separator and paragraph\u2029separator'
        document['segments'][1]['speaker'] = 'Олена\u2028Петренко\u2029'
        document['segments'][1]['annotation'] = {'note': 'Extension\u2028metadata\u2029'}
        text = transcript_text(document)
        self.assertIn('\u2028', text)
        self.assertIn('\u2029', text)
        self.assertEqual(parse_transcript_text(text), document)
        self.assertEqual(parse_transcript_text(text.removesuffix('\n')), document)
        self.assertEqual(transcript_text(parse_transcript_text(text)), text)

    def test_segment_person_identity_and_attribution_survive_display_name_change(self):
        document = copy.deepcopy(TRANSCRIPT)
        document['segments'][1].update(person_id='person-stable-id', attribution='user-confirmed')
        updated = parse_transcript_text(transcript_text(document))
        updated['segments'][1]['speaker'] = 'New display name'
        restored = parse_transcript_text(transcript_text(updated))
        self.assertEqual(restored['segments'][1]['id'], 's2')
        self.assertEqual(restored['segments'][1]['person_id'], 'person-stable-id')
        self.assertEqual(restored['segments'][1]['attribution'], 'user-confirmed')
        self.assertEqual(restored['segments'][1]['start'], 4.5)

    def test_valid_external_edit_of_either_representation_updates_one_logical_transcript(self):
        updated = copy.deepcopy(TRANSCRIPT)
        updated['segments'][0]['text'] = 'Corrected Українська.'
        text, structured = reconcile_transcript(TRANSCRIPT, transcript_text(updated), dumps(TRANSCRIPT))
        self.assertEqual(parse_transcript_text(text), updated)
        self.assertEqual(json.loads(structured), updated)
        updated['segments'][1]['speaker'] = 'Олена Петренко'
        text, structured = reconcile_transcript(TRANSCRIPT, transcript_text(TRANSCRIPT), dumps(updated))
        self.assertEqual(parse_transcript_text(text), updated)
        self.assertEqual(json.loads(structured), updated)

    def test_same_concurrent_edit_converges_different_concurrent_edits_are_preserved(self):
        first, second = copy.deepcopy(TRANSCRIPT), copy.deepcopy(TRANSCRIPT)
        first['segments'][0]['text'] = 'Text editor version'
        second['segments'][0]['text'] = 'JSON editor version'
        text_path = self.write('Meetings/one/transcript.txt', transcript_text(first))
        json_path = self.write('Meetings/one/transcript.json', dumps(second))
        before = (text_path.read_text(), json_path.read_text())
        with self.assertRaises(Conflict):
            reconcile_transcript(TRANSCRIPT, *before)
        self.assertEqual((text_path.read_text(), json_path.read_text()), before)
        text, structured = reconcile_transcript(TRANSCRIPT, transcript_text(first), dumps(first))
        self.assertEqual(parse_transcript_text(text), json.loads(structured))

    def test_invalid_timing_duplicate_id_malformed_rows_fail_without_guessing_alignment(self):
        for invalid in (-1, float('inf'), float('nan'), True):
            document = copy.deepcopy(TRANSCRIPT)
            document['segments'][0]['start'] = invalid
            with self.assertRaises(ValueError):
                transcript_text(document)
        document = copy.deepcopy(TRANSCRIPT)
        document['segments'][1]['id'] = 's1'
        with self.assertRaises(ValueError):
            transcript_text(document)
        with self.assertRaises(ValueError):
            parse_transcript_text('Stillmatter Transcript v2\n')
        with self.assertRaises(ValueError):
            parse_transcript_text('# Transcript\nFree prose with no stable timing metadata')
        with self.assertRaises(ValueError):
            parse_transcript_text(transcript_text(TRANSCRIPT).replace('\ttext\textra', '\ttext'))

    def test_transcript_pair_publication_is_recoverable_after_first_replacement(self):
        text = transcript_text(TRANSCRIPT)
        journal = Journal(self.root, self.support)
        journal.prepare({'Meetings/one/transcript.txt': text,
                         'Meetings/one/transcript.json': dumps(TRANSCRIPT)})
        with self.assertRaises(Interrupted):
            journal.commit(interrupt_after=1)
        self.assertFalse(journal.visible_new())
        Journal(self.root, self.support).commit()
        self.assertTrue(journal.visible_new())
        self.assertEqual(parse_transcript_text((self.root / 'Meetings/one/transcript.txt').read_text()),
                         json.loads((self.root / 'Meetings/one/transcript.json').read_text()))


if __name__ == '__main__':
    unittest.main()
