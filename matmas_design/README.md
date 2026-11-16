# MATMAS – generalized Material Master integration (Informatica CDI + SQL database in Fabric)

One pipeline for every ERP. Files from JDE, Vision and any future ERP land through one CDI run. They are routed by folder name and harmonized by rules stored in control tables. The result is published to `MATMAS.MATERIAL_MASTER_TARGET` in the same format as the JDE details, plus Start Date and End Date.

| Path | What it is |
|---|---|
| `01_MATMAS_Design.md` | Design: architecture, schema inventory, walk-through of the sample, onboarding a new ERP |
| `sql/00_drop_all.sql` | DEV only: drops everything in schema MATMAS for a clean re-install |
| `sql/01_schema_and_tables.sql` | Schema MATMAS: control, landing, canonical SCD2, reject, outbound log, target, monitoring views, and CDI interface views in `stg` |
| `sql/02_procedures.sql` | `sp_MATMAS_Process` (entry point), `sp_MATMAS_Assign`, `sp_Harmonize`, `sp_Publish`, `sp_MATMAS_Reprocess` |
| `sql/03_seed_config.sql` | JDE and Vision routes with field mappings, and the outbound route to the target table |
| `sql/04_test_without_cdi.sql` | End-to-end test of the SQL side with the two sample files, expected results in comments |
| `cdi/import/MATMAS_CDI_Import.zip` | **Import package** with mapping `m_MATMAS_PROCESS` for your org (project `zPF_TCS_Shubham`, connection `jdbcv2.MSSQL.sqldb-p2o-intg.stg`) |
| `cdi/CDI_Build_Guide.md` | Import steps, build of `m_MATMAS_LAND`, mapping tasks, taskflow, test plan, phase 2 (Vision IDoc) |
| `cdi/tools/build_cdi_package.py` | Regenerates the import package, modeled on your export `Mapping58-1794813874687.zip` |
| `secure_agent/MATMAS/` | Folder tree for the Secure Agent: `inbound/JDE`, `inbound/VISION` with sample files, `work`, `design`, `archive`, `error`, `outbound`, `scripts` |

Run order:

1. On the Fabric SQL database, run `sql/01`, then `sql/02`, then `sql/03`.
2. Run `sql/04` to prove the SQL side.
3. Copy `secure_agent/MATMAS` to the agent at `C:\Informatica\SecureAgent\MATMAS`.
4. Import `cdi/import/MATMAS_CDI_Import.zip`, keeping the existing connection.
5. Build `m_MATMAS_LAND`, the two mapping tasks and the taskflow using the guide.
6. Run the taskflow.

What was verified here:
- The import package checksums verify, and its structure matches your export object for object.
- The T-SQL parses, apart from constructs the parser does not support, such as `THROW` and `+=`.
- The SQL that the procedures generate from the seed rows parses.
- The Linux agent scripts ran end to end.

What was not verified here:
- The SQL was not executed, because no SQL Server is available in this workspace.
- The import has not been tried in IDMC.

Send any error message and it will be fixed.
