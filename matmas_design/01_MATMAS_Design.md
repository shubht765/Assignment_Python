# Material Master (MATMAS) – Generalized, Metadata-Driven Integration on Informatica CDI

Status: design proposal v0.1 (16-Nov-2026)
Scope: one reusable CDI pipeline that loads material master from any ERP (JDE, Vision, future ERPs) into a canonical model and publishes it to any target (SAP, JDE, Coupa, ...), driven entirely by rows in control tables.

---

## 1. Design goals

1. **Zero new mappings per ERP.** Onboarding a new source = inserting rows into control tables + creating one landing table. No CDI development.
2. **One canonical material model.** Every ERP lands in its own raw table (`MATERIAL_MASTER_JDE`, `MATERIAL_MASTER_VISION`, ...) and is harmonized into a single `MATERIAL_MASTER` table with the same columns, including `START_DATE` / `END_DATE`.
3. **Routes, not pipelines.** A route = one row: *source X → canonical* (inbound) or *canonical → target Y* (outbound). The same taskflow loops over all active routes.
4. **Auditable and re-runnable.** Every run has a `BATCH_ID`, every stage logs counts and status, rejects are stored with the raw record.

Honest limit of "one pipeline": CDI cannot share one Source/Target transformation across different *connector types* (flat file vs. database vs. SAP IDoc vs. REST). The generalization is therefore **one mapping per connector type**, not per ERP. In practice that is 3 generic mappings + 1 taskflow (see section 5), instead of one mapping per ERP × target.

---

## 2. Architecture

```
          CONTROL PLANE (MATMAS.CTL_*)                       DATA PLANE (MATMAS.*)
 ┌──────────────────────────────────────┐    ┌──────────────────────────────────────────────┐
 │ CTL_SOURCE_SYSTEM     (ERP registry) │    │  Files / tables from JDE, Vision, ERP-n      │
 │ CTL_INBOUND_INTEGRATION (src→canon)  │    │          │ (1) LAND  – 1:1, raw, VARCHAR      │
 │ CTL_OUTBOUND_INTEGRATION(canon→tgt)  │    │          ▼                                   │
 │ CTL_FIELD_MAPPING   (column rules)   │───▶│  MATERIAL_MASTER_JDE / _VISION / _<ERP>      │
 │ CTL_PARAMETER       (key/values)     │    │          │ (2) HARMONIZE – SQL generated from │
 │ CTL_BATCH_RUN       (run log)        │    │          ▼      CTL_FIELD_MAPPING, SCD2       │
 └──────────────────────────────────────┘    │  MATERIAL_MASTER (canonical, effective-dated)│
                                             │  MATERIAL_MASTER_XREF, MATERIAL_MASTER_REJECT│
   TF_MATMAS_ORCHESTRATOR (one taskflow)     │          │ (3) PUBLISH – per target type      │
   loops over active routes and passes       │          ▼                                   │
   connection/object/query parameters        │  SAP table/IDoc · JDE Z-table · Coupa CSV    │
   into 3 generic mappings                   │  MATERIAL_MASTER_OUTBOUND (publish log)      │
                                             └──────────────────────────────────────────────┘
```

Three stages, each a generic CDI mapping:

| Stage | Mapping | What is parameterized | Fixed |
|---|---|---|---|
| 1 Land | `m_MATMAS_LAND_FILE` (and `m_MATMAS_LAND_DB` if a source is a DB table) | source connection, file/table name, landing table | nothing else: field mapping is "automatic by name", all landing columns are VARCHAR |
| 2 Harmonize | `m_MATMAS_HARMONIZE` | the SELECT statement (built from `CTL_FIELD_MAPPING`) | canonical target columns, SCD2 logic, hash keys, reject handling |
| 3 Publish | `m_MATMAS_PUBLISH_TABLE`, `m_MATMAS_PUBLISH_FILE`, (+1 per API protocol e.g. SAP IDoc) | source filter, target connection, target object, outbound column aliases | delta detection via publish log |

---

## 3. Schema MATMAS – table inventory

