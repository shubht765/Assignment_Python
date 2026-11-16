# MATMAS – CDI build guide

One scheduled taskflow runs in the IDMC cloud and reads `MATMAS.CTL_MATMAS_ROUTE` row by row. For each row it:

1. **Collects** the files from that row's Secure Agent folder into OneLake. This uses one file ingestion task, with runtime environment, connections, folder and pattern overridden from the row.
2. **Loads** them with one generic mapping task. The mapping adds Start Date and End Date to the 6 fields and stages the rows. Its Post SQL applies them to the row's ERP table with the row's operation.
3. **Archives** the source files on that same agent. A Command Task does this, with its runtime environment taken from the row.
4. **Logs** every outcome to `MATMAS.CTL_MATMAS_RUN_LOG`.

Objects to build. None of them is specific to an ERP or a location.

| Object | Type | Purpose |
|---|---|---|
| `OL_MATMAS` | Connection (OneLake) | The central landing zone |
| `LF_MATMAS_<agent>` | Connection (local folder) | Source for the file ingestion task, one per agent group |
| `m_MATMAS_ROUTE_READER` / `mt_MATMAS_ROUTE_READER` | Mapping + task | Reads config row N and returns its values to the taskflow |
| `fit_MATMAS_COLLECT` | File ingestion and replication task | Copies agent folder to OneLake |
| `m_MATMAS_LOAD` / `mt_MATMAS_LOAD` | Mapping + task | 6 fields plus 2 dates into staging. Post SQL applies to the ERP table |
| `m_MATMAS_LOG` / `mt_MATMAS_LOG` | Mapping + task | Writes NO_FILE and failure events |
| `tf_MATMAS_ORCHESTRATOR` | Taskflow | The loop, scheduled |

