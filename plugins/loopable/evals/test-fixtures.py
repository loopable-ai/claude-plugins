#!/usr/bin/env python3
"""The offline self-test of the lifecycle evals: no model, no network, no token.

It proves the environment, not the driver. For every case it builds the
workspace and checks the fixture is what the case says it is (a fail at the
head, a head that moved, a start that breaks); then it walks the case twice
through the real plugin scripts and the stand-ins, with the commands a driver
would type:

  the right walk   every grader in the case's case.yaml passes
  a wrong walk     the graders written for that mistake fail

and a workspace nobody touched fails at least one grader, so no case passes by
doing nothing. Every grader of every case fails on at least one of the case's
wrong walks or on the untouched workspace (test_every_grader_can_fail), so no
grader is one that cannot fail. The graders are read from case.yaml and scored here the way
`claude plugin eval` scores them — file_exists and regex over the workspace,
tool_used and tool_order over the walk's own list of tool calls — so a grader
that cannot fail, or a fixture that changed under one, goes red here first.

Run: python3 -B plugin/evals/test-fixtures.py   (guards.yml runs it on every PR)
The last line is the count: read it, not the colour.
"""
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

EVALS = Path(__file__).resolve().parent
LIB = EVALS / '_lib'
CASES = EVALS / 'lifecycle'
EXPECTED = ['after-merge', 'broken-start', 'cleanup-merged', 'fail-at-head', 'hand-made-pr',
            'moved-head', 'owner-asks', 'rounds-escalate', 'rounds-widening']
GRADED = {'count': 0}
OUTCOME = '.loopable-eval/outcome.md'


# ------------------------------------------------- case.yaml, strictly --
def scalar(text):
    """A double-quoted string or a flow map/list in JSON's spelling, a bare
    list of words, a boolean, an integer, or a plain word."""
    text = text.strip()
    if text.startswith(('"', '{', '["')):
        return json.loads(text)
    if text.startswith('[') and text.endswith(']'):
        return [t.strip() for t in text[1:-1].split(',') if t.strip()]
    if text in ('true', 'false'):
        return text == 'true'
    if re.fullmatch(r'-?\d+', text):
        return int(text)
    if re.fullmatch(r'[\w.:/-]+', text):
        return text
    raise AssertionError('not a scalar this suite reads: ' + text)


def read_case(path):
    """The subset of YAML these cases are written in, and nothing more: a line
    this does not understand is an error, never a guess."""
    case, graders, current, section = {}, [], None, None
    for n, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        if not line.startswith(' '):
            key, _, value = line.partition(':')
            section = key
            if key == 'graders':
                case['graders'] = graders
            elif key == 'context':
                case['context'] = {}
            else:
                case[key] = scalar(value)
            continue
        m = re.fullmatch(r'  - (\w+): (.*)', line)
        if m and section == 'graders':
            current = {m.group(1): scalar(m.group(2))}
            graders.append(current)
            continue
        m = re.fullmatch(r'    (\w+): (.*)', line)
        if m and section == 'graders' and current is not None:
            current[m.group(1)] = scalar(m.group(2))
            continue
        m = re.fullmatch(r'  (\w+): (.*)', line)
        if m and section == 'context':
            case['context'][m.group(1)] = scalar(m.group(2))
            continue
        raise AssertionError(f'{path}:{n}: not a line this suite reads: {line!r}')
    return case


# -------------------------------------------------------- the graders --
def flags_of(g):
    f = 0
    for ch in g.get('flags', ''):
        f |= {'i': re.I, 'm': re.M, 's': re.S}[ch]
    return f


def grade(g, ws, calls):
    """True when grader g passes on workspace ws after the tool calls `calls`."""
    GRADED['count'] += 1
    kind = g['type']
    if kind == 'file_exists':
        return (ws / g['path']).exists() == g.get('exists', True)
    if kind == 'regex':
        target = g['target']
        assert target['source'] == 'file', target
        p = ws / target['path']
        text = p.read_text() if p.is_file() else ''
        found = re.search(g['pattern'], text, flags_of(g)) is not None
        return found if g.get('match', 'contains') == 'contains' else not found
    if kind == 'tool_used':
        n = sum(1 for tool, inp in calls if tool == g['tool'] and re.search(g['input_match'], inp))
        return g.get('min', 1) <= n <= g.get('max', 10 ** 9)
    if kind == 'tool_order':
        def first(spec):
            return next((i for i, (tool, inp) in enumerate(calls)
                         if tool == spec['tool'] and re.search(spec['input_match'], inp)), None)
        b, a = first(g['before']), first(g['after'])
        return b is not None and a is not None and b < a
    raise AssertionError('a grader type this suite cannot score: ' + kind)


# ------------------------------------------------------------ the walk --
class Walk:
    """A workspace, and the tool calls made in it, as a driver would make them."""

    def __init__(self, scenario):
        self.tmp = tempfile.TemporaryDirectory()
        self.ws = Path(self.tmp.name).resolve()
        self.calls = []
        built = subprocess.run(['bash', str(CASES / scenario / 'fixture.sh')], cwd=self.ws,
                               capture_output=True, text=True)
        assert built.returncode == 0, built.stderr
        self.fx = json.loads((self.ws / '.loopable-eval/fixture.json').read_text())
        self.env = {**{k: v for k, v in os.environ.items() if k not in ('CLAUDE_PROJECT_DIR', 'LOOPABLE_REPO')},
                    'PATH': str(self.ws / '.loopable-eval/bin') + os.pathsep + os.environ['PATH'],
                    'LOOPABLE_API_URL': 'https://backlog.example.invalid', 'LOOPABLE_TOKEN': 'fixture-token',
                    'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull,
                    'GIT_AUTHOR_NAME': 'Walk', 'GIT_AUTHOR_EMAIL': 'walk@example.invalid',
                    'GIT_COMMITTER_NAME': 'Walk', 'GIT_COMMITTER_EMAIL': 'walk@example.invalid'}
        self.plugin = self.ws / '.loopable-eval/plugin'

    def close(self):
        self.tmp.cleanup()

    def read(self, rel):
        self.calls.append(('Read', json.dumps({'file_path': str(self.ws / rel)})))
        return (self.ws / rel).read_text()

    def bash(self, command, cwd=None, ok=True):
        self.calls.append(('Bash', json.dumps({'command': command})))
        done = subprocess.run(['bash', '-c', command], cwd=cwd or self.ws, env=self.env,
                              capture_output=True, text=True)
        if ok is not None:
            assert (done.returncode == 0) == ok, (command, done.returncode, done.stdout, done.stderr)
        return done

    def tool(self, name, args, ok=True):
        return json.loads(self.bash('loopable ' + name + " '" + json.dumps(args).replace("'", "'\\''") + "'",
                                    ok=ok).stdout)

    def agent(self, subagent_type, name, prompt='dry run'):
        self.calls.append(('Agent', json.dumps({'subagent_type': subagent_type, 'name': name, 'prompt': prompt})))

    def write(self, path, text):
        self.calls.append(('Write', json.dumps({'file_path': str(path)})))
        Path(path).write_text(text)

    def post(self, session, kind, body, ref, ok=True):
        return self.tool('post_activity', {'project_id': self.fx['project'], 'session_id': session,
                                           'kind': kind, 'body': body, 'ref': ref}, ok=ok)

    def outcome(self, text):
        self.write(self.ws / '.loopable-eval/outcome.md', text)

    def json(self, rel):
        return json.loads((self.ws / rel).read_text())

    def git(self, *args, cwd=None):
        return subprocess.check_output(['git', *args], cwd=cwd or self.ws, env=self.env, text=True).strip()


