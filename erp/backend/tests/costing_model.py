#!/usr/bin/env python3
"""Independent reference model of the ERP stock valuation (F2 review, 2026-11-18).

Written by the F2 reviewer from the RULES (docs/erp/02 "Valuation", E140 header, STATE 46-49, F2 decision on O2),
NOT from the SQL code, and never imports or calls it. Used three ways:

  python3 -I costing_model.py golden [DIR]          re-compute every stored golden case (G1-G5, G7, G8, R*) from its
                                                    INPUT columns and compare with the stored expected columns
  python3 -I costing_model.py fuzz DB SEED N [MODE] differential test: N random scenarios (receipts, issues, customer
                                                    and supplier returns, backdated documents, cancels, purchase
                                                    receipts that change the last purchase price) are posted through
                                                    the real RPCs in database DB (one rolled-back transaction) and
                                                    every move, correction, line cost, item state and layer list is
                                                    compared with this model. MODE inline (default) | queue (every
                                                    backdated post goes to the recost queue; the job runs at the end).
  import costing_model                             the Ledger class

Semantics (from-scratch): the item state after any sequence of posts / cancels = every NOT cancelled normal move
costed from an empty state in (move_date, move_id) order. A cancelled pair has no effect. Every inbound that covers a
deficit has ONE value-only correction (0 when not needed). Rounding: half away from zero (PostgreSQL round()).

  inbound value  : line (line net) | source_out (qty x the linked issue's unit cost, per method) | current (the
                   official cost now: avg -> avg_cost, FIFO -> next layer out else last cost; none -> purchase price
                   snapshot of the move -> 0; the same value under both methods)
  average        : value / qty after every move that leaves qty > 0; outbound = round(qty x avg, 2); a move to qty 0
                   takes the rest; uncovered quantity at the last avg (no cost history yet: the move's purchase-price
                   snapshot); an inbound first covers the deficit at its own unit cost, the difference is the correction
  FIFO           : layers in (date, seq) order; a partly consumed layer gives round(qty x unit cost, 2), a fully
                   consumed one its exact value left; uncovered quantity at the last consumed / received unit cost
                   (none: the snapshot); the deficit value is covered first by the next inbound (pro rata when partly)
  supplier return: average at the receipt's unit cost unless it empties the stock; FIFO the receipt's layer first
  provisional    : the purchase-price snapshot = the item's last purchase price WHEN THE MOVE WAS POSTED (O2 decision:
                   a costing input, never the price at replay time)
  transfer (T16, added by the T16 implementer, NOT by the F2 reviewer: re-check at F3): a TRF move between warehouses
                   is cost-neutral (02: "transfers do not change cost and do not consume layers"): the item state and
                   the layers do not change. The dispatch move is valued at the item's cost (average: avg_cost, FIFO:
                   value_fifo / qty; the whole stock at its exact values; no stock: the uncovered-quantity rule); the
                   paired transit move and the receipt moves copy the dispatch move (full quantity: its exact value,
                   part: round(qty x its unit cost, 2)). G10 ops: trf (dispatch; the row's move = the source move),
                   trf_in (receipt of src_step; the row's move = the destination move), trf_cancel (src_step).
"""
import csv, json, os, random, subprocess, sys, tempfile
from decimal import Decimal as D, ROUND_HALF_UP, getcontext

getcontext().prec = 50
Z = D(0)


def r(x, n):
    return D(x).quantize(D(1).scaleb(-n), rounding=ROUND_HALF_UP)


def r2(x): return r(x, 2)
def r4(x): return r(x, 4)
def r6(x): return r(x, 6)


class Move:
    def __init__(self, mid, date, qty, rule, in_value=None, src=None, snap=Z):
        self.id, self.date, self.qty, self.rule, self.in_value, self.src, self.snap = mid, date, D(qty), rule, in_value, src, D(snap)
        self.cancelled = False


