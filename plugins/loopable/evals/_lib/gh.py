#!/usr/bin/env python3
"""The gh stand-in for the lifecycle fixtures. Never contacts GitHub.

Installed as .loopable-eval/bin/gh. Its state is .loopable-eval/github.json next
to that bin/ directory, and every call is appended to github-calls.jsonl with
the directory it ran in, whatever the call was.

Writes persist, so a pull request marked ready stays ready for the next call.
An unsafe merge is deliberately ACCEPTED: the grader must see the mistake in the
markers, not have it hidden by the stand-in. Every merge request leaves
.loopable-eval/merge-requested; a merge that happened leaves .loopable-eval/merged
(one line per pull request) and makes the squash commit on the local origin's
main, the way GitHub would.

`gh pr merge --delete-branch` does what gh 2.103 does from a local checkout:
it deletes the remote branch, and removes the worktree that holds the head
branch and the local branch with it — which is why the driver saves an item's
state before it merges.
"""
import fcntl
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent          # <workspace>/.loopable-eval
STATE = ROOT / 'github.json'
CALLS = ROOT / 'github-calls.jsonl'
JSON_FIELDS = ('number', 'url', 'title', 'body', 'state', 'isDraft', 'isCrossRepository', 'headRefName', 'headRefOid',
               'baseRefName', 'mergeable', 'mergeStateStatus', 'reviewDecision', 'comments',
               'mergeCommit', 'mergedAt', 'closedAt', 'statusCheckRollup', 'autoMergeRequest', 'author')


def git(*args, cwd=None):
    env = {**os.environ, 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull}
    return subprocess.run(['git', '-c', 'core.hooksPath=' + os.devnull, '-c', 'commit.gpgSign=false',
                           '-c', 'user.name=GitHub', '-c', 'user.email=noreply@example.invalid', *args],
                          capture_output=True, text=True, cwd=cwd, env=env)


