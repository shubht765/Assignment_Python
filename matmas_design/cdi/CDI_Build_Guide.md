# MATMAS – Informatica CDI build guide (click-level)

Everything the Informatica side needs: 3 connections, 2 mappings, 2 mapping tasks, 1 taskflow.
All business logic lives in the Fabric SQL database (`sql/02_procedures.sql`), so these objects never change when a new ERP or target is added.

> Why no import zip: an IICS export package is internal object JSON stamped with org/tenant GUIDs, mapping-engine metadata and version numbers that only Informatica itself generates. A hand-written one does not import. Build the objects below once (about an hour), then **export them from your org** and keep that zip in `cdi/export/` as the reusable package.

---

## 0. Prerequisites

1. Run `sql/01_schema_and_tables.sql`, `sql/02_procedures.sql`, `sql/03_seed_config.sql` on the Fabric SQL database.
   If `STRING_SPLIT(..., 1)` errors, the database compatibility level is below 160:
   `ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 160;`
2. Run `sql/04_test_without_cdi.sql` once. If it ends with 3 rows in `MATMAS.MATERIAL_MASTER_TARGET` and 1 reject, the SQL side is proven before you touch CDI.
3. Copy `secure_agent/MATMAS` to the Secure Agent machine (default assumed: `C:\Informatica\SecureAgent\MATMAS`). If you use another path, update `SOURCE_FOLDER` / `ARCHIVE_FOLDER` in `MATMAS.CTL_INBOUND_INTEGRATION`.
4. Copy `cdi/scripts/archive_file.cmd` (Windows agent) or `archive_file.sh` (Linux agent) to `<agent>\MATMAS\scripts\`.
5. The Secure Agent service account needs read/write on the MATMAS folder.

---

## 1. Connections (Administrator → Connections)

| Name | Type | Settings |
|---|---|---|
| `SQL_MATMAS` | Microsoft SQL Server | Server: `<workspace>.database.fabric.microsoft.com`, port 1433, Database: your Fabric SQL DB, Authentication: Microsoft Entra (service principal or user) or SQL auth if enabled, Encryption: on, Schema: `MATMAS`, Runtime env: your Secure Agent group |
| `FF_MATMAS_JDE` | Flat File | Directory: `C:\Informatica\SecureAgent\MATMAS\inbound\JDE`, Date format: `YYYY-MM-DD`, Code page: UTF-8 |
| `FF_MATMAS_VISION` | Flat File | Directory: `C:\Informatica\SecureAgent\MATMAS\inbound\VISION`, Code page: UTF-8 |
| `FF_MATMAS_TEMPLATE` | Flat File | Directory: `C:\Informatica\SecureAgent\MATMAS\inbound\_template` (design time only) |

Every new ERP = one new flat-file connection pointing at its folder + one row in `CTL_INBOUND_INTEGRATION` whose `SOURCE_CONNECTION` is that name. When files move to a share, only the directories change.

---

## 2. Mapping `m_MATMAS_LAND_FILE`  (any file → `MATMAS.LANDING_RAW`)

**Parameters** (Mapping → Parameters panel):

| Name | Type | Default | Override at runtime |
|---|---|---|---|
| `$$SRC_CONN` | Connection (Flat File) | `FF_MATMAS_TEMPLATE` | Yes |
| `$$SRC_OBJECT` | Data object (source) | `LANDING_TEMPLATE.txt` | Yes |
| `$$BATCH_ID` | String, In-Out | `00000000000000` | Yes |
| `$$INTEGRATION_ID` | String, In-Out | `IN_JDE_MATMAS_FILE` | Yes |

**Source** `src_File`
- Connection: `$$SRC_CONN`; Object: `$$SRC_OBJECT`.
- At design time pick `FF_MATMAS_TEMPLATE` / `LANDING_TEMPLATE.txt` so the field list is `COL01..COL30`, then switch both to the parameters.
- Formatting options: Delimiter `|`, Text qualifier: none, **Import field names from first line: OFF**, Rows to skip: **0** (the header is landed as row 1 on purpose; `sp_Harmonize` validates it), Code page UTF-8.
- Fields: `COL01..COL30` string(1000). Files with fewer than 30 columns land NULL in the rest.
- Advanced: set "Allow schema mismatch / fewer columns" tolerant options if your version shows them.

**Sequence Generator** `seq_RowNum`: NEXTVAL, Start 1, Reset on run = Yes. Keep the mapping single-partition so row 1 is the header.

**Expression** `exp_Audit` (passes COL01..COL30 through) and adds:

| Port | Expression |
|---|---|
| `o_BATCH_ID` (string 40) | `$$BATCH_ID` |
| `o_INTEGRATION_ID` (string 60) | `$$INTEGRATION_ID` |
| `o_SRC_FILE_NAME` (string 300) | `$$SRC_OBJECT` (or the built-in `CurrentlyProcessedFileName` field if you enable it on the source) |
| `o_SRC_ROW_NUM` (integer) | `NEXTVAL` from `seq_RowNum` |

**Target** `tgt_LANDING_RAW`
- Connection `SQL_MATMAS`, object `MATMAS.LANDING_RAW`, operation Insert.
- Field mapping: Automatic / Smart match (`o_BATCH_ID→BATCH_ID`, `o_SRC_ROW_NUM→SRC_ROW_NUM`, `COLnn→COLnn`). Leave `LANDING_ID`, `LOAD_TS`, `LOAD_STATUS` unmapped (defaults).
- Advanced: Truncate target = No, Update override: none.

---

## 3. Mapping `m_MATMAS_EXEC_SQL`  (calls `MATMAS.sp_MATMAS_Run`, returns one row)

**Parameters** (all String, In-Out, Override at runtime = Yes):

| Name | Default (used at design time to import the result metadata) |
|---|---|
| `$$STAGE` | `GET_IN_ROUTE` |
| `$$RUN_GROUP` | `DAILY` |
| `$$ITERATION` | `1` |
| `$$BATCH_ID` | `00000000000000` |
| `$$INTEGRATION_ID` | *(empty)* |
| `$$ROWS_READ` | `0` |
| `$$ROWS_LOADED` | `0` |
| `$$MESSAGE` | *(empty)* |

Output in-out parameters (String, written by the Expression with SetVariable):
`$$OUT_STATUS`, `$$OUT_MESSAGE`, `$$OUT_INTEGRATION_ID`, `$$OUT_SOURCE_SYSTEM`, `$$OUT_SRC_CONN`, `$$OUT_SRC_OBJECT`, `$$OUT_SRC_FOLDER`, `$$OUT_ARC_FOLDER`, `$$OUT_TGT_CONN`, `$$OUT_TGT_OBJECT`, `$$OUT_TGT_TYPE`, `$$OUT_TOTAL_ROUTES`, `$$OUT_ROWS_READ`, `$$OUT_ROWS_INSERTED`, `$$OUT_ROWS_UPDATED`, `$$OUT_ROWS_REJECTED`.

**Source** `src_RunProc`
- Connection `SQL_MATMAS`, Source type: **Query**, query:

```sql
SET NOCOUNT ON;
EXEC MATMAS.sp_MATMAS_Run
     @Stage         = '$$STAGE',
     @BatchId       = '$$BATCH_ID',
     @RunGroup      = '$$RUN_GROUP',
     @Iteration     = $$ITERATION,
     @IntegrationId = '$$INTEGRATION_ID',
     @RowsRead      = $$ROWS_READ,
     @RowsLoaded    = $$ROWS_LOADED,
     @Message       = '$$MESSAGE'
