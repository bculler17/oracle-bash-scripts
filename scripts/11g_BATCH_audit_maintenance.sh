#!/bin/sh
#
# ----------------------------------------------------------------------------------------------------------------------------------
# This script performs Audit Trail maintenance for an 11g database when the AUD$ table has grown very large.
# Running this script first purges everything older than 18 months from AUD$ in small batches.
# It will then archive and purge audit records from aud$ that are older than 45 days in small batches, and purge archived records that are older than 18 months from the archive table. 
# After this script brings the audit trail up to standards (records older than 45 days are archived, records older than 18 months are deleted), please schedule Script audit_tr_maintenance_11g.sh to run daily to keep the audit trail up to standard. 
#
# Author: Beth Culler
# Created: 4/23/2021
# ----------------------------------------------------------------------------------------------------------------------------------
# turn on debug by uncommenting below line.
# -----------------------------------------------------------------
#set -x
# -----------------------------------------------------------------
# Set Local Variables.
# -----------------------------------------------------------------
MAILTO=<ENTER EMAIL ADDRESS>
DATE_TIME_FM=`date +%Y%m%d_%H%M%S`
SQLUSER="<username/password>"                      # User used to log into database
LOG_LOC=<ENTER LOG DIRECTORY>
CONT_PURGE=0
CONT_BATCH=0 
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
echo "Details of this session can be found in $AUDM_LOG_FILE.."
# -----------------------------------------------------------------
# Log the start of this script.
# -----------------------------------------------------------------
echo Script $0 >> $AUDM_LOG_FILE
echo ==== started on `date` ==== >> $AUDM_LOG_FILE
echo "Purpose: To be executed when the AUD$ table is very large; to purge records that are older than 18 months from the AUD$ table if any exist, and to archive and purge audit records that are between 18 months and 45 days old in smaller, more manageable batches from the AUD$ table in $DB_NAME." >> $AUDM_LOG_FILE
echo " " >> $AUDM_LOG_FILE
# -----------------------------------------------------------------
# Check if a previous purge is still executing.
# -----------------------------------------------------------------
if [ -f /tmp/audit_purge_$DB_NAME.lck ]; then
  echo "* * * `date` * * *"  >> $AUDM_LOG_FILE
  echo "$0 : CANNOT EXECUTE." >> $AUDM_LOG_FILE
  echo "A previous purge of the AUD$ table in $DB_NAME is still running. Cannot start a new purge." >> $AUDM_LOG_FILE
  mail -s "${DB_NAME}: AUD$ PURGE IS STILL RUNNING" ${MAILTO} 
exit
fi
# ---------------------------------------------------------------------------------------
# Determine how many records in aud$ are older than 18 months 
# Will need to purge these first to avoid archiving and then immediately deleting them
# ---------------------------------------------------------------------------------------
SQL_OUT=`sqlplus -S /nolog<<EOF 
        connect $SQLUSER
	set feedback off
        set echo off
        set pages 0
        spool /tmp/expiredrecs.txt 
        select count(*) from aud\\$ where trunc(NTIMESTAMP#) < trunc(sysdate-548);
	exit;
EOF
`
# Test to make sure an ORA- error was not encountered
export TEST=`grep 'ORA-' /tmp/expiredrecs.txt`
case $TEST in
  *ORA-*)
    # An ORA- error occurred. Delete file so that the script does not execute
    cat /tmp/expiredrecs.txt >> $AUDM_LOG_FILE
    rm -f /tmp/expiredrecs.txt
