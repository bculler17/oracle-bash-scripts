#!/bin/bash
#
# ----------------------------------------------------------------------------------------------------------------------------------
# This script performs Unified Audit Trail maintenance for a 19c standalone or 2-node RAC database.
# Run on node 1 of a 2 node RAC database
# Scheduling this script to run daily will keep a 45 day rolling window of data in the UNIFIED_AUDIT_TRAIL table and a rolling 1.5 year's worth of data in the audit archive table. 
# Audit records older than 45 days will first be archived into an archive table before being purged from the UNIFIED_AUDIT_TRAIL table.
# Any OS Spillover Audit Records on each node of a standalone or 2-node RAC cluster will also be moved into the Unified Audit Trail and deleted from the OS.
#
# Author: Beth Culler
# Created: 4/19/2021
# ----------------------------------------------------------------------------------------------------------------------------------
# turn on debug by uncommenting below line.
# -----------------------------------------------------------------
# set -x
# -----------------------------------------------------------------
# Set Local Variables.
# -----------------------------------------------------------------
MAILTO=<ENTER EMAIL>
DATE_TIME_FM=`date +%Y%m%d_%H%M%S`
DTMASK=`date +%Y%m%d`
SQLUSER="<username/password>"                      # User used to log into database
LOG_LOC=<ENTER LOG DIRECTORY>
ORABASE=<ENTER $ORACLE_BASE>                       # The correct $ORACLE_BASE
GRID_HOME=<ENTER GRID HOME>
AUD_ARCHIVE=45                                     # rolling day window of data to keep in the UNIFIED_AUDIT_TRAIL table                     
ARCHIVE_PURGE=548                                  # rolling day window of data to keep in the archive table
# -----------------------------------------------------------------
# Export Variables to be used.
# -----------------------------------------------------------------
export PATH=$PATH:/usr/local/bin
export NLS_LANG=AMERICAN_AMERICA.WE8MSWIN1252
export ORA_NLS11=$ORACLE_HOME/nls/data
export NLS_DATE_FORMAT='Mon DD YYYY HH24:MI:SS'
export DB_NAME=$1
export AUDM_LOG_FILE=${LOG_LOC}/${DB_NAME}_audit_tr_maintenance_$DATE_TIME_FM.log
export ORACLE_SID=$DB_NAME
export ORAENV_ASK=NO;
# -----------------------------------------------------------------
# Setup Oracle Environment
# -----------------------------------------------------------------
. /usr/local/bin/oraenv
# -----------------------------------------------------------------
# Initialize the log file.
# -----------------------------------------------------------------
> $AUDM_LOG_FILE
chmod 666 $AUDM_LOG_FILE
# -----------------------------------------------------------------
# Log the start of this script.
# -----------------------------------------------------------------
echo Script $0 >> $AUDM_LOG_FILE
echo ==== started on `date` ==== >> $AUDM_LOG_FILE
echo "Purpose: to archive and purge audit records that are older than ${AUD_ARCHIVE} days from the UNIFIED_AUDIT_TRAIL table in $DB_NAME, to delete archived records that are older than ${ARCHIVE_PURGE} days from the archive table, and move any OS Spillover Audit Records into the Unified Audit Trail and delete from the OS."   >> $AUDM_LOG_FILE
echo " " >> $AUDM_LOG_FILE
# -----------------------------------------------------------------
# Check if a previous purge is still executing.
# -----------------------------------------------------------------
if [ -f /tmp/audit_purge_$DB_NAME.lck ]; then
  echo "* * * `date` * * *"  >> $AUDM_LOG_FILE
  echo "$0 : CANNOT EXECUTE. " >> $AUDM_LOG_FILE
  echo "A previous purge of the UNIFIED_AUDIT_TRAIL table in $DB_NAME is still running. Cannot start a new purge." >> $AUDM_LOG_FILE
  mail -s "${DB_NAME}: UNIFIED_AUDIT_TRAIL PURGE IS STILL RUNNING" ${MAILTO} < $AUDM_LOG_FILE
  exit
