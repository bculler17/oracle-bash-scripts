#!/bin/bash
#
# ----------------------------------------------------------------------------------------------------------------------------------
# This script performs Audit Trail maintenance for an 11g database.
# Use for 11g RAC environments with 2+ nodes and an NFS mounted file system is located on node 1 (schedule to run this script from node 1), or for One Node RAC environments, or for Standalone Databases.
# Scheduling this script to run daily for each DB will keep a 45 day rolling window of data in the aud$ table, a rolling 1.5 year's worth of data in the audit archive table, a rolling 15 day window in the ASM and DB AUDIT_FILE_DEST on the OS on each node in the cluster, and a rolling 1.5 year's worth of AUDIT_FILE_DEST archives.
# Audit records older than 45 days will first be archived into an archive table before being purged from the aud$ table.
# ASM and DB AUDIT_FILE_DEST OS files that are older than 15 days are archived to a zip file on an NFS mounted FS and then deleted from the AUDIT_FILE_DEST
#
# Author: Beth Culler
# Created: 4/14/2021
# ----------------------------------------------------------------------------------------------------------------------------------
# turn on debug by uncommenting below line.
# -----------------------------------------------------------------
#set -x
# -----------------------------------------------------------------
# Set Local Variables.
# -----------------------------------------------------------------
MAILTO=<ENTER EMAIL>
DATE_TIME_FM=`date +%Y%m%d_%H%M%S`
DTMASK=`date +%Y%m%d`
SQLUSER="<username/password>"                      # User used to log into database
LOG_LOC=<ENTER LOG DIRECTORY>
ZIP_LOC=<ENTER NFS MOUNTED DIRECTORY>
AUD_ARCHIVE=45                                     # rolling day window of data to keep in the aud$ table                        
ARCHIVE_PURGE=548                                  # rolling day window of data to keep in the archive table
MAND_ARCHIVE=15                                    # rolling day window of data to keep in the ASM and DB AUDIT_FILE_DEST on the OS
MAND_PURGE=548                                     # rolling day window of data to keep in the AUDIT_FILE_DEST archives
# -----------------------------------------------------------------
# Export Variables to be used.
# -----------------------------------------------------------------
export PATH=$PATH:/usr/local/bin
export NLS_LANG=AMERICAN_AMERICA.WE8MSWIN1252
export ORA_NLS11=$ORACLE_HOME/nls/data
export NLS_DATE_FORMAT='Mon DD YYYY HH24:MI:SS'
export DB_NAME=$1
export AUDM_LOG_FILE=${LOG_LOC}/${DB_NAME}_audit_tr_maintenance_${DATE_TIME_FM}.log
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
echo "Purpose: to archive and purge audit records that are older than ${AUD_ARCHIVE} days from the AUD$ table in ${DB_NAME}, to delete archived records that are older than ${ARCHIVE_PURGE} days from the archive table, to archive then delete ASM and DB AUDIT_FILE_DEST OS files that are older than ${MAND_ARCHIVE} days, and to delete archived OS files that are older than ${MAND_PURGE} days." >> $AUDM_LOG_FILE
echo " " >> $AUDM_LOG_FILE
# -----------------------------------------------------------------
# Check if a previous purge is still executing.
# -----------------------------------------------------------------
if [ -f /tmp/audit_purge_$DB_NAME.lck ]; then
  echo "* * * `date` * * *"  >> $AUDM_LOG_FILE
  echo "$0 : CANNOT EXECUTE. " >> $AUDM_LOG_FILE
  echo "A previous purge of the AUD$ table in $DB_NAME is still running. Cannot start a new purge." >> $AUDM_LOG_FILE
  mail -s "${DB_NAME}: AUD$ PURGE IS STILL RUNNING" ${MAILTO} < $AUDM_LOG_FILE
  exit