esac
if [ -f /tmp/expiredrecs.txt ]; then
  cat /tmp/expiredrecs.txt |while read NUM; do
    UNNEEDED=`echo $NUM |awk '{print $1}'`
  done
  rm -f /tmp/expiredrecs.txt
  if [ $UNNEEDED -gt 0 ]; then
    echo "There are $UNNEEDED audit records in AUD$ that are older than 18 months. These records do not need to be archived before being purged." >> $AUDM_LOG_FILE
    while [ $CONT_PURGE -eq 0 ]; do
      echo "Beginning to purge these $UNNEEDED records before beginning the archive of AUD$.." >> $AUDM_LOG_FILE
      echo " " >> $AUDM_LOG_FILE
      SQL_OUT=`sqlplus -S /nolog<<EOF 
          connect $SQLUSER
          alter session set NLS_DATE_FORMAT='DD-MON-YYYY_HH24:MI:SS';
	  set feedback off
          set echo off
          set pages 0
          spool /tmp/purgetest.txt 
          with mdte as
            (select trunc(min(NTIMESTAMP#)) AS "MIN_DATE" from aud\\$)
          select CASE WHEN (b.MIN_DATE < trunc(sysdate-593)) 
                 THEN 'BATCH'
                 ELSE 'WHOLE' END
          from mdte b;
          exit;
EOF
`   
      # Test to make sure an ORA- error was not encountered
      export TEST=`grep 'ORA-' /tmp/purgetest.txt`
      case $TEST in
        *ORA-*)
          # An ORA- error occurred. Delete file so that the script does not execute
          cat /tmp/purgetest.txt >> $AUDM_LOG_FILE
          rm -f /tmp/purgetest.txt
      esac
      if [ -f /tmp/purgetest.txt ]; then
        cat /tmp/purgetest.txt |while read BTST; do
          BTYPE=`echo $BTST |awk '{print $1}'`
        done
        rm -f /tmp/purgetest.txt
      else
        echo "WARNING: An error occurred while determining how to reset the last archive time parameter." >> $AUDM_LOG_FILE
        echo " " >> $AUDM_LOG_FILE
        echo "Script $0 ended on `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
        mail -s "${DB_NAME}: AUD$ ARCHIVE & PURGE ERROR: DID NOT EXECUTE" ${MAILTO} < $AUDM_LOG_FILE
        exit
      fi
      # Set last archive timestamp
      echo "`date` : Updating the last_archive_time parameter.." >> $AUDM_LOG_FILE
      if [ $BTYPE == "BATCH" ]; then
        SQL_OUT=`sqlplus -S /nolog<<EOF >> $AUDM_LOG_FILE
                connect $SQLUSER
                set serveroutput on
                declare
                  c_ardate aud\\$.NTIMESTAMP#%TYPE;
                begin
                  select trunc(min(NTIMESTAMP#)) + (round((trunc(sysdate - 548) - trunc(min(NTIMESTAMP#)))/2)) INTO c_ardate 
                  from aud\\$;
                  dbms_audit_mgmt.set_last_archive_timestamp(
     	       	    audit_trail_type  => dbms_audit_mgmt.audit_trail_aud_std,
		    last_archive_time => c_ardate,
		    rac_instance_number  => null
                  );
	        end;
                /
                exit;
EOF
`
      elif [  $BTYPE == "WHOLE" ]; then
        SQL_OUT=`sqlplus -S /nolog<<EOF >> $AUDM_LOG_FILE
                connect $SQLUSER
                set serveroutput on
                declare
                  c_ardate aud\\$.NTIMESTAMP#%TYPE;
                begin
                  select trunc(min(NTIMESTAMP#)) + (trunc(sysdate - 548) - trunc(min(NTIMESTAMP#))) INTO c_ardate
                  from aud\\$;
                  dbms_audit_mgmt.set_last_archive_timestamp(
                    audit_trail_type  => dbms_audit_mgmt.audit_trail_aud_std,
                    last_archive_time => c_ardate,
                    rac_instance_number  => null
                  );
                end;
                /
                exit;
EOF
`
      else
        echo "WARNING: An error occurred while determining how to set the last archive time parameter." >> $AUDM_LOG_FILE
        echo " " >> $AUDM_LOG_FILE
        echo "Script $0 ended on `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
        mail -s "${DB_NAME}: AUD$ ARCHIVE & PURGE ERROR: DID NOT EXECUTE" ${MAILTO} < $AUDM_LOG_FILE
        exit
      fi
      # Determine if the last_archive_time was set correctly (correctly = to a date later than 18 months ago, NOT earlier than 18 months)
      SQL_OUT=`sqlplus -S /nolog<<EOF
              connect $SQLUSER
              alter session set NLS_DATE_FORMAT='DD-MON-YYYY_HH24:MI:SS';
              set feedback off
              set echo off
              set pages 0
              spool /tmp/archive_timestmp.txt
              select trunc(LAST_ARCHIVE_TS), (select trunc(sysdate - 548) from dual) AS "DATE TO AVOID" from DBA_AUDIT_MGMT_LAST_ARCH_TS;
              exit;
EOF
`
      # Test to make sure an ORA- error was not encountered
      export TEST=`grep 'ORA-' /tmp/archive_timestmp.txt`
      case $TEST in
        *ORA-*)
          # An ORA- error occurred. Delete file so that the script does not execute
          cat /tmp/archive_timestmp.txt >> $AUDM_LOG_FILE
          rm -f /tmp/archive_timestmp.txt
      esac
      if [ -f /tmp/archive_timestmp.txt ]; then
        cat /tmp/archive_timestmp.txt |while read TSTMP; do
          LST_AR=`echo $TSTMP |awk '{print $1}'`
          INCORRECT_DAY=`echo $TSTMP |awk '{print $2}'`
        done
        rm -f /tmp/archive_timestmp.txt
        echo "New LAST_ARCHIVE_TS = $LST_AR" >> $AUDM_LOG_FILE
        echo "The date 18 months ago = $INCORRECT_DAY" >> $AUDM_LOG_FILE
        # Verify that the last_archive_time parameter is not set to a date earlier than 18 months ago.
        SQL_OUT=`sqlplus -S /nolog<<EOF 
                connect $SQLUSER
                alter session set NLS_DATE_FORMAT='DD-MON-YYYY_HH24:MI:SS';
                set feedback off
                set echo off
                set pages 0
                spool /tmp/testtime.txt 
                with atst as
                  (select trunc(LAST_ARCHIVE_TS) AS "ARCHIVE_TIME" from DBA_AUDIT_MGMT_LAST_ARCH_TS)
                select CASE WHEN b.ARCHIVE_TIME > trunc(sysdate-548) 
                       THEN 'DANGER'
                       ELSE 'SAFE' END
                from atst b;
                exit;
EOF
`   
        if [ -f /tmp/testtime.txt ]; then
          cat /tmp/testtime.txt |while read ATST; do
            SAFEGRD=`echo $ATST |awk '{print $1}'`
          done
          if [ $SAFEGRD == "SAFE" ]; then
            echo "The last_archive_time parameter was successfully updated; it is safe to purge." >> $AUDM_LOG_FILE
            echo " " >> $AUDM_LOG_FILE
            echo "`date` : Starting the AUD$ purge." >> $AUDM_LOG_FILE
            echo "Purging records that are older than 18 months from the AUD$ table, starting from $LST_AR.." >> $AUDM_LOG_FILE
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
            echo "The purge of expired audit records older than $LST_AR completed on `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
            rm -f /tmp/audit_purge_$DB_NAME.lck
            # Checking to see how many more records that are older than 18 months may still exist..
            SQL_OUT=`sqlplus -S /nolog<<EOF 
                    connect $SQLUSER
	            set feedback off
                    set echo off
                    set pages 0
                    spool /tmp/stillexpired.txt 
                    select count(*) from aud\\$ where trunc(NTIMESTAMP#) < trunc(sysdate - 548);
                    exit;
EOF
`
            # Test to make sure an ORA- error was not encountered
            export TEST=`grep 'ORA-' /tmp/stillexpired.txt`
            case $TEST in
              *ORA-*)
              # An ORA- error occurred. Delete file so that the script does not execute
              cat /tmp/stillexpired.txt >> $AUDM_LOG_FILE
              rm -f /tmp/stillexpired.txt
            esac
            if [ -f /tmp/stillexpired.txt ]; then
              cat /tmp/stillexpired.txt |while read NUM2; do
                UNNEEDED=`echo $NUM2 |awk '{print $1}'`
              done
              rm -f /tmp/stillexpired.txt
	      echo "There are now $UNNEEDED audit records in AUD$ that are older than 18 months." >> $AUDM_LOG_FILE
              echo " " >> $AUDM_LOG_FILE
              if [ $UNNEEDED -gt 0 ]; then
                echo "---------------------------------------------------------------------------" >> $AUDM_LOG_FILE
                echo "Waiting for an answer from the user to determine if Script $0 should continue purging the remaining outdated AUD$ records, or terminate to resume at a later time.... " >>$AUDM_LOG_FILE
                echo " " >> $AUDM_LOG_FILE
