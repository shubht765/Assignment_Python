#!/usr/bin/env python3
"""
Build an Informatica IDMC/CDI import package (.zip) for the MATMAS process mapping.

The layout is reverse-engineered from a real export of the same org
(Mapping58-1794813874687.zip, "Berry Global-Dev"):

  exportMetadata.v2.json                       manifest of exported objects
  exportPackage.chksum                         SHA-256 (upper hex) of every entry
  ContentsofExportPackage_<name>.csv           human readable list
  Explore/<project>.Project.json               project (copied from the reference)
  Explore/<project>/<mapping>.DTEMPLATE.zip    mapping = metadata.meta + mappingTemplate.json
                                               + fileRecord.json + bin/@3.bin (mapping JSON)
                                               + bin/@2.bin (preview jpeg)
  SYS/<connection>.Connection.zip              connection.json + metadata.meta
  SYS/<agent group>.AgentGroup.zip             runtimeEnvironment.json + metadata.meta

Generated mapping  m_MATMAS_PROCESS:
  Source  JDBC V2  stg.MATMAS_RUN_REQUEST_SRC   (1 row: REQUEST_SOURCE, REQUEST_NOTE)
  Target  JDBC V2  stg.MATMAS_RUN_REQUEST       (insert)  Post SQL: EXEC MATMAS.sp_MATMAS_Process
Both objects are views in the connection's default schema (stg) over MATMAS tables,
exactly like the reference mapping which writes to stg with an empty dbSchema.

Usage:  python3 build_cdi_package.py [--project-json PATH] [--out PATH]
"""
import argparse
import datetime as dt
import hashlib
import io
import json
import os
import random
import string
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------- org constants (from the reference export)
ORG_ID = "kFCREt1YHueikzh0s4ZOsI"
ORG_NAME = "Berry Global-Dev"
PROJECT_GUID = "kH5WfYrWOK1ggU0ocJ0X2n"
PROJECT_NAME = "zPF_TCS_Shubham"
CONN_GUID = "1AIvTtPhmimhpwYPfj4G2j"
CONN_NAME = "jdbcv2.MSSQL.sqldb-p2o-intg.stg"
AGENT_GUID = "9Nsrpw4jLaMha1GCSorpO0"
AGENT_NAME = "US.US02.01"

POST_SQL = "EXEC MATMAS.sp_MATMAS_Process"
# fixed so that a re-generated package re-imports over the same mapping instead of creating a copy
DEFAULT_MAPPING_GUID = "cAB5PPHXfSfelMAd7m9sVP"

CLASS_INFO = {
    "1": "com.informatica.metadata.template.common.Template",
    "2": "com.informatica.metadata.template.common.layout.LayoutAnnotation",
    "3": "com.informatica.metadata.common.genericannotation.GenericAnnotation",
    "4": "com.informatica.metadata.common.description.Description",
    "5": "com.informatica.metadata.template.common.TmplLink",
    "6": "com.informatica.metadata.template.common.TmplGroup",
    "7": "com.informatica.metadata.template.tx.tmplsource.TmplSource",
    "8": "com.informatica.metadata.template.tx.tmplmapplet.TmplMapplet",
    "9": "com.informatica.metadata.template.tx.tmpltarget.TmplTarget",
    "10": "com.informatica.metadata.common.genericannotation.NameValuePair",
    "11": "com.informatica.metadata.template.common.TxAdvancedProperty",
    "12": "com.informatica.metadata.template.ext.da.cloud.common.BaseAdapter",
    "13": "com.informatica.metadata.template.common.field.TxField",
    "14": "com.informatica.metadata.template.ext.da.cloud.common.BaseAdapterField",
    "15": "com.informatica.metadata.common.typesystem.DataType",
    "16": "com.informatica.metadata.template.tx.tmpltarget.FieldMappings",
    "17": "com.informatica.metadata.template.ext.da.cloud.common.MappletAdapter",
    "18": "com.informatica.metadata.template.common.field.FieldMapping",
    "19": "com.informatica.metadata.template.tx.tmplmapplet.TxFieldGroup",
    "20": "com.informatica.metadata.common.types.StringValue",
    "21": "com.informatica.metadata.common.types.BooleanValue",
    "22": "com.informatica.metadata.template.ext.da.cloud.common.DataObject",
    "23": "com.informatica.metadata.template.ext.da.cloud.common.RuntimeAttributes",
    "24": "com.informatica.metadata.template.ext.da.cloud.common.ReadOptions",
    "25": "com.informatica.metadata.template.common.rule.TmplAllRule",
    "26": "com.informatica.metadata.template.ext.da.cloud.common.WriteOptions",
    "27": "com.informatica.metadata.template.ext.da.cloud.common.RuntimeAttribute",
    "28": "com.informatica.metadata.template.ext.da.cloud.common.Option",
}
STRING_TYPE = "smd:com.informatica.metadata.seed.platform.Platform.typesystem/string"

