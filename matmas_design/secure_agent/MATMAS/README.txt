MATMAS folder for the Secure Agent (runtime environment US.US02.01)

Copy this whole folder to the agent machine:
  Windows: C:\Informatica\SecureAgent\MATMAS     (path used in all docs and commands)
  Linux  : /opt/informatica/MATMAS               (use the .sh scripts)

inbound\<ERP>\     one folder per ERP; drop files here (*.txt / *.csv, pipe delimited, header row, UTF-8)
                   JDE\JDE_MATMAS.txt and VISION\VISION_MATMAS.txt are the test files.
                   A new ERP = a new folder + its rows in MATMAS.CTL_INBOUND_INTEGRATION / CTL_FIELD_MAPPING.
work\              flat-file connection FF_MATMAS points here.
                   matmas_filelist.txt = indirect file list, rebuilt before every run by
                   scripts\matmas_prepare_filelist.cmd (shipped version points at design\LANDING_TEMPLATE.txt
                   so the mapping designer sees 30 columns).
design\            LANDING_TEMPLATE.txt (30 columns) for design time only.
archive\<ERP>\     scripts\matmas_archive_files.cmd moves processed files here as <name>_<timestamp>.<ext>.
error\             manual quarantine for files you want to keep out of the next run.
outbound\          for future FILE-type outbound routes.
scripts\           prepare / archive scripts (.cmd Windows, .sh Linux).

Moving to a share later: change the Directory of connection FF_MATMAS and the root path argument
of the two commands in mt_MATMAS_LAND / mt_MATMAS_PROCESS. Nothing in SQL changes (routing uses the
folder name, not the full path).