#                mail -s "${DB_NAME}: AUD$ PURGE OF EXPIRED AUDIT RECORDS NEEDS A RESPONSE" ${MAILTO} < $AUDM_LOG_FILE
                echo "There are still $UNNEEDED audit records in AUD$ that are older than 18 months. Do you want to continue purging? Choose yes to continue. Choose no to exit. (yes/no)"
                read input
                if [ $input != "yes" ]; then
                  echo "User has chosen to terminate script. Purging the remaining $UNNEEDED records will need to be done at a later time." >> $AUDM_LOG_FILE
                  echo "---------------------------------------------------------------------------" >> $AUDM_LOG_FILE
                  echo " " >> $AUDM_LOG_FILE
                  echo "Script $0 ended on `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
                  echo "Thank you. Script $0 has been terminated on `date '+%b %d %Y %H:%M:%S'`."  
                  exit
                else
                  echo "Thank you. Resuming the purge now.." 
                  echo "User has chosen to continue." >> $AUDM_LOG_FILE
                  echo "---------------------------------------------------------------------------" >> $AUDM_LOG_FILE
                  echo " " >> $AUDM_LOG_FILE
                fi
              else
                CONT_PURGE=1     
              fi
            else
              echo "WARNING: An error occurred accessing the DB or accessing the AUD$ table to count how many more records are older than 18 months in the AUD$ table." >> $AUDM_LOG_FILE
              echo " " >> $AUDM_LOG_FILE
              echo "Script $0 ended on `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
              mail -s "${DB_NAME}: SCRIPT $0 TERMINATED BEFORE COMPLETION" ${MAILTO} < $AUDM_LOG_FILE
              exit
            fi
          elif [ $SAFEGRD == "DANGER" ]; then
            # The last_archive_time parameter was not successfully updated; it is not safe to purge.
            echo "CRITICAL: Updating the LAST_ARCHIVE_TIME parameter may have failed. The timestamp cannot be > than $INCORRECT_DAY." >> $AUDM_LOG_FILE
            echo "The purge will not execute to avoid purging records that may first need to be archived before being purged." >> $AUDM_LOG_FILE
            echo " " >> $AUDM_LOG_FILE
            echo "Script $0 will need to be restarted." >> $AUDM_LOG_FILE
            echo " " >> $AUDM_LOG_FILE
            echo "Script $0 ended on `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
            mail -s "${DB_NAME}: AUD$ ARCHIVE & PURGE ERROR: DID NOT EXECUTE" ${MAILTO} < $AUDM_LOG_FILE
            exit
          else
            cat /tmp/testtime.txt >> $AUDM_LOG_FILE 
            echo "CRITICAL: Could not determine if the LAST_ARCHIVE_TS was reset correctly." >> $AUDM_LOG_FILE
            echo "The purge will not execute to avoid purging records that may first need to be archived before being purged." >> $AUDM_LOG_FILE
            echo " " >> $AUDM_LOG_FILE
            echo "Script $0 will need to be restarted." >> $AUDM_LOG_FILE
            echo " " >> $AUDM_LOG_FILE
            echo "Script $0 ended on `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
            mail -s "${DB_NAME}: AUD$ ARCHIVE & PURGE ERROR: DID NOT EXECUTE" ${MAILTO} < $AUDM_LOG_FILE
            rm -f /tmp/testtime.txt 
            exit
          fi
          rm -f /tmp/testtime.txt
        else
          echo "CRITICAL: Could not determine if the LAST_ARCHIVE_TS was reset correctly." >> $AUDM_LOG_FILE
          echo "The purge will not execute to avoid purging records that may first need to be archived before being purged." >> $AUDM_LOG_FILE
          echo " " >> $AUDM_LOG_FILE
          echo "Script $0 will need to be restarted." >> $AUDM_LOG_FILE
          echo " " >> $AUDM_LOG_FILE
          echo "Script $0 ended on `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
          mail -s "${DB_NAME}: AUD$ ARCHIVE & PURGE ERROR: DID NOT EXECUTE" ${MAILTO} < $AUDM_LOG_FILE
          exit
        fi
      else
        echo "CRITICAL: Could not determine the LAST_ARCHIVE_TS." >> $AUDM_LOG_FILE
        echo "The purge will not execute to avoid purging records that may first need to be archived before being purged." >> $AUDM_LOG_FILE
        echo " " >> $AUDM_LOG_FILE 
        echo "Script $0 will need to be restarted." >> $AUDM_LOG_FILE
        echo " " >> $AUDM_LOG_FILE
        echo "Script $0 ended on `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
        mail -s "${DB_NAME}: AUD$ ARCHIVE & PURGE ERROR: DID NOT EXECUTE" ${MAILTO} < $AUDM_LOG_FILE
        exit
      fi
    done
  else
    echo "`date` : There are $UNNEEDED records in AUD$ that are older than 18 months." >> $AUDM_LOG_FILE  
    echo " " >> $AUDM_LOG_FILE
  fi
else
  echo "WARNING: An error occurred accessing the DB or accessing the AUD$ table." >> $AUDM_LOG_FILE
  echo " " >> $AUDM_LOG_FILE
  echo "Script $0 ended on `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
  mail -s "${DB_NAME}: AUD$ ARCHIVE & PURGE ERROR: DID NOT EXECUTE" ${MAILTO} < $AUDM_LOG_FILE
  exit