class Case:
    """Mixed into each case's TestCase. WRONG names that case's wrong-walk tests:
    test_every_grader_can_fail runs each one in a fresh workspace and wants every
    grader of the case to fail on one of them, or on the untouched workspace."""
    scenario = None
    WRONG = ()

    def test_every_grader_can_fail(self):
        failed = set(self.failing())
        for name in self.WRONG:
            self.w.close()
            self.w = Walk(self.scenario)
            getattr(self, name)()
            failed |= set(self.failing())
        never = [g['name'] for g in self.case['graders'] if g['name'] not in failed]
        self.assertEqual(never, [], 'graders no wrong walk and no untouched workspace makes fail')

    def setUp(self):
        self.w = Walk(self.scenario)
        self.case = read_case(CASES / self.scenario / 'case.yaml')

    def tearDown(self):
        self.w.close()

    def failing(self):
        return [g['name'] for g in self.case['graders'] if not grade(g, self.w.ws, self.w.calls)]

    def assertAllPass(self):
        self.assertEqual(self.failing(), [], 'graders that fail on the right walk')

    def assertFails(self, *names):
        failing = self.failing()
        for n in names:
            self.assertIn(n, failing, 'a grader that should catch this wrong walk passed')

    def begin(self):
        """Every walk starts where every model run starts: reading the role."""
        role = self.w.read('.loopable-eval/role.md')
        self.assertIn('name: driver', role)


# ----------------------------------------------------- the whole suite --
class TheSuite(unittest.TestCase):
    def test_exactly_the_cases_the_brief_names(self):
        self.assertEqual(sorted(p.name for p in CASES.iterdir() if p.is_dir()), EXPECTED)

    def test_every_case_is_complete_and_named_for_its_directory(self):
        for d in sorted(CASES.iterdir()):
            with self.subTest(case=d.name):
                for f in ('case.yaml', 'fixture.sh', 'prompt.md'):
                    self.assertTrue((d / f).is_file(), f)
                case = read_case(d / 'case.yaml')
                self.assertEqual(case['name'], 'lifecycle-' + d.name)
                self.assertEqual(case['plugins'], ['../../..'])
                self.assertEqual(case['context'], {'scaffold_script': 'fixture.sh'})
                self.assertIn('lifecycle', case['tags'])
                self.assertGreaterEqual(len(case['graders']), 5)
                self.assertEqual(len({g['name'] for g in case['graders']}), len(case['graders']))
                self.assertIn('fixture.py" ' + d.name + '\n', (d / 'fixture.sh').read_text())
                # All three kinds, in every case: a grader over tool use, one over
                # the outcome file the prompt asks for, and one over a side-effect
                # marker the workspace holds.
                graders = case['graders']
                self.assertTrue([g for g in graders if g['type'] in ('tool_used', 'tool_order')], 'tool use')
                self.assertTrue([g for g in graders if g['type'] == 'regex'
                                 and g['target'] == {'source': 'file', 'path': OUTCOME}], 'the outcome file')
                self.assertTrue([g for g in graders if g['type'] == 'file_exists'], 'a side-effect marker')
                self.assertIn('`' + OUTCOME + '`', (d / 'prompt.md').read_text())

    def test_every_prompt_shares_one_preamble_and_runs_the_role(self):
        preambles = set()
        for d in sorted(CASES.iterdir()):
            text = (d / 'prompt.md').read_text()
            self.assertIn('\nTASK\n', text, d.name)
            preambles.add(text.split('\nTASK\n')[0])
            self.assertIn('.loopable-eval/role.md', text)
        self.assertEqual(len(preambles), 1, 'the prompts drifted apart above TASK')

    def test_the_plugin_under_test_is_copied_in_unmodified(self):
        w = Walk('broken-start')
        try:
            plugin = EVALS.parent
            self.assertEqual((w.ws / '.loopable-eval/role.md').read_text(), (plugin / 'agents/driver.md').read_text())
            for rel in ('bin/start.sh', 'bin/ship.sh', 'hooks/lib.sh', 'skills/loopable/driver-events.md'):
                self.assertEqual((w.ws / '.loopable-eval/plugin' / rel).read_bytes(), (plugin / rel).read_bytes(), rel)
        finally:
            w.close()

    def test_every_fixture_is_a_real_clean_repository_with_a_local_origin(self):
        for name in EXPECTED:
            with self.subTest(case=name):
                w = Walk(name)
                try:
                    self.assertEqual(w.git('status', '--porcelain'), '')
                    self.assertEqual(w.git('symbolic-ref', '--short', 'HEAD'), 'main')
                    origin = w.git('remote', 'get-url', 'origin')
                    self.assertEqual(origin, str(w.ws / '.loopable-eval/origin.git'))
                    self.assertEqual(w.git('rev-parse', 'main'), w.git('--git-dir', origin, 'rev-parse', 'main'))
                    self.assertEqual(w.git('check-ignore', '.loopable-eval/x'), '.loopable-eval/x')
                    for log in ('github-calls.jsonl', 'backlog-events.jsonl'):
                        self.assertEqual((w.ws / '.loopable-eval' / log).read_text(), '')
                    # A workspace nobody touched passes no case.
                    case = read_case(CASES / name / 'case.yaml')
                    self.assertTrue([g for g in case['graders'] if not grade(g, w.ws, [])],
                                    'every grader passes with nothing done')
                finally:
                    w.close()


class TheStandIns(unittest.TestCase):
    def test_gh_logs_every_call_and_persists_writes_across_processes(self):
        w = Walk('hand-made-pr')
        try:
            w.bash('gh pr ready 203')
            self.assertFalse(json.loads(w.bash('gh pr view 203 --json isDraft').stdout)['isDraft'])
            self.assertEqual(w.bash('gh pr view feat/page-paths-41 --json number -q .number').stdout.strip(), '203')
            out = w.bash('gh api repos/fixture/shop', ok=False)
            self.assertEqual(out.returncode, 2)
            calls = [json.loads(l)['argv'] for l in (w.ws / '.loopable-eval/github-calls.jsonl').read_text().splitlines()]
            self.assertEqual(calls[0], ['pr', 'ready', '203'])
            self.assertEqual(len(calls), 4)
        finally:
            w.close()

    def test_gh_accepts_an_unsafe_merge_and_leaves_the_markers(self):
        w = Walk('fail-at-head')
        try:
            w.bash('gh pr merge 203 --squash --delete-branch')
            self.assertTrue((w.ws / '.loopable-eval/merge-requested').is_file())
            self.assertTrue((w.ws / '.loopable-eval/merged').is_file())
            origin = w.ws / '.loopable-eval/origin.git'
            self.assertIn('(#203)', w.git('--git-dir', str(origin), 'log', '-1', '--format=%s', 'main'))
        finally:
            w.close()

    def test_gh_refuses_to_merge_a_draft_as_github_does(self):
        w = Walk('hand-made-pr')
        try:
            w.bash('gh pr merge 203 --squash', ok=False)
            self.assertTrue((w.ws / '.loopable-eval/merge-requested').is_file())
            self.assertFalse((w.ws / '.loopable-eval/merged').exists())
        finally:
            w.close()

    def test_backlog_keeps_the_api_refusals_the_plugin_is_written_around(self):
        w = Walk('after-merge')
        try:
            p = w.fx['project']
            refused = w.tool('report_progress', {'project_id': p, 'item_id': '41', 'status': 'done'}, ok=False)
            self.assertIn('cannot move', refused['error'])
            refused = w.tool('report_progress', {'project_id': p, 'item_id': '41', 'status': 'ready'}, ok=False)
            self.assertIn('cannot move', refused['error'])
            closed = w.fx['sessions'][-1]
            again = w.tool('close_session', {'project_id': p, 'session_id': closed, 'state': 'error'}, ok=False)
            self.assertIn('closes once', again['error'])
            w.tool('add_item', {'project_id': p, 'title': 'mine', 'kind': 'task'})
            filed = w.tool('list_backlog', {'project_id': p, 'status': 'todo'})['items'][-1]
            w.tool('write_brief', {'project_id': p, 'item_id': str(filed['ref']), 'title': 'mine',
                                   'criteria': [{'text': 'it is', 'verify': 'manual'}]})
            w.tool('report_progress', {'project_id': p, 'item_id': str(filed['ref']), 'status': 'ready'})
            lines = (w.ws / '.loopable-eval/backlog-events.jsonl').read_text().splitlines()
            self.assertEqual([json.loads(l)['ok'] for l in lines if '"report_progress"' in l], [False, False, True])
        finally:
            w.close()

    def test_ready_on_its_own_filing_waits_for_readiness_as_the_api_does(self):
        """OWN_FILING_EDGES lets the token take todo -> ready on its own filing,
        and updateItem's readyGate refuses it while readiness() has blockers."""
        w = Walk('after-merge')
        try:
            p = w.fx['project']
            w.tool('add_item', {'project_id': p, 'title': 'mine, unbriefed', 'kind': 'task'})
            ref = str(w.tool('list_backlog', {'project_id': p, 'status': 'todo'})['items'][-1]['ref'])
            refused = w.tool('report_progress', {'project_id': p, 'item_id': ref, 'status': 'ready'}, ok=False)
            self.assertIn('readiness has blockers: no_brief, no_verifiable_criterion', refused['error'])
            pack = w.tool('pull_item', {'project_id': p, 'item_id': ref})['pack']
            self.assertEqual(pack['item']['ready_blockers'], ['no_brief', 'no_verifiable_criterion'])
            self.assertEqual(w.tool('get_item', {'project_id': p, 'item_id': ref})['item']['status'], 'todo')
            # The delegate (the holder's edges) meets the same gate (380).
            state = w.ws / '.loopable-eval/backlog.json'
            s = json.loads(state.read_text())
            s['token']['person_edges'] = True
            s['environments'] = []
            state.write_text(json.dumps(s))
            w.tool('write_brief', {'project_id': p, 'item_id': ref, 'title': 'mine',
                                   'criteria': [{'text': 'it is', 'verify': 'manual'}]})
            refused = w.tool('report_progress', {'project_id': p, 'item_id': ref, 'status': 'ready'}, ok=False)
            self.assertIn('readiness has blockers: no_environment', refused['error'])
        finally:
            w.close()

    def test_curl_answers_the_api_the_upload_bucket_and_the_deploy_only(self):
        w = Walk('after-merge')
        try:
            out = w.bash('curl -fsS -H "Authorization: Bearer x" "https://api.loopable.ai/agent/projects/'
                         + w.fx['project'] + '/items"').stdout
            self.assertEqual(sorted(i['ref'] for i in json.loads(out)['items']), [41])
            out = w.bash("curl -sS -X POST -w '\\n%{http_code}' --data-binary '{}' "
                         "https://backlog.example.invalid/agent/projects/nope/sessions").stdout
            self.assertEqual(out.splitlines()[-1], '404')
            self.assertEqual(w.bash('curl -fsS https://backlog.example.invalid/agent/projects/nope/items',
                                    ok=False).returncode, 22)
            self.assertEqual(json.loads(w.bash('curl -s https://api.example.invalid/version').stdout)['sha'],
                             w.fx['base'])
            self.assertEqual(w.bash('curl -s https://example.com', ok=False).returncode, 6)
        finally:
            w.close()


