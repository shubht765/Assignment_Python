#!/usr/bin/env python3
"""
Build the IDMC import package for the MATMAS process (v1.2).

Every object format below is copied from real, published IDMC exports:
  * DTEMPLATE (mapping)       - org export Mapping58 (JDBC V2 target, connection, org ids)
                                + public export dheeraj2112/ETL_INFA_IICS_Snowflake_Project
                                  (Expression, Filter, SessionVariable = in-out parameter,
                                   flat-file source with FlatFileAttrs)
  * MTT (mapping task)        - public export (mtTask.json, inOutParameters, isFileList, srcFFAttrs)
  * MI_TASK (file ingestion)  - public source-control repos (local and Microsoft Fabric OneLake
                                 source/target, src.file.delete, oneLakeTargetLocation)
  * TASKFLOW (xml)            - public taskflows: assignment, exclusive decision (less-or-equals),
                                 jumpTo, Data Task with in-out parameters, Ingestion Task step with
                                 CATEGORY* overrides, Command Task with runtime environment formula
Guessed (no public sample found) - flagged in the README and in GUESSES below.

Usage: python3 build_matmas_import.py [--onelake-guid G --onelake-handle H] [--out PATH]
"""
import argparse, datetime as dt, hashlib, io, json, os, random, string, zipfile
from xml.sax.saxutils import escape

HERE = os.path.dirname(os.path.abspath(__file__))

# ------------------------------------------------------------------ org facts (from the org's own export)
ORG_ID, ORG_NAME = "kFCREt1YHueikzh0s4ZOsI", "Berry Global-Dev"
PROJECT_GUID, PROJECT = "kH5WfYrWOK1ggU0ocJ0X2n", "zPF_TCS_Shubham"
PATH = f"/Explore/{PROJECT}"
JDBC_GUID, JDBC_NAME = "1AIvTtPhmimhpwYPfj4G2j", "jdbcv2.MSSQL.sqldb-p2o-intg.stg"
AG = {"US.US02.01": ("9Nsrpw4jLaMha1GCSorpO0", "018Z0P2500000000000A"),
      "US.AMCOR.01": ("352BnvZuQA6iHi8ToR3t4Z", "018Z0P2500000000001P")}
CENTRAL_AG = "US.US02.01"
ONELAKE_NAME = "FABRIC.AMCOR.ONELAKE.P2O"
ONELAKE_ROOT = "lh_p2o_intg_dev/Files/erp_to_matmas"   # format of the org's own fi_P2O_000 task
ONELAKE_LAKEHOUSE_PATH = "lh_p2o_intg_dev/Files"           # lakehousePath of connection FABRIC.AMCOR.ONELAKE.P2O
ONELAKE_INTERNAL_NAME = "zzz_FABRIC.AMCOR.ONELAKE.P2O"    # name used inside the org's MI_TASK files

GUESSES = [
    "Ingestion Task step override paths CATEGORYGeneral/runtimeEnvironment, CATEGORYSource/sourceDirectory, "
    "CATEGORYTarget/oneLakeTargetLocation (pattern of the published CATEGORYSource/filePattern and CATEGORYTarget/s3TargetLocation)",
    "Taskflow: jumpTo and nested decisions placed inside a decision branch (UI allows it; no public sample of this exact nesting)",
    "Load mapping OneLake source adapter (no public mapping reads OneLake): confirm connection, folder read and format after import",
]

STRING = "smd:com.informatica.metadata.seed.platform.Platform.typesystem/string"
INTEGER = "smd:com.informatica.metadata.seed.platform.Platform.typesystem/integer"
DATETIME = "smd:com.informatica.metadata.seed.platform.Platform.typesystem/date/time"

CLASS = ["com.informatica.metadata.template.common.Template",                       # 1
         "com.informatica.metadata.common.description.Description",                 # 2
         "com.informatica.metadata.template.common.layout.LayoutAnnotation",        # 3
         "com.informatica.metadata.common.genericannotation.GenericAnnotation",     # 4
         "com.informatica.metadata.template.common.TmplLink",                       # 5
         "com.informatica.metadata.template.common.TmplGroup",                      # 6
         "com.informatica.metadata.template.tx.tmplsource.TmplSource",              # 7
         "com.informatica.metadata.template.tx.tmplexpression.TmplExpression",      # 8
         "com.informatica.metadata.template.tx.tmplfilter.TmplFilter",              # 9
         "com.informatica.metadata.template.tx.tmpltarget.TmplTarget",              # 10
         "com.informatica.metadata.template.common.SessionVariable",                # 11
         "com.informatica.metadata.common.typesystem.DataType",                     # 12
         "com.informatica.metadata.common.genericannotation.NameValuePair",         # 13
         "com.informatica.metadata.template.common.TxAdvancedProperty",             # 14
         "com.informatica.metadata.template.ext.da.cloud.common.BaseAdapter",       # 15
         "com.informatica.metadata.template.common.field.TxField",                  # 16
         "com.informatica.metadata.template.ext.da.cloud.common.BaseAdapterField",  # 17
         "com.informatica.metadata.template.tx.tmpltarget.FieldMappings",           # 18
         "com.informatica.metadata.template.tx.tmplexpression.TmplExpressionField", # 19
         "com.informatica.metadata.template.tx.tmplexpression.TmplExpressionWindowSpec",  # 20
         "com.informatica.metadata.common.types.StringValue",                       # 21
         "com.informatica.metadata.common.types.BooleanValue",                      # 22
         "com.informatica.metadata.template.ext.da.cloud.common.DataObject",        # 23
         "com.informatica.metadata.template.ext.da.cloud.common.RuntimeAttributes", # 24
         "com.informatica.metadata.template.ext.da.cloud.common.ReadOptions",       # 25
         "com.informatica.metadata.template.common.rule.TmplAllRule",               # 26
         "com.informatica.metadata.template.ext.da.cloud.common.WriteOptions",      # 27
         "com.informatica.metadata.template.ext.da.cloud.common.FlatFileAttrs",     # 28
         "com.informatica.metadata.template.ext.da.cloud.common.Option",            # 29
         "com.informatica.metadata.template.tx.tmpltarget.FieldMapping"]            # 30
C = {n.rsplit(".", 1)[1]: i + 1 for i, n in enumerate(CLASS)}
CLASS_INFO = {str(i + 1): n for i, n in enumerate(CLASS)}


RNG = random.Random(20261116)   # fixed seed: rebuilt packages keep the same asset GUIDs


def guid():
    a = string.ascii_letters + string.digits
    return "".join(RNG.choice(a) for _ in range(22))


def now_iso():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def now_ms():
    return int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000)