fi
# ------------------------------------------------------------------
# Determine the number of records that need to be archived.
# ------------------------------------------------------------------
echo "`date` : Starting the UNIFIED_AUDIT_TRAIL archive." >> $AUDM_LOG_FILE
echo "Archiving records that are older than ${AUD_ARCHIVE} days from UNIFIED_AUDIT_TRAIL into the UNIFIED_AUDIT_ARCHIVE table.." >> $AUDM_LOG_FILE
echo " " >> $AUDM_LOG_FILE
echo "DATABASE           NUMBER OF AUDIT RECORDS > ${AUD_ARCHIVE} DAYS NEEDING TO BE ARCHIVED:" >> $AUDM_LOG_FILE 
echo "========           =========================================================" >> $AUDM_LOG_FILE
SQL_OUT=`sqlplus -S /nolog<<EOF 
        connect $SQLUSER
	set feedback off
        set echo off
        set pages 0
        spool /tmp/audit_tr_maint1.txt 
        select name, (select count(*) from UNIFIED_AUDIT_TRAIL where EVENT_TIMESTAMP_UTC < trunc(sysdate - ${AUD_ARCHIVE})) AS "NEEDING ARCHIVED" from v\\$database;
        exit;
EOF
`
# Test to make sure an ORA- error was not encountered
export TEST=`grep 'ORA-' /tmp/audit_tr_maint1.txt`
case $TEST in
  *ORA-*)
    # An ORA- error occurred. Delete file so that the script does not execute
    rm -f /tmp/audit_tr_maint1.txt
esac
if [ -f /tmp/audit_tr_maint1.txt ]; then
  cat /tmp/audit_tr_maint1.txt >> $AUDM_LOG_FILE
  echo " " >> $AUDM_LOG_FILE
  TO_ARCHIVE=`cat /tmp/audit_tr_maint1.txt |awk '{print $2}'`
  if [ "${TO_ARCHIVE}" -eq 0 ]; then
    echo "There are 0 records needing to be archived and purged." >> $AUDM_LOG_FILE
    echo "The archive and purge of the UNIFIED_AUDIT_TRAIL table and the purge of the UNIFIED_AUDIT_ARCHIVE tables did not execute on `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
    ESTAT=2
# ----------------------------------------------------------------------------
# Archive the UNIFIED_AUDIT_TRAIL records that are older than ${AUD_ARCHIVE} days into AUDIT_ARCHIVE.
# ----------------------------------------------------------------------------
  else
    echo "SQL> insert into UNIFIED_AUDIT_ARCHIVE (select * from UNIFIED_AUDIT_TRAIL where EVENT_TIMESTAMP_UTC < trunc(sysdate - ${AUD_ARCHIVE}));" >> $AUDM_LOG_FILE 
    SQL_OUT=`sqlplus -S /nolog<<EOF 
            connect $SQLUSER
            set echo off
            spool /tmp/audit_tr_maint2.txt
    	    insert into UNIFIED_AUDIT_ARCHIVE (select * from UNIFIED_AUDIT_TRAIL where EVENT_TIMESTAMP_UTC < trunc(sysdate - ${AUD_ARCHIVE}));
            exit;
EOF
`     
    if [ -f /tmp/audit_tr_maint2.txt ]; then
      cat /tmp/audit_tr_maint2.txt >> $AUDM_LOG_FILE
      echo "Finished the UNIFIED_AUDIT_TRAIL Archive for $DB_NAME at `date '+%b %d %Y %H:%M:%S'`" >> $AUDM_LOG_FILE
      NUM_ARCHIVED=`cat /tmp/audit_tr_maint2.txt |awk '{print $1}'`
      echo "${NUM_ARCHIVED}" records were archived from UNIFIED_AUDIT_TRAIL into AUDIT_ARCHIVE. >> $AUDM_LOG_FILE
      echo " " >> $AUDM_LOG_FILE
