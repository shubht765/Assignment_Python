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
6. **A straight mapping** of the 6 fields to the target, into **one table per ERP** under schema `MATMAS`: `JDE_MATERIAL_MASTER`, `VISION_MATERIAL_MASTER`, `SAP_MATERIAL_MASTER`, and so on.
7. **The operation per route comes from config**: insert, upsert, update, delete, or truncate-and-insert.

---

## 2. Flow (real names)

| Item | Value |
|---|---|
| Lakehouse / folders | `lh_p2o_intg_dev` → `Files/erp_to_matmas/landing/<ERP>`, `archive/<ERP>`, `duplicate/<ERP>`, `error/<ERP>` |
| OneLake connection | `FABRIC.AMCOR.ONELAKE.P2O` (Microsoft Fabric OneLake, workspace `ws_p2o_intg_dev`) |
| SQL connection | `jdbcv2.MSSQL.sqldb-p2o-intg.stg` |

```
tf_P2O_100_MATMAS_Orchestrator  (IDMC cloud, scheduled) - loop over MATMAS.CTL_MATMAS_ROUTE
 1 READ     mt_P2O_101_MATMAS_Route_Reader   config row N -> taskflow fields
 2 COLLECT  fi_P2O_100_MATMAS_ERP_to_OneLake runs ON THE ROW'S AGENT (runtime env overridden)
            agent folder/pattern -> erp_to_matmas/landing/<ERP>/<RUN_ID>      (0 files -> NO_FILE, next row)
 3 LOAD     mt_P2O_102_MATMAS_Load           landing/<ERP>/<RUN_ID> -> 6 fields + START/END_DATE -> stage
            Post SQL sp_MATMAS_ApplyStage    -> MATMAS.<ERP>_MATERIAL_MASTER with the row's operation
 4 OUTCOME  mt_P2O_103_MATMAS_Outcome        ARCHIVE | DUPLICATE | ERROR
 5 MOVE     fi_P2O_101_MATMAS_OneLake_Move   landing/<ERP>/<RUN_ID> -> archive|duplicate|error/<ERP>/<RUN_ID>
 6 ARCHIVE  Command Task ON THE ROW'S AGENT  source file -> agent archive folder (only when not ERROR)
 7 LOG      every step                        MATMAS.CTL_MATMAS_RUN_LOG
```

**Why it works across agents**: the Ingestion Task step can override the **runtime environment**, connections, directories and file pattern, and the Command Task step takes its **runtime environment** from a field, so collect and agent-side archive run wherever the row says. The mapping tasks never need to switch agents because everything they read is in OneLake.

## 3. Database objects

| Object | Purpose |
|---|---|
| `MATMAS.CTL_MATMAS_SETTING` | Org-wide values: OneLake connection `FABRIC.AMCOR.ONELAKE.P2O`, lakehouse root `.../erp_to_matmas`, script path |
| `MATMAS.CTL_MATMAS_ROUTE` | **The config table.** One row per source location. |
| `MATMAS.CTL_MATMAS_RUN_LOG` | Append-only events: STARTED, NO_FILE, COLLECT_FAILED, LOADED, DUPLICATE_FILE, APPLY_FAILED, LOAD_FAILED, ARCHIVE_FAILED |
| `MATMAS.MATERIAL_MASTER_STAGE` | What the load mapping writes: 6 fields plus START_DATE and END_DATE, with run, route and file |
| `MATMAS.MATERIAL_MASTER_REJECT` | Rows missing a key column or too long for the target |
| `MATMAS.CTL_MATMAS_FILE_HISTORY` | SHA-256 fingerprint of every applied file, so a re-collected file is not loaded twice |
| `MATMAS.JDE_MATERIAL_MASTER`, `MATMAS.VISION_MATERIAL_MASTER`, `MATMAS.SAP_MATERIAL_MASTER` | **ERP target tables**, identical template: 6 fields, START_DATE, END_DATE, source file, run id, created and updated |
| `MATMAS.V_MATMAS_ROUTE_READER`, `MATMAS.V_MATMAS_RUN_STATUS`, `MATMAS.V_MATMAS_RUN_OUTCOME` | Active routes with computed OneLake folders, the last event per run and route, and the archive, duplicate or error decision |
| `stg.MATMAS_ROUTE_READER`, `stg.MATMAS_RUN_LOG`, `stg.MATMAS_MATERIAL_MASTER_STAGE`, `stg.MATMAS_RUN_OUTCOME`, `stg.MATMAS_ONE_ROW` | CDI interface views in the JDBC connection's default schema |
| `sp_MATMAS_ApplyStage`, `sp_MATMAS_ApplyRoute`, `sp_MATMAS_ReapplyRun`, `sp_MATMAS_CreateErpTable`, `sp_MATMAS_LogEvent` | Apply, retry, onboarding and logging |

### Config table columns

| Group | Columns |
|---|---|
| Identity | `ROUTE_ID`, `ERP_SYSTEM`, `ROUTE_NAME`, `RUN_GROUP`, `RUN_ORDER`, `ACTIVE_FLAG` |
| Collect | `RUNTIME_ENVIRONMENT`, `SOURCE_CONNECTION`, `SOURCE_DIRECTORY`, `FILE_PATTERN`, `SOURCE_ARCHIVE_DIRECTORY`, `ONELAKE_FOLDER` (JDE / Vision / ...) |
| Load | `TARGET_SCHEMA`, `TARGET_TABLE`, `LOAD_OPERATION`, `KEY_COLUMNS`, `START_DATE_VALUE`, `END_DATE_VALUE`, `SKIP_DUPLICATE_FILE` |
| Other | `NOTIFY_EMAIL`, audit columns |

No credentials are stored in the table. Accounts live in IDMC connections, and the table only names them.

---

## 4. Sample data through the pipeline

The JDE file has 6 fields and contains the same row twice:

| ERP Item Number | Material Description | Plant Code | Supplier Part# | Supplier Number | Manufacturing Part# |
|---|---|---|---|---|---|
| 109589 | SEN,PROXIMITY,29MM,12-24VDC | AUR | 4462658 (Primary) | 456526 | 4462658 (Fallback) |
| 109589 | SEN,PROXIMITY,29MM,12-24VDC | AUR | 4462658 (Primary) | 456526 | 4462658 (Fallback) |

Result in `MATMAS.JDE_MATERIAL_MASTER` with operation UPSERT. The duplicate collapses, and the mapping adds the dates:

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
5. The path format of `ONELAKE_ROOT` matches the Target Directory of `fi_P2O_000_BPDWFS_PO_to_OneLake`.
6. File Ingestion accepts OneLake as a **source** for the move from landing to archive. Check whether it can delete source files after transfer. If not, schedule `fabric/nb_matmas_purge_landing.py`.
