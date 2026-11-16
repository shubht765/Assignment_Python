# Material Master (MATMAS) – config-driven ingestion
### Informatica CDI taskflow (cloud) · File Ingestion to OneLake · SQL database in Fabric

Status: design v1.1 (16-Nov-2026). This replaces the earlier versions. Build steps are in `cdi/CDI_Build_Guide.md`.

---

## 1. Requirements as agreed

1. **One generic pipeline.** Locations, agents, target tables and operations live in a config table. No pipeline per ERP.
2. **Files land on different Secure Agents.** JDE lands on one agent, Vision on another, SAP on a third.
3. **No 90 listeners.** One file ingestion task, driven row by row from the table, moves each file to **OneLake**. Everything after that is orchestrated centrally.
4. **The taskflow runs in the IDMC cloud.**
5. **Input files have 6 fields**: ERP Item Number, Material Description, Plant Code, Supplier Part#, Supplier Number, Manufacturing Part#. **The mapping adds Start Date and End Date.**
6. **A straight mapping** of the 6 fields to the target, into **one table per ERP** under schema `matmas`: `jde_material_master`, `vision_material_master`, `sap_material_master`, and so on.
7. **The operation per route comes from config**: insert, upsert, update, delete, or truncate-and-insert.

---

## 2. Flow (real names)

| Item | Value |
|---|---|
| Lakehouse / folders | `lh_p2o_intg_dev` → `Files/erp_to_matmas/landing/<ERP>`, `archive/<ERP>`, `duplicate/<ERP>`, `error/<ERP>` |
| OneLake connection | `FABRIC.AMCOR.ONELAKE.P2O` (Microsoft Fabric OneLake, workspace `ws_p2o_intg_dev`) |
| SQL connection | `jdbcv2.MSSQL.sqldb-p2o-intg.stg` |

```
tf_P2O_100_MATMAS_Orchestrator  (IDMC cloud, scheduled) - loop over cfg.matmas_route_config
 1 READ     mt_P2O_101_MATMAS_Route_Reader   config row N -> taskflow fields
 2 COLLECT  fi_P2O_100_MATMAS_Agent_to_OneLake runs ON THE ROW'S AGENT (runtime env overridden)
            agent folder/pattern -> erp_to_matmas/landing/<ERP>/<RUN_ID>, then deletes the agent file (0 files -> NO_FILE)
 3 LOAD     mt_P2O_102_MATMAS_Load           landing/<ERP>/<RUN_ID> -> 6 fields + START/END_DATE -> stage
            Post SQL matmas.sp_apply_stage    -> matmas.<erp>_material_master with the row's operation
 4 OUTCOME  mt_P2O_103_MATMAS_Outcome        ARCHIVE | DUPLICATE | ERROR
   MOVE     fi_P2O_101_MATMAS_OneLake_Move   landing/<ERP>/<RUN_ID> -> archive|duplicate|error/<ERP>/<RUN_ID>
 7 LOG      every step                        matmas.run_log
```

**Why it works across agents**: the Ingestion Task step can override the **runtime environment**, connections, directories and file pattern, so collect runs on whichever agent the row names. The mapping tasks never need to switch agents because everything they read is in OneLake.

## 3. Database objects

Naming follows the database standard (as in `cfg.erp_file_config`): all schema, table, view, column, constraint and procedure names are lower case with underscores, flags are `bit`, and config tables live in schema `cfg`.

