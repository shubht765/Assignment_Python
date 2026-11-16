/* =====================================================================
   MATMAS - 04: end-to-end test of the SQL side WITHOUT Informatica.
   Simulates what the CDI landing mapping does (inserts the two sample
   files into LANDING_RAW, header as row 1), then drives the stages
   exactly as the taskflow does through sp_MATMAS_Run.
   ===================================================================== */
SET NOCOUNT ON;
DECLARE @b VARCHAR(40) = FORMAT(SYSUTCDATETIME(), 'yyyyMMddHHmmss');
PRINT 'BATCH_ID = ' + @b;

/* ---- iteration 1: route lookup ---------------------------------------- */
EXEC MATMAS.sp_MATMAS_Run @Stage='GET_IN_ROUTE', @RunGroup='DAILY', @Iteration=1;   -- expect IN_JDE_MATMAS_FILE, TOTAL_ROUTES=2

/* ---- simulate CDI landing of secure_agent/MATMAS/inbound/JDE/JDE_MATMAS.txt */
EXEC MATMAS.sp_MATMAS_Run @Stage='LAND_START', @BatchId=@b, @IntegrationId='IN_JDE_MATMAS_FILE';
INSERT INTO MATMAS.LANDING_RAW (BATCH_ID, INTEGRATION_ID, SRC_FILE_NAME, SRC_ROW_NUM, COL01,COL02,COL03,COL04,COL05,COL06,COL07,COL08) VALUES
 (@b,'IN_JDE_MATMAS_FILE','JDE_MATMAS.txt',1,'ERP Item Number','Material Description','Plant Code','Supplier Part#','Supplier Number','Manufacturing Part#','Start Date','End Date'),
 (@b,'IN_JDE_MATMAS_FILE','JDE_MATMAS.txt',2,'109589','SEN,PROXIMITY,29MM,12-24VDC','AUR','4462658 (Primary)','456526','4462658 (Fallback)','2026-01-01','9999-12-31'),
 (@b,'IN_JDE_MATMAS_FILE','JDE_MATMAS.txt',3,'109589','SEN,PROXIMITY,29MM,12-24VDC','AUR','4462658 (Primary)','456526','4462658 (Fallback)','2026-01-01','9999-12-31');
EXEC MATMAS.sp_MATMAS_Run @Stage='LAND_END', @BatchId=@b, @IntegrationId='IN_JDE_MATMAS_FILE', @RowsRead=3, @RowsLoaded=3;
EXEC MATMAS.sp_MATMAS_Run @Stage='HARMONIZE', @BatchId=@b, @IntegrationId='IN_JDE_MATMAS_FILE';   -- expect inserted=1, exact_duplicates=1

/* ---- iteration 2: VISION -------------------------------------------- */
EXEC MATMAS.sp_MATMAS_Run @Stage='GET_IN_ROUTE', @RunGroup='DAILY', @Iteration=2;   -- expect IN_VISION_MATMAS_FILE
EXEC MATMAS.sp_MATMAS_Run @Stage='LAND_START', @BatchId=@b, @IntegrationId='IN_VISION_MATMAS_FILE';
INSERT INTO MATMAS.LANDING_RAW (BATCH_ID, INTEGRATION_ID, SRC_FILE_NAME, SRC_ROW_NUM, COL01,COL02,COL03,COL04,COL05,COL06,COL07,COL08,COL09,COL10) VALUES
 (@b,'IN_VISION_MATMAS_FILE','VISION_MATMAS.txt',1,'ITEM_CODE','ITEM_DESC','SITE','VENDOR_ID','VENDOR_PART','PART_PRIORITY','MFR_PART','EFF_FROM','EFF_TO','UOM'),
 (@b,'IN_VISION_MATMAS_FILE','VISION_MATMAS.txt',2,'V-20001','SENSOR PROXIMITY 18MM 24VDC','MEL','78001','PX-18-24','P','PX-18-24','01/02/2026','31/12/9999','EA'),
 (@b,'IN_VISION_MATMAS_FILE','VISION_MATMAS.txt',3,'V-20001','SENSOR PROXIMITY 18MM 24VDC','MEL','78002','PX18-ALT','F','','01/02/2026','31/12/9999','EA'),
 (@b,'IN_VISION_MATMAS_FILE','VISION_MATMAS.txt',4,'V-20002','CABLE M12 4PIN 5M','MEL','78001','CB-M12-5','P','CB-M12-5','31/02/2026','','EA');  -- bad date -> reject