# ----------------------------------------------------------
# Update the LAST_ARCHIVE_TIME parameter. 
# ----------------------------------------------------------
      # Make sure the number of records that were archived match the number of records that are older than ${AUD_ARCHIVE} days before moving forward with the purge
      # This will avoid purging records that were not successfully archived 
      if [ "$NUM_ARCHIVED" -eq "$TO_ARCHIVE" ]; then
        # Number of records archived equals the number of records that are older than ${AUD_ARCHIVE} days, so continue with the purge..
        # Update the last_archive_time parameter
        echo "`date` : Updating the last_archive_time parameter.." >> $AUDM_LOG_FILE
        SQL_OUT=`sqlplus -S /nolog<<EOF >> $AUDM_LOG_FILE
                connect $SQLUSER
                alter session set NLS_DATE_FORMAT='DD-MON-YYYY HH24:MI:SS';
                set serveroutput on
                begin
                  dbms_audit_mgmt.set_last_archive_timestamp(
     	  	    audit_trail_type  => DBMS_AUDIT_MGMT.AUDIT_TRAIL_UNIFIED,
		    last_archive_time => trunc(SYSTIMESTAMP - ${AUD_ARCHIVE}),
		    RAC_INSTANCE_NUMBER  =>  null
   	          );
	        end;
                /
                exit;
EOF
`
        SQL_OUT=`sqlplus -S /nolog<<EOF
                connect $SQLUSER
                alter session set NLS_DATE_FORMAT='DD-MON-YYYY_HH24:MI:SS';
	        set feedback off
                set echo off
                set pages 0
                spool /tmp/last_archive_timestmp.txt
                select trunc(LAST_ARCHIVE_TS), (select trunc(systimestamp - ${AUD_ARCHIVE}) from dual) AS "TARGET DATE" from DBA_AUDIT_MGMT_LAST_ARCH_TS where audit_trail='UNIFIED AUDIT TRAIL';
                exit;
EOF
`
        if [ -f /tmp/last_archive_timestmp.txt ]; then
          LST_AR=`cat /tmp/last_archive_timestmp.txt |awk '{print $1}'`
          CORRECT_DAY=`cat /tmp/last_archive_timestmp.txt |awk '{print $2}'`
          echo New LAST_ARCHIVE_TS = "${LST_AR}" >> $AUDM_LOG_FILE
          echo Correct timestamp = "${CORRECT_DAY}" >> $AUDM_LOG_FILE
# ----------------------------------------------------------
# Purge UNIFIED_AUDIT_TRAIL of records that are older than ${AUD_ARCHIVE} days.
# ----------------------------------------------------------
          # Verify that the last_archive_time parameter was successfully updated to ${AUD_ARCHIVE} days ago.
          if [ "${LST_AR}" == "${CORRECT_DAY}" ]; then
            echo "The last_archive_time parameter was successfully updated; it is safe to purge." >> $AUDM_LOG_FILE
	    echo " " >> $AUDM_LOG_FILE
	    echo "`date` : Starting the UNIFIED_AUDIT_TRAIL purge." >> $AUDM_LOG_FILE
            echo "Purging records that are older than ${AUD_ARCHIVE} days from the UNIFIED_AUDIT_TRAIL table.." >> $AUDM_LOG_FILE
            echo " " >> $AUDM_LOG_FILE
            touch /tmp/audit_purge_$DB_NAME.lck
            SQL_OUT=`sqlplus -S /nolog<<EOF >> $AUDM_LOG_FILE
                    connect $SQLUSER
                    set serveroutput on
                    begin
  	  	      dbms_audit_mgmt.clean_audit_trail(
   		        audit_trail_type        =>  DBMS_AUDIT_MGMT.AUDIT_TRAIL_UNIFIED,
   		        use_last_arch_timestamp => TRUE
  		      );
		    end;
	            /
                    exit;
EOF
`
            echo " " >> $AUDM_LOG_FILE
            echo "Finished the UNIFIED_AUDIT_TRAIL Purge for $DB_NAME at `date '+%b %d %Y %H:%M:%S'`" >> $AUDM_LOG_FILE
            echo " " >> $AUDM_LOG_FILE
            ESTAT=0
            rm -f /tmp/audit_purge_$DB_NAME.lck
            echo " " >> $AUDM_LOG_FILE
            echo "DATABASE           NUMBER OF AUDIT RECORDS > ${AUD_ARCHIVE} DAYS NEEDING TO BE ARCHIVED:" >> $AUDM_LOG_FILE 
            echo "========           =========================================================" >> $AUDM_LOG_FILE
            SQL_OUT=`sqlplus -S /nolog<<EOF >> $AUDM_LOG_FILE
                    connect $SQLUSER
                    set feedback off
                    set echo off
                    set pages 0
                    spool /tmp/audit_tr_maint1.txt 
                    select name, (select count(*) from UNIFIED_AUDIT_TRAIL where EVENT_TIMESTAMP_UTC < trunc(sysdate - ${AUD_ARCHIVE})) AS "NEEDING ARCHIVED" from v\\$database;
                    exit;
EOF
`
          else
            # The last_archive_time parameter was not successfully updated; it is not safe to purge.
            ESTAT=1
            echo "CRITICAL: Updating the LAST_ARCHIVE_TIME parameter may have failed. Correct timestamp = $CORRECT_DAY." >> $AUDM_LOG_FILE
            echo "The purge will not execute to avoid purging the entire UNIFIED_AUDIT_TRAIL table instead of purging only records that are older than ${AUD_ARCHIVE} days." >> $AUDM_LOG_FILE
          fi
        else
          ESTAT=1
          echo "CRITICAL: Updating the LAST_ARCHIVE_TIME parameter may have failed." >> $AUDM_LOG_FILE
          echo "The purge will not execute to avoid purging the entire UNIFIED_AUDIT_TRAIL table instead of purging only records that are older than ${AUD_ARCHIVE} days." >> $AUDM_LOG_FILE 
        fi
      else
        ESTAT=1
        echo "WARNING: Archive possibly failed! Or completed in error: the number of records that were archived may not match the number of records that are older than ${AUD_ARCHIVE} days." >> $AUDM_LOG_FILE
        echo "The purge will not execute to avoid possibly deleting records that may have not been archived." >> $AUDM_LOG_FILE
      fi
    else
      ESTAT=1
      echo "WARNING: Archive possibly failed!" >> $AUDM_LOG_FILE
      echo "The purge will not execute to avoid possibly deleting records that may have not been archived." >> $AUDM_LOG_FILE
    fi
  fi
