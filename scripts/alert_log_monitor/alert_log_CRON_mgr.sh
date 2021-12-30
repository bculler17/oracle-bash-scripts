#!/bin/bash
#
#------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
# Because db_alert_log_monitor.sh executes in a continuous loop, this script is scheduled in crontab to check every 5 minutes that db_alert_log_monitor.sh is still running 
# If db_alert_log_monitor.sh is not running anymore, an alert will be emailed to the DBA's and this script will automatically restart db_alert_log_monitor.sh
#
# Author: Beth Culler
#-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
#Global Parameters
#
#set -x
DT_STAMP=`date +%Y%m%d_%H%M%S`
DIR_LOG=<CHOOSE DIRECTORY>/db_alertlog_check_$DT_STAMP.log
HOSTNAME=`hostname`
DB_NAME=$1
SCRIPT_DIR=<CHOOSE DIRECTORY>
MAILTO=<"INSERT EMAIL">
export MAILTO
# -----------------------------------------------------------------
# Initialize the log file.
# -----------------------------------------------------------------
> $DIR_LOG
chmod 777 $DIR_LOG
if [ "$(ps -efl |grep -v grep |grep "db_alert_log_monitor.sh $DB_NAME" |wc -l)" -gt 0 ]; then
   # process is still running
   chmod 666 $DIR_LOG
else
   # process not running, system restarted??
   echo === `date` === >> $DIR_LOG
   echo " $0: Restarting the Alert Log Monitor for $DB_NAME on $HOSTNAME, verify log/machine to see what happened." >> $DIR_LOG
   mailx -s "$DB_NAME: Restart of the Alert Log Monitor on $HOSTNAME" $MAILTO < $DIR_LOG
   cd $SCRIPT_DIR
   ./db_alert_log_monitor.sh $DB_NAME
fi 
#
# Clean Up logs
#
find <DIRECTORY>/db_alertlog_check*.log -type f -size 0 -exec rm -rf {} \;
find <DIRECTORY>/db_alertlog_check*.log -type f -mtime +14 rm -rf {} \;
#
#set +x
