"""Builds docs/MATMAS_Hybrid_Flow.drawio: what nb_matmas_process (and the IDMC collect taskflow) do,
and what each step updates.  Pages: 1 Overview, 2 Notebook logic, 3 What gets updated.
Usage: python3 docs/tools/make_flow_drawio.py docs/MATMAS_Hybrid_Flow.drawio"""
import sys

# ---------------------------------------------------------------- palette
IDMC = "fillColor=#dae8fc;strokeColor=#6c8ebf;"
NB = "fillColor=#d5e8d4;strokeColor=#82b366;"
PROC = "fillColor=#ffe6cc;strokeColor=#d79b00;"
TABLE = "shape=cylinder3;boundedLbl=1;size=8;fillColor=#f5f5f5;strokeColor=#666666;"
LAKE = "fillColor=#e1d5e7;strokeColor=#9673a6;"
DEC = "rhombus;fillColor=#fff2cc;strokeColor=#d6b656;"
BAD = "fillColor=#f8cecc;strokeColor=#b85450;"
WAIT = "fillColor=#f5f5f5;strokeColor=#999999;fontColor=#333333;dashed=1;"
NOTE_W = "fillColor=#ecf6ea;strokeColor=#82b366;align=left;spacingLeft=8;spacingRight=4;"
NOTE_R = "fillColor=#eef3fb;strokeColor=#6c8ebf;align=left;spacingLeft=8;spacingRight=4;"
BOX = "rounded=1;whiteSpace=wrap;html=1;arcSize=8;"
EDGE = "edgeStyle=orthogonalEdgeStyle;rounded=1;orthogonalLoop=1;jettySize=auto;html=1;endArrow=block;endSize=8;"
DASH = EDGE + "dashed=1;strokeColor=#666666;"


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


