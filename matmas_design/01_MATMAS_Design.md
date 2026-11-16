# Material Master (MATMAS) – Generalized, Metadata-Driven Integration
### Informatica CDI + SQL database in Microsoft Fabric

Status: design v0.2 (16-Nov-2026). Companion files: `sql/`, `cdi/`, `secure_agent/` (see `README.md`).

---

## 1. Goals

1. **Zero new CDI objects per ERP or per target.** Onboarding = rows in control tables + a folder + a flat-file connection.
2. **One canonical material model** (`MATMAS.MATERIAL_MASTER`) with business `START_DATE` / `END_DATE` and full version history.
3. **Routes, not pipelines.** Inbound route = "this ERP's file → canonical". Outbound route = "this slice of canonical → this target". One taskflow loops over all active routes.
4. **Auditable, re-runnable, idempotent.** Batch id on everything, run log per stage, rejects kept with the raw record, duplicate publishes impossible.

The honest limit: CDI cannot share one Source/Target transformation across *connector types* (flat file vs. SAP IDoc vs. REST). So the generalization is one mapping per connector type, not per ERP. With all logic in SQL, the test scope needs exactly **2 mappings + 1 taskflow**.

---

## 2. Architecture

```
 Secure Agent folders                 SQL database in Fabric (schema MATMAS)
 MATMAS\inbound\JDE\JDE_MATMAS.txt    ┌─────────────────────────────────────────────────────────┐
 MATMAS\inbound\VISION\VISION_...txt  │ CONTROL  CTL_SOURCE_SYSTEM  CTL_INBOUND_INTEGRATION       │
 MATMAS\inbound\<ERP>\...             │          CTL_OUTBOUND_INTEGRATION  CTL_FIELD_MAPPING      │
        │                             │          CTL_CANONICAL_COLUMN  CTL_PARAMETER              │
        │ (1) LAND  m_MATMAS_LAND_FILE│          CTL_BATCH_RUN  CTL_STEP_RESULT                   │
        ▼   30 text columns, header   │                                                           │
   LANDING_RAW  ───────────────────▶  │ (2) HARMONIZE  sp_Harmonize: header check, dynamic SELECT │
   (views MATERIAL_MASTER_JDE,        │     built from CTL_FIELD_MAPPING, rejects, SCD2 merge     │
    MATERIAL_MASTER_VISION)           │                 ▼                                         │
                                      │   MATERIAL_MASTER (canonical, versioned)  + REJECT + XREF │
                                      │                 ▼                                         │
                                      │ (3) PUBLISH  sp_Publish (TABLE targets) /                 │
                                      │     CDI publish mapping (FILE / IDOC / API targets)        │
                                      │   MATERIAL_MASTER_TARGET  (same 8 columns as JDE details) │
                                      │   MATERIAL_MASTER_OUTBOUND (publish log)                  │
                                      └─────────────────────────────────────────────────────────┘
   tf_MATMAS_ORCHESTRATOR: loop i=1..N → mt_MATMAS_EXEC_SQL(GET_IN_ROUTE i) → mt_MATMAS_LAND_FILE
   (connection + file name overridden per route) → mt_MATMAS_EXEC_SQL(HARMONIZE) → archive file
   → loop j=1..M → mt_MATMAS_EXEC_SQL(GET_OUT_ROUTE j) → mt_MATMAS_EXEC_SQL(PUBLISH)
```

| Stage | Where | Generic because |
|---|---|---|
| 1 Land | CDI `m_MATMAS_LAND_FILE` | Source connection + file name are parameters; target is always `LANDING_RAW` with 30 text columns; the file header is landed as row 1 |
| 2 Harmonize | SQL `sp_Harmonize` | SELECT list is generated from `CTL_FIELD_MAPPING`; output shape is always the canonical column list; SCD2 code is static |
| 3 Publish | SQL `sp_Publish` for tables; CDI mapping per protocol for files / IDoc / API | INSERT list generated from OUT mappings; filter from the route |
| Orchestration | CDI `tf_MATMAS_ORCHESTRATOR` + `m_MATMAS_EXEC_SQL` | One proc, `sp_MATMAS_Run`, returns a fixed 16-column row for every stage, so one mapping drives everything |

---

## 3. Schema MATMAS – object inventory

| # | Object | Type | Purpose |
|---|---|---|---|
| 1 | `CTL_SOURCE_SYSTEM` | control | Registry of ERPs / endpoints, default date style per system |
| 2 | `CTL_CANONICAL_COLUMN` | control | The fixed canonical attribute list the harmonize SELECT is generated against |
| 3 | `CTL_INBOUND_INTEGRATION` | control | One row per source → canonical route: CDI connection name, file name, folder, expected header, load type, natural key, run group |
| 4 | `CTL_OUTBOUND_INTEGRATION` | control | One row per canonical → target route: target type/connection/object, filter, publish mode (FULL/DELTA) |
| 5 | `CTL_FIELD_MAPPING` | control | Column rules. IN: `COLnn → canonical` with T-SQL expression + validation expression. OUT: `canonical → target column` |
| 6 | `CTL_PARAMETER` | control | Key/value per route or global |
| 7 | `CTL_BATCH_RUN` | control | Run log per batch / route / stage with counts |
| 8 | `CTL_STEP_RESULT` | control | Every call the CDI exec mapping made (trace of the taskflow) |
| 9 | `LANDING_RAW` | landing | One generic landing table: batch, route, file, row number, `COL01..COL30` |
| 10 | `MATERIAL_MASTER_JDE`, `MATERIAL_MASTER_VISION` | views | Readable per-ERP views over `LANDING_RAW` |
| 11 | `MATERIAL_MASTER` | canonical | SCD type 2: hash key, hash diff, `VALID_FROM/TO_TS`, `CURRENT_FLAG`, business `START_DATE/END_DATE`, `ITEM_STATUS` |
| 12 | `V_MATERIAL_MASTER_CURRENT` | view | Current versions only |
| 13 | `MATERIAL_MASTER_XREF` | canonical | Same material across systems (JDE item ↔ SAP material ↔ Coupa item) |
| 14 | `MATERIAL_MASTER_REJECT` | canonical | Failed rows with reason and the raw record |
| 15 | `MATERIAL_MASTER_OUTBOUND` | canonical | Which version was published to which route (idempotency) |
| 16 | `MATERIAL_MASTER_TARGET` | target | The end table in the JDE-details format + Start/End Date (+ Source System) |
| 17 | `sp_Harmonize`, `sp_Publish`, `sp_MATMAS_Run` | procs | Stage logic + the single entry point for CDI |