else
  ESTAT=1
  echo "WARNING: An error occurred accessing the DB or accessing the UNIFIED_AUDIT_TRAIL table." >> $AUDM_LOG_FILE
  echo "The archive and purge of the UNIFIED_AUDIT_TRAIL table in $DB_NAME did not execute." >> $AUDM_LOG_FILE
fi   
# -----------------------------------------------------------------
# Log the completion of the archive and purge of UNIFIED_AUDIT_TRAIL.
# -----------------------------------------------------------------
if [ "$ESTAT" = 0 ]
then
  LOGMSG="completed"
elif [ "$ESTAT" = 2 ]
then
  LOGMSG="was not needed"
else
  LOGMSG="ended in error"
fi
echo " " >> $AUDM_LOG_FILE
echo " " >> $AUDM_LOG_FILE
echo ========================================================= >> $AUDM_LOG_FILE
echo Return Status for UNIFIED_AUDIT_TRAIL Maintenance is: $ESTAT >> $AUDM_LOG_FILE
echo ========================================================= >> $AUDM_LOG_FILE
echo " " >> $AUDM_LOG_FILE
echo "The archive and purge of the UNIFIED_AUDIT_TRAIL table in $DB_NAME" >> $AUDM_LOG_FILE
echo ==== $LOGMSG on `date` ==== >> $AUDM_LOG_FILE
# ----------------------------------------------------------------------------------
# Remove records from the archive table that are older than ${ARCHIVE_PURGE} days.
# ----------------------------------------------------------------------------------
echo " " >> $AUDM_LOG_FILE
echo " " >> $AUDM_LOG_FILE
echo "`date` : Starting the UNIFIED_AUDIT_ARCHIVE maintenance." >> $AUDM_LOG_FILE
echo "Removing records that are older than ${ARCHIVE_PURGE} days from the archive table.." >> $AUDM_LOG_FILE
echo " " >> $AUDM_LOG_FILE
SQL_OUT=`sqlplus -S /nolog<<EOF >> $AUDM_LOG_FILE
        connect $SQLUSER
        set echo off
        set pages 0
        select 'Current total # of records in unified_audit_archive: ' || count(*) from unified_audit_archive;
        select 'SQL> delete UNIFIED_AUDIT_ARCHIVE where trunc(EVENT_TIMESTAMP) < trunc(sysdate - ${ARCHIVE_PURGE});' from dual;
	delete UNIFIED_AUDIT_ARCHIVE where trunc(EVENT_TIMESTAMP) < trunc(sysdate - ${ARCHIVE_PURGE});
        select 'New Total: ' || count(*) from unified_audit_archive;
        commit;
        exit;    
EOF
  ` 
