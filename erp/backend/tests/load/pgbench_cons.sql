-- pgbench (T15): one consumption posted on the 5 hot items of load_std (series CONS-BR1), as the warehouse member
begin;
set local role authenticated;
select load.bench_post('CONS');
commit;
