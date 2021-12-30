#!/bin/bash
#
# --------------------------------------------------------------------------------------------------------------------
# This script monitors the 11g, 12c, or 19c database alert log for ORA- errors and instance terminations / restarts
# Every 5 minutes, the alert log is scanned  
# If an ORA- error or instance termination/restart is found, the DBA's will be notified via email.
#
# Author: Beth Culler
# Created: 07/13/2021
# ---------------------------------------------------------------------------------------------------------------------
# turn on debug by uncommenting below line.
# -----------------------------------------------------------------
# set -x
# -----------------------------------------------------------------
# Set Local Variables.
# -----------------------------------------------------------------
MAILTO="<INSERT EMAIL HERE>"
DT_STAMP=`date +%Y%m%d_%H%M%S`
SQLUSER="<username/password>"                      # User used to log into database
DIR_LOG_LOC=/homes/oracle/log
# -----------------------------------------------------------------
# Export Variables to be used.
# -----------------------------------------------------------------
export PATH=$PATH:/usr/local/bin
export NLS_LANG=AMERICAN_AMERICA.WE8MSWIN1252
export ORA_NLS11=$ORACLE_HOME/nls/data
export NLS_DATE_FORMAT='Mon DD YYYY HH24:MI:SS'
export HOST_NAME=`uname -a |awk '{print $2}'`
export DB_NAME=$1
export ORACLE_SID=$DB_NAME
export ORAENV_ASK=NO;
# -----------------------------------------------------------------
# Setup Oracle Environment
# -----------------------------------------------------------------
. /usr/local/bin/oraenv
# -----------------------------------------------------------------
# Determine the instance name
# -----------------------------------------------------------------
SQL_OUT=`sqlplus -S /nolog<<EOF 
        connect $SQLUSER
        spool /tmp/instname.txt
        set pages 0
	select instance_name from v\\$instance;
        exit;
EOF
`   
INSTNAME=`cat /tmp/instname.txt |awk '{print $1}'`  
# -----------------------------------------------------------------
# Determine the alert log file destination
# -----------------------------------------------------------------
SQL_OUT=`sqlplus -S /nolog<<EOF 
        connect $SQLUSER
        spool /tmp/diagdest.txt
        set pages 0
        select value from v\\$diag_info where name='Diag Trace';
        exit;
EOF
`     
# Test to make sure an ORA- error was not encountered
export TEST=`grep 'ORA-' /tmp/diagdest.txt`
case $TEST in
  *ORA-*)
    # An ORA- error occurred. Delete file and alert DBA's
    mail -s "${HOST_NAME} ERROR: Script $0 Could Not Execute. Needs to be Restarted." ${MAILTO} < /tmp/diagdest.txt
    rm -f /tmp/diagdest.txt
    exit
esac
if [ -f /tmp/diagdest.txt ]; then
  DIAG_DEST=`cat /tmp/diagdest.txt | sed 's/^[ \t]*//;s/[ \t]*$//'`
  ALRTLOG=`ls -ltr $DIAG_DEST/*.log | tail -1 | awk '{print $9}'`
  ALRT_INST=`basename $ALRTLOG .log`
  DIR_LOG=${DIR_LOG_LOC}/alertlog_${ALRT_INST}\_$DT_STAMP.log
  ERR_LOG=${DIR_LOG_LOC}/alertlog_${ALRT_INST}\_$DT_STAMP.err
# -----------------------------------------------------------------
# Clean up /tmp files
# -----------------------------------------------------------------
  rm -f /tmp/instname.txt
  rm -f /tmp/diagdest.txt
# -----------------------------------------------------------------
# Initialize the log file.
# -----------------------------------------------------------------
> $DIR_LOG
chmod 666 $DIR_LOG
end_signal()
  {
     echo "* * * Process Killed * * *" >> $DIR_LOG
     echo "Termination Occurred at: `date`" >> $DIR_LOG
  }
# -----------------------------------------------------------------
# Log the start of this script
# -----------------------------------------------------------------
  echo "Alert Log File $ALRTLOG" >> $DIR_LOG
  echo " " >> $DIR_LOG
  echo "Alert Log Check FOR Instance: $INSTNAME" >> $DIR_LOG
  echo === started on `date` ==== >> $DIR_LOG
  echo >> $DIR_LOG
  echo >> $DIR_LOG
