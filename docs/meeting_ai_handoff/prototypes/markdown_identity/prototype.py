#!/usr/bin/env python3
"""DISPOSABLE ticket-04 experiment. No imports from, or effects on, the shipped app.

Run `python3 -m unittest discover -s <this-directory> -v`.
All persistent operations require caller-owned disposable workspace/support roots.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import uuid

CHECKBOX = re.compile(r'^(\s*[-*]\s+\[)([ xXbBcC])(\]\s+)(.*)$')
META = re.compile(r'\s*<!-- sm-item:(.*?) -->\s*$')
TAGS = re.compile(r'(?<!\S)#[\w-]+', re.UNICODE)
LINK = re.compile(r'\[\[([^\]]+)\]\]')
NAMESPACE = uuid.UUID('3140f666-0256-4c44-b480-8036f696604e')


def dumps(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def stable(seed):
    """Only migration uses deterministic IDs, from captured immutable old locations."""
    return str(uuid.uuid5(NAMESPACE, seed))


def atomic_write(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.prototype-new')
    with temp.open('w', encoding='utf-8') as file:
        file.write(text)
        file.flush()
        os.fsync(file.fileno())
    os.replace(temp, path)
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def read_optional(path):
    return path.read_text() if path.exists() else None


def within(root, relative):
    target = (Path(root) / relative).resolve()
    if not target.is_relative_to(Path(root).resolve()):
        raise ValueError('Reference escapes workspace')
    return target


class Conflict(Exception):
    pass


class Interrupted(Exception):
    pass


def parse_items(markdown, origin='note', allocate=None):
    """Read without mutating. Missing IDs are unadopted until an explicit save."""
    items, seen = [], set()
    for number, line in enumerate(markdown.splitlines()):
        match = CHECKBOX.fullmatch(line)
        if not match:
            continue
        body = match[4]
        meta_match = META.search(body)
        if '<!-- sm-item:' in body and not meta_match:
            raise ValueError('Malformed item metadata')
        meta = json.loads(meta_match[1]) if meta_match else {
            'v': 1, 'id': allocate(number) if allocate else None,
            'owner': 'me' if origin == 'note' else None,
            'review': 'approved' if origin == 'note' else 'pending', 'origin': origin,
        }
        if not isinstance(meta, dict) or meta.get('v') != 1:
            raise ValueError('Unsupported metadata version')
        if meta.get('id') is not None:
            uuid.UUID(meta['id'])
            if meta['id'] in seen:
                raise ValueError('Duplicate item ID requires explicit repair')
            seen.add(meta['id'])
        if meta.get('review') not in ('approved', 'pending', 'rejected', 'referenceOnly'):
            raise ValueError('Invalid review')
        if meta.get('origin') not in ('note', 'generated', 'legacy-todo'):
            raise ValueError('Invalid origin')
        if meta.get('owner') is not None and not isinstance(meta['owner'], str):
            raise ValueError('Invalid owner')
        text = body[:meta_match.start()].rstrip() if meta_match else body
        tags = TAGS.findall(text)
        items.append({'line': number, 'marker': match[2].lower(), 'text': text,
                      'tags': tags, 'meta': meta})
    return items


def serialize_line(item, original_line=None):
    # Keep indentation, bullet style and spaces on lines being adopted/edited.
    old = CHECKBOX.fullmatch(original_line) if original_line else None
    prefix, suffix = (old[1], old[3]) if old else ('- [', '] ')
    marker = old[2] if old and old[2].lower() == item['marker'] else item['marker']
    return prefix + marker + suffix + item['text'] + ' <!-- sm-item:' + dumps(item['meta']) + ' -->'


def adopt(markdown, origin='note', id_seed=None):
    lines = markdown.splitlines(keepends=True)
    allocate = lambda number: stable(id_seed + ':' + str(number)) if id_seed else str(uuid.uuid4())
    for item in parse_items(markdown, origin, allocate):
        old = lines[item['line']]
        if not META.search(old.rstrip('\n')):
            ending = '\n' if old.endswith('\n') else ''
            lines[item['line']] = serialize_line(item, old.rstrip('\n')) + ending
    return ''.join(lines)


class CanonicalWorkspace:
    """Views contain only IDs. Every read/edit resolves the current canonical file."""
    def __init__(self, root, support):
        self.root, self.support = Path(root), Path(support)
        if self.root.resolve() == self.support.resolve() or self.support.resolve().is_relative_to(self.root.resolve()):
            raise ValueError('Separate support root required')

    def catalog(self):
        result = {}
        for path in self.root.rglob('*.md'):
            for item in parse_items(path.read_text()):
                item_id = item['meta']['id']
                if item_id is None:
                    continue
                if item_id in result:
                    raise ValueError('Duplicate ID across files')
                result[item_id] = (path, item)
        return result

    def meeting_view(self, ids):
        catalog = self.catalog()
        return [catalog[item_id][1] for item_id in ids if item_id in catalog]

    def todo_view(self, ids):
        return [item for item in self.meeting_view(ids)
                if item['meta']['owner'] == 'me' and item['meta']['review'] == 'approved']

    def edit(self, item_id, expected_text, *, text=None, marker=None, owner=...):
        path, item = self.catalog()[item_id]
        current = path.read_text()
        draft_item = dict(item)
        draft_item['meta'] = dict(item['meta'])
        if text is not None:
            if '\n' in text or '<!-- sm-item:' in text:
                raise ValueError('Item text cannot introduce new metadata/records')
            draft_item['text'] = text
        if marker is not None:
            if marker not in (' ', 'x', 'b', 'c'):
                raise ValueError('Invalid checkbox state')
            draft_item['marker'] = marker
        if owner is not ...:
            draft_item['meta']['owner'] = owner
        # Draft uses the caller's full base file, never a guessed merge.
        base_items = [candidate for candidate in parse_items(expected_text)
                      if candidate['meta']['id'] == item_id]
        if len(base_items) != 1:
            raise ValueError('Draft base does not identify item')
        lines = expected_text.splitlines(keepends=True)
        number = base_items[0]['line']
        lines[number] = serialize_line(draft_item, lines[number].rstrip('\n')) + ('\n' if lines[number].endswith('\n') else '')
        draft = ''.join(lines)
        if current != expected_text:
            record = {'path': str(path.relative_to(self.root)), 'base': expected_text,
                      'external': current, 'draft': draft}
            conflict_path = self.support / 'conflicts' / (str(uuid.uuid4()) + '.json')
            atomic_write(conflict_path, dumps(record))
            raise Conflict(str(conflict_path))
        atomic_write(path, draft)


class Journal:
    """Recoverable multi-file publication; readers must check the commit marker.

    Old bytes and complete intended replacements persist before the first write.
    This is an experiment in crash recovery, not a lock against arbitrary editors.
    """
    def __init__(self, root, support):
        self.root = Path(root)
        self.path = Path(support) / 'migration.json'

    def prepare(self, outputs):
        if self.path.exists():
            raise ValueError('Existing journal must be recovered first')
        entries = []
        for relative, new in outputs.items():
            old = read_optional(within(self.root, relative))
            entries.append({'path': relative, 'old': old, 'new': new})
        atomic_write(self.path, dumps({'state': 'prepared', 'entries': entries}))

    def commit(self, interrupt_after=None):
        manifest = json.loads(self.path.read_text())
        if manifest['state'] == 'committed':
            return
        if manifest['state'] != 'prepared':
            raise ValueError('Rolled-back migration cannot be recommitted')
        for index, entry in enumerate(manifest['entries']):
            path = within(self.root, entry['path'])
            current = read_optional(path)
            if current not in (entry['old'], entry['new']):
                raise Conflict('Migration left journal/backups and external file intact: ' + entry['path'])
            atomic_write(path, entry['new'])
            if interrupt_after == index + 1:
                raise Interrupted('Crash after replacement ' + str(index + 1))
        manifest['state'] = 'committed'
        atomic_write(self.path, dumps(manifest))

    def visible_new(self):
        return self.path.exists() and json.loads(self.path.read_text())['state'] == 'committed'

    def rollback(self):
        manifest = json.loads(self.path.read_text())
        if manifest['state'] == 'committed':
            raise ValueError('Rollback is only an interrupted-migration experiment')
        for entry in manifest['entries']:
            path = within(self.root, entry['path'])
            current = read_optional(path)
            if current not in (entry['old'], entry['new']):
                raise Conflict('External edit blocks rollback: ' + entry['path'])
        for entry in manifest['entries']:
            path = within(self.root, entry['path'])
            if entry['old'] is None:
                if path.exists():
                    path.unlink()
            else:
                atomic_write(path, entry['old'])
        manifest['state'] = 'rolled-back'
        atomic_write(self.path, dumps(manifest))


def legacy_reviews(database, workspace=None):
    """Read the exact existing proposal_reviews schema, without writing its DB."""
    connection = sqlite3.connect(Path(database).resolve().as_uri() + '?mode=ro', uri=True)
    connection.row_factory = sqlite3.Row
    prefix = 'owner:' + str(Path(workspace).resolve()).encode().hex() + ':' if workspace else ''
    try:
        result = []
        for row in connection.execute('SELECT proposal_id,state,suppression_key,source_ref,title,updated_at FROM proposal_reviews'):
            data = dict(row)
            if prefix:
                if not data['proposal_id'].startswith(prefix):
                    continue
                data['proposal_id'] = data['proposal_id'][len(prefix):]
            elif data['proposal_id'].startswith('owner:'):
                continue
            result.append(data)
        return result
    finally:
        connection.close()


def notes_body(doorway):
    heading = re.search(r'(?m)^## (?:Live notes|Notes)[ \t]*\n', doorway)
    if not heading:
        return '', doorway
    following = re.search(r'(?m)^## [^\n]+$', doorway[heading.end():])
    end = heading.end() + following.start() if following else len(doorway)
    # Preserve whitespace/prose verbatim. The old section becomes an explicit link.
    return doorway[heading.end():end], doorway[:heading.start()] + '## My Notes\n\n[[my-notes]]\n\n' + doorway[end:]


def legacy_title(text):
    text = re.sub(r'\s*\bdue:\s*\d{4}-\d{2}-\d{2}\b', '', text)
    text = re.sub(r'\s*\bdone:\s*\d{4}-\d{2}-\d{2}\b', '', text)
    return re.sub(r'\s+', ' ', LINK.sub('', text)).strip()


def plan_legacy(root, doorway_path, reviews, extraction, *, confirmed_bindings=None):
    """Plan first, publish with Journal. Ambiguous accepted identity is never guessed.

    confirmed_bindings maps proposal ID to original zero-based Todo line after an
    explicit migration review; neither text matching nor source section proves it.
    """
    root = Path(root)
    confirmed_bindings = confirmed_bindings or {}
    doorway = within(root, doorway_path).read_text()
    session_match = re.search(r'(?m)^capture_session_id:\s*(.+)$', doorway)
    meeting_id = session_match[1].strip() if session_match else str(uuid.uuid4())
    directory = str(Path(doorway_path).parent)
    notes, new_doorway = notes_body(doorway)
    notes = adopt(notes, id_seed=meeting_id + ':notes')
    todo_path = root / 'Todos/todo.md'
    todo = read_optional(todo_path) or ''
    todo_lines = todo.splitlines(keepends=True)
    canonical, issues, imported = [], [], {}
    source_prefix = directory + '/'
    todos = parse_items(todo, 'legacy-todo', lambda line: stable(meeting_id + ':legacy-todo:' + str(line)))
    # Move only explicitly meeting-linked top-level blocks. Preserve child/prose blocks.
    for item in todos:
        sources = LINK.findall(item['text'])
        if not any(source.split('|')[0].startswith(source_prefix) for source in sources):
            continue
        if CHECKBOX.fullmatch(todo_lines[item['line']].rstrip('\n'))[1][0].isspace():
            raise ValueError('Nested meeting-linked task requires explicit migration review')
        start = item['line']
        end = start + 1
        while end < len(todo_lines) and (not todo_lines[end].strip() or todo_lines[end][0].isspace()):
            end += 1
        block = ''.join(todo_lines[start:end])
        # Nested checkboxes are deliberately not auto-moved independently.
        if any(CHECKBOX.fullmatch(line.rstrip('\n')) for line in todo_lines[start + 1:end]):
            raise ValueError('Nested task block requires explicit migration review')
        item['meta']['review'] = 'approved'
        item['meta']['owner'] = 'me'
        item['meta']['legacy_location'] = 'Todos/todo.md:' + str(start + 1)
        item['meta']['source_refs'] = sources
        canonical.append(serialize_line(item, todo_lines[start].rstrip('\n')) + '\n' + ''.join(todo_lines[start + 1:end]))
        imported[start] = item
        todo_lines[start] = '- [[item:' + item['meta']['id'] + '|' + legacy_title(item['text']) + ']]\n'
        for number in range(start + 1, end):
            todo_lines[number] = ''
    outcomes = {row['id']: row for row in extraction.get('my_action_items', [])}
    decisions = []
    for review in reviews:
        if not review['proposal_id'].startswith('meeting-action:' + meeting_id + ':'):
            continue
        record = dict(review)
        record['outcome'] = outcomes.get(review['proposal_id'].split(':', 2)[2])
        bound = confirmed_bindings.get(review['proposal_id'])
        if review['state'] in ('accepted', 'merged'):
            if bound is not None:
                if bound not in imported:
                    raise ValueError('Binding must select an existing linked Todo')
                record['canonical_item_id'] = imported[bound]['meta']['id']
            else:
                record['candidate_item_ids'] = [item['meta']['id'] for item in imported.values()]
                record['unresolved'] = 'Legacy copy lacks proposal identity; explicit mapping required'
                issues.append(record['proposal_id'])
        elif review['state'] == 'pending':
            outcome = record['outcome']
            item = {'marker': ' ', 'text': review['title'] + ' #ai-gen #need-approve',
                    'meta': {'v': 1, 'id': stable(review['proposal_id']), 'origin': 'generated',
                             'owner': 'me', 'review': 'pending', 'legacy_proposal_id': review['proposal_id'],
                             'citations': outcome.get('citations', []) if outcome else []}}
            canonical.append(serialize_line(item) + '\n')
        decisions.append(record)
    archive = read_optional(root / directory / 'archive.json')
    metadata = {'v': 2, 'id': meeting_id, 'doorway': doorway_path, 'migration_issues': issues}
    if archive:
        archived = json.loads(archive)['archived']
        metadata.update(archived=archived, archived_at=None,
                        evidence_cleanup_eligible=False, archive_date_requires_review=archived)
    outputs = {
        doorway_path: new_doorway,
        directory + '/my-notes.md': notes,
        directory + '/action-items.md': '# Action Items\n\n' + ''.join(canonical),
        directory + '/meeting-metadata.json': dumps(metadata),
        directory + '/legacy-review-history.json': dumps(decisions),
        'Todos/todo.md': ''.join(todo_lines),
    }
    return outputs


TRANSCRIPT_HEADER = 'Stillmatter Transcript v2\n'


def validate_transcript(document):
    if document.get('schema_version') not in (1, 2) or not isinstance(document.get('segments'), list):
        raise ValueError('Unsupported Transcript')
    ids = set()
    for segment in document['segments']:
        if not isinstance(segment.get('id'), str) or not segment['id'] or segment['id'] in ids:
            raise ValueError('Invalid/duplicate segment ID')
        ids.add(segment['id'])
        start, end = segment['start'], segment['end']
        if not all(isinstance(value, (float, int)) and not isinstance(value, bool) and math.isfinite(value) for value in (start, end)) or start < 0 or end < start:
            raise ValueError('Invalid source timing')
        if segment.get('track') not in ('microphone', 'system-audio'):
            raise ValueError('Invalid track')
        if not all(isinstance(segment.get(key), str) for key in ('text', 'speaker', 'language')):
            raise ValueError('Invalid text/identity fields')
    return document


def transcript_text(document):
    """Plain text with complete IDs/timing; JSON-escaped cells allow tabs/newlines."""
    validate_transcript(document)
    header = {key: value for key, value in document.items() if key != 'segments'}
    rows = [TRANSCRIPT_HEADER.rstrip('\n'), dumps(header), 'id\tstart\tend\ttrack\tlanguage\tspeaker\ttext\textra']
    for segment in document['segments']:
        keys = ('id', 'start', 'end', 'track', 'language', 'speaker', 'text')
        extra = {key: value for key, value in segment.items() if key not in keys}
        rows.append('\t'.join(dumps(segment[key]) for key in keys) + '\t' + dumps(extra))
    return '\n'.join(rows) + '\n'


def parse_transcript_text(text):
    if not text.startswith(TRANSCRIPT_HEADER):
        raise ValueError('Transcript text requires stable row metadata')
    # Records are LF-framed. Unicode line/paragraph separators are valid JSON
    # string content and must never be interpreted as record boundaries.
    lines = text.split('\n')
    if lines[-1] == '':
        lines.pop()  # A single final LF terminates the last record.
    if len(lines) < 3 or lines[2] != 'id\tstart\tend\ttrack\tlanguage\tspeaker\ttext\textra':
        raise ValueError('Invalid column header')
    document = json.loads(lines[1])
    document['segments'] = []
    keys = ('id', 'start', 'end', 'track', 'language', 'speaker', 'text')
    for line in lines[3:]:
        cells = [json.loads(cell) for cell in line.split('\t')]
        if len(cells) != 8 or not isinstance(cells[7], dict) or set(cells[7]).intersection(keys):
            raise ValueError('Malformed Transcript row')
        document['segments'].append(dict(zip(keys, cells[:7]), **cells[7]))
    return validate_transcript(document)


def reconcile_transcript(base_document, text, json_text):
    """One logical source; accept a valid one-sided external edit or signal conflict.

    Neither version silently wins when both diverge. Caller journals both files.
    """
    from_text = parse_transcript_text(text)
    from_json = validate_transcript(json.loads(json_text))
    if from_text == from_json:
        chosen = from_text
    elif from_text == base_document:
        chosen = from_json
    elif from_json == base_document:
        chosen = from_text
    else:
        raise Conflict('Both Transcript representations changed; retain both for resolution')
    return transcript_text(chosen), dumps(chosen)
