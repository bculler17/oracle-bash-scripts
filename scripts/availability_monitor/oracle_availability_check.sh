# To be remotely executed by ./it_reaches_out.sh from the central repository server
# Set up Oracle environment
DATE_TIME_FM=`date +%Y%m%d_%H%M%S`
export ERR_LOG=~/it_reaches_out/CRITICAL_AVAIL_ERR.err
export PATH=$PATH:/usr/local/bin
export DBNAME=$1
export HNAME=$2
export HSTNAME1=$3
export HSTNAME2=$4
export DB_TYPE=$5
export DB_VERSION=$6 
export ORACLE_SID=$DBNAME
export ORAENV_ASK=NO;
. /usr/local/bin/oraenv
# Test online status of the database
echo "`date '+%b %d %Y %H:%M:%S'` - " >> /tmp/dbstatus.log
if [ $HSTNAME1 == $HNAME ]; then
	$ORACLE_HOME/bin/srvctl status database -d $DBNAME -v | head -1  >> /tmp/dbstatus.log
elif [ $HSTNAME2 == $HNAME ]; then
       	$ORACLE_HOME/bin/srvctl status database -d $DBNAME -v | tail -1  >> /tmp/dbstatus.log
fi
export STATUS=`grep -i 'not running' /tmp/dbstatus.log`
export STATE=`grep -i 'OPEN' /tmp/dbstatus.log`
if [ ! -z $STATUS ]; then
	# Database instance is offline
        echo " !! ALERT  - `date '+%b %d %Y %H:%M:%S'` !! " >> $ERR_LOG
        echo " $DBNAME is offline on $HNAME!"  >> $ERR_LOG
        echo "" >> $ERR_LOG
elif [ -z "$STATE" ]; then
        # Database is running but it is not in an OPEN state
        echo "!! ALERT  - `date '+%b %d %Y %H:%M:%S'` !!" >> $ERR_LOG
        echo " $DBNAME is running on $HNAME, but it is not open!" >> $ERR_LOG
        echo "" >> $ERR_LOG
fi
# Test online status of ASM instance
ASM_STATUS=`ps -efl | grep asm_pmon | grep -v "grep asm_pmon"`
if [ -z $ASM_STATUS ]; then
	# ASM instance is offline
        echo "!! ALERT  - `date '+%b %d %Y %H:%M:%S'` !! " >> $ERR_LOG
        echo "ASM instance is offline on ${HNAME}!" >> $ERR_LOG
        echo " " >> $ERR_LOG
else
        echo "`date '+%b %d %Y %H:%M:%S'` -"  >> /tmp/dbstatus.log
        echo "ASM instance is online on $HNAME." >> /tmp/dbstatus.log
fi
# Test online status of listeners
LIST_STATUS=`ps -efl | grep LISTENER | grep -v "grep LISTENER"`
LIST_SCAN_STATUS=`ps -efl | grep LISTENER_SCAN | grep -v "grep LISTENER_SCAN"`
if [ -z $LIST_STATUS ]; then
	# Listeners are offline
        echo " !! ALERT - `date '+%b %d %Y %H%M%S'` !!" >> $ERR_LOG
        echo "There are 0 LISTENERs running on $HNAME!" >> $ERR_LOG
        echo " " >> $ERR_LOG
elif [[  -z $LIST_SCAN_STATUS && $DB_TYPE == "RAC" && $DB_VERSION != "10g" ]]; then
        # SCAN Listeners are offline
        echo " !! ALERT - `date '+%b %d %Y %H%M%S'` !!" >> $ERR_LOG
        echo "SCAN LISTENERS are offline on $HNAME!" >> $ERR_LOG
        echo " " >> $ERR_LOG
else
        echo "`date '+%b %d %Y %H:%M:%S'` - " >> /tmp/dbstatus.log
        echo "LISTENERS are online on $HNAME." >> /tmp/dbstatus.log
fi
# Validate VIP is running on the correct node
if [ $DB_TYPE == "RAC" ]; then
	if [ $DB_VERSION == "10g" ]; then
        	VIP_LOCATION=`$ORACLE_HOME/bin/srvctl status nodeapps -n $HNAME |head -1| awk '{print $6}'`
                if [ $VIP_LOCATION != $HNAME ]; then
                	# VIP is not running on the right machine
                        echo  " !! ALERT - `date '+%b %d %Y %H%M%S'` !!" >> $ERR_LOG
                        echo "The $HNAME VIP is not running on $HNAME!" >> $ERR_LOG
                        $ORACLE_HOME/bin/srvctl status nodeapps -n $HNAME >> $ERR_LOG
                        echo "" >> $ERR_LOG
                else
                        # VIP is running on the right machine
                        echo "`date '+%b %d %Y %H:%M:%S'` - "  >> /tmp/dbstatus.log
                        $ORACLE_HOME/bin/srvctl status nodeapps -n $HNAME >> /tmp/dbstatus.log
                fi
        else
                VIP_LOCATION=`$ORACLE_HOME/bin/srvctl status vip -n $HNAME | tail -1| awk '{print $7}'`
                if [ $VIP_LOCATION != $HNAME ]; then
                        # VIP is not running on the right machine
                        echo  " !! ALERT - `date '+%b %d %Y %H%M%S'` !!" >> $ERR_LOG
                        echo "The $HNAME VIP is not running on $HNAME!" >> $ERR_LOG
                        $ORACLE_HOME/bin/srvctl status vip -n $HNAME >> $ERR_LOG
                        echo "" >> $ERR_LOG
                else
                        # VIP is running on the right machine
                        echo "`date '+%b %d %Y %H:%M:%S'` -" >> /tmp/dbstatus.log
                        $ORACLE_HOME/bin/srvctl status vip -n $HNAME >> /tmp/dbstatus.log
                fi
        fi
else
	echo "VIP is not used because $DBNAME is a standalone database." >> /tmp/dbstatus.log 
fi
if [ -f $ERR_LOG ]; then
        ~/bin/sids.sh >> $ERR_LOG
        echo " " >> $ERR_LOG
        echo "If the outage was not planned, please troubleshoot and bring the resource(s) back online." >> $ERR_LOG        
        echo "Emailed alert to DBAs." >> $ERR_LOG
        cat $ERR_LOG >> /tmp/dbstatus.log
        scp $ERR_LOG <CENTRAL REPOSITORY SERVER>:/tmp/.
        mv $ERR_LOG ~/it_reaches_out/HISTORICAL_CRITICAL_AVAIL_ERR_${DATE_TIME_FM}.err
fi
find ~/it_reaches_out -name "HISTORICAL_CRITICAL*.err" -mtime +548 -exec rm -rf {} \;
scp /tmp/dbstatus.log <CENTRAL REPOSITORY SERVER>:/tmp/.
rm -f /tmp/dbstatus.log
exit