```

- Click "Validate / Select fields": with the defaults the proc returns the 16 columns `STATUS … ROWS_REJECTED`. If your connector version refuses `EXEC` in a custom query, use a SQL transformation (type: SQL query, same text, "Query has output ports" = yes) fed by a one-row dummy source `SELECT 1 AS DUMMY`.

**Expression** `exp_SetOut`: one variable port per output, e.g.

| Variable port | Expression |
|---|---|
| `v_STATUS` | `SetVariable($$OUT_STATUS, STATUS)` |
| `v_MESSAGE` | `SetVariable($$OUT_MESSAGE, MESSAGE)` |
| `v_INTEGRATION_ID` | `SetVariable($$OUT_INTEGRATION_ID, INTEGRATION_ID)` |
| `v_SRC_CONN` | `SetVariable($$OUT_SRC_CONN, SOURCE_CONNECTION)` |
| `v_SRC_OBJECT` | `SetVariable($$OUT_SRC_OBJECT, SOURCE_OBJECT)` |
| `v_SRC_FOLDER` | `SetVariable($$OUT_SRC_FOLDER, SOURCE_FOLDER)` |
| `v_ARC_FOLDER` | `SetVariable($$OUT_ARC_FOLDER, ARCHIVE_FOLDER)` |
| `v_TGT_CONN` | `SetVariable($$OUT_TGT_CONN, TARGET_CONNECTION)` |
| `v_TGT_OBJECT` | `SetVariable($$OUT_TGT_OBJECT, TARGET_OBJECT)` |
| `v_TGT_TYPE` | `SetVariable($$OUT_TGT_TYPE, TARGET_TYPE)` |
| `v_TOTAL` | `SetVariable($$OUT_TOTAL_ROUTES, TO_CHAR(TOTAL_ROUTES))` |
| `v_ROWS_*` | `SetVariable($$OUT_ROWS_READ, TO_CHAR(ROWS_READ))` etc. |

Plus pass-through output ports for all 16 columns and `o_STAGE = $$STAGE`, `o_ITERATION = TO_INTEGER($$ITERATION)`, `o_BATCH_ID = $$BATCH_ID`.

**Target** `tgt_STEP_RESULT`: `SQL_MATMAS` / `MATMAS.CTL_STEP_RESULT`, Insert, map by name (`o_STAGE→STAGE`, `o_ITERATION→ITERATION`, `o_BATCH_ID→BATCH_ID`, rest by name). This gives you a full trace of every taskflow step.

---

## 4. Mapping tasks

| Task | Mapping | Settings |
|---|---|---|
| `mt_MATMAS_LAND_FILE` | `m_MATMAS_LAND_FILE` | Runtime env: Secure Agent group. In-Out parameters: all "Allow override". Connection/object parameters: "Allow parameter to be overridden at run time" = Yes. Error handling: Stop on errors = 1. Optional parameter file for stand-alone tests: `cdi/param/mt_MATMAS_LAND_FILE.param` (copy to `<agent>/apps/Data_Integration_Server/data/userparameters/`). |
| `mt_MATMAS_EXEC_SQL` | `m_MATMAS_EXEC_SQL` | Same. In-Out params: "Allow override" on all `$$STAGE…$$MESSAGE`. The `$$OUT_*` parameters appear automatically as output fields of the Data Task in the taskflow. |

---

## 5. Taskflow `tf_MATMAS_ORCHESTRATOR`

**Input fields**: `RUN_GROUP` (text, default `DAILY`), `INTEGRATION_ID` (text, default empty: run a single route when set).
**Temp fields**: `BATCH_ID` (text), `I` (integer), `TOTAL` (integer), `ROUTE_ID`, `SRC_CONN`, `SRC_OBJECT`, `SRC_FOLDER`, `ARC_FOLDER`, `TGT_TYPE`, `STATUS`, `MSG` (text), `ROWS_READ`, `ROWS_LOADED` (integer).

Steps in order (step names are what you type in the designer):

| # | Step | Type | What to set |
|---|---|---|---|
| 1 | `Init` | Assignment | `BATCH_ID = fn:replace(fn:replace(fn:replace(string(fn:current-dateTime()), '-', ''), ':', ''), 'T', '')` then keep first 14 chars with `substring(…, 1, 14)`; `I = 1` |
| 2 | `GetInRoute` | Data Task → `mt_MATMAS_EXEC_SQL` | Input overrides: `STAGE = 'GET_IN_ROUTE'`, `RUN_GROUP = $input.RUN_GROUP`, `ITERATION = $temp.I`, `INTEGRATION_ID = $input.INTEGRATION_ID`. In **Fields**, map outputs: `OUT_STATUS→$temp.STATUS`, `OUT_INTEGRATION_ID→ROUTE_ID`, `OUT_SRC_CONN→SRC_CONN`, `OUT_SRC_OBJECT→SRC_OBJECT`, `OUT_SRC_FOLDER→SRC_FOLDER`, `OUT_ARC_FOLDER→ARC_FOLDER`, `OUT_TOTAL_ROUTES→TOTAL` (use the Fields pane picker, it writes the correct `$…` reference). |
| 3 | `AnyInbound?` | Decision on `$temp.STATUS` | `= 'NONE'` → go to step 10 (`OutInit`); otherwise continue. |
| 4 | `LandStart` | Data Task → `mt_MATMAS_EXEC_SQL` | `STAGE='LAND_START'`, `BATCH_ID=$temp.BATCH_ID`, `INTEGRATION_ID=$temp.ROUTE_ID` |
| 5 | `Land` | Data Task → `mt_MATMAS_LAND_FILE` | Input overrides: connection parameter `SRC_CONN = $temp.SRC_CONN` (type the connection **name**), `SRC_OBJECT = $temp.SRC_OBJECT`, `BATCH_ID`, `INTEGRATION_ID = $temp.ROUTE_ID`. Error handling: **Custom** → on error go to `Fail`. Map outputs `Success Source Rows→$temp.ROWS_READ`, `Success Target Rows→$temp.ROWS_LOADED`. |
| 6 | `LandEnd` | Data Task → `mt_MATMAS_EXEC_SQL` | `STAGE='LAND_END'`, `ROWS_READ=$temp.ROWS_READ`, `ROWS_LOADED=$temp.ROWS_LOADED`, batch + route as above |
| 7 | `Harmonize` | Data Task → `mt_MATMAS_EXEC_SQL` | `STAGE='HARMONIZE'`, batch + route. Map `OUT_STATUS→$temp.STATUS`, `OUT_MESSAGE→$temp.MSG`. |
| 7a | `HarmonizeOK?` | Decision on `$temp.STATUS` | `= 'OK'` → step 8; else → `Notify` (stage already logged FAILED by SQL) then step 9 |
| 8 | `Archive` | Command Task | Script `C:\Informatica\SecureAgent\MATMAS\scripts\archive_file.cmd`, arguments: `"$temp.SRC_FOLDER" "$temp.SRC_OBJECT" "$temp.ARC_FOLDER" "$temp.BATCH_ID"`. Error handling: ignore (archiving must not fail the run). |
| 9 | `NextIn` | Assignment | `I = $temp.I + 1` |
| 9a | `MoreIn?` | Decision | `$temp.I <= $temp.TOTAL` → **Jump** to step 2 `GetInRoute`; else continue |
| 10 | `OutInit` | Assignment | `I = 1` |
| 11 | `GetOutRoute` | Data Task → `mt_MATMAS_EXEC_SQL` | `STAGE='GET_OUT_ROUTE'`, `ITERATION=$temp.I`, `RUN_GROUP`, `INTEGRATION_ID=$input.INTEGRATION_ID`. Map `OUT_STATUS`, `OUT_INTEGRATION_ID→ROUTE_ID`, `OUT_TGT_TYPE→TGT_TYPE`, `OUT_TOTAL_ROUTES→TOTAL`. |
| 12 | `AnyOutbound?` | Decision on `$temp.STATUS` | `= 'NONE'` → `End` |
| 13 | `TargetType?` | Decision on `$temp.TGT_TYPE` | `= 'TABLE'` → step 14; `= 'FILE'` → (future) Data Task `mt_MATMAS_PUBLISH_FILE` + Command task SFTP; `= 'IDOC'`/`'API'` → (future) protocol mapping |
| 14 | `Publish` | Data Task → `mt_MATMAS_EXEC_SQL` | `STAGE='PUBLISH'`, batch + route. Map `OUT_STATUS`, `OUT_MESSAGE`. On `FAILED` → `Notify`. |
| 15 | `NextOut` | Assignment + Decision | `I = $temp.I + 1`; `$temp.I <= $temp.TOTAL` → Jump to step 11 |
| 16 | `End` | End | |
| F | `Fail` | Data Task → `mt_MATMAS_EXEC_SQL` | `STAGE='FAIL'`, `MESSAGE = $temp.MSG` (or the error text from the failed task's output), batch + route; then `Notify` (Notification Task, e-mail from `CTL_PARAMETER NOTIFY_EMAIL`), then **continue to step 9** so one bad file never blocks the other ERPs. |

Notes
- A Data Task's overridable connection parameter takes the connection **name** as a string. That is how one `mt_MATMAS_LAND_FILE` reads from `FF_MATMAS_JDE` in iteration 1 and `FF_MATMAS_VISION` in iteration 2.
- Jump steps make the loop. There is no native "for each" step in taskflows; this is the supported pattern.
- Schedule: Taskflow → Schedule, daily. Or trigger from a **File Listener** on the inbound folder and pass the listener's file name into `INTEGRATION_ID` after a small lookup (later).
- Re-run one route by hand: run the taskflow with `INTEGRATION_ID = IN_JDE_MATMAS_FILE`.

---

## 6. Test plan (in order)

1. `sql/04_test_without_cdi.sql` → 3 rows in `MATERIAL_MASTER_TARGET`, 1 reject (`INVALID START_DATE` for V-20002), exact duplicate of 109589 collapsed.
2. `TRUNCATE` `LANDING_RAW`, `MATERIAL_MASTER`, `MATERIAL_MASTER_REJECT`, `MATERIAL_MASTER_OUTBOUND`, `MATERIAL_MASTER_TARGET`, `CTL_BATCH_RUN`, `CTL_STEP_RESULT` and run `mt_MATMAS_LAND_FILE` alone with the parameter file → 3 rows in `LANDING_RAW` for the JDE batch, row 1 = header.
3. Run `mt_MATMAS_EXEC_SQL` alone (defaults) → one row in `CTL_STEP_RESULT` with `STATUS = OK`, `INTEGRATION_ID = IN_JDE_MATMAS_FILE`, `TOTAL_ROUTES = 2`.
4. Run `tf_MATMAS_ORCHESTRATOR` → check `CTL_BATCH_RUN` (LAND, HARMONIZE × 2 routes, PUBLISH), `CTL_STEP_RESULT` trace, files moved to `archive\`.
5. Change a description in `JDE_MATMAS.txt`, re-run → one closed version + one new version in `MATERIAL_MASTER`, target reloaded.

---

## 7. Adding ERP "XYZ" later (no CDI change)

1. Folder `MATMAS\inbound\XYZ`, flat-file connection `FF_MATMAS_XYZ`.
2. `INSERT INTO MATMAS.CTL_SOURCE_SYSTEM`.
3. `INSERT INTO MATMAS.CTL_INBOUND_INTEGRATION` (`SOURCE_CONNECTION='FF_MATMAS_XYZ'`, `SOURCE_OBJECT='XYZ_MATMAS.txt'`, `EXPECTED_HEADER` = its header line).
4. `INSERT INTO MATMAS.CTL_FIELD_MAPPING` rows `COLnn → canonical`.
5. Optional view `MATMAS.MATERIAL_MASTER_XYZ` over `LANDING_RAW` for the business.
6. Drop the file, run the taskflow with `INTEGRATION_ID='IN_XYZ_MATMAS_FILE'`.
