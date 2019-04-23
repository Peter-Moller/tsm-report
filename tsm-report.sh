#!/bin/bash
#===============================================================
#
# Reporting of daily TSM activities on a client computer.
# Best used with cron to get daily convenience reports.
#
# Based on earlier scripts from pre-2010 developed by Tomas Richter & Peter 
# Möller at the Department of Computer Science at Lund University, Sweden
#
#===============================================================
#
# Signal files:
# * /tmp/TSM_DSMCAD_ERROR_${Today}                  - dsmcad isn't running
# * /tmp/TSM_user_notified_${Today}                 - User has been notified
# * /tmp/dsmsched_sent_home_${Today}_${ClientName}  - the log file has been send home
# All but the last triggers a curl-note to $RemoteURL (= https://fileadmin.cs.lth.se/intern/Backup-klienter/TSM/Mac)
# so that the sys admins may fix it.
#
# Assumption:
# When the script is run by cron, $PATH is only '/usr/bin:/bin'.
# The number of colons in $PATH determines if it's run through 'cron'
# 
# Settings are placed in a separate file (“/etc/tsm-report.settings”)
# 
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
# 
# * Redistributions of source code must retain the above copyright notice, this
#   list of conditions and the following disclaimer.
# 
# * Redistributions in binary form must reproduce the above copyright notice,
#   this list of conditions and the following disclaimer in the documentation
#   and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.



function help ()
{
	echo
	echo "Usage: $0 [-d]"
	echo "-d: debug. Only for the development of the script (debugs into \"/tmp/tsm-report_debug\")"
	echo
	exit 0
}

#===============================================================
# Set some default values
short=f

#===============================================================
# Read options

while getopts ":d" opt; do
	case $opt in
		d ) Debug="t";;
		\?|H ) help;;
	esac
done


###################################################################################
###                      I N I T I A L I Z A T I O N S                          ###
###################################################################################

# COMMANDS (to make sure the correct commands are used)
# Some commands differ between different unixes
AWK=/usr/bin/awk
CRONTAB=/usr/bin/crontab
CURL=/usr/bin/curl
CUT=/usr/bin/cut
[ -x /usr/bin/egrep ] && EGREP=/usr/bin/egrep || EGREP=/bin/egrep
FIND=/usr/bin/find
[ -x /usr/bin/grep ] && GREP=/usr/bin/grep || GREP=/bin/grep
LESS=/usr/bin/less
PGREP=/usr/bin/pgrep
[ -x /usr/bin/ps ] && PS=/usr/bin/ps || PS=/bin/ps
[ -x /usr/bin/rm ] && RM=/usr/bin/rm || RM=/bin/rm
[ -x /usr/bin/sed ] && SED=/usr/bin/sed || SED=/bin/sed
SSH=/usr/bin/ssh
TAIL=/usr/bin/tail
TEE=/usr/bin/tee
TOUCH=/usr/bin/touch


# +------------------------------------------------------------------------+
# |                  Operating System specific settings                    |
# +------------------------------------------------------------------------+

# OS version (either 'Darwin', 'Linux' or 'Windows')
# See a comprehensive list of uname results: https://en.wikipedia.org/wiki/Uname
OS="$(uname -s 2>/dev/null)"
[ -n "$(grep "Microsoft" /proc/version 2>/dev/null)" ] && OS="Windows"

# TSM base values. Must be set manually for Windows and macOS
if [ -z "${OS/Windows/}" ]; then
	TSMDirName="/mnt/c/Program Files/Tivoli/TSM/baclient"
	Dsm_Sys="/mnt/c/Program Files/Tivoli/TSM/baclient/dsm.opt"
	Dsm_Opt="${TSMDirName}/dsm.opt"
	LogFile="/mnt/c/TSM-logs/dsmsched.log"
	ClientName="$(${GREP} -i "NodeName" "$Dsm_Opt" | ${AWK} '{print $2}' | ${SED} 's/\r//g')"
elif [ -z "${OS/Darwin/}" ]; then
	TSMDirName="/Library/Application Support/tivoli/tsm/client/ba/bin"
	Dsm_Opt="/Library/Preferences/Tivoli Storage Manager/dsm.opt"
	Dsm_Sys="${TSMDirName}/dsm.sys"
	LogFile="/Library/Logs/tivoli/tsm/dsmsched.log"
	ClientName="$(${GREP} -i "NodeName" "$Dsm_Sys" | ${AWK} '{print $2}')"
