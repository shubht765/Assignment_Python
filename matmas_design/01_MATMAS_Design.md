# Material Master (MATMAS) – generalized, metadata-driven integration
### Informatica CDI + SQL database in Microsoft Fabric

Status: design v0.3 (16-Nov-2026), aligned to the org's real CDI export (connection, project, runtime environment, package format). Companion files: `sql/`, `cdi/`, `secure_agent/`. Start with `README.md`.

---

## 1. Goals

1. **No CDI object per ERP or per target.** Onboarding an ERP means a folder plus rows in control tables.
2. **One canonical material model** (`MATMAS.MATERIAL_MASTER`). It has business `START_DATE` / `END_DATE` and full version history.
3. **Routes, not pipelines.** An inbound route maps an ERP folder to canonical. An outbound route maps a slice of canonical to a target.
4. **Auditable, re-runnable, idempotent.** Every run has a batch id and a run log. Rejects are kept with the raw record. Landed data is kept, so a batch can be reprocessed without the file. Publishing the same version twice is not possible.

---

## 2. Architecture

```
 Secure Agent (US.US02.01)                         SQL database in Fabric
 MATMAS\inbound\JDE\JDE_MATMAS.txt          ┌───────────────────────────────────────────────────┐
 MATMAS\inbound\VISION\VISION_MATMAS.txt    │ schema stg (CDI interface views, connection default)│
 MATMAS\inbound\<new ERP>\...               │   MATMAS_LANDING_RAW   MATMAS_RUN_REQUEST(_SRC)      │
        │                                   │ schema MATMAS (data + logic)                        │
  pre-cmd: list all files                   │   CTL_* control tables, LANDING_RAW,                │
        ▼                                   │   MATERIAL_MASTER (SCD2), REJECT, OUTBOUND, TARGET   │
 mt_MATMAS_LAND  (indirect file list) ─────▶│   stg.MATMAS_LANDING_RAW  ─▶ MATMAS.LANDING_RAW      │
        │                                   │                                                     │
 mt_MATMAS_PROCESS (1-row insert) ─────────▶│   stg.MATMAS_RUN_REQUEST  ─▶ CTL_RUN_REQUEST         │
   target Post SQL ────────────────────────▶│   EXEC MATMAS.sp_MATMAS_Process                     │
        │                                   │     1 Assign   : batch id, row numbers, route by    │
  post-cmd: archive listed files            │                  sub-folder + file name pattern     │
                                            │     2 Harmonize: each route, SELECT generated from  │
                                            │                  CTL_FIELD_MAPPING, rejects, SCD2   │
                                            │     3 Publish  : each outbound route, INSERT        │
                                            │                  generated from OUT mappings        │
                                            │   MATERIAL_MASTER_TARGET (same format as JDE details)│
                                            └───────────────────────────────────────────────────┘
 tf_MATMAS_DAILY = mt_MATMAS_LAND → mt_MATMAS_PROCESS (scheduled)
```

Why this shape:
- **One land run for all ERPs.** The flat-file source reads an indirect file list that the pre-processing command builds from every ERP folder. There is no loop in the taskflow and no connection switching.
- **Routing is data, not CDI.** `CurrentlyProcessedFileName` carries the full path. `sp_MATMAS_Assign` matches the parent folder to `FOLDER_KEY` and the file name to `FILE_NAME_PATTERN`.
- **The import package stays within object types the org's own export already contains.** `m_MATMAS_PROCESS` is JDBC V2 to JDBC V2 with a target Post SQL, built from the same template as the reference.
- **Vision is SAP.** The production Vision feed can switch to the MATMAS IDoc through the existing ALE IDoc reader pattern. That is phase 2 and is described in the CDI guide.

---

## 3. Schema inventory