fi
# ---------------------------------------------------------------------------------------------------------
# Start archiving and purging the remaining records in AUD$ that are between 18 months old - 46 days old.
# This will be done in batches according to the "batch date."
# ---------------------------------------------------------------------------------------------------------
# Verify that AUD$ contains records older than 45 days before executing script
SQL_OUT=`sqlplus -S /nolog<<EOF 
        connect $SQLUSER
        alter session set NLS_DATE_FORMAT='DD-MON-YYYY_HH24:MI:SS';
        set feedback off
        set echo off
        set pages 0
        spool /tmp/datetest.txt 
        with mdte as
          (select trunc(min(NTIMESTAMP#)) AS "MIN_DATE" from aud\\$)
        select CASE WHEN (b.MIN_DATE > trunc(sysdate-45)) 
               THEN 'DANGER'
               ELSE 'SAFE' END
        from mdte b;
        exit;
EOF
`   
# Test to make sure an ORA- error was not encountered
export TEST=`grep 'ORA-' /tmp/datetest.txt`
case $TEST in
  *ORA-*)
    # An ORA- error occurred. Delete file so that the script does not execute
    cat /tmp/datetest.txt >> $AUDM_LOG_FILE
    rm -f /tmp/datetest.txt
esac
if [ -f /tmp/datetest.txt ]; then
  cat /tmp/datetest.txt |while read TST; do
    SAFEGUARD=`echo $TST |awk '{print $1}'`
  done
else
  echo "ALERT: Possibly could not access the DB or AUD$ table to count the number of records in AUD$ that are older than 45 days:" >> $AUDM_LOG_FILE
  echo "Script $0 cannot execute." >> $AUDM_LOG_FILE
  echo " " >> $AUDM_LOG_FILE
  echo "Script $0 ended on `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
  mail -s "${DB_NAME}: AUD$ ARCHIVE & PURGE ERROR: DID NOT EXECUTE" ${MAILTO} < $AUDM_LOG_FILE
  exit
fi
if [ $SAFEGUARD == "DANGER" ]; then
  echo "ALERT: There are 0 records in AUD$ that are older than 45 days." >> $AUDM_LOG_FILE
  echo "Script $0 cannot execute." >> $AUDM_LOG_FILE
  echo " " >> $AUDM_LOG_FILE
  echo "Please schedule Script /homes/oracle/chsdba/common/audit_tr_maintenance_11g.sh to run daily to keep the audit trail maintained up to CHS standards." >> $AUDM_LOG_FILE 
  echo " " >> $AUDM_LOG_FILE
  echo "Script $0 ended on `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
  exit
elif [ $SAFEGUARD != "SAFE" ]; then
  echo "ALERT: Possibly could not access the DB or AUD$ table to count the number of records in AUD$ that are older than 45 days:" >> $AUDM_LOG_FILE
  cat /tmp/datetest.txt >> $AUDM_LOG_FILE
  echo "Script $0 cannot execute." >> $AUDM_LOG_FILE
  echo " " >> $AUDM_LOG_FILE
  echo "Script $0 ended on `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
  mail -s "${DB_NAME}: AUD$ ARCHIVE & PURGE ERROR: DID NOT EXECUTE" ${MAILTO} < $AUDM_LOG_FILE
  exit
fi                   
rm -f /tmp/datetest.txt
# ---------------------------------------------------------------------------------------------------------
# Determine the batch date.
# ----------------------------------------------------------------------------------------------------------
while [ $CONT_BATCH -eq 0 ]; do
  SQL_OUT=`sqlplus -S /nolog<<EOF
          connect $SQLUSER
          alter session set NLS_DATE_FORMAT='DD-MON-YYYY_HH24:MI:SS';
          set feedback off
          set echo off
          set pages 0
          spool /tmp/purgetest.txt
          with mdte as
            (select trunc(min(NTIMESTAMP#)) AS "MIN_DATE" from aud\\$)
          select CASE WHEN (b.MIN_DATE < trunc(sysdate-90))
                 THEN 'BATCH'
                 ELSE 'WHOLE' END
          from mdte b;
          exit;
EOF
`
  # Test to make sure an ORA- error was not encountered
  export TEST=`grep 'ORA-' /tmp/purgetest.txt`
  case $TEST in
    *ORA-*)
      # An ORA- error occurred. Delete file so that the script does not execute
      cat /tmp/purgetest.txt >> $AUDM_LOG_FILE
      rm -f /tmp/purgetest.txt
  esac
  if [ -f /tmp/purgetest.txt ]; then
    cat /tmp/purgetest.txt |while read BTST; do
      BTYPE=`echo $BTST |awk '{print $1}'`
    done
    rm -f /tmp/purgetest.txt
  else
    echo "WARNING: An error occurred while determining how to reset the last archive time parameter." >> $AUDM_LOG_FILE
    echo " " >> $AUDM_LOG_FILE
    echo "Script $0 ended on `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
    mail -s "${DB_NAME}: AUD$ ARCHIVE & PURGE ERROR: DID NOT EXECUTE" ${MAILTO} < $AUDM_LOG_FILE
    exit
  fi
  if [ $BTYPE == "BATCH" ]; then
    SQL_OUT=`sqlplus -S /nolog<<EOF 
            connect $SQLUSER
            alter session set NLS_DATE_FORMAT='DD-MON-YYYY_HH24:MI:SS';
            set feedback off
            set echo off
            set pages 0
            spool /tmp/batchdate.txt 
            select trunc(min(NTIMESTAMP#)) + round((trunc(sysdate-45) - trunc(min(NTIMESTAMP#)))/2) from aud\\$;
            exit;
EOF
`
    # Test to make sure an ORA- error was not encountered
    export TEST=`grep 'ORA-' /tmp/batchdate.txt`
    case $TEST in
      *ORA-*)
        # An ORA- error occurred. Delete file so that the script does not execute
        cat /tmp/batchdate.txt >> $AUDM_LOG_FILE
        rm -f /tmp/batchdate.txt
    esac
    if [ -f /tmp/batchdate.txt ]; then
      cat /tmp/batchdate.txt |while read MDT; do
        BATCH_DATE=`echo $MDT |awk '{print $1}'`
      done
      rm -f /tmp/batchdate.txt
    fi
