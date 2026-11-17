# %% [markdown]
# # nb_matmas_process (OneLake landing -> matmas ERP tables)
#
# Hybrid MATMAS flow. IDMC (`tf_P2O_110_MATMAS_Collect`) only copies each route's source files to
# OneLake `Files/erp_to_matmas/landing/{erp}/{run_id}/` and deletes them at the source. This notebook
# does everything after that, with the same audit tables as before:
#
# 1. **Sweep** `landing/{erp}` for every active route in `cfg.matmas_route_config` (the folder is
#    `onelake_folder`; the root comes from the `onelake_root` setting).
# 2. **Stability gate**: a run folder is processed only when every file in it has stopped changing.
# 3. **Load**: read the 6 pipe-delimited fields, add `start_date` / `end_date` from the route,
#    write `matmas.material_master_stage` (rows with the wrong field count go to
#    `matmas.material_master_reject`).
# 4. **Apply** with `matmas.sp_apply_route` (validation, rejects, duplicate-file check,
#    INSERT / UPSERT / UPDATE / DELETE / TRUNCATE_INSERT into `matmas.{erp}_material_master`,
#    `matmas.file_history`, events LOADED / DUPLICATE_FILE / APPLY_FAILED in `matmas.run_log`).
# 5. **Archive**: `matmas.v_run_outcome` decides ARCHIVE, DUPLICATE or ERROR; the files move by
#    swapping `/landing/` for `/archive/`, `/duplicate/` or `/error/` and an OUTCOME event is logged.
#
# The `run_id` is the IDMC run folder name, so one `run_id` carries the whole trail in
# `matmas.run_log`: STARTED and COLLECTED (IDMC), LOADED and OUTCOME (this notebook). A file dropped
# straight into `landing/{erp}/` (no run folder) gets a run id `NB<yyyymmddhhmmss>`.
#
# Runs on a schedule, single-flight. Requires `lh_p2o_intg_dev` as the default lakehouse and the
# Python kernel (same set-up as `ingest_external_files`).

# %% [markdown]
# ## 1. Parameters

# %% tags=["parameters"]
# --- parameters (overridable from a pipeline) ---
ROUTE_IDS           = ''                         # '' = every active route; or 'JDE_MATMAS,VISION_MATMAS'
LAKEHOUSE_FILES     = '/lakehouse/default/Files'  # default lakehouse mount
LANDING_ROOT        = ''                         # '' = from cfg.matmas_setting.onelake_root (.../erp_to_matmas/landing)
DELIMITER           = '|'                        # file contract: pipe delimited, header row, UTF-8, 6 columns
TEXT_QUALIFIER      = ''                         # e.g. '"' if the ERP wraps fields in quotes
HEADER_ROW          = True
quiet_seconds       = 20                         # unmodified this long = stable
recheck_seconds     = 20                         # in-run second look for files that are not yet quiet; 0 = off
empty_grace_seconds = 900                        # 0-byte file older than this is released (fails to /error/)
MAX_LOAD_ATTEMPTS   = 5                          # runtime failures (connection, timeout) before a run folder goes to /error/
REQUIRE_COLLECTED   = True                       # IDMC run folders wait for the taskflow's COLLECTED event (copy finished)
COLLECTED_WAIT_MINUTES = 60                      # ...but a folder older than this is processed anyway (event lost)
SQL_ARTIFACT        = 'sqldb-p2o-intg-dev'       # the Fabric SQL DATABASE item (read-write)
WORKSPACE           = ''                         # '' = this notebook's workspace
dry_run             = False                      # True = sweep + parse + print only (no writes, no moves)

# %% [markdown]
# ## 2. Connection + tiny helpers
# Native Fabric connector, as in `po_transform` / `ingest_external_files`. It autocommits per statement.

# %%
import os, re, shutil, time, datetime, json
import pandas as pd

def connect():
    return notebookutils.data.connect_to_artifact(SQL_ARTIFACT, WORKSPACE)

def _is_na(v):
    # pandas reads SQL NULLs as NaN (a whole-NULL column arrives as float64); treat both as NULL
    try:
        return v is None or pd.isna(v)
    except (TypeError, ValueError):
        return v is None

def _records(df):
    """DataFrame to list[dict], NULLs as None (not NaN)."""
    if df is None or len(df) == 0:
        return []
    return [{k: (None if _is_na(v) else v) for k, v in row.items()}
            for row in df.to_dict('records')]