Documentation this design relies on:
- [Ingestion Task step](https://docs.informatica.com/integration-cloud/data-integration/current-version/taskflows/taskflows/setting-taskflow-step-properties/ingestion-task-step.html): overrides Runtime Environment, Source/Target Connection, Source/Target Directory, File Pattern.
- [Command Task step](https://docs.informatica.com/integration-cloud/data-integration/current-version/taskflows/taskflows/setting-taskflow-step-properties/command-task-step.html): Runtime Environment can come from a field.
- [Data Task step](https://docs.informatica.com/integration-cloud/data-integration/current-version/taskflows/taskflows/setting-taskflow-step-properties/data-task-step.html): overrides in-out and input parameters.
- [KB 000225868](https://knowledge.informatica.com/s/article/HOW-TO-Loop-data-task-in-taskflow-to-process-different-source-targets?language=en_US): read a control table row by row in a loop.

---

## 0. Prerequisites

1. On the Fabric SQL database, run `sql/01_tables.sql`, `sql/02_procedures.sql`, `sql/03_seed_config.sql`. Then fill in the real agent group, connection and folder names in `CTL_MATMAS_ROUTE`.
2. Run `sql/04_test_without_cdi.sql`. The expected results are written in its comments.
3. Check that **File Ingestion and Replication** is enabled in your org.
4. **Every source agent must reach OneLake** over HTTPS (`onelake.dfs.fabric.microsoft.com`). The copy runs on the agent where the file lands, and that agent pushes it to OneLake.
5. Copy `agent_scripts/matmas_archive_source.cmd` and `.ps1` to the **same path on every source agent**, for example `C:\Informatica\scripts\`. Use the `.sh` on Linux agents. This is one script per machine, not per location. It receives everything as arguments from the config row.
6. Pick a **central runtime environment** for the reader, load and log tasks. It must reach OneLake and the Fabric SQL database. `US.US02.01` already runs `jdbcv2.MSSQL.sqldb-p2o-intg.stg`.

---

## 1. Connections

| Name | Type | Settings |
|---|---|---|
| `jdbcv2.MSSQL.sqldb-p2o-intg.stg` | JDBC V2, existing | Unchanged. All MATMAS objects CDI touches are views in schema `stg`. |
| `OL_MATMAS` | Microsoft Fabric OneLake, or Azure Data Lake Storage Gen2 pointed at `onelake.dfs.fabric.microsoft.com` | Workspace and lakehouse that hold `Files/matmas/...`. Service principal with write access. |
| `LF_MATMAS_JDE`, `LF_MATMAS_VISION`, … | Local folder (file ingestion source) | One per agent group. The directory is overridden per row, so any default works. |

Put a test file into OneLake once at `Files/matmas/inbound/_design/JDE_MATMAS_20261116.txt`, copied from `samples/JDE`. The load mapping imports its field list from it.

---

## 2. `m_MATMAS_ROUTE_READER`: read config row N

**In-out parameters.** All are String, aggregation Max, default value empty:

`RUN_GROUP` (default `DAILY`), `ROW_ID` (Integer, default `1`), `RUN_ID`,
`ROUTE_ID`, `ERP_SYSTEM`, `RUNTIME_ENVIRONMENT`, `SOURCE_CONNECTION`, `SOURCE_DIRECTORY`, `FILE_PATTERN`,
`SOURCE_ARCHIVE_DIRECTORY`, `ONELAKE_CONNECTION`, `ONELAKE_DIRECTORY`, `TARGET_TABLE`, `LOAD_OPERATION`,
`START_DATE_VALUE`, `END_DATE_VALUE`, `NOTIFY_EMAIL`

**Transformations:**

1. **Source**: connection `jdbcv2.MSSQL.sqldb-p2o-intg.stg`, object `MATMAS_ROUTE_READER`, a view.
2. **Filter**: `RUN_GROUP = $$RUN_GROUP AND ROW_NUM = $$ROW_ID`
3. **Expression** `exp_SetParams`:
   - **Variable ports**, one per route column:
     ```
     v_ROUTE_ID            = SETVARIABLE($$ROUTE_ID, ROUTE_ID)
     v_ERP_SYSTEM          = SETVARIABLE($$ERP_SYSTEM, ERP_SYSTEM)
     v_RUNTIME_ENVIRONMENT = SETVARIABLE($$RUNTIME_ENVIRONMENT, RUNTIME_ENVIRONMENT)
     ... same for SOURCE_CONNECTION, SOURCE_DIRECTORY, FILE_PATTERN, SOURCE_ARCHIVE_DIRECTORY,
         ONELAKE_CONNECTION, ONELAKE_DIRECTORY, TARGET_TABLE, LOAD_OPERATION,
         START_DATE_VALUE, END_DATE_VALUE, NOTIFY_EMAIL
     ```
   - **Output ports** for a STARTED event:
     `o_RUN_ID = $$RUN_ID`, `o_ROUTE_ID = ROUTE_ID`, `o_EVENT = 'STARTED'`, `o_MESSAGE = 'row ' || TO_CHAR(ROW_NUM) || ' of ' || TO_CHAR(TOTAL_ROUTES)`
4. **Target**: same connection, object `MATMAS_RUN_LOG`, Insert. Map `o_RUN_ID`, `o_ROUTE_ID`, `o_EVENT`, `o_MESSAGE` to `RUN_ID`, `ROUTE_ID`, `EVENT`, `MESSAGE`.

When `ROW_ID` is past the last row, the filter passes nothing. The parameters then keep the empty values the taskflow sent, which is how the taskflow knows the loop is finished.

**Mapping task `mt_MATMAS_ROUTE_READER`** runs on the central runtime environment.

---

## 3. `fit_MATMAS_COLLECT`: agent folder to OneLake

Create it in Data Integration, under New, then File Ingestion and Replication.

| Setting | Value |
|---|---|
| Runtime environment | Any source agent group, for example `US.US02.01`. It is overridden per row. |
| Source | Local folder connection `LF_MATMAS_JDE`. Source directory and file pattern from the JDE row. Overridden per row. |
| Target | `OL_MATMAS`, target directory `Files/matmas/inbound/JDE`. Overridden per row. |
| Source options | Do not delete source files. Archiving happens after a successful load. Turn on skip duplicate files if your version offers it. |
| Trigger | None. Not a file listener, because listener-based tasks cannot be used in a taskflow. |

---

## 4. `m_MATMAS_LOAD`: 6 fields plus dates into the ERP table

**In-out parameters.** All are String with empty defaults:

`RUN_ID`, `ROUTE_ID`, `SRC_DIRECTORY` (default `Files/matmas/inbound/_design`), `START_DATE_VALUE`, `END_DATE_VALUE` (default `9999-12-31`)

**Transformations:**

1. **Source**
   - Connection `OL_MATMAS`, object `JDE_MATMAS_20261116.txt` from the `_design` folder.
   - Format: delimited `|`, import column names from the first line, first data row 2, UTF-8.
   - Advanced: Source type **Directory**, Directory override `$$SRC_DIRECTORY`. This reads every file the collect step put into this run's folder.
   - If the connector offers a FileName field, add it.
   - Property names differ slightly between the OneLake and ADLS Gen2 connectors. Use the directory read and directory override options of yours.
2. **Expression** `exp_AddDates`. The six input ports are named from the file header, for example `ERP_Item_Number`, `Supplier_Part_`:
   ```
   o_RUN_ID                    = $$RUN_ID
   o_ROUTE_ID                  = $$ROUTE_ID
   o_SOURCE_FILE_NAME          = IIF(ISNULL(FileName), $$SRC_DIRECTORY, FileName)   -- or just $$SRC_DIRECTORY
   o_ERP_ITEM_NUMBER           = LTRIM(RTRIM(<ERP Item Number>))
   o_MATERIAL_DESCRIPTION      = LTRIM(RTRIM(<Material Description>))
   o_PLANT_CODE                = LTRIM(RTRIM(<Plant Code>))
   o_SUPPLIER_PART_NUMBER      = LTRIM(RTRIM(<Supplier Part#>))
   o_SUPPLIER_NUMBER           = LTRIM(RTRIM(<Supplier Number>))
   o_MANUFACTURING_PART_NUMBER = LTRIM(RTRIM(<Manufacturing Part#>))
   o_START_DATE = IIF(LTRIM(RTRIM($$START_DATE_VALUE)) = '' OR ISNULL($$START_DATE_VALUE),
                      TRUNC(SESSSTARTTIME, 'DD'),
                      TO_DATE($$START_DATE_VALUE, 'YYYY-MM-DD'))
   o_END_DATE   = TO_DATE(IIF(LTRIM(RTRIM($$END_DATE_VALUE)) = '' OR ISNULL($$END_DATE_VALUE),
                              '9999-12-31', $$END_DATE_VALUE), 'YYYY-MM-DD')
   ```
   Start Date is the load date unless the config row sets `START_DATE_VALUE`. End Date is `9999-12-31` unless the row sets `END_DATE_VALUE`.
3. **Filter**: drop blank lines with
   `LENGTH(LTRIM(RTRIM(o_ERP_ITEM_NUMBER || o_MATERIAL_DESCRIPTION || o_PLANT_CODE || o_SUPPLIER_PART_NUMBER || o_SUPPLIER_NUMBER || o_MANUFACTURING_PART_NUMBER))) > 0`
4. **Target**
   - Connection `jdbcv2.MSSQL.sqldb-p2o-intg.stg`, object `MATMAS_MATERIAL_MASTER_STAGE`, Insert. Field mapping is automatic: strip the `o_` prefix or map by name.
   - **Advanced, Post SQL**: `EXEC MATMAS.sp_MATMAS_ApplyStage`

The Post SQL reads the route's `TARGET_TABLE`, `LOAD_OPERATION` and `KEY_COLUMNS` from the config. It then applies the staged rows in one transaction:

| Operation | What happens |
|---|---|
| `INSERT` | Insert all valid rows |
| `UPSERT` | Merge on the key columns. Update the existing row and keep its original Start Date. Insert new keys. |
| `UPDATE` | Update matching keys only |
| `DELETE` | Delete matching keys |
| `TRUNCATE_INSERT` | Empty the table, then insert |

In every mode:
- A row missing a key is rejected to `MATERIAL_MASTER_REJECT`.
- Exact duplicate lines are collapsed.
- A file whose content was already loaded for this route is skipped as `DUPLICATE_FILE`.
- If any route fails, the procedure raises an error so the mapping task shows **failed** in the monitor.

**Mapping task `mt_MATMAS_LOAD`** runs on the central runtime environment.

---

## 5. `m_MATMAS_LOG`: write an event

- **In-out parameters**, String: `RUN_ID`, `ROUTE_ID`, `EVENT`, `MESSAGE`, `FILE_COUNT` (default `0`).
- **Source**: `MATMAS_ONE_ROW`, a view that always returns 1 row.
- **Expression**: `o_RUN_ID = $$RUN_ID`, `o_ROUTE_ID = $$ROUTE_ID`, `o_EVENT = $$EVENT`, `o_MESSAGE = SUBSTR($$MESSAGE, 1, 4000)`, `o_FILE_COUNT = TO_INTEGER($$FILE_COUNT)`.
- **Target**: `MATMAS_RUN_LOG`, Insert.
- **Mapping task** `mt_MATMAS_LOG` runs on the central runtime environment.

---

## 6. Taskflow `tf_MATMAS_ORCHESTRATOR`

**Start**
- Input field: `RUN_GROUP` (Text, default `DAILY`).
- Temporary fields, all Text unless noted: `RUN_ID`, `ROW_ID` (Integer), `ROUTE_ID`, `RUNTIME_ENVIRONMENT`, `SOURCE_CONNECTION`, `SOURCE_DIRECTORY`, `FILE_PATTERN`, `SOURCE_ARCHIVE_DIRECTORY`, `ONELAKE_CONNECTION`, `ONELAKE_DIRECTORY`, `RUN_FOLDER`, `START_DATE_VALUE`, `END_DATE_VALUE`.

Read a Data Task's or Ingestion Task's outputs with the field picker. The formula it writes looks like `$temp.DT_ReadRoute[1]/output[1]/ROUTE_ID`.

| # | Step | Type | Settings |
|---|---|---|---|
| 1 | `Init` | Assignment | `RUN_ID` (Formula) = `fn:format-dateTime(fn:adjust-dateTime-to-timezone(fn:current-dateTime(), xs:dayTimeDuration('PT0S')), '[Y0001][M01][D01][H01][m01][s01]')`. `ROW_ID` = `0`. |
| 2 | `NextRow` | Assignment | `ROW_ID` = `$temp.ROW_ID + 1`. Set `ROUTE_ID` … `END_DATE_VALUE` to empty. |
| 3 | `DT_ReadRoute` | Data Task → `mt_MATMAS_ROUTE_READER` | Inputs: `ROW_ID` = `$temp.ROW_ID`, `RUN_GROUP` = `$input.RUN_GROUP`, `RUN_ID` = `$temp.RUN_ID`. Every other in-out parameter = empty Content. That reset is needed because of the Max aggregation, per KB 000225868. On Error: Suspend. |
| 4 | `TakeRoute` | Assignment | Copy each output (`ROUTE_ID`, `RUNTIME_ENVIRONMENT`, …) into its temp field. `RUN_FOLDER` = `concat($temp.ONELAKE_DIRECTORY, '/', $temp.RUN_ID)` |
| 5 | `AnyRoute?` | Decision | `$temp.ROUTE_ID = ''` → **End**. Otherwise continue. |
| 6 | `IT_Collect` | Ingestion Task → `fit_MATMAS_COLLECT` | Input fields: **Runtime Environment** = `$temp.RUNTIME_ENVIRONMENT`, **Source Connection** = `$temp.SOURCE_CONNECTION`, **Source Directory** = `$temp.SOURCE_DIRECTORY`, **File Pattern** = `$temp.FILE_PATTERN`, **Target Connection** = `$temp.ONELAKE_CONNECTION`, **Target Directory** = `$temp.RUN_FOLDER`. On Error: Custom → `DT_LogCollectFailed` → Jump to `NextRow`. |
| 7 | `FilesFound?` | Decision | `IT_Collect` output **Success Files** `> 0` → step 8. Otherwise `DT_LogNoFile` → Jump to `NextRow`. |
| 8 | `DT_Load` | Data Task → `mt_MATMAS_LOAD` | Inputs: `RUN_ID`, `ROUTE_ID`, `SRC_DIRECTORY` = `$temp.RUN_FOLDER`, `START_DATE_VALUE`, `END_DATE_VALUE`. On Error: Custom → `DT_LogLoadFailed` → Jump to `NextRow`. The source file is not archived, so the next run retries it. **Fail taskflow on completion**: on. |
| 9 | `Archive?` | Decision | `$temp.SOURCE_ARCHIVE_DIRECTORY != ''` → step 10, otherwise step 11 |
| 10 | `CT_ArchiveSource` | Command Task | **Runtime Environment** = Field `$temp.RUNTIME_ENVIRONMENT`. Script File Name = `C:\Informatica\scripts\matmas_archive_source.cmd`. Input Arguments = `concat('"', $temp.SOURCE_DIRECTORY, '" "', $temp.FILE_PATTERN, '" "', $temp.SOURCE_ARCHIVE_DIRECTORY, '" ', $temp.RUN_ID)`. On Error: Custom → `DT_LogArchiveFailed` → step 11. |
| 11 | `LoopBack` | Jump | to `NextRow` |
| – | `DT_Log…` steps | Data Task → `mt_MATMAS_LOG` | Inputs: `RUN_ID`, `ROUTE_ID`, `EVENT`, `MESSAGE`. EVENT is one of `NO_FILE`, `COLLECT_FAILED`, `LOAD_FAILED`, `ARCHIVE_FAILED`. For NO_FILE the MESSAGE is `concat('no file matching ', $temp.FILE_PATTERN, ' in ', $temp.SOURCE_DIRECTORY)`. For failures use the step's fault detail. On Error: Ignore. |

**Schedule**: Taskflow, then Schedule, daily or as needed. Different run groups can have their own schedules. Run them as separate taskflow instances with a different `RUN_GROUP` input to work in parallel.

---

## 7. Run and check

```sql
-- what happened per route in the last runs
SELECT * FROM MATMAS.V_MATMAS_RUN_STATUS ORDER BY RUN_ID DESC, ROUTE_ID;

-- full event trail of one run
SELECT * FROM MATMAS.CTL_MATMAS_RUN_LOG WHERE RUN_ID = '<RUN_ID>' ORDER BY LOG_ID;

-- the loaded data, one table per ERP
SELECT * FROM MATMAS.JDE_MATERIAL_MASTER;
SELECT * FROM MATMAS.VISION_MATERIAL_MASTER;

-- rejected rows
SELECT * FROM MATMAS.MATERIAL_MASTER_REJECT ORDER BY REJECT_ID DESC;

-- retry an APPLY_FAILED route after fixing its config
EXEC MATMAS.sp_MATMAS_ReapplyRun '<RUN_ID>', '<ROUTE_ID>';
```

Test plan in IDMC:

1. Put `samples/JDE/JDE_MATMAS_20261116.txt` in the JDE agent's source folder.
2. Run the taskflow with only `JDE_MATMAS` active.
3. Expect these log events: `STARTED` → `LOADED` with inserted=1 and duplicates_collapsed=1. The source file should move to the archive folder.
4. Run again with no file. Expect `STARTED` → `NO_FILE`.
5. Put the same file back and run again. Expect `DUPLICATE_FILE`, and no change to the table.
6. Activate `VISION_MATMAS`, set `TARGET_TABLE` to a table that does not exist, and run. Expect `APPLY_FAILED` and `LOAD_FAILED` for Vision. Other routes must still load. Fix the table name, then run `sp_MATMAS_ReapplyRun`.

---

## 8. Onboarding a new ERP or location

1. `EXEC MATMAS.sp_MATMAS_CreateErpTable N'<ERP>_MATERIAL_MASTER';`
2. Insert one row into `MATMAS.CTL_MATMAS_ROUTE` with agent group, local folder connection, folder, pattern, OneLake folder, target table and operation.
3. If it is a new agent group: create its local folder connection and copy the archive script to the agent.

Nothing in the mappings, tasks or taskflow changes.