elif [ -z "${OS/Linux/}" ]; then
	#TSMDirName="$(dirname "$(lsof -p $(pgrep dsmcad) 2>/dev/null | ${EGREP} "dsmcad$" | ${EGREP} -o "\/.*$" )")"  # Ex: '/opt/tivoli/tsm/client/ba/bin'
	TSMDirName="/opt/tivoli/tsm/client/ba/bin"
	Dsm_Sys="${TSMDirName}/dsm.sys"
	Dsm_Opt="${TSMDirName}/dsm.opt"
	LogFile="$(${EGREP} "^DSM_LOG=" "$TSMDirName"/rc.dsmcad | cut -d= -f2)/dsmsched.log"
	ClientName="$(${GREP} -i "NodeName" "$Dsm_Sys" | ${AWK} '{print $2}')"
fi


# Some initial values (needed for the launch/quit checks):
TSM_BANNER=""
TSM_TITLE="Backup Message $(date +%Y-%m-%d):"
TSM_Warning=""
TSM_Error=""
success=""
WarningNr="0"
TSM_Critical_Error=""
ReportDir="/TSM/DailyReports"
PayloadDir="${ReportDir/\/DailyReports/}"
TSMCommonError="tsm_common_errors.txt"
DiaryFile="${ReportDir}/TSM_Diary_${ClientName}.txt"
Now="$(date +%s)"  # Ex: now='1552901837'
Today="$(date +%Y-%m-%d)"  # Ex: Today='2019-03-18'
ErrorFileName="${ReportDir}/Errors_${ClientName}_${Today}.txt"
BigFileName="${ReportDir}/Bigfiles_${ClientName}_${Today}.txt"
BackedUpFileName="${ReportDir}/Backed_up_${ClientName}_${Today}.txt"
Warning=""
timestamp=""
DATEFORMAT=""
DebugFile="/tmp/tsm-report_debug_${ClientName}_$(date +%F"_"%T).txt"
#?# RunningConsoleUserID="$(${PS} -ef | ${GREP} "[l]oginwindow console" | ${AWK} '{print $1}')"


# Read the settings
Settingsfile=/etc/tsm-report.settings
PayloadURL=""
SignalURL=""
ReportBackTo=""
AutoUpdate="t"
# Get settings from the settings file:
[ -r "$Settingsfile" ] && source "$Settingsfile"


# +------------------------------------------------------------------------+
# |                        Info about the script                           |
# +------------------------------------------------------------------------+

# Find where the script resides (so updates update the correct version) -- without trailing slash
ScriptDirName="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# What is the name of the script? (without any PATH)
ScriptName="$(basename $0)"
# Is the file writable?
if [ -w "${ScriptDirName}"/"${ScriptName}" ]; then
  ScriptWritable="yes"
else
  ScriptWritable="no"
fi
# Who owns the script?
ScriptOwner="$(ls -ls ${ScriptDirName}/${ScriptName} | awk '{print $4":"$5}')"

# Is it run through 'cron'? If so, $PATH is VERY limited ('/usr/bin:/bin') and that is used to determine that
[ $(echo $PATH | ${EGREP} -o ":" | wc -l) -lt 3 ] && Cron="t" || Cron=""



# +------------------------------------------------------------------------+
# |                            Define colors                               |
# |                                                                        |
# | (Colors can be found at http://en.wikipedia.org/wiki/ANSI_escape_code, |
# | http://graphcomp.com/info/specs/ansi_col.html and other sites)         |
# +------------------------------------------------------------------------+
Reset="\e[0m"
ESC="\e["
RES="0"
BoldFace="1"
ItalicFace="3"
UnderlineFace="4"
SlowBlink="5"
BlackBack="40"
RedBack="41"
YellowBack="43"
BlueBack="44"
WhiteBack="47"
BlackFont="30"
RedFont="31"
GreenFont="32"
YellowFont="33"
BlueFont="34"
CyanFont="36"
WhiteFont="37"
# Reset all colors
BGColor="$RES"
Face="$RES"
FontColor="$RES"


[ "$Debug" = "t" ] && echo "After variable initializations" >> "$DebugFile"


###################################################################################
###                           F U N C T I O N S                                 ###
###################################################################################