# ================================================================== mapping (DTEMPLATE) builder
class M:
    TYPES = {"string": (STRING, "nvarchar", "java.lang.String", 0),
             "integer": (INTEGER, "int", "java.lang.Integer", 0),
             "date": (DATETIME, "date", "java.sql.Date", 9)}

    def __init__(self, name, desc):
        self.name, self.desc, self.n = name, desc, 0
        self.tx, self.links, self.vars, self.layout, self.conns = [], [], [], {}, set()

    def id(self):
        self.n += 1
        return self.n

    def adv(self, k, v):
        return {"$$ID": self.id(), "$$class": C["TxAdvancedProperty"], "name": k, "value": v}

    def group(self, inp, out):
        g = {"$$ID": self.id(), "$$class": C["TmplGroup"], "input": inp, "name": "DefaultGroup", "output": out}
        if inp == "true":
            g["rules"] = [{"$$ID": self.id(), "$$class": C["TmplAllRule"], "bulkRename": "false", "include": "true"}]
        return g

    def adapter_field(self, name, typ, prec, parent, native=None, ff=False):
        sid, ntype, jtype, scale = self.TYPES[typ]
        f = {"$$ID": self.id(), "$$class": C["BaseAdapterField"], "name": name,
             "annotations": [{"$$ID": self.id(), "$$class": C["Description"], "body": ""}],
             "createable": "false", "externalId": "false", "fieldStatus": "MODIFIED" if ff else "ORIGINAL",
             "fieldType": "CONNECTOR", "filterable": "true", "foreignKey": "false", "generated": "false",
             "javaType": "" if ff else jtype, "key": "false", "label": native or name, "nativeName": native or name,
             "nativeType": "nstring" if ff else ntype, "newField": "false", "nullable": "true", "original": "false",
             "passthroughPort": "false", "precision": prec, "scale": scale, "sfIdLookup": "false", "unique": "false",
             "updateable": "true"}
        if not ff:
            f["metaExtensions"] = [{"$$ID": self.id(), "$$class": C["Option"], "name": "isPartitionKey", "value": "false"}]
        f["properties"] = [{"$$ID": self.id(), "$$class": C["Option"], "name": "parentObject", "value": parent},
                           {"$$ID": self.id(), "$$class": C["Option"], "name": "parentObjectLabel", "value": ""}]
        return f

    def tx_field(self, af, typ):
        sid = self.TYPES[typ][0]
        return {"$$ID": self.id(), "$$class": C["TxField"], "adapterField": {"##ID": af["$$ID"], "$$class": C["BaseAdapterField"]},
                "defaultValue": "", "ignoreComparison": "false", "ignoreNullInputs": "false", "isDefaultValueUpdated": "false",
                "name": af["name"], "platformType": {"##SID": sid, "$$class": C["DataType"]},
                "precision": af["precision"], "scale": af["scale"]}

    def _adapter(self, conn, type_system, obj, read=False, write=False):
        self.conns.add(conn)
        da = {"$$ID": self.id(), "$$class": C["BaseAdapter"], "name": "", "codePage": "", "compatibleEngine": "",
              "connectionId": "saas:@" + conn, "connectionSelectionType": "", "excludeDynamicFileNameField": "false",
              "fwConfigId": "", "multipleObject": "false", "objectType": "SINGLE", "typeSystem": type_system,
              "useDynamicFileName": "false", "object": obj, "oprRuntimeAttributes": {"$$ID": self.id(), "$$class": C["RuntimeAttributes"]}}
        if read:
            da["readOptions"] = {"$$ID": self.id(), "$$class": C["ReadOptions"], "commandType": 0, "descending": "false",
                                 "filterCondition": "", "flatFileCommand": "", "queryAll": "false", "rowLimit": 0,
                                 "selectDistinct": "false", "userDefinedJoin": "", "advancedFilterCondition": "",
                                 "requestXml": "", "sortFieldValues": ""}
        da["runtimeAttributes"] = {"$$ID": self.id(), "$$class": C["RuntimeAttributes"]}
        if write:
            da["writeOptions"] = {"$$ID": self.id(), "$$class": C["WriteOptions"], "batchSize": 0, "bulkApi": "false",
                                  "errorFileDirectory": "", "errorFilePrefix": "", "handleDecimalRoundOff": "false",
                                  "handleSpecialChars": "false", "operations": ["Insert"], "setFieldsToNull": "false",
                                  "successFileDirectory": "", "successFilePrefix": "", "truncate": "false",
                                  "updateStrategyExpression": "", "useErrorFile": "false", "useExactSrcNames": "false",
                                  "useSuccessFile": "false"}
        return da

    def _obj(self, name, fields, file_attrs=None):
        o = {"$$ID": self.id(), "$$class": C["DataObject"], "name": name, "customQuery": "", "dbSchema": "", "label": name,
             "objectName": name if file_attrs else "", "objectType": "", "parentPath": "", "path": name,
             "retainMetadata": "false"}
        if file_attrs:
            o["fileAttrs"] = dict({"$$ID": self.id(), "$$class": C["FlatFileAttrs"]}, **file_attrs)
        o["fields"] = fields
        return o

    def source(self, txname, conn, objname, cols, flat_file=None, x=100):
        afs = [self.adapter_field(n, t, p, objname, native=nat, ff=bool(flat_file)) for n, t, p, nat in cols]
        t = {"$$ID": self.id(), "$$class": C["TmplSource"], "augmented": "false", "createTime": now_iso(), "name": txname,
             "advancedProperties": [self.adv("Tracing Level", "Normal"), self.adv("Pre SQL", ""), self.adv("Post SQL", ""),
                                    self.adv("Sql Override", ""), self.adv("Output is deterministic", "false"),
                                    self.adv("Output is repeatable", "")],
             "groups": [self.group("false", "true")], "generateFilenamePort": "false", "useLabels": "false",
             "useSequenceFields": "false", "fields": [self.tx_field(a, c[1]) for a, c in zip(afs, cols)]}
        t["dataAdapter"] = self._adapter(conn, "CSVFile" if flat_file else "TOOLKIT",
                                         self._obj(objname, afs, flat_file), read=True)
        self.tx.append(t); self.layout[txname] = {"x": x, "y": 100}
        return t

    def expression(self, txname, fields, x=300):
        t = {"$$ID": self.id(), "$$class": C["TmplExpression"], "createTime": now_iso(), "name": txname,
             "groups": [self.group("true", "true")], "additionalFields": "", "windowConfigurationEnabled": "false",
             "fields": [], "windowSpec": None}
        for name, kind, typ, prec, expr in fields:
            sid, _, _, scale = self.TYPES[typ]
            t["fields"].append({"$$ID": self.id(), "$$class": C["TmplExpressionField"], "defaultValue": "",
                                "ignoreComparison": "false", "ignoreNullInputs": "false", "isDefaultValueUpdated": "true",
                                "name": name, "platformType": {"##SID": sid, "$$class": C["DataType"]},
                                "precision": prec, "scale": scale, "expFieldType": kind, "expression": expr,
                                "macroOutputPrefix": "", "macroOutputSuffix": "", "selectedMacroInput": "", "variable": "false"})
        t["windowSpec"] = {"$$ID": self.id(), "$$class": C["TmplExpressionWindowSpec"], "allRowsFollowing": "false",
                           "allRowsPreceding": "false", "endOffset": 0, "startOffset": 0, "partitionKeys": []}
        self.tx.append(t); self.layout[txname] = {"x": x, "y": 100}
        return t

    def filter(self, txname, cond, x=500):
        t = {"$$ID": self.id(), "$$class": C["TmplFilter"], "createTime": now_iso(), "name": txname,
             "groups": [self.group("true", "true")], "advancedFilterCondition": cond}
        self.tx.append(t); self.layout[txname] = {"x": x, "y": 100}
        return t

    def target(self, txname, conn, objname, cols, post_sql="", x=700, field_map=None):
        afs = [self.adapter_field(n, t, p, objname) for n, t, p in cols]
        t = {"$$ID": self.id(), "$$class": C["TmplTarget"], "augmented": "false", "createTime": now_iso(), "name": txname,
             "advancedProperties": [self.adv("Forward Rejected Rows", "true"), self.adv("Pre SQL", ""),
                                    self.adv("Post SQL", post_sql), self.adv("Update Override", "")],
             "groups": [self.group("true", "false")], "createTarget": "false",
             "fieldMappingMode": "MANUAL" if field_map else "BY_NAME",
             "inputSorted": "false", "schemaProviderType": "SELECTED_OBJECT", "targetFieldsOrdered": "false",
             "updateColumns": [], "useLabels": "false", "useSequenceFields": "false",
             "fields": [self.tx_field(a, c[1]) for a, c in zip(afs, cols)]}
        t["dataAdapter"] = self._adapter(conn, "TOOLKIT", self._obj(objname, afs), write=True)
        t["manualMappings"] = {"$$ID": self.id(), "$$class": C["FieldMappings"]}
        if field_map:   # same layout as the MANUAL targets in real exports: fromFieldName -> target TxField
            t["manualMappings"]["mappingList"] = [
                {"$$ID": self.id(), "$$class": C["FieldMapping"], "fromFieldName": field_map.get(f["name"], f["name"]),
                 "toField": {"##ID": f["$$ID"], "$$class": C["TxField"]}} for f in t["fields"]]
        self.tx.append(t); self.layout[txname] = {"x": x, "y": 100}
        return t

    def link(self, a, b):
        ga = next(g for g in a["groups"] if g["output"] == "true")
        gb = next(g for g in b["groups"] if g["input"] == "true")
        self.links.append({"$$ID": self.id(), "$$class": C["TmplLink"], "name": f"{a['name']}.Edge",
                           "fromGroup": {"##ID": ga["$$ID"], "$$class": C["TmplGroup"]},
                           "fromTransformation": {"##ID": a["$$ID"], "$$class": a["$$class"]},
                           "toGroup": {"##ID": gb["$$ID"], "$$class": C["TmplGroup"]},
                           "toTransformation": {"##ID": b["$$ID"], "$$class": b["$$class"]}})

    def variable(self, name, typ="string", prec=1000, default=""):
        sid, _, _, scale = self.TYPES[typ]
        self.vars.append({"$$ID": self.id(), "$$class": C["SessionVariable"], "aggregationType": "MAX",
                          "expressionVariable": "false", "name": name, "platformType": {"##SID": sid, "$$class": C["DataType"]},
                          "precision": prec, "retentionPolicy": "ON_SUCCESS", "scale": scale,
                          "defaultValue": default, "description": ""})

    def document(self):
        ann = [{"$$ID": self.id(), "$$class": C["Description"], "body": self.desc},
               {"$$ID": self.id(), "$$class": C["LayoutAnnotation"], "jsonBlob": json.dumps(self.layout, separators=(",", ":")), "templateId": ""},
               {"$$ID": self.id(), "$$class": C["GenericAnnotation"], "source": "TEMPLATE_SETTINGS", "nameValuePairs": [
                   {"$$ID": self.id(), "$$class": C["NameValuePair"], "name": "UNIQUIFY_MAPPLET_TX_NAMES_OPTIONS",
                    "value": {"$$class": C["StringValue"], "valueLiteral": "{\"nonNativeMappletTx\":true}"}},
                   {"$$ID": self.id(), "$$class": C["NameValuePair"], "name": "UNIQUIFY_MAPPLET_TX_NAMES",
                    "value": {"$$class": C["BooleanValue"], "value": "true"}}]}]
        content = {"$$IID": "stringIdentity:@3", "$$class": C["Template"], "annotations": ann,
                   "allowMaxFieldLength": False, "bigIntConvertType": "ONLY_BIGINT", "documentType": "MAPPING",
                   "ecoSystem": "", "name": self.name, "specialCharacterSupport": False, "templateOrigin": "",
                   "links": self.links, "transformations": self.tx, "variables": self.vars}
        return {"content": content, "metadata": {"$$classInfo": CLASS_INFO}}


