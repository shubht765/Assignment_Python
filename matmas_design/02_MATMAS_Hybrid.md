# MATMAS – hybrid process (IDMC collects, Fabric notebook loads)

Status: v2.0 (17-Nov-2026). Replaces the all-IDMC flow (`tf_P2O_100_MATMAS_Orchestrator`) for loading.
The SQL objects (`sql/01`–`03`) are unchanged.

## 1. Flow

```
IDMC  tf_P2O_110_MATMAS_Collect  (scheduled)        loop over cfg.matmas_route_config, row by row
        mt_P2O_101_MATMAS_Route_Reader              row N -> agent group, source folder, pattern, OneLake folder   (log STARTED)
        fi_P2O_100_MATMAS_Agent_to_OneLake          source -> OneLake landing/<ERP>/<RUN_ID>/, deleted at the source
        Files found?  0 -> mt_P2O_104 NO_FILE  |  otherwise -> mt_P2O_104 COLLECTED
        (nothing else: no load, no archive)

Fabric  nb_matmas_process  (scheduled, every 15 min)   lh_p2o_intg_dev/Files/erp_to_matmas
        sweep landing/<ERP>/<RUN_ID>/  ->  wait for COLLECTED + files stable
        read 6 fields, add start_date / end_date  ->  matmas.material_master_stage   (bad field count -> material_master_reject)
        EXEC matmas.sp_apply_route  ->  matmas.<erp>_material_master   (LOADED / DUPLICATE_FILE / APPLY_FAILED)
        matmas.v_run_outcome  ->  move to archive | duplicate | error/<ERP>/<RUN_ID>/   (log OUTCOME)
```

One `run_id` carries the whole trail in `matmas.run_log`:
`STARTED → COLLECTED` (IDMC) `→ LOADED → OUTCOME` (notebook).

## 2. Objects

| Where | Object | Role |
|---|---|---|
| IDMC | `tf_P2O_110_MATMAS_Collect` | New taskflow: read row, collect, log. No load steps. |
| IDMC | `fi_P2O_100_MATMAS_Agent_to_OneLake` | Collect. The taskflow overrides runtime environment, source directory, pattern and OneLake target per route. |
| IDMC | `mt_P2O_101_MATMAS_Route_Reader`, `mt_P2O_104_MATMAS_Log` | Read the config row (logs STARTED). Write COLLECTED / NO_FILE. |
| Fabric | `nb_matmas_process` | Load, apply, audit, archive. Python kernel, default lakehouse `lh_p2o_intg_dev`, connection `connect_to_artifact('sqldb-p2o-intg-dev')`, the same pattern as `ingest_external_files` and `po_transform`. |
| SQL | `cfg.matmas_route_config`, `cfg.matmas_setting` | Config, unchanged. |
| SQL | `matmas.run_log`, `material_master_stage`, `material_master_reject`, `file_history`, ERP tables, `sp_apply_route`, `sp_reapply_run`, `sp_log_event`, `v_run_outcome`, `v_run_status` | Audit and apply, unchanged. |

No longer used, delete after the new flow is tested: `tf_P2O_100_MATMAS_Orchestrator`,
`m_/mt_P2O_102_MATMAS_Load`, `m_/mt_P2O_103_MATMAS_Outcome`, `fi_P2O_101_MATMAS_OneLake_Move`,
and the views `stg.matmas_stage_file`, `stg.matmas_run_outcome` (harmless if kept).

## 3. Notebook behaviour (same rules as the IDMC version)

| Situation | What happens | Event(s) | Files go to |
|---|---|---|---|
| Normal file | Staged, applied with the route's operation | LOADED, OUTCOME | `archive/<ERP>/<RUN_ID>/` |
| Same content loaded before | Skipped by the fingerprint in `matmas.file_history` | DUPLICATE_FILE, LOADED, OUTCOME | `duplicate/…` |
| Row with missing key / too long | `matmas.material_master_reject` (procedure) | LOADED (rows_rejected), OUTCOME | `archive/…` |
| Row with the wrong field count | `matmas.material_master_reject` (notebook) | OUTCOME mentions the count | `archive/…` |
| Empty file / header not 6 columns | Whole run folder fails | LOAD_FAILED, OUTCOME | `error/…` |
| Config error (missing table, bad keys) | Staged rows kept as FAILED | APPLY_FAILED, OUTCOME | `error/…` |
| Connection / timeout | Retried on the next sweep, up to `MAX_LOAD_ATTEMPTS` (5) | LOAD_RETRY (then LOAD_FAILED) | stays in `landing/` (then `error/`) |
| IDMC still copying | Waits for COLLECTED (or `COLLECTED_WAIT_MINUTES` = 60) | – | stays in `landing/` |
| File still being written | Waits until unchanged (`quiet_seconds`, `recheck_seconds`) | – | stays in `landing/` |
| Fixed and reapplied (`EXEC matmas.sp_reapply_run`) | Next sweep moves the run folder | OUTCOME (after reapply) | `error/` → `archive/` |
| File dropped by hand into `landing/<ERP>/` | Gets its own run id `NB<timestamp>`, no COLLECTED needed | as above | as above |

