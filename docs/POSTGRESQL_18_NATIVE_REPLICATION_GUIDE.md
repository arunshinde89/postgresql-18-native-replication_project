# PostgreSQL 18 Native Streaming Replication — End-to-End Lab and Test Report

**Project outcome:** COMPLETE within the agreed scope: installation → primary initialization → native physical replication with a persistent slot → monitoring → controlled standby outage and recovery.

**Test date:** 19 November 2026  
**Platform:** Rocky Linux 10 on VMware Workstation; PostgreSQL 18 from PGDG RPMs  
**DBA OS account:** `postgres` (no root needed for database-level commands once the Linux team has prepared software, directories and SELinux)  
**Excluded from this release:** Vagrantfile, HAProxy/Keepalived, VIP, application routing, automatic primary failover, manual promotion and `pg_rewind` testing.

> **Scope warning.** This is a well-observed *production-style learning lab*, not a fully secured or automated production HA service. `async` replication does not guarantee zero data loss, replication is not backup, and a two-node native setup needs an external fencing/promotion process before safe failover.

---

## 1. Architecture and current state

```text
                     Native physical replication (WAL)
                ┌─────────────────────────────────────┐
                │                                     ▼
        as-pg1:5432                                as-pg2:5432
        192.168.136.10                             192.168.136.11
        PRIMARY                                    STANDBY
        /u01/18/data                               /u01/18/data
        WAL sender                                WAL receiver + replay
        slot: as_pg2_slot                          primary_slot_name: as_pg2_slot
                ▲                                     │
                └──── replication status feedback ────┘
```

### Inventory

| Host | Role in broader lab | Work completed here |
|---|---|---|
| `as-pg1` / `192.168.136.10` | PostgreSQL primary | Installed, initialized, configured, streaming enabled |
| `as-pg2` / `192.168.136.11` | Physical standby | Installed, cloned, streaming, outage/recovery tested |
| `as-px1` / `192.168.136.20` | Proxy 1 | **Outside completed replication deliverable** |
| `as-px2` / `192.168.136.21` | Proxy 2 | **Outside completed replication deliverable** |
| `as-app` / `192.168.136.30` | Application test VM | **Outside completed replication deliverable** |

**Known final state:** `as-pg1` primary, `as-pg2` standby, physical slot `as_pg2_slot` active and healthy. The test row and 10,000-row outage workload were confirmed on the standby. **No switchover or promotion has been performed.**

### Storage and service conventions

- PostgreSQL binaries: `/usr/pgsql-18/bin/`
- PGDATA (both servers): `/u01/18/data`
- PostgreSQL file logs (both servers): `/u01/18/log`
- PostgreSQL TCP port (both servers): `5432`
- Configuration include: `/u01/18/data/conf.d/10-native-ha.conf`
- Initial replication user: `repl_user`
- Initial physical slot: `as_pg2_slot`
- During this lab, the `postgres` user operated PostgreSQL via `pg_ctl`; **systemd integration remains an OS-team follow-up**.

---

## 2. PostgreSQL 18 installation and primary initialization

### 2.1 Linux/platform prerequisites — ONCE on each database VM

**Performed by Linux infrastructure team with elevated OS permissions, not by the DBA account.**

Install PostgreSQL 18 packages using the PGDG repository (Rocky Linux 10 / EL10):

```bash
dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-10-x86_64/pgdg-redhat-repo-latest.noarch.rpm
dnf install -y postgresql18 postgresql18-server postgresql18-contrib
```

Verify:

```bash
/usr/pgsql-18/bin/postgres --version
/usr/pgsql-18/bin/pg_basebackup --version
```

Provision and assign the appropriate ownership/SELinux label to `/u01/18/data` and `/u01/18/log`. In this lab, the paths were writable by the `postgres` account and a custom PostgreSQL SELinux context was configured. In production, validate mount points, independent storage capacity, OS patching, backups and network controls with infrastructure. **Simply creating `/u01` does not make it a separate filesystem.**

### 2.2 Initialize **only the primary** — `as-pg1`, as `postgres`

**Do not execute `initdb` on `as-pg2`: it will be created from `pg_basebackup`.**

Inspect before initializing:

```bash
whoami
ls -ld /u01/18/data /u01/18/log
df -hT /u01/18/data
/usr/pgsql-18/bin/pg_ctl -D /u01/18/data status
```

Only when PGDATA is empty and no database is running:

```bash
/usr/pgsql-18/bin/initdb \
  -D /u01/18/data \
  --data-checksums \
  --auth-local=peer \
  --auth-host=scram-sha-256
```

Check the result:

```bash
/usr/pgsql-18/bin/pg_controldata /u01/18/data \
  | grep -E 'Database system identifier|Data page checksum version'
```

**Observed on `as-pg1`:**

```text
Database system identifier: 7709811654404845603
Data page checksum version: 1
```

Data checksums help detect corrupted data pages; they are not a substitute for backups. PostgreSQL 18 enables checksums by default; `--data-checksums` makes the intent explicit.

### 2.3 WAL and logging configuration — `as-pg1`, as `postgres`

The lab configuration is preserved in [`../configs/10-native-ha.conf.example`](../configs/10-native-ha.conf.example). The following major values were applied:

| Parameter | Value | Reason |
|---|---|---|
| `listen_addresses` | `*` | Let database nodes communicate on the lab network; restrict with HBA/firewall |
| `password_encryption` | `scram-sha-256` | Avoid legacy MD5 credentials |
| `wal_level` | `replica` | Physical streaming WAL records |
| `max_wal_senders` | `10` | WAL sender capacity |
| `max_replication_slots` | `10` | Physical slot capacity |
| `wal_keep_size` | `256MB` | Additional minimum WAL retention, **not** a hard guarantee of disconnected standby survivability |
| `max_slot_wal_keep_size` | `1GB` | **Lab-only** cap on slot-driven WAL retention at checkpoint |
| `hot_standby` | `on` | Allows standby read-only queries |
| `fsync`, `full_page_writes` | `on` | Durability safeguards |
| `shared_buffers` | `1GB` | Starting point for 4 GiB VM; workload tuning required |
| `logging_collector` | `on` | Write database server logs to files |
| `log_directory` | `/u01/18/log` | Dedicated log directory (not necessarily dedicated mount) |
| `log_min_duration_statement` | `1000ms` | Capture queries exceeding one second |
| `log_lock_waits` | `on` | Investigate lock contention |
| `log_temp_files` | `64MB` | Log large temporary files |
| `log_autovacuum_min_duration` | `5s` | Visibility into expensive maintenance |
| `shared_preload_libraries` | `pg_stat_statements` | SQL workload statistics |
| `track_io_timing` | `on` | I/O timing diagnostics |

Before startup, the DBA created `conf.d/10-native-ha.conf` and added `include_dir = 'conf.d'` to `postgresql.conf` **only once**. The directory and configuration file were owned by `postgres` with restricted permissions.

Start primary (lab operator, `as-pg1`, as `postgres`):

```bash
/usr/pgsql-18/bin/pg_ctl -D /u01/18/data \
  -l /u01/18/log/startup.log -w start
```

Validate from SQL:

```sql
SELECT pg_is_in_recovery() AS is_standby;
SELECT pg_current_logfile();
SELECT name, setting, pending_restart
FROM pg_settings
WHERE name IN ('wal_level','max_wal_senders','max_replication_slots',
               'max_slot_wal_keep_size','logging_collector','shared_preload_libraries')
ORDER BY name;
SELECT sourcefile, sourceline, name, error
FROM pg_file_settings WHERE error IS NOT NULL;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SELECT extname, extversion FROM pg_extension WHERE extname='pg_stat_statements';
```

**Observed:**

```text
pg_current_logfile(): /u01/18/log/postgresql-2026-11-19_094349.log
logging_collector        on
max_replication_slots    10
max_slot_wal_keep_size   1024  -- MB in pg_settings
max_wal_senders          10
shared_preload_libraries pg_stat_statements
wal_level                replica
all shown pending_restart = false
pg_file_settings errors: 0 rows
pg_stat_statements extension version: 1.12
```

**Logging caution:** `log_rotation_age`/`log_rotation_size` create new files but **do not remove old files**. Real production requires retention, forwarding, alerting and protection against sensitive query text exposure. `pg_ctl` as used here does not provide the auto-start and lifecycle guarantees of a platform-managed systemd unit.