function GetFile ()
# Get a file from $RemoteURL (& file.sha1) to /tmp and verifie it's checksum
# Assumes:
#   $1=path for file to fetch, **INCLUDING** a trailing slash
#   $2=filename to fetch
# Returns:
#   ERR=0, all is OK, otherwise something wen't wrong
{
	local PathToFetch=$1
	local FileToFetch=$2
	local RemoteURL=$3
	${CURL} --silent --fail --referer "$ClientName" --output /tmp/"$FileToFetch" "$RemoteURL"/"$PathToFetch""$FileToFetch"
	local ERR1=$?
	${CURL} --silent --fail --referer "$ClientName" --output /tmp/"$FileToFetch".sha1 "$RemoteURL"/"$PathToFetch""$FileToFetch".sha1
	local ERR2=$?
	# If there were any errors, don't do anything further
  	if [ "$ERR1" -ne 0 -o "$ERR2" -ne 0 ]; then
		let ERR="$ERR1"+"$ERR2"
	else
    	# OK, so we got the files, let's verify checksum
	    if [ "$(openssl sha1 /tmp/${FileToFetch} | ${AWK} '{ print $2 }')" = "$(${LESS} /tmp/${FileToFetch}.sha1)" ]; then
    		ERR=0
	    else
    	 	ERR=1
	    fi
  	fi
}


function SendSignal ()
# Send a signal to the apache log file on $RemoteURL
# Assumes:
#   $1=file to "get" with curl
{
	local signal=$1
	local RemoteURL=$2
	${CURL} --silent --fail --referer "$ClientName" --output /dev/null "$RemoteURL"/signals/"$signal" 2>/dev/null
}


function SendHome ()
# if ${SignalURL}/send_home/${ClientName} exists, then send $LogFile home 
# Will only try once per day!
{
	[ "$Debug" = "t" ] && echo "$(date): inside function SendHome, before sending dsmsched home" >> "$DebugFile"

	# Does a SignalURL exist? (If not, there's no need to try to send home)
	# But only send home if the file has not already been sent today
	if [ -n "$SignalURL" -a ! -f "/tmp/dsmsched_sent_home_${Today}_${ClientName}" ]; then
		# Does a signal file exist at the server? If so, the log file needs to be sent home
		if ${CURL} --silent --fail --referer "$ClientName" "${SignalURL}/send_home/${ClientName}"; then
			# Send the file back up, but don't wait more than 10 seconds
			${SSH} -o ConnectTimeout=30 "${ReportBackUser}@${ReportBackTo}" "$(basename "$LogFile")_${ClientName}_${Today}.txt" &> /dev/null < "$LogFile"
			# Did it work? If so, send a signal and create a signal file
			if [ $? -eq 0 ]; then
				SendSignal "send_home_ok" "$SignalURL"
				touch "/tmp/dsmsched_sent_home_${Today}_${ClientName}"
			else
				SendSignal "send_home_not_ok" "$SignalURL"
				touch "/tmp/dsmsched_sent_home_${Today}_${ClientName}"
			fi
		fi
	fi

	[ "$Debug" = "t" ] && echo "$(date): inside function SendHome, after sending dsmsched home" >> "$DebugFile"
}