# Determine the line number of the last entry in the alert log
  START_NUM=$(wc -l $ALRTLOG | awk '{print $1}')
  trap end_signal 15 9 2 1 0
  while /bin/true; do
    # Wait 5 minutes
    sleep 300
    # Check if the alert log has been modified within the past 5 minutes
    NEWENTRY_NUM=$(find $DIAG_DEST -name ${ALRT_INST}.log -type f -mmin -5 | wc -l)
    if [ $NEWENTRY_NUM -eq 0 ]; then
      echo "* * * `date` * * *"  >> $DIR_LOG
      echo -e "There are 0 new entries in ${ALRT_INST}.log from within the past 5 minutes." >> $DIR_LOG
      echo " " >> $DIR_LOG
      echo " " >> $DIR_LOG
    else
      # Determine the new line number of the last entry in the alert log
      END_NUM=$(wc -l $ALRTLOG | awk '{print $1}')
      NUM_LINES=$((END_NUM - START_NUM))
      echo "* * * `date` * * *"  >> $DIR_LOG
      echo "Checking $NUM_LINES lines written within the past 5 minutes out of $END_NUM lines in ${ALRT_INST}.log........" >> $DIR_LOG
      echo " " >> $DIR_LOG
      START_NUM=$END_NUM
      ERRCT=$(tail -$NUM_LINES $ALRTLOG | grep -v ORA-3136 | grep -c ORA-)
      TERM8ED=$(tail -$NUM_LINES $ALRTLOG | grep "Instance terminated")
      RESTRT=$(tail -$NUM_LINES $ALRTLOG | grep "Starting ORACLE instance")
      if [ $ERRCT -gt 0 ]; then
        echo "$ERRCT errors found:" >> $DIR_LOG
        echo ------------ >> $DIR_LOG
        echo "Review Error Log: $ERR_LOG" >> $DIR_LOG
        echo " " >> $DIR_LOG
        echo " " >> $DIR_LOG
        echo "Alert Log File $ALRTLOG." >> $ERR_LOG
        echo "Node name:       $HOST_NAME" >> $ERR_LOG
        echo "Instance name:   $INSTNAME" >> $ERR_LOG
        echo " "  >> $ERR_LOG
        echo "WARNING: $ERRCT errors found within the past 5 minutes:" >> $ERR_LOG  
        echo "**********************************************************" >> $ERR_LOG
        tail -$NUM_LINES $ALRTLOG | 
		awk 'BEGIN{buf=""}
		/[0-9]:[0-9][0-9]:[0-9]/{buf=$0}
		/ORA-/{print NR,buf,$0}' | grep -v ORA-3136 >> $ERR_LOG
        echo "**********************************************************" >> $ERR_LOG
        echo " " >> $ERR_LOG
      else
        echo "$ERRCT errors found. Will check again in 5 minutes." >> $DIR_LOG
        echo " " >> $DIR_LOG
        echo " " >> $DIR_LOG
      fi
      if [ ! -z "${TERM8ED}" ]; then
        if [ $ERRCT -eq 0 ]; then
          echo "Alert Log File $ALRTLOG." >> $ERR_LOG
          echo "Node name:       $HOST_NAME" >> $ERR_LOG
          echo "Instance name:   $INSTNAME" >> $ERR_LOG
          echo " "  >> $ERR_LOG
          echo "ALERT: ORACLE instance was TERMINATED!" >> $DIR_LOG
          echo ------------ >> $DIR_LOG
          echo "Review Error Log: $ERR_LOG" >> $DIR_LOG
        fi
        echo "ALERT: ORACLE instance was TERMINATED!" >> $ERR_LOG
        echo "**********************************************************" >> $ERR_LOG
        tail -$NUM_LINES $ALRTLOG | 
		awk 'BEGIN{buf=""}
		/[0-9]:[0-9][0-9]:[0-9]/{buf=$0}
		/Instance terminated/{print NR,buf,$0}' >> $ERR_LOG
        echo "**********************************************************" >> $ERR_LOG
        echo " " >> $ERR_LOG
      fi
      if [ ! -z "${RESTRT}" ]; then
        if [[ $ERRCT -eq 0 && -z "${TERM8ED}" ]]; then
          echo "Alert Log File $ALRTLOG." >> $ERR_LOG
          echo "Node name:       $HOST_NAME" >> $ERR_LOG
          echo "Instance name:   $INSTNAME" >> $ERR_LOG
          echo " "  >> $ERR_LOG
        fi
        echo "NOTE: ORACLE instance was restarted -" >> $ERR_LOG
        echo "**********************************************************" >> $ERR_LOG
        tail -$NUM_LINES $ALRTLOG | 
		awk 'BEGIN{buf=""}
		/[0-9]:[0-9][0-9]:[0-9]/{buf=$0}
		/Starting ORACLE instance/{print NR,buf,$0}' >> $ERR_LOG
        echo "**********************************************************" >> $ERR_LOG
        echo " " >> $ERR_LOG
      fi
      if [ -f $ERR_LOG ]; then
        mail -s "Alert Log Errors: $ALRT_INST" $MAILTO < $ERR_LOG
        mv $ERR_LOG ${DIR_LOG_LOC}/alertlog_${ALRT_INST}\_`date +%m%d%y%H%M%S`.err
      fi
    fi  
#----------------------------------------------------------------------
# Rename the Log File once it reaches 1MB
#---------------------------------------------------------------------- 
    find $DIR_LOG_LOC -name "alertlog*.log" -size +1000000c -print|while read line; do
      mv $line $line\_`date +%m%d%y%H%M%S`
    done
#----------------------------------------------------------------------
# Remove cycled logs older than 30 days
#----------------------------------------------------------------------   
    find $DIR_LOG_LOC -name "alertlog*.log*" -mtime +30 -exec rm -rf {} \;
    find $DIR_LOG_LOC -name "alertlog*.err" -mtime +30 -exec rm -rf {} \; 
#----------------------------------------------------------------------
# Start the loop again to check for ORA- errors again in 5 minutes
#----------------------------------------------------------------------            
  done
fi
export ORAENV_ASK=YES;
#set +x
exit 
