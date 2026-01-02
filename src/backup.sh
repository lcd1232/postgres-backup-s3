#! /bin/sh

set -eu
set -o pipefail

source ./env.sh

timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}/${POSTGRES_DATABASE}_${timestamp}.dump"

echo "Estimating database size for upload..."
# Get database size in bytes for --expected-size parameter
db_size=$(psql -h $POSTGRES_HOST \
               -p $POSTGRES_PORT \
               -U $POSTGRES_USER \
               -d $POSTGRES_DATABASE \
               -t -c "SELECT pg_database_size('$POSTGRES_DATABASE');" | xargs)

echo "Database size: $db_size bytes"

# Determine if we need --expected-size (for uploads >50GB)
size_threshold=$((50 * 1024 * 1024 * 1024))  # 50GB in bytes
if [ "$db_size" -gt "$size_threshold" ]; then
  echo "Database size exceeds 50GB, using --expected-size parameter"
  expected_size_arg="--expected-size $db_size"
else
  expected_size_arg=""
fi

if [ -n "$PASSPHRASE" ]; then
  echo "Creating encrypted backup of $POSTGRES_DATABASE database and uploading to $S3_BUCKET..."
  s3_uri="${s3_uri_base}.gpg"
  pg_dump --format=custom \
          -h $POSTGRES_HOST \
          -p $POSTGRES_PORT \
          -U $POSTGRES_USER \
          -d $POSTGRES_DATABASE \
          $PGDUMP_EXTRA_OPTS \
          | gpg --symmetric --batch --passphrase "$PASSPHRASE" \
          | aws $aws_args s3 cp $expected_size_arg - "$s3_uri"
else
  echo "Creating backup of $POSTGRES_DATABASE database and uploading to $S3_BUCKET..."
  s3_uri="$s3_uri_base"
  pg_dump --format=custom \
          -h $POSTGRES_HOST \
          -p $POSTGRES_PORT \
          -U $POSTGRES_USER \
          -d $POSTGRES_DATABASE \
          $PGDUMP_EXTRA_OPTS \
          | aws $aws_args s3 cp $expected_size_arg - "$s3_uri"
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