# sanitized copies of the reference connection / agent group (password removed on purpose)
CONNECTION_JSON = [{
    "@type": "connection", "id": "@1", "name": CONN_NAME,
    "runtimeEnvironmentId": "@" + AGENT_GUID,
    "instanceName": "JDBCV2", "instanceDisplayName": "JDBCV2",
    "type": "TOOLKIT_CCI", "baseType": "TOOLKIT", "subType": "TOOLKIT_CCI", "port": -1,
    "majorUpdateTime": "2026-09-29T06:22:10.000Z", "timeout": 60,
    "connParams": {
        "quoteChar": "None", "schemaname": "stg", "agentId": "018Z0P08000000000004", "retrycount": "0",
        "supportmixedcaseidentifier": "false",
        "connectionstring": "jdbc:sqlserver://p4qjz7rq3itefavvx73o6ay4rq-sf3qcbb4bwcupceovfkzeprbga.database.fabric.microsoft.com:1433;database={sqldb-p2o-intg-dev-c4aef771-f306-4050-983f-016f145a37fc};encrypt=true;trustServerCertificate=false;hostNameInCertificate=*.database.fabric.microsoft.com;authentication=ActiveDirectoryServicePrincipal",
        "agentGroupId": "018Z0P2500000000000A", "orgId": "018Z0P", "retryinterval": "0",
        "password": "", "autocommit": "false", "subtype": "Azure SQL Database",
        "jdbcdriverclassname": "com.microsoft.sqlserver.jdbc.SQLServerDriver",
        "username": "7730fa35-0f7f-4e05-b58c-aee7d165f4a3"},
    "internal": False, "federatedId": CONN_GUID, "retryNetworkError": False, "supportsCCIMultiGroup": False,
    "metadataBrowsable": True, "supportLabels": True, "vaultEnabled": False, "vaultEnabledParams": [],
    "connectorGuid": "com.informatica.adapter.jdbc_v2", "isRtAttrsRefreshRequired": False, "connectorStatus": "ACTIVE"}]
AGENT_JSON = [{"@type": "runtimeEnvironment", "id": "@1", "name": AGENT_NAME, "isSystemAgentGroup": False,
               "isShared": False, "federatedId": AGENT_GUID,
               "createTimeUTC": "2021-09-22T09:59:40.000Z", "updateTimeUTC": "2021-09-22T10:00:24.000Z"}]

# 1x1 white baseline JPEG, used as preview when Pillow is not installed
TINY_JPEG = bytes.fromhex(
    "ffd8ffe000104a46494600010101004800480000ffdb004300080606070605080707070909080a0c140d0c0b0b0c1912130f141d1a1f1e1d1a1c1c"
    "20242e2720222c231c1c2837292c30313434341f27393d38323c2e333432ffc0000b080001000101011100ffc4001f00000105010101010101000000"
    "00000000000102030405060708090a0bffc400b5100002010303020403050504040000017d01020300041105122131410613516107227114328191"
    "a1082342b1c11552d1f02433627282090a161718191a25262728292a3435363738393a434445464748494a535455565758595a636465666768696a"
    "737475767778797a838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8"
    "d9dae1e2e3e4e5e6e7e8e9eaf1f2f3f4f5f6f7f8f9faffda0008010100003f00fbfcffd9")


