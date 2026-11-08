#!/usr/bin/env python3
"""The backlog stand-in for the lifecycle fixtures. Never contacts Loopable.

One program with two faces over one state file, so a case sees one backlog
whichever way it is reached:

  loopable <tool> ['<json args>' | -]   the loopable MCP's tools, by their own
                                         names and argument names. The case's
                                         prompt substitutes this for the MCP.
  curl <curl arguments>                  the HTTP API bin/start.sh, bin/ship.sh
                                         and the hooks call. Any URL whose path
                                         starts /agent/ is answered from the
                                         state; the fixture's upload bucket and
                                         deploy are answered too; every other
                                         host fails as an offline curl does.

It is installed twice in the workspace's .loopable-eval/bin/, as `loopable` and
as `curl`, and decides which it is by the name it was run as. Its state is
.loopable-eval/backlog.json next to that bin/ directory, whatever the current
directory, so a call from a worktree reaches the same backlog.

Writes persist, and the API's refusals are kept where the driver meets them —
an agent token cannot set `ready` (except on its own filing) or `done`, a
session closes once, a complete close accounts for every criterion — because
those refusals are what the plugin's machinery is written around. What the
stand-in does NOT do is protect the case from the agent: a bad move it allows
is a move the graders see in backlog-events.jsonl, one flat line per call.
"""
import fcntl
import json
import os
import re
import sys
import uuid
from pathlib import Path
from urllib.parse import urlsplit, parse_qs

ROOT = Path(__file__).resolve().parent.parent          # <workspace>/.loopable-eval
STATE = ROOT / 'backlog.json'
EVENTS = ROOT / 'backlog-events.jsonl'

STATUSES = ['todo', 'ready', 'in_progress', 'in_review', 'verifying', 'done',
            'blocked', 'awaiting_input', 'dropped']
# api/lib/work-items.mjs AGENT_EDGES: destination -> the sources an agent token
# may come from. `ready` is only on the token's own filing (OWN_FILING_EDGES).
AGENT_EDGES = {
    'todo': ['in_progress', 'blocked', 'awaiting_input'],
    'ready': ['todo'],
    'in_progress': ['todo', 'ready', 'blocked', 'awaiting_input'],
    'in_review': ['in_progress'],
    'verifying': ['in_review'],
    'blocked': ['in_progress'],
    'awaiting_input': ['in_progress'],
}
VERIFY = ('browser', 'http', 'eval', 'manual')
KINDS = ('epic', 'story', 'task', 'bug')
ENDINGS = ('met', 'skipped', 'after_merge')


