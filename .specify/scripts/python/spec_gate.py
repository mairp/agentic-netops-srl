#!/usr/bin/env python3
"""Deterministic readiness gate for a spec-kit feature dir. Exit 0 = green. No opinions, only checks."""
import re, sys, json, glob, os, collections
D = sys.argv[1] if len(sys.argv) > 1 else '.'
R = lambda f: open(os.path.join(D, f), encoding='utf-8').read()
spec, plan, tasks, trace, research, dm, qs = (R(f) for f in
    ['spec.md', 'plan.md', 'tasks.md', 'traceability.md', 'research.md', 'data-model.md', 'quickstart.md'])
contracts = {os.path.basename(f): open(f, encoding='utf-8').read() for f in glob.glob(os.path.join(D, 'contracts/*.md'))}
fails, notes = [], []
def check(name, ok, detail=''):
    (notes if ok else fails).append(f"{'PASS' if ok else 'FAIL'}  {name}" + (f" — {detail}" if detail and not ok else ''))

# 1 requirement ids: unique, gap-free
defs = {}
for p in ['FR', 'NFR', 'SC', 'CR']:
    ids = re.findall(r'^\s*[-*]\s*\*\*(%s-\d{3})\*\*' % p, spec, re.M)
    defs[p] = ids
    nums = sorted(int(i[-3:]) for i in ids)
    check(f'{p} ids unique', len(ids) == len(set(ids)), str([k for k, v in collections.Counter(ids).items() if v > 1]))
    check(f'{p} ids gap-free', nums == list(range(1, len(nums) + 1)))
TOMB = {i for p in defs for i in defs[p]
        if re.search(r'^\s*[-*]\s*\*\*%s\*\*:\s*\*Retired' % i, spec, re.M)}
live = [i for p in defs for i in defs[p] if i not in TOMB]

# 2 tasks: format, unique, none ticked, T164 last
tl = re.findall(r'^- \[(.)\] (T\d{3})( \[P\])?( \[US\d+\])? ', tasks, re.M)
allt = re.findall(r'^- \[.\] (T\d{3})', tasks, re.M)
check('every task line well-formed', len(tl) == len(allt), f'{len(allt)-len(tl)} malformed')
check('task ids unique & gap-free', sorted(allt) == ['T%03d' % n for n in range(1, len(allt) + 1)])
# A tick is a claim (Principle I): before implementation none may exist, and once it has begun a
# task may be ticked only in a phase whose gate the critic approved (Specstride ticks on approval).
_gates = os.path.join(D, '..', '..', '.specstride', 'features', os.path.basename(os.path.abspath(D)), 'gates')
_phase_of, _n = {}, None
for _l in tasks.split('\n'):
    _m = re.match(r'^## Phase (\d+):', _l)
    if _m: _n = int(_m.group(1))
    elif re.match(r'^## ', _l): _n = None
    _m = re.match(r'^- \[.\] (T\d{3})', _l)
    if _m: _phase_of[_m.group(1)] = _n
_unbacked = sorted(t for c, t, *_ in tl if c != ' ' and not (_phase_of.get(t) and os.path.exists(os.path.join(_gates, 'GATE%d-APPROVED' % _phase_of[t]))))
check('every ticked task sits in a phase with an approved gate', not _unbacked, str(_unbacked[:8]))
check('T164 (README) is the last task', allt[-1] == 'T164')

# 3 coverage: every live requirement cited by >=1 task line (ranges expanded)
def expand(text):
    out = set(re.findall(r'\b(?:FR|NFR|SC|CR)-\d{3}\b', text))
    for m in re.finditer(r'\b(FR|NFR|SC|CR)-(\d{3})\s*(?:…|–|\.\.\.)\s*(?:(?:FR|NFR|SC|CR)-)?(\d{3})', text):
        out |= {'%s-%03d' % (m.group(1), n) for n in range(int(m.group(2)), int(m.group(3)) + 1)}
    return out
cited = set()
for line in re.findall(r'^- \[.\] T\d{3}.*$', tasks, re.M): cited |= expand(line)
unc = [i for i in live if i not in cited]
check('every live requirement cited by a task', not unc, str(unc))
und = sorted(expand(tasks) - {i for p in defs for i in defs[p]})
check('tasks cite no undefined requirement id', not und, str(und))

# 4 traceability both directions
fwd = set(re.findall(r'^\| ((?:FR|NFR|SC|CR)-\d{3}) \|', trace, re.M))
alld = {i for p in defs for i in defs[p]}
check('traceability forward table == spec ids', fwd == alld, f'missing {sorted(alld-fwd)} extra {sorted(fwd-alld)}')

