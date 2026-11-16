# MATMAS – generalized Material Master integration (Informatica CDI + SQL database in Fabric)

| Path | What it is |
|---|---|
| `01_MATMAS_Design.md` | Design: principles, schema, how one pipeline serves every ERP and target |
| `sql/01_schema_and_tables.sql` | T-SQL: MATMAS schema, control tables, generic landing, canonical SCD2 table, target table, views |
| `sql/02_procedures.sql` | T-SQL: `sp_Harmonize`, `sp_Publish`, `sp_MATMAS_Run` (single entry point for CDI) |
| `sql/03_seed_config.sql` | Seed: systems, canonical column list, JDE + Vision inbound routes with field mappings, outbound route to the target table |
| `sql/04_test_without_cdi.sql` | End-to-end test of the SQL side using the two sample files, no Informatica needed |
| `cdi/CDI_Build_Guide.md` | Click-level build of 3 connections, 2 mappings, 2 mapping tasks, 1 taskflow |
| `cdi/param/*.param` | Parameter files to run each mapping task stand-alone |
| `cdi/scripts/archive_file.*` | Command-task script to archive a processed file (Windows / Linux agent) |
| `secure_agent/MATMAS/` | Folder tree to copy onto the Secure Agent: `inbound/JDE`, `inbound/VISION` with the sample files, `_template`, `archive`, `error`, `outbound` |

Run order: `sql/01` → `sql/02` → `sql/03` → `sql/04` (proves the SQL) → build CDI objects per the guide → copy `secure_agent/MATMAS` to the agent → run the taskflow.

Status: SQL scripts are written for the Azure SQL engine used by Fabric SQL database and were desk-checked, not executed (no SQL Server available in this workspace). Run `sql/04` first; if anything errors, send the message back and it will be fixed.

Honest note on "importable": IICS export zips cannot be hand-authored (internal JSON with org GUIDs). Build once from the guide, then export from your org and store the zip in `cdi/export/`.
