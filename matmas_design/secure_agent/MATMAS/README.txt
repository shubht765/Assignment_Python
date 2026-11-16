Copy this whole MATMAS folder to the Secure Agent machine, e.g.
  Windows: C:\Informatica\SecureAgent\MATMAS
  Linux  : /opt/informatica/secureagent/MATMAS
and point the flat-file connections at the sub-folders:
  FF_MATMAS_JDE      -> MATMAS\inbound\JDE
  FF_MATMAS_VISION   -> MATMAS\inbound\VISION
  FF_MATMAS_TEMPLATE -> MATMAS\inbound\_template   (only used at design time to import the 30-column source)

inbound\<ERP>\<ERP>_MATMAS.txt  : fixed file name per route (CTL_INBOUND_INTEGRATION.SOURCE_OBJECT)
archive\<ERP>\                   : archive_file script moves the file here with a timestamp suffix after a successful load
error\                           : move here manually (or extend the taskflow) when a load fails
outbound\                        : for future FILE type outbound routes
File contract: UTF-8, pipe (|) delimited, header row, no text qualifier, dates as agreed per ERP.
When the endpoints start dropping files on a share, only SOURCE_FOLDER/ARCHIVE_FOLDER in
CTL_INBOUND_INTEGRATION and the directory of the two flat-file connections change.
