#! /bin/sh

set -eu
set -o pipefail

source ./env.sh

timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}/${POSTGRES_DATABASE}_${timestamp}.dump"

echo "Estimating database size for upload..."
# Get database size in bytes for --expected-size parameter
# Use psql's -v option for safe variable substitution to prevent SQL injection
db_size=$(psql -h $POSTGRES_HOST \
               -p $POSTGRES_PORT \
               -U $POSTGRES_USER \
               -d $POSTGRES_DATABASE \
               -v dbname="$POSTGRES_DATABASE" \
               -t -c "SELECT pg_database_size(:'dbname');" | xargs)

# Validate that db_size is a valid positive integer
if ! [ -n "$db_size" ] || ! [ "$db_size" -eq "$db_size" ] 2>/dev/null || [ "$db_size" -lt 0 ]; then
  echo "Error: Failed to get valid database size (got: '$db_size')"
  exit 1
fi

echo "Database size: $db_size bytes"

# Determine if we need --expected-size (for uploads >50GB)
size_threshold=$((50 * 1024 * 1024 * 1024))  # 50GB in bytes
if [ "$db_size" -gt "$size_threshold" ]; then
  echo "Database size exceeds 50GB, using --expected-size parameter"
  use_expected_size=true
else
  use_expected_size=false
fi

if [ -n "$PASSPHRASE" ]; then
  echo "Creating encrypted backup of $POSTGRES_DATABASE database and uploading to $S3_BUCKET..."
  s3_uri="${s3_uri_base}.gpg"
  if [ "$use_expected_size" = true ]; then
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
  echo "Creating backup of $POSTGRES_DATABASE database and uploading to $S3_BUCKET..."
  s3_uri="$s3_uri_base"
  if [ "$use_expected_size" = true ]; then
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