# ------------------------------------------- who the eval key reaches --
WORKFLOW = EVALS.parents[1] / '.github/workflows/plugin-evals.yml'


class TheRevisionCheck(unittest.TestCase):
    """plugin-evals.yml hands ANTHROPIC_API_KEY to the two revisions that
    main-revisions.sh admits. Each test runs that script, the way the workflow
    does, in a clone of a scratch origin: main (m1, m2, a release tag at m1) and
    an unmerged branch (u). Every way round the check found so far is one test."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name).resolve()
        cls.env = {**os.environ, 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull,
                   'GIT_AUTHOR_NAME': 'Check', 'GIT_AUTHOR_EMAIL': 'check@example.invalid',
                   'GIT_COMMITTER_NAME': 'Check', 'GIT_COMMITTER_EMAIL': 'check@example.invalid'}
        cls.origin, seed = root / 'origin.git', root / 'seed'
        git = lambda *a, cwd=seed: subprocess.check_output(['git', *a], cwd=cwd, env=cls.env, text=True).strip()
        git('init', '-q', '--bare', '-b', 'main', str(cls.origin), cwd=root)
        git('clone', '-q', str(cls.origin), str(seed), cwd=root)
        git('commit', '-q', '--allow-empty', '-m', 'm1')
        cls.m1 = git('rev-parse', 'HEAD')
        git('tag', 'loopable-plugin-v1.0.0')
        git('commit', '-q', '--allow-empty', '-m', 'm2')
        cls.m2 = git('rev-parse', 'HEAD')
        git('checkout', '-q', '-b', 'unmerged')
        git('commit', '-q', '--allow-empty', '-m', 'u: code nobody merged')
        cls.u = git('rev-parse', 'HEAD')
        git('push', '-q', 'origin', 'main', 'unmerged', 'loopable-plugin-v1.0.0')
        cls.root = root
        cls.n = 0

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def checkout(self):
        """A fresh clone of the origin with every branch and tag, on main, as
        actions/checkout with fetch-depth 0 leaves it."""
        type(self).n += 1
        co = self.root / f'checkout-{self.n}'
        subprocess.run(['git', 'clone', '-q', str(self.origin), str(co)], env=self.env, check=True)
        return co

    def git(self, co, *args):
        return subprocess.check_output(['git', *args], cwd=co, env=self.env, text=True).strip()

    def admit(self, co, old, new):
        done = subprocess.run(['bash', str(EVALS / 'main-revisions.sh'), old, new], cwd=co, env=self.env,
                              capture_output=True, text=True)
        return done.returncode, dict(l.split('=', 1) for l in done.stdout.splitlines() if '=' in l), done.stderr

    def assertAdmitted(self, co, old, new, want_old, want_new):
        rc, out, err = self.admit(co, old, new)
        self.assertEqual((rc, out), (0, {'old': want_old, 'new': want_new}), err)

    def assertRefused(self, co, old, new='main'):
        rc, out, err = self.admit(co, old, new)
        self.assertEqual((rc, out), (1, {}), f'{old!r} was admitted: {out} {err}')
        self.assertIn('::error::', err)

    def test_main_head_a_release_tag_and_a_commit_on_main_are_admitted(self):
        co = self.checkout()
        self.assertAdmitted(co, self.m1, 'HEAD', self.m1, self.m2)
        self.assertAdmitted(co, self.m1[:7], 'origin/main', self.m1, self.m2)
        self.assertAdmitted(co, 'refs/remotes/origin/main', self.m1, self.m2, self.m1)
        self.assertAdmitted(co, 'loopable-plugin-v1.0.0', 'main', self.m1, self.m2)
        self.assertAdmitted(co, 'latest-release', 'HEAD', self.m1, self.m2)

    def test_a_commit_compared_with_itself_is_refused(self):
        co = self.checkout()
        for old, new in (('origin/main', 'HEAD'), ('main', 'refs/remotes/origin/main'),
                         (self.m1, self.m1[:7]), ('latest-release', 'loopable-plugin-v1.0.0')):
            rc, out, err = self.admit(co, old, new)
            self.assertEqual((rc, out), (1, {}), f'{old!r} and {new!r} were admitted: {err}')
            self.assertIn('are the same commit', err)

    def test_latest_release_is_the_newest_release_tag_main_holds(self):
        co = self.checkout()
        self.git(co, 'tag', 'loopable-plugin-v1.10.0', self.m2)   # newer than v1.9.0 by version, not by text
        self.git(co, 'tag', 'loopable-plugin-v1.9.0', self.m1)
        self.git(co, 'tag', 'loopable-plugin-v9.9.9', self.u)     # newest of all, on code nobody merged
        self.git(co, 'tag', 'loopable-plugin-v99', self.u)        # not a release's spelling
        self.git(co, 'push', '-q', 'origin', 'loopable-plugin-v1.10.0', 'loopable-plugin-v1.9.0',
                 'loopable-plugin-v9.9.9', 'loopable-plugin-v99')
        try:
            self.assertAdmitted(self.checkout(), 'latest-release', self.m1, self.m2, self.m1)
        finally:
            self.git(co, 'push', '-q', 'origin', ':refs/tags/loopable-plugin-v1.10.0',
                     ':refs/tags/loopable-plugin-v1.9.0', ':refs/tags/loopable-plugin-v9.9.9',
                     ':refs/tags/loopable-plugin-v99')

    def test_a_hex_prefix_that_names_two_commits_on_main_is_refused(self):
        """Two commits on main sharing a seven-digit prefix, found by hashing
        candidate commit objects here (a birthday search, some 20k sha1s) and
        written with hash-object, then merged into main. A prefix that names
        both is refused; loosening the one-commit rule would admit either."""
        import hashlib
        co = self.checkout()
        tree = self.git(co, 'rev-parse', self.m2 + '^{tree}')
        def body(i):
            who = 'Check <check@example.invalid> 1700000000 +0000'
            return (f'tree {tree}\nparent {self.m2}\nauthor {who}\ncommitter {who}\n\ncollide {i}\n').encode()
        seen, i = {}, 0
        while True:
            raw = body(i)
            prefix = hashlib.sha1(b'commit %d\0' % len(raw) + raw).hexdigest()[:7]
            if prefix in seen:
                break
            seen[prefix] = i
            i += 1
        pair = []
        for n in (seen[prefix], i):
            pair.append(subprocess.run(['git', 'hash-object', '-t', 'commit', '-w', '--stdin'], cwd=co,
                                       env=self.env, input=body(n), capture_output=True, check=True)
                        .stdout.decode().strip())
        self.assertEqual({p[:7] for p in pair}, {prefix})
        merge = self.git(co, 'commit-tree', tree, '-p', pair[0], '-p', pair[1], '-m', 'both on main')
        self.git(co, 'push', '-q', 'origin', merge + ':refs/heads/main')
        try:
            fetched = self.checkout()
            self.assertAdmitted(fetched, pair[0], pair[1], pair[0], pair[1])
            rc, out, err = self.admit(fetched, prefix, 'main')
            self.assertEqual((rc, out), (1, {}), f'{prefix} names two commits and was admitted: {err}')
            self.assertIn(f"'{prefix}' names 2 commits", err)
        finally:
            self.git(co, 'push', '-q', '-f', 'origin', self.m2 + ':refs/heads/main')

    def test_round_1_a_revision_main_does_not_hold_is_refused(self):
        co = self.checkout()
        self.assertRefused(co, self.u)
        self.assertRefused(co, self.u[:10])
        self.assertRefused(co, 'unmerged')
        self.assertRefused(co, 'origin/unmerged')
        self.assertRefused(co, 'main', self.u)

    def test_round_2_a_release_tag_on_an_unmerged_commit_is_refused(self):
        co = self.checkout()
        self.git(co, 'tag', 'loopable-plugin-v9.9.9', self.u)
        self.git(co, 'push', '-q', 'origin', 'loopable-plugin-v9.9.9')
        try:
            self.assertRefused(co, 'loopable-plugin-v9.9.9')
            self.assertRefused(self.checkout(), 'loopable-plugin-v9.9.9')
        finally:
            self.git(co, 'push', '-q', 'origin', ':refs/tags/loopable-plugin-v9.9.9')

    def test_round_3_a_tag_or_branch_named_origin_main_stands_in_for_nothing(self):
        co = self.checkout()
        self.git(co, 'tag', 'origin/main', self.u)
        self.git(co, 'push', '-q', 'origin', 'refs/tags/origin/main')
        try:
            fetched = self.checkout()  # the tag arrives with the clone, as with --tags
            self.assertEqual(self.git(fetched, 'rev-parse', 'origin/main'), self.u)  # git's own reading
            self.assertAdmitted(fetched, self.m1, 'origin/main', self.m1, self.m2)
            self.assertRefused(fetched, 'main', self.u)
            self.git(fetched, 'branch', 'origin/main', self.u)
            self.assertAdmitted(fetched, 'origin/main', self.m1, self.m2, self.m1)
        finally:
            self.git(co, 'push', '-q', 'origin', ':refs/tags/origin/main')

    def test_a_remote_tracking_main_moved_by_hand_is_fetched_back(self):
        co = self.checkout()
        self.git(co, 'update-ref', 'refs/remotes/origin/main', self.u)
        self.assertRefused(co, self.u)
        self.assertEqual(self.git(co, 'rev-parse', 'refs/remotes/origin/main'), self.m2)

    def test_an_option_for_a_name_is_refused_and_does_nothing(self):
        co = self.checkout()
        marker = self.root / 'option-ran'
        for value in ('--output=' + str(marker), '-h', '--all', '--remotes', '--end-of-options', '--', ''):
            self.assertRefused(co, value)
            self.assertRefused(co, 'main', value)
        self.assertFalse(marker.exists())

    def test_a_hex_prefix_is_an_object_never_a_ref_of_that_name(self):
        co = self.checkout()
        self.git(co, 'tag', self.m1[:7], self.u)      # a tag shadowing m1's prefix, at u
        self.git(co, 'tag', 'abcdef0', self.u)        # a hex-looking tag no commit starts with
        self.assertAdmitted(co, self.m1[:7], 'main', self.m1, self.m2)
        self.assertRefused(co, 'abcdef0')

    def test_any_other_name_is_refused_before_git_reads_it(self):
        co = self.checkout()
        for value in ('main~0', 'HEAD^', 'origin/main^{commit}', 'refs/heads/main', 'refs/tags/origin/main',
                      'loopable-plugin-v1.0.0^{}','loopable-plugin-v1.0', '@', 'main@{1}', 'm1'):
            self.assertRefused(co, value)

    @unittest.skipUnless(WORKFLOW.exists(), 'the workflow lives in the platform repository, not the release')
    def test_the_workflow_decides_through_this_script_alone(self):
        text = WORKFLOW.read_text()
        step = text.split('- name: Only revisions main already holds', 1)[1].split('\n      - ', 1)[0]
        self.assertIn('plugin/evals/main-revisions.sh "$OLD" "$NEW"', step)
        self.assertIn('>> "$GITHUB_OUTPUT"', step)
        self.assertNotRegex(step, r'rev-parse|merge-base|git fetch')
        evals = text.split('- name: Run the evals', 1)[1].split('\n      - ', 1)[0]
        self.assertIn('OLD: ${{ steps.refs.outputs.old }}', evals)
        self.assertIn('NEW: ${{ steps.refs.outputs.new }}', evals)
        self.assertNotIn('inputs.old', evals)
        self.assertNotIn('inputs.new', evals)
        self.assertLess(text.index('Only revisions main already holds'), text.index('secrets.ANTHROPIC_API_KEY'))

    @unittest.skipUnless(WORKFLOW.exists(), 'the workflow lives in the platform repository, not the release')
    def test_the_forms_defaults_dispatched_from_main_compare_two_commits(self):
        """A person who clicks Run on main with the form untouched: actions/checkout
        leaves HEAD at main's tip, and the run must still compare two commits."""
        inputs = '\n' + WORKFLOW.read_text().split('    inputs:\n', 1)[1].split('\npermissions:', 1)[0]
        default = lambda name: re.search(r'\n      ' + name + r':\n(?:        .*\n)*?        default: (.*)\n',
                                         inputs).group(1).strip().strip('"')
        old, new = default('old'), default('new')
        co = self.checkout()
        self.assertEqual(self.git(co, 'rev-parse', 'HEAD'), self.m2)
        self.assertAdmitted(co, old, new, self.m1, self.m2)


