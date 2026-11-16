# MATMAS – import package `cdi/import/MATMAS_CDI_Import.zip`

One zip with the whole CDI process for the material master. Import it into the Berry Global-Dev org, project `zPF_TCS_Shubham`.

## What is inside

| Object | Type | Purpose |
|---|---|---|
| `tf_P2O_100_MATMAS_Orchestrator` | Taskflow | Loops over `MATMAS.CTL_MATMAS_ROUTE` and runs everything below per route |
| `fi_P2O_100_MATMAS_Agent_to_OneLake` | File ingestion | The route's agent folder → `erp_to_matmas/landing/<ERP>/<RUN_ID>`. Runtime environment, folder and pattern come from the row. |
| `fi_P2O_101_MATMAS_OneLake_to_Work` | File ingestion | That run folder → `C:\Informatica\MATMAS\work\inbox` on the central agent |
| `fi_P2O_102_MATMAS_OneLake_Move` | File ingestion | Run folder → `archive`, `duplicate` or `error/<ERP>/<RUN_ID>`, then **deletes** it from landing |
| `m_/mt_P2O_101_MATMAS_Route_Reader` | Mapping + task | Config row N → in-out parameters for the taskflow. Logs STARTED. |
| `m_/mt_P2O_102_MATMAS_Load` | Mapping + task | Work-folder files → 6 fields plus START_DATE and END_DATE → stage. Post SQL applies to `MATMAS.<ERP>_MATERIAL_MASTER`. |
| `m_/mt_P2O_103_MATMAS_Outcome` | Mapping + task | ARCHIVE, DUPLICATE or ERROR for this run |
| `m_/mt_P2O_104_MATMAS_Log` | Mapping + task | Writes NO_FILE events |
| `FF_MATMAS_WORK` | Connection, new | Flat file connection to `C:\Informatica\MATMAS\work` on `US.US02.01` |

**Not inside, on purpose.** The existing connections `jdbcv2.MSSQL.sqldb-p2o-intg.stg` and `FABRIC.AMCOR.ONELAKE.P2O`, and the agent groups, are only *referenced*. An import can therefore never overwrite them.

## Why the files pass through a work folder

A mapping task runs on one fixed agent, while the files arrive on different agents. So the flow is:

1. The agent folder is copied to OneLake `landing`, using the row's runtime environment.
2. The run folder is copied to the central agent's work folder.
3. The load mapping reads it there as a standard flat file through a file list.
4. The run folder in OneLake is moved to `archive`, `duplicate` or `error`.

No local folder connections are needed on the source agents. The ingestion task reads the folder directly.

## How it was built

Every object follows the exact structure of real IDMC exports:
- **Your org's export `Mapping58`**: JDBC V2 target, connection references, org ids and agent groups.
- **A public IDMC export** on GitHub, repository `dheeraj2112/ETL_INFA_IICS_Snowflake_Project`. It provided mapping tasks, Expression and Filter transformations, in-out parameters and flat-file sources.
- **Public IDMC source-control repositories.** They provided file ingestion tasks, including one that reads and writes **Microsoft Fabric OneLake**. They also provided taskflows with decision, jump, assignment, Data Task with in-out parameters, Ingestion Task overrides, and a Command Task whose runtime environment comes from a field.

Checks run on the package:
- Every checksum verifies.
- Every internal reference in each mapping resolves, and no ID is duplicated.
- Every property set matches a real object of the same class.
- Every taskflow link points to an existing step, and every XML element type also appears in real taskflows.

## Import steps

1. **Database first.** Run `sql/01_tables.sql`, `sql/02_procedures.sql` and `sql/03_seed_config.sql`, then fill in the real agent groups, folders and patterns in `MATMAS.CTL_MATMAS_ROUTE`.
2. **Central agent (`US.US02.01`)**:
   - Create `C:\Informatica\MATMAS\work\inbox`.
   - Copy `agent_scripts/central/JDE_MATMAS_20261116.txt` to `C:\Informatica\MATMAS\work\`. The load mapping uses it as its design file.
   - Copy `agent_scripts/central/matmas_work.cmd` to `C:\Informatica\scripts\`.
3. **Source agents**: copy `agent_scripts/matmas_archive_source.cmd` and `.ps1` to `C:\Informatica\scripts\`.
4. **Import.** In IDMC go to Explore, then Import, and select `MATMAS_CDI_Import.zip`. Import all objects into `zPF_TCS_Shubham`.
5. **Post-import checklist**, about 10 minutes, see below.
6. Publish `tf_P2O_100_MATMAS_Orchestrator` and run it once with input `RUN_GROUP = DAILY`. Then schedule it.

## Post-import checklist

These points could not be verified from any public sample. Check each one once.

1. **OneLake connection in the three `fi_P2O_*` tasks.** Open each task. If the Source or Target shows no connection, select `FABRIC.AMCOR.ONELAKE.P2O` and save.
   - Alternatively, export `fi_P2O_000_BPDWFS_PO_to_OneLake` and send me the zip. It contains the connection's internal ids, and I'll regenerate the package so this step goes away:
     ```
     python3 cdi/tools/build_matmas_import.py --onelake-guid <id> --onelake-handle <handle>
     ```
2. **OneLake paths.** In `fi_P2O_100`, compare the Target location `/lh_p2o_intg_dev/Files/erp_to_matmas/landing/JDE` with the target path format in `fi_P2O_000_BPDWFS_PO_to_OneLake`. If the format differs, change `ONELAKE_ROOT` in `MATMAS.CTL_MATMAS_SETTING`. The taskflow takes the paths from there.
3. **Ingestion step overrides.** Open the taskflow, click `IT_Collect` and look at **Input Fields**.
   - Expected: Runtime Environment, Source Directory, File Pattern and the OneLake target location, all mapped from temp fields.
   - If any shows as missing or red, remove it and add it again from the drop-down with the same formula. The formulas are listed in `CDI_Build_Guide.md`, section 9.
   - Do the same for `IT_ToWork` (Source Directory) and `IT_Move` (Source Directory, Target location).
4. **Command tasks.** `CT_PrepWork` and `CT_ListWork` run on `'US.US02.01'`. `CT_ArchiveSource` uses the row's runtime environment. Confirm the script paths `C:\Informatica\scripts\...` exist on those agents.
5. **Load mapping source.** Open `mt_P2O_102_MATMAS_Load`, Source:
   - It should show connection `FF_MATMAS_WORK`, object `matmas_filelist.txt`, source type **File list**, delimiter `|` and header line 1.
   - If the fields don't show, re-select `JDE_MATMAS_20261116.txt` in the mapping, then switch the task back to the file list.
6. Validate all four mappings and the taskflow, then publish the taskflow.

## Run and check

```sql
SELECT * FROM MATMAS.V_MATMAS_RUN_STATUS ORDER BY RUN_ID DESC, ROUTE_ID;   -- last event per route
SELECT * FROM MATMAS.JDE_MATERIAL_MASTER;                                  -- loaded data
SELECT * FROM MATMAS.MATERIAL_MASTER_REJECT ORDER BY REJECT_ID DESC;       -- rejected rows
```

A healthy route produces this event trail: `STARTED` → `LOADED` → `OUTCOME`. The OneLake run folder then sits in `archive/<ERP>/<RUN_ID>`, and the source file is in the agent archive folder.
