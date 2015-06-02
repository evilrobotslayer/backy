#!/bin/bash
#
# This script is designed to be run daily via cron and will generate 
# daily and weekly tarball snapshots for the configured targets.
#
# It has *NOT* been written for POSIX `sh` compliance.  Make sure your
# cron runs jobs as bash, or explicitly execute bash when it runs.
#
# Example cron line:
#  0 6 * * * /root/backups/bin/backup.sh > /dev/null 2>&1 
# ------------------------------------------------------------------------
# Copyright (c) 1999 Vivek Gite <vivek@nixcraft.com>
# Copyright (c) 2015 George M. Grindlinger (georgeg@oit.rutgers.edu)
# ------------------------------------------------------------------------
# Inspiration, and code, drawn from Vivek Gite's tape backup script 
# which is part of the nixCraft shell script collection (NSSC) located at: 
# http://bash.cyberciti.biz/backup/tar-full-incremental-tape-backup-script
# This script is licensed under GNU GPL version 3.0 or above.
##########################################################################

# Define configuration parameters

# Backup configuration
# Backup configuration directories
# Set this to the location of "backup" directory heirarchy
# Optionally, leave this blank if you plan on overriding all dirs
BACKUP_BASE_DIR=~/backups
BACKUP_CONF_DIR=$BACKUP_BASE_DIR/conf
BACKUP_LOG_DIR=$BACKUP_BASE_DIR/log

# Define a prefix for the backups (eg: backup, `hostname`, etc...)
BACKUP_FILE_PREFIX=backup

# Define where to store the backups
BACKUP_DAILY_DIR=$BACKUP_BASE_DIR/$BACKUP_FILE_PREFIX.daily
BACKUP_WEEKLY_DIR=$BACKUP_BASE_DIR/$BACKUP_FILE_PREFIX.weekly

# Backup Configuration
# Define which day of the week you want to export a weekly backup
# Valid options are Sun|Mon|Tue|Wed|Thu|Fri|Sat
BACKUP_EXPORT_DAY=Fri

# Choose whether or not to age out and purge old daily backups
# Daily backups older than this number of days will be deleted 
# If less than 7, weekly exports will not occur
# Unset or comment out to disable ageing out backups
BACKUP_RETENTION=7

# Define which, if any, compression algorithm to use
# Valid options are bz2|gz|none - bz2 is default
BACKUP_COMPRESSION=bz2

# ------------------------------------------------------------------------
# Define targets (file/directory) to be archived in $BACKUP_INCLUDE_CONF 
# by defining paths to target. Regex is allowed, but omit the leading '/'.
# home/vivek/iso
# home/vivek/*.cpp~
# $BACKUP_EXCLUDE_CONF works the same way
# ------------------------------------------------------------------------
BACKUP_INCLUDE_CONF=$BACKUP_CONF_DIR/backup.include.conf
BACKUP_EXCLUDE_CONF=$BACKUP_CONF_DIR/backup.exclude.conf

# Define Command Binaries
# For security purposes since script will be run as root
# We should use hardcoded paths to the binaries
# PLEASE ENSURE THAT THESE ARE SET TO SANE VALUES FOR YOUR SYSTEM
DATE=/bin/date
RM=/bin/rm
CP=/bin/cp
LS=/bin/ls
XARGS=/usr/bin/xargs
TAR=/bin/tar
FIND=/usr/bin/find
TAIL=/usr/bin/tail
ECHO=/bin/echo

# Define tar args
TAR_ARGS="--totals -cvf"

# Initialize some variables
# Today and Day of Week
TODAY=`$DATE +"%F"`
DOW=`$DATE +"%a"`
BACKUP_LOG_FILE=$BACKUP_LOG_DIR/$BACKUP_FILE_PREFIX.$TODAY.log
BACKUP_ERROR_FILE=$BACKUP_LOG_DIR/$BACKUP_FILE_PREFIX.$TODAY.err


