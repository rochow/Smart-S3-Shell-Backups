# Smart S3 Shell Backups with Automated Restore!
========
Have multiple sites (WordPress in particular) inside the 1 hosting account? This bash script can be setup as a cron to automatically backup the files & database for each of them to Amazon S3.

Something go wrong or need an old backup? The 'restore' command will grab the latest from S3, download it to the server and restore the files & database back the way it was. Bam!

The 'final' command will put the backup inside a 'final' folder which is stored on S3 until manually deleted (for long-term backups)

The script keeps the last 7 days of backups then each Sunday for a month.

## Usage
--------

```bash
./smart-s3-shell-backups.sh [--delete] [--backup] [--live] [--restore] [--version date]
```

For example:

```bash
./smart-s3-shell-backups.sh --backup blah
```

Will backup the folder 'blah' (relative to the root directory set in the config)

```bash
./smart-s3-shell-backups.sh --backup --live blah
```

Will backup the folder 'blah' to the 'final' folder on S3, and then rename the folder with 99 prepended (which will also exclude it from any future automated backups)

```bash
./smart-s3-shell-backups.sh --delete --backup --live blah
```

Will backup the folder 'blah' to the 'final' folder on S3, then delete the local files & database

```bash
./smart-s3-shell-backups.sh --restore blah
```

Will restore 'blah' folder from the latest on S3 (note: make sure this folder & database doesn't exist)

```bash
./smart-s3-shell-backups.sh --restore --2015-07-30 blah
```

Will restore 'blah' folder from the 30th July 2015 backup on S3 (note: backup of this date needs to exist!)


## Installation
--------

The basic process is:

1. Setup a new S3 bucket
2. Install s3cmd package on the hosting server (or ask host to)
3. Configure s3cmd with access to the bucket
4. Add smart-s3-shell-backups.sh to the root directory of your hosting account (outside of public access)
5. Edit the configuration options in the .sh file
6. Setup a cron, nightly at 2am is pretty standard

### Setup an S3 Bucket

This is a tutorial in itself. If you haven't got an AWS account register at [http://aws.amazon.com](http://aws.amazon.com).

You then need to create a bucket, and ideally generate a user that has access *only* to the bucket you'll use for this. This is good practice for every S3 connection so your buckets are isolated from each other should your details be compromised.

The details you need from this step are:

- Bucket Name
- Access Key
- Secret Key


### S3CMD

Install the module (more info on [http://s3tools.org/s3cmd](http://s3tools.org/s3cmd)) or ask your host to install.

On Debian/Ubuntu run:

*apt-get install s3cmd*

Once it's installed, configure s3cmd running:

*s3cmd --configure*

Enter your Access key and Secret key. For all other questions just hit Enter.

### .Sh Configuration

Edit the parts at the top of smart-s3-shell-backups.sh marked as config, it's all pretty straight forward.

### Upload the .Sh File

Upload smart-s3-shell-backups.sh to the root directory of your hosting account (outside of public access, so don't put inside httpdocs, public_html or similar).

You're now good to manually run commands via SSH! (refer to 'usage' section)

### Setup Cron

To automate the backups you need a cron. Via SSH or Control Panel setup a nightly cron, 2am is pretty standard. Please google for the relevant tutorial for your control panel as there's many ways this can be setup.

## Considerations
--------

- Any folder starting with a number is excluded
- Only single quotes in wp-config.php like define('DB_NAME', 'database_name_here');
- DB backup will be named like mysql_db_backup_YYYY-MM-DD.sql.gz and placed in root of the site
- If the script is run more than once a day only the latest backup will persist, any previous backups for this day will be overwritten
- Free space checked only for root
- You need to have a local mail server configured in order to send email, for example exim4

## Support or Issues
--------
Feel free to get in touch. This script was custom developed as a backup solution for us by an external contractor so our knowledge is more limited than usual!