---

## 4. Canonical model and the sample

Natural key (configured per route in `NATURAL_KEY_COLUMNS`): `SOURCE_SYSTEM + ERP_ITEM_NUMBER + PLANT_CODE + SUPPLIER_NUMBER + SUPPLIER_PART_NUMBER`.

JDE file as delivered (`secure_agent/MATMAS/inbound/JDE/JDE_MATMAS.txt`), Start/End Date added:

| ERP Item Number | Material Description | Plant Code | Supplier Part# | Supplier Number | Manufacturing Part# | Start Date | End Date |
|---|---|---|---|---|---|---|---|
| 109589 | SEN,PROXIMITY,29MM,12-24VDC | AUR | 4462658 (Primary) | 456526 | 4462658 (Fallback) | 2026-01-01 | 9999-12-31 |
| 109589 | SEN,PROXIMITY,29MM,12-24VDC | AUR | 4462658 (Primary) | 456526 | 4462658 (Fallback) | 2026-01-01 | 9999-12-31 |

What harmonize does with it: the two identical rows collapse to one (exact duplicate, counted, not rejected); `4462658 (Primary)` becomes `SUPPLIER_PART_NUMBER = 4462658`, `SUPPLIER_PART_ROLE = PRIMARY`; `4462658 (Fallback)` becomes `MANUFACTURER_PART_NUMBER = 4462658`, `MANUFACTURER_PART_ROLE = FALLBACK`. Publish re-composes the original text, so `MATERIAL_MASTER_TARGET` shows exactly the format above.

Date semantics: `START_DATE/END_DATE` = business effectivity, consumed by targets. `VALID_FROM_TS/VALID_TO_TS/CURRENT_FLAG` = technical version history. A key that disappears from a FULL extract gets a new version with `ITEM_STATUS = INACTIVE` and `END_DATE = load date`, so consumers see the closure.

---

## 5. How one pipeline serves every route

1. **Land**: the taskflow overrides the flat-file **connection name** and **file name** of `mt_MATMAS_LAND_FILE` per iteration with values from `CTL_INBOUND_INTEGRATION`. Every file lands into the same 30-column table with its header as row 1.
2. **Harmonize**: `sp_Harmonize` checks the header against `EXPECTED_HEADER` (wrong layout = whole file rejected with a clear message), builds `SELECT <expr> AS <canonical col> … FROM LANDING_RAW WHERE BATCH_ID = …` from `CTL_FIELD_MAPPING`, computes `HASH_KEY` and `HASH_DIFF`, rejects rows failing mandatory/validation rules, collapses exact duplicates, then applies the SCD2 merge: new → insert, changed → close + insert, unchanged → skip, missing (FULL) → inactive version.
3. **Publish**: `sp_Publish` builds `INSERT INTO <target>(<target cols>) SELECT <expr> FROM MATERIAL_MASTER mm WHERE CURRENT_FLAG='Y' AND <route filter>` and logs the versions it sent. `FULL` truncates and reloads the current snapshot; `DELTA` appends only versions not yet published to that route. Non-table targets (SAP IDoc, Coupa file/API) are routed by the taskflow to a protocol-specific publish mapping that reads the same canonical data.
4. **Orchestrate**: one taskflow, two loops (inbound routes, outbound routes), one error path that logs the failure and continues with the next route.

Details and exact settings: `cdi/CDI_Build_Guide.md`.

---

## 6. Onboarding ERP "XYZ" = configuration only

Folder + flat-file connection, one row in `CTL_SOURCE_SYSTEM`, one row in `CTL_INBOUND_INTEGRATION`, N rows in `CTL_FIELD_MAPPING`, optional readable view. No mapping, task or taskflow change.

---

## 7. Open points

1. **Vision file layout** is assumed (`ITEM_CODE|ITEM_DESC|SITE|VENDOR_ID|VENDOR_PART|PART_PRIORITY|MFR_PART|EFF_FROM|EFF_TO|UOM`, dates dd/mm/yyyy). Send the real header and the seed rows change.
2. **Grain**: confirmed as item × plant × supplier part for now. Exact duplicates collapse silently; duplicates with different attributes are rejected.
3. **Target column `Source System`** was added to `MATERIAL_MASTER_TARGET` so JDE and Vision rows are distinguishable. Remove one seed row and one column for a strict 8-column target.
4. **Final targets** (SAP staging table vs IDoc, Coupa) decide how many protocol publish mappings are needed later; the TABLE path is complete now.
5. **Secure Agent OS/path**: scripts and folders assume Windows at `C:\Informatica\SecureAgent\MATMAS`; both `.cmd` and `.sh` are provided.
