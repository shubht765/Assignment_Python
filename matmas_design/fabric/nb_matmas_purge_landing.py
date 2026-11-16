# Fabric notebook (PySpark) - attach lakehouse lh_p2o_intg_dev as default.
# Purpose: remove run folders under Files/erp_to_matmas/landing/<ERP>/<RUN_ID> once they have been
# copied to archive / duplicate / error by fi_P2O_101_MATMAS_OneLake_Move and are older than KEEP_DAYS.
# Only needed if the file ingestion task in your IDMC version cannot delete source files after transfer.
# Schedule it daily in Fabric (or call it from a Fabric pipeline).
from datetime import datetime, timedelta, timezone
from notebookutils import mssparkutils

ROOT = "Files/erp_to_matmas"
KEEP_DAYS = 7
cutoff = datetime.now(timezone.utc) - timedelta(days=KEEP_DAYS)

def copied_elsewhere(erp, run_id):
    for area in ("archive", "duplicate", "error"):
        try:
            if mssparkutils.fs.ls(f"{ROOT}/{area}/{erp}/{run_id}"):
                return True
        except Exception:
            pass
    return False

removed = 0
for erp_dir in mssparkutils.fs.ls(f"{ROOT}/landing"):
    if not erp_dir.isDir:
        continue
    for run_dir in mssparkutils.fs.ls(erp_dir.path):
        run_id = run_dir.name.rstrip("/")
        if not (run_dir.isDir and len(run_id) == 14 and run_id.isdigit()):
            continue                                    # only <RUN_ID> folders (yyyyMMddHHmmss, UTC)
        run_ts = datetime.strptime(run_id, "%Y%m%d%H%M%S").replace(tzinfo=timezone.utc)
        if run_ts < cutoff and copied_elsewhere(erp_dir.name.rstrip("/"), run_id):
            mssparkutils.fs.rm(run_dir.path, recurse=True)
            removed += 1
            print("removed", run_dir.path)
print("run folders removed:", removed)