---

## 3. Native physical streaming replication

**Operator convention:** All database commands below run as the **Linux `postgres` user** on the indicated VM. `psql` commands are executed against database `postgres` unless otherwise stated. The infrastructure team handles OS-level access, SELinux and package installation.

### 3.1 Create dedicated replication role — `as-pg1`

```sql
SHOW password_encryption;  -- expected scram-sha-256

CREATE ROLE repl_user
WITH LOGIN REPLICATION
NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;

-- Run in psql, not in a SQL script; prompts without printing secret:
\password repl_user

SELECT rolname, rolcanlogin, rolreplication, rolsuper, rolcreatedb, rolcreaterole
FROM pg_roles WHERE rolname = 'repl_user';
```

**Verified:** `rolcanlogin=t`, `rolreplication=t`, `rolsuper=f`, `rolcreatedb=f`, `rolcreaterole=f`. No superuser password was needed on the standby.

### 3.2 Allow the standby in HBA — `as-pg1`

Back up the file and review first-match rules before adding entries:

```bash
cp -p /u01/18/data/pg_hba.conf \
  "/u01/18/data/pg_hba.conf.bak.$(date +%Y%m%d_%H%M%S)"
```

Entries appended in the lab (example in [`../configs/pg_hba.replication.example`](../configs/pg_hba.replication.example)):

```conf
host replication repl_user 192.168.136.11/32 scram-sha-256
host replication repl_user 192.168.136.10/32 scram-sha-256
```

`replication` is a **special HBA database field for physical replication**, not an actual database. The `.10` entry is intended for reverse-direction replication after a future switchover, but switchover configuration and reverse-direction slot creation were **not tested**.

```sql
SELECT line_number, error FROM pg_hba_file_rules WHERE error IS NOT NULL;
SELECT pg_reload_conf();
SELECT line_number,type,database,user_name,address,auth_method
FROM pg_hba_file_rules WHERE 'replication'=ANY(database)
  AND 'repl_user'=ANY(user_name)
ORDER BY line_number;
```

**Observed:** line 125 allowed `192.168.136.11`, line 126 allowed `192.168.136.10`, both using `scram-sha-256`. In real production, replace these lab-only `host` allowances with controlled network and `hostssl`/certificate validation as designed with security.

### 3.3 Create the physical replication slot — `as-pg1`

```sql
SELECT slot_name, slot_type, active FROM pg_replication_slots;

-- Execute once, only if absent:
SELECT * FROM pg_create_physical_replication_slot('as_pg2_slot');

SELECT slot_name,slot_type,active,restart_lsn,wal_status,safe_wal_size
FROM pg_replication_slots WHERE slot_name='as_pg2_slot';
```

**Observed immediately after creation:** slot `physical`, `active=f`, `restart_lsn=NULL`, `wal_status=NULL`, and `safe_wal_size=1064935816` bytes. A numerical `safe_wal_size` with a NULL `restart_lsn` is possible: this is headroom, **not WAL already stored**. We intentionally did not immediately reserve WAL before standby creation.

The slot was created **on the primary** and is used by the standby; do not create the same slot independently on the standby at this stage.

### 3.4 Prepare unattended credentials — `as-pg2`

Create a password file owned by `postgres` and mode 0600:

```bash
umask 077
touch ~/.pgpass
chmod 600 ~/.pgpass
vi ~/.pgpass
```

**Format (illustrative only; do not commit real contents):**

```text
as-pg1:5432:replication:repl_user:<STRONG_SECRET_NOT_IN_GITHUB>
```

The `replication` field matches a physical replication protocol connection. Password-file matching uses the **first matching line**; special characters `:` and `\` in password values require appropriate escaping. Do not print secrets into shell history, documentation or logs. For production, use a compliant secret-distribution solution and validated TLS.

Test with **no password prompt**:

```bash
env -u PGPASSWORD PGPASSFILE=/var/lib/pgsql/.pgpass \
  /usr/pgsql-18/bin/psql -X -w \
  "host=as-pg1 port=5432 dbname=replication user=repl_user replication=true" \
  -c 'IDENTIFY_SYSTEM;'