def _q(s):
    return "N'" + str(s).replace("'", "''") + "'"

def _lit(v):
    if v is None:
        return 'NULL'
    if isinstance(v, bool):
        return '1' if v else '0'
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, (datetime.date, datetime.datetime)):
        return "'" + v.isoformat() + "'"
    return "N'" + str(v).replace("'", "''") + "'"

def _insert(conn, table, cols, rows, chunk=200):
    """Multi-row INSERT in chunks (SQL Server allows at most 1000 rows per VALUES)."""
    if not rows:
        return 0
    collist = ', '.join(cols)
    for i in range(0, len(rows), chunk):
        block = rows[i:i + chunk]
        vals = ',\n'.join('(' + ', '.join(_lit(r.get(c)) for c in cols) + ')' for r in block)
        conn.query(f'INSERT INTO {table} ({collist}) VALUES {vals};')
    return len(rows)

def _utcnow():
    return datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)

def log_event(conn, run_id, route_id, event, message, file_count=None):
    """matmas.run_log through the same procedure the run book uses."""
    fc = 'NULL' if file_count is None else int(file_count)
    conn.query(f'EXEC matmas.sp_log_event @run_id = {_q(run_id)}, @route_id = {_q(route_id)}, '
               f'@event = {_q(event)}, @message = {_q(str(message)[:3900])}, @file_count = {fc}')

# %% [markdown]
# ## 3. Config (routes + folders)
# Every active route of `cfg.matmas_route_config`. Its OneLake folder is
# `{LAKEHOUSE_FILES}/{onelake_root after Files/}/landing/{onelake_folder}`.

# %%
FIELDS = ['erp_item_number', 'material_description', 'plant_code',
          'supplier_part_number', 'supplier_number', 'manufacturing_part_number']   # file column order
STAGE_COLS = ['run_id', 'route_id', 'source_file_name'] + FIELDS + ['start_date', 'end_date']
REJECT_COLS = ['run_id', 'route_id', 'source_file_name', 'reject_reason'] + FIELDS

def load_settings(conn):
    rows = _records(conn.query('SELECT setting_name, setting_value FROM cfg.matmas_setting'))
    return {r['setting_name']: r['setting_value'] for r in rows}

def load_routes(conn):
    rows = _records(conn.query('''
        SELECT route_id, erp_system, onelake_folder, target_schema, target_table, load_operation,
               start_date_value, end_date_value
        FROM   cfg.matmas_route_config
        WHERE  active_flag = 1
        ORDER  BY run_order, route_id'''))
    wanted = {x.strip().upper() for x in str(ROUTE_IDS or '').split(',') if x.strip()}
    return [r for r in rows if not wanted or str(r['route_id']).upper() in wanted]

def landing_base(settings):
    """/lakehouse/default/Files/erp_to_matmas/landing (from onelake_root = lh_p2o_intg_dev/Files/erp_to_matmas)."""
    if LANDING_ROOT:
        return LANDING_ROOT.rstrip('/')
    root = str(settings.get('onelake_root') or 'lh_p2o_intg_dev/Files/erp_to_matmas').strip('/')
    rel = root.split('/Files/', 1)[1] if '/Files/' in root else root
    return f"{LAKEHOUSE_FILES.rstrip('/')}/{rel.strip('/')}/landing"

def dest_path(landing_file, outcome):
    cat = {'ARCHIVE': 'archive', 'DUPLICATE': 'duplicate'}.get(outcome, 'error')
    return landing_file.replace('/landing/', f'/{cat}/', 1)

# %% [markdown]
# ## 4. Sweep + stability gate
# A run folder `landing/{erp}/{run_id}/` is one unit of work. An IDMC run folder is processed only
# after the taskflow logged COLLECTED for it (`REQUIRE_COLLECTED`). Loose files in `landing/{erp}/` are
# moved into a new run folder first. Folders starting with `_` (e.g. `_design`) are ignored.
# A run folder is processed only when all its files are stable: unmodified for `quiet_seconds`,
# or unchanged in size and mtime after one `recheck_seconds` pause in this run. A 0-byte file is an
# upload placeholder until it has stayed empty for `empty_grace_seconds`.

# %%
def _stat(p):
    st = os.stat(p)
    return {'path': p, 'name': os.path.basename(p), 'size': st.st_size, 'mtime': st.st_mtime}