def log_cols():
    return [("run_id", "string", 30), ("route_id", "string", 60), ("event", "string", 30), ("message", "string", 4000)]


READER_OUT = ["TOTAL_ROUTES", "ROUTE_ID", "ERP_SYSTEM", "RUNTIME_ENVIRONMENT", "SOURCE_DIRECTORY", "FILE_PATTERN",
              "ONELAKE_LANDING_DIR", "ONELAKE_ARCHIVE_DIR", "ONELAKE_DUPLICATE_DIR",
              "ONELAKE_ERROR_DIR", "TARGET_TABLE", "LOAD_OPERATION", "START_DATE_VALUE", "END_DATE_VALUE"]


def m_reader(name):
    m = M(name, "MATMAS: read row $$ROW_ID of the route config into in-out parameters for the taskflow; log STARTED.")
    m.variable("RUN_GROUP", default="DAILY"); m.variable("ROW_ID", "integer", 10, "1"); m.variable("RUN_ID", prec=30)
    for p in READER_OUT:
        m.variable(p)
    # stg.matmas_route_reader columns (lower case, as in the SQL standard); $$ parameters stay upper case
    cols = [("row_num", "integer", 10, None), ("total_routes", "integer", 10, None), ("run_group", "string", 30, None),
            ("route_id", "string", 60, None), ("erp_system", "string", 30, None), ("runtime_environment", "string", 100, None),
            ("source_connection", "string", 100, None), ("source_directory", "string", 500, None),
            ("file_pattern", "string", 200, None),
            ("onelake_connection", "string", 100, None), ("onelake_landing_dir", "string", 500, None),
            ("onelake_archive_dir", "string", 500, None), ("onelake_duplicate_dir", "string", 500, None),
            ("onelake_error_dir", "string", 500, None), ("target_table", "string", 300, None),
            ("load_operation", "string", 20, None), ("start_date_value", "string", 10, None),
            ("end_date_value", "string", 10, None), ("notify_email", "string", 400, None)]
    s = m.source("src_Route", JDBC_GUID, "matmas_route_reader", cols, x=100)
    f = m.filter("flt_Row", "run_group = $$RUN_GROUP AND row_num = $$ROW_ID", x=300)
    fields = [(f"v_{i+1:02d}", "VARIABLE", "string", 1000,
               f"SETVARIABLE($${p}, {'TO_CHAR(total_routes)' if p == 'TOTAL_ROUTES' else p.lower()})") for i, p in enumerate(READER_OUT)]
    fields += [("run_id", "OUTPUT", "string", 30, "$$RUN_ID"), ("event", "OUTPUT", "string", 30, "'STARTED'"),
               ("message", "OUTPUT", "string", 4000,
                "'row ' || TO_CHAR(row_num) || ' of ' || TO_CHAR(total_routes) || ' on ' || runtime_environment")]
    e = m.expression("exp_SetParams", fields, x=500)
    t = m.target("tgt_RunLog", JDBC_GUID, "matmas_run_log", log_cols(), x=700)
    m.link(s, f); m.link(f, e); m.link(e, t)
    return m


HEADER = [("ERP_Item_Number", "ERP Item Number"), ("Material_Description", "Material Description"),
          ("Plant_Code", "Plant Code"), ("Supplier_Part_", "Supplier Part#"), ("Supplier_Number", "Supplier Number"),
          ("Manufacturing_Part_", "Manufacturing Part#")]   # field names as CDI derives them from the file header
STAGE_COLS = ["erp_item_number", "material_description", "plant_code", "supplier_part_number", "supplier_number",
              "manufacturing_part_number"]                  # stg.matmas_stage_file columns, same order as HEADER


def m_load(name, onelake_guid):
    m = M(name, "MATMAS: OneLake run folder -> 6 file fields + RUN/ROUTE/START_DATE/END_DATE -> stage; Post SQL applies to the ERP table.")
    for p, d in (("RUN_ID", ""), ("ROUTE_ID", ""), ("SRC_DIRECTORY", ""), ("START_DATE_VALUE", ""), ("END_DATE_VALUE", "9999-12-31")):
        m.variable(p, default=d)
    s_ = m.source("src_OneLakeFiles", onelake_guid, "erp_to_matmas/landing/JDE/_design/JDE_MATMAS_20261116.txt",
                  [(n, "string", 1000, nat) for n, nat in HEADER], x=100)
    fields = [("run_id", "OUTPUT", "string", 30, "$$RUN_ID"), ("route_id", "OUTPUT", "string", 60, "$$ROUTE_ID"),
              ("source_file_name", "OUTPUT", "string", 500, "$$SRC_DIRECTORY"),
              ("start_date", "OUTPUT", "date", 29,
               "IIF(ISNULL($$START_DATE_VALUE) OR LTRIM(RTRIM($$START_DATE_VALUE)) = '', TRUNC(SESSSTARTTIME, 'DD'), TO_DATE($$START_DATE_VALUE, 'YYYY-MM-DD'))"),
              ("end_date", "OUTPUT", "date", 29,
               "TO_DATE(IIF(ISNULL($$END_DATE_VALUE) OR LTRIM(RTRIM($$END_DATE_VALUE)) = '', '9999-12-31', $$END_DATE_VALUE), 'YYYY-MM-DD')")]
    e = m.expression("exp_AddDates", fields, x=300)
    f = m.filter("flt_NotBlank", "LENGTH(LTRIM(RTRIM(" + " || ".join(n for n, _ in HEADER) + "))) > 0", x=500)
    cols = [("run_id", "string", 30), ("route_id", "string", 60), ("source_file_name", "string", 500)]
    cols += [(c, "string", 1000) for c in STAGE_COLS] + [("start_date", "date", 10), ("end_date", "date", 10)]
    # file header field -> lower-case stage column (MANUAL field mapping); the other fields map to themselves
    fmap = {c: n for c, (n, _) in zip(STAGE_COLS, HEADER)}
    t = m.target("tgt_Stage", JDBC_GUID, "matmas_stage_file", cols, post_sql="EXEC matmas.sp_apply_stage", x=700,
                 field_map=fmap)
    m.link(s_, e); m.link(e, f); m.link(f, t)
    return m