```

**Verified after correcting the secret:**

```text
systemid              timeline    xlogpos
7709811654404845603  1           0/1865E78
```

### 3.5 Build standby using `pg_basebackup` — `as-pg2`

**Safety preconditions:** PostgreSQL not running on `as-pg2`, PGDATA *empty*, directory owned by `postgres`, enough disk capacity, `/u01/18/log` writable. **Do not wipe an existing cluster to satisfy this step.**

```bash
/usr/pgsql-18/bin/pg_ctl -D /u01/18/data status
ls -la /u01/18/data
df -hT /u01/18/data

/usr/pgsql-18/bin/pg_basebackup \
  -h as-pg1 -p 5432 -U repl_user \
  -D /u01/18/data \
  -Fp -Xs -S as_pg2_slot -R -P -v --no-password
```

| Flag | Purpose |
|---|---|
| `-Fp` | Plain directory backup |
| `-Xs` | Stream required WAL during backup |
| `-S as_pg2_slot` | Use the existing persistent physical slot |
| `-R` | Create `standby.signal` and record `primary_conninfo` + `primary_slot_name` |
| `-P -v` | Progress and verbose logging |
| `--no-password` | Do not prompt; use configured passfile |

Do **not** specify `-C` because `as_pg2_slot` already exists. The output included the successful WAL copy and final backup manifest rename:

```text
pg_basebackup: write-ahead log start point: 0/2000028 on timeline 1
pg_basebackup: starting background WAL receiver
24140/24140 kB (100%), 1/1 tablespace
pg_basebackup: write-ahead log end point: 0/2000120
pg_basebackup: base backup completed
```

After backup, **observed on `as-pg2`**:

```text
/u01/18/data/standby.signal           exists
primary_slot_name                    as_pg2_slot
Database system identifier          7709811654404845603
Data page checksum version          1
```

Do not publish `primary_conninfo` unredacted if it contains credentials.

### 3.6 Start standby and verify streaming — `as-pg2`, then `as-pg1`

On `as-pg2`, as `postgres`:

```bash
/usr/pgsql-18/bin/pg_ctl -D /u01/18/data \
  -l /u01/18/log/startup.log -w start
```

```sql
-- as-pg2
SELECT pg_is_in_recovery() AS is_standby,
       pg_last_wal_receive_lsn() AS received_lsn,
       pg_last_wal_replay_lsn() AS replayed_lsn;
SELECT status, slot_name, sender_host, sender_port, latest_end_lsn
FROM pg_stat_wal_receiver;
```

**Observed:**

```text
is_standby=t, received_lsn=0/3000060, replayed_lsn=0/3000060
status=streaming, slot_name=as_pg2_slot, sender_host=as-pg1, sender_port=5432
```

On `as-pg1`:

```sql
SELECT slot_name,active,restart_lsn,wal_status,safe_wal_size
FROM pg_replication_slots WHERE slot_name='as_pg2_slot';
SELECT application_name,client_addr,state,sync_state,
       sent_lsn,write_lsn,flush_lsn,replay_lsn,
       write_lag,flush_lag,replay_lag
FROM pg_stat_replication;
```

**Observed:** the physical slot became `active=t`, `wal_status=reserved`. The replication sender reported:

```text
application_name = walreceiver
client_addr      = 192.168.136.11
state            = streaming
sync_state       = async
sent_lsn         = 0/3027080
write_lsn        = 0/3027080
flush_lsn        = 0/3027080
replay_lsn       = 0/3027080
write_lag        = 00:00:00.001239
flush_lag        = 00:00:00.002339
replay_lag       = 00:00:00.002344
```

**Interpretation:** All WAL pipeline positions matched at that observation. `async` remains important: the primary can acknowledge a commit before the standby has replayed (or even received) it.

---

## 4. Functional replication and monitoring tests

### Test 1 — Application data reaches standby

Run on `as-pg1` (database `postgres`):

```sql
CREATE TABLE public.ha_replication_test (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    created_at TIMESTAMPTZ DEFAULT now(),
    note TEXT NOT NULL
);
INSERT INTO public.ha_replication_test (note)
VALUES ('Inserted on as-pg1') RETURNING *;
```

Run on `as-pg2`:

```sql
SELECT pg_is_in_recovery() AS is_standby, id, created_at, note
FROM public.ha_replication_test ORDER BY id DESC LIMIT 5;
```

**Observed:**

```text
is_standby | id | created_at                    | note
t          | 1  | 2026-11-19 10:39:30.537821+00 | Inserted on as-pg1
```

This is a functional replication check, not merely confirmation of an open network connection.

### Test 2 — Check WAL retention on a healthy slot (`as-pg1`)

```sql
SELECT slot_name, active, restart_lsn, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(),restart_lsn)::bigint)
          AS wal_distance,
       pg_size_pretty(safe_wal_size) AS safe_wal_headroom,
       invalidation_reason