fi
# ------------------------------------------------------------------
# Determine the number of records that need to be archived.
# ------------------------------------------------------------------
echo "`date` : Starting the AUD$ archive." >> $AUDM_LOG_FILE
echo "Archiving records that are older than ${AUD_ARCHIVE} days from AUD$ into the AUDIT_ARCHIVE table.." >> $AUDM_LOG_FILE
echo " " >> $AUDM_LOG_FILE
echo "DATABASE           NUMBER OF AUDIT RECORDS > ${AUD_ARCHIVE} DAYS NEEDING TO BE ARCHIVED:" >> $AUDM_LOG_FILE 
echo "========           =========================================================" >> $AUDM_LOG_FILE
SQL_OUT=`sqlplus -S /nolog<<EOF 
        connect $SQLUSER
	set feedback off
        set echo off
        set pages 0
        spool /tmp/audit_tr_maint1.txt 
        select name, (select count(*) from aud\\$ where trunc(NTIMESTAMP#) < trunc(sysdate-${AUD_ARCHIVE})) AS "NEEDING ARCHIVED" from v\\$database;
        exit;
EOF
`
# Test to make sure an ORA- error was not encountered
export TEST=`grep 'ORA-' /tmp/audit_tr_maint1.txt`
case $TEST in
  *ORA-*)
    # An ORA- error occurred. Delete file so that the script does not execute
    cat /tmp/audit_tr_maint1.txt >> $AUDM_LOG_FILE
    rm -f /tmp/audit_tr_maint1.txt
esac
if [ -f /tmp/audit_tr_maint1.txt ]; then
  cat /tmp/audit_tr_maint1.txt >> $AUDM_LOG_FILE
  echo " " >> $AUDM_LOG_FILE
  cat /tmp/audit_tr_maint1.txt |while read ASTATS; do
    TO_ARCHIVE=`echo $ASTATS |awk '{print $2}'`
  done
  rm -f /tmp/audit_tr_maint1.txt
  if [ $TO_ARCHIVE -eq 0 ]; then
    echo "There are 0 records needing to be archived and purged." >> $AUDM_LOG_FILE
    echo "The archive of the AUD$ table and the purge of the AUD$ and AUDIT_ARCHIVE tables did not execute on `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
    ESTAT=2
# ----------------------------------------------------------------------------
# Archive the AUD$ records that are older than ${AUD_ARCHIVE} days into AUDIT_ARCHIVE.
# ----------------------------------------------------------------------------
  else
    echo "SQL> insert into AUDIT_ARCHIVE (select * from aud$ where trunc(NTIMESTAMP#) < trunc(sysdate-${AUD_ARCHIVE}));" >> $AUDM_LOG_FILE 
    SQL_OUT=`sqlplus -S /nolog<<EOF 
          connect $SQLUSER
          set echo off
          spool /tmp/audit_tr_maint2.txt
	  insert into AUDIT_ARCHIVE (select * from aud\\$ where trunc(NTIMESTAMP#) < trunc(sysdate-${AUD_ARCHIVE}));
          exit;
EOF
`     
    # Test to make sure an ORA- error was not encountered
    export TEST=`grep 'ORA-' /tmp/audit_tr_maint2.txt`
    case $TEST in
      *ORA-*)
        # An ORA- error occurred. Delete file so that the script does not execute
        cat /tmp/audit_tr_maint2.txt >> $AUDM_LOG_FILE
        rm -f /tmp/audit_tr_maint2.txt
    esac
    if [ -f /tmp/audit_tr_maint2.txt ]; then
      cat /tmp/audit_tr_maint2.txt >> $AUDM_LOG_FILE
      echo "Finished the AUD$ Archive for $DB_NAME at `date '+%b %d %Y %H:%M:%S'`" >> $AUDM_LOG_FILE
      cat /tmp/audit_tr_maint2.txt |sed '/^$/d' |while read ARSTATS; do
        NUM_ARCHIVED=`echo $ARSTATS |awk '{print $1}'`
      done
      rm -f /tmp/audit_tr_maint2.txt
      echo "$NUM_ARCHIVED records were archived from AUD$ into AUDIT_ARCHIVE." >> $AUDM_LOG_FILE
      echo " " >> $AUDM_LOG_FILE
