#! /bin/sh

set -u # `-e` omitted intentionally, but i can't remember why exactly :'(
set -o pipefail

source ./env.sh

s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}"

if [ -z "$PASSPHRASE" ]; then
  file_type=".dump"
else
  file_type=".dump.gpg"
fi

if [ $# -eq 1 ]; then
  timestamp="$1"
  key_suffix="${POSTGRES_DATABASE}_${timestamp}${file_type}"
else
  echo "Finding latest backup..."
  key_suffix=$(
    aws $aws_args s3 ls "${s3_uri_base}/${POSTGRES_DATABASE}" \
      | sort \
      | tail -n 1 \
      | awk '{ print $4 }'
  )
fi

conn_opts="-h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER -d $POSTGRES_DATABASE"

# Get the backup file size for progress display
echo "Getting backup file size..."
backup_size=$(aws $aws_args s3api head-object \
  --bucket "${S3_BUCKET}" \
  --key "${S3_PREFIX}/${key_suffix}" \
  --query 'ContentLength' \
  --output text)

if [ -n "$PASSPHRASE" ]; then
  echo "Downloading encrypted backup from S3 and restoring..."
  aws $aws_args s3 cp "${s3_uri_base}/${key_suffix}" - \
    | pv -s "$backup_size" -i 10 \
    | gpg --decrypt --batch --passphrase "$PASSPHRASE" \
    | pg_restore $conn_opts --clean --if-exists
else
  echo "Downloading backup from S3 and restoring..."
  aws $aws_args s3 cp "${s3_uri_base}/${key_suffix}" - \
    | pv -s "$backup_size" -i 10 \
    | pg_restore $conn_opts --clean --if-exists
fi

echo "Restore complete."
