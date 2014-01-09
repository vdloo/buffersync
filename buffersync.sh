#!/usr/bin/env bash
VERBOSE=$1

#Directory that will be encrypted and transfered
ENCRYPTTARGET="~"
ENCRYPTTARGET=`eval echo $ENCRYPTTARGET`
#Directory where the splitted encrypted archives will be stored before transfer
KEYFILE="~/.ssh/id_rsa.crt"
KEYFILE=`eval echo $KEYFILE`

#Size of parts
SPLITSIZE="1m"
PARTSDIR="~/Downloads/backuptemp"
PARTSDIR=`eval echo $PARTSDIR`

#Threshold of space left in dir to pause the archiving process (kilobytes)
SPACELEFTTHRESHOLD="512000" #approx 500M
MINSTARTSPACE="512000"      #approx 500M

function archive(){
	echo "encrypting directory $ENCRYPTTARGET";
	tar --exclude '$PARTSDIR/*' --exclude '$PARTSDIR' --ignore-failed -cpj $ENCRYPTTARGET 2> /dev/null | openssl aes-256-cbc -kfile $KEYFILE | split -d -b $SPLITSIZE - $PARTSDIR/$(date "+%Y%m%d-%s").tar.bz2.enc.;
	echo "finished encrypting $ENCRYPTTARGET"
}


function sync1() {
	if [[ "$VERBOSE" == "-v" ]]; then
		echo "start sync1"
	fi;
	COUNTLOCKS1="find \"$PARTSDIR\" -type f -name "*flock1" 2> /dev/null | wc -l"
	LOCKS1COUNT=$(eval $COUNTLOCKS1)
	while [[ "$LOCKS1COUNT" -gt 0 ]]; do
		NEXTLOCK1=`find "$PARTSDIR" -type f -name "*flock1" 2> /dev/null | sort | head -n 1`
		if [[ $( echo $NEXTLOCK1 | wc -c ) -gt 0 ]]; then
			PART1=$( echo $NEXTLOCK1 | sed -e 's/.flock.*//' )
			echo "syncing $PART1 to USB"
			sleep 10 ##Simulate slow connection
			rsync -tuq --modify-window=1 $PART1 /mnt/usb && rm $NEXTLOCK1 2> /dev/null
		fi;
		LOCKS1COUNT=$(eval $COUNTLOCKS1)
	done;
	rm -rf "$PARTSDIR/sync1.plock"
}

function sync2() {
	if [[ "$VERBOSE" == "-v" ]]; then
		echo "start sync2"
	fi;
	COUNTLOCKS2="find \"$PARTSDIR\" -type f -name "*flock2" 2> /dev/null | wc -l"
	LOCKS2COUNT=$(eval $COUNTLOCKS2)
	while [[ "$LOCKS2COUNT" -gt 0 ]]; do
		NEXTLOCK2=`find "$PARTSDIR" -type f -name "*flock2" 2> /dev/null | sort | head -n 1`
		if [[ $( echo $NEXTLOCK2 | wc -c ) -gt 0 ]]; then
			PART2=$( echo $NEXTLOCK2 | sed -e 's/.flock.*//' )
			echo "syncing $PART2 to OASIS"
			rsync -azq $PART2 OASIS:/mnt/lvmdisk/backup 2> /dev/null && rm $NEXTLOCK2 2> /dev/null
		fi;
		LOCKS2COUNT=$(eval $COUNTLOCKS2)
	done;
	rm -rf "$PARTSDIR/sync2.plock"
}

function sync3() {
	if [[ "$VERBOSE" == "-v" ]]; then
		echo "start sync3"
	fi;
	COUNTLOCKS3="find \"$PARTSDIR\" -type f -name "*flock3" 2> /dev/null | wc -l"
	LOCKS3COUNT=$(eval $COUNTLOCKS3)
	while [[ "$LOCKS3COUNT" -gt 0 ]]; do
		NEXTLOCK3=`find "$PARTSDIR" -type f -name "*flock3" 2> /dev/null | sort | head -n 1`
		if [[ $( echo $NEXTLOCK3 | wc -c ) -gt 0 ]]; then
			PART3=$( echo $NEXTLOCK3 | sed -e 's/.flock.*//' )
			echo "syncing $PART3 to Beest"
			rsync -avq $PART3 Beest:/volume3/RAID1/backup 2> /dev/null && rm $NEXTLOCK3 2> /dev/null
		fi;
		LOCKS3COUNT=$(eval $COUNTLOCKS3)
	done;
	rm -rf "$PARTSDIR/sync3.plock"
}