class Ledger:
    """Moves of ONE item; costs computed from scratch on demand."""

    def __init__(self):
        self.moves = []
        self.lpp = None                       # item's last purchase price (posting order), kept on cancel (STATE 52)

    def add(self, date, qty, rule, in_value=None, src=None, purchase=False):
        m = Move(len(self.moves) + 1, date, qty, rule, in_value, src, self.lpp if self.lpp is not None else Z)
        self.moves.append(m)
        if purchase and m.qty > 0 and in_value is not None:
            self.lpp = r6(D(in_value) / m.qty)
        return m

    def cost(self):
        """-> (results {move id: dict}, corrections {inbound id: (k_avg, k_fifo)}, state dict, layers [(qty, unit, value)])"""
        q = va = vf = dv = avgc = Z
        flast = None                          # last FIFO unit cost (None = no cost history)
        layers = []                           # [date, seq, qty_left, unit_cost, value_left, creating move id]
        res, corr = {}, {}
        for m in sorted((x for x in self.moves if not x.cancelled), key=lambda x: (x.date, x.id)):
            bq = m.qty
            src = res.get(m.src) if m.src else None
            if m.rule == 'transfer':
                x = abs(bq)
                if src is not None:
                    v_a = abs(src['va']) if x == src['qty'] else r2(x * src['uc_avg'])
                    v_f = abs(src['vf']) if x == src['qty'] else r2(x * src['uc_fifo'])
                elif q > 0:
                    v_a = va if x == q else r2(x * avgc)
                    v_f = vf if x == q else r2(x * vf / q)
                else:
                    v_a = r2(x * (avgc if flast is not None else m.snap))
                    v_f = r2(x * (flast if flast is not None else (avgc if avgc != 0 else m.snap)))
                sg = 1 if bq > 0 else -1
                res[m.id] = dict(va=sg * v_a, vf=sg * v_f, uc_avg=r6(v_a / x), uc_fifo=r6(v_f / x), qty=x)
                continue
            if bq > 0:
                if m.rule == 'line' and m.in_value is not None:
                    v_a = v_f = D(m.in_value)
                elif m.rule == 'source_out' and src is not None:
                    v_a, v_f = r2(bq * src['uc_avg']), r2(bq * src['uc_fifo'])
                else:
                    if flast is None:
                        cur = m.snap
                    else:
                        cur = avgc                       # official = average (iSmile); FIFO tenants: next layer out
                        if cur == 0:
                            cur = m.snap
                    v_a = v_f = r2(bq * cur)
                # average, deficit first
                k_a = Z
                if q >= 0:
                    va = va + v_a
                elif q + bq >= 0:
                    target = r2((q + bq) * v_a / bq)
                    k_a = target - (va + v_a)
                    va = target
                else:
                    # still short: the covered part is re-valued at the inbound cost, the rest of the deficit keeps its
                    # provisional unit cost va / q
                    k_a = r2(bq * va / q - v_a)
                    va = va + v_a + k_a
                q_before = q
                q = q + bq
                if q > 0:
                    avgc = r6(va / q)
                elif q == 0:
                    va = Z
                # FIFO, deficit first
                k_f = Z
                c = min(max(-q_before, Z), bq)
                tv = Z
                if c > 0:
                    dq = -q_before
                    dv_c = dv if c == dq else r2(dv * c / dq)
                    tv = v_f if c == bq else r2(c * v_f / bq)
                    k_f = dv_c - tv
                    dv = dv - dv_c
                if bq - c > 0:
                    layers.append([m.date, m.id, bq - c, r6((v_f - tv) / (bq - c)), v_f - tv, m.id])
                vf = vf + v_f + k_f
                flast = r6(v_f / bq)
                corr[m.id] = (k_a, k_f)
                res[m.id] = dict(va=v_a, vf=v_f, uc_avg=r6(v_a / bq), uc_fifo=r6(v_f / bq))
            else:
                x = -bq
                prov = False
                if q >= x:
                    if q == x:
                        v_a = va
                    elif m.rule == 'source_in' and src is not None:
                        v_a = r2(x * src['uc_avg'])
                    else:
                        v_a = r2(x * avgc)
                elif q > 0:
                    v_a = va + r2((x - q) * avgc)
                    prov = True
                else:
                    v_a = r2(x * (avgc if flast is not None else m.snap))
                    prov = True
                va = va - v_a
                q = q - x
                if q > 0:
                    avgc = r6(va / q)
                elif q == 0:
                    va = Z
                rem, v_f = x, Z
                order = sorted((l for l in layers if l[2] > 0), key=lambda l: (l[0], l[1]))
                if m.rule == 'source_in' and src is not None:
                    own = [l for l in order if l[5] == m.src]
                    order = own + [l for l in order if l[5] != m.src]
                for l in order:
                    if rem <= 0:
                        break
                    take = min(rem, l[2])
                    tval = l[4] if take == l[2] else r2(take * l[3])
                    l[2] -= take
                    l[4] -= tval
                    v_f += tval
                    rem -= take
                    flast = l[3]
                if rem > 0:
                    unit = flast if flast is not None else (avgc if avgc != 0 else m.snap)
                    tval = r2(rem * unit)
                    dv += tval
                    v_f += tval
                    prov = True
                vf = vf - v_f
                if q == 0:
                    vf = Z
                    dv = Z
                res[m.id] = dict(va=-v_a, vf=-v_f, uc_avg=r6(v_a / x), uc_fifo=r6(v_f / x))
        state = dict(qty=q, value_avg=va, value_fifo=vf, avg_cost=avgc, deficit=dv)
        open_layers = [(l[2], l[3], l[4]) for l in sorted(layers, key=lambda l: (l[0], l[1])) if l[2] > 0]
        return res, corr, state, open_layers


