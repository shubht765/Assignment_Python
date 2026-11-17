"""Local test of nb_matmas_process.py: fake lakehouse folder + fake SQL connection. Usage: python3 fabric/tools/test_nb_matmas_process.py fabric/nb_matmas_process.py"""
import os, re, sys, time, shutil, tempfile, types, json
import pandas as pd

NB = sys.argv[1]
src = open(NB).read()
root = tempfile.mkdtemp()
FILES = os.path.join(root, 'Files')
L = f'{FILES}/erp_to_matmas/landing'
for erp in ('JDE', 'Vision'):
    os.makedirs(f'{L}/{erp}', exist_ok=True)
os.makedirs(f'{L}/JDE/_design', exist_ok=True)
open(f'{L}/JDE/_design/design.txt', 'w').write('x')

HDR = 'ERP Item Number|Material Description|Plant Code|Supplier Part#|Supplier Number|Manufacturing Part#\n'
ROW = '109589|SEN,PROXIMITY,29MM,12-24VDC|AUR|4462658 (Primary)|456526|4462658 (Fallback)\n'


def put(path, text, age=120):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, 'w', encoding='utf-8').write(text)
    t = time.time() - age
    os.utime(path, (t, t))


# run 1: IDMC run folder with COLLECTED -> ARCHIVE (one good row, one wrong field count, one blank)
put(f'{L}/JDE/20261117090000/JDE_MATMAS_20261117.txt', '﻿' + HDR + ROW + 'bad|row\n' + '|||||\n')
# run 2: IDMC folder without COLLECTED, recent -> waits
put(f'{L}/JDE/20261117100000/JDE_MATMAS_b.txt', HDR + ROW, age=60)
# run 3: loose Vision file -> NB folder, apply raises -> APPLY_FAILED -> ERROR
put(f'{L}/Vision/VISION_MATMAS_1.txt', HDR + 'V-1|desc|MEL|p|78001|m\n')
# run 4: bad header -> LOAD_FAILED -> ERROR
put(f'{L}/JDE/20261117110000/bad.txt', 'a|b|c\n1|2|3\n')
# run 5: still being written (fresh mtime) -> recheck; we modify during the pause -> next sweep
put(f'{L}/JDE/20261117120000/x.txt', HDR + ROW, age=0)


