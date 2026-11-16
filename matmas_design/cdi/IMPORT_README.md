# MATMAS – import in two parts

The full zip failed with *"One or more objects are missing required dependent objects"*. The import did not recognize the two generated file ingestion tasks, so the taskflow lost its dependencies. The import therefore runs in two parts.

## Part 1: mappings and mapping tasks (import now)

1. Import `cdi/import/MATMAS_CDI_Import_Part1_Mappings.zip`. It contains the 4 mappings and the 4 mapping tasks, all of which showed **Create object** (green) in your last attempt. It also contains their connections and agent groups, which the import never overwrites.
2. If the import asks you to map `FABRIC.AMCOR.ONELAKE.P2O` or `jdbcv2.MSSQL.sqldb-p2o-intg.stg`, select your existing connection.

## Create the 2 file ingestion tasks (about 5 minutes)

In Explore, open `fi_P2O_000_BPDWFS_PO_to_OneLake`, then use **Copy** twice. Name the copies exactly as shown, because the taskflow refers to these names.

| Setting | `fi_P2O_100_MATMAS_Agent_to_OneLake` | `fi_P2O_101_MATMAS_OneLake_Move` |
|---|---|---|
| Runtime environment | `US.US02.01`. The taskflow overrides it per route. | `US.US02.01` |
| Source | **Local folder**, directory `D:\Interfaces\JDE\MATMAS\outbound`, pattern `JDE_MATMAS*.txt`. Overridden per route. | **Microsoft Fabric OneLake** `FABRIC.AMCOR.ONELAKE.P2O`, folder `/lh_p2o_intg_dev/Files/erp_to_matmas/landing/JDE`, pattern `*` |
| After transfer | **Delete** source files | **Delete** source files |
| Target | `FABRIC.AMCOR.ONELAKE.P2O`, location `/lh_p2o_intg_dev/Files/erp_to_matmas/landing/JDE` | `FABRIC.AMCOR.ONELAKE.P2O`, location `/lh_p2o_intg_dev/Files/erp_to_matmas/archive/JDE` |
| If file exists | Overwrite | Overwrite |
| Schedule / file listener | None | None |

The folders above are only defaults. The taskflow overrides them on every run from `cfg.matmas_route_config`.

## Part 2: the taskflow

1. In Explore, select the two new tasks, then **Export**. Including dependencies is fine.
2. Send me that export zip. Its contents list holds both task IDs.
3. I regenerate the taskflow pointing at your two tasks, using this command:
   ```
   python3 cdi/tools/build_matmas_import.py --fi-collect <id of fi_P2O_100> --fi-move <id of fi_P2O_101> --out cdi/import/MATMAS_CDI_Import_Part2_Taskflow.zip
   ```
4. Import `MATMAS_CDI_Import_Part2_Taskflow.zip`. It also contains the Part 1 objects, which show as existing. Leave the overwrite option on.

The same export also contains the real ID of the OneLake connection, which removes that placeholder too.

---

## Reference: the full flow and checks

## The flow

For each row of `cfg.matmas_route_config`, the taskflow does the following.

1. **Read the row.** `mt_P2O_101_MATMAS_Route_Reader` returns the agent group, source folder, file pattern, OneLake folders, target table and operation.
2. **Collect.** `fi_P2O_100_MATMAS_Agent_to_OneLake` runs on the row's Secure Agent. It copies `<source folder>/<pattern>` to `erp_to_matmas/landing/<ERP>/<RUN_ID>` in OneLake, then **deletes the file on the agent**. The copy is kept in OneLake.
3. **Check for files.** If nothing was found, it logs `NO_FILE` and moves to the next row.
4. **Load.** `mt_P2O_102_MATMAS_Load` reads the run folder in OneLake, adds Start Date and End Date to the 6 fields, and writes the stage. Its Post SQL applies the rows to `matmas.<erp>_material_master` with the row's operation.
5. **Decide the outcome.** `mt_P2O_103_MATMAS_Outcome` returns ARCHIVE, DUPLICATE or ERROR.
6. **Move.** `fi_P2O_101_MATMAS_OneLake_Move` moves `landing/<ERP>/<RUN_ID>` to `archive`, `duplicate` or `error/<ERP>/<RUN_ID>`.

Every source and target comes from the config table and settings. The file ingestion steps move all the files.

## What is inside

| Object | Type |
|---|---|
| `tf_P2O_100_MATMAS_Orchestrator` | Taskflow |
| `fi_P2O_100_MATMAS_Agent_to_OneLake`, `fi_P2O_101_MATMAS_OneLake_Move` | File ingestion tasks |
| `m_/mt_P2O_101_MATMAS_Route_Reader`, `_102_MATMAS_Load`, `_103_MATMAS_Outcome`, `_104_MATMAS_Log` | 4 mappings and 4 mapping tasks |

