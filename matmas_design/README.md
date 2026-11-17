# MATMAS – config-driven Material Master ingestion (IDMC + OneLake + Fabric notebook + Fabric SQL)

**Current design: hybrid (v2.0).** IDMC only collects: `tf_P2O_110_MATMAS_Collect` reads `cfg.matmas_route_config` row by row and copies each route's source files into OneLake (`lh_p2o_intg_dev/Files/erp_to_matmas/landing/<ERP>/<RUN_ID>/`, connection `FABRIC.AMCOR.ONELAKE.P2O`), deleting them at the source. The Fabric notebook `nb_matmas_process` does the rest: it reads the 6 fields, adds Start Date and End Date, applies them with the route's operation into the ERP's own table (such as `matmas.jde_material_master`) through `matmas.sp_apply_route`, writes the audit, and moves the run folder to archive, duplicate or error. See `02_MATMAS_Hybrid.md`.

| Path | What it is |
|---|---|
| `02_MATMAS_Hybrid.md` | **Current design**: flow, objects, notebook behaviour, set-up, test, and what changes when the source becomes a share path or SFTP |
| `cdi/import/MATMAS_CDI_Collect_Only.zip` | **IDMC import (current)**: `tf_P2O_110_MATMAS_Collect`, `fi_P2O_100`, `mt_P2O_101` (reader), `mt_P2O_104` (log) |
| `fabric/nb_matmas_process.ipynb` | **Fabric notebook (current)**: import into `ws_p2o_intg_dev`. Source in `fabric/nb_matmas_process.py` |
| `fabric/tools/py_to_fabric_ipynb.py` | Rebuilds the `.ipynb` from the `.py` source with the team's Fabric notebook metadata |
| `cdi/tools/build_matmas_import.py` | Regenerates the IDMC packages (`--collect-only` for the current one). Every format is copied from real IDMC exports |
| `sql/01_tables.sql` | Config, run log, staging, reject, file history, ERP tables, views, `stg` interface views |
| `sql/02_procedures.sql` | Apply (insert, upsert, update, delete, truncate-insert), retry, logging |
| `sql/03_seed_config.sql` | JDE, Vision and SAP route rows. Replace the placeholder names |
| `sql/04_test_without_cdi.sql` | SQL-only test of upsert, duplicate file, reject and retry, with expected results |
| `sql/00_drop_all.sql` | DEV only: drops every MATMAS object |
| `samples/` | 6-field test files for JDE, Vision and SAP |
| `01_MATMAS_Design.md`, `cdi/IMPORT_README.md`, `cdi/CDI_Build_Guide.md`, `cdi/import/MATMAS_CDI_Import_Full.zip`, `..._Part1_Mappings.zip` | Earlier all-IDMC design (load in IDMC mappings). Kept for reference |

Run order:

1. On the Fabric SQL database, run `sql/01`, `sql/02` and `sql/03`, then fill in the real names. If an earlier version with upper-case names (`MATMAS.CTL_MATMAS_ROUTE`, ...) is installed, run `sql/00_drop_all.sql` first (DEV only).
2. Run `sql/04` (optional SQL-only test).
3. Import `cdi/import/MATMAS_CDI_Collect_Only.zip` in IDMC (Data Integration → Explore → Import), publish and schedule `tf_P2O_110_MATMAS_Collect`.
4. Import `fabric/nb_matmas_process.ipynb` in Fabric, run it once with `dry_run = True`, then schedule it.

All SQL names follow the database standard: lower case with underscores (`cfg.matmas_route_config`, `matmas.jde_material_master`, column `erp_item_number`), flags as `bit`, config tables in schema `cfg`.

Verification status:
- The SQL parses with a T-SQL parser. It has not been executed here, because no SQL Server is available.
- The IDMC package was checked against real IDMC exports: checksums, internal references and taskflow links verify; decisions use the published format (field on the left).
- The notebook was run here against a simulated lakehouse folder and a simulated database (archive, duplicate, bad header, wrong field count, apply failure, retry, reconcile after reapply, wait for COLLECTED, stability gate). It has not run in Fabric yet.
