-- pgbench (T15): a consumption posted and then ROLLED BACK (the number must return to the series: no gap)
begin;
set local role authenticated;
select load.bench_post('CONS');
rollback;