def guid():
    """22-character base62 id like the ones IDMC uses."""
    alphabet = string.ascii_letters + string.digits
    return "".join(random.SystemRandom().choice(alphabet) for _ in range(22))


class Ids:
    def __init__(self):
        self.n = 0

    def next(self):
        self.n += 1
        return self.n


def adv(ids, name, value):
    return {"$$ID": ids.next(), "$$class": 11, "name": name, "value": value}


def adapter_field(ids, name, precision, parent, key=False):
    return {
        "$$ID": ids.next(), "$$class": 14, "name": name,
        "annotations": [{"$$ID": ids.next(), "$$class": 4, "body": ""}],
        "createable": "false", "externalId": "false", "fieldStatus": "ORIGINAL", "fieldType": "CONNECTOR",
        "filterable": "true", "foreignKey": "false", "generated": "false", "javaType": "java.lang.String",
        "key": "true" if key else "false", "label": name, "nativeName": name, "nativeType": "nvarchar",
        "newField": "false", "nullable": "true", "original": "false", "passthroughPort": "false",
        "precision": precision, "scale": 0, "sfIdLookup": "false", "unique": "false", "updateable": "true",
        "metaExtensions": [{"$$ID": ids.next(), "$$class": 28, "name": "isPartitionKey", "value": "false"}],
        "properties": [{"$$ID": ids.next(), "$$class": 28, "name": "parentObject", "value": parent},
                       {"$$ID": ids.next(), "$$class": 28, "name": "parentObjectLabel", "value": ""}],
    }


def tx_field(ids, af):
    return {"$$ID": ids.next(), "$$class": 13, "adapterField": {"##ID": af["$$ID"], "$$class": 14},
            "defaultValue": "", "ignoreComparison": "false", "ignoreNullInputs": "false",
            "isDefaultValueUpdated": "false", "name": af["name"],
            "platformType": {"##SID": STRING_TYPE, "$$class": 15},
            "precision": af["precision"], "scale": 0}


def data_object(ids, name, fields):
    return {"$$ID": ids.next(), "$$class": 22, "name": name, "customQuery": "", "dbSchema": "", "label": name,
            "objectName": "", "objectType": "", "parentPath": "", "path": name, "retainMetadata": "false",
            "fields": fields}


def base_adapter(ids, obj, read=False, write=False):
    da = {"$$ID": ids.next(), "$$class": 12, "name": "", "codePage": "", "compatibleEngine": "",
          "connectionId": "saas:@" + CONN_GUID, "connectionSelectionType": "", "excludeDynamicFileNameField": "false",
          "fwConfigId": "", "multipleObject": "false", "objectType": "SINGLE", "typeSystem": "TOOLKIT",
          "useDynamicFileName": "false", "object": obj,
          "oprRuntimeAttributes": {"$$ID": ids.next(), "$$class": 23}}
    if read:
        da["readOptions"] = {"$$ID": ids.next(), "$$class": 24, "commandType": 0, "descending": "false",
                             "filterCondition": "", "flatFileCommand": "", "queryAll": "false", "rowLimit": 0,
                             "selectDistinct": "false", "userDefinedJoin": "", "advancedFilterCondition": "",
                             "requestXml": "", "sortFieldValues": ""}
    da["runtimeAttributes"] = {"$$ID": ids.next(), "$$class": 23}
    if write:
        da["writeOptions"] = {"$$ID": ids.next(), "$$class": 26, "batchSize": 0, "bulkApi": "false",
                              "errorFileDirectory": "", "errorFilePrefix": "", "handleDecimalRoundOff": "false",
                              "handleSpecialChars": "false", "operations": ["Insert"], "setFieldsToNull": "false",
                              "successFileDirectory": "", "successFilePrefix": "", "truncate": "false",
                              "updateStrategyExpression": "", "useErrorFile": "false", "useExactSrcNames": "false",
                              "useSuccessFile": "false"}
    return da