init(){
    # Initialization routines; mostly configuration sanity checking 
    # Create a failure flag
    local fail=false

    # Check to make sure backup storage directories exist
    # Deliberately fail instead of trying to create potentially 
    # erroneous directories
    [[ ! -d $BACKUP_DAILY_DIR ]] && \
        $ECHO "ERROR: BACKUP_DAILY_DIR does not exist: $BACKUP_DAILY_DIR" 1>&2 && \
        fail=true

    [[ ! -d $BACKUP_WEEKLY_DIR ]] && \
        $ECHO "ERROR: BACKUP_WEEKLY_DIR does not exist: $BACKUP_WEEKLY_DIR" 1>&2 && \
        fail=true

    # Test for valid backup configuration
    [[ ! -s $BACKUP_INCLUDE_CONF ]] && \
        $ECHO "ERROR: BACKUP_INCLUDE_CONF is blank or non-existant" 1>&2 && \
        fail=true

    # Test for correct compression configuration; 
    # set appropriate arg and file extension
    case "$BACKUP_COMPRESSION" in
        bz2) 
            TAR_ARGS="-j $TAR_ARGS" 
            BACKUP_FILE_EXT="tbz"
            ;;
        gz) 
            TAR_ARGS="-z $TAR_ARGS" 
            BACKUP_FILE_EXT="tgz"
            ;;
        none) 
            BACKUP_FILE_EXT="tar"
            ;;
        *)  
            $ECHO -e "ERROR: BACKUP_COMPRESSION has incorrect value: $BACKUP_COMPRESSION" 1>&2 
            fail=true
            ;;
    esac

    # If anything failed; die
    [[ "$fail" == true ]] && \
        $ECHO "Check your configuration!" 1>&2 && \
        exit 10
}

# Test $BACKUP_EXPORT_DAY and echo Day-of-Week for logging purposes
echo_dow(){
    case "$BACKUP_EXPORT_DAY" in 
        Sun|Mon|Tue|Wed|Thu|Fri|Sat) 
            $ECHO -e "Day of Week: $DOW\n"
            ;;
        *) 
            $ECHO -e "ERROR: BACKUP_EXPORT_DAY has incorrect value: $BACKUP_EXPORT_DAY\nCheck your configuration!" 1>&2 
            exit 15
            ;;
    esac
}

export_weekly(){
    $ECHO -e "Export Day!\nSearching for weekly export..."

    # Find all files >6 days old, sort by time in 'ls' and grab latest one
    # If backups haven't been run in a while for some reason this should 
    # export the last backup taken
    local export_file=`$FIND $BACKUP_DAILY_DIR -mindepth 1 -maxdepth 1 -name $BACKUP_FILE_PREFIX\* -type f -daystart -mtime +6 -print0 | \
        $XARGS -0r $LS -Art | $TAIL -1` 

    if [[ -n "$export_file" ]]; then
        $ECHO -e "Exporting to weekly: $export_file\n" 
        $CP -t $BACKUP_WEEKLY_DIR $export_file
    else
        $ECHO -e "No files to export found!\nContinuing...\n"
    fi

    # Determine if $BACKUP_RETENTION is set, and if so purge the old backups
    # xargs will not run if find produces no output
    if [[ ! -z $BACKUP_RETENTION ]]; then
        $ECHO -e "BACKUP_RETENTION set to $BACKUP_RETENTION days\nPurging old backups..."
        $FIND $BACKUP_DAILY_DIR -mindepth 1 -maxdepth 1 -name $BACKUP_FILE_PREFIX\* -type f -daystart -mtime +$BACKUP_RETENTION -print0 | \
        $XARGS -0r $RM
    fi
}

backup(){
    # If exclude configuration exists and it's not empty; add it to TAR_ARGS
    [[ -s $BACKUP_EXCLUDE_CONF ]] && \
        $ECHO "BACKUP_EXCLUDE_CONF found; processing..." && \
        TAR_ARGS="-X $BACKUP_EXCLUDE_CONF $TAR_ARGS"

    # Commence actual backup!
    $ECHO "Backing up files to tar archive in $BACKUP_DAILY_DIR"

    # Preserve current directory; we're going to cwd to '/' so that targets
    # are stored with relative names from '/' instead of absolute names.
    local oldDir=$(pwd)
    cd /

    # Construct the 'tar' command, and wrap it in 'xargs' 
    # so you can read in the list of targets
    $XARGS $TAR $TAR_ARGS $BACKUP_DAILY_DIR/$BACKUP_FILE_PREFIX.$TODAY.$BACKUP_FILE_EXT < $BACKUP_INCLUDE_CONF 2>&1

    # Return to original directory
    cd $oldDir
    $ECHO "Backup complete!"
}

#### Main Logic ####

# Check for root creds; die if not root
[[ `id -u` != "0" ]] && \
    $ECHO "ERROR: You must be root to run this script." 1>&2 && \
    exit 1

# Use Day-of-Week as case selector to determine action to take
# Also sets up the the logging
case $DOW in
    $BACKUP_EXPORT_DAY) 
        init 
        echo_dow 
        export_weekly 
        backup
        ;;
    *)    
        init 
        echo_dow 
        backup
        ;;
esac > >(tee $BACKUP_LOG_FILE) 2> >(tee $BACKUP_ERROR_FILE >&2)

# The `tee` command is going to generate the error log file before any
# errors (if any even occur) are written.
# We need to check to see if error file is empty and, if so, delete it
[[ ! -s $BACKUP_ERROR_FILE ]] && \
    rm $BACKUP_ERROR_FILE

# If we get here, presume normal exit
exit 0