# ------------------------------------------------------------------
# Determine the number of records that need to be archived.
# ------------------------------------------------------------------
    echo "`date` : Starting the AUD$ archive." >> $AUDM_LOG_FILE
    echo "Records older than $BATCH_DATE will be archived and purged this batch.." >> $AUDM_LOG_FILE
    echo " " >> $AUDM_LOG_FILE
    echo "DATABASE   AUD$ TOTAL:  #<45DAYS:   # TO BE ARCHIVED/PURGED THIS BATCH:" >> $AUDM_LOG_FILE
    echo "========   ===========  =========   ===================================" >> $AUDM_LOG_FILE
    SQL_OUT=`sqlplus -S /nolog<<EOF
            connect $SQLUSER
            set feedback off
            set echo off
            set pages 0
            spool /tmp/total.txt
            with batchdte as
              (select trunc(min(NTIMESTAMP#)) + round((trunc(sysdate-45) - trunc(min(NTIMESTAMP#)))/2) AS "BATCH_DTE" from aud\\$)
            select name, (select count(*) from aud\\$) AS "TOTAL", (select count(*) from aud\\$ where trunc(NTIMESTAMP#) < trunc(sysdate-45)) AS "# > 45 DAYS", (select count(*) from aud\\$, batchdte b where trunc(NTIMESTAMP#) < b.BATCH_DTE) AS "# THIS BATCH" from v\\$database;
            exit;
EOF
`
    # Test to make sure an ORA- error was not encountered
    export TEST=`grep 'ORA-' /tmp/total.txt`
    case $TEST in
      *ORA-*)
        # An ORA- error occurred. Delete file so that the script does not execute
        cat /tmp/total.txt >> $AUDM_LOG_FILE
        rm -f /tmp/total.txt
    esac
    if [ -f /tmp/total.txt ]; then
      cat /tmp/total.txt >> $AUDM_LOG_FILE
      echo " " >> $AUDM_LOG_FILE
      cat /tmp/total.txt |while read NUM; do
        TO_ARCHIVE=`echo $NUM |awk '{print $4}'`
      done
      rm -f /tmp/total.txt
# ----------------------------------------------------------------------------
# Archive AUD$ records.
# ----------------------------------------------------------------------------
      echo "SQL> insert into AUDIT_ARCHIVE (select * from aud$ where trunc(NTIMESTAMP#) < ${BATCH_DATE});" >> $AUDM_LOG_FILE
      SQL_OUT=`sqlplus -S /nolog<<EOF
              connect $SQLUSER
              set echo off
              spool /tmp/archive.txt
              insert into AUDIT_ARCHIVE (select * from aud\\$ where trunc(NTIMESTAMP#) < (select trunc(min(NTIMESTAMP#)) + round((trunc(sysdate-45) - trunc(min(NTIMESTAMP#)))/2) from aud\\$));
              exit;
EOF
`
      # Test to make sure an ORA- error was not encountered
      export TEST=`grep 'ORA-' /tmp/archive.txt`
      case $TEST in
        *ORA-*)
        # An ORA- error occurred. Delete file so that the script does not execute
        cat /tmp/archive.txt >> $AUDM_LOG_FILE
        rm -f /tmp/archive.txt
      esac
      if [ -f /tmp/archive.txt ]; then
        cat /tmp/archive.txt >> $AUDM_LOG_FILE
        echo "Finished the AUD$ Archive for $DB_NAME at `date '+%b %d %Y %H:%M:%S'`" >> $AUDM_LOG_FILE
        cat /tmp/archive.txt |sed '/^$/d' |while read ARSTATS; do
          NUM_ARCHIVED=`echo $ARSTATS |awk '{print $1}'`
        done
        rm -f /tmp/archive.txt
        echo "$NUM_ARCHIVED records were archived from AUD$ into AUDIT_ARCHIVE." >> $AUDM_LOG_FILE
        echo " " >> $AUDM_LOG_FILE
# ----------------------------------------------------------
# Update the LAST_ARCHIVE_TIME parameter.
# ----------------------------------------------------------
        # Make sure the number of records that were archived match the number of records that needed to be archived before moving forward with the purge
        # This will avoid purging records that were not successfully archived
        if [ $NUM_ARCHIVED -eq $TO_ARCHIVE ]; then
          # Number of records archived equals the number of records that needed to be archived, so continue with the purge..
          # Update the last_archive_time parameter
          echo "`date` : Updating the last_archive_time parameter.." >> $AUDM_LOG_FILE
          SQL_OUT=`sqlplus -S /nolog<<EOF >> $AUDM_LOG_FILE
                  connect $SQLUSER
                  alter session set NLS_DATE_FORMAT='DD-MON-YYYY HH24:MI:SS';
                  set serveroutput on
                  declare
                    c_ardate aud\\$.NTIMESTAMP#%TYPE;
                  begin
                    select trunc(min(NTIMESTAMP#)) + (round((trunc(sysdate-45) - trunc(min(NTIMESTAMP#)))/2)) INTO c_ardate
                    from aud\\$;
                    dbms_audit_mgmt.set_last_archive_timestamp(
                      audit_trail_type  => dbms_audit_mgmt.audit_trail_aud_std,
                      last_archive_time => c_ardate,
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
                  select trunc(LAST_ARCHIVE_TS) from DBA_AUDIT_MGMT_LAST_ARCH_TS;
                  exit;
EOF
`
          if [ -f /tmp/last_archive_timestmp.txt ]; then
            cat /tmp/last_archive_timestmp.txt |while read TSTMP; do
              LST_AR=`echo $TSTMP |awk '{print $1}'`
            done
            rm -f /tmp/last_archive_timestmp.txt
            echo "New LAST_ARCHIVE_TS = $LST_AR" >> $AUDM_LOG_FILE
            echo "Correct timestamp = $BATCH_DATE" >> $AUDM_LOG_FILE
          fi
        else
          echo "WARNING: Archive possibly failed! Or completed in error: the number of records that were archived may not match the number of records that are older than 45 days." >> $AUDM_LOG_FILE
          echo "The purge will not execute to avoid possibly deleting records that may have not been archived." >> $AUDM_LOG_FILE
          echo " " >> $AUDM_LOG_FILE
          echo "Script $0 ended on `date '+%b %d %Y %H:%M:%S'`." >>  $AUDM_LOG_FILE
          mail -s "${DB_NAME}: AUD$ ARCHIVE ERROR: PURGE DID NOT EXECUTE" ${MAILTO} < $AUDM_LOG_FILE
          exit
        fi
      else
        echo "WARNING: Archive possibly failed!" >> $AUDM_LOG_FILE
        echo "The purge will not execute to avoid possibly deleting records that may have not been archived." >> $AUDM_LOG_FILE
        echo " " >> $AUDM_LOG_FILE
        echo "Script $0 ended on `date '+%b %d %Y %H:%M:%S'`." >>  $AUDM_LOG_FILE
        mail -s "${DB_NAME}: AUD$ ARCHIVE ERROR: PURGE DID NOT EXECUTE" ${MAILTO} < $AUDM_LOG_FILE
        exit
      fi
    else
      echo "WARNING: An error occurred accessing the DB or accessing the AUD$ table." >> $AUDM_LOG_FILE
      echo " " >> $AUDM_LOG_FILE
      echo "Script $0 ended on `date '+%b %d %Y %H:%M:%S'`." >>  $AUDM_LOG_FILE
      mail -s "${DB_NAME}: AUD$ ARCHIVE & PURGE ERROR: DID NOT EXECUTE" ${MAILTO} < $AUDM_LOG_FILE
      exit
    fi
  elif [  $BTYPE == "WHOLE" ]; then
    SQL_OUT=`sqlplus -S /nolog<<EOF
            connect $SQLUSER
            alter session set NLS_DATE_FORMAT='DD-MON-YYYY_HH24:MI:SS';
            set feedback off
            set echo off
            set pages 0
            spool /tmp/batchdate.txt
            select trunc(min(NTIMESTAMP#)) + (trunc(sysdate-45) - trunc(min(NTIMESTAMP#))) from aud\\$;
            exit;
EOF
`
    # Test to make sure an ORA- error was not encountered
    export TEST=`grep 'ORA-' /tmp/batchdate.txt`
    case $TEST in
      *ORA-*)
        # An ORA- error occurred. Delete file so that the script does not execute
        cat /tmp/batchdate.txt >> $AUDM_LOG_FILE
        rm -f /tmp/batchdate.txt
    esac
    if [ -f /tmp/batchdate.txt ]; then
      cat /tmp/batchdate.txt |while read MDT; do
        BATCH_DATE=`echo $MDT |awk '{print $1}'`
      done
      rm -f /tmp/batchdate.txt
    fi