FROM pg_replication_slots WHERE slot_name='as_pg2_slot';
```

**Observed healthy baseline:**

```text
slot_name=as_pg2_slot    active=t    restart_lsn=0/30271C0
wal_status=reserved     wal_distance=0 bytes    safe_wal_headroom=1040 MB
invalidation_reason=NULL
```

`wal_distance` is an approximate LSN difference, **not** the amount of disk occupied by segment files in `pg_wal`. `safe_wal_headroom` is a WAL-generation safety estimate, **not filesystem free space**. The slot limit is considered at checkpoints; even with a nominal 1 GB limit, observed safe headroom can be around 1040 MB because of PostgreSQL's WAL/checkpoint accounting.

### Test 3 — Byte lag across replication pipeline (`as-pg1`)

```sql
SELECT application_name, client_addr, state, sync_state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(),sent_lsn)::bigint)
           AS unsent_wal,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn,write_lsn)::bigint)
           AS sent_not_written,
       pg_size_pretty(pg_wal_lsn_diff(write_lsn,flush_lsn)::bigint)
           AS written_not_flushed,
       pg_size_pretty(pg_wal_lsn_diff(flush_lsn,replay_lsn)::bigint)
           AS flushed_not_replayed,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(),replay_lsn)::bigint)
           AS total_replay_gap
FROM pg_stat_replication;
```

**Observed:**

```text
application_name=walreceiver, client_addr=192.168.136.11
state=streaming, sync_state=async
unsent_wal=0 bytes
sent_not_written=0 bytes
written_not_flushed=0 bytes
flushed_not_replayed=0 bytes
total_replay_gap=0 bytes
```

Five zero measurements describe **one observation**, not a zero-data-loss guarantee. A disconnection can also cause `pg_stat_replication` to have no row at all; never mistake that for zero lag.

### Test 4 — Controlled standby outage (lab only)

On `as-pg2` (Linux `postgres`):

```bash
/usr/pgsql-18/bin/pg_ctl -D /u01/18/data -m fast -w stop
/usr/pgsql-18/bin/pg_ctl -D /u01/18/data status
```

On `as-pg1`:

```sql
SELECT slot_name,active,restart_lsn,wal_status,
       pg_size_pretty(safe_wal_size) AS safe_wal_headroom
FROM pg_replication_slots WHERE slot_name='as_pg2_slot';
SELECT application_name,client_addr,state FROM pg_stat_replication;
```

**Observed while `as-pg2` stopped:**

```text
active=f, restart_lsn=0/30271C0, wal_status=reserved
safe_wal_headroom=1040 MB
pg_stat_replication: 0 rows
```

**Meaning:** The physical slot persisted after the consumer disconnected and continued to describe required WAL. This was a clean PostgreSQL stop, **not** a primary crash/failover test.

### Test 5 — Generate modest WAL while standby offline

On `as-pg1`, after confirming sufficient disk headroom and while `as-pg2` was still stopped:

```sql
CREATE TABLE public.ha_slot_wal_test AS
SELECT g AS id, repeat(md5(g::text),32) AS payload
FROM generate_series(1,10000) AS g;
SELECT count(*) FROM public.ha_slot_wal_test;
```

This deliberately created only a small test dataset. The exact data size is not the same as generated WAL volume. **Do not repeatedly run the CREATE TABLE or stress the 1 GB slot limit on production.**

The primary slot was queried again using the WAL-distance SQL from Test 2.

**Observed:**

```text
slot_name=as_pg2_slot, active=f, restart_lsn=0/30271C0
wal_status=reserved, wal_distance=11 MB
safe_wal_headroom=1029 MB
```

The inactive slot kept its `restart_lsn` while the primary advanced, and headroom decreased from `1040 MB` to `1029 MB`. This demonstrates why abandoned or lagging slots require monitoring.

### Test 6 — Restart standby and catch up

On `as-pg2`:

```bash
/usr/pgsql-18/bin/pg_ctl -D /u01/18/data \
  -l /u01/18/log/startup.log -w start
