-- Run on as-pg2 (CURRENT STANDBY), database postgres, as Linux postgres.
-- Safe read-only monitoring queries; no updates to database state.
SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END AS db_role;

SELECT status, slot_name, sender_host, sender_port,
       written_lsn, flushed_lsn, latest_end_lsn, latest_end_time
FROM pg_stat_wal_receiver;

SELECT pg_is_in_recovery() AS is_standby,
       pg_last_wal_receive_lsn() AS received_lsn,
       pg_last_wal_replay_lsn() AS replayed_lsn,
       pg_last_xact_replay_timestamp() AS last_replayed_commit_time;

SELECT sourcefile, sourceline, name, error
FROM pg_file_settings WHERE error IS NOT NULL;