class Fail(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


def flag(args, *names, default=None):
    for n in names:
        if n in args:
            i = args.index(n)
            return args[i + 1] if i + 1 < len(args) else ''
        for a in args:
            if a.startswith(n + '='):
                return a.split('=', 1)[1]
    return default


VALUED = {'--json', '-q', '--jq', '--title', '-t', '--body', '-b', '--body-file', '-F', '--head', '-H',
          '--base', '-B', '--state', '-s', '--commit', '-c', '--workflow', '-w', '--limit', '-L',
          '-R', '--repo', '--subject', '--branch', '--template', '--match-head-commit', '--author-email'}


def positionals(args):
    out, i = [], 0
    while i < len(args):
        a = args[i]
        if a in VALUED:
            i += 2
            continue
        if not a.startswith('-'):
            out.append(a)
        i += 1
    return out


def emit(result, args):
    """--json picks fields, -q/--jq runs a jq expression, the way gh does."""
    fields = flag(args, '--json')
    if fields:
        names = [f.strip() for f in fields.split(',') if f.strip()]
        pick = lambda r: {n: r.get(n) for n in names}
        result = [pick(r) for r in result] if isinstance(result, list) else pick(result)
    expr = flag(args, '-q', '--jq')
    text = json.dumps(result)
    if expr:
        done = subprocess.run(['jq', '-r', expr], input=text, capture_output=True, text=True)
        if done.returncode:
            raise Fail(done.stderr.strip() or 'jq failed', done.returncode)
        sys.stdout.write(done.stdout)
    else:
        print(json.dumps(result, indent=2))


def current_branch():
    r = git('symbolic-ref', '--quiet', '--short', 'HEAD')
    return r.stdout.strip() if r.returncode == 0 else ''


def find_pr(state, sel):
    prs = state['prs']
    if sel in (None, ''):
        sel = current_branch()
        if not sel:
            raise Fail('could not determine current branch')
    sel = str(sel).rstrip('/')
    if sel.startswith('#'):
        sel = sel[1:]
    if '/pull/' in sel:
        sel = sel.split('/pull/')[1].split('/')[0]
    if sel.isdigit():
        for p in prs:
            if p['number'] == int(sel):
                return p
        raise Fail('GraphQL: Could not resolve to a PullRequest with the number of ' + sel + '. (repository.pullRequest)')
    mine = [p for p in prs if p['headRefName'] == sel]
    open_ = [p for p in mine if p['state'] == 'OPEN']
    if open_:
        return open_[0]
    if mine:
        return max(mine, key=lambda p: p['number'])
    raise Fail('no pull requests found for branch "' + sel + '"')


def checks_of(state, pr):
    return state.get('checks', {}).get(pr['headRefOid'], [])


def rollup(state, pr):
    return [{'name': c['name'], 'status': 'COMPLETED' if c['state'] in ('SUCCESS', 'FAILURE') else 'IN_PROGRESS',
             'conclusion': c['state'] if c['state'] in ('SUCCESS', 'FAILURE') else ''}
            for c in checks_of(state, pr)]


def view(state, pr):
    # Every pull request here is opened in the stand-in's one repository, so
    # none is from a fork unless a fixture says so — and ship.sh takes only a
    # same-repository one as the branch's own (370).
    return {'isCrossRepository': False, **pr, 'statusCheckRollup': rollup(state, pr)}


def origin_dir():
    url = git('remote', 'get-url', 'origin')
    if url.returncode:
        raise Fail('no origin remote in this repository')
    return url.stdout.strip()


def merge(state, pr, args):
    state['merge_requests'] = state.get('merge_requests', 0) + 1
    with (ROOT / 'merge-requested').open('a') as f:
        f.write(str(pr['number']) + ' ' + ' '.join(args) + '\n')
    if pr['state'] != 'OPEN':
        raise Fail('Pull request #' + str(pr['number']) + ' is ' + pr['state'].lower() + '.')
    if pr['isDraft']:
        raise Fail('Pull request #' + str(pr['number']) + ' is still a draft.')
    if '--auto' in args and '--admin' not in args and any(c['state'] != 'SUCCESS' for c in checks_of(state, pr)):
        pr['autoMergeRequest'] = {'enabledBy': 'driver'}
        print('! Pull request #' + str(pr['number']) + ' will be automatically merged when all requirements are met')
        return
    origin = origin_dir()
    tree = git('rev-parse', pr['headRefOid'] + '^{tree}', cwd=origin)
    base = git('rev-parse', 'refs/heads/' + pr['baseRefName'], cwd=origin)
    if tree.returncode or base.returncode:
        raise Fail('the head ' + pr['headRefOid'] + ' is not on the origin')
    if '--merge' in args:
        made = git('commit-tree', tree.stdout.strip(), '-p', base.stdout.strip(), '-p', pr['headRefOid'],
                   '-m', 'Merge pull request #' + str(pr['number']), cwd=origin)
    else:
        made = git('commit-tree', tree.stdout.strip(), '-p', base.stdout.strip(),
                   '-m', pr['title'] + ' (#' + str(pr['number']) + ')', cwd=origin)
    sha = made.stdout.strip()
    git('update-ref', 'refs/heads/' + pr['baseRefName'], sha, cwd=origin)
    pr.update({'state': 'MERGED', 'mergeCommit': {'oid': sha}, 'mergedAt': '2026-11-08T12:00:00Z'})
    with (ROOT / 'merged').open('a') as f:
        f.write(str(pr['number']) + ' ' + sha + '\n')
    if state.get('deploy_on_merge'):
        state.setdefault('runs', []).append({
            'databaseId': 9000 + pr['number'], 'workflowName': 'deploy', 'name': 'deploy',
            'headSha': sha, 'headBranch': pr['baseRefName'], 'event': 'push', 'status': 'completed',
            'conclusion': state['deploy_on_merge'], 'url': 'https://github.com/fixture/shop/actions/runs/' + str(9000 + pr['number'])})
        if state['deploy_on_merge'] == 'success':
            (ROOT / 'deployed').write_text(sha + '\n')
    if '--delete-branch' in args:
        branch = pr['headRefName']
        git('update-ref', '-d', 'refs/heads/' + branch, cwd=origin)
        listing = git('worktree', 'list', '--porcelain').stdout
        wt, holder = None, None
        for line in listing.splitlines():
            if line.startswith('worktree '):
                wt = line[9:]
            elif line == 'branch refs/heads/' + branch:
                holder = wt
        if holder and holder != git('rev-parse', '--show-toplevel').stdout.strip():
            removed = git('worktree', 'remove', holder)
            if removed.returncode:
                print('! could not remove the worktree at ' + holder + ': ' + removed.stderr.strip(), file=sys.stderr)
        if current_branch() != branch:
            git('branch', '-D', branch)
        state.setdefault('deleted_branches', []).append(branch)


def main(argv):
    with CALLS.open('a') as log:
        log.write(json.dumps({'argv': argv, 'cwd': os.getcwd()}) + '\n')
    fh = open(STATE, 'r+')
    fcntl.flock(fh, fcntl.LOCK_EX)
    state = json.load(fh)
    code = 0
    try:
        code = dispatch(state, argv) or 0
    except Fail as f:
        print(str(f), file=sys.stderr)
        code = f.code
    fh.seek(0)
    fh.truncate()
    json.dump(state, fh, indent=2)
    fh.write('\n')
    fcntl.flock(fh, fcntl.LOCK_UN)
    fh.close()
    return code


def dispatch(state, argv):
    group, action = (argv + ['', ''])[:2]
    args = argv[2:]
    pos = positionals(args)
    if group == 'auth' and action == 'status':
        print('github.com\n  Logged in to github.com account fixture-driver (fixture)')
        return 0
    if group == 'repo' and action == 'view':
        emit({'nameWithOwner': state['repo'], 'url': 'https://github.com/' + state['repo'],
              'defaultBranchRef': {'name': 'main'}}, args)
        return 0
    if group == 'pr':
        if action == 'view':
            emit(view(state, find_pr(state, pos[0] if pos else None)), args)
            return 0
        if action == 'list':
            head = flag(args, '--head', '-H')
            want = (flag(args, '--state', '-s', default='open') or 'open').upper()
            prs = [view(state, p) for p in state['prs']
                   if (not head or p['headRefName'] == head) and (want == 'ALL' or p['state'] == want)]
            emit(prs, args)
            return 0
        if action == 'checks':
            pr = find_pr(state, pos[0] if pos else None)
            rows = checks_of(state, pr)
            if flag(args, '--json'):
                emit([{'name': c['name'], 'state': c['state'], 'bucket':
                       {'SUCCESS': 'pass', 'FAILURE': 'fail'}.get(c['state'], 'pending')} for c in rows], args)
            else:
                for c in rows:
                    print(c['name'] + '\t' + {'SUCCESS': 'pass', 'FAILURE': 'fail'}.get(c['state'], 'pending') +
                          '\t1m2s\thttps://github.com/' + state['repo'] + '/actions/runs/1')
            if any(c['state'] == 'FAILURE' for c in rows):
                return 1
            if any(c['state'] not in ('SUCCESS', 'FAILURE') for c in rows):
                return 8
            return 0
        if action == 'create':
            branch = flag(args, '--head', '-H') or current_branch()
            body = flag(args, '--body', '-b')
            if flag(args, '--body-file', '-F'):
                body = Path(flag(args, '--body-file', '-F')).read_text()
            if any(p['headRefName'] == branch and p['state'] == 'OPEN' for p in state['prs']):
                raise Fail('a pull request for branch "' + branch + '" into branch "main" already exists')
            state['created_prs'] = state.get('created_prs', 0) + 1
            number = state.get('next_pr', 210)
            state['next_pr'] = number + 1
            head = git('rev-parse', 'HEAD').stdout.strip()
            url = 'https://github.com/' + state['repo'] + '/pull/' + str(number)
            state['prs'].append({'number': number, 'url': url, 'title': flag(args, '--title', '-t') or branch,
                                 'body': body or '', 'state': 'OPEN', 'isDraft': '--draft' in args or '-d' in args,
                                 'headRefName': branch, 'headRefOid': head, 'baseRefName': 'main',
                                 'mergeable': 'MERGEABLE', 'reviewDecision': '', 'comments': [],
                                 'author': {'login': 'fixture-driver'}})
            with (ROOT / 'pr-created').open('a') as f:
                f.write(str(number) + ' ' + branch + '\n')
            print(url)
            return 0
        if action == 'comment':
            pr = find_pr(state, pos[0] if pos else None)
            body = flag(args, '--body', '-b')
            if flag(args, '--body-file', '-F'):
                body = Path(flag(args, '--body-file', '-F')).read_text()
            pr.setdefault('comments', []).append({'body': body or '', 'author': {'login': 'fixture-driver'}})
            print(pr['url'] + '#issuecomment-' + str(len(pr['comments'])))
            return 0
        if action == 'ready':
            pr = find_pr(state, pos[0] if pos else None)
            pr['isDraft'] = '--undo' in args
            print('✓ Pull request #' + str(pr['number']) + ' is marked as "ready for review"')
            return 0
        if action == 'edit':
            pr = find_pr(state, pos[0] if pos else None)
            state['edits'] = state.get('edits', 0) + 1
            with (ROOT / 'pr-edited').open('a') as f:
                f.write(str(pr['number']) + ' ' + ' '.join(args) + '\n')
            if flag(args, '--title', '-t'):
                pr['title'] = flag(args, '--title', '-t')
            if flag(args, '--body-file', '-F'):
                pr['body'] = Path(flag(args, '--body-file', '-F')).read_text()
            elif flag(args, '--body', '-b'):
                pr['body'] = flag(args, '--body', '-b')
            print(pr['url'])
            return 0
        if action == 'merge':
            pr = find_pr(state, pos[0] if pos else None)
            merge(state, pr, args)
            return 0
        if action == 'close':
            pr = find_pr(state, pos[0] if pos else None)
            pr['state'] = 'CLOSED'
            return 0
    if group == 'run':
        runs = state.get('runs', [])
        if action == 'list':
            sha = flag(args, '--commit', '-c')
            wf = flag(args, '--workflow', '-w')
            emit([r for r in runs if (not sha or r['headSha'].startswith(sha))
                  and (not wf or r['workflowName'] == wf)], args)
            return 0
        if action in ('view', 'watch'):
            rid = pos[0] if pos else ''
            run = next((r for r in runs if str(r['databaseId']) == rid), None)
            if not run:
                raise Fail('could not find any workflow run with ID ' + rid)
            if action == 'view' and '--log-failed' in args:
                print('deploy\tdeploy\t' + ('ok' if run['conclusion'] == 'success' else 'error: the deploy failed'))
                return 0
            if action == 'view':
                emit(run, args)
                return 0
            print('✓ ' + run['workflowName'] + ' completed with ' + run['conclusion'])
            return 0 if run['conclusion'] == 'success' or '--exit-status' not in args else 1
    raise Fail('The gh stand-in does not answer ' + repr(argv) + '. It never contacts GitHub.', 2)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
