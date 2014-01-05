#!/usr/bin/env bash
VERBOSE=$1

#Directory that will be encrypted and transfered
ENCRYPTTARGET="~"
#Directory where the splitted encrypted archives will be stored before transfer
KEYFILE="~/.ssh/id_rsa.crt"

#Size of parts
SPLITSIZE="50m"
PARTSDIR="~/Downloads/backuptemp"

ENCRYPTDIR="echo \"Encrypting directory ${ENCRYPTTARGET}\";tar --ignore-failed -cpj $ENCRYPTTARGET 2>/dev/null | openssl aes-256-cbc -kfile $KEYFILE | split -d -b $SPLITSIZE - $PARTSDIR/$(date "+%Y%m%d-%s").tar.bz2.enc.; echo \"Finished encrypting $ENCRYPTTARGET\""

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
			echo "Syncing $PART1 to USB"
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
			echo "Syncing $PART2 to OASIS"
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
			echo "Syncing $PART3 to Beest"
			rsync -avq $PART3 Beest:/volume3/RAID1/backup 2> /dev/null && rm $NEXTLOCK3 2> /dev/null
		fi;
		LOCKS3COUNT=$(eval $COUNTLOCKS3)
	done;
	rm -rf "$PARTSDIR/sync3.plock"
}

#Callback for the black hole handler
function process_file() {
	touch $1.flock1 $1.flock2 $1.flock3
}

#Callback that persists every iteration of the black hole while loop
function process_pool() {
	if ! mkdir $PARTSDIR/sync1.plock 2> /dev/null ; then
		if [[ "$VERBOSE" == "-v" ]]; then
			echo "Sync 1 in progress.."
		fi;
	else
		if [[ "$VERBOSE" == "-v" ]]; then
			echo "Starting new sync1"
		fi;
		sync1 &
	fi;

	if ! mkdir $PARTSDIR/sync2.plock 2> /dev/null ; then
		if [[ "$VERBOSE" == "-v" ]]; then
			echo "Sync 2 in progress.."
		fi;
	else
		if [[ "$VERBOSE" == "-v" ]]; then
			echo "Starting new sync2"
		fi;
		sync2 &
	fi;

	if ! mkdir $PARTSDIR/sync3.plock 2> /dev/null ; then
		if [[ "$VERBOSE" == "-v" ]]; then
			echo "Sync 3 in progress.."
		fi;
	else
		if [[ "$VERBOSE" == "-v" ]]; then
			echo "Starting new sync3"
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
		done;
		if [[ "$VERBOSE" == "-v" ]]; then
			echo "end process pool"
		fi;
	fi;
	rm -rf "$PARTSDIR/outer.plock"
}

#This function checks if there are files in the tempdir, and if so then processes them
function blackhole_handler() {
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
		PATH_CURRENT=`find "$PARTSDIR" -type f 2> /dev/null | sort | sed -e 's/.flock.*//' | sort | uniq -u | head -n 1 | sed -e 's/\.\///g'`
		if [[ $FILECOUNT -gt 1 || $CLEAR_FLIP -eq 1 ]]; then
			BYTECOUNT_PREV=0
			CLEAR_FLIP=0
			touch $PATH_CURRENT.flock0
			eval $CALLBACKFUNCINNER "$PATH_CURRENT"
		else
			#Count the amount of bytes in the current file
			BYTECOUNT_CURRENT=$(cat $PATH_CURRENT | wc -c)
			if [[ "$VERBOSE" == "-v" ]]; then
				echo "BYTECOUNT CURRENT IS $BYTECOUNT_CURRENT"
				echo "BYTECOUNT PREV IS $BYTECOUNT_PREV"
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
				echo "Sync in progress"
			fi;
		else
			eval $CALLBACKFUNCOUTER &
		fi;

		FILECOUNT=$(eval $COUNTFILES)
	done
}

#Execute and loop a command while another command runs in the background
function wait_while(){
	WAITFUNC="$1"
	LOOPFUNC="$2"
	WAITDELAY="$3"
	eval $WAITFUNC &
	WAITPID=$!
	while ps -p $WAITPID > /dev/null; do 
		eval $LOOPFUNC
		sleep $WAITDELAY
	done
}

PARTSDIR=`eval echo $PARTSDIR`
if [[ "$VERBOSE" == "-v" ]]; then
	echo "PARTSDIR IS $PARTSDIR";
fi;

mkdir -p $PARTSDIR
rm -R $PARTSDIR/*plock 2> /dev/null

#Initialize the pool handler
SYNCBLACKHOLE="blackhole_handler $PARTSDIR process_file process_pool 10"
wait_while "$ENCRYPTDIR" "$SYNCBLACKHOLE" 1; echo "Now waiting for synchronization pool to be emptied"; wait && rm -R $PARTSDIR
echo "Done synchronizing"
