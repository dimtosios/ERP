-- pgbench (T15): one goods receipt on the 5 hot items of load_std (series GRN-BR1), as the warehouse member
begin;
set local role authenticated;
select load.bench_post('GRN');
commit;
