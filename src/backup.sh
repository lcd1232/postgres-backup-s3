#! /bin/sh

set -eu
set -o pipefail

source ./env.sh

# Constants
FIFTY_GB_BYTES=53687091200  # 50GB threshold for --expected-size parameter

# Execute pre-backup command if provided
if [ -n "${BACKUP_PRE_COMMAND:-}" ]; then
  echo "Running pre-backup command..."
  if eval "$BACKUP_PRE_COMMAND"; then
    echo "Pre-backup command completed successfully."
  else
    echo "Pre-backup command failed with exit code $?"
    if [ -n "${BACKUP_POST_FAILURE_COMMAND:-}" ]; then
      echo "Running post-failure command..."
      eval "$BACKUP_POST_FAILURE_COMMAND" || true
    fi
    exit 1
  fi
fi

# Function to execute backup and handle success/failure
run_backup() {
  # Get database size to determine if we need --expected-size for AWS CLI
  # This is needed for backups larger than 50GB
  echo "Calculating database size..."
  db_size=$(psql -h $POSTGRES_HOST \
                 -p $POSTGRES_PORT \
                 -U $POSTGRES_USER \
                 -d $POSTGRES_DATABASE \
                 -t -c "SELECT pg_database_size(current_database());" | xargs echo -n)

  echo "Database size: $db_size bytes"

  timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
  s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}/${POSTGRES_DATABASE}_${timestamp}.dump"

  if [ -n "$PASSPHRASE" ]; then
    echo "Creating encrypted backup and uploading to $S3_BUCKET..."
    s3_uri="${s3_uri_base}.gpg"
    
    # Determine if we need --expected-size parameter
    if [ "$db_size" -gt "$FIFTY_GB_BYTES" ]; then
      echo "Database is larger than 50GB, adding --expected-size parameter"
      pg_dump --format=custom \
              -h $POSTGRES_HOST \
              -p $POSTGRES_PORT \
              -U $POSTGRES_USER \
              -d $POSTGRES_DATABASE \
              $PGDUMP_EXTRA_OPTS \
              | gpg --symmetric --batch --passphrase "$PASSPHRASE" \
              | aws $aws_args s3 cp --expected-size "$db_size" - "$s3_uri"
    else
      pg_dump --format=custom \
              -h $POSTGRES_HOST \
              -p $POSTGRES_PORT \
              -U $POSTGRES_USER \
              -d $POSTGRES_DATABASE \
              $PGDUMP_EXTRA_OPTS \
              | gpg --symmetric --batch --passphrase "$PASSPHRASE" \
              | aws $aws_args s3 cp - "$s3_uri"
    fi
  else
    echo "Creating backup and uploading to $S3_BUCKET..."
    s3_uri="$s3_uri_base"
    
    # Determine if we need --expected-size parameter
    if [ "$db_size" -gt "$FIFTY_GB_BYTES" ]; then
      echo "Database is larger than 50GB, adding --expected-size parameter"
      pg_dump --format=custom \
              -h $POSTGRES_HOST \
              -p $POSTGRES_PORT \
              -U $POSTGRES_USER \
              -d $POSTGRES_DATABASE \
              $PGDUMP_EXTRA_OPTS \
              | aws $aws_args s3 cp --expected-size "$db_size" - "$s3_uri"
    else
      pg_dump --format=custom \
              -h $POSTGRES_HOST \
              -p $POSTGRES_PORT \
              -U $POSTGRES_USER \
              -d $POSTGRES_DATABASE \
              $PGDUMP_EXTRA_OPTS \
              | aws $aws_args s3 cp - "$s3_uri"
    fi
  fi

  echo "Backup complete."

  if [ -n "$BACKUP_KEEP_DAYS" ]; then
    sec=$((86400*BACKUP_KEEP_DAYS))
    date_from_remove=$(date -d "@$(($(date +%s) - sec))" +%Y-%m-%d)
    backups_query="Contents[?LastModified<='${date_from_remove} 00:00:00'].{Key: Key}"

    echo "Removing old backups from $S3_BUCKET..."
    aws $aws_args s3api list-objects \
      --bucket "${S3_BUCKET}" \
      --prefix "${S3_PREFIX}" \
      --query "${backups_query}" \
      --output text \
      | xargs -n1 -t -I 'KEY' aws $aws_args s3 rm s3://"${S3_BUCKET}"/'KEY'
    echo "Removal complete."
  fi
}

# Execute backup and handle post-commands
if run_backup; then
  # Backup succeeded
  if [ -n "${BACKUP_POST_SUCCESS_COMMAND:-}" ]; then
    echo "Running post-success command..."
    eval "$BACKUP_POST_SUCCESS_COMMAND" || echo "Warning: Post-success command failed with exit code $?"
  fi
else
  # Backup failed
  backup_exit_code=$?
  echo "Backup failed with exit code $backup_exit_code"
  if [ -n "${BACKUP_POST_FAILURE_COMMAND:-}" ]; then
    echo "Running post-failure command..."
    eval "$BACKUP_POST_FAILURE_COMMAND" || true
  fi
  exit $backup_exit_code
fi