# 5 decisions: every AD heading has a traceability row, ordered, no stubs
ads = [int(n) for n in re.findall(r'^### AD-(\d+):', research, re.M)]
rows = [int(n) for n in re.findall(r'^\| AD-(\d+) \|', trace, re.M)]
check('AD entries contiguous from 1', ads == list(range(1, len(ads) + 1)))
check('every AD has exactly one traceability row, in order', rows == ads, f'rows={len(rows)} ads={len(ads)}')
check('no STUB / placeholder left', not re.search(r'STUB|TODO|TBD|TKTK|\?\?\?|NEEDS CLARIFICATION', research + spec + plan + tasks),
      str(re.findall(r'.{0,30}(?:STUB|TODO|TBD|TKTK|NEEDS CLARIFICATION).{0,20}', research + spec + plan + tasks)[:3]))

# 6 references resolve
tset = set(allt)
badT = sorted({t for f in [spec, plan, trace, qs, dm] + list(contracts.values()) for t in re.findall(r'\bT\d{3}\b', f)} - tset - {'T468'})
check('every cited task id exists', not badT, str(badT))
badAD = sorted({int(n) for f in [spec, plan, tasks, trace, qs, dm] + list(contracts.values()) for n in re.findall(r'\bAD-(\d+)\b', f)} - set(ads))
check('every cited AD id exists', not badAD, str(badAD))
def sections(text): return set(re.findall(r'^#{2,4} (\d+[a-z]?)\.', text, re.M))
for name, text, label in [('data-model.md', dm, 'data-model'), ('quickstart.md', qs, 'quickstart')]:
    have = sections(text); bad = set()
    for f in [spec, plan, tasks, trace] + list(contracts.values()) + [dm, qs]:
        for m in re.finditer(re.escape(name) + r'\)?\s*§(\d+[a-z]?)', f):
            if m.group(1) not in have: bad.add(m.group(1))
    check(f'every "{name} §N" reference resolves', not bad, str(sorted(bad)))

# 7 make targets: used ⊆ declared in T006
t006 = re.search(r'^- \[.\] T006 .*$', tasks, re.M).group(0)
declared = set(re.findall(r'`([a-z][a-z0-9-]+)`', t006))
used = set()
for f in [tasks, plan, spec, qs]:
    for m in re.finditer(r'\bmake ((?:[a-z][a-z0-9-]+)(?:(?: &&)? (?:make )?[a-z][a-z0-9-]+)*)', f):
        for w in re.findall(r'[a-z][a-z0-9-]+', m.group(1)):
            if w not in ('make', 'and') and ('-' in w or w in declared): used.add(w)
missing = sorted(used - declared)
check('every make target used is declared in T006', not missing, str(missing))

# 8 JSON schemas parse
for f in glob.glob(os.path.join(D, 'contracts/*.json')):
    try: json.load(open(f)); ok = True
    except Exception as e: ok = False
    check(f'{os.path.basename(f)} parses', ok)

# 9 markdown tables: constant column count inside each table
for name, text in [('spec.md', spec), ('plan.md', plan), ('tasks.md', tasks), ('traceability.md', trace), ('data-model.md', dm), ('quickstart.md', qs)] + list(contracts.items()):
    bad = []; hdr = None; incode = False
    for n, l in enumerate(text.split('\n'), 1):
        if l.startswith('```'): incode = not incode
        if incode or not l.startswith('|'): hdr = None; continue
        c = len(re.sub(r'`[^`]*`', '', l).replace('\\|', '').split('|'))
        if hdr is None: hdr = c
        elif c != hdr: bad.append(n)
    check(f'{name}: table rows match header width', not bad, str(bad[:6]))

# 10 totals stated in the newest traceability paragraph are true
last = [p for p in trace.split('\n\n') if 'analysis pass, 2026-09-21' in p][-1]
def said(pat):
    m = re.search(pat, last); return int(m.group(1)) if m else None
checks = [('tasks', r'tasks at (\d+)', len(allt)), ('FR ids', r'stay at (\d+) identifiers', len(defs['FR'])),
          ('SC ids', r'success criteria (\d+) with', len(defs['SC'])), ('research decisions', r'research decisions reach (\d+)',
           len(re.findall(r'^### (?:D|RD|CD|AD)-\d+', research, re.M)))]
for label, pat, actual in checks:
    s = said(pat)
    if s is not None: check(f'stated total "{label}" = {actual}', s == actual, f'says {s}')

print('\n'.join(notes)); print()
print('\n'.join(fails) if fails else 'ALL CHECKS PASS')
print(f'\nlive requirements {len(live)} · tasks {len(allt)} · [P] {sum(1 for x in tl if x[2])} · AD {len(ads)} · coverage {100*(len(live)-len(unc))//len(live)}%')
sys.exit(1 if fails else 0)
