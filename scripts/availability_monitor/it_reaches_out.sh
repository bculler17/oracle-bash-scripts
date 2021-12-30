#!/bin/bash
#
# ---------------------------------------------------------------------------------------------------------------------------------
#
# it reaches out it reaches out it reaches out once every 60 minutes..
# 
# To execute this script, the following database tables will need to already exist in an Oracle database: oracle_servers, oracle_databases and be populated with the db servers and databases that need to be monitored 
# The following script is also required to be staged on each server to be checked: ~/oracle_availability_check.sh
#
# This script monitors the availability of the Oracle database servers stored in the db table oracle_servers and the Oracle environments residing on the servers. 
# An alert will be emailed to the DBA's if a server, database instance, ASM instance, or if the LISTENERS is/are offline and/or unavailable.
# An alert will also be emailed to the DBA's if the VIP is not running on the correct machine.
#
# This script also collects various information about each environment to populate a dashboard that summarizes the entire Oracle environment
#
# Availability is checked once every hour.
#
# Author: Beth Culler
# Created: Septemer 15, 2021
# ---------------------------------------------------------------------------------------------------------------------------------
# turn on debug by uncommenting below line.
# -----------------------------------------------------------------
# set -x
# -----------------------------------------------------------------
# Set Local Variables.
# -----------------------------------------------------------------
MAILTO="<ENTER EMAIL ADDRESS>"
DATE_TIME_FM=`date +%Y%m%d_%H%M%S`
DTMASK=`date +%Y%m%d`
LOG_LOC=<ENTER LOG DIRECTORY>
DIR_LOG=${LOG_LOC}/oracle_availability_check_${DTMASK}.log
ERR_LOG=/tmp/CRITICAL_AVAIL_ERR.err
ARCHIVED_ERR_LOG=${LOG_LOC}/CRITICAL_AVAIL_ERR_${DATE_TIME_FM}.err
SYSID=`uname -a |awk '{print $2}'`
# -----------------------------------------------------------------
# Export Variables to be used.
# -----------------------------------------------------------------
export ORACLE_HOME=<ENTER $ORACLE_HOME>
export NLS_LANG=AMERICAN_AMERICA.WE8MSWIN1252
export ORA_NLS11=$ORACLE_HOME/nls/data
export NLS_DATE_FORMAT='Mon DD YYYY HH24:MI:SS'
export HOST_NAME=`uname -a |awk '{print $2}'`
export ORACLE_SID=<ENTER SID>
export PATH=$ORACLE_HOME/bin:$ORACLE_HOME/lib:$ORACLE_HOME/lib32:$PATH:
export SQLUSER="<username/password>"
# -----------------------------------------------------------------
# Initialize the log file.
# -----------------------------------------------------------------
if [ ! -f $DIR_LOG ]; then
> $DIR_LOG
chmod 666 $DIR_LOG
# -----------------------------------------------------------------
# Log the start of this script
# -----------------------------------------------------------------
	echo "Oracle Online Status Monitoring from HOST: $HOST_NAME" >> $DIR_LOG
	echo === started on `date` ==== >> $DIR_LOG
	echo "PURPOSE: Validate that Oracle is available - all of the Oracle servers, database instances, ASM instances, and LISTENERS are online, open and reachable." >> $DIR_LOG
	echo "Validate that the VIP is running on the correct machine." >> $DIR_LOG
	echo "Alert DBAs if they are not." >> $DIR_LOG
	echo >> $DIR_LOG
	echo >> $DIR_LOG
fi
# ---------------------------------------------------------------------
# Verify that another check is not still running and is therefore HUNG
# ---------------------------------------------------------------------
if [ -f /tmp/it-reaches-out.lck ]; then
   echo "$0: Still Running from last Availability Check. Check system for hung process." >> $DIR_LOG
   echo "$0: Still Running from last Availability Check. Check system for hung process." >> $ERR_LOG
   mail -s "WARNING: $0 MAY BE HUNG" ${MAILTO} < $ERR_LOG
   rm -f $ERR_LOG
   exit
else
   touch /tmp/it-reaches-out.lck