function freespacelock() {
	#Checks if we want to pause the archiving until there is enough space available
	SPACELEFT=$(df -k $PARTSDIR | awk 'END{print $(NF-2)}')
	if [[ $SPACELEFT -lt $SPACELEFTTHRESHOLD ]]; then
		if [[ "$VERBOSE" == "-v" ]]; then
			echo "space left is below threshold $SPACELEFT/$SPACELEFTTHRESHOLD"
		fi;
		if [ ! -d "$PARTSDIR/archive.plock" ]; then
			#Pauses archiving process chain (like ^z)
			echo "pausing chain ($SPACELEFT available, need $SPACELEFTTHRESHOLD)";
			mkdir $PARTSDIR/archive.plock 2> /dev/null;
			for childprocess in $(ps -o pid --ppid $WAITPID | tail -n +2); do kill -TSTP $childprocess; done
		fi;
	else
		if [[ "$VERBOSE" == "-v" ]]; then
			echo "space left is adequate $SPACELEFT/$SPACELEFTTHRESHOLD"
		fi;
		if [ -d "$PARTSDIR/archive.plock" ]; then
			#Continues archiving process chain (like fg)
			echo "coninuing chain ($SPACELEFT available)";
			rm -rf "$PARTSDIR/archive.plock" 2> /dev/null;
			for childprocess in $(ps -o pid --ppid $WAITPID | tail -n +2); do kill -CONT $childprocess; done
		fi;
	fi;
}


#Callback for the black hole handler
function process_file() {
	touch $1.flock1 $1.flock2 $1.flock3
}

#Callback that persists every iteration of the black hole while loop
function process_pool() {
	freespacelock

	if ! mkdir $PARTSDIR/sync1.plock 2> /dev/null ; then
		if [[ "$VERBOSE" == "-v" ]]; then
			echo "sync 1 in progress.."
		fi;
	else
		if [[ "$VERBOSE" == "-v" ]]; then
			echo "starting new sync1"
		fi;
		sync1 &
	fi;

	if ! mkdir $PARTSDIR/sync2.plock 2> /dev/null ; then
		if [[ "$VERBOSE" == "-v" ]]; then
			echo "sync 2 in progress.."
		fi;
	else
		if [[ "$VERBOSE" == "-v" ]]; then
			echo "starting new sync2"
		fi;
		sync2 &
	fi;

	if ! mkdir $PARTSDIR/sync3.plock 2> /dev/null ; then
		if [[ "$VERBOSE" == "-v" ]]; then
			echo "sync 3 in progress.."
		fi;
	else
		if [[ "$VERBOSE" == "-v" ]]; then
			echo "starting new sync3"
		fi;
		sync3 &
	fi;

	LOCKSLEFT=`find "$PARTSDIR" -type f -name "*flock0" 2> /dev/null | wc -l`
	if [[ $LOCKSLEFT -gt 0 ]]; then
		if [[ "$VERBOSE" == "-v" ]]; then
			echo "starting process pool"
		fi;
		#See if there are processed files waiting to be deleted, then delete those files
		COUNTPROCESSED="find \"$PARTSDIR\" -type f -name "*flock*" 2> /dev/null | sort | sed -e 's/.flock.*//' | uniq -u | wc -l"
		PROCESSEDCOUNT=$(eval $COUNTPROCESSED)
		while [ $PROCESSEDCOUNT -gt 0 ]; do
			PROCESSED=`find "$PARTSDIR" -type f -name "*flock*" 2> /dev/null | sort | sed -e 's/.flock.*//' | uniq -u | head -n 1 | sed -e 's/\.\///g'`
			if [ $( echo $PROCESSED | wc -c ) -gt 0 ]; then
				if [[ "$VERBOSE" == "-v" ]]; then
					echo "now deleting $PROCESSED"
				fi;
				rm "${PROCESSED}.flock0" "$PROCESSED" 2>/dev/null
			fi;
			PROCESSEDCOUNT=$(eval $COUNTPROCESSED)
			if [ -d "$PARTSDIR/archive.plock" ]; then
				sleep 1
			fi;
		done;
		if [[ "$VERBOSE" == "-v" ]]; then
			echo "end process pool"
		fi;
	fi;
	rm -rf "$PARTSDIR/outer.plock"
}

