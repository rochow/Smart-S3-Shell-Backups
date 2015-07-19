#!/bin/bash

######## START CONFIG ########

BACKUP_DIR			= "/home/blah/public_html/" # Directory to backup. Note, all usage is relative to this path
TMP_BASE_DIR		= "/home/blah/backups/"		# This directory must have enough space for storing backups temporarily. Example: /var/tmp
S3_BUCKET			= "blah"					# S3 Bucket
S3_PREFIX_FILES		= "files"					# S3 Prefix for files
S3_PREFIX_DB		= "databases"				# S3 Prefix for DB
S3_PREFIX_FINAL		= "final"					# S3 Prefix for forever keeping will not be deleted during cleanup
EXCLUDES_FILE		= "/home/blah/excludes.txt"	# One exclude per line (absolute path)
ADMIN_EMAIL			= "blah@blah.com"			# Email notifications
MYSQL_ADMIN_USER	= "blah"					# Root MySQL user (on cPanel for example will usually be the same as the cPanel logins)
MYSQL_ADMIN_PASS	= "blah"					# Root MySQL pass

######## END CONFIG ########

VERBOSE=1

Usage()  {
    echo
    cat  <<EOF
Usage:
    $0 [--delete] [--backup] [--live] [--restore] [--version date]
EOF

}

Echo()  {
    if [ $VERBOSE = 1 ]; then
        echo $@
    fi
}

backup_db()  {
    DBNAME=`cat $DIR/wp-config.php | grep DB_NAME | cut -d \' -f 4`
    DBUSER=`cat $DIR/wp-config.php | grep DB_USER | cut -d \' -f 4`
    DBPASS=`cat $DIR/wp-config.php | grep DB_PASSWORD | cut -d \' -f 4`
    DBHOST=`cat $DIR/wp-config.php | grep DB_HOST | cut -d \' -f 4`

    DB_BACKUP_FILE="${DIRNAME}_mysql_dump_${DATE}.sql.gz"
    /usr/bin/mysqldump -u $DBUSER --password="$DBPASS" -h $DBHOST $DBNAME |/bin/gzip >$TMP_DIR_DB/$DB_BACKUP_FILE
}

cleanup_old_backups()  {
    Echo "Cleaning up outdated backups..."
    for i in {0..7}; do ((keep[$(date +%Y%m%d -d "-$i day")]++)); done  # Keep last 7 days
    for i in {0..4}; do ((keep[$(date +%Y%m%d -d "sunday-$((i+1)) week")]++)); done # Keep backup of every Sunday during last 4 weeks. All the rest will be deleted inside this bucket/prefix

    /usr/sbin/s3cmd ls s3://$S3_BUCKET/$S3_PREFIX_FILES/ | while read -r F; do
        F=`echo $F |sed "s~.*\/~~g"`
        FILE_DATE=`echo $F |sed "s~.*_\([0-9\-]\+\)\.tar\.gz~\1~" |sed "s/\-//g"`
        if [ $FILE_DATE ]; then
            if [ ! ${keep[$FILE_DATE]} ]; then
                /usr/sbin/s3cmd del s3://$S3_BUCKET/$S3_PREFIX_FILES/$F
            fi
        fi
    done

    /usr/sbin/s3cmd ls s3://$S3_BUCKET/$S3_PREFIX_DB/ | while read -r F; do
        F=`echo $F |sed "s~.*\/~~g"`
        FILE_DATE=`echo $F |sed "s~.*_\([0-9\-]\+\)\.sql\.gz~\1~" |sed "s/\-//g"`
        if [ $FILE_DATE ]; then
            if [ ! "${keep[$FILE_DATE]}" ]; then
                /usr/sbin/s3cmd del s3://$S3_BUCKET/$S3_PREFIX_DB/$F
            fi
        fi
    done

    Echo "Done"
}