echo " " >> $AUDM_LOG_FILE
echo "Finished the UNIFIED_AUDIT_ARCHIVE maintenance for $DB_NAME at `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
echo " " >> $AUDM_LOG_FILE
# -------------------------------------------------------------------
# Move Any OS Spillover Audit Records into the Unified Audit Trail
# -------------------------------------------------------------------
# Get instance name
SQL_OUT=`sqlplus -S /nolog<<EOF 
        connect $SQLUSER
        spool /tmp/instname.txt
        set pages 0
	select instance_name from v\\$instance;
        exit;
EOF
`   
INSTNAME=`cat /tmp/instname.txt |awk '{print $1}'`
rm -f /tmp/instname.txt  
# Get the number of spillover audit files on the OS
SPILLOVER_COUNT=$(ls -1 ${ORABASE}/audit/${INSTNAME} | wc -l | sed 's/^[ \t]*//;s/[ \t]*$//')
echo "$SPILLOVER_COUNT spillover audit records have been found in ${ORABASE}/audit/${INSTNAME}." >> $AUDM_LOG_FILE
echo " " >> $AUDM_LOG_FILE
if [ $SPILLOVER_COUNT -gt 0 ]; then
  echo "`date` : Starting the OS spillover audit record maintenance for $INSTNAME." >> $AUDM_LOG_FILE
  echo "Moving $SPILLOVER_COUNT spillover audit records into the AUDSYS schema audit table and deleting them from the OS...." >> $AUDM_LOG_FILE
  # The following procedure loads the spillover audit records into the AUDSYS schema audit table immediately and deletes them from the OS.
  SQL_OUT=`sqlplus -S /nolog<<EOF >> $AUDM_LOG_FILE
          connect $SQLUSER      
          set serveroutput on
          EXEC DBMS_AUDIT_MGMT.LOAD_UNIFIED_AUDIT_FILES;      
          exit;
EOF
`
  SPILLOVER_COUNT2=$(ls -1 ${ORABASE}/audit/${INSTNAME} | wc -l | sed 's/^[ \t]*//;s/[ \t]*$//')
  if [ $SPILLOVER_COUNT2 -gt 0 ]; then
    echo "$SPILLOVER_COUNT spillover audit files were moved into the db." >> $AUDM_LOG_FILE
    echo "$SPILLOVER_COUNT2 spillover audit files out of the $SPILLOVER_COUNT were moved into the db but cannot be deleted from the OS." >> $AUDM_LOG_FILE
    echo "A probable cause for this is because the session id associated with these files is owned by the PMON process, and manual cleanup is now required." >> $AUDM_LOG_FILE
    echo "Please see Doc ID 2570945.1 for more details." >> $AUDM_LOG_FILE
    echo " " >> $AUDM_LOG_FILE
    echo "Manually removing .bin files older than ${ARCHIVE_PURGE} days... " >> $AUDM_LOG_FILE
    find ${ORABASE}/audit/${INSTNAME} -name "*.bin" -mtime +${ARCHIVE_PURGE} -exec rm -f {} \;
    SPILLOVER_COUNT2=$(ls -1 ${ORABASE}/audit/${INSTNAME} | wc -l | sed 's/^[ \t]*//;s/[ \t]*$//')
  fi
  echo " " >> $AUDM_LOG_FILE
  echo "$SPILLOVER_COUNT2 spillover audit records now remain in ${ORABASE}/audit/${INSTNAME}." >> $AUDM_LOG_FILE
  echo "Finished the OS spillover audit record maintenance for $INSTNAME at `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
  echo " " >> $AUDM_LOG_FILE
fi
# Determine if other nodes exist; their spill over audit records will need maintenance also
NUMNODES=`/u01/112/grid/bin/olsnodes | wc -l`
if [ $NUMNODES -eq 2 ]; then
  # Perform the same spillover audit record maintenance on node 2
  $GRID_HOME/bin/olsnodes > /tmp/nodelist.txt
  cat /tmp/nodelist.txt | tail -n 1 | while read NLST; do
    NODE2=`echo $NLST |awk '{print $1}'`
  done
  cat /tmp/nodelist.txt | head -n 1 | while read NLST; do
    NODE1=`echo $NLST |awk '{print $1}'`
  done
  rm -f /tmp/nodelist.txt
  ssh oracle@$NODE2 "
    # Get instance name
    export ORAENV_ASK=NO;
    . /usr/local/bin/oraenv
    SQL_OUT=`sqlplus -S /nolog<<EOF 
          connect $SQLUSER
          spool /tmp/instname.txt
          set pages 0
	  select instance_name from v\\$instance;
          exit;
EOF
`   
    INSTNAME2=`cat /tmp/instname.txt |awk '{print $1}'` 
    rm -f /tmp/instname.txt 
    # Get the number of spillover audit files on the OS
    SPILLOVER_COUNT2=$(ls -1 ${ORABASE}/audit/${INSTNAME2} | wc -l | sed 's/^[ \t]*//;s/[ \t]*$//')