```

```sql
SELECT pg_is_in_recovery() AS is_standby,
       pg_last_wal_receive_lsn() AS received_lsn,
       pg_last_wal_replay_lsn() AS replayed_lsn;
SELECT status,slot_name,sender_host FROM pg_stat_wal_receiver;
SELECT count(*) AS replicated_rows FROM public.ha_slot_wal_test;
```

**Observed:**

```text
is_standby=t, received_lsn=0/3ADBB38, replayed_lsn=0/3ADBB38
status=streaming, slot_name=as_pg2_slot, sender_host=as-pg1
replicated_rows=10000
```

On `as-pg1`, final slot verification:

```text
slot_name=as_pg2_slot
active=t
restart_lsn=0/3ADBB38
wal_status=reserved
wal_distance=0 bytes
safe_wal_headroom=1029 MB
```

**Result: PASS.** The standby resumed streaming and applied all changes generated during the controlled outage, with no new base backup required. This is a **standby recovery** test, not a primary-failover or zero-RPO test.

---

## 5. Troubleshooting recorded during implementation

### `pg_basebackup: FATAL: password authentication failed for user repl_user`

**Meaning:** Server connection reached `as-pg1`, a password was found, but the server rejected it. The failure message named `/var/lib/pgsql/.pgpass`. Check the secret and avoid switching authentication to `trust`.

### `psql: fe_sendauth: no password supplied`

**Meaning:** The connection requested no password prompt (`-w`) but no usable matching entry was found in the configured passfile. We verified file mode `0600` and inspected only nonsecret fields without printing the password:

```bash
awk -F: '{printf "line=%d host=%s port=%s database=%s user=%s fields=%d\n", NR,$1,$2,$3,$4,NF}' \
  /var/lib/pgsql/.pgpass
```

Note: that `awk -F:` inspection is only safe for the five-field format when the password does not include escaped colons; do not paste real passfile contents into tickets or chats.

This explicit connection string helped distinguish passfile matching from password validity:

```bash
env -u PGPASSWORD PGPASSFILE=/var/lib/pgsql/.pgpass \
  /usr/pgsql-18/bin/psql -X -w \
  'host=as-pg1 port=5432 dbname=replication user=repl_user replication=true' \
  -c 'IDENTIFY_SYSTEM;'
```

With a matching passfile entry, the remaining authentication failure was resolved by correcting the password. The working standby bootstrap followed.

**Safer manual password test** (does not read `.pgpass`):

```bash
env -u PGPASSWORD PGPASSFILE=/dev/null \
  /usr/pgsql-18/bin/psql -X -W \
  'host=as-pg1 port=5432 dbname=replication user=repl_user replication=true' \
  -c 'IDENTIFY_SYSTEM;'
