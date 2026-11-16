# MATMAS – CDI process, step by step

> **Update v1.3: import the package instead of building by hand.** Import `cdi/import/MATMAS_CDI_Import.zip` and follow `cdi/IMPORT_README.md`. The current flow is: read the row, then `fi_P2O_100` copies agent files to OneLake and deletes them on the agent, then the load mapping reads the OneLake run folder, then the outcome is decided, then `fi_P2O_101` moves the run folder to archive, duplicate or error.
> There are no command tasks, no agent scripts and no local folder connections. Where this guide mentions `CT_ArchiveSource`, `SOURCE_ARCHIVE_DIRECTORY`, the work folder or the purge notebook, that part no longer applies. The rest stays valid as a reference.
> **Update v1.7: lower-case SQL names.** Database objects and columns follow the lower-case standard (`cfg.matmas_route_config`, `matmas.run_log`, `stg.matmas_stage_file`, column `erp_item_number`, ...). Where this guide still shows a column in upper case, use the lower-case name from `sql/01_tables.sql`. Mapping in-out parameters (`$$RUN_ID`, `$$ROUTE_ID`, ...) stay upper case.


Built for the values seen in the org:

| Item | Value |
|---|---|
| Fabric workspace | `ws_p2o_intg_dev` |
| Lakehouse | `lh_p2o_intg_dev` |
| OneLake folders | `Files/erp_to_matmas/landing/{JDE, Vision}`, `archive`, `duplicate`, `error` |
| OneLake connection | `FABRIC.AMCOR.ONELAKE.P2O`, type Microsoft Fabric OneLake |
| SQL connection | `jdbcv2.MSSQL.sqldb-p2o-intg.stg`, JDBC V2, default schema `stg` |
| Template to copy | `fi_P2O_000_BPDWFS_PO_to_OneLake`, an existing file ingestion task targeting OneLake |
| Project / naming | `P2O` prefix as in the org. The numbers `100`–`104` are placeholders, so use your next free numbers. |

---

## 1. The process in one picture

```
tf_P2O_100_MATMAS_Orchestrator   (scheduled, runs in IDMC cloud)
│
├─ Init                RUN_ID = yyyyMMddHHmmss (UTC), ROW_ID = 0
├─ NextRow  ◄──────────────────────────────────────────────────────────────┐
├─ DT_ReadRoute        mt_P2O_101_MATMAS_Route_Reader  → config row N        │
├─ AnyRoute?           no more rows → End                                     │
├─ IT_Collect          fi_P2O_100_MATMAS_ERP_to_OneLake                       │
│                      runs on the row's Secure Agent:                         │
│                      <agent folder>/<pattern> → erp_to_matmas/landing/<ERP>/<RUN_ID>
├─ FilesFound?         0 files → DT_LogNoFile ───────────────────────────────┤
├─ DT_Load             mt_P2O_102_MATMAS_Load                                  │
│                      landing/<ERP>/<RUN_ID> → 6 fields + START/END_DATE     │
│                      → MATMAS stage → Post SQL → matmas.<erp>_material_master (INSERT/UPSERT/...)
├─ DT_Outcome          mt_P2O_103_MATMAS_Outcome → ARCHIVE | DUPLICATE | ERROR │
├─ IT_Move             fi_P2O_101_MATMAS_OneLake_Move                          │
│                      landing/<ERP>/<RUN_ID> → archive|duplicate|error/<ERP>/<RUN_ID>
├─ CT_ArchiveSource    (only if load OK) Command Task on the row's agent:      │
│                      move source file to the agent archive folder            │
└─ LoopBack            Jump ──────────────────────────────────────────────────┘
```

Objects:

