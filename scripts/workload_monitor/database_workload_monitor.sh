#!/bin/bash
# 
# To execute this script, the following database table will need to already exist in an Oracle database: oracle_DB_workload_trend
#
# This script calculates the average number of total 'User Calls' and DML transactions ('User Commits' and 'User Rollbacks') that have occured in the database per hour since the last startup time to trend over time
# Purpose: Determine if the database's workload is increasing or decreasing over time; pin point peak hours /days
#
# Created: 12/3/2021
# Author: Beth Culler
#
# ---------------------------------------------------------------------------------------------------------------------------------
# turn on debug by uncommenting below line.
# -----------------------------------------------------------------
# set -x
# -----------------------------------------------------------------
# Export Variables to be used.
# -----------------------------------------------------------------
SYSID=`uname -a |awk '{print $2}'`
export ORACLE_HOME=<ENTER $ORACLE_HOME>
export NLS_LANG=AMERICAN_AMERICA.WE8MSWIN1252
export ORA_NLS11=$ORACLE_HOME/nls/data
export NLS_DATE_FORMAT='Mon DD YYYY HH24:MI:SS'
export HOST_NAME=`uname -a |awk '{print $2}'`
export ORACLE_SID=<ENTER SID>
export PATH=$ORACLE_HOME/bin:$ORACLE_HOME/lib:$ORACLE_HOME/lib32:$PATH:
export SQLUSER=<"username/password">                          # Access to the db table that will trend the data over time
export LSQLUSER=<"username/password@TNSNAMES_ID">             # Access to the db to be monitored
# Calculate the avg number of 'User Calls' and DML transactions ('User Commits' and 'User Rollbacks') that have occured per hour since the last startup time 
SQL_OUT=`sqlplus -S /nolog<<EOF
         connect $LSQLUSER
         set feedback off
         set echo off
         set pages 0
         spool /tmp/oracle_DB_avg_workload.txt
         select D1, I1, TO_CHAR(V3 / T1 / 24, '999,999,999.99') "Avg Hourly User Calls", TO_CHAR(S1 / T1 /24, '999,999,999.99') "Avg Hourly DML Transactions", TO_CHAR(((V3 / T1 / 24) - (S1 / T1 /24)), '999,999,999.99') "Avg Hourly Read Only" from (SELECT NAME D1 from v\\$database), (SELECT INST_ID I1, SUM(VALUE) S1 FROM gV\\$SYSSTAT WHERE NAME IN ('user commits', 'user rollbacks') group by INST_ID) A, (SELECT INST_ID, VALUE V3 FROM gV\\$SYSSTAT WHERE NAME = 'user calls') B, (SELECT INST_ID, SYSDATE - STARTUP_TIME T1 FROM gV\\$INSTANCE) C where A.I1=B.INST_ID and A.I1=C.INST_ID;
         spool off;
         exit;
EOF
`
# Test to make sure an ORA- error was not encountered
export WORKLOAD=/tmp/oracle_DB_avg_workload.txt
export TEST=`grep 'ORA-' $WORKLOAD`
case $TEST in
        *ORA-*)
                # An ORA- error occurred.
                rm -f $WORKLOAD
esac
if [ -f $WORKLOAD ]; then
	cat $WORKLOAD | sed 's/^[ \t]*//;s/[ \t]*$//' | while read AVG; do
                DBNAME=`echo $AVG | awk '{print $1}'`
		INST_ID=`echo $AVG | awk '{print $2}'`
                TOT_USER_CALLS=`echo $AVG | awk '{print $3}'`
                DML_TX=`echo $AVG | awk '{print $4}'`
                READ_ONLY=`echo $AVG | awk '{print $5}'`
                SQLOUT=`sqlplus -S /nolog<<EOF
                         connect $SQLUSER
                         insert into oracle_DB_workload_trend VALUES (sysdate, '$DBNAME', $INST_ID, '$TOT_USER_CALLS', '$DML_TX', '$READ_ONLY');
                         commit;
                         exit;
EOF
`
        done
fi
rm -f $WORKLOAD
#set +x
exit