class TheStatistics(unittest.TestCase):
    def test_cases_are_compared_one_by_one_and_never_pooled(self):
        import contextlib
        import importlib.util
        import io
        spec = importlib.util.spec_from_file_location('ab_stats', EVALS / 'ab-stats.py')
        stats = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(stats)
        run = lambda ok: {'passed': ok, 'graders': [{'name': 'merged', 'passed': ok}]}
        old = {'cases': [{'name': 'lifecycle-fail-at-head', 'arms': {'with': [run(True), run(True)]}},
                         {'name': 'lifecycle-after-merge', 'arms': {'with': [run(True)]}}]}
        new = {'cases': [{'name': 'lifecycle-fail-at-head', 'arms': {'with': [run(False), run(True)]}},
                         {'name': 'lifecycle-after-merge', 'arms': {'with': [run(True)]}}]}
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / 'old.json').write_text(json.dumps(old))
            (Path(d) / 'new.json').write_text(json.dumps(new))
            printed = io.StringIO()
            with contextlib.redirect_stdout(printed):
                stats.main(str(Path(d) / 'old.json'), str(Path(d) / 'new.json'))
        text = printed.getvalue()
        self.assertIn('lifecycle-fail-at-head', text)
        self.assertIn('WORSE in the new arm', text)
        self.assertIn('saturated', text)
        self.assertNotIn('pooled', text)
        self.assertEqual(stats.fisher_two_sided(3, 3, 0, 3), 0.1)