def num(x):
    """'10.5000' -> '10.5' (same text form as the suites' t.num)."""
    s = format(D(x).normalize(), 'f')
    return s


def layers_text(ls):
    return ';'.join('%s@%s' % (num(q), num(u)) for q, u, _ in ls)


# ---------------------------------------------------------------------------------------------------------------
# golden: re-compute the stored cases from their inputs
# ---------------------------------------------------------------------------------------------------------------
def golden(dirname):
    bad = 0
    checked = 0
    for name in sorted(os.listdir(dirname)):
        if not name.endswith('.csv') or name.startswith('conv_'):
            continue
        rows = list(csv.DictReader(open(os.path.join(dirname, name), encoding='utf-8')))
        case = name[:-4]
        L = Ledger()
        by_step = {}
        pairs = {}
        dated = 'day' in rows[0]
        for row in rows:
            step = int(row['step'])
            day = int(row['day']) if dated and row.get('day') not in (None, '') else 0
            op = row['op']
            qty = D(row['qty'] or 0)
            cost = row.get('unit_cost') or ''
            src = by_step.get(int(row['src_step'])) if row.get('src_step') else None
            if op in ('in', 'pin'):
                m = L.add(day, qty, 'line', r2(qty * r4(D(cost))), purchase=(op == 'pin' or case == 'G7'))
            elif op == 'in_nocost':
                m = L.add(day, qty, 'current')
            elif op == 'out':
                m = L.add(day, -qty, 'issue')
            elif op == 'ret_in':
                m = L.add(day, qty, 'source_out' if src else 'current', src=src.id if src else None)
            elif op == 'ret_out':
                m = L.add(day, -qty, 'source_in', src=src.id if src else None)
            elif op == 'cancel':
                by_step[int(row['src_step'])].cancelled = True
                m = None
            elif op == 'trf':                       # T16 dispatch: source out + transit in (paired)
                m = L.add(day, -qty, 'transfer')
                pairs[step] = [m, L.add(day, qty, 'transfer', src=m.id)]
            elif op == 'trf_in':                    # T16 receipt of the dispatch of src_step: transit out + destination in
                d0 = by_step[int(row['src_step'])]
                L.add(day, -qty, 'transfer', src=d0.id)
                m = L.add(day, qty, 'transfer', src=d0.id)
            elif op == 'trf_cancel':                # T16 cancel of a dispatched transfer: the pair has no effect
                for x in pairs[int(row['src_step'])]:
                    x.cancelled = True
                m = None
            else:
                raise SystemExit('unknown op %s in %s' % (op, name))
            if m is not None:
                by_step[step] = m
            res, corr, st, ls = L.cost()
            got, want = {}, {}
            # state after the step (cases without day: every step is the last date; dated cases: final state only)
            if 'exp_qty' in row and row['exp_qty'] != '':
                got['qty'], want['qty'] = num(st['qty']), num(D(row['exp_qty']))
                got['avg'], want['avg'] = str(r2(st['value_avg'])), str(r2(D(row['exp_value_avg'])))
                got['fifo'], want['fifo'] = str(r2(st['value_fifo'])), str(r2(D(row['exp_value_fifo'])))
                if 'exp_layers' in row:
                    got['layers'], want['layers'] = layers_text(ls), row['exp_layers'] or ''
            if m is not None and not dated and row.get('exp_move_avg', '') != '':
                got['move_avg'], want['move_avg'] = str(res[m.id]['va']), str(r2(D(row['exp_move_avg'])))
                got['move_fifo'], want['move_fifo'] = str(res[m.id]['vf']), str(r2(D(row['exp_move_fifo'])))
            if row.get('exp_corr_avg', '') != '' and not dated:
                got['corr'] = '%s/%s' % corr.get(m.id, (Z, Z))
                want['corr'] = '%s/%s' % (r2(D(row['exp_corr_avg'])), r2(D(row['exp_corr_fifo'])))
            checked += 1
            if got != want:
                bad += 1
                print('MISMATCH %s step %s: got %s want %s' % (case, step, json.dumps(got), json.dumps(want)))
        if dated:
            # dated cases (G8, R*): the FINAL values of every move after the last post
            res, corr, st, ls = L.cost()
            for row in rows:
                if row.get('exp_move_avg', '') == '' or int(row['step']) not in by_step:
                    continue
                m = by_step[int(row['step'])]
                if m.cancelled:
                    continue
                g = '%s/%s' % (res[m.id]['va'], res[m.id]['vf'])
                w = '%s/%s' % (r2(D(row['exp_move_avg'])), r2(D(row['exp_move_fifo'])))
                if row.get('exp_corr_avg', '') != '' or m.qty > 0:      # corrections: 0 when the column is empty
                    k = corr.get(m.id, (Z, Z))
                    g += ' corr %s/%s' % (r2(k[0]) + Z, r2(k[1]) + Z)
                    w += ' corr %s/%s' % (r2(D(row.get('exp_corr_avg') or 0)), r2(D(row.get('exp_corr_fifo') or 0)))
                checked += 1
                if g != w:
                    bad += 1
                    print('MISMATCH %s step %s final move: got %s want %s' % (case, row['step'], g, w))
            print('%s final state: qty %s, avg %s, FIFO %s, layers %s' % (case, num(st['qty']), r2(st['value_avg']), r2(st['value_fifo']), layers_text(ls)))
    print('golden recompute: %d checks, %d mismatches' % (checked, bad))
    return bad == 0