def adopt_loose_files(route_dir, dry_run=False):
    """Files dropped straight into landing/{erp}/ get their own run folder NB<timestamp>."""
    loose = [n for n in sorted(os.listdir(route_dir))
             if os.path.isfile(os.path.join(route_dir, n)) and not n.startswith('_')]
    if not loose:
        return None
    run_id = 'NB' + _utcnow().strftime('%Y%m%d%H%M%S')
    if dry_run:
        print(f'  (dry) {len(loose)} loose file(s) would move into {run_id}/')
        return run_id
    os.makedirs(os.path.join(route_dir, run_id), exist_ok=True)
    for n in loose:
        shutil.move(os.path.join(route_dir, n), os.path.join(route_dir, run_id, n))
    print(f'  {len(loose)} loose file(s) moved into {run_id}/')
    return run_id

def sweep_route(route_dir):
    """{run_id: [file stats]} for every run folder under landing/{erp}/."""
    groups = {}
    if not os.path.isdir(route_dir):
        return groups
    for run_id in sorted(os.listdir(route_dir)):
        p = os.path.join(route_dir, run_id)
        if run_id.startswith('_') or not os.path.isdir(p):
            continue
        files = [_stat(os.path.join(dp, n)) for dp, _d, names in os.walk(p) for n in sorted(names)]
        if files:
            groups[run_id] = files
        else:
            try:
                os.rmdir(p)                 # empty run folder left by a move
            except OSError:
                pass
    return groups

def is_stable(f, now):
    if f['size'] == 0:
        return now - f['mtime'] >= empty_grace_seconds
    return now - f['mtime'] >= quiet_seconds

def stable_groups(groups):
    """Run folders whose files are all stable (one shared recheck pause for the whole sweep)."""
    now = time.time()
    ready, recheck = {}, {}
    for run_id, files in groups.items():
        if all(is_stable(f, now) for f in files):
            ready[run_id] = files
        elif recheck_seconds > 0 and all(f['size'] > 0 or is_stable(f, now) for f in files):
            recheck[run_id] = files
        else:
            print(f'    {run_id}: not stable yet, next sweep')
    if recheck:
        time.sleep(recheck_seconds)
        for run_id, files in recheck.items():
            try:
                again = [_stat(f['path']) for f in files]
            except OSError:
                print(f'    {run_id}: file changed or gone during recheck, next sweep')
                continue
            if all((a['size'], a['mtime']) == (f['size'], f['mtime']) for a, f in zip(again, files)):
                ready[run_id] = files
            else:
                print(f'    {run_id}: still being written, next sweep')
    return ready

# %% [markdown]
# ## 5. Parse (6 fields + start / end date)
# Positional: the file's 6 columns map to the 6 business columns in order, whatever the header text
# says. A data row with another field count is rejected (`matmas.material_master_reject`); a file
# whose header does not have 6 columns, or that is empty, fails as a whole (`LOAD_FAILED`, `/error/`).

# %%
class FileContentError(Exception):
    """The file itself is unusable: not retried, the run folder goes to /error/."""

def _split(line):
    parts = line.split(DELIMITER)
    q = TEXT_QUALIFIER
    if q:
        parts = [p[1:-1] if len(p) >= 2 and p[0] == q and p[-1] == q else p for p in parts]
    return [p.strip() for p in parts]

def read_lines(path):
    with open(path, 'r', encoding='utf-8-sig') as fh:      # utf-8-sig drops a BOM if the ERP writes one
        return [ln.rstrip('\r\n') for ln in fh if ln.strip() != '']

def route_dates(route):
    start = route.get('start_date_value')
    start = (datetime.date.fromisoformat(str(start)[:10]) if start and str(start).strip()
             else datetime.datetime.now(datetime.timezone.utc).date())
    end = route.get('end_date_value')
    end = datetime.date.fromisoformat(str(end)[:10]) if end and str(end).strip() else datetime.date(9999, 12, 31)
    return start, end

