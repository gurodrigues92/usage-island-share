#!/usr/bin/env python3
"""On-demand local Claude/Codex session reader. No network, writes or execution.

Index and transcript stay in memory. Reasoning/thinking is excluded. Known secret
patterns are redacted before any text is returned to the application.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import itertools
import json
from pathlib import Path
import re


def redact(value):
    text = str(value)
    text = re.sub(r'-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----', '[credencial ocultada]', text, flags=re.S)
    text = re.sub(r'\b(?:oc_sk_[\w-]+|sk-ant-[\w-]+|sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[\w]+|github_pat_[\w]+|AKIA[A-Z0-9]{16})\b', '[credencial ocultada]', text)
    text = re.sub(r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b', '[credencial ocultada]', text)
    text = re.sub(r'(?i)(bearer\s+)[A-Za-z0-9_.~+/-]+', r'\1[ocultado]', text)
    text = re.sub(r'''(?ix)((?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|authorization)["']?\s*[:=]\s*["']?)[^\s,"'}]+''', r'\1[ocultado]', text)
    return text


def date(value):
    try:
        if isinstance(value, (float, int)):
            return datetime.fromtimestamp(value, timezone.utc).isoformat()
        return datetime.fromisoformat(str(value).replace('Z', '+00:00')).isoformat()
    except (ValueError, TypeError, OverflowError, OSError):
        return None


def records(path, budget, coverage=None):
    consumed = 0
    with path.open('rb') as handle:
        while consumed < budget:
            raw = handle.readline(min(1024 * 1024 + 1, budget - consumed))
            if not raw:
                break
            consumed += len(raw)
            if not raw.endswith(b'\n') and len(raw) >= min(1024 * 1024 + 1, budget):
                # Never parse a fragment of an oversized JSON record.
                if coverage is not None: coverage['limited'] = True
                while raw and not raw.endswith(b'\n') and consumed < budget:
                    raw = handle.readline(min(64 * 1024, budget - consumed)); consumed += len(raw)
                continue
            try:
                item = json.loads(raw)
                if isinstance(item, dict): yield item
            except (ValueError, UnicodeDecodeError):
                if coverage is not None: coverage['limited'] = True
                continue


def roots(home):
    return [home / '.codex/sessions'] + [p / 'projects' for p in sorted(home.glob('.claude*'))[:16] if p.is_dir()]


def allowed(path, home):
    try:
        real = path.resolve(strict=True)
        return real.suffix == '.jsonl' and real.is_file() and any(real.is_relative_to(root.resolve()) for root in roots(home))
    except (OSError, ValueError):
        return False


def text_content(content):
    if isinstance(content, str): return content
    if not isinstance(content, list): return ''
    return '\n'.join(str(p.get('text', '')) for p in content if isinstance(p, dict) and p.get('type') in ('text', 'input_text', 'output_text'))


def message(row):
    def visible(role, content):
        body = text_content(content)
        if role == 'user' and body.lstrip().startswith(('# AGENTS.md instructions', '<external_codex_apps_open_page>', '<environment_context>', '<INSTRUCTIONS>')):
            return None
        return role, body
    if row.get('type') == 'response_item':
        p = row.get('payload') or {}
        if not isinstance(p,dict): return None
        if p.get('type') == 'message' and p.get('role') in ('user', 'assistant') and p.get('channel') != 'analysis':
            return visible(p['role'], p.get('content'))
    if row.get('type') in ('user', 'assistant'):
        p = row.get('message') or {}
        if not isinstance(p,dict): return None
        if p.get('role') in ('user', 'assistant'):
            return visible(p['role'], p.get('content'))
    return None


def index(home, limit=100):
    candidates = []
    for root in roots(home):
        for path in itertools.islice(root.rglob('*.jsonl'), 10000):
            try:
                if allowed(path, home): candidates.append((path.stat().st_mtime, path))
            except OSError: continue
    sessions = []
    for modified, path in sorted(candidates, reverse=True)[:limit]:
        cwd, model, title, started = '', '', '', None
        try:
            for row in records(path, 256 * 1024):
                p = row.get('payload') or {}
                if not isinstance(p, dict): p = {}
                cwd = row.get('cwd') or (p.get('cwd') if row.get('type') in ('session_meta', 'turn_context') else '') or cwd
                msg_meta = row.get('message') or {}
                model = (msg_meta.get('model') if isinstance(msg_meta,dict) else None) or p.get('model') or model
                started = started or date(row.get('timestamp'))
                msg = message(row)
                if msg and msg[0] == 'user' and not title:
                    body = re.sub(r'<system-reminder>.*?</system-reminder>', '', msg[1], flags=re.S).strip()
                    if body and not body.startswith(('# AGENTS.md', '<environment_context>', '<INSTRUCTIONS>', '<external_codex')):
                        title = ' '.join(redact(body).split())[:150]
                if cwd and model and title: break
            sessions.append({'id':hashlib.sha256(str(path.resolve()).encode()).hexdigest(), 'file':str(path.resolve()),
                             'provider':'Codex' if path.is_relative_to(home / '.codex') else 'Claude',
                             'project':redact(Path(cwd).name) if cwd else 'Projeto não identificado', 'model':redact(model)[:150] or 'Modelo não identificado',
                             'title':title or path.stem, 'startedAt':started or date(modified), 'updatedAt':date(modified)})
        except (OSError, ValueError, TypeError): continue
    return {'sessions':sessions, 'limited':len(candidates) > limit}


def outcome(output):
    text = str(output)
    if re.search(r'(?:Script running with cell ID|Process running with session ID)', text, re.I):
        return 'received'
    codes = re.findall(r'(?:"?exit_code"?\s*[:=]\s*|Process exited with code\s+)(-?\d+)', text)
    if codes: return 'failed' if any(int(v) != 0 for v in codes) else 'success'
    return 'received'


def detail(path, home, budget=16 * 1024 * 1024):
    if not allowed(path, home): raise ValueError('Fonte fora das pastas de histórico permitidas')
    events, calls, seen = [], {}, set()
    coverage = {'limited': False}
    def add(kind, body, timestamp, call_id=None):
        raw = str(body)
        if not raw.strip(): return
        # Tool IDs identify distinct executions even when timestamps and commands match.
        # Hash full text before display truncation so long messages cannot collide.
        key = ['call', call_id] if call_id else ['message', timestamp, kind, raw]
        identity = hashlib.sha256(json.dumps(key, ensure_ascii=False).encode()).hexdigest()
        if identity in seen: return
        if len(events) >= 600:
            coverage['limited'] = True
            return
        seen.add(identity)
        encoded = redact(raw).encode('utf-8')
        if len(encoded) > 3000: coverage['limited'] = True
        body = encoded[:3000].decode('utf-8', errors='ignore')
        event = {'id':identity,'kind':kind,'text':body,'timestamp':date(timestamp),'status':'pending' if call_id else 'recorded'}
        events.append(event)
        if call_id: calls[call_id] = event
    for row in records(path, budget, coverage):
        ts = row.get('timestamp'); msg = message(row)
        if msg: add(msg[0], msg[1], ts)
        p = row.get('payload') or {}
        if not isinstance(p, dict): p = {}
        if row.get('type') == 'response_item':
            kind = p.get('type'); call_id = p.get('call_id')
            if kind in ('function_call','custom_tool_call'):
                name = str(p.get('name','ferramenta')); args = p.get('arguments', p.get('input',''))
                if not isinstance(args,str): args = json.dumps(args,ensure_ascii=False)
                category = 'edit' if re.search(r'apply_patch|edit|write',name,re.I) else 'command' if re.search(r'exec|shell|terminal',name,re.I) else 'tool'
                if category == 'command' and re.search(r'\b(?:pytest|vitest|jest)\b|\b(?:npm|swift|cargo|bun)\s+(?:run\s+)?test\b',args): category = 'test'
                add(category, name+'\n'+args, ts, call_id)
            elif kind in ('function_call_output','custom_tool_call_output') and call_id in calls:
                calls[call_id]['status'] = outcome(p.get('output',''))
        if row.get('type') in ('assistant','user'):
            metadata = row.get('message') or {}
            if not isinstance(metadata,dict): continue
            for part in metadata.get('content',[]) if isinstance(metadata.get('content'),list) else []:
                if not isinstance(part,dict): continue
                if part.get('type') == 'tool_use':
                    name = str(part.get('name','ferramenta')); args = json.dumps(part.get('input',{}),ensure_ascii=False)
                    category = 'read' if name in ('Read','Glob','Grep') else 'edit' if name in ('Edit','Write','MultiEdit') else 'command' if name == 'Bash' else 'tool'
                    if category == 'command' and re.search(r'pytest|vitest|jest|(?:npm|swift|cargo|bun)\s+(?:run\s+)?test',args): category = 'test'
                    add(category,name+'\n'+args,ts,part.get('id'))
                elif part.get('type') == 'tool_result' and part.get('tool_use_id') in calls:
                    calls[part['tool_use_id']]['status'] = 'failed' if part.get('is_error') is True else 'received'
        if len(events) >= 600: break
    return {'events':events,'limited':coverage['limited'] or path.stat().st_size > budget or len(events) >= 600}


if __name__ == '__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--home',type=Path,default=Path.home()); parser.add_argument('--detail',type=Path)
    args=parser.parse_args()
    try: print(json.dumps(detail(args.detail,args.home) if args.detail else index(args.home),ensure_ascii=False))
    except (OSError,ValueError) as error:
        print(json.dumps({'error':'Não foi possível ler esta fonte local.'})); raise SystemExit(1)