| # | Object | Type | Runs on |
|---|---|---|---|
| 1 | `fi_P2O_100_MATMAS_ERP_to_OneLake` | File Ingestion and Replication | The row's agent, overridden per row |
| 2 | `fi_P2O_101_MATMAS_OneLake_Move` | File Ingestion and Replication | Central agent |
| 3 | `m_/mt_P2O_101_MATMAS_Route_Reader` | Mapping + mapping task | Central agent |
| 4 | `m_/mt_P2O_102_MATMAS_Load` | Mapping + mapping task | Central agent |
| 5 | `m_/mt_P2O_103_MATMAS_Outcome` | Mapping + mapping task | Central agent |
| 6 | `m_/mt_P2O_104_MATMAS_Log` | Mapping + mapping task | Central agent |
| 7 | `tf_P2O_100_MATMAS_Orchestrator` | Taskflow | IDMC cloud |

The **central agent** is any runtime environment that reaches both OneLake and the Fabric SQL database. `US.US02.01` already runs the JDBC connection.

---

## 2. One-time setup

1. **Database.** On the Fabric SQL database:
   - Run `sql/01_tables.sql`, then `sql/02_procedures.sql`, then `sql/03_seed_config.sql`.
   - Check the computed paths with `SELECT * FROM matmas.v_route_reader;`.
   - Run `sql/04_test_without_cdi.sql` and compare with the expected results in its comments.
2. **OneLake path format.** Open `fi_P2O_000_BPDWFS_PO_to_OneLake`, go to Target, and look at the **Target Directory**. Write the MATMAS root in exactly the same format:
   ```sql
   UPDATE cfg.matmas_setting SET setting_value = N'<same format>/erp_to_matmas' WHERE setting_name = 'onelake_root';
   ```
   The seeded value is `lh_p2o_intg_dev.Lakehouse/Files/erp_to_matmas`.