def parse_files(route, run_id, files):
    """-> (stage rows, reject rows, per-file summary)."""
    start, end = route_dates(route)
    stage, rejects, summary = [], [], []
    for f in files:
        lines = read_lines(f['path'])
        if not lines:
            raise FileContentError(f"{f['name']}: file is empty")
        data = lines
        if HEADER_ROW:
            header = _split(lines[0])
            if len(header) != len(FIELDS):
                raise FileContentError(f"{f['name']}: header has {len(header)} column(s), expected "
                                       f"{len(FIELDS)} ({DELIMITER!r} delimited): {lines[0][:200]}")
            data = lines[1:]
        n_ok = n_bad = 0
        for line_no, ln in enumerate(data, start=2 if HEADER_ROW else 1):
            vals = _split(ln)
            if all(v == '' for v in vals):
                continue                                   # blank row
            if len(vals) != len(FIELDS):
                padded = (vals + [None] * len(FIELDS))[:len(FIELDS)]
                rejects.append(dict(zip(FIELDS, [(v or None) and v[:1000] for v in padded]),
                                    run_id=run_id, route_id=route['route_id'], source_file_name=f['name'][:500],
                                    reject_reason=f'line {line_no}: {len(vals)} field(s), expected {len(FIELDS)}'))
                n_bad += 1
                continue
            row = {c: (v[:1000] if v != '' else None) for c, v in zip(FIELDS, vals)}
            row.update(run_id=run_id, route_id=route['route_id'], source_file_name=f['name'][:500],
                       start_date=start, end_date=end)
            stage.append(row)
            n_ok += 1
        summary.append({'file': f['name'], 'rows': n_ok, 'bad_field_count': n_bad})
    return stage, rejects, summary

# %% [markdown]
# ## 6. Load, apply, archive (one run folder)
# Same audit trail as the IDMC version. `sp_apply_route` does the validation, the duplicate-file
# check, the operation and the LOADED / DUPLICATE_FILE / APPLY_FAILED events.
#
# Failures:
# - **File unusable** (empty, wrong header): `LOAD_FAILED`, files to `/error/`.
# - **Apply failed** (config, missing table, ...): `APPLY_FAILED` from the procedure, files to
#   `/error/`, staged rows kept as FAILED. Fix and run `EXEC matmas.sp_reapply_run '<run_id>', '<route_id>'`;
#   the next sweep then moves the files from `/error/` to `/archive/` (section 7).
# - **Runtime error** (connection, timeout): `LOAD_RETRY`, files stay in landing for the next sweep,
#   up to `MAX_LOAD_ATTEMPTS`; then `LOAD_FAILED` and `/error/`.
#
# One run per route at a time: `sp_getapplock` on `matmas_<route_id>`, as in `ingest_external_files`.

# %%
def _claim(conn, lane):
    rows = _records(conn.query(
        'DECLARE @rc int; '
        f"EXEC @rc = sp_getapplock @Resource = {_q(lane)}, @LockMode = 'Exclusive', "
        "@LockOwner = 'Session', @LockTimeout = 0; SELECT @rc AS rc"))
    return bool(rows) and int(rows[0]['rc']) >= 0

def _release(conn, lane):
    try:
        conn.query(f"EXEC sp_releaseapplock @Resource = {_q(lane)}, @LockOwner = 'Session'")
    except Exception as e:
        print(f'  lane {lane}: release failed ({e})')

def events_for(conn, run_id, route_id):
    return [r['event'] for r in _records(conn.query(
        f'SELECT event FROM matmas.run_log WHERE run_id = {_q(run_id)} AND route_id = {_q(route_id)} ORDER BY log_id'))]

def outcome_for(conn, run_id, route_id):
    rows = _records(conn.query(
        f'SELECT outcome FROM matmas.v_run_outcome WHERE run_id = {_q(run_id)} AND route_id = {_q(route_id)}'))
    return (rows[0]['outcome'] if rows else None) or 'ERROR'

def move_files(files, outcome):
    moved = []
    for f in files:
        dest = dest_path(f['path'], outcome)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if os.path.exists(dest):
            os.remove(dest)                        # a re-run overwrites its own earlier copy
        shutil.move(f['path'], dest)
        moved.append(dest)
    run_dir = os.path.dirname(files[0]['path'])
    try:
        os.rmdir(run_dir)                          # landing/{erp}/{run_id} is now empty
    except OSError:
        pass
    return moved

def finish(conn, route, run_id, files, outcome, note=''):
    dests = move_files(files, outcome)
    names = ', '.join(f['name'] for f in files)
    log_event(conn, run_id, route['route_id'], 'OUTCOME',
              f'files go to {outcome}{note}: {names}', file_count=len(files))
    return dests