| # | Object | Type | Purpose |
|---|---|---|---|
| 1 | `MATMAS.CTL_SOURCE_SYSTEM` | control | ERPs and endpoints |
| 2 | `MATMAS.CTL_CANONICAL_COLUMN` | control | Fixed canonical attribute list the generated SELECT is built against |
| 3 | `MATMAS.CTL_INBOUND_INTEGRATION` | control | One row per ERP route: `FOLDER_KEY`, `FILE_NAME_PATTERN`, `EXPECTED_HEADER`, load type, natural key |
| 4 | `MATMAS.CTL_OUTBOUND_INTEGRATION` | control | One row per target route: type, object, filter, FULL or DELTA |
| 5 | `MATMAS.CTL_FIELD_MAPPING` | control | IN: `COLnn` to canonical, with a T-SQL expression and a validation rule. OUT: canonical to target column |
| 6 | `MATMAS.CTL_PARAMETER` | control | Key/value settings |
| 7 | `MATMAS.CTL_BATCH_RUN` | log | One row per batch, route and stage, with counts and message |
| 8 | `MATMAS.CTL_RUN_REQUEST` | log | One row per CDI run, with overall status and summary |
| 9 | `MATMAS.LANDING_RAW` | landing | All files of all ERPs: file path, row number, `COL01..COL30` |
| 10 | `MATMAS.MATERIAL_MASTER_JDE`, `_VISION` | views | Readable per-ERP views over landing |
| 11 | `MATMAS.MATERIAL_MASTER` | canonical | SCD type 2, with business dates and status |
| 12 | `MATMAS.MATERIAL_MASTER_XREF` | canonical | The same material across systems |
| 13 | `MATMAS.MATERIAL_MASTER_REJECT` | canonical | Failed rows with reason and raw record |
| 14 | `MATMAS.MATERIAL_MASTER_OUTBOUND` | canonical | Which version went to which route |
| 15 | `MATMAS.MATERIAL_MASTER_TARGET` | target | The end table in the JDE-details format plus Start/End Date |
| 16 | `MATMAS.V_MATMAS_RUN_REQUEST`, `V_MATMAS_RUN_STATUS`, `V_MATERIAL_MASTER_CURRENT` | views | Process source, monitoring, current materials |
| 17 | `stg.MATMAS_LANDING_RAW`, `stg.MATMAS_RUN_REQUEST_SRC`, `stg.MATMAS_RUN_REQUEST` | views | CDI interface in the connection's default schema |
| 18 | `sp_MATMAS_Process`, `sp_MATMAS_Assign`, `sp_Harmonize`, `sp_Publish`, `sp_MATMAS_Reprocess` | procs | Pipeline logic |

---

## 4. The sample and what happens to it

JDE file `inbound/JDE/JDE_MATMAS.txt`, with Start/End Date added:

| ERP Item Number | Material Description | Plant Code | Supplier Part# | Supplier Number | Manufacturing Part# | Start Date | End Date |
|---|---|---|---|---|---|---|---|
| 109589 | SEN,PROXIMITY,29MM,12-24VDC | AUR | 4462658 (Primary) | 456526 | 4462658 (Fallback) | 2026-01-01 | 9999-12-31 |
| 109589 | SEN,PROXIMITY,29MM,12-24VDC | AUR | 4462658 (Primary) | 456526 | 4462658 (Fallback) | 2026-01-01 | 9999-12-31 |

1. **Land.** Three rows reach `LANDING_RAW`: the header and two data rows. Each carries the full file path.
2. **Assign.** The parent folder is `JDE` and the file name matches `JDE_MATMAS%.txt`, so the file goes to route `IN_JDE_MATMAS_FILE`. Rows are numbered 1 to 3.
3. **Harmonize.**
   - The header matches `EXPECTED_HEADER`.
   - `4462658 (Primary)` becomes part number `4462658` with role `PRIMARY`. `4462658 (Fallback)` becomes manufacturer part `4462658` with role `FALLBACK`.
   - The dates are parsed. Empty dates would default to the load date and 9999-12-31.
   - The two identical rows collapse into one.
   - The result is inserted as version 1.
4. **Publish.** The original text format is re-composed into `MATERIAL_MASTER_TARGET`.

The Vision sample has a different header, dd/mm/yyyy dates and P/F priority codes. It goes through the same procedures with only different mapping rows, which proves the generalization. One Vision row is rejected for an invalid date.

Date semantics:
- `START_DATE` / `END_DATE` are business effectivity, and targets consume them.
- `VALID_FROM_TS` / `VALID_TO_TS` / `CURRENT_FLAG` are technical history.
- A key missing from a FULL extract gets a new version with status `INACTIVE` and `END_DATE` set to the load date.

---

## 5. Onboarding ERP "XYZ" without CDI changes

1. Create folder `MATMAS\inbound\XYZ`.
2. Insert one row into `CTL_SOURCE_SYSTEM`.
3. Insert one row into `CTL_INBOUND_INTEGRATION` with `FOLDER_KEY = 'XYZ'`, the `FILE_NAME_PATTERN` and the `EXPECTED_HEADER`.
4. Insert one row into `CTL_FIELD_MAPPING` per canonical column you can fill.
5. Optionally create a readable view over landing.

The next scheduled run picks up the file.

---

## 6. Open points

1. **Real Vision file layout.** The current one is assumed. Alternatively, decide whether production Vision should arrive as a MATMAS IDoc (phase 2).
2. **Strict 8-column target.** `[Source System]` was added to the target. Remove it and its mapping row if it is not wanted.
3. **Final targets.** SAP IDoc and Coupa routes need one publish mapping per protocol later. The TABLE path is complete.
4. **Land mapping import.** It needs one exported flat-file mapping from the org as a template.