def build_process_mapping(name):
    """m_MATMAS_PROCESS: JDBC V2 view -> JDBC V2 view, target Post SQL runs the whole pipeline."""
    ids = Ids()
    now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + "000Z"
    cols = [("REQUEST_SOURCE", 50), ("REQUEST_NOTE", 200)]

    # ids of annotations come first, like in the reference
    layout = {"$$ID": ids.next(), "$$class": 2,
              "jsonBlob": json.dumps({"Source": {"x": 50, "y": 100}, "Target": {"x": 450, "y": 100}},
                                     separators=(",", ":")),
              "templateId": ""}
    settings = {"$$ID": ids.next(), "$$class": 3, "source": "TEMPLATE_SETTINGS", "nameValuePairs": [
        {"$$ID": ids.next(), "$$class": 10, "name": "UNIQUIFY_MAPPLET_TX_NAMES_OPTIONS",
         "value": {"$$class": 20, "valueLiteral": "{\"nonNativeMappletTx\":true}"}},
        {"$$ID": ids.next(), "$$class": 10, "name": "UNIQUIFY_MAPPLET_TX_NAMES",
         "value": {"$$class": 21, "value": "true"}}]}
    desc = {"$$ID": ids.next(), "$$class": 4,
            "body": "MATMAS: inserts one run request; target Post SQL runs EXEC MATMAS.sp_MATMAS_Process "
                    "(assign files to routes, harmonize, publish)."}

    link_id = ids.next()
    src_group = {"$$ID": ids.next(), "$$class": 6, "input": "false", "name": "DefaultGroup", "output": "true"}
    tgt_group = {"$$ID": ids.next(), "$$class": 6, "input": "true", "name": "DefaultGroup", "output": "false",
                 "rules": [{"$$ID": ids.next(), "$$class": 25, "bulkRename": "false", "include": "true"}]}
    src_id = ids.next()
    tgt_id = ids.next()

    # ---- source
    src_obj_name = "MATMAS_RUN_REQUEST_SRC"
    s_afs = [adapter_field(ids, c, p, src_obj_name) for c, p in cols]
    source = {
        "$$ID": src_id, "$$class": 7, "augmented": "false", "createTime": now, "name": "Source",
        "advancedProperties": [adv(ids, "Tracing Level", "Normal"), adv(ids, "Pre SQL", ""),
                               adv(ids, "Post SQL", ""), adv(ids, "Sql Override", ""),
                               adv(ids, "Output is deterministic", "false"), adv(ids, "Output is repeatable", "")],
        "groups": [src_group],
        "generateFilenamePort": "false", "useLabels": "false", "useSequenceFields": "false",
        "fields": [tx_field(ids, af) for af in s_afs],
    }
    source["dataAdapter"] = base_adapter(ids, data_object(ids, src_obj_name, s_afs), read=True)

    # ---- target
    tgt_obj_name = "MATMAS_RUN_REQUEST"
    t_afs = [adapter_field(ids, c, p, tgt_obj_name) for c, p in cols]
    target = {
        "$$ID": tgt_id, "$$class": 9, "augmented": "false", "createTime": now, "name": "Target",
        "advancedProperties": [adv(ids, "Forward Rejected Rows", "true"), adv(ids, "Pre SQL", ""),
                               adv(ids, "Post SQL", POST_SQL), adv(ids, "Update Override", "")],
        "groups": [tgt_group],
        "createTarget": "false", "fieldMappingMode": "BY_NAME", "inputSorted": "false",
        "schemaProviderType": "SELECTED_OBJECT", "targetFieldsOrdered": "false", "updateColumns": [],
        "useLabels": "false", "useSequenceFields": "false",
        "fields": [tx_field(ids, af) for af in t_afs],
    }
    target["dataAdapter"] = base_adapter(ids, data_object(ids, tgt_obj_name, t_afs), write=True)
    target["manualMappings"] = {"$$ID": ids.next(), "$$class": 16}

    link = {"$$ID": link_id, "$$class": 5, "name": "Source.Edge",
            "fromGroup": {"##ID": src_group["$$ID"], "$$class": 6},
            "fromTransformation": {"##ID": src_id, "$$class": 7},
            "toGroup": {"##ID": tgt_group["$$ID"], "$$class": 6},
            "toTransformation": {"##ID": tgt_id, "$$class": 9}}

    content = {"$$IID": "stringIdentity:@3", "$$class": 1, "annotations": [layout, settings, desc],
               "allowMaxFieldLength": False, "bigIntConvertType": "ONLY_BIGINT", "documentType": "MAPPING",
               "ecoSystem": "", "name": name, "specialCharacterSupport": False, "templateOrigin": "",
               "links": [link], "transformations": [source, target]}
    return {"content": content, "metadata": {"$$classInfo": CLASS_INFO}}