| Object | Purpose |
|---|---|
| `cfg.matmas_setting` | Org-wide values: OneLake connection `FABRIC.AMCOR.ONELAKE.P2O`, lakehouse root `.../erp_to_matmas` |
| `cfg.matmas_route_config` | **The config table.** One row per source location. |
| `matmas.run_log` | Append-only events: STARTED, NO_FILE, COLLECT_FAILED, LOADED, DUPLICATE_FILE, APPLY_FAILED, LOAD_FAILED, ARCHIVE_FAILED |
| `matmas.material_master_stage` | What the load mapping writes: 6 fields plus start_date and end_date, with run, route and file |
| `matmas.material_master_reject` | Rows missing a key column or too long for the target |
| `matmas.file_history` | SHA-256 fingerprint of every applied file, so a re-collected file is not loaded twice |
| `matmas.jde_material_master`, `matmas.vision_material_master`, `matmas.sap_material_master` | **ERP target tables**, identical template: 6 fields, start_date, end_date, source file, run id, created and updated |
| `matmas.v_route_reader`, `matmas.v_run_status`, `matmas.v_run_outcome` | Active routes with computed OneLake folders, the last event per run and route, and the archive, duplicate or error decision |
| `stg.matmas_route_reader`, `stg.matmas_run_log`, `stg.matmas_stage_file`, `stg.matmas_run_outcome`, `stg.matmas_one_row` | CDI interface views in the JDBC connection's default schema |
| `matmas.sp_apply_stage`, `matmas.sp_apply_route`, `matmas.sp_reapply_run`, `matmas.sp_create_erp_table`, `matmas.sp_log_event` | Apply, retry, onboarding and logging |

### Config table columns

| Group | Columns |
|---|---|
| Identity | `route_id`, `erp_system`, `route_name`, `run_group`, `run_order`, `active_flag` (bit) |
| Collect | `runtime_environment`, `source_connection`, `source_directory`, `file_pattern`, `onelake_folder` (JDE / Vision / ...) |
| Load | `target_schema`, `target_table`, `load_operation`, `key_columns`, `start_date_value`, `end_date_value`, `skip_duplicate_file` (bit) |
| Other | `notify_email`, audit columns |

No credentials are stored in the table. Accounts live in IDMC connections, and the table only names them.

---

## 4. Sample data through the pipeline

The JDE file has 6 fields and contains the same row twice:

| ERP Item Number | Material Description | Plant Code | Supplier Part# | Supplier Number | Manufacturing Part# |
|---|---|---|---|---|---|
| 109589 | SEN,PROXIMITY,29MM,12-24VDC | AUR | 4462658 (Primary) | 456526 | 4462658 (Fallback) |
| 109589 | SEN,PROXIMITY,29MM,12-24VDC | AUR | 4462658 (Primary) | 456526 | 4462658 (Fallback) |

Result in `matmas.jde_material_master` with operation UPSERT. The duplicate collapses, and the mapping adds the dates:

| ERP_ITEM_NUMBER | MATERIAL_DESCRIPTION | PLANT_CODE | SUPPLIER_PART_NUMBER | SUPPLIER_NUMBER | MANUFACTURING_PART_NUMBER | START_DATE | END_DATE |
|---|---|---|---|---|---|---|---|
| 109589 | SEN,PROXIMITY,29MM,12-24VDC | AUR | 4462658 (Primary) | 456526 | 4462658 (Fallback) | 2026-11-16 | 9999-12-31 |

What happens on later runs:
- **Same file again.** It is skipped as DUPLICATE_FILE.
- **File with a changed description.** The row is updated, and START_DATE stays 2026-11-16.
- **New supplier part.** A new row is inserted.

---

## 5. Decisions and limits

- **The file contract** is pipe delimited, a header row, UTF-8, 6 columns in this order. The JDE descriptions contain commas, so a comma delimiter would need quoting.
- **The default key** is item, plant, supplier and supplier part. It can be changed per route in `KEY_COLUMNS`.
- **A failed load** does not archive the source file, so the next run retries it. The fingerprint prevents a double load if the load succeeded but archiving failed.
- **Parallelism.** Routes run one after another inside a run group. Use several run groups with their own schedules for parallel processing.
- **Operation "search".** This is not defined yet. Tell me the intended behaviour and it becomes one more value of `LOAD_OPERATION`.

## 6. To confirm in your org

1. File Ingestion and Replication is enabled.
2. Overriding the runtime environment works with your local folder connection. Test once with two agents.
3. Every source agent can write to OneLake.
4. The OneLake connector supports reading a whole directory with a directory override in the load mapping.
5. The path format of the `onelake_root` setting matches the Target Directory of `fi_P2O_000_BPDWFS_PO_to_OneLake`.
6. File Ingestion accepts OneLake as a **source** for the move from landing to archive. Check whether it can delete source files after transfer. If not, schedule `fabric/nb_matmas_purge_landing.py`.