# ------------------------------------------------------------------
# Determine the number of records that need to be archived.
# ------------------------------------------------------------------
    echo "`date` : Starting the AUD$ archive." >> $AUDM_LOG_FILE
    echo "Records older than $BATCH_DATE will be archived and purged this batch.." >> $AUDM_LOG_FILE
    echo " " >> $AUDM_LOG_FILE
    echo "DATABASE   AUD$ TOTAL:  #<45DAYS:   # TO BE ARCHIVED/PURGED THIS BATCH:" >> $AUDM_LOG_FILE
    echo "========   ===========  =========   ===================================" >> $AUDM_LOG_FILE
    SQL_OUT=`sqlplus -S /nolog<<EOF
            connect $SQLUSER
            set feedback off
            set echo off
            set pages 0
            spool /tmp/total.txt
            with batchdte as
              (select trunc(min(NTIMESTAMP#)) + (trunc(sysdate-45) - trunc(min(NTIMESTAMP#))) AS "BATCH_DTE" from aud\\$)
            select name, (select count(*) from aud\\$) AS "TOTAL", (select count(*) from aud\\$ where trunc(NTIMESTAMP#) < trunc(sysdate-45)) AS "# > 45 DAYS", (select count(*) from aud\\$, batchdte b where trunc(NTIMESTAMP#) < b.BATCH_DTE) AS "# THIS BATCH" from v\\$database;
            exit;
EOF
`
    # Test to make sure an ORA- error was not encountered
    export TEST=`grep 'ORA-' /tmp/total.txt`
    case $TEST in
      *ORA-*)
        # An ORA- error occurred. Delete file so that the script does not execute
        cat /tmp/total.txt >> $AUDM_LOG_FILE
        rm -f /tmp/total.txt
    esac
    if [ -f /tmp/total.txt ]; then
      cat /tmp/total.txt >> $AUDM_LOG_FILE
      echo " " >> $AUDM_LOG_FILE
      cat /tmp/total.txt |while read NUM; do
        TO_ARCHIVE=`echo $NUM |awk '{print $4}'`
      done
      rm -f /tmp/total.txt
# ----------------------------------------------------------------------------
# Archive AUD$ records.
# ----------------------------------------------------------------------------
      echo "SQL> insert into AUDIT_ARCHIVE (select * from aud$ where trunc(NTIMESTAMP#) < ${BATCH_DATE});" >> $AUDM_LOG_FILE
      SQL_OUT=`sqlplus -S /nolog<<EOF
              connect $SQLUSER
              set echo off
              spool /tmp/archive.txt
              insert into AUDIT_ARCHIVE (select * from aud\\$ where trunc(NTIMESTAMP#) < (select trunc(min(NTIMESTAMP#)) + (trunc(sysdate-45) - trunc(min(NTIMESTAMP#))) from aud\\$)); 
              exit;
EOF
`
      # Test to make sure an ORA- error was not encountered
      export TEST=`grep 'ORA-' /tmp/archive.txt`
      case $TEST in
        *ORA-*)
        # An ORA- error occurred. Delete file so that the script does not execute
        cat /tmp/archive.txt >> $AUDM_LOG_FILE
        rm -f /tmp/archive.txt
      esac
      if [ -f /tmp/archive.txt ]; then
        cat /tmp/archive.txt >> $AUDM_LOG_FILE
        echo "Finished the AUD$ Archive for $DB_NAME at `date '+%b %d %Y %H:%M:%S'`" >> $AUDM_LOG_FILE
        cat /tmp/archive.txt |sed '/^$/d' |while read ARSTATS; do
          NUM_ARCHIVED=`echo $ARSTATS |awk '{print $1}'`
        done
        rm -f /tmp/archive.txt
        echo "$NUM_ARCHIVED records were archived from AUD$ into AUDIT_ARCHIVE." >> $AUDM_LOG_FILE
        echo " " >> $AUDM_LOG_FILE