3. **Lakehouse folders.** `landing/JDE` and `landing/Vision` exist. Also create `archive/JDE`, `archive/Vision`, `duplicate/JDE`, `duplicate/Vision`, `error/JDE` and `error/Vision`. The ingestion task may create them itself, but creating them avoids surprises.
4. **Design sample.** Upload `samples/JDE/JDE_MATMAS_20261116.txt` to `Files/erp_to_matmas/landing/JDE/_design/`. The load mapping takes its field list from it.
5. **Local folder connections.** Create one per source agent group, for example `LF_MATMAS_JDE` on `US.US02.01` and `LF_MATMAS_VISION` on `US.AMCOR.01`. Put the names in `cfg.matmas_route_config.source_connection`.
6. **Agent archive script.** Copy `agent_scripts/matmas_archive_source.cmd` and `.ps1` to `C:\Informatica\scripts\` on every source agent. Use the `.sh` on Linux agents.
7. **Network.** Every source agent must reach `onelake.dfs.fabric.microsoft.com` over HTTPS. The collect step pushes from there.
8. **Real values.** Fill the real agent groups, source folders and patterns into `cfg.matmas_route_config`.

---

## 3. `fi_P2O_100_MATMAS_ERP_to_OneLake`: collect from the agent

Fastest way: **Copy** `fi_P2O_000_BPDWFS_PO_to_OneLake`, rename it, then change the settings below.

| Step | Setting | Value |
|---|---|---|
| Definition | Name | `fi_P2O_100_MATMAS_ERP_to_OneLake` |
| | Runtime environment | `US.US02.01`, overridden per row |
| Source | Connection type / connection | Local folder / `LF_MATMAS_JDE`, overridden per row |
| | Source directory | `D:\Interfaces\JDE\MATMAS\outbound`, overridden per row |
| | File pattern | `JDE_MATMAS*.txt`, overridden per row |
| | After transfer | **Keep** the source file. Archiving happens only after a successful load. |
| Target | Connection type / connection | Microsoft Fabric OneLake / `FABRIC.AMCOR.ONELAKE.P2O` |
| | Target directory | `<ONELAKE_ROOT>/landing/JDE`, overridden per row with `/<RUN_ID>` |
| | If file exists | Overwrite |
| Action | Actions | None |
| Schedule | Schedule | None. Only the taskflow runs it. Do not use a file listener as source, because listener-based tasks cannot be used in a taskflow. |

---

## 4. `fi_P2O_101_MATMAS_OneLake_Move`: landing to archive, duplicate or error

Copy `fi_P2O_100_...` again and change:

| Setting | Value |
|---|---|
| Runtime environment | Central agent, for example `US.US02.01` |
| Source | Microsoft Fabric OneLake / `FABRIC.AMCOR.ONELAKE.P2O`. Directory `<ONELAKE_ROOT>/landing/JDE`, pattern `*`. Overridden per row. |
| After transfer | **Delete source files**, if your version offers it. If not, schedule `fabric/nb_matmas_purge_landing.py` in Fabric. It removes copied run folders from `landing` after 7 days. |
| Target | `FABRIC.AMCOR.ONELAKE.P2O`, directory `<ONELAKE_ROOT>/archive/JDE`, overridden per row with the outcome folder and `/<RUN_ID>` |

If your file ingestion version does not accept OneLake as a source, leave this task out. The files stay in `landing/<ERP>/<RUN_ID>`, and the outcome is still recorded in the run log.

---

## 5. `m_P2O_101_MATMAS_Route_Reader`: read config row N

**In-out parameters.** All are String, aggregation **Max**, default empty, except where noted:

| Parameter | Default | Role |
|---|---|---|
| `RUN_GROUP` | `DAILY` | Input from the taskflow |
| `ROW_ID` | `1`, Integer | Input from the taskflow |
| `RUN_ID` | | Input from the taskflow |
| `ROUTE_ID`, `ERP_SYSTEM`, `RUNTIME_ENVIRONMENT`, `SOURCE_CONNECTION`, `SOURCE_DIRECTORY`, `FILE_PATTERN`, `SOURCE_ARCHIVE_DIRECTORY`, `ONELAKE_CONNECTION`, `ONELAKE_LANDING_DIR`, `ONELAKE_ARCHIVE_DIR`, `ONELAKE_DUPLICATE_DIR`, `ONELAKE_ERROR_DIR`, `TARGET_TABLE`, `LOAD_OPERATION`, `START_DATE_VALUE`, `END_DATE_VALUE`, `NOTIFY_EMAIL` | | Outputs back to the taskflow |

**Transformations:**

1. **Source** `src_Route`: connection `jdbcv2.MSSQL.sqldb-p2o-intg.stg`, single object **`matmas_route_reader`**, a view.
2. **Filter** `flt_Row`: `RUN_GROUP = $$RUN_GROUP AND ROW_NUM = $$ROW_ID`
3. **Expression** `exp_SetParams`:
   - **Variable ports**, one per output parameter:
     ```
     v_1  = SETVARIABLE($$ROUTE_ID,              ROUTE_ID)
     v_2  = SETVARIABLE($$ERP_SYSTEM,            ERP_SYSTEM)
     v_3  = SETVARIABLE($$RUNTIME_ENVIRONMENT,   RUNTIME_ENVIRONMENT)
     v_4  = SETVARIABLE($$SOURCE_CONNECTION,     SOURCE_CONNECTION)
     v_5  = SETVARIABLE($$SOURCE_DIRECTORY,      SOURCE_DIRECTORY)
     v_6  = SETVARIABLE($$FILE_PATTERN,          FILE_PATTERN)
     v_7  = SETVARIABLE($$SOURCE_ARCHIVE_DIRECTORY, SOURCE_ARCHIVE_DIRECTORY)
     v_8  = SETVARIABLE($$ONELAKE_CONNECTION,    ONELAKE_CONNECTION)
     v_9  = SETVARIABLE($$ONELAKE_LANDING_DIR,   ONELAKE_LANDING_DIR)
     v_10 = SETVARIABLE($$ONELAKE_ARCHIVE_DIR,   ONELAKE_ARCHIVE_DIR)
     v_11 = SETVARIABLE($$ONELAKE_DUPLICATE_DIR, ONELAKE_DUPLICATE_DIR)
     v_12 = SETVARIABLE($$ONELAKE_ERROR_DIR,     ONELAKE_ERROR_DIR)
     v_13 = SETVARIABLE($$TARGET_TABLE,          TARGET_TABLE)
     v_14 = SETVARIABLE($$LOAD_OPERATION,        LOAD_OPERATION)
     v_15 = SETVARIABLE($$START_DATE_VALUE,      START_DATE_VALUE)
     v_16 = SETVARIABLE($$END_DATE_VALUE,        END_DATE_VALUE)
     v_17 = SETVARIABLE($$NOTIFY_EMAIL,          NOTIFY_EMAIL)
     ```
   - **Output ports**: `o_RUN_ID = $$RUN_ID`, `o_ROUTE_ID = ROUTE_ID`, `o_EVENT = 'STARTED'`, `o_MESSAGE = 'row ' || TO_CHAR(ROW_NUM) || ' of ' || TO_CHAR(TOTAL_ROUTES) || ' on ' || RUNTIME_ENVIRONMENT`
4. **Target** `tgt_RunLog`: same connection, object **`matmas_run_log`**, Insert. Map `o_*` to `RUN_ID`, `ROUTE_ID`, `EVENT`, `MESSAGE`.

When `ROW_ID` is past the last row, the filter returns nothing. All outputs then stay empty, and the taskflow ends the loop.

**Mapping task `mt_P2O_101_MATMAS_Route_Reader`** runs on the central agent.

---

## 6. `m_P2O_102_MATMAS_Load`: 6 fields plus dates into the ERP table

**In-out parameters.** All are String:

| Parameter | Default |
|---|---|
| `RUN_ID`, `ROUTE_ID` | empty |
| `SRC_DIRECTORY` | `<ONELAKE_ROOT>/landing/JDE/_design` |
| `START_DATE_VALUE` | empty, meaning the load date |
| `END_DATE_VALUE` | `9999-12-31` |

**Transformations:**

1. **Source** `src_OneLakeFiles`
   - Connection `FABRIC.AMCOR.ONELAKE.P2O`, object the design sample `JDE_MATMAS_20261116.txt`.
   - Formatting: Delimited, delimiter `|`, text qualifier none, **import column names from first line**, first data row 2, UTF-8.
   - Advanced:
     - **Source type: Directory**, or the equivalent "read all files in folder" option.
     - **Directory override: `$$SRC_DIRECTORY`**. This reads every file the collect step put into this run's folder.
     - Add the **FileName** field, if your connector offers it.
2. **Expression** `exp_AddDates`. Input names follow the file header, for example `ERP_Item_Number`:
   ```
   o_RUN_ID                    = $$RUN_ID
   o_ROUTE_ID                  = $$ROUTE_ID
   o_SOURCE_FILE_NAME          = $$SRC_DIRECTORY        -- or the FileName field when available
   o_ERP_ITEM_NUMBER           = LTRIM(RTRIM(ERP_Item_Number))
   o_MATERIAL_DESCRIPTION      = LTRIM(RTRIM(Material_Description))
   o_PLANT_CODE                = LTRIM(RTRIM(Plant_Code))
   o_SUPPLIER_PART_NUMBER      = LTRIM(RTRIM(Supplier_Part_))      -- "Supplier Part#"
   o_SUPPLIER_NUMBER           = LTRIM(RTRIM(Supplier_Number))
   o_MANUFACTURING_PART_NUMBER = LTRIM(RTRIM(Manufacturing_Part_)) -- "Manufacturing Part#"
   o_START_DATE = IIF(ISNULL($$START_DATE_VALUE) OR LTRIM(RTRIM($$START_DATE_VALUE)) = '',
                      TRUNC(SESSSTARTTIME, 'DD'),
                      TO_DATE($$START_DATE_VALUE, 'YYYY-MM-DD'))
   o_END_DATE   = TO_DATE(IIF(ISNULL($$END_DATE_VALUE) OR LTRIM(RTRIM($$END_DATE_VALUE)) = '',
                              '9999-12-31', $$END_DATE_VALUE), 'YYYY-MM-DD')
   ```
3. **Filter** `flt_NotBlank`:
   `LENGTH(LTRIM(RTRIM(o_ERP_ITEM_NUMBER || o_MATERIAL_DESCRIPTION || o_PLANT_CODE || o_SUPPLIER_PART_NUMBER || o_SUPPLIER_NUMBER || o_MANUFACTURING_PART_NUMBER))) > 0`
4. **Target** `tgt_Stage`
   - Connection `jdbcv2.MSSQL.sqldb-p2o-intg.stg`, object **`MATMAS_MATERIAL_MASTER_STAGE`**, operation Insert. Map the `o_` ports to the same column names.
   - **Advanced, Post SQL**: `EXEC matmas.sp_apply_stage`
   - Forward rejected rows: on.

What the Post SQL does, using the row's `TARGET_TABLE`, `LOAD_OPERATION` and `KEY_COLUMNS`:

| `LOAD_OPERATION` | Effect on `matmas.<erp>_material_master` |
|---|---|
| `INSERT` | Insert all valid rows |
| `UPSERT` | Merge on the key columns. Update existing rows and keep their original START_DATE. Insert new keys. |
| `UPDATE` | Update matching keys only |
| `DELETE` | Delete matching keys |
| `TRUNCATE_INSERT` | Empty the table, then insert |

In every mode:
- Rows missing a key go to `matmas.material_master_reject`.
- Exact duplicate lines collapse.
- A file already loaded for the route is skipped as `DUPLICATE_FILE`.
- A failure rolls back that route, logs `APPLY_FAILED`, and **fails the task** so the taskflow takes its error path.

**Mapping task `mt_P2O_102_MATMAS_Load`** runs on the central agent.

---

## 7. `m_P2O_103_MATMAS_Outcome`: where do the files go

- **In-out parameters**, String: `RUN_ID`, `ROUTE_ID`, `OUTCOME`. Inputs from the taskflow, `OUTCOME` is the output.
- **Source**: `matmas_run_outcome`, a view.
- **Filter**: `RUN_ID = $$RUN_ID AND ROUTE_ID = $$ROUTE_ID`
- **Expression**:
  - `v_1 = SETVARIABLE($$OUTCOME, OUTCOME)`
  - `o_RUN_ID = RUN_ID`, `o_ROUTE_ID = ROUTE_ID`, `o_EVENT = 'OUTCOME'`, `o_MESSAGE = 'files go to ' || OUTCOME`
- **Target**: `matmas_run_log`, Insert.

`OUTCOME` takes one of three values:

| Value | When |
|---|---|
| `ARCHIVE` | Data was applied |
| `DUPLICATE` | Every file had already been loaded before |
| `ERROR` | Apply or load failed |

---

## 8. `m_P2O_104_MATMAS_Log`: write an event

- **In-out parameters**, String: `RUN_ID`, `ROUTE_ID`, `EVENT`, `MESSAGE`, `FILE_COUNT` (default `0`).
- **Source**: `matmas_one_row`
- **Expression**: `o_RUN_ID = $$RUN_ID`, `o_ROUTE_ID = $$ROUTE_ID`, `o_EVENT = $$EVENT`, `o_MESSAGE = SUBSTR($$MESSAGE, 1, 4000)`, `o_FILE_COUNT = TO_INTEGER($$FILE_COUNT)`
- **Target**: `matmas_run_log`, Insert.

---

## 9. `tf_P2O_100_MATMAS_Orchestrator`: the taskflow

**Start properties**
- Input field: `RUN_GROUP` (Text, default `DAILY`).
- Temporary fields, all Text unless noted: `RUN_ID`, `ROW_ID` (Integer), `ROUTE_ID`, `RUNTIME_ENVIRONMENT`, `SOURCE_CONNECTION`, `SOURCE_DIRECTORY`, `FILE_PATTERN`, `SOURCE_ARCHIVE_DIRECTORY`, `ONELAKE_CONNECTION`, `RUN_LANDING_DIR`, `ONELAKE_ARCHIVE_DIR`, `ONELAKE_DUPLICATE_DIR`, `ONELAKE_ERROR_DIR`, `START_DATE_VALUE`, `END_DATE_VALUE`, `OUTCOME`, `MOVE_TARGET_DIR`.

Pick every task output with the field picker. The formula it writes looks like `$temp.DT_ReadRoute[1]/output[1]/ROUTE_ID`.

| # | Step name | Type | Configuration |
|---|---|---|---|
| 1 | `Init` | Assignment | `RUN_ID` (Formula): `fn:format-dateTime(fn:adjust-dateTime-to-timezone(fn:current-dateTime(), xs:dayTimeDuration('PT0S')), '[Y0001][M01][D01][H01][m01][s01]')`. `ROW_ID` (Content): `0` |
| 2 | `NextRow` | Assignment | `ROW_ID` = `$temp.ROW_ID + 1`. Set every route field and `OUTCOME` to empty. |
| 3 | `DT_ReadRoute` | Data Task, `mt_P2O_101_MATMAS_Route_Reader` | Input fields: `ROW_ID` = `$temp.ROW_ID`, `RUN_GROUP` = `$input.RUN_GROUP`, `RUN_ID` = `$temp.RUN_ID`. Every output parameter = empty Content. That resets it each loop because of the Max aggregation, per KB 000225868. On Error: Suspend. |
| 4 | `TakeRoute` | Assignment | Copy the reader outputs into the temp fields. `RUN_LANDING_DIR` = `concat(<DT_ReadRoute output ONELAKE_LANDING_DIR>, '/', $temp.RUN_ID)` |
| 5 | `AnyRoute?` | Decision | Path 1: `$temp.ROUTE_ID = ''` → **End**. Otherwise → step 6. |
| 6 | `IT_Collect` | Ingestion Task, `fi_P2O_100_MATMAS_ERP_to_OneLake` | Input fields:<br>• **Runtime Environment** = `$temp.RUNTIME_ENVIRONMENT`<br>• **Source Connection** = `$temp.SOURCE_CONNECTION`<br>• **Source Directory** = `$temp.SOURCE_DIRECTORY`<br>• **File Pattern** = `$temp.FILE_PATTERN`<br>• **Target Connection** = `$temp.ONELAKE_CONNECTION`<br>• **Target Directory** = `$temp.RUN_LANDING_DIR`<br>On Error: Custom → `DT_LogCollectFailed` → Jump `NextRow`. |
| 7 | `FilesFound?` | Decision | `IT_Collect` output **Success Files** `> 0` → step 8. Otherwise → `DT_LogNoFile` → Jump `NextRow`. |
| 8 | `DT_Load` | Data Task, `mt_P2O_102_MATMAS_Load` | Inputs: `RUN_ID`, `ROUTE_ID`, `SRC_DIRECTORY` = `$temp.RUN_LANDING_DIR`, `START_DATE_VALUE`, `END_DATE_VALUE`. On Error: Custom → `DT_LogLoadFailed` → step 9. **Fail taskflow on completion**: on. |
| 9 | `DT_Outcome` | Data Task, `mt_P2O_103_MATMAS_Outcome` | Inputs: `RUN_ID`, `ROUTE_ID`, `OUTCOME` = empty. Then Assignment `OUTCOME` = output `OUTCOME`. Then Assignment `MOVE_TARGET_DIR` = `concat(if ($temp.OUTCOME = 'ARCHIVE') then $temp.ONELAKE_ARCHIVE_DIR else if ($temp.OUTCOME = 'DUPLICATE') then $temp.ONELAKE_DUPLICATE_DIR else $temp.ONELAKE_ERROR_DIR, '/', $temp.RUN_ID)` |
| 10 | `IT_Move` | Ingestion Task, `fi_P2O_101_MATMAS_OneLake_Move` | Input fields: **Source Directory** = `$temp.RUN_LANDING_DIR`, **Target Directory** = `$temp.MOVE_TARGET_DIR`. On Error: Custom → `DT_LogMoveFailed` → step 11. |
| 11 | `LoadOK?` | Decision | `$temp.OUTCOME != 'ERROR'` and `$temp.SOURCE_ARCHIVE_DIRECTORY != ''` → step 12. Otherwise → step 13. When the outcome is ERROR, the source file stays on the agent and the next run retries it. |
| 12 | `CT_ArchiveSource` | Command Task | **Runtime Environment**: Field `$temp.RUNTIME_ENVIRONMENT`. **Script File Name**: `C:\Informatica\scripts\matmas_archive_source.cmd`. **Input Arguments**: `concat('"', $temp.SOURCE_DIRECTORY, '" "', $temp.FILE_PATTERN, '" "', $temp.SOURCE_ARCHIVE_DIRECTORY, '" ', $temp.RUN_ID)`. On Error: Custom → `DT_LogArchiveFailed` → step 13. |
| 13 | `LoopBack` | Jump | → `NextRow` |
| – | `DT_Log…` | Data Task, `mt_P2O_104_MATMAS_Log` | Inputs: `RUN_ID`, `ROUTE_ID`, `EVENT`, `MESSAGE`. Events: `NO_FILE`, `COLLECT_FAILED`, `LOAD_FAILED`, `MOVE_FAILED`, `ARCHIVE_FAILED`. Example NO_FILE message: `concat('no ', $temp.FILE_PATTERN, ' in ', $temp.SOURCE_DIRECTORY, ' on ', $temp.RUNTIME_ENVIRONMENT)`. For failures, pass the failed step's fault detail. On Error: Ignore. |

**Schedule**: Publish the taskflow, then schedule it, for example daily. For parallel work, give routes different `RUN_GROUP` values and schedule one taskflow run per group.

---

## 10. Monitoring

```sql
SELECT * FROM matmas.v_run_status ORDER BY run_id DESC, route_id;            -- last event per route
SELECT * FROM matmas.run_log WHERE run_id = '<RUN_ID>' ORDER BY log_id;  -- full trail
SELECT * FROM matmas.v_run_outcome WHERE run_id = '<RUN_ID>';               -- archive/duplicate/error
SELECT * FROM matmas.jde_material_master;  SELECT * FROM matmas.vision_material_master;
SELECT * FROM matmas.material_master_reject ORDER BY reject_id DESC;
EXEC matmas.sp_reapply_run '<RUN_ID>', '<ROUTE_ID>';   -- retry after fixing config
```

A healthy route produces this trail: `STARTED` → `LOADED` → `OUTCOME` ("files go to ARCHIVE").

## 11. Test plan in IDMC

1. Put `samples/JDE/JDE_MATMAS_20261116.txt` in the JDE agent's source folder. Activate only `JDE_MATMAS`. Run the taskflow.
   - Expect `LOADED` with inserted=1 and duplicates_collapsed=1.
   - The file should appear in `archive/JDE/<RUN_ID>`, and the source file should move to the agent archive.
2. Run with no file. Expect `NO_FILE`.
3. Put the same file back and run. Expect `DUPLICATE_FILE`, the outcome DUPLICATE, and the file in `duplicate/JDE/<RUN_ID>`.
4. Point the Vision route at a wrong `TARGET_TABLE` and run.
   - Expect `APPLY_FAILED` and `LOAD_FAILED`, with the file in `error/Vision/<RUN_ID>`.
   - The source file stays on the agent. The JDE route still processes normally.

## 12. Onboarding the next ERP

1. Run `EXEC matmas.sp_create_erp_table N'<erp>_material_master';`
2. Add one row to `cfg.matmas_route_config`.
3. Create `landing`, `archive`, `duplicate` and `error/<ERP>` folders in `lh_p2o_intg_dev`.
4. For a new agent group only: create a local folder connection and copy the archive script to the agent.
