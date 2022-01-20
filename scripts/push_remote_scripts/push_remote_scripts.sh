#!/bin/bash
#
# To execute this script, the following database tables will need to already exist in an Oracle database: oracle_servers, oracle_databases and be populated with the db servers and databases you wish to push files to
#
# This script will push a local file or files to every server stored in the oracle_servers table with status='ACTIVE' (excluding those that host a database with status='HMA' from rcpbdct's chs_oracle_databases table)
#
# Purpose: To create a central repository for maintenance scripts. Some scripts are required to be stored locally on the machine the script needs to be executed on. When changes need to be made to those scripts, each script on each server would have to be individually changed. To prevent that, the script(s) can be stored on this local machine (the central repository) and then just copied over to all of the other servers by using this script. Any changes to those scripts can be done here (this local machine - the central repository) then pushed out using this script. Therefore, only one server and one file will need to be touched instead of multiple. 
#
# Syntax: ./push_remote_scripts.sh file1.sh file2.sh file3.sh
# where file1.sh, file2.sh, and file3.sh are the files to be pushed out. 
# You can push 1+ files out (any number)
#
# Author: Beth Culler
# Created: 12/15/2021
# ----------------------------------------------------------------------------------------------------------------------------------
# turn on debug by uncommenting below line
# -----------------------------------------------------------------
# set -x
# -----------------------------------------------------------------
# Export Variables to be used.
# -----------------------------------------------------------------
START=BEGIN
while [ $START == 'BEGIN' ]; do
        echo "Would you like to push these files to ALL servers, both PROD and DEV/TEST? Y/N"
        read REPLY
        if [ $REPLY == 'Y' ]; then
		export TYPE="'PROD', 'DEV/TEST'"
		START=FINISHED
        elif [ $REPLY == 'N' ]; then
		ASK=YES
		while [ $ASK == 'YES' ]; do
			echo "Would you like to push these files ONLY to PROD servers? Y/N"	
                        read REPLY
			if [ $REPLY == 'Y' ]; then
                		export TYPE="'PROD'"
				ASK=NO
                		START=FINISHED
			elif [ $REPLY == 'N' ]; then
				ASKAGAIN=YES
				while [ $ASKAGAIN == 'YES' ]; do
					echo "Push these files only to DEV/TEST servers? Y/N"
                                        read REPLY
					if [ $REPLY == 'Y' ]; then
                        			export TYPE="'DEV/TEST'"
						ASKAGAIN=NO
						ASK=NO
                        			START=FINISHED
					elif [ $REPLY == 'N' ]; then
						echo "Please select one of the following: ALL, PROD, or DEV/TEST."
						ASKAGAIN=NO
						ASK=NO
					else
						echo "Please enter Y/N"
					fi
				done
			else
				echo "Please enter Y/N"
			fi
		done
	else
		echo "Please enter Y/N"
	fi
done
START=BEGIN	
while [ $START == 'BEGIN' ]; do
	echo "Would you like to push these files to ~/standard/location? Y/N"
	read ANSWER
	if [ $ANSWER == 'Y' ]; then
		export REMOTE_DEST='~/standard/location'	# push file to this location on the remote servers
		START=FINISHED
                echo " "
	elif [ $ANSWER == 'N' ]; then
        	CHECK=N
        	while [ $CHECK == 'N' ]; do
			read -p "New directory: " REMOTE_DEST
        		echo "You entered ${REMOTE_DEST}. Is this correct? Y/N"
			read VERIFY
			if [ $VERIFY == 'Y' ]; then
        			export $REMOTE_DEST
               		        CHECK=Y
                                START=FINISHED
                                echo " "
			elif [ $VERIFY == 'N' ]; then
                                echo "Please enter the directory again."
                	else
				echo "Please enter Y/N"
                	fi
		done	
	else
		echo "Please enter Y/N"
	fi
done
export NLS_LANG=AMERICAN_AMERICA.WE8MSWIN1252
export ORACLE_HOME=<INSERT $ORACLE_HOME>
export ORA_NLS11=$ORACLE_HOME/nls/data
export NLS_DATE_FORMAT='Mon DD YYYY HH24:MI:SS'
export HOST_NAME=`uname -a |awk '{print $2}'`
export ORACLE_SID=<INSERT SID>
export PATH=$ORACLE_HOME/bin:$ORACLE_HOME/lib:$ORACLE_HOME/lib32:$PATH:
export SQLUSER="<username/password>"
# Build list of servers
SQL_OUT=`sqlplus -S /nolog<<EOF
         connect $SQLUSER
         set feedback off
         set echo off
         set pages 0
         set lines 1000
         col node1 format a25
         col node2 format a25
         spool /tmp/oracle_pushlist.txt
         select distinct IPADDRESS, hostname from oracle_servers s, oracle_databases d where (s.hostname=d.node1 or s.hostname=d.node2) and s.status='ACTIVE' and s.function in (${TYPE}) order by 2;
         spool off;
         exit;
EOF
`
# Test to make sure an ORA- error was not encountered
export PUSHLIST=/tmp/oracle_pushlist.txt
export TEST=`grep 'ORA-' $PUSHLIST`
case $TEST in
        *ORA-*)
                # An ORA- error occurred.
                rm -f $PUSHLIST
esac
if [ -f $PUSHLIST ]; then
        echo "Starting to push your files to ${REMOTE_DEST} on the following remote servers......."
        cat $PUSHLIST | sed 's/^[ \t]*//;s/[ \t]*$//'
        echo ""
        ERRORS=0
	cat $PUSHLIST | while read IP; do
		IPADD=`echo $IP | awk '{print $1}'`
                HNAME=`echo $IP | awk '{print $2}'`
                # Loop through scripts and scp each one
                for SCRIPT in "$@"
                	do
                		scp ${SCRIPT} oracle@${IPADD}:${REMOTE_DEST}/.  
                                if [ $? -eq 0 ]; then
                                        echo " "
					echo "${SCRIPT}: Push succeeded to ${HNAME}:${REMOTE_DEST}."
                                else
                                        echo " "
					echo "${SCRIPT}: Push FAILED to ${HNAME}:${REMOTE_DEST}!"
					((ERRORS=ERRORS+1))
                                        echo $ERRORS  > /tmp/errorcount.txt
                                fi
                                echo " " 
			done
        done 
        if [ -f /tmp/errorcount.txt ]; then
          ERRORS=`cat /tmp/errorcount.txt`
          rm -f /tmp/errorcount.txt
        fi
	echo "Finished with $ERRORS error(s). Goodbye."
fi
rm -f $PUSHLIST
#set +x
exit