# ----------------------------------------------------------
# Update the LAST_ARCHIVE_TIME parameter.
# ----------------------------------------------------------
        # Make sure the number of records that were archived match the number of records that needed to be archived before moving forward with the purge
        # This will avoid purging records that were not successfully archived
        if [ $NUM_ARCHIVED -eq $TO_ARCHIVE ]; then
          # Number of records archived equals the number of records that needed to be archived, so continue with the purge..
          # Update the last_archive_time parameter
          echo "`date` : Updating the last_archive_time parameter.." >> $AUDM_LOG_FILE
          SQL_OUT=`sqlplus -S /nolog<<EOF >> $AUDM_LOG_FILE
                  connect $SQLUSER
                  alter session set NLS_DATE_FORMAT='DD-MON-YYYY HH24:MI:SS';
                  set serveroutput on
                  declare
                    c_ardate aud\\$.NTIMESTAMP#%TYPE;
                  begin
                    select trunc(min(NTIMESTAMP#)) + (trunc(sysdate-45) - trunc(min(NTIMESTAMP#))) INTO c_ardate
                    from aud\\$;
                    dbms_audit_mgmt.set_last_archive_timestamp(
                      audit_trail_type  => dbms_audit_mgmt.audit_trail_aud_std,
                      last_archive_time => c_ardate,
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
                  select trunc(LAST_ARCHIVE_TS) from DBA_AUDIT_MGMT_LAST_ARCH_TS;
                  exit;
EOF
`
          if [ -f /tmp/last_archive_timestmp.txt ]; then
            cat /tmp/last_archive_timestmp.txt |while read TSTMP; do
              LST_AR=`echo $TSTMP |awk '{print $1}'`
            done
            rm -f /tmp/last_archive_timestmp.txt
            echo "New LAST_ARCHIVE_TS = $LST_AR" >> $AUDM_LOG_FILE
            echo "Correct timestamp = $BATCH_DATE" >> $AUDM_LOG_FILE
          fi
        else
          echo "WARNING: Archive possibly failed! Or completed in error: the number of records that were archived may not match the
number of records that are older than 45 days." >> $AUDM_LOG_FILE
          echo "The purge will not execute to avoid possibly deleting records that may have not been archived." >> $AUDM_LOG_FILE
          echo " " >> $AUDM_LOG_FILE
          echo "Script $0 ended on `date '+%b %d %Y %H:%M:%S'`." >>  $AUDM_LOG_FILE
          mail -s "${DB_NAME}: AUD$ ARCHIVE ERROR: PURGE DID NOT EXECUTE" ${MAILTO} < $AUDM_LOG_FILE
          exit
        fi 
      else
        echo "WARNING: Archive possibly failed!" >> $AUDM_LOG_FILE
        echo "The purge will not execute to avoid possibly deleting records that may have not been archived." >> $AUDM_LOG_FILE
        echo " " >> $AUDM_LOG_FILE
        echo "Script $0 ended on `date '+%b %d %Y %H:%M:%S'`." >>  $AUDM_LOG_FILE
        mail -s "${DB_NAME}: AUD$ ARCHIVE ERROR: PURGE DID NOT EXECUTE" ${MAILTO} < $AUDM_LOG_FILE
        exit 
      fi
     else
      echo "WARNING: An error occurred accessing the DB or accessing the AUD$ table." >> $AUDM_LOG_FILE
      echo " " >> $AUDM_LOG_FILE
      echo "Script $0 ended on `date '+%b %d %Y %H:%M:%S'`." >>  $AUDM_LOG_FILE
      mail -s "${DB_NAME}: AUD$ ARCHIVE & PURGE ERROR: DID NOT EXECUTE" ${MAILTO} < $AUDM_LOG_FILE
      exit
    fi
  else
    echo "WARNING: An error occurred while determining how to set the last archive time parameter." >> $AUDM_LOG_FILE
    echo " " >> $AUDM_LOG_FILE
    echo "Script $0 ended on `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
    mail -s "${DB_NAME}: AUD$ ARCHIVE & PURGE ERROR: DID NOT EXECUTE" ${MAILTO} < $AUDM_LOG_FILE
    exit
  fi