class Conn:
    def __init__(self):
        self.log, self.stage, self.rejects, self.sql = [], [], [], []
        self.collected = {('20261117090000', 'JDE_MATMAS'), ('20261117110000', 'JDE_MATMAS'), ('20261117120000', 'JDE_MATMAS')}
        for r, rt in self.collected:
            self.log.append((r, rt, 'COLLECTED'))

    def __enter__(self): return self
    def __exit__(self, *a): return False

    def query(self, sql):
        self.sql.append(sql)
        s = ' '.join(sql.split())
        if 'FROM cfg.matmas_setting' in s:
            return pd.DataFrame([{'setting_name': 'onelake_root', 'setting_value': 'lh_p2o_intg_dev/Files/erp_to_matmas'}])
        if 'FROM cfg.matmas_route_config' in s:
            return pd.DataFrame([
                {'route_id': 'JDE_MATMAS', 'erp_system': 'JDE', 'onelake_folder': 'JDE', 'target_schema': 'matmas',
                 'target_table': 'jde_material_master', 'load_operation': 'UPSERT', 'start_date_value': None, 'end_date_value': '9999-12-31'},
                {'route_id': 'VISION_MATMAS', 'erp_system': 'VISION', 'onelake_folder': 'Vision', 'target_schema': 'matmas',
                 'target_table': 'vision_material_master', 'load_operation': 'UPSERT', 'start_date_value': '2026-01-01', 'end_date_value': None}])
        if 'sp_getapplock' in s:
            return pd.DataFrame([{'rc': 0}])
        if 'sp_releaseapplock' in s:
            return None
        m = re.search(r"EXEC matmas.sp_log_event @run_id = N'([^']*)', @route_id = N'([^']*)', @event = N'([^']*)', @message = N'(.*)', @file_count", s)
        if m:
            self.log.append((m.group(1), m.group(2), m.group(3), m.group(4)[:80]))
            return None
        m = re.search(r"FROM matmas.run_log WHERE run_id = N'([^']*)' AND route_id = N'([^']*)'", s)
        if m and re.search(r'SELECT (TOP 1 )?event', s):
            evs = [e[2] for e in self.log if e[0] == m.group(1) and e[1] == m.group(2)]
            if 'TOP 1' in s:
                evs = [e for e in evs if e in ('LOADED', 'APPLY_FAILED', 'LOAD_FAILED')][-1:]
            return pd.DataFrame([{'event': e} for e in evs])
        m = re.search(r"FROM matmas.v_run_outcome WHERE run_id = N'([^']*)' AND route_id = N'([^']*)'", s)
        if m:
            evs = [e[2] for e in self.log if e[0] == m.group(1) and e[1] == m.group(2)]
            o = 'ERROR' if {'APPLY_FAILED', 'LOAD_FAILED'} & set(evs) else 'ARCHIVE' if 'LOADED' in evs else 'ERROR'
            return pd.DataFrame([{'outcome': o}])
        m = re.search(r"EXEC matmas.sp_apply_route @run_id = N'([^']*)', @route_id = N'([^']*)'", s)
        if m:
            if m.group(2) == 'VISION_MATMAS':
                self.log.append((m.group(1), m.group(2), 'APPLY_FAILED'))
                raise RuntimeError('50102 Target table does not exist')
            self.log.append((m.group(1), m.group(2), 'LOADED'))
            return None
        if s.startswith('INSERT INTO matmas.material_master_stage'):
            if getattr(self, 'fail_insert', False):
                raise ConnectionError('connection reset by peer')
            self.stage.append(s); return None
        if s.startswith('INSERT INTO matmas.material_master_reject'):
            self.rejects.append(s); return None
        if s.startswith('DELETE'):
            return None
        raise AssertionError('unexpected SQL: ' + s[:200])


conn = Conn()
nbu = types.SimpleNamespace(data=types.SimpleNamespace(connect_to_artifact=lambda a, w: conn),
                            notebook=types.SimpleNamespace(exit=lambda v: print('EXIT', v[:400])))
g = {'notebookutils': nbu, '__name__': '__nb__'}
code = src.replace("LAKEHOUSE_FILES     = '/lakehouse/default/Files'", f"LAKEHOUSE_FILES     = {FILES!r}")
code = code.replace('recheck_seconds     = 20', 'recheck_seconds     = 2')

# modify run 5 during the recheck pause
import threading
def touch():
    time.sleep(1); open(f'{L}/JDE/20261117120000/x.txt', 'a').write(ROW)
threading.Thread(target=touch).start()
exec(compile(code, NB, 'exec'), g)

# sweep 2: Vision was reapplied (LOADED after APPLY_FAILED) -> reconcile error->archive;
# a new loose JDE file hits a connection error on insert -> LOAD_RETRY, stays in landing
nb_run = [e[0] for e in conn.log if e[1] == 'VISION_MATMAS'][0]
conn.log.append((nb_run, 'VISION_MATMAS', 'LOADED'))
put(f'{L}/JDE/JDE_MATMAS_loose.txt', HDR + ROW)
conn.fail_insert = True
print('\n######## sweep 2')
exec(compile(code.replace('recheck_seconds     = 2', 'recheck_seconds     = 0'), NB, 'exec'), g)
print('\n=== run_log'); [print(' ', e) for e in conn.log]
print('=== stage inserts', len(conn.stage)); print(' ', conn.stage[0][:400] if conn.stage else None)
print('=== reject inserts', len(conn.rejects)); print(' ', conn.rejects[0][:300] if conn.rejects else None)
print('=== tree')
for dp, dn, fn in sorted(os.walk(f'{FILES}/erp_to_matmas')):
    for f in fn:
        print(' ', os.path.relpath(os.path.join(dp, f), FILES))
shutil.rmtree(root)