def process_run(conn, route, run_id, files):
    rid = route['route_id']
    lane = f'matmas_{rid}'
    if not dry_run and not _claim(conn, lane):
        return {'route_id': rid, 'run_id': run_id, 'skipped': 'lane in use'}
    try:
        return _process_claimed(conn, route, run_id, files)
    finally:
        if not dry_run:
            _release(conn, lane)

def _process_claimed(conn, route, run_id, files):
    rid = route['route_id']
    res = {'route_id': rid, 'run_id': run_id, 'files': [f['name'] for f in files]}

    # a previous sweep already applied this run (it stopped before or during the move):
    # don't load again, just finish the move with the recorded outcome
    seen = [] if dry_run else events_for(conn, run_id, rid)
    if any(e in ('LOADED', 'APPLY_FAILED', 'LOAD_FAILED') for e in seen):
        outcome = outcome_for(conn, run_id, rid)
        finish(conn, route, run_id, files, outcome, ' (resumed)')
        return {**res, 'outcome': outcome, 'resumed': True}

    # IDMC writes the files of a run one by one: wait until the taskflow has logged COLLECTED for this
    # run folder, so a half-copied run is never loaded. NB<...> folders (loose files) need no event.
    if REQUIRE_COLLECTED and not run_id.startswith('NB') and not dry_run and 'COLLECTED' not in seen:
        age_min = (time.time() - max(f['mtime'] for f in files)) / 60
        if age_min < COLLECTED_WAIT_MINUTES:
            return {**res, 'skipped': f'waiting for COLLECTED from IDMC ({age_min:.0f} of {COLLECTED_WAIT_MINUTES} min)'}
        res['note'] = f'no COLLECTED event after {COLLECTED_WAIT_MINUTES} min, processed anyway'

    try:
        stage, rejects, summary = parse_files(route, run_id, files)
    except FileContentError as e:
        res.update(error=str(e), outcome='ERROR')
        if not dry_run:
            log_event(conn, run_id, rid, 'LOAD_FAILED', e, file_count=len(files))
            finish(conn, route, run_id, files, 'ERROR')
        return res
    res.update(summary=summary, staged=len(stage), bad_field_count=len(rejects))
    if dry_run:
        print(f'    (dry) {run_id}: {len(stage)} row(s) to stage, {len(rejects)} wrong field count')
        return res

    try:
        # idempotent: clear what an interrupted earlier attempt left, then stage
        conn.query(f"DELETE FROM matmas.material_master_stage WHERE run_id = {_q(run_id)} "
                   f"AND route_id = {_q(rid)} AND stage_status = 'NEW'")
        conn.query(f"DELETE FROM matmas.material_master_reject WHERE run_id = {_q(run_id)} "
                   f"AND route_id = {_q(rid)} AND reject_reason LIKE N'line %field(s), expected%'")
        _insert(conn, 'matmas.material_master_reject', REJECT_COLS, rejects)
        _insert(conn, 'matmas.material_master_stage', STAGE_COLS, stage)
    except Exception as e:
        return {**res, **retry_or_fail(conn, route, run_id, files, e)}

    try:
        conn.query(f'EXEC matmas.sp_apply_route @run_id = {_q(run_id)}, @route_id = {_q(rid)}')
    except Exception as e:
        # sp_apply_route has logged APPLY_FAILED and marked the staged rows FAILED before it raised
        res['apply_error'] = str(e)[:500]
        if 'APPLY_FAILED' not in events_for(conn, run_id, rid):
            return {**res, **retry_or_fail(conn, route, run_id, files, e)}   # never reached the procedure

    outcome = outcome_for(conn, run_id, rid)
    note = f' ({len(rejects)} row(s) with a wrong field count rejected)' if rejects else ''
    finish(conn, route, run_id, files, outcome, note)
    return {**res, 'outcome': outcome}