# ----------------------------------------------------------
# Purge AUD$ of records.
# ----------------------------------------------------------
  # Verify that the last_archive_time parameter was successfully updated to the correct date.
  if [ $LST_AR == $BATCH_DATE ]; then
    echo "The last_archive_time parameter was successfully updated; it is safe to purge." >> $AUDM_LOG_FILE
    echo " " >> $AUDM_LOG_FILE
    echo "`date` : Starting the AUD$ purge." >> $AUDM_LOG_FILE
    echo "Purging records that are older than $BATCH_DATE from the AUD$ table.." >> $AUDM_LOG_FILE
    echo " " >> $AUDM_LOG_FILE
    touch /tmp/audit_purge_$DB_NAME.lck
    SQL_OUT=`sqlplus -S /nolog<<EOF >> $AUDM_LOG_FILE
            connect $SQLUSER
            set serveroutput on
            alter session set NLS_DATE_FORMAT='DD-MON-YYYY HH24:MI:SS';
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
    rm -f /tmp/audit_purge_$DB_NAME.lck
    ESTAT=0
    echo " " >> $AUDM_LOG_FILE
# --------------------------------------------------------------
# Determine how many records are left that need to be archived.
# --------------------------------------------------------------
    echo "DATABASE   AUD$ TOTAL:  #<45 DAYS:" >> $AUDM_LOG_FILE 
    echo "========   ==========   ==========" >> $AUDM_LOG_FILE
    SQL_OUT=`sqlplus -S /nolog<<EOF 
            connect $SQLUSER
            set feedback off
            set echo off
            set pages 0
            spool /tmp/newtotal.txt
            select name, (select count(*) from aud\\$) AS "TOTAL", (select count(*) from aud\\$ where trunc(NTIMESTAMP#) < trunc(sysdate-45)) AS "# > 45 DAYS" from v\\$database;
            exit;
EOF
`
    # Test to make sure an ORA- error was not encountered
    export TEST=`grep 'ORA-' /tmp/newtotal.txt`
    case $TEST in
      *ORA-*)
      # An ORA- error occurred. Delete file so that the script does not execute
      cat /tmp/newtotal.txt >> $AUDM_LOG_FILE
      rm -f /tmp/newtotal.txt
    esac
    if [ -f /tmp/newtotal.txt ]; then
      cat /tmp/newtotal.txt >> $AUDM_LOG_FILE
      echo " " >> $AUDM_LOG_FILE
      cat /tmp/newtotal.txt |while read NUM; do
        REMAINING=`echo $NUM |awk '{print $3}'`
      done
      rm -f /tmp/newtotal.txt
    else
      echo "ALERT: Possibly could not access the DB or AUD$ table to count the number of records in AUD$ that are older than 45 days:" >> $AUDM_LOG_FILE
      echo "Script $0 cannot continue." >> $AUDM_LOG_FILE
      echo " " >> $AUDM_LOG_FILE
      echo "Script $0 ended on `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
      mail -s "${DB_NAME}: Script $0 Ended in Error" ${MAILTO} < $AUDM_LOG_FILE
      exit
    fi
    if [ $REMAINING -gt 0 ]; then
      echo "---------------------------------------------------------------------------" >> $AUDM_LOG_FILE
      echo "Waiting for an answer from the user to determine if Script $0 should continue archiving and purging these $REMAINING records, or terminate to resume at a later time.... " >> $AUDM_LOG_FILE
      echo " " >> $AUDM_LOG_FILE
#      mail -s "${DB_NAME}: AUD$ ARCHIVE AND PURGE NEEDS A RESPONSE" ${MAILTO} < $AUDM_LOG_FILE
      echo "Would you like to continue archiving and purging the remaining $REMAINING records? Choose yes to continue. Choose no to exit. (yes/no)"
      read input
      if [ $input != "yes" ]; then
        echo "User has chosen to terminate script. Purging the remaining $REMAINING records will need to be done at a later time." >> $AUDM_LOG_FILE
        echo "---------------------------------------------------------------------------" >> $AUDM_LOG_FILE
        echo " " >> $AUDM_LOG_FILE
        echo "Thank you. Script $0 has been terminated on `date '+%b %d %Y %H:%M:%S'`."
        echo "Script $0 was terminated by the user on `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
        exit  
      else
        echo "Thank you. Resuming Script $0 now.." 
        echo "User has chosen to continue." >> $AUDM_LOG_FILE
        echo "---------------------------------------------------------------------------" >> $AUDM_LOG_FILE
        echo " " >> $AUDM_LOG_FILE   
      fi
    else
      echo "Now that there are $REMAINING records that need to be archived and purged from AUD$, please schedule Script /homes/oracle/chsdba/common/audit_tr_maintenance_11g.sh to run daily to keep the audit trail maintained up to CHS standards." >> $AUDM_LOG_FILE
      CONT_BATCH=1
    fi   
  else
    # The last_archive_time parameter was not successfully updated; it is not safe to purge.
    ESTAT=1
    echo "CRITICAL: Updating the LAST_ARCHIVE_TIME parameter may have failed. Correct timestamp = $BATCH_DATE." >> $AUDM_LOG_FILE
    echo "The purge will not execute to avoid purging the entire AUD$ table instead of purging only records that are older than 45 days." >> $AUDM_LOG_FILE
  fi
done 
# -----------------------------------------------------------------
# Log the completion of the archive and purge of AUD$.
# -----------------------------------------------------------------
if [ "$ESTAT" -eq 0 ]
then
  LOGMSG="completed"
else
  LOGMSG="did not execute"
fi
echo " " >> $AUDM_LOG_FILE
echo " " >> $AUDM_LOG_FILE
echo ================================================= >> $AUDM_LOG_FILE
echo Return Status for AUD$ Maintenance is: $ESTAT >> $AUDM_LOG_FILE
echo ================================================= >> $AUDM_LOG_FILE
echo " " >> $AUDM_LOG_FILE
echo "The archive and purge of the AUD$ table in $DB_NAME" >> $AUDM_LOG_FILE
echo ==== $LOGMSG on `date` ==== >> $AUDM_LOG_FILE
# -----------------------------------------------------------------
# Remove records from the archive table that are older than 18 months.
# -----------------------------------------------------------------
echo " " >> $AUDM_LOG_FILE
echo " " >> $AUDM_LOG_FILE
echo "`date` : Starting the AUDIT_ARCHIVE maintenance." >> $AUDM_LOG_FILE
echo "Removing records that are older than 18 months from the archive table.." >> $AUDM_LOG_FILE
echo " " >> $AUDM_LOG_FILE
SQL_OUT=`sqlplus -S /nolog<<EOF >> $AUDM_LOG_FILE
        connect $SQLUSER
        set echo off
        set pages 0
        select 'Current total # of records in audit_archive: ' || count(*) from audit_archive;
        select 'SQL> delete AUDIT_ARCHIVE where trunc(NTIMESTAMP#) < trunc(sysdate-548);' from dual;
	delete AUDIT_ARCHIVE where trunc(NTIMESTAMP#) < trunc(sysdate-548);
        select 'New Total: ' || count(*) from audit_archive;
        commit;
        exit;    
EOF
  ` 
echo " " >> $AUDM_LOG_FILE
echo "Finished the AUDIT_ARCHIVE maintenance for $DB_NAME at `date '+%b %d %Y %H:%M:%S'`." >> $AUDM_LOG_FILE
# -----------------------------------------------------------------
# Email script status to DBAs.
# -----------------------------------------------------------------
if [ "$ESTAT" -eq 0 ]
then
  mail -s "${DB_NAME}: AUD$ ARCHIVE & PURGE COMPLETE" ${MAILTO} < $AUDM_LOG_FILE
else
  mail -s "${DB_NAME}: AUD$ ERROR: PURGE DID NOT EXECUTE" ${MAILTO} < $AUDM_LOG_FILE
fi
#----------------------------------------------------------------------
# Remove cycled logs older than 30 days
#----------------------------------------------------------------------   
find $LOG_LOC -name "${DB_NAME}_audit_tr_maintenance*.log" -mtime +30 -exec rm -rf {} \;
export ORAENV_ASK=YES;
#set +x
exit 