def m_outcome(name):
    m = M(name, "MATMAS: read ARCHIVE / DUPLICATE / ERROR for this run and route into $$OUTCOME; log it.")
    for p in ("RUN_ID", "ROUTE_ID", "OUTCOME"):
        m.variable(p, prec=60)
    s = m.source("src_Outcome", JDBC_GUID, "matmas_run_outcome",
                 [("run_id", "string", 30, None), ("route_id", "string", 60, None), ("outcome", "string", 20, None)], x=100)
    f = m.filter("flt_Run", "run_id = $$RUN_ID AND route_id = $$ROUTE_ID", x=300)
    e = m.expression("exp_SetOutcome", [("v_01", "VARIABLE", "string", 20, "SETVARIABLE($$OUTCOME, outcome)"),
                                        ("event", "OUTPUT", "string", 30, "'OUTCOME'"),
                                        ("message", "OUTPUT", "string", 4000, "'files go to ' || outcome")], x=500)
    t = m.target("tgt_RunLog", JDBC_GUID, "matmas_run_log", log_cols(), x=700)
    m.link(s, f); m.link(f, e); m.link(e, t)
    return m


def m_log(name):
    m = M(name, "MATMAS: write one event (NO_FILE, COLLECT_FAILED, ...) from in-out parameters.")
    for p in ("RUN_ID", "ROUTE_ID", "EVENT", "MESSAGE"):
        m.variable(p, prec=4000 if p == "MESSAGE" else 60)
    s = m.source("src_OneRow", JDBC_GUID, "matmas_one_row", [("one", "integer", 10, None)], x=100)
    e = m.expression("exp_Event", [("run_id", "OUTPUT", "string", 30, "$$RUN_ID"), ("route_id", "OUTPUT", "string", 60, "$$ROUTE_ID"),
                                   ("event", "OUTPUT", "string", 30, "$$EVENT"), ("message", "OUTPUT", "string", 4000, "$$MESSAGE")], x=300)
    t = m.target("tgt_RunLog", JDBC_GUID, "matmas_run_log", log_cols(), x=500)
    m.link(s, e); m.link(e, t)
    return m


# ================================================================== packaging helpers
def zbytes(entries):
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w", zipfile.ZIP_DEFLATED) as z:
        for p, d in entries:
            z.writestr(p, d)
    return b.getvalue()


def dumps(o):
    return json.dumps(o, separators=(",", ":")).encode()


def tiny_jpeg(title):
    try:
        from PIL import Image, ImageDraw
        img = Image.new("RGB", (819, 300), "white"); ImageDraw.Draw(img).text((20, 20), title, fill="black")
        b = io.BytesIO(); img.save(b, "JPEG"); return b.getvalue()
    except ImportError:
        return bytes.fromhex("ffd8ffe000104a46494600010101004800480000ffd9")


def dtemplate(m, mguid):
    body = dumps(m.document()); jpg = tiny_jpeg(m.name); t = now_ms()
    refs = [{"@type": "reference", "refObjectId": "@" + c, "refType": "connection"} for c in sorted(m.conns)]
    mt = [{"@type": "mappingTemplate", "id": "@1", "name": m.name, "description": m.desc, "autoExpireObject": False,
           "bundleVersion": "0", "assetFrsGuid": mguid, "templateId": "@3", "deployTime": t, "hasParameters": False,
           "valid": True, "fixedConnection": True, "hasParametersDeployed": False, "fixedConnectionDeployed": True,
           "isSchemaValidationEnabled": False, "tasks": 1, "mappingPreviewFileRecordId": "@2", "documentType": "MAPPING",
           "allowMaxFieldLength": False, "specialCharacterSupport": False, "references": refs}]
    fr = [{"@type": "fileRecord", "id": "@3", "name": m.name, "type": "IMFOBJECT", "size": len(body), "attachTime": t,
           "additionalInfo": "com.informatica.metadata.template.common.Template"},
          {"@type": "fileRecord", "id": "@2", "name": m.name + "_preview.jpeg", "type": "IMAGE", "size": len(jpg), "attachTime": t}]
    return zbytes([("metadata.meta", dumps([{"@type": "objectRef", "id": "@1", "type": "mappingTemplate"}])),
                   ("mappingTemplate.json", dumps(mt)), ("fileRecord.json", dumps(fr)), ("bin/@3.bin", body), ("bin/@2.bin", jpg)])


def mt_param(kind, txname, conn, obj, extra=None):
    p = {"@type": "mtTaskParameter", "id": random.randint(10**7, 10**8), "name": f"${txname}$", "type": kind, "label": txname,
         "uiProperties": {"connectionParameterized": "false", "objectParameterized": "false", "visible": "false",
                          "originalPath": txname}, "newFlatFile": False, "newObject": False, "showBusinessNames": False,
         "naturalOrder": True, "truncateTarget": False, "bulkApiDBTarget": False,
         "customFuncCfg": {"@type": "customFuncConfig", "id": -1, "connections": [], "inputMap": [], "outputFields": []},
         "targetRefsV2": {}, "targetUpdateColumns": [], "runtimeAttrs": {}, "isRESTModernSource": True, "isFileList": False,
         "handleSpecialChars": False, "handleDecimalRoundOff": False, "frsAsset": False, "dynamicFileName": False,
         "excludeDynamicFileNameField": False, "currentlyProcessedFileName": False, "retainFieldMetadata": False,
         "objectName": obj, "useExactSrcNames": False, "tgtObjectAttributes": {},
         "runtimeParameterData": {"@type": "mtTaskRuntimeParameterData", "isConnectionRuntimeParameter": False,
                                  "isObjectRuntimeParameter": False}, "overridableProperties": [], "overriddenFields": []}
    if kind == "SOURCE":
        p["uiProperties"]["isSelectDistinct"] = "false"; p["sourceConnectionId"] = "@" + conn; p["sourceObject"] = obj; p["customQuery"] = ""
    else:
        p["uiProperties"].update({"defaultTargetUpdateColumns": "", "supportApplyDDLChanges": "true"})
        p.update({"targetConnectionId": "@" + conn, "targetObject": obj, "targetObjectLabel": obj, "operationType": "Insert",
                  "extendedObject": {"@type": "extendedObject", "singleMode": True, "filters": [], "sortFields": []}})
    p.update(extra or {})
    return p


def mtt(name, mt_guid, m_guid, m, params):
    inout = [{"@type": "mtTaskInOutParameter", "id": "-1", "name": v["name"], "description": "",
              "initialValue": v["defaultValue"], "datatype": "INTEGER" if v["platformType"]["##SID"] == INTEGER else "STRING",
              "precision": str(v["precision"]), "scale": "0", "retentionPolicy": "ON_SUCCESS", "aggregationType": "MAX",
              "currentValue": v["defaultValue"]} for v in m.vars]
    task = [{"@type": "mtTask", "id": "@1", "name": name, "runtimeEnvironmentId": "@" + AG[CENTRAL_AG][0], "maxLogs": 10,
             "verbose": False, "mappingId": "@" + m_guid, "frsGuid": mt_guid,
             "sessionPropertiesList": [{"name": "Pushdown Optimization", "value": "None", "recommended": False},
                                       {"name": "Stop on errors", "value": "0", "recommended": False}],
             "hidden": False, "enableCrossSchemaPushdown": True, "enableParallelRun": False, "autoTunedApplied": False,
             "autoTunedAppliedType": "NONE", "paramFileType": "PARAM_FILE_LOCAL", "schemaMode": "async", "valid": True,
             "schemaValidationErrorCount": -1, "serverlessProperties": {},
             "taskProperties": [{"@type": "taskProperty", "name": "parameterFileDir", "currentValue": "", "type": "STRING",
                                 "label": "label.parameterFileDir", "required": False},
                                {"@type": "taskProperty", "name": "parameterFileName", "currentValue": "", "type": "STRING",
                                 "label": "label.parameterFileName", "required": False}],
             "optimizationPlan": "NONE", "isMidstreamPreview": False, "parameters": params, "sequences": [],
             "inOutParameters": inout, "connRuntimeAttrs": []}]
    return zbytes([("metadata.meta", dumps([{"@type": "objectRef", "id": "@1", "type": "mtTask"}])), ("mtTask.json", dumps(task))])


