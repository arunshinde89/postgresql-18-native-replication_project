-- PostgreSQL 18 native physical replication monitoring.
-- Run connected to database 'postgres'. Use the Linux 'postgres' account.
-- Some functions are meaningful ONLY on primary or standby as labeled.

-- 01: BOTH NODES — identify role
SELECT inet_server_addr() AS server_ip,
       CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END AS db_role,
       current_setting('data_directory') AS pgdata;

-- 02: PRIMARY — sender state, byte gaps and async/sync mode
SELECT application_name, client_addr, state, sync_state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)::bigint) AS unsent_wal,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, write_lsn)::bigint) AS sent_not_written,
       pg_size_pretty(pg_wal_lsn_diff(write_lsn, flush_lsn)::bigint) AS written_not_flushed,
       pg_size_pretty(pg_wal_lsn_diff(flush_lsn, replay_lsn)::bigint) AS flushed_not_replayed,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::bigint) AS total_replay_gap,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;

-- 03: PRIMARY — slot state and WAL retention; NOT filesystem usage
SELECT slot_name, slot_type, active, restart_lsn, wal_status,
       CASE WHEN restart_lsn IS NOT NULL
            THEN pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(),restart_lsn)::bigint)
       END AS wal_distance,
       CASE WHEN safe_wal_size IS NOT NULL
            THEN pg_size_pretty(safe_wal_size)
       END AS safe_wal_headroom,
       invalidation_reason
FROM pg_replication_slots
WHERE slot_name = 'as_pg2_slot';

-- 04: STANDBY — receiver info (one row if connected)
SELECT status, slot_name, sender_host, sender_port, latest_end_lsn
FROM pg_stat_wal_receiver;

-- 05: STANDBY — local WAL receive vs replay (NULL may be normal before first connection)
SELECT pg_is_in_recovery() AS is_standby,
       pg_last_wal_receive_lsn() AS received_lsn,
       pg_last_wal_replay_lsn() AS replayed_lsn,
       pg_last_xact_replay_timestamp() AS last_replay_commit_time;

-- 06: BOTH NODES — configuration file parse errors
SELECT sourcefile, sourceline, name, error
FROM pg_file_settings WHERE error IS NOT NULL;

-- 07: BOTH NODES — production operational checks
SELECT name, setting, unit, pending_restart
FROM pg_settings
WHERE name IN ('wal_level','max_wal_senders','max_replication_slots',
               'max_slot_wal_keep_size','logging_collector','shared_preload_libraries')
ORDER BY name;

-- OS checks (NOT SQL), as Linux postgres:
-- df -hT /u01/18/data
-- du -sh /u01/18/data/pg_wal
-- ls -lhtr /u01/18/log