"
    echo "$SPILLOVER_COUNT2 spillover audit records have been found in ${ORABASE}/audit/${INSTNAME2}." >> $AUDM_LOG_FILE
    echo " " >> $AUDM_LOG_FILE
    if [ $SPILLOVER_COUNT -gt 0 ]; then
      echo "`date` : Starting the OS spillover audit record maintenance for $INSTNAME2." >> $AUDM_LOG_FILE
      echo "Moving $SPILLOVER_COUNT spillover audit records into the AUDSYS schema audit table and deleting them from the OS...." >> $AUDM_LOG_FILE
      # The following procedure loads the spillover audit records into the AUDSYS schema audit table immediately and deletes them from the OS.
      ssh oracle@$NODE2 "
        export ORAENV_ASK=NO;
        . /usr/local/bin/oraenv
        SQL_OUT=`sqlplus -S /nolog<<EOF 
               connect $SQLUSER      
               EXEC DBMS_AUDIT_MGMT.LOAD_UNIFIED_AUDIT_FILES;      
               exit;
EOF
`
        SPILLOVER_COUNT2=$(ls -1 ${ORABASE}/audit/${INSTNAME2} | wc -l | sed 's/^[ \t]*//;s/[ \t]*$//')
        if [ $SPILLOVER_COUNT2 -gt 0 ]; then
          echo "$SPILLOVER_COUNT spillover audit files were moved into the db." >> $AUDM_LOG_FILE
    	  echo "$SPILLOVER_COUNT2 spillover audit files out of the $SPILLOVER_COUNT were moved into the db but cannot be deleted from the OS." >> $AUDM_LOG_FILE
    	  echo "A probable cause for this is because the session id associated with these files is owned by the PMON process, and manual cleanup is now required." >> $AUDM_LOG_FILE
    	  echo "Please see Doc ID 2570945.1 for more details." >> $AUDM_LOG_FILE
    	  echo " " >> $AUDM_LOG_FILE
    	  echo "Manually removing spillover audit files older than ${ARCHIVE_PURGE} days from ${ORABASE}/audit/${INSTNAME}" >> $AUDM_LOG_FILE
     	  OLDNUM=$(find ${ORABASE}/audit/${INSTNAME} -name "*.bin" -mtime +${ARCHIVE_PURGE} | wc-l)
    	  if [ $OLDNUM -gt 0 ]; then
            find ${ORABASE}/audit/${INSTNAME} -name "*.bin" -mtime +${ARCHIVE_PURGE} -exec rm -f {} \;
          else
            echo "Could not find any files older than ${ARCHIVE_PURGE} days. Manual cleanup not required at this time." >> $AUDM_LOG_FILE
          fi
    	  SPILLOVER_COUNT2=$(ls -1 ${ORABASE}/audit/${INSTNAME} | wc -l | sed 's/^[ \t]*//;s/[ \t]*$//')
        fi
"  
    echo " " >> $AUDM_LOG_FILE
    echo "$SPILLOVER_COUNT2 spillover audit records now remain in ${ORABASE}/audit/${INSTNAME2}." >> $AUDM_LOG_FILE
    echo "Finished the OS spillover audit record maintenance for $INSTNAME2 at `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
    echo " " >> $AUDM_LOG_FILE
  fi
fi   
# -----------------------------------------------------------------
# Email script status to DBAs.
# -----------------------------------------------------------------
if [ "$ESTAT" = 0 ]
then
  mail -s "${DB_NAME}: UNIFIED_AUDIT_TRAIL ARCHIVE & PURGE COMPLETE" ${MAILTO} < $AUDM_LOG_FILE
elif [ "$ESTAT" = 2 ]
then 
  mail -s "${DB_NAME}: UNIFIED_AUDIT_TRAIL did not need an archive or purge on `date '+%b %d %Y'`." ${MAILTO} < $AUDM_LOG_FILE
else
  mail -s "${DB_NAME}: UNIFIED_AUDIT_TRAIL ARCHIVE & PURGE ERROR" ${MAILTO} < $AUDM_LOG_FILE
fi
# -----------------------------------------------------------------
# Clean up /tmp/ files.
# -----------------------------------------------------------------
rm -rf /tmp/audit_tr_maint1.txt
rm -rf /tmp/audit_tr_maint2.txt
rm -rf /tmp/last_archive_timestmp.txt
#----------------------------------------------------------------------
# Remove cycled logs older than 30 days
#----------------------------------------------------------------------   
find $LOG_LOC -name "${DB_NAME}_audit_tr_maintenance*.log" -mtime +30 -exec rm -rf {} \;
export ORAENV_ASK=YES;
#set +x
exit 
