# MATMAS – config-driven Material Master ingestion (Informatica CDI + OneLake + Fabric SQL)

A scheduled cloud taskflow reads `MATMAS.CTL_MATMAS_ROUTE` row by row. For each row it copies the files from that row's Secure Agent folder into OneLake (`lh_p2o_intg_dev/Files/erp_to_matmas/landing/<ERP>`, connection `FABRIC.AMCOR.ONELAKE.P2O`) with one file ingestion task. It then loads them with one generic mapping, which adds Start Date and End Date to the 6 fields, into the ERP's own table, such as `MATMAS.JDE_MATERIAL_MASTER`. The operation comes from the config row. The collect task deletes the source file on the agent after copying it. The run folder in OneLake then moves to archive, duplicate or error.

| Path | What it is |
|---|---|
| `01_MATMAS_Design.md` | Requirements, flow, objects, config columns, sample walk-through, decisions |
| `cdi/import/MATMAS_CDI_Import_Part1_Mappings.zip` | **Import Part 1**: 4 mappings and 4 mapping tasks. Part 2, the taskflow, is generated once the 2 ingestion tasks exist. See `cdi/IMPORT_README.md` |
| `cdi/IMPORT_README.md` | Import steps and the 10-minute post-import checklist |
| `cdi/tools/build_matmas_import.py` | Regenerates the package. Every format is copied from real IDMC exports |
| `cdi/CDI_Build_Guide.md` | Every CDI object with parameters, expressions and the taskflow step table |
| `sql/01_tables.sql` | Config, run log, staging, reject, file history, ERP tables, views, `stg` interface views |
| `sql/02_procedures.sql` | Apply (insert, upsert, update, delete, truncate-insert), retry, logging |
| `sql/03_seed_config.sql` | JDE, Vision and SAP route rows. Replace the placeholder names |
| `sql/04_test_without_cdi.sql` | SQL-only test of upsert, duplicate file, reject and retry, with expected results |
| `sql/00_drop_all.sql` | DEV only: drops every object in schema MATMAS |
| `samples/` | 6-field test files for JDE, Vision and SAP |
| `fabric/nb_matmas_purge_landing.py` | Fabric notebook: removes copied run folders from `erp_to_matmas/landing` (only if the move task cannot delete) |

Run order:

1. On the Fabric SQL database, run `sql/01`, `sql/02` and `sql/03`, then fill in the real names.
2. Run `sql/04`.
3. Create the local folder connections, the 2 file ingestion tasks and the 4 mapping tasks from the guide.
4. Build the taskflow and schedule it.

Verification status:
- The SQL parses with a T-SQL parser. It has not been executed here, because no SQL Server is available.
- The import package was checked against real IDMC exports: checksums, internal references, property sets and taskflow links all verify. It has not been imported into IDMC yet. See `cdi/IMPORT_README.md` for the post-import checklist.
