# PostgreSQL 18 — Native Physical Streaming Replication Lab

**Status: COMPLETED for the stated learning scope (19 November 2026).** Two-node PostgreSQL 18 physical streaming replication with a persistent replication slot, SCRAM authentication, operational logging, replication monitoring, and a controlled standby outage/catch-up test were implemented and verified.

> This is a **production-style learning lab**, **not a production-certified HA deployment**. Native streaming replication is not automatic failover and does not replace backups. The application VIP, HAProxy/Keepalived and database promotion are outside this completed deliverable.

## Architecture

```text
                           Native physical WAL streaming
  as-pg1 (PRIMARY)  --------------------------------------> as-pg2 (STANDBY)
  192.168.136.10:5432                                       192.168.136.11:5432
  PGDATA: /u01/18/data                                      PGDATA: /u01/18/data
  slot: as_pg2_slot                                          primary_slot_name: as_pg2_slot
                  <-- WAL progress / replication feedback --
```

The larger five-VM environment also includes `as-px1`, `as-px2` and `as-app`, but **this repository documents only the completed database portion**. The Vagrantfile is intentionally **not included**, as requested.

## Verified outcomes

| Test | Verified result |
|---|---|
| PostgreSQL 18 primary initialized | System ID `7709811654404845603`, checksums `1` |
| Logging and WAL parameters | Applied; zero `pg_file_settings` errors |
| `pg_stat_statements` | Installed, version `1.12` |
| Replication authentication | `repl_user`, SCRAM, dedicated replication privilege |
| Persistent physical slot | `as_pg2_slot`, active, `wal_status=reserved` |
| Standby creation | `pg_basebackup` successful; `standby.signal` present |
| Streaming | `pg_stat_wal_receiver.status=streaming` |
| Replay test | Row written on primary visible on standby |
| Sender-side WAL lag | All five measured gaps `0 bytes` at checkpoint |
| Standby-outage test | Slot became inactive, approximately 11 MB WAL generated |
| Restart/catch-up | 10,000 rows replayed; matching receive/replay LSNs |
| Final primary slot test | Active, reserved, WAL distance `0 bytes` |

## Files

- [Full build and test guide](docs/POSTGRESQL_18_NATIVE_REPLICATION_GUIDE.md) — one comprehensive Markdown document, including observed outputs and explanations.
- [PostgreSQL configuration example](configs/10-native-ha.conf.example) — **lab baseline only**, not a universal production setting.
- [Replication HBA example](configs/pg_hba.replication.example) — minimum physical-replication allowlist.
- [Primary monitoring SQL](sql/primary_monitoring.sql) — safe to run as a whole on `as-pg1`.
- [Standby monitoring SQL](sql/standby_monitoring.sql) — safe to run as a whole on `as-pg2`.
- [Full query reference](sql/replication_monitoring.sql) — individual queries marked by execution node; **not** intended for execution as one script on either node.

## Running the existing lab

Both PostgreSQL nodes were started as the Linux `postgres` user with `pg_ctl` rather than a systemd-managed service. For a simple health check:

```bash
# On EACH database host, as postgres
/usr/pgsql-18/bin/psql -X -d postgres -c \
  "SELECT pg_is_in_recovery() AS is_standby, current_setting('port') AS port;"
```

For the full operations, credential handling, troubleshooting, and exact commands, read the [guide](docs/POSTGRESQL_18_NATIVE_REPLICATION_GUIDE.md).

## Important production gaps

- No automatic database promotion/fencing or split-brain protection in this completed scope.
- Asynchronous replication: **nonzero potential RPO** on sudden primary loss.
- No verified pgBackRest/PITR/WAL archival or restore test in this project.
- No demonstrated TLS enforcement, firewall hardening, privileged service auto-start or centralized logging/retention.
- The `max_slot_wal_keep_size=1GB` value was chosen for the learning lab and must be sized for real WAL rates and recovery objectives.

Do **not** publish passwords, `.pgpass`, private keys, database files, or unredacted production logs. Configuration examples contain no credentials.

## References

- [PostgreSQL 18 — Streaming replication and standby servers](https://www.postgresql.org/docs/18/warm-standby.html)
- [PostgreSQL 18 — pg_basebackup](https://www.postgresql.org/docs/18/app-pgbasebackup.html)
- [PostgreSQL 18 — Replication slots](https://www.postgresql.org/docs/18/view-pg-replication-slots.html)
- [PostgreSQL 18 — Replication settings](https://www.postgresql.org/docs/18/runtime-config-replication.html)
- [PostgreSQL 18 — Error reporting and logging](https://www.postgresql.org/docs/18/runtime-config-logging.html)

## Publish this repository to GitHub

Create a **new empty GitHub repository** (for example `postgresql-18-native-replication`), extract this ZIP, and in the extracted project folder run:

```bash
git init
git add README.md .gitignore docs/ configs/ sql/
git commit -m "Document verified PostgreSQL 18 native replication lab"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/postgresql-18-native-replication.git
git push -u origin main
```

Replace `YOUR_USERNAME` with the actual account and follow your organization’s authentication rules. **Do not include the local Vagrantfile** or any `.pgpass` secrets. Alternatively upload the Markdown and other project files through GitHub's web interface.