def preview_jpeg(title):
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        return TINY_JPEG
    img = Image.new("RGB", (819, 300), "white")
    d = ImageDraw.Draw(img)
    for x, label in ((30, "Source\nstg.MATMAS_RUN_REQUEST_SRC"), (470, "Target\nstg.MATMAS_RUN_REQUEST\nPost SQL: sp_MATMAS_Process")):
        d.rounded_rectangle([x, 90, x + 320, 200], radius=8, fill=(214, 234, 248), outline=(150, 190, 220))
        d.multiline_text((x + 12, 105), label, fill="black")
    d.line([350, 145, 470, 145], fill=(90, 90, 90), width=2)
    d.text((30, 30), title, fill="black")
    buf = io.BytesIO()
    img.save(buf, "JPEG")
    return buf.getvalue()


def zip_bytes(entries):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for path, data in entries:
            z.writestr(path, data)
    return buf.getvalue()


def dumps(o):
    return json.dumps(o, separators=(",", ":")).encode("utf-8")


def build_dtemplate(name, asset_guid, mapping):
    now_ms = int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000)
    body = dumps(mapping)
    jpg = preview_jpeg(name)
    mt = [{"@type": "mappingTemplate", "id": "@1", "name": name, "description": mapping["content"]["annotations"][2]["body"],
           "autoExpireObject": False, "bundleVersion": "0", "assetFrsGuid": asset_guid, "templateId": "@3",
           "deployTime": now_ms, "hasParameters": False, "valid": True, "fixedConnection": True,
           "hasParametersDeployed": False, "fixedConnectionDeployed": True, "isSchemaValidationEnabled": False,
           "tasks": 0, "mappingPreviewFileRecordId": "@2", "documentType": "MAPPING", "allowMaxFieldLength": False,
           "specialCharacterSupport": False,
           "references": [{"@type": "reference", "refObjectId": "@" + CONN_GUID, "refType": "connection"}]}]
    fr = [{"@type": "fileRecord", "id": "@3", "name": name, "type": "IMFOBJECT", "size": len(body),
           "attachTime": now_ms, "additionalInfo": "com.informatica.metadata.template.common.Template"},
          {"@type": "fileRecord", "id": "@2", "name": name + "_preview.jpeg", "type": "IMAGE", "size": len(jpg),
           "attachTime": now_ms}]
    meta = [{"@type": "objectRef", "id": "@1", "type": "mappingTemplate"}]
    return zip_bytes([("metadata.meta", dumps(meta)), ("mappingTemplate.json", dumps(mt)),
                      ("fileRecord.json", dumps(fr)), ("bin/@3.bin", body), ("bin/@2.bin", jpg)])