class TheRunner(unittest.TestCase):
    """run-ab.sh, in a scratch repository holding a copy of it, a plugin.json and a
    stand-in self-test that leaves a marker, prints a count line shaped like this
    file's, and exits as told. DRY=1 throughout: nothing reaches claude."""

    STUB = ('import os, sys\n'
            "open(os.environ['MARK'], 'w').close()\n"
            "print('F' if os.environ['SELF_TEST_RC'] != '0' else '.')\n"
            "print('\\n3 tests, 7 grader scorings, 9 cases')\n"
            "sys.exit(int(os.environ['SELF_TEST_RC']))\n")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name).resolve() / 'repo'
        (self.repo / 'plugin/evals').mkdir(parents=True)
        (self.repo / 'plugin/.claude-plugin').mkdir()
        (self.repo / 'plugin/.claude-plugin/plugin.json').write_text('{"version": "0.0.1"}\n')
        shutil.copy(EVALS / 'run-ab.sh', self.repo / 'plugin/evals/run-ab.sh')
        (self.repo / 'plugin/evals/test-fixtures.py').write_text(self.STUB)
        self.env = {**os.environ, 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull,
                    'GIT_AUTHOR_NAME': 'Check', 'GIT_AUTHOR_EMAIL': 'check@example.invalid',
                    'GIT_COMMITTER_NAME': 'Check', 'GIT_COMMITTER_EMAIL': 'check@example.invalid',
                    'DRY': '1', 'MARK': str(self.repo.parent / 'self-test-ran'), 'SELF_TEST_RC': '0'}
        for args in (['init', '-q', '-b', 'main'], ['add', '-A'], ['commit', '-q', '-m', 'one']):
            subprocess.run(['git', *args], cwd=self.repo, env=self.env, check=True)

    def tearDown(self):
        self.tmp.cleanup()

    def run_ab(self, *refs, **env):
        import time
        start = time.monotonic()
        done = subprocess.run(['bash', 'plugin/evals/run-ab.sh', *refs], cwd=self.repo,
                              env={**self.env, **env}, capture_output=True, text=True, timeout=60)
        return done, time.monotonic() - start

    def test_a_bad_revision_fails_at_once_naming_it_before_the_self_test(self):
        for refs, bad in ((('no-such-ref', 'HEAD'), "old revision 'no-such-ref'"),
                          (('HEAD', 'deadbeef'), "new revision 'deadbeef'"),
                          (('HEAD', '--output=x'), "new revision '--output=x'")):
            done, took = self.run_ab(*refs)
            self.assertEqual(done.returncode, 2, done.stderr)
            self.assertEqual(done.stderr.splitlines(), [f'run-ab.sh: {bad} is not a commit here; nothing was run'])
            self.assertEqual(done.stdout, '')
            self.assertFalse(Path(self.env['MARK']).exists(), 'the self-test ran before the refs were checked')
            self.assertLess(took, 5)
        self.assertFalse((self.repo / 'x').exists())

    def test_a_red_self_test_prints_no_count_line(self):
        done, _ = self.run_ab('HEAD', 'HEAD', SELF_TEST_RC='1')
        self.assertEqual(done.returncode, 1)
        self.assertTrue(Path(self.env['MARK']).exists())
        self.assertIn('the offline self-test is red; nothing was run', done.stderr)
        self.assertIn('F', done.stderr.splitlines())
        self.assertNotIn('grader scorings', done.stdout + done.stderr)

    def test_a_green_self_test_prints_its_count_and_goes_on(self):
        done, _ = self.run_ab('HEAD', 'main')
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.splitlines()[0], '3 tests, 7 grader scorings, 9 cases')
        sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.repo, env=self.env, text=True)
        self.assertIn(f'== old: HEAD ({sha[:12]}, plugin 0.0.1)', done.stdout)
        self.assertIn('claude plugin eval', done.stdout)

    def test_the_count_line_it_hides_is_the_one_this_file_prints(self):
        text = Path(__file__).read_text()
        self.assertIn('''print(f"\\n{ran} tests, {GRADED['count']} grader scorings, {len(EXPECTED)} cases")''', text)
        self.assertIn("count_line='^[0-9]+ tests, [0-9]+ grader scorings, [0-9]+ cases$'",
                      (EVALS / 'run-ab.sh').read_text())


# ------------------------------------------------------------ the cases --
class BrokenStart(Case, unittest.TestCase):
    scenario = 'broken-start'
    WRONG = ('test_a_stand_in_with_no_bug_filed_fails', 'test_stopping_at_the_breakage_fails',
             'test_a_stand_in_out_of_the_scripts_order_fails', 'test_reaching_past_the_start_fails')

    def start(self):
        self.begin()
        out = self.w.bash('"' + str(self.w.plugin) + '/bin/start.sh" 41', ok=False)
        self.assertEqual(out.returncode, 1)
        self.assertIn('was started but no worktree is checked out on it', out.stderr)
        return out

    def test_the_fixture_breaks_start_sh_and_reports_nothing(self):
        out = self.start()
        self.assertIn('Removed the branch feat/page-paths-41', out.stderr)
        # It made a worktree, detached, and nothing on the item's branch.
        listing = self.w.git('worktree', 'list', '--porcelain')
        self.assertIn('detached', listing)
        self.assertNotIn('refs/heads/feat/page-paths-41', listing)
        ops = [json.loads(l)['op'] for l in (self.w.ws / '.loopable-eval/backlog-events.jsonl').read_text().splitlines()]
        self.assertEqual(ops, ['list_backlog', 'pull_item'], 'start.sh reported nothing before it broke')
        self.assertEqual(self.w.json('.loopable-eval/backlog.json')['items'][self.w.fx['item']['id']]['status'], 'ready')

    def stand_in(self, file_bug=True, in_order=True):
        w, p = self.w, self.w.fx['project']
        failure = self.start().stderr
        w.tool('pull_item', {'project_id': p, 'item_id': '41'})
        wt = w.fx['expected_worktree']
        steps = {
            'worktree': lambda: w.bash('git worktree add -b feat/page-paths-41 ' + wt + ' origin/main'),
            'claim': lambda: w.tool('report_progress', {
                'project_id': p, 'item_id': '41', 'status': 'in_progress',
                'note': 'started on branch feat/page-paths-41 (worktree ' + wt + ')'}),
            'session': lambda: w.tool('open_session', {
                'project_id': p, 'item_id': '41', 'harness': 'claude-code', 'repo': 'fixture/shop',
                'branch': 'feat/page-paths-41'})['session']['id'],
        }
        done = {k: steps[k]() for k in (('worktree', 'claim', 'session') if in_order
                                        else ('session', 'claim', 'worktree'))}
        sess = done['session']
        bug = 0
        if file_bug:
            bug = w.tool('add_item', {'project_id': p, 'kind': 'bug', 'title': 'start.sh: no worktree on the branch',
                                      'body': failure})['item']['ref']
        w.post(sess, 'action', 'Stood in for start.sh.', {'event': 'stood_in', 'script': 'start.sh',
                                                          'failure': failure, 'did': 'worktree\nclaim\nsession',
                                                          'bug': bug})
        w.outcome('Stood in for start.sh; filed bug ' + str(bug) + '.')
        return sess

    def test_the_right_walk_passes_every_grader(self):
        self.stand_in()
        self.assertAllPass()

    def test_a_stand_in_out_of_the_scripts_order_fails(self):
        # The session before the claim, the claim before there is a worktree.
        self.stand_in(in_order=False)
        self.assertFails('worktree-before-the-claim', 'claim-before-the-session')

    def test_reaching_past_the_start_fails(self):
        sess = self.stand_in()
        self.w.post(sess, 'thought', 'Refused.', {'event': 'start_refused', 'blockers': 'none'})
        self.w.bash('git worktree remove --force ' + str(self.w.ws / '.loopable/worktrees/page-paths-41'))
        self.w.agent('loopable:builder', 'builder-41')
        self.assertFails('no-start-refused', 'no-force', 'no-build')

    def test_a_stand_in_with_no_bug_filed_fails(self):
        # stood_in still names a number — 0, the bug nobody filed — and the grader wants 42.
        self.stand_in(file_bug=False)
        self.assertFails('bug-filed', 'bug-before-stood-in', 'stood-in-names-the-bug')

    def test_stopping_at_the_breakage_fails(self):
        self.start()
        self.assertFails('claimed', 'session-on-the-branch', 'stood-in-names-the-bug')


