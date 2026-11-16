# MATMAS – Informatica CDI guide (import + build)

The whole CDI side is **2 mappings, 2 mapping tasks, 1 taskflow**. None of them is ERP specific. A new ERP is a new folder plus rows in the control tables.

| Object | How you get it | What it does |
|---|---|---|
| `m_MATMAS_PROCESS` | **Import** `cdi/import/MATMAS_CDI_Import.zip` | Inserts one run request through `stg.MATMAS_RUN_REQUEST`. Its target Post SQL runs `EXEC MATMAS.sp_MATMAS_Process`: route files, harmonize, history, publish |
| `m_MATMAS_LAND` | Build (2 transformations, about 10 minutes) | Reads **every file in every ERP folder** in one run (indirect file list) into `stg.MATMAS_LANDING_RAW` |
| `mt_MATMAS_LAND` | Create on the mapping | Pre-processing command builds the file list |
| `mt_MATMAS_PROCESS` | Create on the mapping | Post-processing command archives the processed files |
| `tf_MATMAS_DAILY` | Create (2 Data Tasks) | Runs land, then process. Schedule it |

How the import package was made: it follows the exact structure of your export `Mapping58-1794813874687.zip`. That covers the manifest, the SHA-256 checksum file, the DTEMPLATE zip and the class table. It reuses your JDBC V2 connection `jdbcv2.MSSQL.sqldb-p2o-intg.stg` (GUID `1AIvTtPhmimhpwYPfj4G2j`) on runtime environment `US.US02.01`. It is regenerated with `cdi/tools/build_cdi_package.py`.

The land mapping is not in the package. A flat-file source stores its format in a separate file-format object that your reference export does not contain, and a guessed one would not import. Export any small flat-file mapping from your org and send it to me, and the land mapping will be added to the package the same way.

---

## 0. Prerequisites

1. Run on the Fabric SQL database, in order: `sql/01_schema_and_tables.sql`, `sql/02_procedures.sql`, `sql/03_seed_config.sql`.
   If `STRING_SPLIT(..., 1)` errors, raise the compatibility level once: `ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 160;`
2. Run `sql/04_test_without_cdi.sql`. It must end with run status `SUCCESS`, 3 rows in `MATMAS.MATERIAL_MASTER_TARGET` and 1 reject. This proves the SQL side before CDI is involved.
3. The service principal used by the JDBC V2 connection needs on the database: `SELECT, INSERT` on schema `stg`, and `EXECUTE` on schema `MATMAS`. The procedures run with the owner's rights for the tables they touch (ownership chaining inside schema MATMAS), but if your schemas have different owners also grant `SELECT, INSERT, UPDATE, DELETE` on schema `MATMAS`. `sp_Publish` truncates the target table, which needs `ALTER` on that table.
4. Copy `secure_agent/MATMAS` to the Secure Agent machine of runtime environment `US.US02.01`. Default path used everywhere: `C:\Informatica\SecureAgent\MATMAS`. The agent service account needs read/write there.

---

## 1. Import `m_MATMAS_PROCESS`

1. Data Integration → **Explore** → **Import** → select `cdi/import/MATMAS_CDI_Import.zip`.
2. Objects listed: `m_MATMAS_PROCESS` (mapping, project `zPF_TCS_Shubham`), connection `jdbcv2.MSSQL.sqldb-p2o-intg.stg`, runtime environment `US.US02.01`, project `zPF_TCS_Shubham`.
3. **Do not overwrite the connection or the runtime environment.** Choose the existing ones, or deselect them. The connection in the package has no password on purpose, so overwriting it would blank the password in your org.
4. Import. Open `m_MATMAS_PROCESS` and click **Validate**.
5. Check the target: Target → **Advanced** → *Post SQL* = `EXEC MATMAS.sp_MATMAS_Process`.

If the import reports an error, send me the exact message. The package is generated, so a fix is a re-run of the script.

Manual equivalent, if you prefer to build it:

- **Source**: connection `jdbcv2.MSSQL.sqldb-p2o-intg.stg`, single object `MATMAS_RUN_REQUEST_SRC` (a view in schema `stg`).
- **Target**: same connection, existing object `MATMAS_RUN_REQUEST`, operation Insert, field mapping Automatic.
- Target **Advanced → Post SQL**: `EXEC MATMAS.sp_MATMAS_Process`.

---

## 2. Connection for the files: `FF_MATMAS`

Administrator → Connections → New:

| Property | Value |
|---|---|
| Name | `FF_MATMAS` |
| Type | Flat File |
| Runtime environment | `US.US02.01` |
| Directory | `C:\Informatica\SecureAgent\MATMAS\work` |
| Date format | default |
| Code page | UTF-8 |

Only one file connection is needed for all ERPs. It points at the `work` folder, where the file list lives. The list holds full paths into `inbound\JDE`, `inbound\VISION` and any future ERP folder.

---

## 3. Build `m_MATMAS_LAND`

New mapping `m_MATMAS_LAND` in project `zPF_TCS_Shubham`.

**Source**
- Connection: `FF_MATMAS`.
- Source type: **File List** (indirect). Object: `matmas_filelist.txt`.
  The shipped `work\matmas_filelist.txt` points at `design\LANDING_TEMPLATE.txt`, which has 30 columns. This makes the designer create 30 fields. At run time the pre-processing command overwrites the list with the real files.
- Formatting options: Delimited, delimiter `|`, text qualifier **None**, **Import column names from first line: off**, Rows to skip: 0, code page UTF-8.
  The header of every file is landed on purpose as row 1, and `sp_Harmonize` checks it against the expected header of the route.