fi
# -----------------------------------------------------------------
# Build list of servers	
# -----------------------------------------------------------------
SQL_OUT=`sqlplus -S /nolog<<EOF 
 	 connect $SQLUSER
	 set feedback off
	 set echo off
 	 set pages 0
	 spool /tmp/oracle_server_list.txt
         select ipaddress, hostname, alert_status from oracle_servers where status='ACTIVE' order by 2;
	 spool off;
         exit;
EOF
`
# Test to make sure an ORA- error was not encountered
export SERVERS=/tmp/oracle_server_list.txt
export TEST=`grep 'ORA-' $SERVERS`
case $TEST in
	*ORA-*)
		# An ORA- error occurred. 
		mail -s "$0: Cannot get list of Oracle servers on `date '+%b %d %Y %H:%M:%S'`." ${MAILTO} < $SERVERS
		echo "ERROR: `date '+%b %d %Y %H:%M:%S'` - Could not get list of Oracle servers. See error below." >> $DIR_LOG
	        cat $SERVERS >> $DIR_LOG	
		rm -f $SERVERS
esac
# -----------------------------------------------------------------
# Build list of databases 
# -----------------------------------------------------------------
SQL_OUT=`sqlplus -S /nolog<<EOF 
         connect $SQLUSER
         set feedback off
         set echo off
         set pages 0
         set lines 1000
         col node1 format a25
         col node2 format a25
         spool /tmp/oracle_db_list.txt
         select distinct node1, node2, name from oracle_databases where status='ACTIVE' and ALERT_STATUS='YES' order by  1, 2, 3;
         spool off;
         exit;
EOF
`
# Test to make sure an ORA- error was not encountered
export DBLIST=/tmp/oracle_db_list.txt
export TEST=`grep 'ORA-' $DBLIST`
case $TEST in
	*ORA-*)
		# An ORA- error occurred. 
		mail -s "$0: Cannot get list of Oracle databases on `date '+%b %d %Y %H:%M:%S'`." ${MAILTO} < $DBLIST
		echo "ERROR: `date '+%b %d %Y %H:%M:%S'` - Could not get list of Oracle databases. See error below." >> $DIR_LOG
	        cat $DBLIST >> $DIR_LOG	
		rm -f $DBLIST