```

If password reset is required, run `\password repl_user` inside a privileged `psql` session on `as-pg1`, update the protected secret on `as-pg2`, and retest. Never publish real credentials.

### How to check problems without root

As `postgres` on the relevant server:

```bash
/usr/pgsql-18/bin/pg_ctl -D /u01/18/data status
ls -lhtr /u01/18/log/
df -hT /u01/18/data
du -sh /u01/18/data/pg_wal
```

In `psql`, use the SQL from [`../sql/replication_monitoring.sql`](../sql/replication_monitoring.sql). If no standby row appears in `pg_stat_replication`, investigate receiver startup, database logs, authentication, DNS/routing, firewall and slot validity. Do not change PGDATA or promote a node without a documented plan.

---

## 6. Operations and production handover

### Daily DBA checks

1. Confirm `pg_is_in_recovery()` roles on both machines — one primary, one standby.
2. On primary, ensure `pg_stat_replication.state='streaming'` and inspect byte gaps; note `sync_state='async'`.
3. On standby, ensure `pg_stat_wal_receiver.status='streaming'` and check receive/replay LSNs.
4. Inspect slot `active`, `wal_status`, `safe_wal_size`, `restart_lsn`, `invalidation_reason` on primary.
5. Monitor filesystem free space **and** `pg_wal` physical usage, plus database/log storage and retention.
6. Verify backup jobs and **actual restore tests** once backup infrastructure exists; they were not completed here.

### Lab start/stop commands

The currently tested lifecycle on each database host as Linux `postgres` is:

```bash
# status
/usr/pgsql-18/bin/pg_ctl -D /u01/18/data status
# clean controlled stop
/usr/pgsql-18/bin/pg_ctl -D /u01/18/data -m fast -w stop
# start
/usr/pgsql-18/bin/pg_ctl -D /u01/18/data -l /u01/18/log/startup.log -w start
```

For normal planned lab shutdown, stop standby before primary; start primary before standby. **Do not run the above `pg_ctl` commands against a systemd-managed production instance unless your runbook explicitly calls for them.** The Linux/Platform team owns privileged service configuration and restart-on-boot behavior.

### Hardening items NOT completed (must not be represented as implemented)

| Area | Required for real production |
|---|---|
| Automatic failover | External trusted decision-maker, fencing, promotion policy and tested recovery; **not provided by native streaming alone** |
| Availability | Two DB nodes + manual promotion do not meet an automatically managed HA RTO |
| RPO | `async` replication can lose acknowledged commits on sudden primary failure; evaluate synchronous replication trade-offs |
| Backup/restore | pgBackRest or equivalent, WAL archiving, off-host repositories, validated PITR and restore drills |
| Database service | Linux/SRE-managed systemd with custom PGDATA and reboot behavior |
| Security | Network ACLs, SELinux, firewall, TLS/`hostssl`, certificates, managed secrets, audit and least privilege |
| Storage | Validated mounts/capacity, IOPS/latency sizing, WAL burst headroom, disk alerts |
| Logs | Centralized collection, retention/purge, sensitive-data access control and alerts |
| Monitoring | Automated metrics/alert thresholds for lag, inactive/invalid slots, WAL rate, disk and backup freshness |
| Slot capacity | Replace lab `1GB` WAL cap with retention sized to WAL generation rate and operational recovery window |
| Promoted primary rejoin | Dedicated new slot on new primary, connection updates and carefully tested `pg_rewind`/reseed runbook |

**End-of-project statement:** Native PostgreSQL 18 primary/standby streaming replication and physical slot monitoring were successfully configured and tested. All commands, outcomes and caveats above reflect the actual lab checkpoints. HAProxy and Keepalived were explored separately but are **not** part of this completed database-replication GitHub deliverable.

---

## 7. Official documentation

- [PGDG installation on Red Hat family](https://www.postgresql.org/download/linux/redhat/)
- [PostgreSQL 18 — initdb](https://www.postgresql.org/docs/18/app-initdb.html)
- [PostgreSQL 18 — pg_basebackup](https://www.postgresql.org/docs/18/app-pgbasebackup.html)
- [PostgreSQL 18 — Replication settings](https://www.postgresql.org/docs/18/runtime-config-replication.html)
- [PostgreSQL 18 — Replication slots view](https://www.postgresql.org/docs/18/view-pg-replication-slots.html)
- [PostgreSQL 18 — Monitoring statistics](https://www.postgresql.org/docs/18/monitoring-stats.html)
- [PostgreSQL 18 — Logging](https://www.postgresql.org/docs/18/runtime-config-logging.html)
- [PostgreSQL 18 — Password file](https://www.postgresql.org/docs/18/libpq-pgpass.html)
- [PostgreSQL 18 — Streaming replication protocol](https://www.postgresql.org/docs/18/protocol-replication.html)
- [PostgreSQL 18 — pg_rewind (future exercise)](https://www.postgresql.org/docs/18/app-pgrewind.html)