# ----------------------------------------------------------
# Update the LAST_ARCHIVE_TIME parameter. 
# ----------------------------------------------------------
      # Make sure the number of records that were archived match the number of records that are older than ${AUD_ARCHIVE} days before moving forward with the purge
      # This will avoid purging records that were not successfully archived 
      if [ $NUM_ARCHIVED -eq $TO_ARCHIVE ]; then
        # Number of records archived equals the number of records that are older than ${AUD_ARCHIVE} days, so continue with the purge..
        # Update the last_archive_time parameter
        echo "`date` : Updating the last_archive_time parameter.." >> $AUDM_LOG_FILE
        SQL_OUT=`sqlplus -S /nolog<<EOF >> $AUDM_LOG_FILE
                connect $SQLUSER
                alter session set NLS_DATE_FORMAT='DD-MON-YYYY HH24:MI:SS';
                set serveroutput on
                begin
                  dbms_audit_mgmt.set_last_archive_timestamp(
     	       	    audit_trail_type  => dbms_audit_mgmt.audit_trail_aud_std,
		    last_archive_time => trunc(SYSTIMESTAMP-${AUD_ARCHIVE}),
		    rac_instance_number  => null
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
                select trunc(LAST_ARCHIVE_TS), (select trunc(systimestamp - ${AUD_ARCHIVE}) from dual) AS "TARGET DATE" from DBA_AUDIT_MGMT_LAST_ARCH_TS;
                exit;
EOF
`
        # Test to make sure an ORA- error was not encountered
        export TEST=`grep 'ORA-' /tmp/last_archive_timestmp.txt`
        case $TEST in
          *ORA-*)
            # An ORA- error occurred. Delete file so that the script does not execute
            cat /tmp/last_archive_timestmp.txt >> $AUDM_LOG_FILE
            rm -f /tmp/last_archive_timestmp.txt
        esac
        if [ -f /tmp/last_archive_timestmp.txt ]; then
          cat /tmp/last_archive_timestmp.txt |while read TSTMP; do
  	    LST_AR=`echo $TSTMP |awk '{print $1}'`
            CORRECT_DAY=`echo $TSTMP |awk '{print $2}'`
          done
          rm -f /tmp/last_archive_timestmp.txt
          echo "New LAST_ARCHIVE_TS = $LST_AR" >> $AUDM_LOG_FILE
          echo "Correct timestamp = $CORRECT_DAY" >> $AUDM_LOG_FILE