def mi_task(name, mi_guid, ag_name, src, tgt, src_path, pattern, tgt_path, delete, onelake, handle):
    """Same keys and order as the org's own export of fi_P2O_000_BPDWFS_GR_to_OneLake.MI_TASK.dat."""
    def conn(kind):
        if kind == "local":
            return {"type": "local", "name": "", "displayName": None, "connId": ""}
        return {"type": "Fabric OneLake", "name": ONELAKE_INTERNAL_NAME, "displayName": None, "connId": onelake[1]}
    src_opts = {"filePatternFilter": "true", "src.file.pattern": pattern, "src.file.delete": delete,
                "src.download.path": src_path, "filePickupOption": "PATTERN", "srcPushdownCopy": "false",
                "src.file.pattern.type": "WILDCARD", "batchSize": "5", "fileStability": "false"}
    tgt_opts = ({"oneLakeTargetLocation": tgt_path, "compression": "None", "fileExistsAction": "OVERWRITE"} if tgt != "local"
                else {"fileExistsAction": "OVERWRITE", "tgt.download.path": tgt_path})
    d = {"orgId": ORG_ID, "icsGuid": mi_guid, "name": name, "id": int(handle), "description": "MATMAS - generated",
         "sourceType": "CONNECTION", "sourceConnection": conn(src), "targetConnection": conn(tgt), "taskActions": [],
         "lastModified": now_ms(), "sourceOptions": src_opts, "targetOptions": tgt_opts, "agentGroup": AG[ag_name][1],
         "job": "", "schedule": None, "fileListener": None, "fileListenerName": None, "fileListenerAction": None,
         "emailIds": None, "filePickupOption": "PATTERN", "lastRun": None, "threadCount": 1, "logLevel": "NORMAL",
         "allowConcurrency": False, "fileListenerAsSource": False, "fileListenerAsTrigger": False, "identifier": handle}
    return json.dumps(d, separators=(",", ":")).encode()


# ================================================================== taskflow (xml) builder
# Element builders return xml for ONE element. `nxt` is the id of the following element in the same
# flow, or None when the element is the last one of a decision branch (the branch then ends with a
# flow-level containerLink back to its decision, exactly like the published taskflows).
class TF:
    def __init__(self):
        self.n, self.temp, self.po = 0, [], {}

    def id(self):
        self.n += 1
        return f"mm{self.n:06d}"

    @staticmethod
    def x(s):
        return escape(s, {'"': "&quot;"})

    def lnk(self, nxt):
        return f'<link id="{self.id()}" targetId="{nxt}"/>' if nxt else ""

    def catch(self, step, ignore):
        return (f'<events><catch faultField="temp.{step}/fault" id="{self.id()}" interrupting="true" name="error">'
                f'{"" if ignore else "<suspend/>"}</catch></events>')

    def assignment(self, own, nxt, title, ops):
        body = "".join(f'<operation source="formula" to="{t}"><expression language="XQuery">{self.x(e)}</expression></operation>'
                       for t, e in ops)
        return f'<assignment id="{own}"><title>{self.x(title)}</title>{body}{self.lnk(nxt)}</assignment>'

    def data_task(self, own, nxt, step, task, guid, inout_in, inout_out, ignore=False):
        po = f"{task.replace('_', '-')}-{guid}"
        self.po[po] = "mt"
        self.temp.append(f'<field description="" name="{step}" type="reference"><options><option name="referenceTo">$po:{po}</option>'
                         f'<option name="failOnNotRun">false</option><option name="failOnFault">false</option></options></field>')
        ins = "".join(f'<operation source="formula" to="{po}/inout[1]/{k}"><expression language="XQuery">{self.x(v)}</expression></operation>'
                      for k, v in inout_in)
        std = [("Object_Name", "Object Name"), ("Run_Id", "Run Id"), ("Log_Id", "Log Id"), ("Task_Id", "Task Id"),
               ("Task_Status", "Task Status"), ("Success_Source_Rows", "Success Source Rows"),
               ("Failed_Source_Rows", "Failed Source Rows"), ("Success_Target_Rows", "Success Target Rows"),
               ("Failed_Target_Rows", "Failed Target Rows"), ("Start_Time", "Start Time"), ("End_Time", "End Time"),
               ("Error_Message", "Error Message")]
        outs = "".join(f'<operation source="field" to="temp.{step}/output/{a}">{b}</operation>' for a, b in std)
        outs += "".join(f'<operation source="field" to="temp.{step}/inout/{k}">{k}</operation>' for k in inout_out)
        return (f'<eventContainer id="{own}"><service id="{self.id()}"><title>{step}</title><serviceName>ICSExecuteDataTask</serviceName>'
                f'<serviceGUID/><serviceInput>'
                f'<parameter name="Wait for Task to Complete" source="constant" updatable="true">true</parameter>'
                f'<parameter name="Max Wait" source="constant" updatable="true">604800</parameter>'
                f'<parameter name="Task Name" source="constant" updatable="true">{task}</parameter>'
                f'<parameter name="GUID" source="constant" updatable="true">{guid}</parameter>'
                f'<parameter name="Task Type" source="constant" updatable="true">MCT</parameter>'
                f'<parameter name="Has Inout Parameters" source="constant" updatable="true">true</parameter>'
                f'<parameter name="taskField" source="nested"><operation source="field" to="{po}">temp.{step}</operation>{ins}</parameter>'
                f'</serviceInput><serviceOutput>{outs}</serviceOutput></service>'
                f'{self.lnk(nxt)}{self.catch(step, ignore)}</eventContainer>')

    def ingestion(self, own, nxt, step, task, guid, src_type, tgt_type, overrides):
        po = f"{task.replace('_', '-')}-{guid}"
        self.po[po] = "mi"
        self.temp.append(f'<field description="" name="{step}" type="reference"><options><option name="referenceTo">$po:{po}</option></options></field>')
        ops = (f'<operation source="field" to="{po}">temp.{step}</operation>'
               f'<operation source="constant" to="{po}/input[1]/CATEGORYGeneral[1]/sourceConnectionType">{src_type}</operation>'
               f'<operation source="constant" to="{po}/input[1]/CATEGORYGeneral[1]/targetConnectionType">{tgt_type}</operation>'
               f'<operation source="constant" to="{po}/input[1]/CATEGORYGeneral[1]/maxFileLimit">0</operation>')
        for path, expr in overrides:
            ops += (f'<operation objName="{path.split("/")[0]}" source="formula" to="{po}/input[1]/{path}">'
                    f'<expression language="XQuery">{self.x(expr)}</expression></operation>')
        return (f'<eventContainer id="{own}"><service id="{self.id()}"><title>{step}</title>'
                f'<serviceName>DIExecuteServiceTaskIngestionTaskImpl</serviceName><serviceGUID/><serviceInput>'
                f'<parameter name="Wait for Task to Complete" source="constant" updatable="true">true</parameter>'
                f'<parameter name="Max Wait" source="constant" updatable="true">604800</parameter>'
                f'<parameter name="Task Name" source="constant" updatable="true">{task}</parameter>'
                f'<parameter name="GUID" source="constant" updatable="true">{guid}</parameter>'
                f'<parameter name="Task Type" source="constant" updatable="true">MI_TASK</parameter>'
                f'<parameter name="serviceProviderId" source="constant" updatable="true">filelistener</parameter>'
                f'<parameter name="serviceProviderContextPath" source="constant" updatable="true">mitask/</parameter>'
                f'<parameter name="taskField" source="nested">{ops}</parameter></serviceInput><serviceOutput>'
                f'<operation source="field" to="temp.{step}/output/successFiles">successFiles</operation>'
                f'<operation source="field" to="temp.{step}/output/failedFiles">failedFiles</operation>'
                f'<operation source="field" to="temp.{step}/output/fileDetails">fileDetails</operation>'
                f'</serviceOutput></service>{self.lnk(nxt)}{self.catch(step, True)}</eventContainer>')

    def command(self, own, nxt, step, runtime_expr, script, args_expr):
        self.po["INFA-commandTask"] = "cmd"
        self.temp.append(f'<field description="" name="{step}" type="reference"><options><option name="referenceTo">$po:INFA-commandTask</option>'
                         f'<option name="failOnNotRun">false</option><option name="failOnFault">false</option></options></field>')
        return (f'<eventContainer id="{own}"><service id="{self.id()}"><title>{step}</title><serviceName>ICSExecuteCommandTask</serviceName>'
                f'<serviceGUID/><serviceInput>'
                f'<parameter name="Task Name" source="constant">{step}</parameter>'
                f'<parameter name="Wait for Task to Complete" source="constant">true</parameter>'
                f'<parameter name="Runtime Environment" source="formula"><expression language="XQuery">{self.x(runtime_expr)}</expression></parameter>'
                f'<parameter name="Max Wait" source="constant">86400</parameter>'
                f'<parameter name="Script Name" source="constant"/><parameter name="Input Arguments" source="constant"/>'
                f'<parameter name="Work Directory" source="constant"/><parameter name="RuntimeEnvGUID" source="constant"/>'
                f'<parameter name="FailTaskIfAnyScriptFails" source="constant">false</parameter>'
                f'<parameter name="taskField" source="nested">'
                f'<operation source="field" to="INFA-commandTask">temp.{step}</operation>'
                f'<operation source="constant" to="INFA-commandTask/input[1]/script-1/name">Script1</operation>'
                f'<operation source="constant" to="INFA-commandTask/input[1]/script-1/scriptName">{self.x(script)}</operation>'
                f'<operation source="formula" to="INFA-commandTask/input[1]/script-1/inputArguments"><expression language="XQuery">{self.x(args_expr)}</expression></operation>'
                f'<operation source="constant" to="INFA-commandTask/input[1]/script-1/workDir"/>'
                f'</parameter></serviceInput><serviceOutput>'
                f'<operation source="field" to="temp.{step}/output/Run_Id">Run Id</operation>'
                f'<operation source="field" to="temp.{step}/output/Start_Time">Start Time</operation>'
                f'<operation source="field" to="temp.{step}/output/End_Time">End Time</operation>'
                f'<operation source="field" to="temp.{step}/output/Exit_Code">Exit Code</operation>'
                f'<operation source="field" to="temp.{step}/output/Execution_Status">Execution Status</operation>'
                f'<operation source="field" to="temp.{step}/output/Std_Error">Std Error</operation>'
                f'</serviceOutput></service>{self.lnk(nxt)}{self.catch(step, True)}</eventContainer>')

    def jump(self, own, nxt, target):
        return f'<jumpTo id="{own}"><link id="{self.id()}" targetId="{target}"/></jumpTo>'

    def seq(self, builders, own_ids=None):
        """builders: callables (own, nxt) -> xml. Returns (first_id, xml)."""
        ids_ = own_ids or [self.id() for _ in builders]
        xml = "".join(b(ids_[i], ids_[i + 1] if i + 1 < len(builders) else None) for i, b in enumerate(builders))
        return (ids_[0] if ids_ else None), xml

    def decision(self, own, nxt, title, left, right, branch, otherwise=()):
        f1, f2 = self.id(), self.id()
        _, x1 = self.seq(list(branch))
        _, x2 = self.seq(list(otherwise))
        back = lambda: f'<link id="{self.id()}" targetId="{own}" type="containerLink"/>'
        return (f'<container id="{own}" type="exclusive"><title>{self.x(title)}</title>'
                f'<flow id="{f1}">{x1}{back()}</flow><flow id="{f2}">{x2}{back()}</flow>'
                f'<link id="{self.id()}" targetId="{f1}" type="containerLink"><condition source="formula">'
                f'<function name="less-or-equals"><arg name="left">{{{left}}}</arg><arg name="right">{{{right}}}</arg></function>'
                f'</condition></link><link id="{self.id()}" targetId="{f2}" type="containerLink"/>'
                f'{self.lnk(nxt)}</container>')