| # | Table | Type | Purpose |
|---|---|---|---|
| 1 | `CTL_SOURCE_SYSTEM` | control | Registry of ERPs / systems (JDE, VISION, SAP, COUPA): code, description, time zone, default date format, owner. |
| 2 | `CTL_INBOUND_INTEGRATION` | control | One row per **source → canonical** route: where to read (connection, object/file pattern), which landing table, load type, run group, sequence, active flag. |
| 3 | `CTL_OUTBOUND_INTEGRATION` | control | One row per **canonical → target** route: filter on canonical (which source systems / plants), target type, connection, object, last published watermark. |
| 4 | `CTL_FIELD_MAPPING` | control | Column-level rules for a route. Inbound: landing column → canonical column with optional SQL expression. Outbound: canonical column → target column. Drives the generated SELECT. |
| 5 | `CTL_PARAMETER` | control | Free key/value overrides per route (delimiter, header flag, SFTP folder, e-mail list). Keeps the route table from growing a column per quirk. |
| 6 | `CTL_BATCH_RUN` | control | Run log: batch id, route, stage, status, timestamps, rows read / inserted / updated / rejected, error text, file name. |
| 7 | `MATERIAL_MASTER_JDE` | landing | Raw JDE extract, columns = file header + audit. All VARCHAR. Includes `START_DATE`, `END_DATE`. |
| 8 | `MATERIAL_MASTER_VISION` | landing | Raw Vision extract (layout assumed; replace with actual header). |
| 9 | `MATERIAL_MASTER` | canonical | Harmonized material master, one row version per natural key (SCD type 2), with business `START_DATE`/`END_DATE` and technical `VALID_FROM_TS`/`VALID_TO_TS`. |
| 10 | `MATERIAL_MASTER_XREF` | canonical | Cross-reference of the same material across systems (JDE item ↔ SAP material ↔ Coupa item). |
| 11 | `MATERIAL_MASTER_REJECT` | canonical | Rows that failed mandatory/format checks, with reason and raw record. |
| 12 | `MATERIAL_MASTER_OUTBOUND` | canonical | Publish log per outbound route and material version (status, target reference such as IDoc number). |
| 13 | `V_CTL_INBOUND_RUNTIME` | view | Joins route + field mappings and **builds the harmonize SELECT text** per route. The taskflow reads this view. |
| 14 | `V_CTL_OUTBOUND_RUNTIME` | view | Same for outbound: builds the publish SELECT with target column aliases. |