function GetPayload ()
# Get auxilliary payload
# These files will be placed in "/CS" on the client
# Exit the script if the payload could not be fetched
{
	# Get the payload manifest-file
	GetFile "payload/" "payload.txt" "$PayloadURL"
	# Exit if it failed
	if [ "$ERR" -ne 0 ]; then
		echo "$(date): payload could not be fetched or the checksum was incorrect. Exiting script" >> "$DiaryFile"
		exit 1
	fi

	# Read the manifest and fetch the files one by one
	exec 5</tmp/payload.txt
	while read -u 5 FILE
	do
		# Get the file
		GetFile "payload/" "$FILE" "$PayloadURL"
		if [ "$ERR" -eq 0 ]; then
			# Only move the file to /CS if it differs from one that is already there
			# Note that the diff will be empty if the second file doens't exist *unless* one redirect std err 2 std out!
			# Rename the file so that "_" is replaced by space
			# Also, make a note in the diary
			if [ -n "$(diff /tmp/$FILE "${PayloadDir}/${FILE//_/ }" 2>&1)" ]; then
				chmod 644 /tmp/"$FILE"
				mv /tmp/"$FILE" "${PayloadDir}"/"${FILE//_/ }"
				echo "$(date): the file \"${FILE//_/ }\" was fetched and moved into the \"${PayloadDir}\"-directory" >> "$DiaryFile"
			fi
		fi
	done
}


function SelfUpdate ()
{
	cd "$ScriptDirName"
	# Get the metadata for the repo
	git fetch --all &> /dev/null
	if [ -n "$(git diff --name-only origin/master | grep "$ScriptName")" ]; then
		# Reset the local repo so we are in a consistent state with the server
		git reset --hard origin/master &> /dev/null
		# Get the new version
		git pull --force origin master &> /dev/null
		# Send signal home and say that the update has been performed
		[ -n "$SignalURL" ] && SendSignal "tsmreport_updated" "$SignalURL"
		exit 0
#	else
#		echo "Already the latest version."
	fi
}

[ "$Debug" = "t" ] && echo "After functions" >> "$DebugFile"

###################################################################################
###                      E N D   O F   F U N C T I O N S                        ###
###################################################################################


# +-------------------------------------------------------------------------------+
# |                               Startup checks                                  |
# |         (Should we quit immediately – even if we run from 'cron'?)            |
# +-------------------------------------------------------------------------------+

[ "$Debug" = "t" ] && echo "$(date): Start of basic controls" >> "$DebugFile"

# Quit if running from cron and the user has been notified today. (Saves a load of execution time)
[ -f "/tmp/TSM_user_notified_${ClientName}_${Today}" -a "$Cron" = "t" ] && exit 0

# Exit if more than one instance of this script is running
# (Why this [has to be] "2" instead of "1" is beyond me...)
# (Also, I don't understand why "pgrep -fl $ScriptName" doesn't work)
[ $(ps -ef | egrep "\/bash\ .*\/[t]sm-report.sh" | wc -l) -gt 2 ] && exit 0

# Exit if we cannot read the log file:
if [ ! -r "$LogFile" ]; then
	# Touch the signal file so we don't do this again in 10 minutes, but rather tomorrow
	${TOUCH} "/tmp/TSM_user_notified_${ClientName}_${Today}"
	[ "$Debug" = "t" ] && echo "$(date): exit (no log file)" >> "$DebugFile"
	[ -n "$Cron" ] && exit 1
	echo "The script can't read the log file (\"$LogFile\")! Either:"
	echo "1. The system has just been installed and no logfile has been created yet"
	echo "or"
	echo "2. Something is wrong with the log file"
	echo "Anyhow; you might want to check \"${LogFile}\""
fi

# Check and create $ReportDir if not already there
if [ ! -d "$ReportDir" ]; then
	if ! mkdir -p "$ReportDir" 2>/dev/null; then
		# Touch the signal file so we don't do this again in 10 minutes, but rather tomorrow
		${TOUCH} "/tmp/TSM_user_notified_${ClientName}_${Today}"
		[ -n "$SignalURL" ] && SendSignal "no_report_dir" "$SignalURL"
		# Warn if we aren't run from cron and exit if we are (it's no use to continue if we can't do what this script exists to do)
		[ -z "$Cron" ] && printf "Could not create \"$ReportDir\".\nReports will not be created.\n" || exit 1
	fi
fi

# Check date formatting (quit if not OK)
if [ ! "$(${GREP} DATEFORMAT "$Dsm_Opt" | ${AWK} '{print $2}')" = "3" ]; then
	[ -n "$SignalURL" ] && SendSignal "wrong_dateformat" "$SignalURL"
	# Touch the signal file so we don't do this again in 10 minutes, but rather tomorrow
	${TOUCH} "/tmp/TSM_user_notified_${ClientName}_${Today}"
	[ -z "$Cron" ] && echo "Wrong date format: \"DATEFORMAT\" in \"${Dsm_Opt}\" is not set to \"3\"!"
	[ -z "$Cron" ] && echo "Script will now quit"
	exit 1
fi

# Check to see if the logfile is short (to avoid this script just hanging)
if [ -z "$(${GREP} ' --- SCHEDULEREC STATUS END' $LogFile)" ]; then
	if [ -z "$Cron" ]; then
		echo "The log file is too short to give any useful information."
		echo "it has probably been truncated or just been started."
		echo "Look at \"${LogFile}\" if you are qurious"
	fi
	[ "$Debug" = "t" ] && echo "$(date): exit (too short log file)" >> "$DebugFile"
	exit 0
fi

# See if dsmcad is not running and no signalfile has been produced
# Send a signal to the server and make a note of it in the DiaryFile
# We do not, however, restart the dsmcad (since some people want it to be off)
if [ -z "$(${PGREP} dsmcad 2>/dev/null)" -a ! -f "/tmp/TSM_DSMCAD_ERROR_${Today}" ]; then
	TSM_Critical_Error="The backup software (\"dsmcad\") is not running\!\! You should inform your technical support team of this as soon as possible\! ($(date))"
	# Send a signal that the dsmcad isn't running
	[ -n "$SignalURL" ] && SendSignal "dsmcad_not_running" "$SignalURL"
	#echo "$(date): \"dsmcad\" is not running. This is serious. Attempting to restart."  >> "$DiaryFile"
	${TOUCH} "/tmp/TSM_DSMCAD_ERROR_${Today}"
	echo "$(date): \"dsmcad\" not running"  >> "$DiaryFile"
fi

[ "$Debug" = "t" ] && echo "$(date): End of basic controls" >> "$DebugFile"


################################################################################################################
###                              B E G I N N I N G   O F   T H E   S C R I P T                               ###
################################################################################################################

[ "$Debug" = "t" ] && echo "$(date): start of script" >> "$DebugFile"

# If the script is older than 7 days, update it and also get the latest payload
if [ -n "$(${FIND} ${ScriptDirName}/${ScriptName} -type f -mtime +7d 2> /dev/null)" ]; then
	# But only report if AutoUpdate = "t"
	if [ "$AutoUpdate" = "t" ]; then
		# Display warning if we are interactive
		[ -z "$Cron" ] && echo "The script is too old, updating"
		# If there is a payload, get it
		[ -n "$PayloadURL" ] && GetPayload
		SelfUpdate
	fi
fi

# See if we should send the log file home
SendHome

# Grab the relevant lines between 'SCHEDULEREC STATUS BEGIN' and 'Scheduled event':
TodaysResult="$(${EGREP} "^$Today" "$LogFile" | awk '/SCHEDULEREC STATUS BEGIN/{a=1}/ Session established with server /{print;a=0}a')"
# This gives:
# 2019-03-26 02:53:59 Session established with server TSM3: Linux/x86_64
# 2019-03-26 03:07:11 --- SCHEDULEREC STATUS BEGIN
# 2019-03-26 03:07:11 Total number of objects inspected:    3,220,562
# 2019-03-26 03:07:11 Total number of objects backed up:          418     <--- Interesting!
# 2019-03-26 03:07:11 Total number of objects updated:            208
# 2019-03-26 03:07:11 Total number of objects rebound:              0
# 2019-03-26 03:07:11 Total number of objects deleted:              0
# 2019-03-26 03:07:11 Total number of objects expired:            296
# 2019-03-26 03:07:11 Total number of objects failed:               2     <---  Interesting!
# 2019-03-26 03:07:11 Total number of objects encrypted:            0
# 2019-03-26 03:07:11 Total number of objects grew:                 0
# 2019-03-26 03:07:11 Total number of retries:                      1
# 2019-03-26 03:07:11 Total number of bytes inspected:           4.51 TB
# 2019-03-26 03:07:11 Total number of bytes transferred:       155.34 MB  <--- Interesting!
# 2019-03-26 03:07:11 Data transfer time:                        1.08 sec
# 2019-03-26 03:07:11 Network data transfer rate:          147,046.32 KB/sec
# 2019-03-26 03:07:11 Aggregate data transfer rate:            200.83 KB/sec
# 2019-03-26 03:07:11 Objects compressed by:                        0%
# 2019-03-26 03:07:11 Total data reduction ratio:              100.00%
# 2019-03-26 03:07:11 Elapsed processing time:               00:13:12     <--- Interesting!
# 2019-03-26 03:07:11 --- SCHEDULEREC STATUS END
# 2019-03-26 03:07:11 --- SCHEDULEREC OBJECT END DAILY_MACSERVERS 2019-03-26 02:00:00
# 2019-03-26 03:07:11 Scheduled event 'DAILY_MACSERVERS' completed successfully.
# 2019-03-26 03:07:11 Sending results for scheduled event 'DAILY_MACSERVERS'.
# 2019-03-26 03:07:11 Results sent to server for scheduled event 'DAILY_MACSERVERS'.
# 2019-03-26 03:07:11 ANS1483I Schedule log pruning started.
# 2019-03-26 03:07:11 ANS1484I Schedule log pruning finished successfully.
# 2019-03-26 03:07:11 TSM Backup-Archive Client Version 7, Release 1, Level 2.0  
# 2019-03-26 03:07:11 Querying server for next scheduled event.
# 2019-03-26 03:07:11 Node Name: LAGRING2
# 2019-03-26 03:07:11 Session established with server TSM3: Linux/x86_64

# Note: somtimes we get the infamous 'Return code = 12':
# 2019-03-20 02:29:05 ANS1512E Scheduled event 'DAILY_MACSERVERS' failed.  Return code = 12.

# What TSM-server are we running against?
TSM_Server="$(echo "$TodaysResult" | ${GREP} "Session established with server" | awk '{print $7}' | cut -d: -f1 | head -1)"

# Has the backup run today and concluded?
if [ -n "$(echo "$TodaysResult" | grep " Scheduled event ")" ]; then
	# Yes: dig out the data
	[ "$Debug" = "t" ] && echo "$(date): successful backup today: digging out the data from the log file" >> "$DebugFile"

	success="$(echo "$TodaysResult" | ${GREP} ' --- SCHEDULEREC STATUS END')"
	# success='2013-12-03 09:02:29 --- SCHEDULEREC STATUS END'
	# Get data for the latest backup
	success_date="$(echo $success | ${AWK} '{ print $1 }')"
	# Gives: success_date=2013-12-03
	success_time="$(echo $success | ${AWK} '{ print $2 }')"
	# success_time=09:02:29
	
	# Get the number of different objects:
	failures="$(echo "$TodaysResult" | ${EGREP} 'Total number of objects failed' | ${AWK} '{ print $8" "$9" "$10 }' | sed 's/\ *$//g')"
	BackedUpFiles="$(echo "$TodaysResult" | ${GREP} 'Total number of objects backed up' | ${AWK} '{ print $9" "$10" "$11 }' | sed 's/\ *$//g')"
	BackedUpVolume="$(echo "$TodaysResult" | ${GREP} 'Total number of bytes transferred' | ${AWK} '{ print $8" "$9 }')"
	BackedUpTime="$(echo "$TodaysResult" | ${GREP} 'Elapsed processing time' | ${AWK} '{ print $6 }')"
else
	[ "$Debug" = "t" ] && echo "$(date): successful backup today: digging out the data from the log file" >> "$DebugFile"

	LastResult="$(${GREP} -B 22 'completed successfully.$' $LogFile | ${TAIL} -22)"
	success_date="$(echo "$LastResult" | ${GREP} 'completed successfully.$' | ${TAIL} -1 | ${AWK} '{ print $1 }')"
	# Gives: success_date=2013-12-04
	success_time="$(echo "$LastResult" | ${GREP} 'completed successfully.$' | ${TAIL} -1 | ${AWK} '{ print $2 }')"
	# success_time=09:02:29

	# Get the number of different objects:
	failures="$(echo "$LastResult" | ${EGREP} 'Total number of objects failed' | ${AWK} '{ print $8" "$9" "$10 }' | sed 's/\ *$//g')"
	BackedUpFiles="$(echo "$LastResult" | ${GREP} 'Total number of objects backed up' | ${AWK} '{ print $9" "$10" "$11 }' | sed 's/\ *$//g')"
	BackedUpVolume="$(echo "$LastResult" | ${GREP} 'Total number of bytes transferred' | ${AWK} '{ print $8" "$9 }')"
	BackedUpTime="$(echo "$LastResult" | ${GREP} 'Elapsed processing time' | ${AWK} '{ print $6 }')"

	#Set warning flag
	Warning="t"

	# Look for >5 of the infamous ANS1029E/ANS1017E messages and create warning message accordingly
	# However, ignore error messages during the night (when there is no scheduler) from houres 01, 02, 03, 04, 05, 06.
	# TSM_Warning≠"" constitutes a REAL failure that should be alerted!
	if [ "$(${GREP} "$Today" "$LogFile" 2>/dev/null | ${EGREP} 'ANS1029E Communication with the  TSM server is lost' | ${GREP} -v " 0[123456]:" | wc -l | ${AWK} '{ print $1 }')" -gt 5 ]; then
		TSM_Warning="W A R N I N G:  Communication with the TSM-server \"$TSM_Server\" cannot be established. Contact the system administrator\!\!\!\!\!\!\!"
	fi
	if [ "$(${GREP} "$Today" "$LogFile" 2>/dev/null | ${EGREP} 'ANS1017E Session rejected: TCP/IP connection failure' | ${GREP} -v " 0[123456]:" | wc -l | ${AWK} '{ print $1 }')" -gt 5 ]; then
		TSM_Warning="W A R N I N G:  The TSM-server \"$TSM_Server\" cannot be contacted (may be down?). Contact the system administrator\!\!\!\!\!\!\!"
	fi
	# Also, look for ANS1311E (Server out of data storage space)
	if [ "$(${GREP} "$Today" "$LogFile" 2>/dev/null | ${EGREP} 'ANS1311E')" ]; then
		TSM_Warning="W A R N I N G:  The TSM-server \"$TSM_Server\" is out of space! Contact the system administrator\!\!\!\!\!\!\!"
	fi
fi

[ "$Debug" = "t" ] && echo "$(date): after digging out data in the log file" >> "$DebugFile"


################################################################################################################
###                                       R E P O R T   S E C T  I O N                                       ###
################################################################################################################

# Set the timestamp
[ "$timestamp" = "t" ] && TSM_BANNER="$(date): " || TSM_BANNER=""

# Create the message
if [ "$Warning" = "t" ]; then
	BackupMessage="${TSM_BANNER}W_A_R_N_I_N_G: last successful TSM-backup with \"$TSM_Server\" was $success_date. $TSM_Warning"
elif [ "$short" = "t" ] ; then
	BackupMessage="${TSM_BANNER}Backup Successful" ;
elif [ "$short" = "f" ]; then 
	BackupMessage="${TSM_BANNER}$BackedUpFiles files backed up by server \"$TSM_Server\". $BackedUpVolume was transferred in $BackedUpTime"
fi

# Add warning, if any
if [ ! "$failures" = "0" ]; then
	BackupMessage="$BackupMessage. However, $failures object(s) failed. Check the loggfile ($LogFile)"
fi

### +--------------------------------------------------------+
### Interactive report
[ "$Debug" = "t" ] && echo "$(date): Start of Interactive report" >> "$DebugFile"

# If we are not running from cron, present an interactive report end the exit
if [ -z "$Cron" ]; then

	# Do some basic checks before starting the presentation
	# Check that $ReportDir exists and is writable
	[ -w "$ReportDir" ] || echo "Report directory (\"$ReportDir\") not writeable!"
	# Check that the report script runs periodically
	CronCommand="$(${CRONTAB} -l | ${EGREP} "${ScriptName}" | sed -e 's/^\([^ ]* \)\{5\}//')"  # CronCommand='/usr/local/bin/tsm-report.sh'
	# Is the script correctly set up to work through 'cron'?
	if [ ! "$CronCommand" = "${ScriptDirName}/${ScriptName}" -a ! "$(readlink "$CronCommand")" = "${ScriptDirName}/${ScriptName}" ]; then
		printf "The script (\"${ScriptDirName}/${ScriptName}\") is not set up to run periodically through \"crontab\" — at least not as the current user.\nYou should see to this!\n\n"
	fi
	# Is dsmcad not running? Warn if so. (Not on Windows since we cannot see the processes on Windows)
	[ ! "$OS" = "Windows" -a -z "$(pgrep dsmcad)" ] && printf "${ESC}${RedBack};${YellowFont}m\"dsmcad\" is not running! Backup will not run and this is BAD...${Reset}\n\n"

	# Print header for the report
	printf "${ESC}${BlackBack};${WhiteFont}mBackup report for:${Reset}${ESC}${WhiteBack};${BlackFont}m $(uname -n) ${Reset}   ${ESC}${BlackBack};${WhiteFont}mTSM-server:${ESC}${WhiteBack};${BlackFont}m $TSM_Server ${Reset}   ${ESC}${BlackBack};${WhiteFont}mDate & time:${ESC}${WhiteBack};${BlackFont}m $(date +%F", "%R) ${Reset}\n"

	# If there is a Critical Error, display it
	if [ -n "$TSM_Critical_Error" ]; then
		printf "${ESC}${RedFont}mCRITICAL ERROR: $TSM_Critical_Error${Reset}\n"
	fi
	if [ "$Warning" = "t" ]; then
		echo "W A R N I N G:  last successful TSM-backup was $success_date at $success_time"
		echo "$TSM_Warning"
	else
		echo "Date of last backup: ${success_date/$Today/today} at $success_time"
	fi

	# Did the backup succeed?
	if [ -n "$(echo "$TodaysResult" | ${EGREP} "Scheduled event.* completed successfully")" ]; then
		printf "${ESC}${GreenFont}mStatus: Backup completed successfully${Reset}\n"
	else
		printf "${ESC}${RedFont}mStatus: Backup did NOT complete successfully. $(echo "$TodaysResult" | grep " Scheduled event " | cut -d. -f2 | sed 's/^\ *//g')${Reset}\n"
	fi
	echo "Files backed up: $BackedUpFiles"
	echo "Volume transferred: $BackedUpVolume"
	echo "Time it took to back up: $BackedUpTime"
	if [ ! "$failures" = "0" ]; then
		#Get the number of errors
		ANSE="$(${EGREP} "$Today" "$LogFile" | ${EGREP} -o "ANS[0-9]{4}E" | ${EGREP} -v "ANS1512E" | wc -l)"
		echo
		echo "The following ${ANSE// /} errors were encountered:"
		printf "${ESC}${BoldFace}m%4s%-9s%-30s${Reset}\n" "#" " Error" " Explanation"
		# Get the list of errors:
		ErrorList="$(${EGREP} "$Today" "$LogFile" | ${EGREP} -o "ANS[0-9]{4}E" | ${EGREP} -v "ANS1512E" | sort | uniq -c)"
		# Ex: ErrorList='  20 ANS1228E
	    #   1 ANS1802E
	    #   2 ANS4005E
	    #  15 ANS4007E'
	    echo "$ErrorList" | while read -r Num Error
	    do
	    	TSMError="$(grep "^#${Error}_" "$TSMCommonError" | cut -d_ -f2)"
	    	printf "%4s%-9s%-30s\n" "$Num" " ${Error}" " $TSMError"
	    done
	    printf "${ESC}${ItalicFace}m%40s${Reset}\n" "Look at the error-log file ($ErrorFileName) for details!"
	else
		echo "No errors were encountered."
	fi


	# Additional errors
	if [[ $WarningNr -ne 0 ]]; then
		echo "Additional error[s]:"
		for ((i = 1; i <= "$WarningNr"; i += 1))
		do
			echo "${TSM_Error[$i]}"
		done
	fi

	[ "$Debug" = "t" ] && echo "$(date): exit (at the end of the interaktive report)" >> "$DebugFile"

	exit 0
fi
### End of interactive report
### +--------------------------------------------------------+

[ "$Debug" = "t" ] && echo "$(date): After the Interactive report" >> "$DebugFile"

[ "$Debug" = "t" ] && echo "$(date): before check of no success and no warning" >> "$DebugFile"

# No success and no warning .: TSM has not run today so there is nothing to report (yet)!!
# Just exit
if [ -z "$success" -a -z "$TSM_Warning" ]; then
	[ "$Debug" = "t" ] && echo "$(date): exit (no backup and no errors)" >> "$DebugFile"
	exit 0
fi

[ "$Debug" = "t" ] && echo "$(date): before display of normal message" >> "$DebugFile"

# If we have not exited before coming here, it must mean that we have something to report. Either:
# - success
# - TSM_Warning
# is NOT empty! Let's report that!

# If dsmcad isn't running, make a special note about that
if [ -n "$TSM_Critical_Error" ]; then
	# Make a note with growlnotify (it it's set)
	[ -n "$GrowlNotify" ] && ${GrowlNotify} -t "TSM Backup CRITICAL ERROR" -n tsm -m "$TSM_Critical_Error" "$GrowlSticky" 2>/dev/null
	echo "$(date): TSM_Critical_Error" >> "$DiaryFile"
fi

# Display the normal BackupMessage with growlnotify (if it's set)
[ -n "$GrowlNotify" ] && ${GrowlNotify}  -t "$TSM_TITLE" -n tsm -m "$BackupMessage" "$GrowlSticky" 2>/dev/null ;
# Add it to the DiaryFile:
echo "$(date): \"$BackupMessage\"" >> "$DiaryFile"


### End of primary report
### +--------------------------------------------------------+


### +--------------------------------------------------------+
### Create files in $ReportDir for the convenience of the end user

# Create a file with all file from todays backup
${GREP} "^$Today" "$LogFile" > "$BackedUpFileName"

# Create a file with backuped up all files larger that 10 MB in!
${EGREP} ' Normal File-->' "$BackedUpFileName" | perl -ne 'while(<>) { print "$_" if /(?!\s)(\d+[, ]?)*\d?\d{2}[, ]\d{3}[, ]\d{3}(?=\s)/g }' > "$BigFileName"
# But remove bigfiles if file size = 0
[ -s "$BigFileName" ] || rm -f "$BigFileName" 2> /dev/null

# Create a file that contains the Errors from todays execution
${GREP} "^$Today" "$BackedUpFileName" | ${EGREP} " ANS[0-9]{4}E " > "$ErrorFileName"
# But remove error file if size = 0
[ -s "$ErrorFileName" ] || rm -f "$ErrorFileName" 2> /dev/null


### End of “convenience-reporting”
### +--------------------------------------------------------+

[ "$Debug" = "t" ] && echo "$(date): before house-keeping of log files" >> "$DebugFile"

################################################################################################################
### H O U S E K E E P I N G
################################################################################################################
  
# House keeping: remove old report files
# Remove Backup reports that are older than 30 days
${FIND} "$ReportDir" -name 'Backed_up_*' -type f -mtime +30d -exec rm -f {} \;
# clean out BigFiles that are older than 30 days
${FIND} "$ReportDir" -name 'Bigfiles_*' -type f -mtime +30d -exec rm -f {} \;
# clean out Errors that are older than 30 days
${FIND} "$ReportDir" -name 'Errors_*' -type f -mtime +30d -exec rm -f {} \;


# Remove the old signal file and create a new one
rm -f "/tmp/TSM_user_notified_${ClientName}_201[0-9]-[0-9-]*" 2>/dev/null
${TOUCH} "/tmp/TSM_user_notified_${ClientName}_${Today}"
#?# # Set owner of all signal files to be the user running the console (and if none, user 501)
#?# /usr/sbin/chown "${RunningConsoleUserID:-501}":staff "/tmp/tsm_*" 2>/dev/null

[ "$Debug" = "t" ] && echo "$(date): (end of script)" >> "$DebugFile"
exit 0