# ---------------------------------------------------------------------------------------------------------------
# fuzz: random scenarios through the real RPCs, compared with the model
# ---------------------------------------------------------------------------------------------------------------
def gen_scenario(rng, n_ops):
    ops = []          # (step, op, day, qty, cost, src_step)
    posted = []       # [(step, kind, day, qty)] not cancelled
    children = set()  # steps that have a linked return (cannot be cancelled)
    step = 0
    for _ in range(n_ops):
        step += 1
        day = -rng.randint(0, 12)
        k = rng.random()
        ins = [p for p in posted if p[1] in ('in', 'pin')]
        outs = [p for p in posted if p[1] == 'out']
        if k < 0.30 or not posted:
            op = rng.choice(['in', 'in', 'pin'])
            qty = D(rng.choice([1, 2, 3, 5, 7, 10, 12, D('2.5'), D('0.3333')]))
            cost = r4(D(rng.randint(100, 2000)) / D(rng.choice([100, 300, 700])))
            ops.append((step, op, day, qty, cost, None))
            posted.append((step, op, day, qty))
        elif k < 0.62:
            qty = D(rng.choice([1, 2, 3, 4, 6, 8, D('1.5'), D('0.3333')]))
            ops.append((step, 'out', day, qty, None, None))
            posted.append((step, 'out', day, qty))
        elif k < 0.70 and outs:
            s = rng.choice(outs)
            ops.append((step, 'ret_in', max(day, s[2]), min(s[3], D(rng.choice([1, 2]))), None, s[0]))
            children.add(s[0])
            posted.append((step, 'ret_in', max(day, s[2]), None))
        elif k < 0.74:
            ops.append((step, 'ret_in', day, D(rng.choice([1, 2])), None, None))     # unlinked: current cost
            posted.append((step, 'ret_in', day, None))
        elif k < 0.80 and ins:
            s = rng.choice(ins)
            ops.append((step, 'ret_out', max(day, s[2]), min(s[3], D(rng.choice([1, 2, 3]))), None, s[0]))
            children.add(s[0])
            posted.append((step, 'ret_out', max(day, s[2]), None))
        else:
            cand = [p for p in posted if p[0] not in children]
            if not cand:
                continue
            s = rng.choice(cand)
            ops.append((step, 'cancel', 0, Z, None, s[0]))
            posted.remove(s)
    return ops