def build_taskflow(tf_name, tf_guid, ids):
    t = TF()
    q = lambda s: "'" + s.replace("'", "''") + "'"
    # builder factories: each returns callable(own, nxt)
    A = lambda title, ops: (lambda o, n: t.assignment(o, n, title, ops))
    D = lambda step, key, i, out=(), ignore=False: (lambda o, n: t.data_task(o, n, step, ids[key][0], ids[key][1], i, list(out), ignore))
    I = lambda step, key, st, tt, ov: (lambda o, n: t.ingestion(o, n, step, ids[key][0], ids[key][1], st, tt, ov))
    X = lambda step, rt, script, args: (lambda o, n: t.command(o, n, step, rt, script, args))
    DEC = lambda title, l, r, br, ot=(): (lambda o, n: t.decision(o, n, title, l, r, br, ot))
    J = lambda target: (lambda o, n: t.jump(o, n, target))
    LOG = lambda step, event, msg: D(step, "log", [("RUN_ID", "$temp.RUN_ID"), ("ROUTE_ID", "$temp.ROUTE_ID"),
                                                  ("EVENT", q(event)), ("MESSAGE", msg)], ignore=True)

    rd = "$temp.DT_ReadRoute[1]/inout[1]/"
    reader_in = [("RUN_GROUP", "if (string($input.RUN_GROUP) = '') then 'DAILY' else $input.RUN_GROUP"),
                 ("ROW_ID", "$temp.ROW_ID"), ("RUN_ID", "$temp.RUN_ID")] + [(p, "''") for p in READER_OUT]
    take = [("temp.TOTAL", f"if (string({rd}TOTAL_ROUTES) = '') then 0 else number({rd}TOTAL_ROUTES)"),
            ("temp.HAS_ROUTE", f"if (string({rd}ROUTE_ID) = '') then 0 else 1")]
    take += [(f"temp.{p}", f"string({rd}{p})") for p in READER_OUT[1:]]
    take += [("temp.RUN_LANDING_DIR", f"concat(string({rd}ONELAKE_LANDING_DIR), '/', $temp.RUN_ID)")]
    outcome_dir = ("concat(if ($temp.OUTCOME = 'ARCHIVE') then $temp.ONELAKE_ARCHIVE_DIR else if ($temp.OUTCOME = 'DUPLICATE') "
                   "then $temp.ONELAKE_DUPLICATE_DIR else $temp.ONELAKE_ERROR_DIR, '/', $temp.RUN_ID)")
    oc = "$temp.DT_Outcome[1]/inout[1]/OUTCOME"

    files_branch = [
        D("DT_Load", "load", [("RUN_ID", "$temp.RUN_ID"), ("ROUTE_ID", "$temp.ROUTE_ID"), ("SRC_DIRECTORY", f"fn:substring-after($temp.RUN_LANDING_DIR, '{ONELAKE_LAKEHOUSE_PATH}/')"),
                              ("START_DATE_VALUE", "$temp.START_DATE_VALUE"), ("END_DATE_VALUE", "$temp.END_DATE_VALUE")], ignore=True),
        D("DT_Outcome", "outcome", [("RUN_ID", "$temp.RUN_ID"), ("ROUTE_ID", "$temp.ROUTE_ID"), ("OUTCOME", "''")], ["OUTCOME"], ignore=True),
        A("TakeOutcome", [("temp.OUTCOME", f"if (string({oc}) = '') then 'ERROR' else string({oc})"),
                          ("temp.MOVE_TARGET_DIR", outcome_dir)]),
        I("IT_Move", "mi_move", "Fabric OneLake", "Fabric OneLake",
          [("CATEGORYSource[1]/sourceDirectory", "$temp.RUN_LANDING_DIR"), ("CATEGORYTarget[1]/oneLakeTargetLocation", "$temp.MOVE_TARGET_DIR")]),
    ]
    route_branch = [
        I("IT_Collect", "mi_collect", "local", "Fabric OneLake",
          [("CATEGORYGeneral[1]/runtimeEnvironment", "$temp.RUNTIME_ENVIRONMENT"),
           ("CATEGORYSource[1]/sourceDirectory", "$temp.SOURCE_DIRECTORY"),
           ("CATEGORYSource[1]/filePattern", "$temp.FILE_PATTERN"),
           ("CATEGORYTarget[1]/oneLakeTargetLocation", "$temp.RUN_LANDING_DIR")]),
        A("CountFiles", [("temp.FILES", "if (string($temp.IT_Collect[1]/output[1]/successFiles) = '') then 0 "
                                        "else number($temp.IT_Collect[1]/output[1]/successFiles)")]),
        DEC("Files found?", "1", "$temp.FILES", files_branch,
            [LOG("DT_LogNoFile", "NO_FILE", "concat('no ', $temp.FILE_PATTERN, ' in ', $temp.SOURCE_DIRECTORY, ' on ', "
                                            "$temp.RUNTIME_ENVIRONMENT, ' (or the collect step failed)')")]),
    ]
    init_id, loop_id = t.id(), t.id()
    loop_branch = [D("DT_ReadRoute", "reader", reader_in, READER_OUT), A("TakeRoute", take),
                   DEC("Route found?", "1", "$temp.HAS_ROUTE", route_branch),
                   A("NextRow", [("temp.ROW_ID", "$temp.ROW_ID + 1")]), J(loop_id)]
    init = t.assignment(init_id, loop_id, "Init", [
        ("temp.RUN_ID", "fn:format-dateTime(fn:adjust-dateTime-to-timezone(fn:current-dateTime(), xs:dayTimeDuration('PT0S')), "
                        "'[Y0001][M01][D01][H01][m01][s01]')"), ("temp.ROW_ID", "1"), ("temp.TOTAL", "1")])
    loop = t.decision(loop_id, "c", "More routes?", "$temp.ROW_ID", "$temp.TOTAL", loop_branch)

    temps = "".join(f'<field description="" name="{n}" type="{ty}"><options><option name="required">false</option></options></field>'
                    for n, ty in [("RUN_ID", "string"), ("ROW_ID", "double"), ("TOTAL", "double"), ("HAS_ROUTE", "double"),
                                  ("FILES", "double"), ("OUTCOME", "string"), ("MOVE_TARGET_DIR", "string"),
                                  ("RUN_LANDING_DIR", "string")] + [(p, "string") for p in READER_OUT[1:]])
    pos = ""
    for po, kind in t.po.items():
        fields = {"mt": [("InOut Parameters", "inout", "reference"), ("TaskProperties Parameters", "taskProperties", "reference"),
                         ("Output Parameters", "output", "reference"), ("Fault", "fault", "reference"),
                         ("Max Wait (Seconds)", "Max_Wait", "int")],
                  "mi": [("Fault", "fault", "reference"), ("Input Parameters", "input", "reference"), ("Output Parameters", "output", "reference")],
                  "cmd": [("Output Parameters", "output", "reference"), ("Fault", "fault", "reference")]}[kind]
        desc = "This process object represents a taskflow specific command task output field details." if kind == "cmd" else ""
        f = "".join(f'<field label="{a}" name="{b}" nullable="true" required="false" type="{c}"/>' for a, b, c in fields)
        pos += (f'<processObject xmlns="http://schemas.active-endpoints.com/appmodules/screenflow/2011/06/avosHostEnvironment.xsd" '
                f'displayName="{po}" isByCopy="true" name="{po}"><description>{desc}</description><tags/><detail>{f}</detail></processObject>')
    ts = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    xml = f"""<aetgt:getResponse xmlns:aetgt="http://schemas.active-endpoints.com/appmodules/repository/2010/10/avrepository.xsd"
                   xmlns:types1="http://schemas.active-endpoints.com/appmodules/repository/2010/10/avrepository.xsd">
   <types1:Item>
      <types1:EntryId>{tf_guid}::tf.xml</types1:EntryId>
      <types1:Name>{tf_name}</types1:Name>
      <types1:MimeType>application/xml+taskflow</types1:MimeType>
      <types1:Description/>
      <types1:AppliesTo/>
      <types1:Tags/>
      <types1:VersionLabel>1.0</types1:VersionLabel>
      <types1:State>CURRENT</types1:State>
      <types1:ProcessGroup/>
      <types1:CreationDate>{ts}</types1:CreationDate>
      <types1:ModificationDate>{ts}</types1:ModificationDate>
      <types1:PublicationStatus>unpublished</types1:PublicationStatus>
      <types1:Entry>
         <taskflow xmlns="http://schemas.active-endpoints.com/appmodules/screenflow/2010/10/avosScreenflow.xsd"
                   xmlns:tfm="http://schemas.active-endpoints.com/appmodules/screenflow/2021/04/taskflowModel.xsd"
                   xmlns:list="urn:activevos:spi:list:functions"
                   displayName="{tf_name}"
                   name="{tf_name}"
                   overrideAPIName="false">
            <parameterSet xmlns="http://schemas.active-endpoints.com/appmodules/screenflow/2021/04/taskflowModel.xsd"/>
            <appliesTo/>
            <description>MATMAS: loop over cfg.matmas_route_config - collect agent files to OneLake, load, route files, archive.</description>
            <tags/>
            <generator>Informatica Process Designer 11</generator>
            <input><parameter description="" name="RUN_GROUP" type="string"><options><option name="required">false</option></options></parameter></input>
            <tempFields>{temps}{"".join(t.temp)}</tempFields>
            <notes/>
            <deployment skipIfRunning="true" suspendOnFault="false" tracingLevel="verbose"><rest/></deployment>
            <extData><nvpair name="treatEmptyStringAsNotNull">false</nvpair><nvpair name="treatEmptyObjectListAsArray">false</nvpair></extData>
            <flow id="a">
               <start id="b"><link id="{t.id()}" targetId="{init_id}"/></start>
               {init}
               {loop}
               <end id="c"/>
            </flow>
            <dependencies>{pos}</dependencies>
         </taskflow>
      </types1:Entry>
      <types1:GUID>{tf_guid}</types1:GUID>
      <types1:DisplayName>{tf_name}</types1:DisplayName>
   </types1:Item>
</aetgt:getResponse>
"""
    return xml.encode()


