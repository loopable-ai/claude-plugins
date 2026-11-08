#!/usr/bin/env python3
"""Statistics for an old-vs-new run of the loopable lifecycle evals.

Usage: ab-stats.py old.json new.json   (the --json files `claude plugin eval` wrote)

Per case: full passes (every grader) in each arm, and a two-sided Fisher exact p
for the difference. Per grader: pass counts, a Fisher p, and a flag for graders
that cannot show a difference — `saturated` (passes in every run of both arms) or
`floor` (fails in every run of both) — and for one that did worse in the new arm.

Nothing is pooled. Each case is a different stage of the driver's lifecycle — a
start, a cleanup, a decision, a fix round — and summing them would suggest one
reliability rate that these seeded continuations do not support. The arms are
independent runs, not pairs, so the test is on two proportions; with few runs the
p-values are weak, and the script says so. Standard library only.
"""
import json
import sys
from math import comb


def fisher_two_sided(a, n1, b, n2):
    """P(a table at least as unlikely as the one observed), for a/n1 vs b/n2 passes."""
    k, total = a + b, comb(n1 + n2, a + b)
    probs = {i: comb(n1, i) * comb(n2, k - i) / total
             for i in range(max(0, k - n2), min(n1, k) + 1)}
    return sum(p for p in probs.values() if p <= probs[a] + 1e-12)


def load(path):
    with open(path) as source:
        data = json.load(source)
    return {case['name']: case['arms']['with'] for case in data['cases']}


def full(runs):
    return sum(1 for r in runs if r['passed'])


def passed(runs, grader):
    return sum(1 for r in runs for g in r['graders'] if g['name'] == grader and g['passed'])


def main(old_path, new_path):
    old, new = load(old_path), load(new_path)
    smallest = None
    print(f"{'case / grader':40s} {'old':>7s} {'new':>7s}   Fisher p   note")
    for name in sorted(new):
        if name not in old:
            print(f'{name:40s} missing from the old results')
            continue
        o, n = old[name], new[name]
        if not o or not n:
            print(f"{name:40s} not measured: no completed run in the {'old' if not o else 'new'} arm")
            continue
        smallest = min(smallest or len(o), len(o), len(n))
        a, b = full(o), full(n)
        print(f'{name:40s} {a:>3d}/{len(o):<3d} {b:>3d}/{len(n):<3d}   {fisher_two_sided(a, len(o), b, len(n)):8.3f}')
        for grader in sorted(g['name'] for g in n[0]['graders']):
            ga, gb = passed(o, grader), passed(n, grader)
            flag = ''
            if ga == len(o) and gb == len(n):
                flag = 'saturated (cannot show a difference)'
            elif ga == 0 and gb == 0:
                flag = 'floor (fails in both arms)'
            elif gb / len(n) < ga / len(o):
                flag = 'WORSE in the new arm'
            p = fisher_two_sided(ga, len(o), gb, len(n))
            print(f'  {grader:38s} {ga:>3d}/{len(o):<3d} {gb:>3d}/{len(n):<3d}   {p:8.3f}   {flag}')
    if smallest is not None and smallest < 6:
        print(f'\nnote: {smallest} runs per case per arm. Below about 6 a single case cannot '
              'reach p < 0.05 unless the arms are perfectly apart (3 vs 0 gives 0.10); '
              'read the per-grader rows, and add runs for a smaller gap.')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