class Page:
    def __init__(self, name):
        self.name, self.cells, self.n = name, [], 1

    def _id(self, key):
        return f"p{self.name[0]}_{key}"

    def v(self, key, label, x, y, w, h, style, parent=None):
        pid = self._id(parent) if parent else "1"
        self.cells.append(f'<mxCell id="{self._id(key)}" value="{esc(label)}" style="{style}" vertex="1" parent="{pid}">'
                          f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>')

    def e(self, key, src, tgt, label="", style=EDGE, pts=(), exit=None, entry=None, offset=None):
        st = style
        if exit:
            st += f"exitX={exit[0]};exitY={exit[1]};exitDx=0;exitDy=0;"
        if entry:
            st += f"entryX={entry[0]};entryY={entry[1]};entryDx=0;entryDy=0;"
        geo = ""
        if pts:
            geo += '<Array as="points">' + "".join(f'<mxPoint x="{x}" y="{y}"/>' for x, y in pts) + "</Array>"
        if offset:
            geo += f'<mxPoint x="{offset[0]}" y="{offset[1]}" as="offset"/>'
        self.cells.append(f'<mxCell id="{self._id(key)}" value="{esc(label)}" style="{st}" edge="1" parent="1" '
                          f'source="{self._id(src)}" target="{self._id(tgt)}"><mxGeometry relative="1" as="geometry">{geo}'
                          f"</mxGeometry></mxCell>")

    def xml(self, w, h):
        return (f'<diagram id="page{self.name[0]}" name="{esc(self.name)}"><mxGraphModel dx="{w}" dy="{h}" grid="1" gridSize="10" '
                f'guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="{w}" pageHeight="{h}" '
                f'math="0" shadow="0"><root><mxCell id="0"/><mxCell id="1" parent="0"/>{"".join(self.cells)}</root></mxGraphModel></diagram>')


def title(p, text, sub, w):
    p.v("title", f"<b>{text}</b>", 40, 20, w, 30, "text;html=1;fontSize=20;align=left;verticalAlign=middle;")
    p.v("sub", sub, 40, 52, w, 24, "text;html=1;fontSize=12;align=left;verticalAlign=middle;fontColor=#555555;")


def legend(p, x, y, items):
    h = 30 + 24 * len(items)
    p.v("legend", "Legend", x, y, 250, h, "rounded=0;whiteSpace=wrap;html=1;fillColor=none;strokeColor=#666666;verticalAlign=top;fontStyle=1;")
    for i, (style, text) in enumerate(items):
        p.v(f"lg{i}", "", 10, 30 + 24 * i, 30, 16, "rounded=0;html=1;" + style.replace("shape=cylinder3;boundedLbl=1;size=8;", ""), "legend")
        p.v(f"lgt{i}", text, 50, 28 + 24 * i, 190, 20, "text;html=1;align=left;verticalAlign=middle;fontSize=11;", "legend")


# ================================================================ page 1: overview
def overview():
    p = Page("1 Overview")
    title(p, "MATMAS hybrid flow: IDMC collects, Fabric notebook loads",
          "One run_id carries the trail in matmas.run_log: STARTED and COLLECTED (IDMC), LOADED and OUTCOME (notebook)", 1600)
    lane = "swimlane;startSize=30;html=1;whiteSpace=wrap;fontStyle=1;rounded=0;"
    p.v("A", "Source (Secure Agent)", 40, 100, 220, 760, lane + "fillColor=#f5f5f5;strokeColor=#666666;")
    p.v("B", "IDMC  tf_P2O_110_MATMAS_Collect (scheduled)", 300, 100, 320, 760, lane + IDMC)
    p.v("C", "OneLake  lh_p2o_intg_dev / Files / erp_to_matmas", 660, 100, 260, 760, lane + LAKE)
    p.v("D", "Fabric notebook  nb_matmas_process (every 15 min)", 960, 100, 340, 760, lane + NB)
    p.v("S", "Fabric SQL database  sqldb-p2o-intg-dev", 40, 920, 1660, 340, lane + "fillColor=#fafafa;strokeColor=#666666;")

    p.v("A1", "<b>Agent folder</b><br>D:\\Interfaces\\JDE\\<br>MATMAS\\outbound<br><i>JDE_MATMAS*.txt</i>", 10, 170, 200, 80, BOX + "fillColor=#ffffff;strokeColor=#666666;", "A")
    p.v("A2", "Later: share path (UNC) or SFTP.<br>Only the config / collect task change.", 10, 330, 200, 70, BOX + WAIT, "A")

    p.v("B1", "<b>mt_P2O_101 Route Reader</b><br>row N of cfg.matmas_route_config<br>logs <b>STARTED</b>", 20, 50, 280, 70, BOX + IDMC, "B")
    p.v("B2", "<b>fi_P2O_100 Agent to OneLake</b><br>runtime env, folder, pattern from the row<br>copy, then <b>delete at source</b>", 20, 170, 280, 80, BOX + IDMC, "B")
    p.v("B3", "Files found?", 70, 300, 180, 90, DEC + "whiteSpace=wrap;html=1;", "B")
    p.v("B4", "<b>mt_P2O_104</b><br>logs COLLECTED", 20, 440, 130, 60, BOX + IDMC, "B")
    p.v("B5", "<b>mt_P2O_104</b><br>logs NO_FILE", 170, 440, 130, 60, BOX + IDMC, "B")
    p.v("B6", "NextRow, until all routes are done.<br><i>No load, no archive in IDMC.</i>", 20, 560, 280, 60, BOX + WAIT, "B")

    p.v("C1", "<b>landing/&lt;ERP&gt;/&lt;RUN_ID&gt;/</b><br>e.g. landing/JDE/20261117090000/", 20, 170, 220, 80, BOX + LAKE, "C")
    p.v("C2", "<b>archive/&lt;ERP&gt;/&lt;RUN_ID&gt;/</b>", 20, 470, 220, 60, BOX + LAKE, "C")
    p.v("C3", "<b>duplicate/&lt;ERP&gt;/&lt;RUN_ID&gt;/</b>", 20, 570, 220, 60, BOX + LAKE, "C")
    p.v("C4", "<b>error/&lt;ERP&gt;/&lt;RUN_ID&gt;/</b>", 20, 670, 220, 60, BOX + BAD, "C")

    p.v("D1", "<b>1 Sweep</b> active routes (cfg.matmas_route_config)<br>wait: files stable + COLLECTED", 20, 170, 300, 70, BOX + NB, "D")
    p.v("D2", "<b>2 Parse</b> 6 fields by position<br>+ start_date / end_date from the route", 20, 270, 300, 70, BOX + NB, "D")
    p.v("D3", "<b>3 Stage</b> rows (wrong field count = reject)", 20, 370, 300, 70, BOX + NB, "D")
    p.v("D4", "<b>4 Apply</b>  EXEC matmas.sp_apply_route", 20, 470, 300, 70, BOX + NB, "D")
    p.v("D5", "<b>5 Outcome</b> from matmas.v_run_outcome<br>move files, log <b>OUTCOME</b>", 20, 570, 300, 70, BOX + NB, "D")
    p.v("D6", "<b>6 Reconcile</b> error to archive after sp_reapply_run", 20, 670, 300, 60, BOX + NB, "D")

    p.v("S1", "<b>cfg.matmas_route_config</b><br><b>cfg.matmas_setting</b><br>routes, folders, table, operation, dates", 280, 60, 280, 100, TABLE + "whiteSpace=wrap;html=1;", "S")
    p.v("S2", "<b>matmas.run_log</b><br>STARTED, COLLECTED, NO_FILE, LOADED,<br>DUPLICATE_FILE, APPLY_FAILED, LOAD_RETRY,<br>LOAD_FAILED, OUTCOME", 620, 50, 280, 120, TABLE + "whiteSpace=wrap;html=1;", "S")
    p.v("S3", "<b>matmas.sp_apply_route</b><br>validate, duplicate-file check, de-duplicate,<br>INSERT / UPSERT / UPDATE / DELETE / TRUNCATE_INSERT<br>in one transaction", 930, 60, 320, 100, BOX + PROC, "S")
    for i, (k, t) in enumerate([("S4", "matmas.material_master_stage"), ("S5", "matmas.material_master_reject"),
                                ("S6", "matmas.jde_ / vision_ / sap_material_master"), ("S7", "matmas.file_history")]):
        p.v(k, f"<b>{t}</b>", 1310, 40 + 72 * i, 320, 56, TABLE + "whiteSpace=wrap;html=1;", "S")

    p.e("e1", "A1", "B2", "1 copy + delete", exit=(1, 0.5), entry=(0, 0.5))
    p.e("e2", "B1", "B2", exit=(0.5, 1), entry=(0.5, 0))
    p.e("e3", "B2", "B3", exit=(0.5, 1), entry=(0.5, 0))
    p.e("e4", "B3", "B4", "files &gt; 0", style=EDGE.replace("edgeStyle=orthogonalEdgeStyle;", "edgeStyle=none;"), exit=(0.25, 0.75), entry=(0.5, 0))
    p.e("e5", "B3", "B5", "0", style=EDGE.replace("edgeStyle=orthogonalEdgeStyle;", "edgeStyle=none;"), exit=(0.75, 0.75), entry=(0.5, 0))
    p.e("e6", "B2", "C1", "2 writes", exit=(1, 0.5), entry=(0, 0.5))
    p.e("e7", "C1", "D1", "3 notebook reads", exit=(1, 0.5), entry=(0, 0.5))
    for k, a, b in (("d12", "D1", "D2"), ("d23", "D2", "D3"), ("d34", "D3", "D4"), ("d45", "D4", "D5")):
        p.e(k, a, b, exit=(0.5, 1), entry=(0.5, 0))
    p.e("m1", "D5", "C2", "ARCHIVE", exit=(0, 0.25), entry=(1, 0.5))
    p.e("m2", "D5", "C3", "DUPLICATE", exit=(0, 0.5), entry=(1, 0.5))
    p.e("m3", "D5", "C4", "ERROR", exit=(0, 0.75), entry=(1, 0.5))
    p.e("rc", "C4", "C2", "6", style=DASH, exit=(0, 0.5), entry=(0, 0.5), pts=[(670, 800), (670, 600)], offset=(-10, 0))
    # to / from the database (through the corridor between the two bands, y 870 to 910)
    p.e("q1", "B", "S1", "reads row", style=DASH, exit=(0.5, 1), entry=(0.5, 0))
    p.e("q2", "B", "S2", "STARTED / COLLECTED / NO_FILE", exit=(0.85, 1), entry=(0.3, 0), pts=[(572, 890), (764, 890)], offset=(0, -12))
    p.e("q3", "D", "S2", "OUTCOME, LOAD_FAILED", exit=(0.15, 1), entry=(0.7, 0), pts=[(1011, 880), (836, 880)], offset=(0, -12))
    p.e("q4", "D3", "S4", "3 INSERT stage + reject", exit=(1, 0.5), entry=(0.5, 0), pts=[(1470, 505)])
    p.e("q5", "D4", "S3", "4 EXEC", exit=(1, 0.75), entry=(0.75, 0), pts=[(1320, 622), (1320, 900), (1210, 900)])
    for i, k in enumerate(("S4", "S5", "S6", "S7")):
        p.e(f"w{i}", "S3", k, exit=(1, 0.2 + 0.2 * i), entry=(0, 0.5))
    p.e("w9", "S3", "S2", exit=(0, 0.5), entry=(1, 0.5))
    legend(p, 40, 1290, [(IDMC, "IDMC step"), (NB, "Notebook step"), (PROC, "SQL procedure"),
                         (TABLE, "SQL table / view"), (LAKE, "OneLake folder"), (DEC, "Decision"), (BAD, "Error folder")])
    p.v("note", "<b>Solid arrow</b> = writes / moves &nbsp;&nbsp; <b>Dashed arrow</b> = reads / reconcile", 320, 1300, 600, 30,
        "text;html=1;align=left;verticalAlign=middle;fontSize=12;")
    return p.xml(1760, 1500)


# ================================================================ page 2: notebook logic
def logic():
    p = Page("2 Notebook logic")
    title(p, "nb_matmas_process: what happens in the code, step by step",
          "Section numbers match the notebook. Right: what each step reads (blue) or updates (green).", 1500)
    CX, CW = 560, 300                       # centre column
    LX, LW = 140, 300                       # left column: waits, skips, failures
    RX, RW = 1080, 460                      # right column: reads / updates
    seq = []

    def step(k, label, y, h=60, style=BOX + NB):
        p.v(k, label, CX, y, CW, h, style); seq.append(k)

    def dec(k, label, y, h=100):
        p.v(k, label, CX + 20, y, CW - 40, h, DEC + "whiteSpace=wrap;html=1;fontSize=11;"); seq.append(k)

    def note(k, label, y, h, kind="w"):
        p.v(k, label, RX, y, RW, h, BOX + (NOTE_W if kind == "w" else NOTE_R) + "fontSize=11;")

    def side(k, label, y, h=70, style=BOX + WAIT):
        p.v(k, label, LX, y, LW, h, style + "fontSize=11;")

    p.v("start", "<b>Scheduled run</b> (every 15 min)", CX + 40, 100, CW - 80, 50, "ellipse;whiteSpace=wrap;html=1;" + NB); seq.append("start")
    step("conn", "<b>§2 connect</b><br>connect_to_artifact('sqldb-p2o-intg-dev')", 190)
    step("cfg", "<b>§3 load config</b><br>settings + active routes", 290)
    note("ncfg", "<b>READ</b> cfg.matmas_setting: onelake_root<br>→ /lakehouse/default/Files/erp_to_matmas/landing<br>"
         "<b>READ</b> cfg.matmas_route_config (active_flag = 1): route_id, onelake_folder,<br>target table, load_operation, start/end date values", 280, 80, "r")
    step("route", "<b>For each route</b><br>folder landing/&lt;onelake_folder&gt; (e.g. JDE)", 400)
    step("adopt", "<b>§4 adopt loose files</b><br>file dropped straight into landing/JDE/", 500)
    note("nadopt", "<b>MOVE (OneLake)</b> landing/JDE/file<br>→ landing/JDE/<b>NB&lt;yyyymmddhhmmss&gt;</b>/file", 500, 60)
    step("sweep", "<b>§4 sweep run folders</b><br>landing/JDE/&lt;RUN_ID&gt;/ (skip _design); oldest first", 600)
    dec("stable", "<b>All files stable?</b><br>unchanged 20 s<br>(or after a 20 s recheck)", 700)
    side("wstable", "<b>Wait</b>: files stay in landing,<br>next sweep checks again", 715)
    step("lock", "<b>§6a lock route</b><br>sp_getapplock matmas_&lt;route_id&gt;", 850)
    side("wlock", "<b>Skip</b>: another run is loading this route", 845, 60)
    note("nlock", "<b>SQL session lock</b> (released at the end of the run folder)", 860, 40, "r")
    dec("resume", "<b>Already LOADED / FAILED</b><br>for this run in run_log?", 950)
    note("nresume", "<b>READ</b> matmas.run_log events for run_id + route_id<br>(yes = an earlier run stopped before the move: move only)", 965, 60, "r")
    dec("coll", "<b>IDMC COLLECTED logged?</b><br>(NB folder, or older than 60 min = yes)", 1100)
    side("wcoll", "<b>Wait</b>: IDMC is still copying<br>this run's files", 1115)
    note("ncoll", "<b>READ</b> matmas.run_log: event COLLECTED for this run_id", 1130, 40, "r")
    step("parse", "<b>§5 parse</b><br>6 fields by position + start_date / end_date", 1250)
    note("nparse", "start_date = start_date_value or today, end_date = end_date_value or 9999-12-31<br>"
         "blank rows skipped; a row without 6 fields → reject row", 1250, 60, "r")
    dec("file", "<b>File usable?</b><br>not empty, header has 6 columns", 1350)
    side("ffile", "<b>LOAD_FAILED</b> (file cannot be read)<br>outcome = ERROR", 1365, 70, BOX + BAD)
    step("stage", "<b>§6e stage</b><br>delete leftovers, insert stage + rejects", 1500)
    note("nstage", "<b>DELETE</b> matmas.material_master_stage (stage_status NEW, this run)<br>"
         "<b>INSERT</b> matmas.material_master_stage: run_id, route_id, source_file_name,<br>6 fields, start_date, end_date (stage_status NEW)<br>"
         "<b>INSERT</b> matmas.material_master_reject: rows with a wrong field count", 1480, 100)
    dec("ins", "<b>Insert OK?</b>", 1610, 90)
    side("fins", "<b>LOAD_RETRY</b> attempt n of 5: files stay in landing<br>5th failure: <b>LOAD_FAILED</b>, outcome = ERROR", 1620, 70, BOX + BAD)
    step("apply", "<b>§6f EXEC matmas.sp_apply_route</b><br>validate keys + lengths, skip duplicate file,<br>de-duplicate, run the route's operation<br>(one transaction)", 1750, 100, BOX + PROC)
    note("napply", "<b>INSERT</b> matmas.material_master_reject: missing key / too long<br>"
         "<b>INSERT / MERGE / UPDATE / DELETE</b> matmas.&lt;erp&gt;_material_master<br>&nbsp;&nbsp;(load_operation; start_date kept on update)<br>"
         "<b>INSERT</b> matmas.file_history: SHA-256 fingerprint of each file<br>"
         "<b>UPDATE</b> material_master_stage.stage_status: APPLIED / REJECTED / DUPLICATE<br>"
         "<b>INSERT</b> matmas.run_log: LOADED (counts), DUPLICATE_FILE<br>"
         "on error: rollback, stage rows FAILED, <b>APPLY_FAILED</b>", 1720, 160)
    step("outc", "<b>§6g outcome</b><br>matmas.v_run_outcome: ARCHIVE / DUPLICATE / ERROR", 1950)
    note("noutc", "<b>READ</b> matmas.v_run_outcome (from this run's run_log events)", 1960, 40, "r")
    step("move", "<b>§6h move + log</b><br>landing → archive | duplicate | error /JDE/&lt;RUN_ID&gt;/", 2050, 70)
    note("nmove", "<b>MOVE (OneLake)</b> every file of the run folder, landing folder removed<br>"
         "<b>INSERT</b> matmas.run_log: OUTCOME (file_count, file names)", 2055, 60)
    dec("more", "<b>More run folders</b><br>in this route?", 2170, 90)
    step("recon", "<b>§7 reconcile</b><br>error/JDE/&lt;RUN_ID&gt; whose last load event is LOADED", 2310)
    note("nrecon", "after a fix + EXEC matmas.sp_reapply_run:<br><b>MOVE (OneLake)</b> error → archive, <b>INSERT</b> run_log OUTCOME (after reapply)", 2310, 60)
    dec("moreR", "<b>More routes?</b>", 2410, 80)
    step("exit", "<b>§9 exit value</b><br>JSON: runs, archive, duplicate, error, retry, rows", 2540)
    p.v("end", "End", CX + 90, 2640, CW - 180, 40, "ellipse;whiteSpace=wrap;html=1;" + NB)

    yes, no = "Yes", "No"
    down = dict(exit=(0.5, 1), entry=(0.5, 0))
    chain = ["start", "conn", "cfg", "route", "adopt", "sweep", "stable", "lock", "resume", "coll", "parse", "file",
             "stage", "ins", "apply", "outc", "move", "more", "recon", "moreR", "exit", "end"]
    label = {("stable", "lock"): yes, ("resume", "coll"): no, ("coll", "parse"): yes, ("file", "stage"): yes,
             ("ins", "apply"): yes, ("more", "recon"): no, ("moreR", "exit"): no}
    for a, b in zip(chain, chain[1:]):
        p.e(f"c_{a}", a, b, label.get((a, b), ""), **down)
    # left branches (failures, waits) leave the decision's left vertex and head left
    for d, s in (("stable", "wstable"), ("coll", "wcoll"), ("file", "ffile"), ("ins", "fins")):
        p.e(f"l_{d}", d, s, no, exit=(0, 0.5), entry=(1, 0.5))
    p.e("l_lock", "lock", "wlock", "lane in use", exit=(0, 0.5), entry=(1, 0.5))
    # failures that end in ERROR continue to the move step along the left corridor
    p.e("f1", "ffile", "move", "ERROR", exit=(0, 0.5), entry=(0, 0.7), pts=[(100, 1400), (100, 2099)])
    p.e("f2", "fins", "move", "5th failure: ERROR", exit=(0.5, 1), entry=(0, 0.3), pts=[(290, 2071)], offset=(0, -120))
    # resume: straight to the move step along the right corridor
    p.e("r1", "resume", "move", "Yes: move only", exit=(1, 0.5), entry=(1, 0.3), pts=[(920, 1000), (920, 2071)], offset=(0, -300))
    # loops
    p.e("lp1", "more", "stable", "Yes: next run folder", style=DASH, exit=(1, 0.5), entry=(1, 0.5), pts=[(960, 2215), (960, 750)], offset=(0, 520))
    p.e("lp2", "moreR", "route", "Yes: next route", style=DASH, exit=(1, 0.5), entry=(1, 0.5), pts=[(1000, 2450), (1000, 430)], offset=(0, 760))
    legend(p, 140, 2560, [(NB, "Notebook step"), (PROC, "SQL procedure"), (DEC, "Decision"), (WAIT, "Wait / skip (next sweep)"),
                          (BAD, "Failure"), (NOTE_W, "Updates (writes / moves)"), (NOTE_R, "Reads only")])
    return p.xml(1600, 2760)


# ================================================================ page 3: what gets updated
def updates():
    p = Page("3 What gets updated")
    title(p, "What each step updates",
          "In run order for one route and one run folder. Reads only: cfg.matmas_setting, cfg.matmas_route_config, matmas.run_log (events), matmas.v_run_outcome.", 1500)
    cols = [("#", 40), ("Step (who)", 250), ("Object", 330), ("Action", 150), ("What is written", 610)]
    rows = [
        ("IDMC  mt_P2O_101 Route Reader", "matmas.run_log (via stg.matmas_run_log)", "INSERT", "event STARTED, message 'row n of N on <agent group>'"),
        ("IDMC  fi_P2O_100", "OneLake landing/<ERP>/<RUN_ID>/", "WRITE file", "copy of every file matching the route's pattern"),
        ("IDMC  fi_P2O_100", "Source folder on the Secure Agent", "DELETE file", "after a successful copy"),
        ("IDMC  mt_P2O_104 Log", "matmas.run_log", "INSERT", "COLLECTED ('n file(s) copied to ...') or NO_FILE"),
        ("Notebook §4 adopt", "OneLake landing/<ERP>/", "MOVE file", "loose file → landing/<ERP>/NB<timestamp>/"),
        ("Notebook §6a", "SQL application lock matmas_<route_id>", "LOCK", "held while one run folder is processed"),
        ("Notebook §6e stage", "matmas.material_master_stage", "DELETE + INSERT", "removes NEW leftovers of this run; inserts run_id, route_id, source_file_name, 6 fields, start_date, end_date, stage_status NEW"),
        ("Notebook §6e stage", "matmas.material_master_reject", "DELETE + INSERT", "rows with a wrong field count (reason 'line n: x field(s), expected 6')"),
        ("sp_apply_route", "matmas.material_master_reject", "INSERT", "rows with a missing key or a value too long for the ERP table"),
        ("sp_apply_route", "matmas.<erp>_material_master", "INSERT / MERGE / UPDATE / DELETE", "per load_operation: 6 fields, start_date (kept on update), end_date, source_file_name, run_id, created_ts / updated_ts"),
        ("sp_apply_route", "matmas.file_history", "INSERT", "route_id, file_fingerprint (SHA-256), source_file_name, row_count, run_id"),
        ("sp_apply_route", "matmas.material_master_stage", "UPDATE", "stage_status APPLIED / REJECTED / DUPLICATE (FAILED on error)"),
        ("sp_apply_route", "matmas.run_log", "INSERT", "LOADED (staged, inserted, updated, deleted, rejected), DUPLICATE_FILE; APPLY_FAILED on error"),
        ("Notebook §6 failures", "matmas.run_log", "INSERT", "LOAD_FAILED (file unusable / 5th attempt) or LOAD_RETRY (attempt n of 5)"),
        ("Notebook §6h move", "OneLake archive | duplicate | error /<ERP>/<RUN_ID>/", "MOVE files", "every file of the run folder; empty landing folder removed"),
        ("Notebook §6h move", "matmas.run_log", "INSERT", "OUTCOME ('files go to ARCHIVE: <names>'), file_count"),
        ("Notebook §7 reconcile", "OneLake error → archive /<ERP>/<RUN_ID>/", "MOVE folder", "only after EXEC matmas.sp_reapply_run loaded the run"),
        ("Notebook §7 reconcile", "matmas.run_log", "INSERT", "OUTCOME ('files go to ARCHIVE (after reapply)')"),
    ]
    act_style = {"INSERT": NOTE_W, "UPDATE": "fillColor=#fff2cc;strokeColor=#d6b656;", "DELETE": BAD, "MOVE": LAKE,
                 "WRITE": NOTE_W, "LOCK": "fillColor=#f5f5f5;strokeColor=#666666;"}
    x0, y0, rh = 40, 100, 50
    hdr = "rounded=0;whiteSpace=wrap;html=1;fillColor=#333333;fontColor=#ffffff;fontStyle=1;strokeColor=#333333;"
    cell = "rounded=0;whiteSpace=wrap;html=1;fontSize=11;strokeColor=#bbbbbb;align=left;spacingLeft=6;"
    x = x0
    for i, (c, w) in enumerate(cols):
        p.v(f"h{i}", c, x, y0, w, 34, hdr); x += w
    for r, (who, obj, act, what) in enumerate(rows):
        y = y0 + 34 + r * rh
        who_style = IDMC if who.startswith("IDMC") else PROC if who.startswith("sp_") else NB
        key = next((k for k in act_style if act.startswith(k)), "INSERT")
        vals = [(esc(str(r + 1)), "fillColor=#ffffff;align=center;"), (esc(who), who_style),
                ("<b>" + esc(obj) + "</b>", "fillColor=#ffffff;"),
                (esc(act), act_style[key] + "align=center;fontStyle=1;"), (esc(what), "fillColor=#ffffff;")]
        x = x0
        for c, ((v, st), (_, w)) in enumerate(zip(vals, cols)):
            p.v(f"r{r}c{c}", v, x, y, w, rh, cell + st)      # v is HTML; p.v escapes it once more for the XML attribute
            x += w

    # worked example: the run_log trail of one run
    ty = y0 + 34 + len(rows) * rh + 60
    p.v("tt", "<b>Example: matmas.run_log for run_id 20261117090000 (JDE_MATMAS)</b>", 40, ty, 900, 30,
        "text;html=1;fontSize=14;align=left;verticalAlign=middle;")
    trail = [("STARTED", "IDMC reader", IDMC), ("COLLECTED", "IDMC log: 1 file copied", IDMC),
             ("LOADED", "sp_apply_route: inserted=1", PROC), ("OUTCOME", "notebook: files go to ARCHIVE", NB)]
    for i, (ev, who, st) in enumerate(trail):
        p.v(f"t{i}", f"<b>{ev}</b><br><font style='font-size:10px'>{who}</font>", 40 + i * 300, ty + 50, 220, 60,
            BOX + st)
        if i:
            p.e(f"te{i}", f"t{i-1}", f"t{i}", exit=(1, 0.5), entry=(0, 0.5))
    p.v("tq", "SELECT * FROM matmas.run_log WHERE run_id = '20261117090000' ORDER BY log_id;", 40, ty + 130, 900, 30,
        "text;html=1;fontSize=12;align=left;verticalAlign=middle;fontFamily=Courier New;")
    p.v("tn", "Same file again next day: DUPLICATE_FILE, LOADED (0 rows), OUTCOME → duplicate/JDE/&lt;RUN_ID&gt;/", 40, ty + 165, 900, 30,
        "text;html=1;fontSize=12;align=left;verticalAlign=middle;fontColor=#555555;")
    return p.xml(1460, ty + 260)


if __name__ == "__main__":
    out = sys.argv[1]
    xml = ('<?xml version="1.0" encoding="UTF-8"?>\n<mxfile host="drawio" version="26.0.0">'
           + overview() + logic() + updates() + "</mxfile>\n")
    open(out, "w", encoding="utf-8").write(xml)
    print("written", out)