Only one run per route at a time (`sp_getapplock`), like the lanes in `ingest_external_files`.
`dry_run = True` parses and prints without writing or moving.

## 4. Set-up

1. **SQL**: nothing new. `sql/01`–`03` as installed.
2. **IDMC**: Data Integration → Explore → Import `cdi/import/MATMAS_CDI_Collect_Only.zip` into `zPF_TCS_Shubham`.
   Existing objects (`mt_P2O_101`, `mt_P2O_104`, `fi_P2O_100`) show as *exists*: overwrite. New: `tf_P2O_110_MATMAS_Collect`.
   Validate, publish, schedule (e.g. daily, input `RUN_GROUP = DAILY`).
3. **Fabric**: workspace `ws_p2o_intg_dev` → Import → Notebook → `fabric/nb_matmas_process.ipynb`.
   Check the default lakehouse is `lh_p2o_intg_dev` and the kernel is Python. Run once with `dry_run = True`.
4. **Schedule the notebook**: notebook → Run → Schedule, every 15 minutes (or a pipeline with one Notebook
   activity if you want alerts on failure). Overlapping runs are safe (lane lock), but keep it single-flight
   like `ingest_external_files`.
5. **Lakehouse folders**: `Files/erp_to_matmas/{landing,archive,duplicate,error}/{JDE,Vision}` (already there).

## 5. Test

| Step | Do | Check |
|---|---|---|
| 1 | Drop `samples/JDE/JDE_MATMAS_20261116.txt` straight into `Files/erp_to_matmas/landing/JDE/` and run the notebook | Output shows `NB…: … outcome ARCHIVE`. `SELECT * FROM matmas.v_run_status ORDER BY log_ts DESC;` → OUTCOME. `SELECT * FROM matmas.jde_material_master;` → 1 row, start_date today, end_date 9999-12-31. File in `archive/JDE/NB…/`. |
| 2 | Drop the same file again, run | Outcome DUPLICATE, file in `duplicate/JDE/NB…/` |
| 3 | Drop a file whose header has only 3 columns, run | LOAD_FAILED, file in `error/JDE/NB…/` |
| 4 | Put the sample in the JDE agent folder, run `tf_P2O_110_MATMAS_Collect` | Agent folder empty, file in `landing/JDE/<RUN_ID>/`, `run_log`: STARTED, COLLECTED. Vision: STARTED, NO_FILE. |
| 5 | Run the notebook (or wait for its schedule) | Same run id: LOADED, OUTCOME. File in `archive/JDE/<RUN_ID>/`. |

```sql
SELECT * FROM matmas.run_log ORDER BY log_id DESC;          -- full trail
SELECT * FROM matmas.v_run_status ORDER BY log_ts DESC;     -- last event per run and route
SELECT * FROM matmas.material_master_reject ORDER BY reject_id DESC;
```

## 6. When the source changes to a share path or SFTP (pending: locations to be provided)

The collect step currently reads a **local folder on the Secure Agent** (`D:\Interfaces\...`). Once the share / SFTP
locations are known, these are the only places that change. The notebook, the SQL procedures and the audit stay as they are.

| # | Where | Share path (UNC, e.g. `\\server\share\MATMAS\JDE`) | SFTP |
|---|---|---|---|
| 1 | `cfg.matmas_route_config` (per route) | `source_directory` = the UNC path; `runtime_environment` = an agent group whose service account can read/delete on the share; `file_pattern` | `source_directory` = remote folder (e.g. `/outbound/matmas`); `source_connection` = the SFTP connection name; `runtime_environment` = an agent group that can reach the SFTP host |
| 2 | IDMC connection | None needed: `fi_P2O_100` keeps its **Local folder** source; a UNC path works as the directory when the Secure Agent service runs as a domain account with access | New **Advanced SFTP V2** connection per SFTP server (host, port, user, key/password) |
| 3 | `fi_P2O_100_MATMAS_Agent_to_OneLake` | No change | Source type of a file ingestion task is fixed per task: create `fi_P2O_102_MATMAS_SFTP_to_OneLake` (source = the SFTP connection, target = OneLake, delete after transfer) |
| 4 | `tf_P2O_110_MATMAS_Collect` | No change | Add a `source_type` column (`LOCAL` / `SFTP`) to the config and the reader, and a decision before collect: `LOCAL` → `IT_Collect` (fi_P2O_100), `SFTP` → `IT_Collect_SFTP` (fi_P2O_102). Same overrides (runtime environment, source directory, pattern, OneLake target). |
| 5 | Notebook | No change | No change |

Send the locations (path or host + folder per ERP, which agent group can reach each, and whether files are deleted
or archived at the source) and the generator / config will be updated accordingly.