# ----------------------------------------------------------
# Purge AUD$ of records that are older than ${AUD_ARCHIVE} days.
# ----------------------------------------------------------
          # Verify that the last_archive_time parameter was successfully updated to ${AUD_ARCHIVE} days ago.
          if [ $LST_AR == $CORRECT_DAY ]; then
            echo "The last_archive_time parameter was successfully updated; it is safe to purge." >> $AUDM_LOG_FILE
	    echo " " >> $AUDM_LOG_FILE
	    echo "`date` : Starting the AUD$ purge." >> $AUDM_LOG_FILE
            echo "Purging records that are older than ${AUD_ARCHIVE} days from the AUD$ table.." >> $AUDM_LOG_FILE
            echo " " >> $AUDM_LOG_FILE
            touch /tmp/audit_purge_$DB_NAME.lck
            SQL_OUT=`sqlplus -S /nolog<<EOF >> $AUDM_LOG_FILE
                    connect $SQLUSER
                    set serveroutput on
                    begin
  	              dbms_audit_mgmt.clean_audit_trail(
   		        audit_trail_type        =>  dbms_audit_mgmt.audit_trail_aud_std,
   		        use_last_arch_timestamp => TRUE
  		      );
		    end;
	            /
                    exit;
EOF
`
            echo " " >> $AUDM_LOG_FILE
            echo "Finished the AUD$ Purge for $DB_NAME at `date '+%b %d %Y %H:%M:%S'`" >> $AUDM_LOG_FILE
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
                    select name, (select count(*) from aud\\$ where trunc(NTIMESTAMP#) < trunc(sysdate-${AUD_ARCHIVE})) AS "NEEDING ARCHIVED" from v\\$database;
                    exit;
EOF
`
          else
            # The last_archive_time parameter was not successfully updated; it is not safe to purge.
            ESTAT=1
            echo "CRITICAL: Updating the LAST_ARCHIVE_TIME parameter may have failed. Correct timestamp = $CORRECT_DAY." >> $AUDM_LOG_FILE
            echo "The purge will not execute to avoid purging the entire AUD$ table instead of purging only records that are older than ${AUD_ARCHIVE} days." >> $AUDM_LOG_FILE
          fi
        else
          ESTAT=1
          echo "CRITICAL: Updating the LAST_ARCHIVE_TIME parameter may have failed." >> $AUDM_LOG_FILE
          echo "The purge will not execute to avoid purging the entire AUD$ table instead of purging only records that are older than ${AUD_ARCHIVE} days." >> $AUDM_LOG_FILE 
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
  echo "WARNING: An error occurred accessing the DB or accessing the AUD$ table." >> $AUDM_LOG_FILE
  echo "The archive and purge of the AUD$ table in $DB_NAME did not execute." >> $AUDM_LOG_FILE
fi   
# -----------------------------------------------------------------
# Log the completion of the archive and purge of AUD$.
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
echo ================================================= >> $AUDM_LOG_FILE
echo Return Status for AUD$ Maintenance is: $ESTAT >> $AUDM_LOG_FILE
echo ================================================= >> $AUDM_LOG_FILE
echo " " >> $AUDM_LOG_FILE
echo "The archive and purge of the AUD$ table in $DB_NAME" >> $AUDM_LOG_FILE
echo ==== $LOGMSG on `date` ==== >> $AUDM_LOG_FILE
# ---------------------------------------------------------------------
# Remove records from the archive table that are older than ${ARCHIVE_PURGE} days.
# ---------------------------------------------------------------------
echo " " >> $AUDM_LOG_FILE
echo " " >> $AUDM_LOG_FILE
echo "`date` : Starting the AUDIT_ARCHIVE maintenance." >> $AUDM_LOG_FILE
echo "Removing records that are older than ${ARCHIVE_PURGE} days from the archive table.." >> $AUDM_LOG_FILE
echo " " >> $AUDM_LOG_FILE
SQL_OUT=`sqlplus -S /nolog<<EOF >> $AUDM_LOG_FILE
        connect $SQLUSER
        set echo off
        set pages 0
        select 'Current total # of records in audit_archive: ' || count(*) from audit_archive;
        select 'SQL> delete AUDIT_ARCHIVE where trunc(NTIMESTAMP#) < trunc(sysdate - ${ARCHIVE_PURGE});' from dual;
	delete AUDIT_ARCHIVE where trunc(NTIMESTAMP#) < trunc(sysdate - ${ARCHIVE_PURGE});
        select 'New Total: ' || count(*) from audit_archive;
        commit;
        exit;    
EOF
  ` 
echo " " >> $AUDM_LOG_FILE
echo "Finished the AUDIT_ARCHIVE maintenance for $DB_NAME at `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
#-------------------------------------------------------------------------------------
# Archive/Delete ASM and DB AUDIT_FILE_DEST's OS files that are older than ${MAND_ARCHIVE} days 
# Delete AUD_FILE_DEST archives that are older than ${MAND_PURGE} days
#-------------------------------------------------------------------------------------
echo " " >> $AUDM_LOG_FILE
echo "`date` : Starting the AUDIT_FILE_DEST maintenance." >> $AUDM_LOG_FILE
echo "Archiving records that are older than ${MAND_ARCHIVE} days from the AUDIT_FILE_DEST to $ZIP_LOC and deleting AUDIT_FILE_DEST archives that are older than ${MAND_PURGE} days.." >> $AUDM_LOG_FILE
echo " " >> $AUDM_LOG_FILE
# Clean up the DB audit_file_dest files
SQL_OUT=`sqlplus -S /nolog<<EOF 
         connect $SQLUSER
	 spool /tmp/audfiledest.txt
         set pages 0
	 select value from v\\$parameter where name='audit_file_dest';
         exit;
EOF
`     
# Test to make sure an ORA- error was not encountered
export TEST=`grep 'ORA-' /tmp/audfiledest.txt`
case $TEST in
  *ORA-*)
    # An ORA- error occurred. Delete file
    rm -f /tmp/audfiledest.txt
esac
if [ -f /tmp/audfiledest.txt ]; then
  AUD_DEST=`cat /tmp/audfiledest.txt | sed 's/^[ \t]*//;s/[ \t]*$//'`
  rm -f /tmp/audfiledest.txt
  find ${AUD_DEST} -name "*.aud" -type f -mtime +${MAND_ARCHIVE} -exec $ORACLE_HOME/bin/zip -mT $ZIP_LOC/db_aud_file_dest1_$DTMASK.zip {} \;
fi
if [ -f $ZIP_LOC/db_aud_file_dest1_$DTMASK.zip ]; then
  echo "$AUD_DEST archive on node 1 was succesful." >> $AUDM_LOG_FILE
else
  echo "WARNING: $AUD_DEST archive on $NODE1 may have failed." >> $AUDM_LOG_FILE
  echo " " >> $AUDM_LOG_FILE
fi
# Clean up the ASM audit_file_dest files
export ORACLE_SID=+ASM
. /usr/local/bin/oraenv
SQL_OUT=`sqlplus -S /nolog<<EOF 
         connect $SQLUSER
	 spool /tmp/asmfiledest.txt
         set pages 0
	 select value from v\\$parameter where name='audit_file_dest';
         exit;
EOF
`     
# Test to make sure an ORA- error was not encountered
export TEST=`grep 'ORA-' /tmp/asmfiledest.txt`
case $TEST in
  *ORA-*)
    # An ORA- error occurred. Delete file
    rm -f /tmp/asmfiledest.txt
esac
if [ -f /tmp/asmfiledest.txt ]; then
# this way removes trailing "t"  ASM_DEST=`cat /tmp/asmfiledest.txt | sed 's/^[ \t]*//;s/[ \t]*$//'`  
  ASM_DEST=`cat /tmp/asmfiledest.txt |sed 's/^ *//;s/ *$//;s/  */ /;'`
  rm -f /tmp/asmfiledest.txt
  find ${ASM_DEST} -name "*.aud" -type f -mtime +${MAND_ARCHIVE} -exec $ORACLE_HOME/bin/zip -mT $ZIP_LOC/asm_aud_file_dest1_$DTMASK.zip {} \;
fi
if [ -f $ZIP_LOC/asm_aud_file_dest1_$DTMASK.zip ]; then
  echo "$ASM_DEST archive on node 1 was succesful." >> $AUDM_LOG_FILE
else
  echo "WARNING: $ASM_DEST archive on $NODE1 may have failed." >> $AUDM_LOG_FILE
  echo " " >> $AUDM_LOG_FILE
fi
# Determine if other nodes exist; their AUDIT_FILE_DEST's will need maintenance also
NUMNODES=`/u01/112/grid/bin/olsnodes | wc -l`
if [ $NUMNODES -eq 2 ]; then
# Perform the same DB and ASM audit_file_dest maintenance on node 2 
  /u01/112/grid/bin/olsnodes > /tmp/nodelist.txt
  cat /tmp/nodelist.txt | tail -n 1 | while read NLST; do
    NODE2=`echo $NLST |awk '{print $1}'`
  done
  cat /tmp/nodelist.txt | head -n 1 | while read NLST; do
    NODE1=`echo $NLST |awk '{print $1}'`
  done
  rm -f /tmp/nodelist.txt
  ssh oracle@$NODE2 "
    find ${AUD_DEST} -name "*.aud" -type f -mtime +${MAND_ARCHIVE} -exec $ORACLE_HOME/bin/zip -mT $AUD_DEST/db_aud_file_dest2_$DTMASK.zip {} \;
    find ${ASM_DEST} -name "*.aud" -type f -mtime +${MAND_ARCHIVE} -exec $ORACLE_HOME/bin/zip -mT $ASM_DEST/asm_aud_file_dest2_$DTMASK.zip {} \;
    scp $AUD_DEST/db_aud_file_dest2_$DTMASK.zip oracle@${NODE1}:$ZIP_LOC/.
    scp $ASM_DEST/asm_aud_file_dest2_$DTMASK.zip oracle@${NODE1}:$ZIP_LOC/.
"
  if [ -f $ZIP_LOC/db_aud_file_dest2_$DTMASK.zip ]; then
    echo "$AUD_DEST archive on node 2 was succesful." >> $AUDM_LOG_FILE
    ssh oracle@$NODE2 "
      rm -f $AUD_DEST/db_aud_file_dest2_$DTMASK.zip
"
  else
    echo "WARNING: $AUD_DEST archive on $NODE2 may have failed or was not needed." >> $AUDM_LOG_FILE
    echo " " >> $AUDM_LOG_FILE
  fi
  if [ -f $ZIP_LOC/asm_aud_file_dest2_$DTMASK.zip ]; then
    echo "$ASM_DEST archive on node 2 was succesful." >> $AUDM_LOG_FILE
    ssh oracle@$NODE2 "
    rm -f $ASM_DEST/asm_aud_file_dest2_$DTMASK.zip
"
  else
    echo "WARNING: $ASM_DEST archive on $NODE2 may have failed or was not needed." >> $AUDM_LOG_FILE
    echo " " >> $AUDM_LOG_FILE
  fi
fi
# Delete archives older than ${MAND_PURGE} days old
find $ZIP_LOC -name "*.zip" -type f -mtime +${MAND_PURGE} -exec rm -f {} \;
echo "AUDIT_FILE_DEST archives older than ${MAND_PURGE} days old were deleted." >> $AUDM_LOG_FILE
echo " " >> $AUDM_LOG_FILE
echo "Finished the AUDIT_FILE_DEST maintenance for $DB_NAME at `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
echo "The most recent AUDIT_FILE_DEST archives: " >> $AUDM_LOG_FILE
ls -ltr $ZIP_LOC | tail -5 >> $AUDM_LOG_FILE
# -----------------------------------------------------------------
# Email script status to DBAs.
# -----------------------------------------------------------------
if [ "$ESTAT" = 0 ]
then
  mail -s "${DB_NAME}: AUD$ ARCHIVE & PURGE COMPLETE" ${MAILTO} < $AUDM_LOG_FILE
elif [ "$ESTAT" = 2 ]
then 
  mail -s "${DB_NAME}: AUD$ did not need an archive or purge on `date '+%b %d %Y'`." ${MAILTO} < $AUDM_LOG_FILE
else
  mail -s "${DB_NAME}: AUD$ ARCHIVE & PURGE ERROR" ${MAILTO} < $AUDM_LOG_FILE
fi
#----------------------------------------------------------------------
# Remove cycled logs older than 30 days
#----------------------------------------------------------------------   
find $LOG_LOC -name "${DB_NAME}_audit_tr_maintenance*.log" -mtime +30 -exec rm -rf {} \;
export ORAENV_ASK=YES;
set +x
exit 