class Refused(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


# ------------------------------------------------------------------ state --
class Backlog:
    def __enter__(self):
        self.fh = open(STATE, 'r+')
        fcntl.flock(self.fh, fcntl.LOCK_EX)
        self.s = json.load(self.fh)
        return self

    def __exit__(self, *exc):
        self.fh.seek(0)
        self.fh.truncate()
        json.dump(self.s, self.fh, indent=2)
        self.fh.write('\n')
        fcntl.flock(self.fh, fcntl.LOCK_UN)
        self.fh.close()

    # --- lookups
    def project(self, pid):
        if pid not in (None, '', self.s['project']['id']):
            raise Refused(404, 'No project ' + str(pid) + ' that this token can see.')

    def item(self, ref):
        ref = str(ref or '').strip().lower()
        ref = ref.split('/')[-1]
        if re.fullmatch(r'[estbf]?[0-9]+', ref):
            ref = ref.lstrip('estbf')
            for it in self.s['items'].values():
                if str(it['ref']) == ref:
                    return it
        if ref in self.s['items']:
            return self.s['items'][ref]
        raise Refused(404, 'No item ' + ref + ' in this project.')

    def session(self, sid):
        s = self.s['sessions'].get(str(sid or ''))
        if not s:
            raise Refused(404, 'No session ' + str(sid) + ' in this project.')
        return s

    def new_id(self):
        self.s['counter'] = self.s.get('counter', 0) + 1
        return str(uuid.UUID(int=(0x5e55 << 112) + self.s['counter']))

    # --- shapes
    def summary(self, it):
        return {k: it.get(k) for k in ('id', 'ref', 'kind', 'title', 'status',
                                        'status_note', 'parent_id')}

    def criteria(self, it):
        return [{'id': c['id'], 'text': c['text'], 'verify': c['verify'],
                 'source': c.get('source', 'asked'), 'status': c.get('status', 'open')}
                for c in it.get('criteria', [])]

    def blockers(self, it):
        if not any(c.get('verify') in VERIFY for c in it.get('criteria', [])):
            return ['no_verifiable_criterion']
        return []

    def pack(self, it):
        refs = {i['id']: i['title'] for i in self.s['items'].values()}
        edges = [{'relation': 'blocks', 'from': refs.get(l['blocker_id']), 'to': refs.get(l['blocked_id'])}
                 for l in self.s['links'] if it['id'] in (l['blocker_id'], l['blocked_id'])]
        return {
            'item': {**self.summary(it), 'ask': it.get('ask'), 'body': it.get('body'),
                     'brief_rev': it.get('brief_rev', 0),
                     'ready_blockers': [] if it['status'] == 'ready' else self.blockers(it)},
            'criteria': [{'text': c['text'], 'verify': c['verify'], 'status': c.get('status', 'open')}
                         for c in it.get('criteria', [])],
            'neighbourhood': {'nodes': [], 'edges': edges},
            'decisions': self.s.get('decisions', []),
            'environments': self.s.get('environments', []),
            'truncated': False,
        }

    def full(self, it):
        return {'item': {**self.summary(it), 'ask': it.get('ask'), 'body': it.get('body')},
                'brief': {'brief_rev': it.get('brief_rev', 0), 'ask': it.get('ask'),
                          'criteria': self.criteria(it),
                          'out_of_scope': it.get('out_of_scope', []),
                          'assumptions': it.get('assumptions', []),
                          'open_questions': it.get('open_questions', [])},
                'links': [l for l in self.s['links'] if it['id'] in (l['blocker_id'], l['blocked_id'])],
                'sessions': [self.session_view(s) for s in self.s['sessions'].values()
                             if s['item_id'] == it['id']]}

    def session_view(self, s):
        return {k: v for k, v in s.items() if k != 'activities'} | {
            'activities': len(s.get('activities', []))}

    # --- the writes
    def move(self, it, status, note, via):
        if status not in STATUSES:
            raise Refused(422, 'status must be one of ' + ', '.join(STATUSES) + '.')
        token = self.s['token']
        if not token.get('person_edges'):
            sources = AGENT_EDGES.get(status)
            if sources is None or it['status'] not in sources:
                raise Refused(403, 'An agent token cannot move an item from ' + it['status'] +
                              ' to ' + status + '.')
            if status == 'ready' and not it.get('filed_by_this_token'):
                raise Refused(403, 'An agent token sets ready only on an item it filed itself.')
        it['status'] = status
        it['status_note'] = note
        it.setdefault('trail', []).append({'to': status, 'note': note, 'via': via})

    def add_item(self, a, via):
        title = (a.get('title') or '').strip()
        if not title:
            raise Refused(422, 'title is required.')
        kind = a.get('kind') or 'story'
        if kind not in KINDS:
            raise Refused(422, 'kind must be one of ' + ', '.join(KINDS) + '.')
        parent = a.get('parent_id')
        if parent:
            parent = self.item(parent)['id']
            if kind == 'bug':
                raise Refused(422, 'A bug stands alone: it has no parent.')
        self.s['next_ref'] += 1
        ref = self.s['next_ref']
        iid = str(uuid.UUID(int=(0x17e4 << 112) + ref))
        it = {'id': iid, 'ref': ref, 'kind': kind, 'title': title, 'status': 'todo',
              'status_note': None, 'parent_id': parent, 'body': a.get('body'), 'ask': None,
              'brief_rev': 0, 'criteria': [], 'filed_by_this_token': True}
        self.s['items'][iid] = it
        return it


# ---------------------------------------------------------------- the log --
def log(line):
    with EVENTS.open('a') as f:
        f.write(json.dumps(line) + '\n')


def flat(op, via, a, result=None, error=None):
    """One line a regex can read: the op, whether it held, and the fields that say what it did."""
    line = {'op': op, 'via': via, 'ok': error is None}
    for k in ('item_id', 'session_id', 'status', 'kind', 'title', 'state', 'verdict', 'head_sha',
              'blocker_id', 'blocked_id', 'parent_id', 'branch', 'pr_url', 'note'):
        if k in a and a[k] is not None:
            line[k] = a[k]
    ref = a.get('ref')
    if isinstance(ref, dict):
        line['event'] = ref.get('event')
        line['fields'] = ref
    if op == 'close_session' and isinstance(a.get('criteria'), list):
        line['criteria'] = [c.get('status') for c in a['criteria'] if isinstance(c, dict)]
    if op in ('post_activity', 'add_item', 'propose') and a.get('body'):
        line['body'] = a['body']
    if result is not None:
        line['result'] = result
    if error is not None:
        line['error'] = error
    return line


# -------------------------------------------------------------- the tools --
def tool(b, name, a, via='tool'):
    """Run one MCP-shaped tool against the state. Returns (result, flat-log extras)."""
    if name == 'whoami':
        return {'member': b.s['me'], 'token': b.s['token'],
                'projects': [b.s['project']]}, None
    b.project(a.get('project_id'))
    if name == 'list_backlog':
        want = a.get('status')
        if isinstance(want, str):
            want = [w.strip() for w in want.split(',') if w.strip()]
        items = [b.summary(i) for i in b.s['items'].values()
                 if (not want or i['status'] in want)
                 and (not a.get('parent_id') or i.get('parent_id') == a['parent_id'])]
        items.sort(key=lambda i: i['ref'])
        if a.get('titles_only'):
            items = [{'id': i['id'], 'ref': i['ref'], 'title': i['title'], 'status': i['status'],
                      'kind': i['kind']} for i in items]
        return {'items': items}, None
    if name == 'get_item':
        return b.full(b.item(a.get('item_id'))), None
    if name == 'pull_item':
        return {'pack': b.pack(b.item(a.get('item_id')))}, None
    if name == 'next_ready':
        ready = sorted((i for i in b.s['items'].values() if i['status'] == 'ready'), key=lambda i: i['ref'])
        return {'pack': b.pack(ready[0]) if ready else None}, None
    if name == 'list_decisions':
        return {'decisions': b.s.get('decisions', [])}, None
    if name == 'list_escalations':
        return {'escalations': b.s.get('escalations', [])}, None
    if name == 'list_sessions':
        sid = a.get('item_id')
        iid = b.item(sid)['id'] if sid else None
        return {'sessions': [b.session_view(s) for s in b.s['sessions'].values()
                             if not iid or s['item_id'] == iid]}, None
    if name == 'add_item':
        it = b.add_item(a, via)
        # The parent as a ref, however it was named (an id or a ref): which
        # epic a follow-up was filed under is what a grader reads.
        parent = b.s['items'][it['parent_id']]['ref'] if it['parent_id'] else None
        return {'item': b.summary(it)}, {'ref': it['ref'], 'parent_ref': parent}
    if name == 'propose':
        b.s.setdefault('drafts', []).append({'title': a.get('title'), 'body': a.get('body'),
                                             'kind': a.get('kind')})
        return {'draft': {'id': b.new_id(), 'status': 'pending'}}, None
    if name == 'revise':
        it = b.item(a.get('item_id'))
        for k in ('title', 'body'):
            if a.get(k) is not None:
                it[k] = a[k]
        return {'item': b.summary(it)}, {'ref': it['ref']}
    if name == 'link_items':
        blocker, blocked = b.item(a.get('blocker_id')), b.item(a.get('blocked_id'))
        b.s['links'].append({'blocker_id': blocker['id'], 'blocked_id': blocked['id']})
        return {'ok': True}, {'blocker': blocker['ref'], 'blocked': blocked['ref']}
    if name == 'report_progress':
        it = b.item(a.get('item_id'))
        b.move(it, a.get('status'), a.get('note'), via)
        return {'item': b.summary(it)}, {'ref': it['ref']}
    if name == 'write_brief':
        it = b.item(a.get('item_id'))
        crit = a.get('criteria')
        if not isinstance(crit, list) or not crit:
            raise Refused(422, 'criteria: at least one, each with text and verify.')
        rows = []
        for c in crit:
            if not isinstance(c, dict) or not c.get('text') or c.get('verify') not in VERIFY:
                raise Refused(422, 'every criterion needs text and a verify of ' + ', '.join(VERIFY) + '.')
            rows.append({'id': b.new_id(), 'text': c['text'], 'verify': c['verify'],
                         'source': c.get('source', 'asked')})
        it['criteria'] = rows
        it['brief_rev'] = it.get('brief_rev', 0) + 1
        for k in ('ask', 'out_of_scope', 'assumptions', 'open_questions'):
            if a.get(k) is not None:
                it[k] = a[k]
        if a.get('title'):
            it['title'] = a['title']
        return {'brief_rev': it['brief_rev']}, {'ref': it['ref']}
    if name == 'open_session':
        it = b.item(a.get('item_id'))
        for s in b.s['sessions'].values():
            if s['item_id'] == it['id'] and not s.get('closed_at'):
                raise Refused(409, 'Item ' + str(it['ref']) + ' already has an open session, ' + s['id'] + '.')
        sid = b.new_id()
        b.s['sessions'][sid] = {'id': sid, 'item_id': it['id'], 'item_ref': it['ref'],
                                'harness': a.get('harness'), 'repo': a.get('repo'),
                                'branch': a.get('branch'), 'state': 'open', 'closed_at': None,
                                'head_sha': None, 'verdict': None, 'verdict_reason': None,
                                'pr_url': None, 'pr_number': None, 'criteria': [], 'activities': []}
        return {'session': b.session_view(b.s['sessions'][sid])}, {'ref': it['ref'], 'session': sid}
    if name == 'post_activity':
        s = b.session(a.get('session_id'))
        kind = a.get('kind')
        if kind not in ('action', 'thought', 'result', 'question'):
            raise Refused(422, 'kind must be action, thought, result or question.')
        if not a.get('body'):
            raise Refused(422, 'body is required.')
        ref = a.get('ref') if isinstance(a.get('ref'), dict) else {}
        act = {'id': b.new_id(), 'kind': kind, 'body': a['body'], 'ref': ref}
        s.setdefault('activities', []).append(act)
        return {'activity': act}, {'ref': s['item_ref']}
    if name == 'close_session':
        s = b.session(a.get('session_id'))
        if s.get('closed_at'):
            raise Refused(404, 'Session ' + s['id'] + ' is not open: a session closes once.')
        state = a.get('state')
        if state not in ('complete', 'error', 'abandoned'):
            raise Refused(422, 'state must be complete, error or abandoned.')
        it = b.s['items'][s['item_id']]
        crit = a.get('criteria') or []
        if state == 'complete':
            verdict = a.get('verdict')
            if verdict not in ('pass', 'fail', 'not_run'):
                raise Refused(422, 'A complete close needs a verdict: pass, fail or not_run.')
            if not re.fullmatch(r'[0-9a-f]{40}', str(a.get('head_sha') or '')):
                raise Refused(422, 'A complete close needs head_sha, the full 40-character sha.')
            known = {c['id'] for c in it.get('criteria', [])}
            given = {c.get('id') for c in crit if isinstance(c, dict)}
            if known - given:
                raise Refused(422, 'A complete close accounts for every criterion; missing ' +
                              ', '.join(sorted(known - given)) + '.')
            for c in crit:
                if c.get('status') not in ENDINGS:
                    raise Refused(422, 'A criterion ends met, skipped or after_merge.')
                if c.get('status') == 'after_merge' and verdict != 'pass':
                    raise Refused(422, 'after_merge is a pass close\'s alone.')
            if it['status'] == 'verifying' and (verdict != 'pass' or any(c.get('status') != 'met' for c in crit)):
                raise Refused(409, 'The item is verifying: only a close with every criterion met '
                                   'brings it back to in_review.')
        pr = a.get('pr_url')
        s.update({'state': state, 'closed_at': 'closed', 'summary': a.get('summary'),
                  'brief_rev': a.get('brief_rev'), 'head_sha': a.get('head_sha'),
                  'verdict': a.get('verdict'), 'verdict_reason': a.get('verdict_reason'),
                  'criteria': crit, 'screenshot_ids': a.get('screenshot_ids', []),
                  'pr_url': pr, 'pr_number': int(pr.rstrip('/').split('/')[-1]) if pr else None})
        if state == 'complete' and it['status'] in ('in_progress', 'verifying'):
            it['status'] = 'in_review'
            it.setdefault('trail', []).append({'to': 'in_review', 'note': 'session ' + s['id'] + ' closed',
                                               'via': via})
        return {'session': b.session_view(s)}, {'ref': it['ref']}
    raise Refused(400, 'The loopable stand-in has no tool ' + repr(name) + '.')


def run_tool(name, a, via='tool'):
    try:
        with Backlog() as b:
            result, extra = tool(b, name, a, via)
    except Refused as r:
        log(flat(name, via, a, error=r.message))
        return r.status, {'error': r.message, 'message': r.message}
    line = flat(name, via, a)
    if extra:
        line.update(extra)
    if name in ('whoami', 'list_backlog', 'get_item', 'pull_item', 'next_ready', 'list_decisions',
                'list_escalations', 'list_sessions'):
        line = {'op': name, 'via': via, 'ok': True, 'read': True}
    log(line)
    return 200, result


def main_tool(argv):
    if not argv or argv[0] in ('-h', '--help'):
        print('usage: loopable <tool> [\'<json arguments>\' | -]\n'
              'The loopable MCP stand-in: the same tool names and argument names.', file=sys.stderr)
        return 2
    name = argv[0]
    raw = argv[1] if len(argv) > 1 else '{}'
    if raw == '-':
        raw = sys.stdin.read()
    try:
        a = json.loads(raw) if raw.strip() else {}
        if not isinstance(a, dict):
            raise ValueError('not an object')
    except ValueError as e:
        print('The arguments are not a JSON object: ' + str(e), file=sys.stderr)
        return 2
    status, result = run_tool(name, a)
    print(json.dumps(result, indent=2))
    return 0 if status < 300 else 1


# ------------------------------------------------------------ the HTTP API --
def route(method, path, query, body):
    """The API routes the plugin's scripts and hooks call, mapped onto the tools."""
    p = path.rstrip('/').split('/')[1:]          # ['agent', 'projects', P, ...]
    if p == ['agent', 'whoami']:
        return run_tool('whoami', {}, 'http')
    if len(p) < 3 or p[:2] != ['agent', 'projects']:
        return 404, {'error': 'no route ' + path}
    pid, rest = p[2], p[3:]
    a = {'project_id': pid}
    if rest == ['items'] and method == 'GET':
        status, r = run_tool('list_backlog', a, 'http')
        return status, r
    if rest == ['items', 'next-ready'] and method == 'GET':
        return run_tool('next_ready', a, 'http')
    if len(rest) == 3 and rest[0] == 'items' and rest[2] == 'pack' and method == 'GET':
        return run_tool('pull_item', {**a, 'item_id': rest[1]}, 'http')
    if len(rest) == 2 and rest[0] == 'items':
        if method == 'GET':
            return run_tool('get_item', {**a, 'item_id': rest[1]}, 'http')
        if method == 'PATCH':
            return run_tool('report_progress', {**a, 'item_id': rest[1], **body}, 'http')
    if rest == ['sessions']:
        if method == 'POST':
            return run_tool('open_session', {**a, **body}, 'http')
        if method == 'GET':
            return run_tool('list_sessions', {**a, 'item_id': (query.get('item_id') or [None])[0]}, 'http')
    if len(rest) == 2 and rest[0] == 'sessions' and method == 'GET':
        try:
            with Backlog() as b:
                s = b.session(rest[1])
                return 200, {'session': b.session_view(s)}
        except Refused as r:
            return r.status, {'error': r.message}
    if len(rest) == 3 and rest[0] == 'sessions' and method == 'POST':
        if rest[2] == 'activities':
            return run_tool('post_activity', {**a, 'session_id': rest[1], **body}, 'http')
        if rest[2] == 'close':
            return run_tool('close_session', {**a, 'session_id': rest[1], **body}, 'http')
        if rest[2] == 'attachments':
            with Backlog() as b:
                b.session(rest[1])
                aid = b.new_id()
                b.s.setdefault('attachments', {})[aid] = {'session_id': rest[1], 'status': 'pending',
                                                          'filename': body.get('filename')}
            log({'op': 'attachment_requested', 'via': 'http', 'ok': True, 'session_id': rest[1],
                 'filename': body.get('filename')})
            return 200, {'attachment_id': aid,
                         'upload': {'url': 'https://uploads.example.invalid/fixture',
                                    'fields': {'key': 'attachments/' + aid}}}
    if len(rest) == 5 and rest[0] == 'sessions' and rest[2] == 'attachments' and rest[4] == 'confirm':
        with Backlog() as b:
            att = b.s.get('attachments', {}).get(rest[3])
            if not att:
                return 404, {'error': 'no attachment ' + rest[3]}
            att['status'] = 'stored'
        log({'op': 'attachment_confirmed', 'via': 'http', 'ok': True, 'session_id': rest[1]})
        return 200, {'attachment': {'id': rest[3], 'status': 'stored'}}
    return 404, {'error': 'no route ' + method + ' ' + path}


def main_curl(argv):
    opts = {'method': None, 'data': None, 'fmt': None, 'out': None, 'form': []}
    url, fail = None, False
    takes = {'-X': 'method', '--request': 'method', '-H': None, '--header': None,
             '-d': 'data', '--data': 'data', '--data-binary': 'data', '--data-raw': 'data',
             '-w': 'fmt', '--write-out': 'fmt', '-o': 'out', '--output': 'out',
             '-F': 'form', '--form': 'form', '--max-time': None, '-m': None,
             '--connect-timeout': None, '-u': None, '-A': None}

    def take(what, val):
        if what == 'form':
            opts['form'].append(val)
        elif what == 'data':
            opts['data'] = Path(val[1:]).read_text() if val.startswith('@') else val
        elif what:
            opts[what] = val

    i = 0
    while i < len(argv):
        arg = argv[i]
        i += 1
        if arg in takes:
            take(takes[arg], argv[i] if i < len(argv) else '')
            i += 1
        elif arg.startswith('--'):
            fail = fail or arg == '--fail'
        elif arg.startswith('-') and len(arg) > 1:
            # A cluster of short flags, like -fsS. A flag that takes a value
            # takes the rest of the cluster, or else the next argument.
            for j, ch in enumerate(arg[1:], 1):
                fail = fail or ch == 'f'
                if '-' + ch in takes:
                    rest = arg[j + 1:]
                    if not rest:
                        rest = argv[i] if i < len(argv) else ''
                        i += 1
                    take(takes['-' + ch], rest)
                    break
        else:
            url = arg
    method, data, fmt, out, form = opts['method'], opts['data'], opts['fmt'], opts['out'], opts['form']
    if not url:
        print('curl: no URL specified', file=sys.stderr)
        return 2
    method = method or ('POST' if data is not None or form else 'GET')
    parts = urlsplit(url)
    host = parts.hostname or ''
    if parts.path.startswith('/agent/'):
        try:
            body = json.loads(data) if data else {}
        except ValueError:
            status, result = 400, {'error': 'the body is not JSON'}
        else:
            status, result = route(method, parts.path, parse_qs(parts.query), body if isinstance(body, dict) else {})
        text = json.dumps(result)
    elif host == 'uploads.example.invalid':
        log({'op': 'attachment_uploaded', 'via': 'http', 'ok': True})
        status, text = 204, ''
    elif host == 'api.example.invalid' and parts.path == '/version':
        deployed = ROOT / 'deployed'
        sha = deployed.read_text().strip() if deployed.exists() else (ROOT / 'deployed-before').read_text().strip()
        status, text = 200, json.dumps({'sha': sha})
    else:
        print('curl: (6) Could not resolve host: ' + host, file=sys.stderr)
        return 6
    if fail and status >= 400:
        print('curl: (22) The requested URL returned error: ' + str(status), file=sys.stderr)
        return 22
    if out:
        if out != '/dev/null':
            Path(out).write_text(text)
    else:
        sys.stdout.write(text)
    if fmt:
        sys.stdout.write(fmt.replace('%{http_code}', str(status)).replace('\\n', '\n'))
    return 0


if __name__ == '__main__':
    me = Path(sys.argv[0]).name
    sys.exit(main_curl(sys.argv[1:]) if me == 'curl' else main_tool(sys.argv[1:]))