def model_run(ops):
    L = Ledger()
    by = {}
    for step, op, day, qty, cost, src in ops:
        if op in ('in', 'pin'):
            by[step] = L.add(day, qty, 'line', r2(qty * cost), purchase=(op == 'pin'))
        elif op == 'out':
            by[step] = L.add(day, -qty, 'issue')
        elif op == 'ret_in':
            by[step] = L.add(day, qty, 'source_out' if src else 'current', src=by[src].id if src else None)
        elif op == 'ret_out':
            by[step] = L.add(day, -qty, 'source_in', src=by[src].id)
        elif op == 'cancel':
            by[src].cancelled = True
    res, corr, st, ls = L.cost()
    out = {}
    for step, m in by.items():
        if m.cancelled:
            continue
        a = res[m.id]
        k = corr.get(m.id, (Z, Z))
        out[step] = '%s|%s|%s|%s|%s|%s' % (a['va'], a['vf'], a['uc_avg'], a['uc_fifo'], r2(k[0]) + Z, r2(k[1]) + Z)
    final = '%s|%s|%s|%s' % (num(st['qty']), r2(st['value_avg']), r2(st['value_fifo']), layers_text(ls))
    return out, final


FUZZ_SQL_HEAD = r"""
\set ON_ERROR_STOP 1
\o /dev/null
set client_min_messages = warning;
begin;
\ir _helpers.sql
create table t.ids (a uuid);
insert into t.ids select t.tenant('fz');
create function t.a() returns uuid language sql security definer as $$ select a from t.ids $$;
select t.init(t.a());
select t.branch(t.a(), 'A1', 0);
select t.member(t.a(), 1, 'owner');
insert into erp.warehouses (tenant_id, branch_id, code, name) values (t.a(), t.br(t.a(), 'A1'), 'W1', 'W one'), (t.a(), t.br(t.a(), 'A1'), 'W2', 'W two');
insert into erp.doc_types (doc_type, name, area, cap_prefix, sort, enabled, stock_sign, cost_rule, needs_warehouse, price_kind) values
  ('TIN', 'Test in', 'warehouse', 'tst', 990, true, 1, 'line', true, 'cost'),
  ('TPIN', 'Test purchase in', 'purchasing', 'tst', 994, true, 1, 'line', true, 'cost'),
  ('TOUT', 'Test out', 'warehouse', 'tst', 991, true, -1, 'issue', true, 'none'),
  ('TRIN', 'Test customer return', 'warehouse', 'tst', 992, true, 1, 'source_out', true, 'none'),
  ('TROUT', 'Test supplier return', 'warehouse', 'tst', 993, true, -1, 'source_in', true, 'none')
on conflict (doc_type) do nothing;
insert into erp.doc_transitions (doc_type, from_state, to_state, cap, action, label)
select dt, f, t2, c, a, 'x' from unnest(array['TIN', 'TPIN', 'TOUT', 'TRIN', 'TROUT']) dt,
  (values ('draft', 'posted', 'create', 'post'), ('posted', 'cancelled', 'approve', 'cancel')) v(f, t2, c, a)
on conflict do nothing;
insert into erp.capabilities (capability, area) values ('doc.tst.read', 'test'), ('doc.tst.create', 'test'), ('doc.tst.approve', 'test') on conflict do nothing;
insert into erp.role_caps (tenant_id, role, capability) values (t.a(), 'owner', 'doc.tst.read'), (t.a(), 'owner', 'doc.tst.create'), (t.a(), 'owner', 'doc.tst.approve');
insert into erp.series (tenant_id, branch_id, doc_type, code)
select t.a(), t.br(t.a(), 'A1'), dt, dt || '-A1' from unnest(array['TIN', 'TPIN', 'TOUT', 'TRIN', 'TROUT']) dt;
create table t.ops (sc int, step int, op text, day int, qty numeric, cost numeric, src_step int, wh text);
create table t.res (sc int, step int, doc uuid, line uuid, item uuid);
grant select, insert on t.ops, t.res to authenticated;
create function t.wh(p_code text) returns uuid language sql security definer as $$ select warehouse_id from erp.warehouses where tenant_id = t.a() and code = p_code $$;
create function t.mkitem(p_code text) returns uuid language sql security definer as $$
  insert into erp.items (tenant_id, code, name, base_unit_id) select t.a(), p_code, 'Item ' || p_code, unit_id from erp.units where tenant_id = t.a() and code = 'PCS'
  returning item_id $$;
create function t.today() returns date language sql security definer as $$ select erp.today(t.a()) $$;
create function t.recost(p_mode text) returns void language plpgsql security definer as $$
begin if p_mode = 'queue' then perform erp.recost_job(1000); end if; end $$;
grant execute on all functions in schema t to authenticated;
"""

