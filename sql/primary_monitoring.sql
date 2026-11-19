-- Run on as-pg1 (CURRENT PRIMARY), database postgres, as Linux postgres.
-- Safe read-only monitoring queries; no updates to database state.
SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END AS db_role;

SELECT application_name, client_addr, state, sync_state,
       sent_lsn, write_lsn, flush_lsn, replay_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn)::bigint) AS unsent_wal,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, write_lsn)::bigint) AS sent_not_written,
       pg_size_pretty(pg_wal_lsn_diff(write_lsn, flush_lsn)::bigint) AS written_not_flushed,
       pg_size_pretty(pg_wal_lsn_diff(flush_lsn, replay_lsn)::bigint) AS flushed_not_replayed,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::bigint) AS total_replay_gap,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;

SELECT slot_name, active, restart_lsn, wal_status,
       CASE WHEN restart_lsn IS NOT NULL
            THEN pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)::bigint)
       END AS wal_distance,
       CASE WHEN safe_wal_size IS NOT NULL
            THEN pg_size_pretty(safe_wal_size)
       END AS safe_wal_headroom,
       invalidation_reason
FROM pg_replication_slots
WHERE slot_name = 'as_pg2_slot';

SELECT sourcefile, sourceline, name, error
FROM pg_file_settings WHERE error IS NOT NULL;
