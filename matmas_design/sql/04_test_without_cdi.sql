/* =====================================================================
   MATMAS - 04: end-to-end test of the SQL side WITHOUT Informatica.
   Step A inserts exactly what m_MATMAS_LAND writes (file path + COL01..),
   step B inserts what m_MATMAS_PROCESS writes and calls what its Post SQL
   calls. Expected results are in the comments.
   ===================================================================== */
SET NOCOUNT ON;

/* ---- A. simulate m_MATMAS_LAND reading both inbound folders ---------- */
INSERT INTO MATMAS.LANDING_RAW (SRC_FILE_NAME, COL01,COL02,COL03,COL04,COL05,COL06,COL07,COL08) VALUES
 (N'C:\Informatica\SecureAgent\MATMAS\inbound\JDE\JDE_MATMAS.txt', N'ERP Item Number',N'Material Description',N'Plant Code',N'Supplier Part#',N'Supplier Number',N'Manufacturing Part#',N'Start Date',N'End Date'),
 (N'C:\Informatica\SecureAgent\MATMAS\inbound\JDE\JDE_MATMAS.txt', N'109589',N'SEN,PROXIMITY,29MM,12-24VDC',N'AUR',N'4462658 (Primary)',N'456526',N'4462658 (Fallback)',N'2026-01-01',N'9999-12-31'),
 (N'C:\Informatica\SecureAgent\MATMAS\inbound\JDE\JDE_MATMAS.txt', N'109589',N'SEN,PROXIMITY,29MM,12-24VDC',N'AUR',N'4462658 (Primary)',N'456526',N'4462658 (Fallback)',N'2026-01-01',N'9999-12-31');

INSERT INTO MATMAS.LANDING_RAW (SRC_FILE_NAME, COL01,COL02,COL03,COL04,COL05,COL06,COL07,COL08,COL09,COL10) VALUES
 (N'C:\Informatica\SecureAgent\MATMAS\inbound\VISION\VISION_MATMAS.txt', N'ITEM_CODE',N'ITEM_DESC',N'SITE',N'VENDOR_ID',N'VENDOR_PART',N'PART_PRIORITY',N'MFR_PART',N'EFF_FROM',N'EFF_TO',N'UOM'),
 (N'C:\Informatica\SecureAgent\MATMAS\inbound\VISION\VISION_MATMAS.txt', N'V-20001',N'SENSOR PROXIMITY 18MM 24VDC',N'MEL',N'78001',N'PX-18-24',N'P',N'PX-18-24',N'01/02/2026',N'31/12/9999',N'EA'),
 (N'C:\Informatica\SecureAgent\MATMAS\inbound\VISION\VISION_MATMAS.txt', N'V-20001',N'SENSOR PROXIMITY 18MM 24VDC',N'MEL',N'78002',N'PX18-ALT',N'F',N'',N'01/02/2026',N'31/12/9999',N'EA'),
 (N'C:\Informatica\SecureAgent\MATMAS\inbound\VISION\VISION_MATMAS.txt', N'V-20002',N'CABLE M12 4PIN 5M',N'MEL',N'78001',N'CB-M12-5',N'P',N'CB-M12-5',N'31/02/2026',N'',N'EA');   -- invalid date -> reject

/* ---- B. simulate m_MATMAS_PROCESS: one request row, then its Post SQL */
INSERT INTO MATMAS.CTL_RUN_REQUEST (REQUEST_SOURCE, REQUEST_NOTE)
SELECT REQUEST_SOURCE, REQUEST_NOTE FROM MATMAS.V_MATMAS_RUN_REQUEST;     -- note: "pending landing rows: 7"

EXEC MATMAS.sp_MATMAS_Process;

/* ---- results ---------------------------------------------------------- */
-- expected: STATUS = SUCCESS, files=2 routed=2
SELECT TOP 1 'RUN' AS what, * FROM MATMAS.CTL_RUN_REQUEST ORDER BY RUN_ID DESC;

-- expected 3 rows: JDE 109589 (once), VISION V-20001 x2 (vendors 78001 primary, 78002 fallback)
SELECT 'TARGET' AS what, * FROM MATMAS.MATERIAL_MASTER_TARGET ORDER BY [Source System], [ERP Item Number], [Supplier Number];

SELECT 'CANONICAL' AS what, SOURCE_SYSTEM, ERP_ITEM_NUMBER, PLANT_CODE, SUPPLIER_NUMBER, SUPPLIER_PART_NUMBER, SUPPLIER_PART_ROLE,
       MANUFACTURER_PART_NUMBER, MANUFACTURER_PART_ROLE, START_DATE, END_DATE, ITEM_STATUS, CURRENT_FLAG, VALID_FROM_TS
FROM   MATMAS.MATERIAL_MASTER ORDER BY SOURCE_SYSTEM, ERP_ITEM_NUMBER, VALID_FROM_TS;

-- expected 1 row: V-20002 'INVALID START_DATE'
SELECT 'REJECTS' AS what, * FROM MATMAS.MATERIAL_MASTER_REJECT
WHERE  BATCH_ID = (SELECT TOP 1 BATCH_ID FROM MATMAS.CTL_RUN_REQUEST ORDER BY RUN_ID DESC);

-- expected: ASSIGN x2, HARMONIZE x2 (JDE exact_duplicates=1), PUBLISH published=3
SELECT 'RUN LOG' AS what, * FROM MATMAS.V_MATMAS_RUN_STATUS
WHERE  RUN_ID = (SELECT MAX(RUN_ID) FROM MATMAS.CTL_RUN_REQUEST) ORDER BY STAGE, INTEGRATION_ID;

/* ---- optional C: change history (SCD2). Run after A+B. ---------------
INSERT INTO MATMAS.LANDING_RAW (SRC_FILE_NAME, COL01,COL02,COL03,COL04,COL05,COL06,COL07,COL08) VALUES
 (N'C:\Informatica\SecureAgent\MATMAS\inbound\JDE\JDE_MATMAS.txt', N'ERP Item Number',N'Material Description',N'Plant Code',N'Supplier Part#',N'Supplier Number',N'Manufacturing Part#',N'Start Date',N'End Date'),
 (N'C:\Informatica\SecureAgent\MATMAS\inbound\JDE\JDE_MATMAS.txt', N'109589',N'SEN,PROXIMITY,29MM,12-24VDC,IP67',N'AUR',N'4462658 (Primary)',N'456526',N'4462658 (Fallback)',N'2026-01-01',N'9999-12-31');
EXEC MATMAS.sp_MATMAS_Process;   -- expected JDE: inserted=1 closed_changed=1; target shows the new description
------------------------------------------------------------------------ */

/* ---- optional D: reset test data ------------------------------------
TRUNCATE TABLE MATMAS.LANDING_RAW; TRUNCATE TABLE MATMAS.MATERIAL_MASTER; TRUNCATE TABLE MATMAS.MATERIAL_MASTER_REJECT;
TRUNCATE TABLE MATMAS.MATERIAL_MASTER_OUTBOUND; TRUNCATE TABLE MATMAS.MATERIAL_MASTER_TARGET; TRUNCATE TABLE MATMAS.CTL_BATCH_RUN;
TRUNCATE TABLE MATMAS.CTL_RUN_REQUEST;
------------------------------------------------------------------------ */