- Fields: the designer names them `Field1 … Field30`, all string. Set precision to 1000 if it offers a smaller default.
- Advanced: tick **Add Currently Processed Flat File Name Field**. This creates field `CurrentlyProcessedFileName`, which holds the full path. SQL routes each file by the name of its parent folder.

**Target**
- Connection: `jdbcv2.MSSQL.sqldb-p2o-intg.stg`.
- Object: existing `MATMAS_LANDING_RAW`. This is a view in schema `stg` whose columns are named `CurrentlyProcessedFileName`, `Field1 … Field30`.
- Operation: Insert. Field mapping: **Automatic**. All 31 fields match by name.
- Advanced: Truncate target off, Pre/Post SQL empty.

Validate and save.

---

## 4. Mapping tasks

| Task | Mapping | Runtime env | Schedule tab |
|---|---|---|---|
| `mt_MATMAS_LAND` | `m_MATMAS_LAND` | `US.US02.01` | **Pre-processing command**: `C:\Informatica\SecureAgent\MATMAS\scripts\matmas_prepare_filelist.cmd C:\Informatica\SecureAgent\MATMAS` |
| `mt_MATMAS_PROCESS` | `m_MATMAS_PROCESS` | `US.US02.01` | **Post-processing command**: `C:\Informatica\SecureAgent\MATMAS\scripts\matmas_archive_files.cmd C:\Informatica\SecureAgent\MATMAS` |

On a Linux agent use the `.sh` scripts with the Linux path.

What the scripts do:
- **Prepare**: writes one line per `*.txt` and `*.csv` found in every sub-folder of `inbound`. If nothing is found, it lists an empty placeholder so the land task still succeeds with 0 rows.
- **Archive**: moves only the listed files to `archive\<ERP folder>\<name>_<timestamp>.<ext>`. Files that arrive during the run stay for the next run.

---

## 5. Taskflow `tf_MATMAS_DAILY`

New taskflow, two steps:

1. Data Task → `mt_MATMAS_LAND`. On error: **Stop**, because without landed data there is nothing to process.
2. Data Task → `mt_MATMAS_PROCESS`.
3. Optional Notification Task on failure, sent to the list in `MATMAS.CTL_PARAMETER` `NOTIFY_EMAIL`.

Publish and schedule it, for example daily. A *Linear Taskflow* with the two tasks works as well.

---

## 6. Run and check

```sql
-- outcome of the last runs (one row per route and stage)
SELECT * FROM MATMAS.V_MATMAS_RUN_STATUS ORDER BY RUN_ID DESC, STAGE;

-- the end table, same format as the JDE details
SELECT * FROM MATMAS.MATERIAL_MASTER_TARGET;

-- rejected rows with reason and raw record
SELECT * FROM MATMAS.MATERIAL_MASTER_REJECT ORDER BY REJECT_ID DESC;

-- re-run one batch after fixing configuration (no file needed, data is kept in landing)
EXEC MATMAS.sp_MATMAS_Reprocess @BatchId = '<BATCH_ID>';
```

`CTL_RUN_REQUEST.STATUS` values:

| Status | Meaning |
|---|---|
| `SUCCESS` | All files routed, all routes harmonized and published |
| `PARTIAL` | At least one step failed. The other routes still completed. Details are in `V_MATMAS_RUN_STATUS` |
| `FAILED` | Every step failed, or the procedure itself failed |
| `NO_DATA` | No files were found. Publish still ran |
| `REQUESTED` and never changes | The Post SQL did not run. Check the target's Advanced settings |

---

## 7. Test plan in CDI

1. Reset with the commented block D at the end of `sql/04_test_without_cdi.sql`.
2. Make sure `inbound\JDE\JDE_MATMAS.txt` and `inbound\VISION\VISION_MATMAS.txt` are on the agent.
3. Run `mt_MATMAS_LAND` alone. Expect 7 rows in `MATMAS.LANDING_RAW` with `LOAD_STATUS = NEW` and full file paths.
4. Run `mt_MATMAS_PROCESS` alone. Expect the same results as the SQL test, and both files moved to `archive`.
5. Run `tf_MATMAS_DAILY` with no files present. Expect run status `NO_DATA`.
6. Put a file with a wrong header in `inbound\JDE`. Expect `PARTIAL`, with a header-mismatch message on the JDE harmonize row while Vision still loads.

---

## 8. Phase 2: Vision through IDoc, and SAP targets

Your reference mapping shows that Vision is SAP and that this org already reads IDocs from it. It uses connection `0140.SAP.VISION.IP.IDOC` (SAP ALE IDoc Reader) and an IDoc Interpreter mapplet.

- **Vision material master through IDoc.** Generate an IDoc Interpreter mapplet for `MATMAS05` (or your extension) in the org, the same way `SAP IDoc Mapplet4` was made for `ZGRCOUPA01`. A mapping then writes the segments to segment tables in `stg`. Add a view per route that flattens the segments into the `COL01..` layout and a route row with `SOURCE_TYPE = 'IDOC'`. Harmonize, history and publish stay unchanged.
- **Publishing to SAP.** Add an outbound route with `TARGET_TYPE = 'IDOC'`. `sp_Publish` reports it as skipped, and a publish mapping with an IDoc Prepare mapplet sends `MATMAS` to SAP through the IDoc writer connection.
- **Moving to a share path.** Change the Directory of `FF_MATMAS` and the root path argument of the two commands. Nothing else changes.