class HandMadePr(Case, unittest.TestCase):
    scenario = 'hand-made-pr'
    WRONG = ('test_a_second_pull_request_fails', 'test_rewriting_the_builders_body_fails',
             'test_verifying_again_fails')

    def test_the_fixture_is_a_draft_the_builder_opened_with_both_reports_in(self):
        st = Path(self.w.fx['state'])
        self.assertEqual(json.loads((st / 'verify.json').read_text())['verdict'], 'pass')
        self.assertTrue((st / 'review.md').read_text().rstrip().splitlines()[-1].startswith('ship'))
        pr = self.w.json('.loopable-eval/github.json')['prs']
        self.assertEqual(len(pr), 1)
        self.assertTrue(pr[0]['isDraft'])
        self.assertEqual(pr[0]['headRefOid'], self.w.fx['head'])
        self.assertIn('Loopable: 41', pr[0]['body'])

    def close(self):
        self.begin()
        out = self.w.bash('"' + str(self.w.plugin) + '/bin/ship.sh" --close', cwd=self.w.fx['worktree'])
        self.assertIn('Commented on https://github.com/fixture/shop/pull/203', out.stdout)
        self.assertIn('Marked https://github.com/fixture/shop/pull/203 ready', out.stdout)

    def test_the_right_walk_passes_every_grader(self):
        self.close()
        self.w.bash('gh pr merge 203 --squash --delete-branch')
        self.w.outcome('Merged 203.')
        self.assertAllPass()
        self.assertEqual(self.w.json('.loopable-eval/github.json')['created_prs'], 0)

    def test_a_second_pull_request_fails(self):
        self.begin()
        self.w.bash('gh pr create --title again --body-file /dev/null', cwd=self.w.fx['worktree'], ok=False)
        self.w.bash('gh pr close 203')
        self.w.bash('gh pr create --title again --body-file /dev/null', cwd=self.w.fx['worktree'])
        self.assertFails('no-second-pr', 'ran-close', 'merged')

    def test_rewriting_the_builders_body_fails(self):
        self.close()
        self.w.bash('gh pr edit 203 --body "rewritten"')
        self.w.bash('gh pr merge 203 --squash --delete-branch')
        self.assertFails('no-edit')

    def test_verifying_again_fails(self):
        # Both reports are in for this head: a second verifier is a step nobody asked for.
        self.begin()
        self.w.agent('loopable:verifier', 'verifier-41')
        self.close()
        self.w.bash('gh pr merge 203 --squash --delete-branch')
        self.w.outcome('Merged 203.')
        self.assertFails('no-rerun')


class CleanupMerged(Case, unittest.TestCase):
    scenario = 'cleanup-merged'
    WRONG = ('test_removing_every_ended_worktree_without_looking_fails', 'test_forcing_and_starting_fails')

    def wt(self, ref):
        return self.w.fx['worktrees'][str(ref)]

    def test_the_fixture_has_each_kind_of_worktree(self):
        w = self.w
        listing = w.git('worktree', 'list', '--porcelain')
        self.assertIn('prunable', listing.split('worktree ' + self.wt(46)['worktree'])[1].split('\n\n')[0])
        self.assertIn('!! .env', w.git('-C', self.wt(43)['worktree'], 'status', '--porcelain', '--ignored'))
        self.assertEqual(w.git('-C', self.wt(43)['worktree'], 'status', '--porcelain'), '')
        self.assertNotEqual(w.git('-C', self.wt(45)['worktree'], 'rev-parse', 'HEAD'), self.wt(45)['head'])
        states = {p['number']: p['state'] for p in w.json('.loopable-eval/github.json')['prs']}
        self.assertEqual(states, {191: 'MERGED', 192: 'CLOSED', 193: 'OPEN', 194: 'MERGED', 195: 'MERGED'})
        self.assertTrue((w.ws / '.git/loopable/archive/46/session').is_file())
        self.assertFalse((w.ws / '.git/loopable/archive/46/worktree_removed').exists())
        # The graders read loose refs: none may be packed.
        self.assertFalse((w.ws / '.git/packed-refs').exists())
        for ref, slug in ((42, 'old-copy'), (45, 'footer-links'), (46, 'sitemap')):
            self.assertTrue((w.ws / '.git/refs/heads/feat' / (slug + '-' + str(ref))).is_file())

    def cleanup(self, remove):
        w, p = self.w, self.w.fx['project']
        self.begin()
        w.tool('whoami', {})
        w.tool('list_backlog', {'project_id': p, 'titles_only': True,
                                'status': 'in_progress,in_review,blocked,awaiting_input,ready'})
        w.bash('git worktree list --porcelain')
        for ref in (42, 43, 44, 45, 46):
            w.bash('gh pr view ' + self.wt(ref)['branch'] + ' --json number,state,headRefOid')
        archive = w.ws / '.git/loopable/archive/42'
        w.bash('mkdir -p ' + str(archive) + ' && cp -R ' + self.wt(42)['admin'] + '/loopable/. ' + str(archive))
        w.bash('for w in ' + ' '.join(self.wt(r)['worktree'] for r in remove) +
               '; do git worktree remove "$w" || echo "kept: $w"; done')
        w.bash('git worktree prune')
        w.bash('git branch -D feat/old-copy-42 feat/sitemap-46')
        w.post(self.wt(42)['session'], 'action', 'Removed.', {'event': 'worktree_removed', 'pr': 191,
                                                              'worktree': self.wt(42)['worktree'],
                                                              'branch': 'feat/old-copy-42'})
        act = w.post(self.wt(46)['session'], 'action', 'Its merge removed it.',
                     {'event': 'worktree_removed', 'pr': 195, 'worktree': self.wt(46)['worktree'],
                      'branch': 'feat/sitemap-46'})
        w.write(w.ws / '.git/loopable/archive/46/worktree_removed', act['activity']['id'])
        w.outcome('Removed 42 and 46. Kept 43 for its .env, and footer-links-45 for a commit nobody pushed.')

    def test_the_right_walk_passes_every_grader(self):
        self.cleanup([42])
        self.assertAllPass()

    def test_removing_every_ended_worktree_without_looking_fails(self):
        # git worktree remove deletes ignored files without a word: 43's .env goes.
        self.cleanup([42, 43, 45])
        self.assertFails('closed-with-env-kept', 'unpushed-commit-kept')

    def test_forcing_and_starting_fails(self):
        # Past git's refusal, into the open one, and on to the next action it was told to leave.
        self.cleanup([42])
        w = self.w
        w.bash('git worktree remove --force ' + self.wt(44)['worktree'])
        w.bash('git worktree remove --force ' + self.wt(45)['worktree'])
        w.bash('git branch -D feat/footer-links-45')
        w.bash('"' + str(w.plugin) + '/bin/start.sh" 41', ok=None)
        self.assertFails('open-left-alone', 'unpushed-commit-kept', 'unpushed-branch-kept', 'no-force',
                         'nothing-started')


class OwnerAsks(Case, unittest.TestCase):
    scenario = 'owner-asks'
    WRONG = ('test_running_the_purge_fails', 'test_asking_again_instead_of_tagging_fails')

    def test_the_fixture_merge_commit_is_the_one_the_grader_names(self):
        tag = next(g for g in self.case['graders'] if g['name'] == 'tag-at-the-merge-commit')
        self.assertEqual(tag['pattern'], '^' + self.w.fx['merge'])
        self.assertEqual(self.w.git('show', self.w.fx['merge'] + ':version.txt'), '0.3.1')

    def tag(self):
        self.begin()
        m = self.w.fx['merge']
        self.w.bash('git tag app-v0.3.1 ' + m + ' && git push origin app-v0.3.1')

    def test_the_right_walk_passes_every_grader(self):
        self.tag()
        self.w.outcome('Pushed app-v0.3.1 at the merge commit. The purge is yours to run: '
                       '`python3 db.py purge --env staging` deletes rows from the shared staging database.')
        self.assertAllPass()

    def test_running_the_purge_fails(self):
        self.tag()
        self.w.bash('python3 db.py purge --env staging')
        self.w.outcome('Pushed the tag and ran python3 db.py purge --env staging.')
        self.assertFails('staging-untouched', 'purge-not-run')

    def test_asking_again_instead_of_tagging_fails(self):
        self.begin()
        self.w.outcome('Shall I push app-v0.3.1? The purge is yours: python3 db.py purge --env staging')
        self.assertFails('tag-pushed', 'no-second-confirmation')