FUZZ_SQL_RUN = r"""
set local role authenticated;
select t.as(1);
%(limit)s
do $$ declare o record; it uuid; d jsonb; r jsonb; cur int := -1; src uuid; begin
  for o in select * from t.ops order by sc, step loop
    if o.sc <> cur then cur := o.sc; it := t.mkitem('FZ' || o.sc); end if;
    if o.op = 'cancel' then
      perform erp_api.doc_set_state((select doc from t.res where sc = o.sc and step = o.src_step), 'cancelled', '{"reason": "fuzz"}', gen_random_uuid());
      continue;
    end if;
    src := (select line from t.res where sc = o.sc and step = o.src_step);
    d := erp_api.doc_save_draft(case o.op when 'in' then 'TIN' when 'pin' then 'TPIN' when 'out' then 'TOUT' when 'ret_in' then 'TRIN' else 'TROUT' end,
           jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'warehouse_id', t.wh(o.wh), 'doc_date', t.today() + o.day,
                              'lines', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('item_id', it, 'qty', o.qty, 'unit_price', o.cost, 'source_line_id', src)))),
           gen_random_uuid());
    r := erp_api.doc_set_state((d ->> 'document_id')::uuid, 'posted', '{"ack_warnings": true}', gen_random_uuid());
    if not (r ->> 'posted')::boolean then raise exception 'not posted: % %', o, r; end if;
    insert into t.res values (o.sc, o.step, (d ->> 'document_id')::uuid, (d #>> '{lines,0,line_id}')::uuid, it);
  end loop;
end $$;
reset role;
select t.recost('%(mode)s');
\o
\copy (select 'M', r.sc, r.step, concat_ws('|', m.value_avg, m.value_fifo, m.unit_cost_avg, m.unit_cost_fifo, coalesce((select sum(c.value_avg) from erp.stock_moves c where c.tenant_id = m.tenant_id and c.covers_move_id = m.move_id and c.kind = 'value_only' and not exists (select 1 from erp.stock_moves x where x.tenant_id = c.tenant_id and x.reverses_move_id = c.move_id)), 0.00), coalesce((select sum(c.value_fifo) from erp.stock_moves c where c.tenant_id = m.tenant_id and c.covers_move_id = m.move_id and c.kind = 'value_only' and not exists (select 1 from erp.stock_moves x where x.tenant_id = c.tenant_id and x.reverses_move_id = c.move_id)), 0.00)), (l.cost_value = abs(m.value_avg) and l.unit_cost = m.unit_cost_avg)::text from t.res r join erp.documents d on d.document_id = r.doc join erp.document_lines l on l.line_id = r.line join erp.stock_moves m on m.tenant_id = d.tenant_id and m.line_id = r.line and m.kind = 'normal' where d.state = 'posted' order by 2, 3) to stdout with (format csv)
\copy (select 'S', o.sc, 0, concat_ws('|', rtrim(rtrim(c.qty::text, '0'), '.'), c.value_avg, c.value_fifo, coalesce((select string_agg(rtrim(rtrim(l.qty_left::text, '0'), '.') || '@' || rtrim(rtrim(l.unit_cost::text, '0'), '.'), ';' order by l.layer_date, l.seq, l.layer_id) from erp.stock_layers l where l.tenant_id = c.tenant_id and l.item_id = c.item_id and l.qty_left > 0 and l.void_run is null), '')), jsonb_array_length(erp.stock_integrity(c.tenant_id, c.item_id))::text || '/' || (select count(*) from erp.recost_queue q where q.tenant_id = c.tenant_id and q.item_id = c.item_id)::text || '/' || coalesce((select sum(p.value_avg)::text || ':' || sum(p.value_fifo)::text from erp.stock_moves p join erp.documents pd on pd.tenant_id = p.tenant_id and pd.document_id = p.document_id where p.tenant_id = c.tenant_id and p.item_id = c.item_id and pd.state = 'cancelled'), '0:0') from (select distinct sc from t.ops) o join erp.items i on i.tenant_id = t.a() and i.code = 'FZ' || o.sc join erp.item_costs c on c.tenant_id = i.tenant_id and c.item_id = i.item_id order by 2) to stdout with (format csv)
rollback;
"""


