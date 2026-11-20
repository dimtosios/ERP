#!/usr/bin/env python3
"""iSmile ERP - T15 measurement run against the scratch load database (run_erp_load.sh builds it).

    python3 erp/backend/tests/load/measure_erp.py [--db erp_load] [--n 200] [--clients 50] [--seconds 120] [--no-bench]

Local only: talks to the local PostgreSQL through `su postgres -c psql` (no network, no live system).
Steps: load measure_erp.sql; 50 x 20-line documents saved + posted (kept, notes measure20:i); recost probe item
(RC000001, 2,000 later moves); pgbench (CONS 60 % / GRN 30 % / CONS rolled back 10 %, 3 lines on the 5 hot items, one series each) with
deadlock / numbering / integrity checks; then the read timings (load_std and load_s01) and the recost timings.
Writes tests/load/results.json and tests/load/RESULTS.md.
"""
import argparse, datetime, json, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))


def psql(db, sql, at=True):
    cmd = ['su', 'postgres', '-c', 'psql -X -q -v ON_ERROR_STOP=1 %s -d %s' % ('-At' if at else '', db)]
    p = subprocess.run(cmd, input=sql, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit('psql failed:\n' + sql[:400] + '\n' + p.stderr)
    return p.stdout.strip()


def pj(db, sql):
    out = psql(db, sql)
    return json.loads(out.splitlines()[-1])


# metric -> (group, target ms or None, what it is)
TARGETS = [
    ('item_lookup_code', 'search', 150, 'item lookup, exact code (all visible warehouses)'),
    ('item_lookup_prefix', 'search', 150, 'item lookup, code prefix, one warehouse'),
    ('item_lookup_name', 'search', 150, 'item lookup, name contains'),
    ('item_lookup_barcode', 'search', 150, 'item lookup, exact barcode'),
    ('stock_on_hand_page', 'search', 150, 'on hand, first page of a warehouse'),
    ('stock_on_hand_q', 'search', 150, 'on hand, search by code'),
    ('item_availability', 'search', 150, 'availability of one item (all warehouses)'),
    ('doc_list_first', 'list', 200, 'document list, first page, no filter'),
    ('doc_list_type_state', 'list', 200, 'document list, type + state filter'),
    ('doc_list_month', 'list', 200, 'document list, one month'),
    ('doc_list_page5', 'list', 200, 'document list, a page deep in the history (cursor)'),
    ('doc_get_20', 'open', 150, 'open a posted 20-line document'),
    ('doc_save_draft_20', 'post', None, 'save a 20-line draft (info)'),
    ('post_cons_20', 'post', 300, 'post a 20-line consumption'),
    ('post_grn_20', 'post', 300, 'post a 20-line goods receipt'),
    ('stock_card_item', 'card', 200, 'stock card, first page, typical item'),
    ('stock_card_hot', 'card', 200, 'stock card, first page, hot item (all pgbench moves)'),
    ('stock_card_hot_last', 'card', 200, 'stock card, last 7 days of the hot item (opening qty over its history)'),
    ('report_negative_stock', 'report', None, 'negative-stock report, first page (info)'),
    ('recost_status', 'report', None, 'recost status (info)'),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--db', default='erp_load')
    ap.add_argument('--n', type=int, default=200)
    ap.add_argument('--clients', type=int, default=50)
    ap.add_argument('--seconds', type=int, default=120)
    ap.add_argument('--no-bench', action='store_true')
    a = ap.parse_args()
    if not re.fullmatch(r'erp_load(_\w+)?', a.db):
        sys.exit('refusing: scratch DB name must be erp_load*')
    db = a.db
    res = {'when': datetime.datetime.now().strftime('%Y-%m-%d %H:%M'), 'db': db}
    res['commit'] = subprocess.run(['git', '-C', REPO, 'rev-parse', '--short', 'HEAD'], capture_output=True, text=True).stdout.strip()
    dirty = subprocess.run(['git', '-C', REPO, 'status', '--porcelain', '--', 'erp/backend/E*.sql'], capture_output=True, text=True).stdout.strip()
    if dirty:
        res['commit'] += ' + uncommitted E-file changes'
    res['server'] = psql(db, 'show server_version')
    res['host'] = {'cpus': os.cpu_count(), 'mem_gb': round(os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PHYS_PAGES') / 2 ** 30, 1),
                   'shared_buffers': psql(db, 'show shared_buffers')}
    psql(db, open(os.path.join(HERE, 'measure_erp.sql')).read())
    res['scale'] = json.loads(psql(db, """select jsonb_agg(jsonb_build_object('code', l.code, 'items', l.items, 'warehouses', l.warehouses,
        'documents', (select count(*) from erp.documents d where d.tenant_id = l.tenant_id),
        'lines', (select count(*) from erp.document_lines x where x.tenant_id = l.tenant_id),
        'moves', (select count(*) from erp.stock_moves m where m.tenant_id = l.tenant_id),
        'generate_s', round(extract(epoch from l.finished - l.started))) order by l.code) from load.tenants l"""))
    res['totals'] = json.loads(psql(db, """select jsonb_build_object('tenants', (select count(*) from erp.tenants), 'documents', (select count(*) from erp.documents),
        'moves', (select count(*) from erp.stock_moves), 'db_size', pg_size_pretty(pg_database_size(current_database())))"""))
    print('scale:', res['totals'], flush=True)

    # 1. 20-line documents (kept for doc_get; every run adds 50)
    res['posts'] = pj(db, "begin; set local role authenticated; select load.measure_posts('load_std', 50); commit;")
    print('posts:', res['posts'], flush=True)

    # 2. recost probe item (2,000 later moves; built once)
    psql(db, "call load.recost_setup('load_std', 2000)")

    # 3. concurrency
    if not a.no_bench:
        before = pj(db, "select jsonb_build_object('deadlocks', deadlocks, 'rollbacks', xact_rollback) from pg_stat_database where datname = current_database()")
        nb = int(psql(db, "select count(*) from erp.documents d join load.tenants l on l.tenant_id = d.tenant_id and l.code = 'load_std' where d.state = 'posted'"))
        tmp = tempfile.mkdtemp(prefix='erp_bench.')
        for f in ('pgbench_cons.sql', 'pgbench_grn.sql', 'pgbench_rollback.sql'):
            shutil.copy(os.path.join(HERE, f), tmp)
        os.chmod(tmp, 0o755)
        cmd = 'cd %s && pgbench -n -c %d -j 2 -T %d -f pgbench_cons.sql@6 -f pgbench_grn.sql@3 -f pgbench_rollback.sql@1 %s' % (tmp, a.clients, a.seconds, db)
        p = subprocess.run(['su', 'postgres', '-c', cmd], capture_output=True, text=True)
        out = p.stdout + p.stderr
        shutil.rmtree(tmp, ignore_errors=True)
        res['bench_output'] = out[-3000:]
        after = pj(db, "select jsonb_build_object('deadlocks', deadlocks, 'rollbacks', xact_rollback) from pg_stat_database where datname = current_database()")
        na = int(psql(db, "select count(*) from erp.documents d join load.tenants l on l.tenant_id = d.tenant_id and l.code = 'load_std' where d.state = 'posted'"))
        def grab(rx):
            m = re.search(rx, out)
            return m.group(1) if m else None
        res['bench'] = {'clients': a.clients, 'seconds': a.seconds, 'exit': p.returncode,
                        'transactions': grab(r'number of transactions actually processed: (\d+)'),
                        'failed': grab(r'number of failed transactions: (\d+)'),
                        'latency_avg_ms': grab(r'latency average = ([\d.]+) ms'),
                        'tps': grab(r'tps = ([\d.]+)'), 'aborted_clients': len(re.findall(r'client \d+ aborted', out)),
                        'posted_documents': na - nb, 'deadlocks': after['deadlocks'] - before['deadlocks'],
                        'rollbacks': after['rollbacks'] - before['rollbacks'],
                        'errors': sorted(set(re.findall(r'ERROR:\s+(.*)', out)))[:5]}
        res['bench']['checks'] = pj(db, 'select load.check_after_bench()')
        print('bench:', json.dumps(res['bench']), flush=True)
        psql(db, 'vacuum analyze erp.stock_moves; vacuum analyze erp.documents; vacuum analyze erp.document_lines; vacuum analyze erp.stock_balances')

    # 4. reads (rolled back), standard and one small tenant
    res['reads_std'] = pj(db, "begin; set local role authenticated; select load.measure_reads('load_std', %d); rollback;" % a.n)
    res['reads_s01'] = pj(db, "begin; set local role authenticated; select load.measure_reads('load_s01', %d); rollback;" % max(a.n // 4, 20))
    print('reads done', flush=True)

    # 5. recost (each rolled back)
    res['backdate'] = [pj(db, "begin; set local role authenticated; select load.measure_backdate('load_std'); rollback;") for _ in range(5)]
    res['replay'] = [pj(db, "begin; select load.measure_replay('load_std'); rollback;") for _ in range(3)]
    res['integrity_final'] = pj(db, "select jsonb_object_agg(l.code, jsonb_array_length(erp.stock_integrity(l.tenant_id))) from load.tenants l")
    json.dump(res, open(os.path.join(HERE, 'results.json'), 'w'), indent=1, sort_keys=True)
    write_md(res)
    print('wrote RESULTS.md', flush=True)


def fmt(s):
    return '%s / %s / %s' % (s['p50'], s['p95'], s['max']) if s else '-'


def write_md(r):
    std = {**r['reads_std'], **r.get('posts', {})}
    L = ['# ERP load results (T15)', '',
         'Generated by `measure_erp.py` on %s, commit `%s`, PostgreSQL %s, %s CPUs / %s GB RAM, shared_buffers %s (a sandbox VM, '
         'not the Supabase tier). Database `%s` (scratch, local), %s tenants, %s documents, %s stock moves, %s.' % (
             r['when'], r['commit'], r['server'], r['host']['cpus'], r['host']['mem_gb'], r['host']['shared_buffers'], r['db'],
             r['totals']['tenants'], r['totals']['documents'], r['totals']['moves'], r['totals']['db_size']), '',
         'Timings are server-side (clock_timestamp around each RPC, inside the database), as role `authenticated` with a load '
         'member\'s claims, so require_member / require_cap / RLS run as for the app. Network and browser time are NOT included. '
         'Values are p50 / p95 / max in ms; pass = p95 within the 03 target.', '',
         '## Scale', '', 'Counts at the start of this run; load_std includes the documents earlier measurement runs added (pgbench, '
         '20-line documents, the recost probe item RC000001 with 2,001 documents).', '', '| tenant | items | warehouses | documents | lines | moves | generated in (s) |', '|---|---|---|---|---|---|---|']
    sc = {t['code']: t for t in r['scale']}
    small = sorted(c for c in sc if c.startswith('load_s') and c != 'load_std')
    rows = [sc[c] for c in ('load_std', 'load_stress') if c in sc] + [sc[c] for c in small[:1]]
    if len(small) > 1:
        rows.append({'code': '%s .. %s (same scale as %s)' % (small[1], small[-1], small[0])})
    for t in rows:
        L.append('| %s | %s | %s | %s | %s | %s | %s |' % tuple(str(t.get(k, '')) for k in ('code', 'items', 'warehouses', 'documents', 'lines', 'moves', 'generate_s')))
    L += ['', '## Latency (03 targets)', '', '| metric | what | target p95 | load_std p50 / p95 / max | load_s01 p50 / p95 / max | pass |', '|---|---|---|---|---|---|']
    for k, grp, tgt, what in TARGETS:
        s = std.get(k); s1 = r['reads_s01'].get(k)
        ok = '-' if tgt is None or not s else ('yes' if s['p95'] <= tgt and (not s1 or s1['p95'] <= tgt) else '**NO**')
        L.append('| `%s` | %s | %s | %s | %s | %s |' % (k, what, '%d ms' % tgt if tgt else '-', fmt(s), fmt(s1), ok))
    bd = r['backdate']; rp = r['replay']
    bms = sorted(x['ms'] for x in bd); rms = sorted(x['ms'] for x in rp)
    L += ['', '## Recost (target: an item with 2,000 later moves <= 2 s)', '',
          '| path | later / replayed moves | runs | ms (min / max) | pass |', '|---|---|---|---|---|',
          '| backdated GRN posted inline (`doc_set_state`, replays every later move in the posting transaction) | %s | %d | %s / %s | %s |' % (
              bd[0]['later_moves'], len(bd), bms[0], bms[-1], 'yes' if bms[-1] <= 2000 and not bd[0]['queued'] else '**NO**'),
          '| queue path (`erp.recost_item`, what the 5-minute job runs) | %s | %d | %s / %s | %s |' % (
              rp[0]['moves'], len(rp), rms[0], rms[-1], 'yes' if rms[-1] <= 2000 else '**NO**'), '']
    b = r.get('bench')
    if b:
        ser = b['checks']['series']
        L += ['## Concurrency (pgbench)', '',
              '%d clients, %d s, `pgbench_cons.sql@6 pgbench_grn.sql@3 pgbench_rollback.sql@1`: each transaction saves and posts a 3-line CONS or GRN on the 5 hot '
              'items of load_std (series CONS-BR1 / GRN-BR1), as the warehouse member, CONS past negative stock with ack; one in ten posts a CONS '
              'and rolls back (its number must return to the series).' % (b['clients'], b['seconds']), '',
              '| check | result |', '|---|---|',
              '| transactions / tps / avg latency | %s / %s / %s ms |' % (b['transactions'], b['tps'], b['latency_avg_ms']),
              '| documents posted in the run | %s |' % b['posted_documents'],
              '| failed transactions / aborted clients | %s / %s |' % (b['failed'] or 0, b['aborted_clients']),
              '| deadlocks (pg_stat_database delta) | %s |' % b['deadlocks'],
              '| numbering: every series of load_std gapless and unique | %s |' % ('yes' if all(s['gapless'] for s in ser) else '**NO**'),
              '| stock_integrity problems (all tenants) | %s |' % sum(b['checks']['integrity'].values()),
              '| drafts left in load_std | %s |' % b['checks']['unposted_drafts_bench'], '']
        L += ['| series | posted | distinct numbers | min | max | gapless |', '|---|---|---|---|---|---|']
        for s in ser:
            L.append('| %s | %s | %s | %s | %s | %s |' % (s['series'], s['posted'], s['distinct'], s['min'], s['max'], 'yes' if s['gapless'] else '**NO**'))
        if b['errors']:
            L += ['', 'Errors seen: ' + '; '.join('`%s`' % e for e in b['errors'])]
        L.append('')
    L += ['Final `erp.stock_integrity` problem count per tenant: %s (0 = ledger, balances, cost state and layers agree).' % (
        sum(r['integrity_final'].values())), '', open(os.path.join(HERE, 'RESULTS_notes.md')).read().strip(), '']
    open(os.path.join(HERE, 'RESULTS.md'), 'w').write('\n'.join(L))


if __name__ == '__main__':
    main()
