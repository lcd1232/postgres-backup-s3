#! /bin/sh

set -eu
set -o pipefail

source ./env.sh

# Execute pre-backup command if provided
if [ -n "${BACKUP_PRE_COMMAND:-}" ]; then
  echo "Running pre-backup command..."
  if eval "$BACKUP_PRE_COMMAND"; then
    echo "Pre-backup command completed successfully."
  else
    echo "Warning: Pre-backup command failed with exit code $?"
  fi
fi

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
  if [ "$db_size" -gt "$EXPECTED_SIZE_THRESHOLD_BYTES" ]; then
      echo "Database size exceeds expected size threshold, using --expected-size parameter."
      aws_s3_args="--expected-size $db_size"
  else
      aws_s3_args=""
  fi

  timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
  s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}/${POSTGRES_DATABASE}_${timestamp}.dump"

  if [ -n "$PASSPHRASE" ]; then
    echo "Creating encrypted backup and uploading to $S3_BUCKET..."
    s3_uri="${s3_uri_base}.gpg"
    pg_dump --format=custom \
            -h $POSTGRES_HOST \
            -p $POSTGRES_PORT \
            -U $POSTGRES_USER \
            -d $POSTGRES_DATABASE \
            $PGDUMP_EXTRA_OPTS \
            | pv -i $PV_INTERVAL_SEC \
            | gpg --symmetric --batch --passphrase "$PASSPHRASE" \
            | aws $aws_args s3 cp $aws_s3_args - "$s3_uri"
  else
    echo "Creating backup and uploading to $S3_BUCKET..."
    s3_uri="$s3_uri_base"

    pg_dump --format=custom \
            -h $POSTGRES_HOST \
            -p $POSTGRES_PORT \
            -U $POSTGRES_USER \
            -d $POSTGRES_DATABASE \
            $PGDUMP_EXTRA_OPTS \
            | pv -i $PV_INTERVAL_SEC \
            | aws $aws_args s3 cp $aws_s3_args - "$s3_uri"
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

if run_backup; then
  if [ -n "${BACKUP_POST_SUCCESS_COMMAND:-}" ]; then
    echo "Running post-success command..."
    if ! eval "$BACKUP_POST_SUCCESS_COMMAND"; then
      echo "Warning: Post-success command failed with exit code $?"
    fi
  fi
else
  backup_exit_code=$?
  echo "Backup failed with exit code $backup_exit_code"
  if [ -n "${BACKUP_POST_FAILURE_COMMAND:-}" ]; then
    echo "Running post-failure command..."
    if ! eval "$BACKUP_POST_FAILURE_COMMAND"; then
      echo "Warning: Post-failure command failed with exit code $?"
    fi
  fi
fi