#This function checks if there are files in the tempdir, and if so then processes them
function blackhole_handler() {
	freespacelock
	TEMPDIR="$1"
	CALLBACKFUNCINNER="$2"
	CALLBACKFUNCOUTER="$3"
	SCANDELAY=$4

	BYTECOUNT_PREV=0
	CLEAR_FLIP=0
	#Find parts that aren't already marked with a lock
	COUNTFILES="find \"$PARTSDIR\" -type f 2> /dev/null | sort | sed -e 's/.flock.*//' | uniq -u | wc -l"
	FILECOUNT=$(eval $COUNTFILES)


	#Loop if there are files left to process
	while [ $FILECOUNT -gt 0 ]; do
		freespacelock

		PATH_CURRENT=`find "$PARTSDIR" -type f 2> /dev/null | sort | sed -e 's/.flock.*//' | sort | uniq -u | head -n 1 | sed -e 's/\.\///g'`
		if [[ $FILECOUNT -gt 1 || $CLEAR_FLIP -eq 1 ]] && [[ ! -d "$PARTSDIR/archive.plock" ]]; then
			BYTECOUNT_PREV=0
			CLEAR_FLIP=0
			touch $PATH_CURRENT.flock0
			eval $CALLBACKFUNCINNER "$PATH_CURRENT"
		else
			#Count the amount of bytes in the current file
			BYTECOUNT_CURRENT=$(cat $PATH_CURRENT | wc -c)
			if [[ "$VERBOSE" == "-v" ]]; then
				echo "bytecount current is $BYTECOUNT_CURRENT"
				echo "bytecount previous is $BYTECOUNT_PREV"
			fi;

			#Check if the current file is still being written to
			if [[ $BYTECOUNT_CURRENT -gt $BYTECOUNT_PREV || $BYTECOUNT_CURRENT -eq 0 ]]; then
				#Save bytecount for next iteration and wait before checking again
				BYTECOUNT_PREV=$BYTECOUNT_CURRENT
				sleep $SCANDELAY
			else
				#Tell the next iteration to process the file
				CLEAR_FLIP=1
			fi
		fi

		if ! mkdir $PARTSDIR/outer.plock 2> /dev/null ; then
			if [[ "$VERBOSE" == "-v" ]]; then
				echo "sync in progress"
			fi;
		else
			(eval $CALLBACKFUNCOUTER &) #Parenthesis because running this command in a subshell will prevent the [pid] done output
		fi;

		FILECOUNT=$(eval $COUNTFILES)
		if [ -d "$PARTSDIR/archive.plock" ]; then
			sleep $WAITDELAY
		fi;
	done
}

#Execute and loop a command while another command runs in the background
function wait_while(){
	WAITFUNC="$1"
	LOOPFUNC="$2"
	WAITDELAY="$3"
	archive &
	WAITPID=$!
	while ps -p $WAITPID > /dev/null || [ -d "$PARTSDIR/archive.plock" ] ; do 
		if [[ "$VERBOSE" == "-v" ]]; then
			echo "archive not finished yet, continuing with the callback loop";
		fi;
		eval $LOOPFUNC
		sleep $WAITDELAY
	done
}

PARTSDIR=`eval echo $PARTSDIR`
if [[ "$VERBOSE" == "-v" ]]; then
	echo "partsdir is $PARTSDIR";
fi;
mkdir -p $PARTSDIR
SPACELEFT=$(df -k $PARTSDIR | awk 'END{print $(NF-2)}')
if [[ $SPACELEFT -gt $MINSTARTSPACE ]]; then
	rm -R $PARTSDIR/*plock 2> /dev/null

	#Initialize the pool handler
	SYNCBLACKHOLE="blackhole_handler $PARTSDIR process_file process_pool 10"
	wait_while "$ENCRYPTDIR" "$SYNCBLACKHOLE" 1; echo "now waiting for synchronization pool to be emptied"; wait && rm -R $PARTSDIR
	echo "done synchronizing"
else
	echo "drive it too full to start archiving (${SPACELEFT}k left need ${MINSTARTSPACE}k)";
fi;