esac
if [ -f $SERVERS ]; then
	# Cycle through the server list to touch each server
	cat $SERVERS | while read SVRS; do
		IPA=`echo $SVRS |awk '{print $1}'`
		HNAME=`echo $SVRS |awk '{print $2}'`
                ALERTSTAT=`echo $SVRS |awk '{print $3}'`
		echo "Checking Availability of HOST: $HNAME........." >> $DIR_LOG
		# Test online status of server
		ping -c 3 $IPA > /dev/null
		if [ $? -eq 0 ]; then
			# Server is online
			echo "`date '+%b %d %Y %H:%M:%S'`: $HNAME is online." >> $DIR_LOG
			echo " " $DIR_LOG
                        if [ $IPA != '10.215.142.11' ]; then
                                UPTME=$(ssh -n ${IPA} uptime | awk '{print $3 " " substr($4, 1, length($4)-1)}')
                                LNXOS=$(ssh -n ${IPA} cat /etc/redhat-release)
                        	if [ $? -eq 0 ]; then 
                               		# This is a Linux server
	                        	SQL_OUT=`sqlplus -S /nolog<<EOF
				         	connect $SQLUSER
					 	update oracle_servers set online_status='YES', os_version='$LNXOS', up_time='$UPTME', record_updated=sysdate, record_updated_by='$0' where ipaddress='$IPA'; 
               		                 	commit;
				         	exit;
EOF
`
                        	else
					# This is an AIX server
                                	AIXOS=$(ssh -n ${IPA} oslevel -s)
					SQL_OUT=`sqlplus -S /nolog<<EOF
                                         	connect $SQLUSER
                                         	update oracle_servers set online_status='YES', os_version='AIX $AIXOS', up_time='$UPTME', record_updated=sysdate, record_updated_by='$0' where ipaddress='$IPA';
                                         	commit;
                                         	exit;
EOF
`
                        	fi
                        fi
			echo "Checking Availability of the Oracle environment that resides on $HNAME........" >> $DIR_LOG
			if [ -f $DBLIST ]; then
				# Pull out the databases from the list that reside on this server to test online status
               			cat $DBLIST | sed 's/^[ \t]*//;s/[ \t]*$//' | while read DB; do
                                        WORDCOUNT=`echo $DB | awk '{print NF}'`
                                        if [ $WORDCOUNT -eq 3 ]; then
					        HSTNAME1=`echo $DB | awk '{print $1}'`
       	        			        HSTNAME2=`echo $DB | awk '{print $2}'`
				       		DBNAME=`echo $DB | awk '{print $3}'`	
                                        elif [ $WORDCOUNT -eq 2 ]; then
                                                HSTNAME1=`echo $DB | awk '{print $1}'`
                                                HSTNAME2='NULL'
                                                DBNAME=`echo $DB | awk '{print $2}'`
                                        else
                                                echo "WARNING: An error occurred with the database list. Check oracle_databases for record errors." >> $DIR_LOG
                                        fi
					if [[ $HSTNAME1 == $HNAME || $HSTNAME2 == $HNAME ]]; then
                                        	if [ $DBNAME == '<DB_NAME>' ]; then
							RMSQLUSER="<username/password@TNSNAMES_ID>"
                                                elif [ $DBNAME == '<DB_NAME>' ]; then
				                        RMSQLUSER="<username/password@TNSNAMES_ID>"
						else
       							RMSQLUSER="<username/password@${DBNAME}_TNSNAMES_ID"          
						fi
                                                TOT_DBFILES=`sqlplus -S /nolog<<EOF
                                                           connect $RMSQLUSER
                                                           set feedback off
                                                           set echo off
                                                           set pages 0
                                                           select count(*) from dba_data_files;
                                                           exit;
EOF
`
                                                MAX_DBFILES=`sqlplus -S /nolog<<EOF
                                                           connect $RMSQLUSER
                                                           set feedback off
                                                           set echo off
                                                           set pages 0
                                                           select TO_NUMBER(value) from v\\$parameter where name='db_files';
                                                           exit;
EOF
`
                                                CURRENT_SIZE=`sqlplus -S /nolog<<EOF
                                                           connect $RMSQLUSER
                                                           set feedback off
                                                           set echo off
                                                           set pages 0
                                                           select TO_CHAR(round((sum(total_mb - free_mb))/1024, 2), '999,999,999.99') || ' GB' used_gb from v\\$asm_diskgroup where name like UPPER('${DBNAME}%');
                                                           exit;
EOF
`
                                                DB_VERSION=`sqlplus -S /nolog<<EOF
						           connect $RMSQLUSER
						           set feedback off
						           set echo off
						           set pages 0
                                                           select distinct version from gv\\$instance;
         				      	           exit;
EOF
`
                                                DBTYPE=`sqlplus -S /nolog<<EOF
                                                           connect $RMSQLUSER
                                                           set feedback off
                                                           set echo off
                                                           set pages 0
                                                           select value from v\\$parameter where name='cluster_database';
                                                           exit;
EOF
`
                                                if [ $DBTYPE == 'TRUE' ]; then
                                                  DB_TYPE='RAC'
                                                elif [ $DBTYPE == 'FALSE' ]; then
                                                  DB_TYPE='standalone'
                                                fi
                                                UPTIME1=`sqlplus -S /nolog<<EOF
                                                         connect $RMSQLUSER
                                                         set feedback off
                                                         set echo off
                                                         set pages 0
                                                         select round(sysdate - (select startup_time from gv\\$instance where instance_number=1)) from dual;
                                                         exit;
EOF
`
                                                if [ ! -z "${UPTIME1// }" ]; then
							SQL_OUT=`sqlplus -S /nolog<<EOF
				                                 connect $SQLUSER
                               					 update oracle_databases set UP_TIME1='$UPTIME1 days', version='$DB_VERSION', dbtype='$DB_TYPE', current_size='$CURRENT_SIZE', TOTAL_DB_FILES=${TOT_DBFILES}, MAX_DB_FILES=${MAX_DBFILES}, record_updated=sysdate, record_updated_by='$0' where name='$DBNAME';
				                                 commit;
                               					 exit;
EOF
`
                                                fi
                                                UPTIME2=`sqlplus -S /nolog<<EOF
                                                         connect $RMSQLUSER
                                                         set feedback off
                                                         set echo off
                                                         set pages 0
                                                         select round(sysdate - (select startup_time from gv\\$instance where instance_number=2)) from dual;
                                                         exit;
EOF
`
                                                if [ ! -z "${UPTIME2// }" ]; then
                                                        SQL_OUT=`sqlplus -S /nolog<<EOF
                                                                 connect $SQLUSER
                                                                 update oracle_databases set UP_TIME2='$UPTIME2 days', version='$DB_VERSION', dbtype='$DB_TYPE', current_size='$CURRENT_SIZE', TOTAL_DB_FILES=${TOT_DBFILES}, MAX_DB_FILES=${MAX_DBFILES}, record_updated=sysdate, record_updated_by='$0' where name='$DBNAME';
                                                                 commit;
                                                                 exit;
EOF
`
						fi
						echo "  DATABASE: $DBNAME  -" >> $DIR_LOG
						ssh -t -t -n $HNAME -l oracle "~/oracle_availability_check.sh $DBNAME $HNAME $HSTNAME1 $HSTNAME2 $DB_TYPE $DB_VERSION" 
                                        	export STATLOG=/tmp/dbstatus.log
	                       			if [ -f "$ERR_LOG" ]; then
							mail -s "ALERT! ORACLE is UNAVAILABLE on $HNAME! `date '+%b %d %Y %H:%M:%S'`." ${MAILTO} < $ERR_LOG
							mv $ERR_LOG $ARCHIVED_ERR_LOG
							SQL_OUT=`sqlplus -S /nolog<<EOF
				                                 connect $SQLUSER
                               					 update oracle_databases set online_status='NO',up_time='0 days', record_updated=sysdate, record_updated_by='$0' where name='$DBNAME';
				                                 commit;
                               					 exit;
EOF
`
						else
							SQL_OUT=`sqlplus -S /nolog<<EOF
				                                 connect $SQLUSER
                               					 update oracle_databases set online_status='YES', record_updated=sysdate, record_updated_by='$0' where name='$DBNAME'; 
				                                 commit;
                               					 exit;
EOF
`
       		                                fi
						if [ -f "$STATLOG" ]; then
							cat $STATLOG  >> $DIR_LOG
							echo " " >> $DIR_LOG
							echo " --------- " >> $DIR_LOG
						else
							echo "WARNING: $HNAME is ONLINE but the Oracle availability check could not be completed. Could not locate the log file(s) sent from $HNAME. Please investigate." >> $ERR_LOG
                                                        echo "WARNING: $HNAME is ONLINE but the Oracle availability check could not be completed. Could not locate the log file(s) sent from $HNAME. DBA's have been notified." >> $DIR_LOG
                       	                                mail -s "WARNING: Oracle availability check could not be completed on $HNAME. `date '+%b %d %Y %H:%M:%S'`." ${MAILTO} < $ERR_LOG
							rm -f $ERR_LOG
                                       		fi
						rm -f $STATLOG
					fi
			       	done	
			else 
				echo "WARNING: Cannot find list of Oracle databases that reside on $HNAME. Availability could not be checked." >> $DIR_LOG
			fi 
			echo " " >> $DIR_LOG
		else
                        if [ $ALERTSTAT == 'YES' ]; then
			  echo " !! ALERT  - `date '+%b %d %Y %H:%M:%S'` !!" >> $DIR_LOG
			  echo "$HNAME is OFFLINE! Emailed alert to DBA's." >> $DIR_LOG
			  echo "" >> $DIR_LOG
       		          echo "ALERT: `date '+%b %d %Y %H:%M:%S'` - $HNAME is OFFLINE! " >> $ERR_LOG
			  echo "If this outage was not planned, please troubleshoot and bring $HNAME back online." >> $ERR_LOG
			  mail -s "ALERT! Node $HNAME is OFFLINE! `date '+%b %d %Y %H:%M:%S'`." ${MAILTO} < $ERR_LOG  
                          mv $ERR_LOG $ARCHIVED_ERR_LOG
                        fi
                        SQL_OUT=`sqlplus -S /nolog<<EOF
                                 connect $SQLUSER
                                 update oracle_servers set online_status='NO', record_updated=sysdate, record_updated_by='$0' where hostname='$HNAME';
                                 commit;
                                 exit;
EOF
`
		fi 
		echo " " >> $DIR_LOG
		echo " ----------------------------------------------------------" >> $DIR_LOG
		echo " " >> $DIR_LOG
	done
else
	echo "WARNING: Cannot find list of Oracle servers. Availability could not be checked. " >> $DIR_LOG
	echo " " >> $DIR_LOG
fi
#----------------------------------------------------------------------
# Rename the Log File if it reaches 1MB
#---------------------------------------------------------------------- 
find $LOG_LOC -name "oracle_availability_check*.log" -size +1000000c -print|while read line; do
	mv $line $line\_`date +%m%d%y%H%M%S`
done
#----------------------------------------------------------------------
# Remove cycled logs older than 30 days
#----------------------------------------------------------------------   
find $LOG_LOC -name "oracle_availability_check*.log" -mtime +30 -exec rm -rf {} \;
#----------------------------------------------------------------------
# Remove archived error logs older than 18 months
#----------------------------------------------------------------------
find $LOG_LOC -name "CRITICAL*.err" -mtime +548 -exec rm -rf {} \;
rm -f /tmp/it-reaches-out.lck
#set +x
exit
