#!/usr/bin/env python3
"""regroup-docs.py — move planning documents into area directories and keep every reference true.

    tools/migrate/regroup-docs.py [--dry-run]

The table GROUPS below says which area directory under docs/planning/ each
document belongs in. A move rewrites:

  1. Written paths: `docs/planning/NAME.md` → `docs/planning/AREA/NAME.md` in every
     text file of the tree (code comments, docs, the Makefile, generated-file headers),
     and the short form `planning/NAME.md`.
  2. Relative links: `[x](other.md)` and `](../planning/other.md)` inside any
     Markdown file are resolved against the file's OLD location and written
     relative to its NEW one, whichever of the two ends moved.

--dry-run lists the moves and the number of files each rewrite would touch.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.chdir(ROOT)
PLAN = 'docs/planning/'

GROUPS = {
    'solve': """antifragile-sweep cadence-phase-axis capacity-denomination-open-questions commitment-horizon
        control_system discrete-layer drawn-stock-weight ecological-tipping-ideal ecological-tipping-tensions
        harmony-planning-design intra-period-time planner-coherence-open-threads planner-cross-pollination
        planner-known-gaps planner-open-questions planning-under-uncertainty possibility-tensions-unified
        propagator quantity-as-a-cap recipe-metabolism-barbell reproduction-bands robust-multiscenario
        robust-tractability scenario-intent-shocks scenario-tree time-and-uncertainty wiod-planner
        worker-supply-capacity-solver-bug temporal-expression-vs-rrule space-time-navigation plan-acceptance
        step-notes""",
    'books': """accounting-horizon accounting-work-log beyond-valueflows confirmed-flow-stock-defects
        correct-by-construction-confirmation leave-and-take portable-event-log transport-modes-and-observation
        valueflows-accounting-by-construction valueflows-accounting-rules valueflows-native-inventory""",
    'federation': """FEDERATED-SOLVE federation-flow-map federation-identity-and-folds labour-aggregation-architecture
        labour-assignment-and-rotation means-pool-uc-allocation capacity-combine-across-scopes three-trees
        patchwork-scopes-containment live-location-and-desire-aggregation monitoring-channel
        international-socialization""",
    'socialization': """housing-socialization socialization-surfaces socialize-interface temporary-socialization
        social-means-common-property-divergences three-bills reimbursement-funding-source anon-purchase-gift-cards""",
    'legal': """legal-compliance-lifecycle legal-crossings inspection-in-plan two-rulebooks gdpr-analysis
        berlin-food-policy-reform""",
    'food': """berlin-food-data-sources berlin-food-networks berlin-socialize-infra berlin-verteilstation-requirements
        foodsharing-requirements free-healthy-food-for-everyone feel-the-food diet-constraints
        reproduction-of-labour-power agroecology-bring-over forestry-bring-over permaculture-bring-over
        natural-processes-research-plan resource-slots-mapping""",
    'identity': """device-keys keri-openvtc-library-split openvtc-parity skill-standing skill-maintenance-recipes
        trust-substrate-belief-acceptance truth-telling repo-split-and-protocol-doors folksonomy
        first-person-portable-citizen-index""",
    'faces': """calendar-design offline-outbox spine-worker voice-search-pipeline watch-progressive-disclosure
        nl-interface recipe-patchbay ai-stack-wiring communications-recipes festival-live-coherence-threads
        world-loop meeting-station city-symbol-table door-inventory corpus-guile-native""",
    'audits': """acdc-signing-audit-2026-07-21 goblins-actor-audit-2026-07-20 protocol-inventory-2026-09-12""",
}


def plan():
    on_disk = {f[:-3] for f in os.listdir(PLAN) if f.endswith('.md') and os.path.isfile(PLAN + f)}
    moves = {}
    for area, names in GROUPS.items():
        for n in names.split():
            moved = os.path.isfile(f'{PLAN}{area}/{n}.md')   # a run that stopped half way resumes
            if n not in on_disk and not moved:
                sys.exit(f'regroup-docs: {n} is not a document under {PLAN}')
            if n in moves:
                sys.exit(f'regroup-docs: {n} is assigned twice')
            moves[PLAN + n + '.md'] = f'{PLAN}{area}/{n}.md'
    return moves


def text_files():
    out = subprocess.check_output(['git', 'ls-files', '-co', '--exclude-standard'], text=True).splitlines()
    skip = ('browser/', 'node_modules/', 'docs/history/', 'docs/dependency-graph-data.js',
            'module/playnet/README.md', 'tools/migrate/regroup-docs.py')
    ext = ('.scm', '.md', '.typ', '.sh', '.py', '.mjs', '.cjs', '.ts', '.txt', '.org', '.json')
    for f in out:
        if f.startswith(skip) or not os.path.isfile(f):
            continue
        if f.endswith(ext) or os.path.basename(f) in ('Makefile', 'guix.scm', '.gitignore'):
            yield f


LINK = re.compile(r'(\]\()([^)\s#]+)((?:#[^)\s]*)?\))')


def main(dry):
    moves = plan()
    new_of_old = dict(moves)
    old_of_new = {v: k for k, v in moves.items()}
    names = '|'.join(re.escape(o[len(PLAN):-3]) for o in sorted(moves, key=len, reverse=True))
    path_rx = re.compile(r'(?<![\w/.-])((?:docs/)?planning/)(' + names + r')(\.md)(?![\w-])')
    area_of = {o[len(PLAN):-3]: n[len(PLAN):].split('/')[0] for o, n in moves.items()}

    def fix_paths(text):
        return path_rx.sub(lambda m: m.group(1) + area_of[m.group(2)] + '/' + m.group(2) + m.group(3), text)

    touched = 0
    edits = {}
    for f in text_files():
        try:
            text = open(f, encoding='utf-8').read()
        except UnicodeDecodeError:
            continue
        out = fix_paths(text)
        if f.endswith('.md'):
            old_dir = os.path.dirname(old_of_new.get(f, f))
            new_dir = os.path.dirname(new_of_old.get(f, f))

            def link(m):
                target = m.group(2)
                if re.match(r'[a-z]+:|/|mailto:', target):
                    return m.group(0)
                resolved = os.path.normpath(os.path.join(old_dir, target))
                now = new_of_old.get(resolved, resolved)
                rel = os.path.relpath(now, new_dir)
                if rel == target:
                    return m.group(0)
                return m.group(1) + rel + m.group(3)
            # a link is resolved against the file's OLD place; `f` is its path before the move
            out = LINK.sub(link, out)
        if out != text:
            edits[f] = out
            touched += 1
    print(f'regroup-docs: {len(moves)} documents, {touched} file(s) with rewritten references')
    if dry:
        return
    for src, dst in sorted(moves.items()):
        if not os.path.exists(src):
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        tracked = subprocess.run(['git', 'ls-files', '--error-unmatch', src], capture_output=True).returncode == 0
        if tracked:
            subprocess.check_call(['git', 'mv', src, dst])
        else:
            os.rename(src, dst)
    for f, out in edits.items():
        p = new_of_old.get(f, f)
        open(p, 'w', encoding='utf-8').write(out)


if __name__ == '__main__':
    main('--dry-run' in sys.argv)