EXEC MATMAS.sp_MATMAS_Run @Stage='LAND_END', @BatchId=@b, @IntegrationId='IN_VISION_MATMAS_FILE', @RowsRead=4, @RowsLoaded=4;
EXEC MATMAS.sp_MATMAS_Run @Stage='HARMONIZE', @BatchId=@b, @IntegrationId='IN_VISION_MATMAS_FILE';  -- expect inserted=2, rejected=1

/* ---- iteration 3: no more inbound routes ------------------------------ */
EXEC MATMAS.sp_MATMAS_Run @Stage='GET_IN_ROUTE', @RunGroup='DAILY', @Iteration=3;   -- expect STATUS=NONE

/* ---- outbound --------------------------------------------------------- */
EXEC MATMAS.sp_MATMAS_Run @Stage='GET_OUT_ROUTE', @RunGroup='DAILY', @Iteration=1;  -- expect OUT_ALL_TO_TARGET
EXEC MATMAS.sp_MATMAS_Run @Stage='PUBLISH', @BatchId=@b, @IntegrationId='OUT_ALL_TO_TARGET';   -- expect published=3

/* ---- results ---------------------------------------------------------- */
SELECT 'TARGET' AS what, * FROM MATMAS.MATERIAL_MASTER_TARGET ORDER BY [Source System], [ERP Item Number];
SELECT 'CANONICAL' AS what, SOURCE_SYSTEM, ERP_ITEM_NUMBER, PLANT_CODE, SUPPLIER_NUMBER, SUPPLIER_PART_NUMBER, SUPPLIER_PART_ROLE,
       MANUFACTURER_PART_NUMBER, MANUFACTURER_PART_ROLE, START_DATE, END_DATE, ITEM_STATUS, CURRENT_FLAG, VALID_FROM_TS
FROM   MATMAS.MATERIAL_MASTER ORDER BY SOURCE_SYSTEM, ERP_ITEM_NUMBER, VALID_FROM_TS;
SELECT 'REJECTS' AS what, * FROM MATMAS.MATERIAL_MASTER_REJECT WHERE BATCH_ID = @b;
SELECT 'RUN LOG' AS what, * FROM MATMAS.CTL_BATCH_RUN WHERE BATCH_ID = @b ORDER BY START_TS;

/* ---- optional: run the JDE file again with a changed description to see SCD2 ----
DECLARE @b2 VARCHAR(40) = FORMAT(SYSUTCDATETIME(), 'yyyyMMddHHmmss');
INSERT INTO MATMAS.LANDING_RAW (BATCH_ID, INTEGRATION_ID, SRC_FILE_NAME, SRC_ROW_NUM, COL01,COL02,COL03,COL04,COL05,COL06,COL07,COL08) VALUES
 (@b2,'IN_JDE_MATMAS_FILE','JDE_MATMAS.txt',1,'ERP Item Number','Material Description','Plant Code','Supplier Part#','Supplier Number','Manufacturing Part#','Start Date','End Date'),
 (@b2,'IN_JDE_MATMAS_FILE','JDE_MATMAS.txt',2,'109589','SEN,PROXIMITY,29MM,12-24VDC,IP67','AUR','4462658 (Primary)','456526','4462658 (Fallback)','2026-01-01','9999-12-31');
EXEC MATMAS.sp_MATMAS_Run @Stage='HARMONIZE', @BatchId=@b2, @IntegrationId='IN_JDE_MATMAS_FILE';  -- expect inserted=1 closed_changed=1
-------------------------------------------------------------------------------- */