def manifest_entry(guid_, name, otype, path, refs, content_type="JSON", state="VALID", desc=None, ctx=True):
    return {"objectGuid": guid_, "objectName": name, "objectType": otype, "path": path, "providerName": None,
            "metadata": {"modelVersion": {"major": 0, "minor": 0}, "repoInfo": None, "objectRefs": refs,
                         "contextAttributes": [{"name": "id", "value": "@1"}] if ctx else [],
                         "additionalInfo": {"description": desc, "contentType": content_type, "documentState": state}}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project-json", default=os.path.join(HERE, "ref", PROJECT_NAME + ".Project.json"),
                    help="Project.json taken from any export of the same project")
    ap.add_argument("--out", default=os.path.join(HERE, "..", "import", "MATMAS_CDI_Import.zip"))
    ap.add_argument("--mapping-name", default="m_MATMAS_PROCESS")
    ap.add_argument("--mapping-guid", default=DEFAULT_MAPPING_GUID, help="GUID of the mapping (keep it to re-import over the same mapping)")
    args = ap.parse_args()

    name = args.mapping_name
    mguid = args.mapping_guid or guid()
    pkg_name = f"{name}-{int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000)}"

    mapping = build_process_mapping(name)
    files = {}
    files[f"Explore/{PROJECT_NAME}/{name}.DTEMPLATE.zip"] = build_dtemplate(name, mguid, mapping)
    files[f"SYS/{CONN_NAME}.Connection.zip"] = zip_bytes([
        ("metadata.meta", dumps([{"@type": "objectRef", "id": "@1", "type": "connection"}])),
        ("connection.json", dumps(CONNECTION_JSON))])
    files[f"SYS/{AGENT_NAME}.AgentGroup.zip"] = zip_bytes([
        ("metadata.meta", dumps([{"@type": "objectRef", "id": "@1", "type": "runtimeEnvironment"}])),
        ("runtimeEnvironment.json", dumps(AGENT_JSON))])
    with open(args.project_json, "rb") as f:
        files[f"Explore/{PROJECT_NAME}.Project.json"] = f.read()

    manifest = {"name": pkg_name, "sourceOrgId": ORG_ID, "sourceOrgName": ORG_NAME, "exportedObjects": [
        manifest_entry(mguid, name, "DTEMPLATE", f"/Explore/{PROJECT_NAME}", [CONN_GUID], desc=""),
        manifest_entry(AGENT_GUID, AGENT_NAME, "AgentGroup", "/SYS", []),
        manifest_entry(PROJECT_GUID, PROJECT_NAME, "Project", "/Explore", [], content_type="Binary",
                       state="COMPLETE", desc="TCS Consultant", ctx=False),
        manifest_entry(CONN_GUID, CONN_NAME, "Connection", "/SYS", [AGENT_GUID], state="COMPLETE"),
    ]}
    files["exportMetadata.v2.json"] = json.dumps(manifest, indent=2).encode("utf-8")

    csv_rows = ["objectPath,objectName,objectType,id",
                f"/Explore/{PROJECT_NAME},{name},DTEMPLATE,{mguid}",
                f"/SYS,{AGENT_NAME},AgentGroup,{AGENT_GUID}",
                f"/Explore,{PROJECT_NAME},Project,{PROJECT_GUID}",
                f"/SYS,{CONN_NAME},Connection,{CONN_GUID}"]
    files[f"ContentsofExportPackage_{pkg_name}.csv"] = ("\n".join(csv_rows) + "\n").encode("utf-8")

    stamp = dt.datetime.now(dt.timezone.utc).strftime("%a %b %d %H:%M:%S UTC %Y")
    lines = ["#", "#" + stamp]
    for path, data in files.items():
        if path.startswith("ContentsofExportPackage_"):
            continue
        lines.append(path.replace(" ", "\\ ") + "=" + hashlib.sha256(data).hexdigest().upper())
    files["exportPackage.chksum"] = ("\n".join(lines) + "\n").encode("utf-8")

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "wb") as f:
        f.write(zip_bytes(list(files.items())))
    print(f"written {os.path.abspath(args.out)}")
    print(f"mapping {name} guid {mguid} package {pkg_name}")


if __name__ == "__main__":
    main()