# ================================================================== main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--onelake-guid", default="aHJH3tHOCgJj59wmDtIsKs")
    ap.add_argument("--onelake-handle", default="018Z0P0B0000000000D0")
    ap.add_argument("--out", default=os.path.join(HERE, "..", "import", "MATMAS_CDI_Import.zip"))
    ap.add_argument("--no-taskflow", action="store_true",
                    help="Part 1: only mappings, mapping tasks and their connections / agent groups")
    ap.add_argument("--fi-collect", help="GUID of the existing file ingestion task fi_P2O_100_MATMAS_Agent_to_OneLake (Part 2)")
    ap.add_argument("--fi-move", help="GUID of the existing file ingestion task fi_P2O_101_MATMAS_OneLake_Move (Part 2)")
    a = ap.parse_args()
    existing_fi = bool(a.fi_collect and a.fi_move)
    onelake = (a.onelake_guid, a.onelake_handle)

    G = {k: guid() for k in ("reader_m", "load_m", "outcome_m", "log_m", "reader_t", "load_t", "outcome_t", "log_t",
                             "mi_collect", "mi_move", "tf", "ff_conn")}
    N = {"reader": "P2O_101_MATMAS_Route_Reader", "load": "P2O_102_MATMAS_Load",
         "outcome": "P2O_103_MATMAS_Outcome", "log": "P2O_104_MATMAS_Log"}
    MI = {"mi_collect": "fi_P2O_100_MATMAS_Agent_to_OneLake", "mi_move": "fi_P2O_101_MATMAS_OneLake_Move"}
    MI_HANDLE = {"mi_collect": 9810011, "mi_move": 9810012}   # numeric repo handles, like real MI tasks (high values to avoid clashes)
    TFN = "tf_P2O_100_MATMAS_Orchestrator"
    FF_NAME = "FF_MATMAS_WORK"

    maps = {"reader": m_reader("m_" + N["reader"]), "load": m_load("m_" + N["load"], onelake[0]),
            "outcome": m_outcome("m_" + N["outcome"]), "log": m_log("m_" + N["log"])}
    files, manifest, csv = {}, [], ["objectPath,objectName,objectType,id"]

    def entry(guid_, name, otype, path, refs, ctype="JSON", state="VALID", major=0, ctx=True, desc="", repo=None):
        manifest.append({"objectGuid": guid_, "objectName": name, "objectType": otype, "path": path, "providerName": None,
                         "metadata": {"modelVersion": {"major": major, "minor": 0}, "repoInfo": ({"repoHandle": repo} if repo else None), "objectRefs": refs,
                                      "contextAttributes": [{"name": "id", "value": "@1"}] if ctx else [],
                                      "additionalInfo": {"description": desc, "contentType": ctype, "documentState": state}}})
        csv.append(f"{path},{name},{otype},{guid_}")

    # ---- dependencies, exactly as the org's own export ships them. The import option
    #      "overwrite existing assets, excluding connections and runtime environments" never overwrites these.
    def conn_zip(cj):
        return zbytes([("metadata.meta", dumps([{"@type": "objectRef", "id": "@1", "type": "connection"}])), ("connection.json", dumps(cj))])
    jdbc = [{"@type": "connection", "id": "@1", "name": JDBC_NAME, "runtimeEnvironmentId": "@" + AG["US.US02.01"][0],
             "instanceName": "JDBCV2", "instanceDisplayName": "JDBCV2", "type": "TOOLKIT_CCI", "baseType": "TOOLKIT",
             "subType": "TOOLKIT_CCI", "port": -1, "timeout": 60,
             "connParams": {"quoteChar": "None", "schemaname": "stg", "agentId": "018Z0P08000000000004", "retrycount": "0",
                            "supportmixedcaseidentifier": "false", "agentGroupId": AG["US.US02.01"][1], "orgId": "018Z0P",
                            "retryinterval": "0", "password": "", "autocommit": "false", "subtype": "Azure SQL Database",
                            "jdbcdriverclassname": "com.microsoft.sqlserver.jdbc.SQLServerDriver",
                            "username": "7730fa35-0f7f-4e05-b58c-aee7d165f4a3"},
             "internal": False, "federatedId": JDBC_GUID, "retryNetworkError": False, "supportsCCIMultiGroup": False,
             "metadataBrowsable": True, "supportLabels": True, "vaultEnabled": False, "vaultEnabledParams": [],
             "connectorGuid": "com.informatica.adapter.jdbc_v2", "isRtAttrsRefreshRequired": False, "connectorStatus": "ACTIVE"}]
    files[f"SYS/{JDBC_NAME}.Connection.zip"] = conn_zip(jdbc)
    entry(JDBC_GUID, JDBC_NAME, "Connection", "/SYS", [AG["US.US02.01"][0]], state="COMPLETE", desc=None, repo="018Z0P0B0000000000D5")
    ol = [{"@type": "connection", "id": "@1", "name": ONELAKE_NAME, "description": "", "runtimeEnvironmentId": "@" + AG["US.US02.01"][0],
           "instanceName": "Microsoft OneLake", "instanceDisplayName": "Microsoft Fabric OneLake", "shortDescription": "",
           "type": "TOOLKIT_CCI", "baseType": "TOOLKIT", "subType": "TOOLKIT_CCI", "port": 0,
           "majorUpdateTime": "2026-07-31T04:46:51.000Z", "timeout": 60,
           "connParams": {"agentId": "018Z0P08000000000004", "clientID": "7730fa35-0f7f-4e05-b58c-aee7d165f4a3",
                          "agentGroupId": AG["US.US02.01"][1], "lakehousePath": ONELAKE_LAKEHOUSE_PATH,
                          "tenantID": "fe9c207f-da30-4226-82b5-bff6ef031c8c", "workspaceName": "ws_p2o_intg_dev", "clientSecret": "",
                          "authenticationType": "Service Principal Authentication", "endPointSuffix": "fabric.microsoft.com", "orgId": "018Z0P"},
           "internal": False, "federatedId": onelake[0], "retryNetworkError": False, "supportsCCIMultiGroup": False,
           "metadataBrowsable": True, "supportLabels": True, "vaultEnabled": False, "vaultEnabledParams": [],
           "connectorGuid": "com.informatica.adapter.onelake", "isRtAttrsRefreshRequired": False, "connectorStatus": "ACTIVE"}]
    files[f"SYS/{ONELAKE_NAME}.Connection.zip"] = conn_zip(ol)
    entry(onelake[0], ONELAKE_NAME, "Connection", "/SYS", [AG["US.US02.01"][0]], state="COMPLETE", desc="", repo=onelake[1])
    for agn, created in (("US.US02.01", "2021-09-22T09:59:40.000Z"), ("US.AMCOR.01", "2026-06-25T15:38:08.000Z")):
        rj = [{"@type": "runtimeEnvironment", "id": "@1", "name": agn, "isSystemAgentGroup": False, "isShared": False,
               "federatedId": AG[agn][0], "createTimeUTC": created, "updateTimeUTC": created}]
        files[f"SYS/{agn}.AgentGroup.zip"] = zbytes([("metadata.meta", dumps([{"@type": "objectRef", "id": "@1", "type": "runtimeEnvironment"}])),
                                                     ("runtimeEnvironment.json", dumps(rj))])
        entry(AG[agn][0], agn, "AgentGroup", "/SYS", [], desc=None, repo=AG[agn][1])

    with open(os.path.join(HERE, "ref", f"{PROJECT}.Project.json"), "rb") as f:
        files[f"Explore/{PROJECT}.Project.json"] = f.read()
    entry(PROJECT_GUID, PROJECT, "Project", "/Explore", [], ctype="Binary", state="COMPLETE", ctx=False, desc="TCS Consultant")

    for k, m in maps.items():
        mg, tg = G[k + "_m"], G[k + "_t"]
        files[f"Explore/{PROJECT}/m_{N[k]}.DTEMPLATE.zip"] = dtemplate(m, mg)
        entry(mg, f"m_{N[k]}", "DTEMPLATE", PATH, sorted(m.conns))
        src = next(t for t in m.tx if t["$$class"] == C["TmplSource"]); tgt = next(t for t in m.tx if t["$$class"] == C["TmplTarget"])
        conn = onelake[0] if k == "load" else JDBC_GUID
        sp = mt_param("SOURCE", src["name"], conn, src["dataAdapter"]["object"]["name"])
        tp = mt_param("TARGET", tgt["name"], JDBC_GUID, tgt["dataAdapter"]["object"]["name"])
        files[f"Explore/{PROJECT}/mt_{N[k]}.MTT.zip"] = mtt(f"mt_{N[k]}", tg, mg, m, [sp, tp])
        entry(tg, f"mt_{N[k]}", "MTT", PATH, sorted(m.conns | {AG[CENTRAL_AG][0], mg}))

    if not a.no_taskflow:
        if existing_fi:
            # Part 2: the ingestion tasks already exist in the org (copied from fi_P2O_000) - reference them, don't ship them
            G["mi_collect"], G["mi_move"] = a.fi_collect, a.fi_move
        else:
            landing_jde = ONELAKE_ROOT + "/landing/JDE"
            mi_defs = {"mi_collect": ("US.US02.01", "local", "onelake", r"D:\Interfaces\JDE\MATMAS\outbound", "JDE_MATMAS*.txt", landing_jde, "DELETE"),
                       "mi_move": (CENTRAL_AG, "onelake", "onelake", landing_jde, "*", ONELAKE_ROOT + "/archive/JDE", "DELETE")}
            for k, (agn, s_, tg_, sp_, pat, tp_, dele) in mi_defs.items():
                handle = str(MI_HANDLE[k])
                files[f"Explore/{PROJECT}/{MI[k]}.MI_TASK.dat"] = mi_task(MI[k], G[k], agn, s_, tg_, sp_, pat, tp_, dele, onelake, handle)
                refs = ([onelake[0]] if "onelake" in (s_, tg_) else []) + [AG[agn][0]]
                entry(G[k], MI[k], "MI_TASK", PATH, refs, ctype=None, major=1, ctx=False, repo=handle)
        ids = {"reader": (f"mt_{N['reader']}", G["reader_t"]), "load": (f"mt_{N['load']}", G["load_t"]),
               "outcome": (f"mt_{N['outcome']}", G["outcome_t"]), "log": (f"mt_{N['log']}", G["log_t"]),
               "mi_collect": (MI["mi_collect"], G["mi_collect"]), "mi_move": (MI["mi_move"], G["mi_move"])}
        files[f"Explore/{PROJECT}/{TFN}.TASKFLOW.xml"] = build_taskflow(TFN, G["tf"], ids)
        entry(G["tf"], TFN, "TASKFLOW", PATH, [G[k] for k in ("reader_t", "load_t", "outcome_t", "log_t", "mi_collect", "mi_move")],
              ctype="application/json; charset=utf-8", major=1, ctx=False)

    pkg = f"MATMAS_CDI_Import-{now_ms()}"
    files["exportMetadata.v2.json"] = json.dumps({"name": pkg, "sourceOrgId": ORG_ID, "sourceOrgName": ORG_NAME,
                                                  "exportedObjects": manifest}, indent=2).encode()
    files[f"ContentsofExportPackage_{pkg}.csv"] = ("\n".join(csv) + "\n").encode()
    lines = ["#", "#" + dt.datetime.now(dt.timezone.utc).strftime("%a %b %d %H:%M:%S UTC %Y"),
             "9BYDzwvqg1vfnGsPQcCRQb=B8F9765B666B7E9BC8E37292CD7EFB887580C48417A640AAA0BBFCBF76CD4CA4",
             "5E2jEuhTW3jf1X2CWDEAMR=14806E1FA52980963C9431D25E3C9E2FFC233CA0A2CDE30123A88788F8E863E5"]   # fixed lines seen in every org export
    lines += [p.replace(" ", "\\ ") + "=" + hashlib.sha256(d).hexdigest().upper() for p, d in files.items()
              if not p.startswith("ContentsofExportPackage_")]
    files["exportPackage.chksum"] = ("\n".join(lines) + "\n").encode()
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "wb") as f:
        f.write(zbytes(list(files.items())))
    print("written", os.path.abspath(a.out))
    for e in manifest:
        print(f"  {e['objectType']:10} {e['objectName']:40} {e['objectGuid']}")


if __name__ == "__main__":
    main()
