#!/usr/bin/env python3
"""Incremental local token ledger. Stores only counters and project/model metadata.

No credentials, prompts, responses, commands, inference, network or dependencies.
The byte budget resumes on the next invocation rather than skipping unread records.
"""
import argparse
import hashlib
import json
import os
import re
from functools import lru_cache
from pathlib import Path
import sqlite3
import time
from datetime import datetime, timezone, timedelta


def stamp(value):
    try:
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return float(value) / (1000 if value > 1e11 else 1)
        return datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except (ValueError, TypeError, AttributeError, OverflowError):
        return None


def count(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= 10**12 else None


@lru_cache(maxsize=4096)
def project_name(cwd):
    if not isinstance(cwd, str) or not cwd:
        return 'Projeto não identificado'
    path = Path(cwd)
    # Worktree .git files point to a common repository. Only its name is exported.
    for parent in (path, *path.parents):
        if parent == Path.home() or parent == Path('/'):
            break
        dot = parent / '.git'
        if dot.is_dir():
            return parent.name
        if dot.is_file():
            try:
                text = dot.read_text()[:2048].strip()
                gitdir = Path(text.split(':', 1)[1].strip())
                if not gitdir.is_absolute():
                    gitdir = parent / gitdir
                common = gitdir / 'commondir'
                if common.is_file():
                    main = (gitdir / common.read_text().strip()).resolve()
                    return main.parent.name
                return parent.name
            except (OSError, IndexError):
                return parent.name
    return path.name or 'Projeto não identificado'


def event(provider, row, meta):
    ts = stamp(row.get('timestamp') or row.get('ts'))
    if ts is None or ts > time.time() + 60:
        return None
    usage = None
    if provider == 'Claude':
        msg = row.get('message') or {}
        usage = msg.get('usage')
        model = msg.get('model') or 'Modelo não identificado'
        key = row.get('requestId') or msg.get('id') or row.get('uuid')
        if not isinstance(usage, dict):
            return None
        if 'input_tokens' not in usage or 'output_tokens' not in usage:
            return None
        inp, out = usage.get('input_tokens', 0), usage.get('output_tokens', 0)
        read = usage.get('cache_read_input_tokens', 0)
        write = usage.get('cache_creation_input_tokens', 0)
        details = usage.get('cache_creation') or {}
        hour = details.get('ephemeral_1h_input_tokens', 0) if isinstance(details, dict) else 0
        if count(write) is None or count(hour) is None or hour > write:
            return None
        write -= hour
    elif provider == 'Codex':
        p = row.get('payload') or {}
        if row.get('type') == 'token_usage_record':
            usage = p.get('usage')
            kind = 'direct'
        elif row.get('type') == 'event_msg' and p.get('type') == 'token_count' and not meta.get('hasDirect'):
            info = p.get('info') or {}
            totals = info.get('total_token_usage')
            if not isinstance(totals, dict) or totals == meta.get('lastTotals'):
                return None
            usage = info.get('last_token_usage')
            if not isinstance(usage, dict):
                previous = meta.get('lastTotals') or {}
                usage = {k: max(0, v - previous.get(k, 0)) for k, v in totals.items() if count(v) is not None}
            meta['lastTotals'] = totals
            kind = 'legacy'
        else:
            return None
        if not isinstance(usage, dict):
            return None
        if 'input_tokens' not in usage or 'output_tokens' not in usage:
            return None
        model = p.get('model') or usage.get('model') or meta.get('model') or 'Modelo não identificado'
        key = p.get('response_id') if kind == 'direct' else 'legacy:' + hashlib.sha256(json.dumps([row.get('timestamp'), usage, model], sort_keys=True).encode()).hexdigest()
        total, read = usage.get('input_tokens', 0), usage.get('cached_input_tokens', 0)
        if count(total) is None or count(read) is None or read > total:
            return None
        inp, out, write, hour = total - read, usage.get('output_tokens', 0), usage.get('cache_write_input_tokens', 0), 0
    elif provider == 'SuperGrok':
        if row.get('msg') != 'shell.turn.inference_done':
            return None
        usage = row.get('ctx') or {}
        if 'prompt_tokens' not in usage or 'completion_tokens' not in usage:
            return None
        total, read = usage.get('prompt_tokens', 0), usage.get('cached_prompt_tokens', 0)
        if count(total) is None or count(read) is None or read > total:
            return None
        inp, out, write, hour = total - read, usage.get('completion_tokens', 0), 0, 0
        model = usage.get('model') or meta.get('model') or 'Modelo não identificado'
        key = None
    else:
        return None
    values = [inp, out, read, write, hour]
    if any(count(v) is None for v in values):
        return None
    if provider == 'Codex' and kind == 'direct':
        # Only validated counters can replace the legacy representation.
        meta['hasDirect'] = True
        meta['directValidated'] = True
    identity = str(key) if key else hashlib.sha256(json.dumps([meta.get('session'), ts, model, values], separators=(',', ':')).encode()).hexdigest()
    cwd = row.get('cwd') or meta.get('cwd')
    return identity, ts, project_name(cwd), str(model)[:200], values


# Only this schema may enter the incremental reader state or the ledger.
# Message bodies, tool arguments/results and arbitrary JSON are never retained.
_COUNTERS = dict.fromkeys(('input_tokens', 'output_tokens', 'cached_input_tokens',
                          'cache_read_input_tokens', 'cache_creation_input_tokens',
                          'cache_write_input_tokens', 'prompt_tokens', 'completion_tokens',
                          'cached_prompt_tokens', 'reasoning_output_tokens', 'total_tokens', 'model'), True)
_COUNTERS['cache_creation'] = {'ephemeral_1h_input_tokens': True}
_PROJECTION = dict.fromkeys(('type', 'timestamp', 'ts', 'cwd', 'requestId', 'uuid', 'msg'), True)
_PROJECTION.update(message={'id': True, 'model': True, 'usage': _COUNTERS},
                   payload={'type': True, 'cwd': True, 'model': True, 'response_id': True,
                            'usage': _COUNTERS, 'info': {'total_token_usage': _COUNTERS,
                                                       'last_token_usage': _COUNTERS}},
                   ctx=_COUNTERS)
_READER_VERSION = 3
_STRING_SPECIAL = re.compile(rb'["\\\x00-\x1f]')
_NUMBER = re.compile(rb'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\Z')


class CounterJSONStream:
    """Resumable JSONL projection with bounded memory, including huge string values.

    Only selected scalar fields are buffered (8 KiB each, keys 256 bytes). Opaque
    strings are scanned in C-sized chunks without accumulating their contents.
    The state is JSON-serializable and contains no prompts, results or commands.
    Invalid records are isolated at the next newline; an unfinished tail remains
    resumable even after days without writes and is not treated as unread backlog.
    """
    def __init__(self, state=None):
        self.state = state or self.empty()

    @staticmethod
    def empty():
        return {'stack': [], 'token': None, 'root': None, 'done': False,
                'started': False, 'invalid': False}

    def schema(self, path):
        result = _PROJECTION
        if path is None: return None
        for key in path:
            if not isinstance(result, dict): return None
            result = result.get(key)
        return result

    def value_path(self):
        stack = self.state['stack']
        if not stack:
            if self.state['done']: raise ValueError('extra value')
            return []
        parent = stack[-1]
        if parent['kind'] == 'array':
            if parent['phase'] not in ('first', 'value'): raise ValueError('array value')
            return None
        if parent['phase'] != 'value': raise ValueError('object value')
        path = parent['path']
        schema = self.schema(path)
        return path + [parent['key']] if isinstance(schema, dict) and parent['key'] in schema else None

    def complete(self, value):
        stack = self.state['stack']
        if not stack:
            self.state['root'] = value
            self.state['done'] = True
            return
        parent = stack[-1]
        if parent['kind'] == 'object' and parent['out'] is not None and parent['key'] in self.schema(parent['path']):
            parent['out'][parent['key']] = value
        parent['phase'] = 'comma'
        parent.pop('key', None)

    def finish_token(self):
        token = self.state['token']
        raw = token['buffer'].encode('latin1')
        if token['kind'] == 'string':
            if token['overflow']:
                value = None
            elif token['capture']:
                value = json.loads(raw)
            else:
                value = None
            if token['key']:
                parent = self.state['stack'][-1]
                # Unknown keys are discarded before serializing parser state.
                schema = self.schema(parent['path'])
                parent['key'] = value if isinstance(schema, dict) and value in schema else None
                parent['phase'] = 'colon'
            else:
                self.complete(value)
        else:
            if token['lex'] not in ('zero', 'integer', 'fraction', 'exponentDigits', 'true', 'false', 'null'):
                raise ValueError('unfinished primitive')
            if token['overflow']:
                # JSON numeric literals may be arbitrarily long, but token counters
                # cannot exceed count()'s range. Keep no unbounded numeric buffer.
                value = None
            elif token['capture']:
                if raw not in (b'true', b'false', b'null') and not _NUMBER.fullmatch(raw):
                    raise ValueError('invalid primitive')
                value = json.loads(raw)
            else:
                value = None
            self.complete(value)
        self.state['token'] = None

    @staticmethod
    def append(token, data):
        if token['kind'] == 'primitive':
            for byte in data:
                ch = chr(byte); state = token['lex']; digit = '0' <= ch <= '9'
                if state == 'sign' and digit: state = 'zero' if ch == '0' else 'integer'
                elif state in ('integer', 'fraction', 'exponentDigits') and digit: pass
                elif state in ('zero', 'integer') and ch == '.': state = 'decimal'
                elif state in ('zero', 'integer', 'fraction') and ch in 'eE': state = 'exponent'
                elif state == 'decimal' and digit: state = 'fraction'
                elif state == 'exponent' and ch in '+-': state = 'exponentSign'
                elif state in ('exponent', 'exponentSign') and digit: state = 'exponentDigits'
                elif any(word.startswith(state + ch) for word in ('true', 'false', 'null')): state += ch
                else: raise ValueError('invalid primitive')
                token['lex'] = state
        if not token['capture']: return
        available = token['limit'] - len(token['buffer'])
        if len(data) > available: token['overflow'] = True
        if available > 0: token['buffer'] += data[:available].decode('latin1')

    def flush(self):
        state = self.state
        if state['token'] and state['token']['kind'] == 'primitive' and not state['invalid']:
            try: self.finish_token()
            except (ValueError, UnicodeError): state['invalid'] = True
        valid = not state['invalid'] and state['done'] and not state['stack'] and not state['token']
        row = state['root'] if valid and isinstance(state['root'], dict) else None
        invalid = int(state['started'] and not valid)
        self.state = self.empty()
        return row, invalid

    def feed(self, data):
        rows = []; invalid = 0; pos = 0
        while pos < len(data):
            state = self.state
            if state['invalid']:
                end = data.find(b'\n', pos)
                if end < 0: break
                _, bad = self.flush(); invalid += bad; pos = end + 1; continue
            try:
                token = state['token']
                if token and token['kind'] == 'string':
                    if token['unicode']:
                        value = data[pos]
                        if value not in b'0123456789abcdefABCDEF': raise ValueError('unicode escape')
                        self.append(token, data[pos:pos+1]); token['unicode'] -= 1; pos += 1; continue
                    if token['escape']:
                        value = data[pos]
                        if value not in b'"\\/bfnrtu': raise ValueError('escape')
                        self.append(token, data[pos:pos+1]); token['escape'] = False
                        if value == ord('u'): token['unicode'] = 4
                        pos += 1; continue
                    match = _STRING_SPECIAL.search(data, pos)
                    end = match.start() if match else len(data)
                    self.append(token, data[pos:end]); pos = end
                    if not match: continue
                    value = data[pos]
                    if value < 32: raise ValueError('control in string')
                    self.append(token, data[pos:pos+1]); pos += 1
                    if value == ord('\\'): token['escape'] = True
                    else: self.finish_token()
                    continue
                if token:
                    end = pos
                    while end < len(data) and data[end] not in b' \t\r\n,]}:{[': end += 1
                    self.append(token, data[pos:end]); pos = end
                    if end == len(data): continue
                    self.finish_token(); continue
                value = data[pos]
                if value == 10:
                    row, bad = self.flush(); invalid += bad
                    if row is not None: rows.append(row)
                    pos += 1; continue
                if value in b' \t\r': pos += 1; continue
                state['started'] = True
                stack = state['stack']; top = stack[-1] if stack else None
                if value == ord('"'):
                    key = bool(top and top['kind'] == 'object' and top['phase'] in ('first', 'key'))
                    schema = self.schema(top['path']) if key else self.schema(self.value_path())
                    capture = isinstance(schema, dict) if key else schema is True
                    state['token'] = {'kind': 'string', 'buffer': '"' if capture else '',
                                      'capture': capture, 'overflow': False, 'limit': 256 if key else 8192,
                                      'key': key, 'escape': False, 'unicode': 0}
                elif value in (ord('{'), ord('[')):
                    path = self.value_path(); schema = self.schema(path)
                    if len(stack) >= 256: raise ValueError('maximum nesting')
                    kind = 'object' if value == ord('{') else 'array'
                    stack.append({'kind': kind, 'phase': 'first', 'path': path if kind == 'object' and isinstance(schema, dict) else None,
                                  'out': {} if kind == 'object' and isinstance(schema, dict) else None})
                elif value in (ord('}'), ord(']')):
                    if not top or top['kind'] != ('object' if value == ord('}') else 'array') or top['phase'] not in ('first', 'comma'):
                        raise ValueError('unmatched container')
                    stack.pop(); self.complete(top['out'])
                elif value == ord(':'):
                    if not top or top['kind'] != 'object' or top['phase'] != 'colon': raise ValueError('colon')
                    top['phase'] = 'value'
                elif value == ord(','):
                    if not top or top['phase'] != 'comma': raise ValueError('comma')
                    top['phase'] = 'key' if top['kind'] == 'object' else 'value'
                else:
                    path = self.value_path()
                    if value not in b'-0123456789tfn': raise ValueError('primitive')
                    state['token'] = {'kind': 'primitive', 'buffer': chr(value) if self.schema(path) is True else '', 'capture': self.schema(path) is True,
                                      'overflow': False, 'limit': 128,
                                      'lex': 'sign' if value == 45 else 'zero' if value == 48 else 'integer' if 49 <= value <= 57 else chr(value)}
                pos += 1
            except (ValueError, TypeError, UnicodeError):
                state['invalid'] = True
        return rows, invalid

    def finish_eof(self):
        # A syntactically complete record does not need a newline. Do not discard
        # partial tails: persist only the projection/parser state and resume later.
        state = self.state
        if state['token'] and state['token']['kind'] == 'primitive' and not state['stack']:
            try: self.finish_token()
            except (ValueError, UnicodeError): return [], 0
        if state['done'] and not state['stack'] and not state['token'] and not state['invalid']:
            row, invalid = self.flush()
            return ([row] if row is not None else []), invalid
        return [], 0


def run(home, db, budget=32*1024*1024):
    db.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(db.parent, 0o700)
    con = sqlite3.connect(db, timeout=5)
    os.chmod(db, 0o600)
    con.execute('PRAGMA journal_mode=WAL')
    con.execute('CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, inode INTEGER, offset INTEGER, meta TEXT)')
    con.execute('CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, provider TEXT, ts REAL, project TEXT, model TEXT, inp INTEGER, out INTEGER, cr INTEGER, cw INTEGER, ch INTEGER)')
    columns = {r[1] for r in con.execute('PRAGMA table_info(events)')}
    if 'origin' not in columns:
        con.execute("ALTER TABLE events ADD COLUMN origin TEXT DEFAULT ''")
        con.execute("ALTER TABLE events ADD COLUMN format TEXT DEFAULT ''")
    con.execute('CREATE INDEX IF NOT EXISTS events_origin_format ON events(origin,format)')
    files = []
    for root in sorted(home.glob('.claude*')):
        if (root / 'projects').is_dir():
            files += [('Claude', f, root.name) for f in (root / 'projects').rglob('*.jsonl')]
    codex = home / '.codex/sessions'
    if codex.is_dir():
        files += [('Codex', f, '.codex') for f in codex.rglob('*.jsonl')]
    grok = home / '.grok/logs/unified.jsonl'
    if grok.is_file():
        files.append(('SuperGrok', grok, '.grok'))
    saved_files = {row[0]: row[1:] for row in con.execute('SELECT path,inode,offset,meta FROM files')}
    def reader_age(item):
        saved = saved_files.get(str(item[1]))
        try: return json.loads(saved[2]).get('readAt', 0) if saved else 0
        except (ValueError, TypeError): return 0
    # Least recently serviced sources first: an active multi-GB session cannot
    # indefinitely starve older files while generating more than one byte budget.
    files.sort(key=reader_age)
    incomplete = False; warnings = []; deadline = time.monotonic() + 20
    progress = dict(filesTotal=len(files), filesComplete=0, bytesTotal=0, bytesRead=0,
                    recordsInvalid=0, pendingTailFiles=0)

    purged_origins = set()
    def record(provider, row, meta, origin, account):
        try:
            p = row.get('payload') or {}
            if row.get('type') in ('session_meta', 'turn_context') and isinstance(p, dict):
                for key in ('cwd', 'model'):
                    if isinstance(p.get(key), str): meta[key] = p[key]
            if isinstance(row.get('cwd'), str): meta['cwd'] = row['cwd']
            found = event(provider, row, meta)
            if not found: return
            key, ts, project, model, values = found
            kind = 'legacy' if provider == 'Codex' and row.get('type') == 'event_msg' else 'direct'
            if provider == 'Codex' and kind == 'direct' and origin not in purged_origins:
                con.execute("DELETE FROM events WHERE origin=? AND format='legacy'", (origin,))
                purged_origins.add(origin)
            if ts < time.time() - 365 * 86400: return
            scope = hashlib.sha256((provider + '|' + account + '|' + key).encode()).hexdigest()
            if kind == 'legacy':
                # Old helper versions hashed every usage field. A newly added or
                # omitted non-counter field must not duplicate migrated events.
                old = con.execute('SELECT id FROM events WHERE origin=? AND format=? AND ts=? AND model=? AND inp=? AND out=? AND cr=? AND cw=? AND ch=? LIMIT 1',
                                  (origin, kind, ts, model, *values)).fetchone()
                if old: scope = old[0]
            con.execute('INSERT INTO events(id,provider,ts,project,model,inp,out,cr,cw,ch,origin,format) VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET inp=excluded.inp,out=excluded.out,cr=excluded.cr,cw=excluded.cw,ch=excluded.ch WHERE (excluded.inp+excluded.out+excluded.cr+excluded.cw+excluded.ch) >= (events.inp+events.out+events.cr+events.cw+events.ch)', (scope, provider, ts, project, model, *values, origin, kind))
        except (ValueError, TypeError, AttributeError, OverflowError):
            # A usage-shaped record with unusable counters must not turn into zero.
            meta['invalidRecords'] = meta.get('invalidRecords', 0) + 1

    for provider, file, account in files:
        try:
            stat = file.stat(); saved = saved_files.get(str(file))
            if saved and saved[0] == stat.st_ino and saved[1] <= stat.st_size:
                offset, meta = saved[1], json.loads(saved[2])
                length = meta.get('prefixLength', 0)
                if length:
                    with file.open('rb') as prefix: actual = hashlib.sha256(prefix.read(length)).hexdigest()
                    if actual != meta.get('fingerprint'): offset, meta = 0, {'session': file.stem}
            else:
                offset, meta = 0, {'session': file.stem}
            if meta.get('readerVersion') != _READER_VERSION or (provider == 'Codex' and meta.get('hasDirect') and not meta.get('directValidated')):
                # Rescan exactly once with the selective reader, recovering all
                # records discarded by the previous size cap/broken-tail handling.
                # Existing events stay deduplicated and are never cleared here.
                offset, meta = 0, {'session': file.stem, 'readerVersion': _READER_VERSION}
            origin = hashlib.sha256(str(file).encode()).hexdigest()
            parser = CounterJSONStream(meta.pop('parser', None))
            if offset < stat.st_size and budget > 0 and time.monotonic() < deadline:
                with file.open('rb') as stream:
                    stream.seek(offset)
                    while budget > 0 and time.monotonic() < deadline:
                        # Persist progress within huge records; bytes never have to
                        # be reread just because a single record exceeds the budget.
                        block = stream.read(min(64 * 1024, budget, max(0, stat.st_size-stream.tell())))
                        if not block: break
                        budget -= len(block)
                        rows, invalid = parser.feed(block)
                        meta['invalidRecords'] = meta.get('invalidRecords', 0) + invalid
                        for row in rows: record(provider, row, meta, origin, account)
                        offset = stream.tell()
                    if offset >= stat.st_size:
                        rows, invalid = parser.finish_eof()
                        meta['invalidRecords'] = meta.get('invalidRecords', 0) + invalid
                        for row in rows: record(provider, row, meta, origin, account)
                meta['readAt'] = time.time()
            pending_tail = offset >= stat.st_size and parser.state['started']
            if parser.state['started']: meta['parser'] = parser.state
            if pending_tail:
                progress['pendingTailFiles'] += 1
                warnings.append('Há registros finais incompletos aguardando continuação')
            progress['recordsInvalid'] += meta.get('invalidRecords', 0)
            progress['bytesTotal'] += stat.st_size
            progress['bytesRead'] += min(offset, stat.st_size)
            progress['filesComplete'] += int(offset >= stat.st_size)
            incomplete |= offset < stat.st_size
            length = min(offset, 4096)
            with file.open('rb') as prefix: meta['fingerprint'] = hashlib.sha256(prefix.read(length)).hexdigest()
            meta['prefixLength'] = length
            con.execute('INSERT OR REPLACE INTO files VALUES(?,?,?,?)', (str(file), stat.st_ino, offset, json.dumps(meta)))
        except OSError:
            incomplete = True
            warnings.append('Uma fonte local não pôde ser lida')
    if progress['recordsInvalid']:
        warnings.append('Há registros JSON inválidos não contabilizados')
    opencode = home / '.local/share/opencode/opencode.db'
    if opencode.is_file():
        try:
            remote = sqlite3.connect(f'file:{opencode}?mode=ro', uri=True, timeout=3)
            cursor = remote.execute("SELECT id,time_created,data FROM message WHERE time_created>=? AND data LIKE '%tokens%'", (int((time.time()-365*86400)*1000),))
            for ident, created, raw in cursor:
                try:
                    row = json.loads(raw); t = row.get('tokens') or {}; cache = t.get('cache') or {}
                    values = [t.get('input', 0), t.get('output', 0) + t.get('reasoning', 0), cache.get('read', 0), cache.get('write', 0), 0]
                    if not isinstance(t, dict) or not t or any(count(v) is None for v in values):
                        continue
                    model = row.get('modelID') or row.get('model') or 'Modelo não identificado'
                    model = model if isinstance(model, str) else 'Modelo não identificado'
                    cwd = (row.get('path') or {}).get('cwd') if isinstance(row.get('path'), dict) else None
                    key = hashlib.sha256(('OpenCode|' + str(ident)).encode()).hexdigest()
                    con.execute('INSERT OR REPLACE INTO events(id,provider,ts,project,model,inp,out,cr,cw,ch) VALUES(?,?,?,?,?,?,?,?,?,?)', (key,'OpenCode',created/1000,project_name(cwd),model,*values))
                except (ValueError, TypeError, AttributeError):
                    continue
            remote.close()
        except sqlite3.Error:
            warnings.append('OpenCode local indisponível')
    con.execute('DELETE FROM events WHERE ts<?', (time.time()-365*86400,))
    con.commit()
    rows = []
    for row in con.execute("SELECT provider,project,model,date(ts,'unixepoch'),sum(inp),sum(out),sum(cr),sum(cw),sum(ch),count(*) FROM events WHERE ts>=? GROUP BY provider,project,model,date(ts,'unixepoch') ORDER BY 4 DESC", (time.time()-365*86400,)):
        provider, project, model, day, inp, out, cr, cw, ch, calls = row
        ident = hashlib.sha256(json.dumps(row[:4]).encode()).hexdigest()
        rows.append(dict(id=ident,provider=provider,project=project,model=model,day=day,input=inp,output=out,cacheRead=cr,cacheWrite=cw,cacheWrite1h=ch,calls=calls))
    con.close()
    return dict(rows=rows,incomplete=incomplete,updatedAt=datetime.now(timezone.utc).isoformat(),warnings=sorted(set(warnings)),progress=progress)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--home', type=Path, default=Path.home())
    parser.add_argument('--database', type=Path)
    parser.add_argument('--budget', type=int, default=32*1024*1024)
    args = parser.parse_args()
    db = args.database or args.home / '.cache/usage-island/analytics.sqlite3'
    print(json.dumps(run(args.home, db, max(1024,args.budget)), ensure_ascii=False))