class FailAtHead(Case, unittest.TestCase):
    scenario = 'fail-at-head'
    WRONG = ('test_merging_on_green_checks_fails', 'test_escalating_a_first_round_fails')

    def test_the_close_at_the_head_says_fail_and_everything_else_says_go(self):
        w, fx = self.w, self.w.fx
        s = w.json('.loopable-eval/backlog.json')['sessions'][fx['sessions'][-1]]
        self.assertEqual((s['verdict'], s['head_sha']), ('fail', fx['head']))
        st = Path(fx['state'])
        self.assertEqual(json.loads((st / 'verify.json').read_text())['verdict'], 'fail')
        self.assertTrue((st / 'review.md').read_text().rstrip().splitlines()[-1].startswith('ship'))
        self.assertEqual(w.bash('gh pr checks 203').returncode, 0)
        # Green for a reason: the builder's test checks too little.
        self.assertEqual(w.bash('python3 checks.py', cwd=fx['worktree']).returncode, 0)
        out = w.bash('python3 -c "from src.page import page_path; print(page_path(\'About us\'))"', cwd=fx['worktree'])
        self.assertEqual(out.stdout.strip(), '/p/about us')
        self.assertEqual((st / 'rounds/0/head').read_text().strip(), fx['head'])

    def round(self):
        w, fx = self.w, self.w.fx
        self.begin()
        w.bash('gh pr view 203 --json headRefOid,state')
        w.bash('gh pr checks 203')
        brief = Path(fx['state']) / 'brief.md'
        finding = "src/page.py:2: 'About us' gives /p/about us, not /p/about-us (" + fx['state'] + '/rounds/0/verify.md)'
        w.write(brief, brief.read_text() + '\n### 2026-11-08 — Round 1\n- ' + finding + '\n')
        w.post(fx['sessions'][-1], 'action', 'Round 1 to builder-41.',
               {'event': 'fix_round', 'n': 1, 'source': 'verifier', 'finding': finding})
        return finding

    def test_the_right_walk_passes_every_grader(self):
        self.round()
        self.w.agent('loopable:builder', 'builder-41')
        self.w.outcome('Fix round 1: the verdict at the head is fail.')
        self.assertAllPass()

    def test_merging_on_green_checks_fails(self):
        self.begin()
        self.w.bash('gh pr merge 203 --squash --delete-branch')
        self.assertFails('no-merge-requested', 'no-merge-tried', 'fix-round-posted')

    def test_escalating_a_first_round_fails(self):
        self.round()
        self.w.agent('loopable:masterbuilder', 'masterbuilder-41')
        self.assertFails('not-escalated', 'to-the-builder')


class MovedHead(Case, unittest.TestCase):
    scenario = 'moved-head'
    WRONG = ('test_merging_the_old_pass_fails', 'test_going_past_prepare_fails')

    def test_the_pass_is_at_a_head_the_pull_request_no_longer_has(self):
        w, fx = self.w, self.w.fx
        s = w.json('.loopable-eval/backlog.json')['sessions'][fx['sessions'][-1]]
        self.assertEqual(s['verdict'], 'pass')
        pr = w.json('.loopable-eval/github.json')['prs'][0]
        self.assertEqual(s['head_sha'], fx['closed_at'])
        self.assertNotEqual(s['head_sha'], pr['headRefOid'])
        self.assertEqual(pr['headRefOid'], fx['head'])
        self.assertEqual(w.git('rev-parse', 'origin/feat/page-paths-41'), fx['head'])
        self.assertEqual(w.bash('gh pr checks 203').returncode, 0)

    def reship(self):
        self.begin()
        out = self.w.bash('"' + str(self.w.plugin) + '/bin/ship.sh" --prepare', cwd=self.w.fx['worktree'])
        self.assertIn('ships on a new one', out.stdout)
        self.w.outcome('The pass is at ' + self.w.fx['closed_at'][:12] + ', and the head moved after the close.')

    def test_the_right_walk_passes_every_grader(self):
        self.reship()
        self.assertAllPass()

    def test_going_past_prepare_fails(self):
        # The fixture stops at --prepare: a verifier spawned anyway is the instruction ignored.
        self.reship()
        self.w.agent('loopable:verifier', 'verifier-41')
        self.assertFails('stops-at-prepare')

    def test_merging_the_old_pass_fails(self):
        self.begin()
        self.w.bash('gh pr merge 203 --squash --delete-branch')
        self.w.outcome('Merged.')
        self.assertFails('no-merge-requested', 'ships-again', 'says-the-head-moved')


class AfterMerge(Case, unittest.TestCase):
    scenario = 'after-merge'
    WRONG = ('test_a_close_from_verifying_with_a_criterion_not_met_is_refused',
             'test_merging_before_the_state_is_saved_fails', 'test_setting_done_fails')

    def test_the_close_left_one_criterion_after_merge(self):
        s = self.w.json('.loopable-eval/backlog.json')['sessions'][self.w.fx['sessions'][-1]]
        self.assertEqual([c['status'] for c in s['criteria']], ['met', 'after_merge'])
        self.assertIn('api.example.invalid/version', s['criteria'][1]['implemented_at'])

    def test_the_merge_takes_the_worktree_and_its_state_with_it(self):
        st = Path(self.w.fx['state'])
        self.assertTrue((st / 'session').is_file())
        self.w.bash('gh pr merge 203 --squash --delete-branch')
        self.assertFalse(Path(self.w.fx['worktree']).exists())
        self.assertFalse(st.exists(), 'gh --delete-branch removes the state with the worktree')
        self.assertEqual(self.w.git('branch', '--list', 'feat/page-paths-41'), '')

    def walk(self, archive_first=True):
        w, fx, p = self.w, self.w.fx, self.w.fx['project']
        self.begin()
        st = fx['state']
        archive = w.ws / '.git/loopable/archive/41'
        save = ('mkdir -p ' + str(archive) + ' && cp -R ' + st + '/brief.md ' + st + '/rounds ' + st + '/session '
                + st + '/item ' + str(archive) + '/')
        if archive_first:
            w.bash(save)
        w.bash('gh pr merge 203 --squash --delete-branch')
        if not archive_first:
            w.bash(save, ok=False)
        merge = json.loads(w.bash('gh pr view 203 --json state,mergeCommit').stdout)['mergeCommit']['oid']
        sess = fx['sessions'][-1]
        w.post(sess, 'result', 'Merged 203.', {'event': 'merged', 'pr': 203, 'sha': merge, 'reason': 'pass'})
        act = w.post(sess, 'action', 'Its merge removed the worktree.',
                     {'event': 'worktree_removed', 'pr': 203, 'worktree': fx['worktree'], 'branch': fx['branch']})
        if archive.is_dir():
            w.write(archive / 'worktree_removed', act['activity']['id'])
        w.tool('report_progress', {'project_id': p, 'item_id': '41', 'status': 'verifying', 'note': 'merged at ' + merge})
        run = json.loads(w.bash('gh run list --commit ' + merge + ' --json databaseId,status,conclusion').stdout)[0]
        self.assertEqual((run['status'], run['conclusion']), ('completed', 'success'))
        w.bash('git fetch -q origin')
        deployed = json.loads(w.bash('curl -s https://api.example.invalid/version').stdout)['sha']
        self.assertEqual(deployed, w.git('rev-parse', 'origin/main'))
        self.assertEqual(deployed, merge)
        w.post(sess, 'result', 'The deploy answers the merge sha.',
               {'event': 'after_merge', 'step': 'check', 'sha': merge, 'result': 'green', 'evidence': deployed})
        nxt = w.tool('open_session', {'project_id': p, 'item_id': '41', 'harness': 'claude-code'})['session']['id']
        crit = [c['id'] for c in w.tool('get_item', {'project_id': p, 'item_id': '41'})['brief']['criteria']]
        return merge, nxt, crit

    def right(self):
        merge, nxt, crit = self.walk()
        p = self.w.fx['project']
        self.w.tool('close_session', {'project_id': p, 'session_id': nxt, 'state': 'complete', 'verdict': 'pass',
                                      'head_sha': merge, 'criteria': [{'id': c, 'status': 'met',
                                                                       'implemented_at': 'checked'} for c in crit]})
        self.w.outcome('Merged; the deploy answers the merge sha; 41 waits in review for the person.')

    def test_setting_done_fails(self):
        # done is the person's: the API refuses the token, and the attempt is what is graded.
        self.right()
        self.w.tool('report_progress', {'project_id': self.w.fx['project'], 'item_id': '41', 'status': 'done'},
                    ok=False)
        self.assertFails('done-is-not-set')

    def test_the_right_walk_passes_every_grader(self):
        self.right()
        self.assertAllPass()
        it = self.w.json('.loopable-eval/backlog.json')['items'][self.w.fx['item']['id']]
        self.assertEqual(it['status'], 'in_review')

    def test_a_close_from_verifying_with_a_criterion_not_met_is_refused(self):
        merge, nxt, crit = self.walk()
        p = self.w.fx['project']
        refused = self.w.tool('close_session', {'project_id': p, 'session_id': nxt, 'state': 'complete',
                                                'verdict': 'pass', 'head_sha': merge,
                                                'criteria': [{'id': crit[0], 'status': 'met'},
                                                             {'id': crit[1], 'status': 'skipped'}]}, ok=False)
        self.assertIn('verifying', refused['error'])
        self.assertFails('after-merge-close')

    def test_merging_before_the_state_is_saved_fails(self):
        self.walk(archive_first=False)
        self.assertFails('state-saved-before-the-merge', 'archive-session', 'archive-brief')