do_backup()  {
    TMP_DIR_FILES=$(mktemp -d --tmpdir=$TMP_BASE_DIR)
    TMP_DIR_DB=$(mktemp -d --tmpdir=$TMP_BASE_DIR)
    DATE=`date +%Y-%m-%d`

    for DIR in `/bin/find $BACKUP_DIR -maxdepth 1 ! -path $BACKUP_DIR -type d`; do
        DIRNAME=$(basename $DIR)
        if [ "$ONE_FOLDER" -a "$ONE_FOLDER" != "$DIRNAME" ]; then
            continue
        fi

        Echo "Backing up ${DIR} ..."
        if [[ $DIRNAME =~ ^[0-9] ]]; then
            Echo "dir $DIRNAME starting from digits, skipping"
            continue
        fi

        if grep -qP "^$DIR$" $EXCLUDES_FILE; then
            Echo "$DIR found in excludes. Skipping"
            continue
        fi

        if [ -e $DIR/wp-config.php ]; then
            Echo "Backing up DB..."
            backup_db
        fi

        Echo "Backing up dir $DIR..."
        ionice -c3 tar -C $DIR -zcf $TMP_DIR_FILES/${DIRNAME}_${DATE}.tar.gz .
    done

    # Uploading to S3

    if [ "$IS_LIVE" ]; then
        S3_PREFIX_F=$S3_PREFIX_FINAL
        S3_PREFIX_DB=$S3_PREFIX_FINAL
    else
	S3_PREFIX_F=$S3_PREFIX_FILES
    fi

    Echo "Uploading backups to S3..."
    if [ ! $VERBOSE = 1 ]; then
        if ! /bin/find $TMP_DIR_FILES -maxdepth 0 -empty |read v; then
            /usr/sbin/s3cmd --acl-private --no-progress put $TMP_DIR_FILES/* s3://$S3_BUCKET/$S3_PREFIX_F/ >/dev/null
        fi
        if ! /bin/find $TMP_DIR_DB -maxdepth 0 -empty |read v; then
            /usr/sbin/s3cmd --acl-private --no-progress put $TMP_DIR_DB/* s3://$S3_BUCKET/$S3_PREFIX_DB/ >/dev/null
        fi
    else
        if ! /bin/find $TMP_DIR_FILES -maxdepth 0 -empty |read v; then
            /usr/sbin/s3cmd --acl-private put $TMP_DIR_FILES/* s3://$S3_BUCKET/$S3_PREFIX_F/
        fi
        if ! /bin/find $TMP_DIR_DB -maxdepth 0 -empty |read v; then
            /usr/sbin/s3cmd --acl-private put $TMP_DIR_DB/* s3://$S3_BUCKET/$S3_PREFIX_DB/
        fi
    fi

    if [ "$IS_LIVE" = "yes" ]; then
        if [ -d $BACKUP_DIR/99${ONE_FOLDER} ]; then
            echo "Can't rename folder $ONE_FOLDER to 99${ONE_FOLDER} as it already exists!"
        else
            /bin/mv $BACKUP_DIR/$ONE_FOLDER $BACKUP_DIR/99${ONE_FOLDER}
        fi
    fi

    /bin/rm -rf $TMP_DIR_FILES
    /bin/rm -rf $TMP_DIR_DB
}

do_restore()  {
    if [ -e $BACKUP_DIR/$ONE_FOLDER ]; then
        echo "Folder $BACKUP_DIR/$ONE_FOLDER exists, will not restore. Exiting"
        exit 1
    fi

    local FILE_TO_RESTORE=""

    PREFIX_DB=$S3_PREFIX_DB

    echo "Restoring files..."
    i=0
    for PREFIX_FILES in $S3_PREFIX_FINAL $S3_PREFIX_FILES; do
        LINES=`/usr/sbin/s3cmd ls s3://$S3_BUCKET/$PREFIX_FILES/ | grep s3://$S3_BUCKET/$PREFIX_FILES/$ONE_FOLDER`
        while read -r F; do
            F=`echo $F |sed "s~.*\/~~g"`
            FOLDER_NAME=`echo $F |sed "s~_[0-9\-]\+\.tar\.gz~~"`
            FILE_DATE=`echo $F |sed "s~.*_\([0-9\-]\+\)\.tar\.gz~\1~" |sed "s/\-//g"`
            if [ "$ONE_FOLDER" = "$FOLDER_NAME" ]; then
                if [ "$BACKUP_VERSION" ]; then
                    if [ "$BACKUP_VERSION" = "$FILE_DATE" ]; then
                        FILE_TO_RESTORE=$F
                    fi
                else
                    FILE_TO_RESTORE=$F
                fi
            fi
        done <<< "$LINES"
        if [ "$FILE_TO_RESTORE" ]; then
            s3cmd get s3://$S3_BUCKET/$PREFIX_FILES/$FILE_TO_RESTORE $TMP_BASE_DIR/
            mkdir $BACKUP_DIR/$ONE_FOLDER
            tar -C $BACKUP_DIR/$ONE_FOLDER -zxf $TMP_BASE_DIR/$FILE_TO_RESTORE
            rm $TMP_BASE_DIR/$FILE_TO_RESTORE
            if [ "$i" = 0 ]; then
                PREFIX_DB=$S3_PREFIX_FINAL
            fi
            break
         fi
         i=$((i + 1))
    done

    LINES=`/usr/sbin/s3cmd ls s3://$S3_BUCKET/$PREFIX_DB/$ONE_FOLDER |grep _mysql_dump_`
    while read -r F; do
        F=`echo $F |sed "s~.*\/~~g"`
        FOLDER_NAME=`echo $F |sed "s~_mysql_dump_[0-9\-]\+\.sql\.gz~~"`
        FILE_DATE=`echo $F |sed "s~.*_mysql_dump_\([0-9\-]\+\)\.sql\.gz~\1~" |sed "s/\-//g"`
        if [ "$ONE_FOLDER" = "$FOLDER_NAME" ]; then
            if [ "$BACKUP_VERSION" ]; then
                if [ "$BACKUP_VERSION" = "$FILE_DATE" ]; then
                    DB_TO_RESTORE=$F
                fi
            else
                DB_TO_RESTORE=$F
            fi
    fi
    done <<< "$LINES"
    if [ "$DB_TO_RESTORE" ]; then
        DBNAME=`cat $BACKUP_DIR/$ONE_FOLDER/wp-config.php | grep DB_NAME | cut -d \' -f 4`
        DBUSER=`cat $BACKUP_DIR/$ONE_FOLDER/wp-config.php | grep DB_USER | cut -d \' -f 4`
        DBPASS=`cat $BACKUP_DIR/$ONE_FOLDER/wp-config.php | grep DB_PASSWORD | cut -d \' -f 4`
        DBHOST=`cat $BACKUP_DIR/$ONE_FOLDER/wp-config.php | grep DB_HOST | cut -d \' -f 4`

        if [ "$DBNAME" ]; then
            DB_EXISTS=`mysql -u$DBUSER --password="$DBPASS" $DBNAME -s -N -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='$DBNAME'" 2>/dev/null`
            if [ -z $DB_EXISTS ]; then
                mysqladmin -u$MYSQL_ADMIN_USER --password="$MYSQL_ADMIN_PASS" create $DBNAME
                s3cmd get s3://$S3_BUCKET/$S3_PREFIX_DB/$DB_TO_RESTORE $TMP_BASE_DIR/
                zcat $TMP_BASE_DIR/$DB_TO_RESTORE | mysql -u$DBUSER --password="$DBPASS" $DBNAME
                rm $TMP_BASE_DIR/$DB_TO_RESTORE
            else
                echo "Database $DBNAME already exists, will not restore"
                exit 1
            fi
        fi
    fi

    if [ "$FILE_TO_RESTORE" -o "$DB_TO_RESTORE" ]; then
        echo "Restore complete"
    fi
}

do_delete()  {
    Echo "Deleting $ONE_FOLDER locally"

    DBNAME=`cat $BACKUP_DIR/$ONE_FOLDER/wp-config.php | grep DB_NAME | cut -d \' -f 4`
    DBUSER=`cat $BACKUP_DIR/$ONE_FOLDER/wp-config.php | grep DB_USER | cut -d \' -f 4`
    DBPASS=`cat $BACKUP_DIR/$ONE_FOLDER/wp-config.php | grep DB_PASSWORD | cut -d \' -f 4`
    DBHOST=`cat $BACKUP_DIR/$ONE_FOLDER/wp-config.php | grep DB_HOST | cut -d \' -f 4`

    if [ "$DBNAME" ]; then
        mysqladmin -u$MYSQL_ADMIN_USER --password="$MYSQL_ADMIN_PASS" drop $DBNAME
    fi

    rm -rf $BACKUP_DIR/$ONE_FOLDER
}

if [ ! -d $TMP_BASE_DIR ]; then
    echo "TMP directory $TMP_BASE_DIR doesn't exists!"
    exit 1
fi

if [ ! -d $BACKUP_DIR ]; then
    echo "Backup directory $BACKUP_DIR doesn't exists!"
    exit 1
fi

if [ ! -d $EXCLUDE_DIR ]; then
    echo "Directory with exclude files $EXCLUDE_DIR doesn't exists!"
    exit 1
fi

if [ ! "$S3_PREFIX_FILES" -o ! "$S3_PREFIX_DB" ]; then
    echo '$S3_PREFIX_FILES and $S3_PREFIX_DB must not be empty!'
    exit 1
fi

BACKUP_DIR=$(echo $BACKUP_DIR |sed "s~[/]\+$~~")

ARGUMENTS=`getopt -o '' -l "backup,restore,delete,live,version:,help" -n "$0" -- "$@"`

if [ "${?}" != "0" ]; then
    echo "terminating" >&2
    exit 1
fi

eval set -- "${ARGUMENTS}"

while true; do
    case "${1}" in
        --delete)
            ACTION="delete"
            shift
            ;;
        --backup)
            ACTION="backup"
            shift
            ;;
         --restore)
            ACTION="restore"
            shift
            ;;
         --live)
            IS_LIVE="yes"
            shift
            ;;
        --version)
            BACKUP_VERSION=$2
            shift 2
            ;;
        -h|--help)
            Usage
            exit 0
            ;;
         --)
            shift
            break
            ;;
        *)
            echo "Arguments error!"
            Usage
            exit 1
            break
    esac
done

ONE_FOLDER=$1

if [ "$ACTION" = "backup" ]; then
    do_backup
elif [ "$ACTION" = "restore" ]; then
    do_restore
elif [ "$ACTION" = "delete" ]; then
    echo "Make sure to have a backup first. press 'y' to confirm"
    read CONFIRM
    if [ "$CONFIRM" = "y" ]; then
        do_delete
    fi
else
    Usage
    exit 1
fi

cleanup_old_backups