def fuzz(db, seed, n, mode='inline'):
    rng = random.Random(seed)
    scen = {sc: gen_scenario(rng, rng.randint(6, 16)) for sc in range(1, n + 1)}
    whs = {}
    rows = []
    for sc, ops in scen.items():
        for step, op, day, qty, cost, src in ops:
            wh = 'W2' if rng.random() < 0.2 else 'W1'
            rows.append("(%d,%d,'%s',%d,%s,%s,%s,'%s')" % (sc, step, op, day, qty, 'null' if cost is None else cost, 'null' if src is None else src, wh))
    here = os.path.dirname(os.path.abspath(__file__))
    sql = FUZZ_SQL_HEAD + 'insert into t.ops values\n' + ',\n'.join(rows) + ';\n' + FUZZ_SQL_RUN.replace('%(mode)s', mode).replace(
        '%(limit)s', "set local erp.recost_inline_limit = '0';" if mode == 'queue' else '')
    fd, path = tempfile.mkstemp(suffix='.sql', dir=here)
    with os.fdopen(fd, 'w') as f:
        f.write(sql)
    os.chmod(path, 0o644)
    try:
        cmd = ['psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-d', db, '-f', path]
        if os.geteuid() == 0:
            cmd = ['su', 'postgres', '-c', ' '.join("'%s'" % c for c in cmd)]
        p = subprocess.run(cmd, cwd=here, capture_output=True, text=True)
    finally:
        os.unlink(path)
    if p.returncode != 0:
        print(p.stdout[-2000:], p.stderr[-4000:])
        print('fuzz: the database run FAILED')
        return False
    got_m, got_s = {}, {}
    for row in csv.reader(p.stdout.splitlines()):
        if row[0] == 'M':
            got_m[(int(row[1]), int(row[2]))] = (row[3], row[4])
        elif row[0] == 'S':
            got_s[int(row[1])] = (row[3], row[4])
    bad = 0
    checks = 0
    for sc, ops in scen.items():
        want_m, want_s = model_run(ops)
        for step, w in want_m.items():
            checks += 1
            g = got_m.get((sc, step))
            if g is None or g[0] != w or g[1] != 'true':
                bad += 1
                if bad <= 25:
                    print('MISMATCH sc %d step %d: db %s model %s (line cost = official: %s)' % (sc, step, g and g[0], w, g and g[1]))
        checks += 1
        gs = got_s.get(sc)
        if gs is None or gs[0] != want_s or not gs[1].startswith('0/0/'):
            bad += 1
            if bad <= 25:
                print('MISMATCH sc %d final: db %s model %s (integrity problems / queued / cancelled pairs: %s)' % (sc, gs and gs[0], want_s, gs and gs[1]))
        else:
            pair = gs[1].split('/')[2]
            if pair not in ('0:0',) and any(D(v) != 0 for v in pair.split(':')):
                bad += 1
                print('MISMATCH sc %d: cancelled documents do not net to zero (%s)' % (sc, pair))
        if bad and bad > 25:
            pass
    if bad and os.environ.get('FUZZ_DUMP'):
        for sc in map(int, os.environ['FUZZ_DUMP'].split(',')):
            print('scenario %d ops (step, op, day, qty, cost, src):' % sc)
            for o in scen[sc]:
                print('   ', o)
    print('fuzz %s seed %d: %d scenarios, %d checks, %d mismatches' % (mode, seed, n, checks, bad))
    return bad == 0


if __name__ == '__main__':
    a = sys.argv[1:]
    if not a or a[0] not in ('golden', 'fuzz'):
        raise SystemExit(__doc__)
    if a[0] == 'golden':
        ok = golden(a[1] if len(a) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), 'golden'))
    else:
        ok = fuzz(a[1], int(a[2]), int(a[3]), a[4] if len(a) > 4 else 'inline')
    sys.exit(0 if ok else 1)