def retry_or_fail(conn, route, run_id, files, exc):
    rid = route['route_id']
    try:
        attempt = sum(1 for e in events_for(conn, run_id, rid) if e == 'LOAD_RETRY') + 1
        conn.query(f"DELETE FROM matmas.material_master_stage WHERE run_id = {_q(run_id)} "
                   f"AND route_id = {_q(rid)} AND stage_status = 'NEW'")
        if attempt < MAX_LOAD_ATTEMPTS:
            log_event(conn, run_id, rid, 'LOAD_RETRY',
                      f'attempt {attempt} of {MAX_LOAD_ATTEMPTS}: {str(exc)[:1500]}; files left in landing')
            return {'retry': attempt, 'error': str(exc)[:500]}
        log_event(conn, run_id, rid, 'LOAD_FAILED',
                  f'attempt {attempt} of {MAX_LOAD_ATTEMPTS}, no attempts left: {str(exc)[:1500]}')
        finish(conn, route, run_id, files, 'ERROR')
        return {'outcome': 'ERROR', 'error': str(exc)[:500]}
    except Exception as unwind_error:
        # the connection is gone: leave the files in landing, the next sweep tries again
        print(f'  {rid}/{run_id}: could not record the failure ({unwind_error}); left in landing')
        return {'error': str(exc)[:500], 'unrecorded': True}

# %% [markdown]
# ## 7. Reconcile /error/ after a reapply
# A run folder in `/error/{erp}/` whose latest load event is LOADED (after
# `matmas.sp_reapply_run`) moves to `/archive/`.

# %%
def reconcile_errors(conn, route, base):
    error_dir = base.replace('/landing', '/error', 1) + '/' + route['onelake_folder']
    if not os.path.isdir(error_dir):
        return 0
    moved = 0
    for run_id in sorted(os.listdir(error_dir)):
        p = os.path.join(error_dir, run_id)
        if not os.path.isdir(p):
            continue
        rows = _records(conn.query(
            f"SELECT TOP 1 event FROM matmas.run_log WHERE run_id = {_q(run_id)} "
            f"AND route_id = {_q(route['route_id'])} AND event IN ('LOADED','APPLY_FAILED','LOAD_FAILED') "
            'ORDER BY log_id DESC'))
        if not rows or rows[0]['event'] != 'LOADED':
            continue
        if dry_run:
            print(f'  (dry) reconcile {run_id}: error -> archive')
            continue
        dest = p.replace('/error/', '/archive/', 1)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if os.path.exists(dest):
            shutil.rmtree(dest)
        shutil.move(p, dest)
        log_event(conn, run_id, route['route_id'], 'OUTCOME', 'files go to ARCHIVE (after reapply)')
        print(f'  reconcile {route["route_id"]}/{run_id}: error -> archive')
        moved += 1
    return moved

# %% [markdown]
# ## 8. Run
# Every active route: adopt loose files, sweep, stability gate, process each stable run folder
# (oldest run id first), then reconcile `/error/`. One failure is logged and the loop continues.

# %%
results = []
with connect() as conn:
    settings = load_settings(conn)
    base = landing_base(settings)
    routes = load_routes(conn)
    print(f'landing: {base}  routes: {", ".join(r["route_id"] for r in routes) or "(none active)"}')
    for route in routes:
        route_dir = f"{base}/{route['onelake_folder']}"
        print(f"{route['route_id']}: {route_dir}")
        if not os.path.isdir(route_dir):
            print('  folder not found (create it in the lakehouse), skipped')
            continue
        adopt_loose_files(route_dir, dry_run)
        groups = sweep_route(route_dir)
        print(f'  {len(groups)} run folder(s) in landing')
        for run_id, files in sorted(stable_groups(groups).items()):
            try:
                r = process_run(conn, route, run_id, files)
            except Exception as e:
                r = {'route_id': route['route_id'], 'run_id': run_id, 'error': str(e)[:500]}
            print(' ', r)
            results.append(r)
        try:
            reconcile_errors(conn, route, base)
        except Exception as e:
            print(f'  reconcile failed: {e}')
    if dry_run:
        print('DRY RUN - nothing written, nothing moved.')

# %% [markdown]
# ## 9. Return outcome (for the scheduler / pipeline)

# %%
_outcome = json.dumps({
    'runs': len(results),
    'archive': sum(1 for r in results if r.get('outcome') == 'ARCHIVE'),
    'duplicate': sum(1 for r in results if r.get('outcome') == 'DUPLICATE'),
    'error': sum(1 for r in results if r.get('outcome') == 'ERROR'),
    'retry': sum(1 for r in results if 'retry' in r),
    'skipped': sum(1 for r in results if 'skipped' in r),
    'rows_staged': sum(r.get('staged', 0) for r in results),
    'written': (not dry_run),
    'detail': results,
}, default=str)
try:
    notebookutils.notebook.exit(_outcome)
except Exception:
    try:
        mssparkutils.notebook.exit(_outcome)
    except Exception:
        print('exit value (interactive):', _outcome)