Full DDL: `02_MATMAS_DDL.sql`. Seed data (JDE sample from Prabakaran's table + start/end date): `03_MATMAS_Seed_Config.sql`.

---

## 4. Canonical model – `MATMAS.MATERIAL_MASTER`

Grain (proposed natural key): `SOURCE_SYSTEM + ERP_ITEM_NUMBER + PLANT_CODE + SUPPLIER_NUMBER + SUPPLIER_PART_NUMBER`.
The sample shows two identical rows for item 109589, which suggests the extract is at item × plant × supplier-part level (or contains duplicates). Confirm the grain; the key list is a config value (`CTL_INBOUND_INTEGRATION.NATURAL_KEY_COLUMNS`), not hard-coded.

| Column | Type | Notes |
|---|---|---|
| `HASH_KEY` | VARCHAR(32) | MD5 of natural key columns. Stable id across runs. |
| `SOURCE_SYSTEM` | VARCHAR(20) | FK to `CTL_SOURCE_SYSTEM`. |
| `ERP_ITEM_NUMBER` | VARCHAR(50) | e.g. 109589 |
| `MATERIAL_DESCRIPTION` | VARCHAR(240) | e.g. SEN,PROXIMITY,29MM,12-24VDC |
| `PLANT_CODE` | VARCHAR(10) | e.g. AUR |
| `SUPPLIER_NUMBER` | VARCHAR(30) | e.g. 456526 |
| `SUPPLIER_PART_NUMBER` | VARCHAR(60) | 4462658 (the "(Primary)" suffix is split out) |
| `SUPPLIER_PART_ROLE` | VARCHAR(10) | PRIMARY / FALLBACK |
| `MANUFACTURER_PART_NUMBER` | VARCHAR(60) | 4462658 |
| `MANUFACTURER_PART_ROLE` | VARCHAR(10) | PRIMARY / FALLBACK |
| `START_DATE` | DATE | Business effectivity start (the field Abhishek asked to add). From source if provided, else batch date. |
| `END_DATE` | DATE | Business effectivity end. From source if provided, else 9999-12-31. |
| `ITEM_STATUS`, `BASE_UOM`, `ITEM_CATEGORY`, `COMMODITY_CODE` | VARCHAR | Optional common attributes, nullable. |
| `EXT_ATTR_01..05` | VARCHAR(100) | Overflow for ERP-specific attributes you want to carry without schema change. Meaning per source documented in `CTL_FIELD_MAPPING`. |
| `HASH_DIFF` | VARCHAR(32) | MD5 of all non-key attributes; drives change detection. |
| `VALID_FROM_TS`, `VALID_TO_TS`, `CURRENT_FLAG` | TIMESTAMP / CHAR(1) | SCD2 technical versioning (when we learned about the change). |
| `BATCH_ID`, `INTEGRATION_ID`, `SRC_FILE_NAME`, `CREATED_TS`, `UPDATED_TS` | audit | |

Why both `START_DATE/END_DATE` and `VALID_FROM/TO_TS`: the first pair is business meaning ("this supplier part is valid for this material from/to"), the second is technical history ("this version of the record was current from/to"). SAP and Coupa consume the first; audit and reprocessing use the second.

JDE sample (what the landing table receives, with the two new columns):

| ERP Item Number | Material Description | Plant Code | Supplier Part# | Supplier Number | Manufacturing Part# | Start Date | End Date |
|---|---|---|---|---|---|---|---|
| 109589 | SEN,PROXIMITY,29MM,12-24VDC | AUR | 4462658 (Primary) | 456526 | 4462658 (Fallback) | 2026-01-01 | 9999-12-31 |
| 109589 | SEN,PROXIMITY,29MM,12-24VDC | AUR | 4462658 (Primary) | 456526 | 4462658 (Fallback) | 2026-01-01 | 9999-12-31 |

---

## 5. How one pipeline serves every route (CDI mechanics)

### 5.1 Parameters used by the generic mappings

| Parameter | Type | Set by | Used in |
|---|---|---|---|
| `$$BATCH_ID` | string | taskflow (yyyymmddhh24miss + route) | all stages, audit |
| `$$INTEGRATION_ID` | string | taskflow, from control table | all stages |
| `$$SRC_CONN` | connection | taskflow override, from `SOURCE_CONNECTION` | Land |
| `$$SRC_OBJECT` | object | taskflow override, from `SOURCE_OBJECT` (file name or table) | Land |
| `$$LANDING_TABLE` | object | from `LANDING_TABLE` | Land (target), Harmonize |
| `$$HARMONIZE_SQL` | string | from `V_CTL_INBOUND_RUNTIME.HARMONIZE_SQL` | Harmonize source (custom query) |
| `$$PUBLISH_SQL` | string | from `V_CTL_OUTBOUND_RUNTIME.PUBLISH_SQL` | Publish source |
| `$$TGT_CONN`, `$$TGT_OBJECT` | connection / object | from `CTL_OUTBOUND_INTEGRATION` | Publish target |

All connection and object parameters are created with "Allow parameter to be overridden at run time" so the taskflow Data Task can set them per iteration. Source-type mappings use **dynamic schema handling** and target **field mapping = automatic by name**.

### 5.2 Stage 1 – Land (`m_MATMAS_LAND_FILE`)

- Source: flat file, connection `$$SRC_CONN`, object `$$SRC_OBJECT`, header row, delimiter from `CTL_PARAMETER` (standardize inbound extracts to one file contract: UTF-8, pipe or comma, header row, dates ISO). 
- Expression: adds `BATCH_ID`, `INTEGRATION_ID`, `SRC_FILE_NAME` (= `CurrentlyProcessedFileName`), `SRC_ROW_NUM`, `LOAD_TS`.
- Target: `$$LANDING_TABLE`, insert, field mapping automatic by name. Because the landing table columns are named exactly like the file header (spaces → underscore, # → NO), JDE and Vision files load through the same mapping into different tables.
- Everything is VARCHAR in landing: a bad date never fails the load; it is rejected in stage 2 with a reason.

If a source is a DB table rather than a file, `m_MATMAS_LAND_DB` is the same mapping with a relational source (one extra mapping per connector *type*, not per ERP).

### 5.3 Stage 2 – Harmonize (`m_MATMAS_HARMONIZE`)

- Source: custom query = `$$HARMONIZE_SQL`. The view `V_CTL_INBOUND_RUNTIME` generates it from `CTL_FIELD_MAPPING`, e.g. for JDE:

```sql
SELECT 'JDE' AS SOURCE_SYSTEM,
       TRIM(ERP_ITEM_NUMBER)                                        AS ERP_ITEM_NUMBER,
       TRIM(MATERIAL_DESCRIPTION)                                   AS MATERIAL_DESCRIPTION,
       UPPER(TRIM(PLANT_CODE))                                      AS PLANT_CODE,
       TRIM(SUPPLIER_NUMBER)                                        AS SUPPLIER_NUMBER,
       CASE WHEN INSTR(SUPPLIER_PART_NO,'(')>0
            THEN TRIM(SUBSTR(SUPPLIER_PART_NO,1,INSTR(SUPPLIER_PART_NO,'(')-1))
            ELSE TRIM(SUPPLIER_PART_NO) END                         AS SUPPLIER_PART_NUMBER,
       CASE WHEN UPPER(SUPPLIER_PART_NO) LIKE '%FALLBACK%' THEN 'FALLBACK' ELSE 'PRIMARY' END
                                                                    AS SUPPLIER_PART_ROLE,
       ...                                                          AS MANUFACTURER_PART_NUMBER,
       ...                                                          AS MANUFACTURER_PART_ROLE,
       COALESCE(TO_DATE(START_DATE,'YYYY-MM-DD'), TRUNC(SYSDATE))   AS START_DATE,
       COALESCE(TO_DATE(END_DATE,'YYYY-MM-DD'), DATE '9999-12-31')  AS END_DATE,
       BATCH_ID, INTEGRATION_ID, SRC_FILE_NAME, SRC_ROW_NUM
FROM   MATMAS.MATERIAL_MASTER_JDE
WHERE  BATCH_ID = '$$BATCH_ID'
```

  Every row of the SELECT list is one row in `CTL_FIELD_MAPPING` (`TARGET_COLUMN`, `TRANSFORM_EXPR`). Canonical columns not mapped for a source are emitted as NULL by the view, so the output column list is always identical, which is what lets the rest of the mapping stay fixed.

- Expression: `HASH_KEY = MD5(natural key columns joined by '|')`, `HASH_DIFF = MD5(all other attributes)`; mandatory check flag from `CTL_FIELD_MAPPING.MANDATORY_FLAG` (also enforced in SQL via a `REJECT_REASON` column the view adds).
- Router 1: `REJECT_REASON IS NOT NULL` → `MATERIAL_MASTER_REJECT`.
- Lookup: `MATERIAL_MASTER` where `CURRENT_FLAG='Y'` on `HASH_KEY`, returns `HASH_DIFF`.
- Router 2: NEW (no lookup hit) → insert; CHANGED (hash differs) → update old version (`VALID_TO_TS = now, CURRENT_FLAG='N'`) + insert new version; UNCHANGED → drop.
- Targets: `MATERIAL_MASTER` (insert), `MATERIAL_MASTER` (update), `MATERIAL_MASTER_REJECT` (insert).
- `LOAD_TYPE = FULL` routes additionally close versions whose key did not appear in the batch (post-SQL in the mapping task, parameterized by `$$INTEGRATION_ID`).

### 5.4 Stage 3 – Publish (`m_MATMAS_PUBLISH_TABLE` / `_FILE` / `_<API>`)

- Source: custom query = `$$PUBLISH_SQL`, generated by `V_CTL_OUTBOUND_RUNTIME`: selects current canonical rows matching `SOURCE_FILTER` (e.g. `SOURCE_SYSTEM='JDE' AND PLANT_CODE IN ('AUR')`), not yet in `MATERIAL_MASTER_OUTBOUND` with status SUCCESS for this route, with OUT field mappings aliasing canonical columns to the **target's** column names (e.g. `ERP_ITEM_NUMBER AS MATNR`).
- Target: `$$TGT_CONN` / `$$TGT_OBJECT`, field mapping automatic by name. One mapping covers every relational target (SAP staging table, JDE Z-table, Snowflake, ...). File targets (Coupa CSV over SFTP) use the `_FILE` variant plus a Command Task for the transfer. SAP IDoc / BAPI or Coupa REST need their own small mapping per protocol; they still read the same `$$PUBLISH_SQL`, so column logic stays in the control table.
- Writes `MATERIAL_MASTER_OUTBOUND` (route, `HASH_KEY`, batch, status, target reference) so re-runs are idempotent and failures can be resent.

### 5.5 Orchestration – `TF_MATMAS_ORCHESTRATOR` (one taskflow)

Input fields: `RUN_GROUP` (e.g. `DAILY`, `JDE_ONLY`, or a file name when triggered by a File Listener), `INTEGRATION_ID` (optional, run a single route).

```
Start
 ├─ Assignment: BATCH_ID = to_char(now,'yyyymmddhh24miss'); i = 1
 ├─ Data Task DT_GET_INBOUND(i)          -- mapping m_MATMAS_CTL_READ: reads row #i of
 │     outputs: TOTAL, INTEGRATION_ID,    --   V_CTL_INBOUND_RUNTIME for RUN_GROUP, exposes
 │              SRC_CONN, SRC_OBJECT,     --   values as in-out parameters (SetVariable),
 │              SRC_TYPE, LANDING_TABLE,  --   which become Data Task output fields
 │              HARMONIZE_SQL
 ├─ Decision: TOTAL = 0 → End (nothing to do)
 ├─ Data Task: insert CTL_BATCH_RUN (RUNNING)
 ├─ Decision on SRC_TYPE
 │     FILE → Data Task DT_LAND_FILE  (overrides $$SRC_CONN,$$SRC_OBJECT,$$LANDING_TABLE,$$BATCH_ID)
 │     DB   → Data Task DT_LAND_DB
 ├─ Data Task DT_HARMONIZE               (overrides $$HARMONIZE_SQL,$$BATCH_ID,$$INTEGRATION_ID)
 ├─ Data Task: update CTL_BATCH_RUN (SUCCESS + counts from task output fields)
 │     on error → update FAILED, Notification Task, continue to next route
 ├─ Assignment: i = i + 1
 ├─ Decision: i <= TOTAL → Jump to DT_GET_INBOUND
 │
 ├─ (same loop over V_CTL_OUTBOUND_RUNTIME)
 │     Data Task DT_GET_OUTBOUND(j) → Decision on TGT_TYPE → DT_PUBLISH_TABLE / _FILE / _IDOC
 │     → Command Task (SFTP) when TGT_TYPE = FILE → update CTL_BATCH_RUN, LAST_PUBLISHED_TS
End
```

Key CDI features relied on: Jump step for looping, Decision step, Data Task input-field overrides for connection/object/string parameters, in-out parameters surfaced as Data Task outputs, File Listener as trigger (file name arrives as a taskflow input and is matched against `SOURCE_OBJECT` pattern).

Alternative for parallel execution: a **Dynamic Mapping Task** with one job group per route. It runs routes in parallel but job groups are configured in the UI, so it is less data-driven. Recommended only if run time becomes an issue.

### 5.6 Error handling, audit, re-run

- Every stage writes to `CTL_BATCH_RUN` with counts from the Data Task output fields (`Success Source Rows`, `Success Target Rows`, `Failed Target Rows`).
- A failed route does not stop other routes; the taskflow logs FAILED, notifies the `NOTIFY_EMAIL` list from `CTL_PARAMETER`, and continues.
- Re-run a route: run the taskflow with `INTEGRATION_ID` set. Landing is append-by-batch, harmonize is idempotent (hash compare), publish is idempotent (outbound log).
- Retention: purge landing rows older than N days by `LOAD_TS` (post-SQL or a weekly route).

---

## 6. Onboarding a new ERP ("XYZ") – no CDI change

1. `INSERT INTO CTL_SOURCE_SYSTEM` ('XYZ').
2. Create landing table `MATMAS.MATERIAL_MASTER_XYZ` (columns = file header, all VARCHAR, + the 6 audit columns). Template in the DDL file.
3. `INSERT INTO CTL_INBOUND_INTEGRATION` (connection, file pattern, landing table, run group).
4. `INSERT INTO CTL_FIELD_MAPPING` one row per canonical column you can populate (at least the key columns + description + START/END dates).
5. Optional: `INSERT INTO CTL_PARAMETER` for delimiter / date format quirks.
6. Run `TF_MATMAS_ORCHESTRATOR` with `INTEGRATION_ID = 'IN_XYZ_MATMAS_FILE'` in a test run group, check `CTL_BATCH_RUN` and `MATERIAL_MASTER_REJECT`.
7. To send XYZ materials somewhere: one row in `CTL_OUTBOUND_INTEGRATION` + OUT rows in `CTL_FIELD_MAPPING`.

---

## 7. Open questions (answers change the DDL, not the design)

1. **Database platform** for the MATMAS schema (Oracle / SQL Server / Snowflake / Postgres)? DDL and the runtime views are written in Oracle syntax; the `LISTAGG`, `INSTR/SUBSTR`, `TO_DATE` parts need a one-time dialect swap for anything else.
2. **Targets and protocols**: is SAP fed via a staging table, IDoc MATMAS, or BAPI? Is Coupa a target for items (CSV over SFTP / API)? This decides how many publish mappings exist (one per protocol).
3. **Grain / natural key**: is one JDE row = item × plant × supplier part? The sample's two identical rows suggest duplicates in the extract; should the pipeline de-duplicate silently or reject?
4. **Start/End date source**: does JDE provide effectivity dates in the extract, or should the pipeline derive `START_DATE` = batch date and `END_DATE` = 9999-12-31 (current default)?
5. **Vision file layout**: send the header row; the landing table and field mappings in the seed file for Vision are placeholders.
6. **Load type**: are the extracts full snapshots (then missing keys get closed) or deltas?
7. **File contract**: can all ERPs deliver pipe-delimited UTF-8 with a header row to the same Secure Agent folder (one sub-folder per ERP)? That keeps stage 1 to a single mapping.