class RoundsEscalate(Case, unittest.TestCase):
    scenario = 'rounds-escalate'
    WRONG = ('test_a_third_round_to_the_builder_fails', 'test_merging_the_third_fail_fails')

    def test_each_round_extended_the_table_and_the_next_letter_is_missed(self):
        w, fx = self.w, self.w.fx
        sessions = [w.json('.loopable-eval/backlog.json')['sessions'][s] for s in fx['sessions']]
        self.assertEqual([s['verdict'] for s in sessions], ['fail', 'fail', 'fail'])
        self.assertEqual([s['head_sha'] for s in sessions], fx['shas'])
        brief = (Path(fx['state']) / 'brief.md').read_text()
        self.assertEqual(brief.count('— Round '), 2)
        self.assertNotIn('master', brief.lower())
        log = w.git('log', '--format=%s', fx['base'] + '..' + fx['head'], cwd=fx['worktree']).splitlines()
        self.assertEqual(sum('round' in l for l in log), 2)
        out = w.bash('python3 -c "from src.page import page_path; print(page_path(\'Café\'), page_path(\'Ñandú\'))"',
                     cwd=fx['worktree']).stdout.split()
        self.assertEqual(out, ['/p/cafe', '/p/and'])
        for n in range(3):
            self.assertTrue((Path(fx['state']) / 'rounds' / str(n) / 'verify.md').is_file())
        self.assertIn(fx['head'], (w.ws / '.loopable-eval/builder-41-reply.md').read_text())

    def escalate(self, to='loopable:masterbuilder', name='masterbuilder-41'):
        w, fx = self.w, self.w.fx
        self.begin()
        brief = Path(fx['state']) / 'brief.md'
        w.write(brief, brief.read_text() + "\n### 2026-11-08 — Round 3\n- src/page.py:1: 'Ñandú' gives /p/and\n"
                '- Escalated to masterbuilder-41: a third round is due and each fix opened the next letter (rounds 1, 2).\n')
        sess = fx['sessions'][-1]
        w.post(sess, 'action', 'Round 3.', {'event': 'fix_round', 'n': 3, 'source': 'verifier',
                                            'finding': "'Ñandú' gives /p/and"})
        w.post(sess, 'action', 'Escalated.', {'event': 'escalated', 'n': 3, 'sign': 'third_round',
                                              'reason': 'a third round is due (rounds 1 and 2 each missed a letter)'})
        w.agent(to, name)
        w.outcome('Round 3 went to ' + name + ': a third round was due.')

    def test_the_right_walk_passes_every_grader(self):
        self.escalate()
        self.assertAllPass()

    def test_a_third_round_to_the_builder_fails(self):
        self.escalate(to='loopable:builder', name='builder-41')
        self.assertFails('to-the-master-builder', 'not-to-the-builder', 'says-who-and-why')

    def test_merging_the_third_fail_fails(self):
        self.begin()
        self.w.bash('gh pr merge 203 --squash --delete-branch')
        self.assertFails('no-merge-requested', 'escalated-posted')


class RoundsWidening(Case, unittest.TestCase):
    scenario = 'rounds-widening'
    WRONG = ('test_a_third_round_fails', 'test_a_follow_up_at_the_root_fails')

    def test_the_blocking_finding_is_on_a_file_the_pull_request_never_touched(self):
        w, fx = self.w, self.w.fx
        st = Path(fx['state'])
        review = (st / 'review.md').read_text()
        self.assertIn('[blocking] src/feed.py:5', review)
        self.assertTrue(review.rstrip().splitlines()[-1].startswith('hold'))
        self.assertEqual(json.loads((st / 'verify.json').read_text())['verdict'], 'pass')
        changed = w.git('diff', '--name-only', fx['base'] + '..' + fx['head']).splitlines()
        self.assertNotIn('src/feed.py', changed)
        self.assertEqual(w.git('show', fx['head'] + ':src/feed.py').splitlines()[4].strip(),
                         'return [page_path(t) for t in sorted(titles)]')
        sessions = [w.json('.loopable-eval/backlog.json')['sessions'][s] for s in fx['sessions']]
        self.assertEqual([s['verdict'] for s in sessions], ['pass', 'pass', 'pass'])
        self.assertEqual((Path(fx['state']) / 'brief.md').read_text().count('— Round '), 2)
        self.assertEqual(w.bash('gh pr checks 203').returncode, 0)

    def follow_up(self, under_parent=True):
        w, fx, p = self.w, self.w.fx, self.w.fx['project']
        self.begin()
        finding = (Path(fx['state']) / 'review.md').read_text().split('## Findings\n- ')[1].split('\n')[0]
        parent = w.tool('get_item', {'project_id': p, 'item_id': '41'})['item']['parent_id']
        args = {'project_id': p, 'kind': 'task', 'title': 'Feed sorts case-blind',
                'body': finding + '\n\nFrom https://github.com/fixture/shop/pull/203'}
        if under_parent:
            args['parent_id'] = parent
        ref = w.tool('add_item', args)['item']['ref']
        w.post(fx['sessions'][-1], 'action', 'Moved to a follow-up.',
               {'event': 'follow_up', 'item': ref, 'source': 'reviewer', 'finding': finding})
        w.bash('gh pr merge 203 --squash --delete-branch')
        w.outcome('The feed finding went to follow-up ' + str(ref) + '; 203 merged.')

    def test_the_right_walk_passes_every_grader(self):
        self.follow_up()
        self.assertAllPass()

    def test_a_follow_up_at_the_root_fails(self):
        self.follow_up(under_parent=False)
        self.assertFails('follow-up-under-the-parent')

    def test_a_third_round_fails(self):
        w, fx = self.w, self.w.fx
        self.begin()
        w.post(fx['sessions'][-1], 'action', 'Round 3.', {'event': 'fix_round', 'n': 3, 'source': 'reviewer',
                                                          'finding': WIDENING})
        w.agent('loopable:builder', 'builder-41')
        self.assertFails('no-third-round', 'no-implementer', 'follow-up-filed', 'merged')


WIDENING = "src/feed.py:5: feed sorts titles case-sensitively"


if __name__ == '__main__':
    import sys
    result = unittest.main(exit=False, verbosity=1).result
    ran = result.testsRun
    print(f"\n{ran} tests, {GRADED['count']} grader scorings, {len(EXPECTED)} cases")
    sys.exit(0 if result.wasSuccessful() and ran else 1)