The package also contains the connections `jdbcv2.MSSQL.sqldb-p2o-intg.stg` and `FABRIC.AMCOR.ONELAKE.P2O` and the agent groups `US.US02.01` and `US.AMCOR.01`, the same way your own exports ship dependencies. The import option *"Overwrite existing assets, excluding connections and runtime environments"* never overwrites them. They are there only so that every reference resolves. On the import screen, map each one to the existing connection or agent group if you are asked.

## How it was built

The structure of each object is copied from real IDMC exports:
- **Your org's export `Mapping58`.**
- **A public IDMC export** in the GitHub repository `dheeraj2112/ETL_INFA_IICS_Snowflake_Project`. It supplied the mappings, mapping tasks, Expression and Filter transformations, and in-out parameters.
- **Public IDMC source-control repositories.** They supplied file ingestion tasks with Microsoft Fabric OneLake as source and target, including the delete-after-transfer option. They also supplied taskflow steps: decision, jump, assignment, a Data Task with in-out parameters, and Ingestion Task overrides.

Checks run on the package:
- All checksums verify.
- All internal references in each mapping resolve.
- Each set of properties matches a real object of the same type.
- Every taskflow link points to an existing step.

## Import steps

1. **Database.** Run `sql/01_tables.sql`, `sql/02_procedures.sql` and `sql/03_seed_config.sql`. Fill in the real agent groups, source folders and patterns in `cfg.matmas_route_config`.
2. **Lakehouse `lh_p2o_intg_dev`.** Upload `samples/JDE/JDE_MATMAS_20261116.txt` to `Files/erp_to_matmas/landing/JDE/_design/`. It is the design file of the load mapping.
3. **Import.** In IDMC, go to Explore, then Import, and select `MATMAS_CDI_Import.zip`. Import all objects into `zPF_TCS_Shubham`.
4. **If the import still reports errors**, scroll the Select Assets table to the right to the **Status** column and hover over each red status for its message. Send me those messages.
5. **Post-import checklist.** It takes about 10 minutes and is described below.
6. **Run.** Publish `tf_P2O_100_MATMAS_Orchestrator`, run it once with `RUN_GROUP = DAILY`, then schedule it.

## Post-import checklist

These settings have no public sample, so check each one once.

1. **The load mapping's OneLake source.** No public export contains a mapping that reads OneLake. Open `m_P2O_102_MATMAS_Load`, select the source `src_OneLakeFiles`, and set:
   - Connection `FABRIC.AMCOR.ONELAKE.P2O`. Object: the design file uploaded in import step 2.
   - Formatting: delimited, delimiter `|`, no text qualifier, column names from the first line.
   - Read the whole folder, using source type Directory or your connector's equivalent. Set the folder or directory override to **`$$SRC_DIRECTORY`**. The taskflow fills it with `landing/<ERP>/<RUN_ID>`.
   - The six source fields should be named `ERP_Item_Number`, `Material_Description`, `Plant_Code`, `Supplier_Part_`, `Supplier_Number` and `Manufacturing_Part_`. The target `tgt_Stage` maps them by hand (field mapping Manual) to the lower-case columns of `stg.matmas_stage_file`: `erp_item_number`, `material_description`, `plant_code`, `supplier_part_number`, `supplier_number`, `manufacturing_part_number`. If CDI names the source fields differently, fix those links on the target's Field Mapping tab.
2. **The OneLake connection in both `fi_P2O_*` tasks.** If the source or target shows no connection, select `FABRIC.AMCOR.ONELAKE.P2O`.
   - Alternatively, export `fi_P2O_000_BPDWFS_PO_to_OneLake` and send it to me. I'll regenerate the package with the connection's real IDs so this step goes away.
3. **OneLake path format.** Compare the target location `/lh_p2o_intg_dev/Files/erp_to_matmas/landing/JDE` in `fi_P2O_100` with the format used in `fi_P2O_000_BPDWFS_PO_to_OneLake`. If the format differs, change the `onelake_root` row in `cfg.matmas_setting`.
4. **Ingestion step overrides.** In the taskflow, check the Input Fields of each ingestion step:
   - `IT_Collect`: Runtime Environment, Source Directory, File Pattern, OneLake target location.
   - `IT_Move`: Source Directory, OneLake target location.

   If one shows as missing, add it again from the drop-down with the formula listed in `CDI_Build_Guide.md`, section 9.
5. **Validate and publish.** Validate the 4 mappings and the taskflow, then publish.

## Check a run

```sql
SELECT * FROM matmas.v_run_status ORDER BY run_id DESC, route_id;
SELECT * FROM matmas.jde_material_master;
SELECT * FROM matmas.material_master_reject ORDER BY reject_id DESC;
```

A healthy route produces the trail `STARTED` → `LOADED` → `OUTCOME`. The files then sit in `erp_to_matmas/archive/<ERP>/<RUN_ID>`, and the agent folder is empty.
