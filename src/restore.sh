#! /bin/sh

set -u # `-e` omitted intentionally, but i can't remember why exactly :'(
set -o pipefail

source ./env.sh

# Execute pre-restore command if provided
if [ -n "${RESTORE_PRE_COMMAND:-}" ]; then
  echo "Running pre-restore command..."
  if eval "$RESTORE_PRE_COMMAND"; then
    echo "Pre-restore command completed successfully."
  else
    echo "Warning: Pre-restore command failed with exit code $?"
  fi
fi

# Function to execute restore and handle success/failure
run_restore() {
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

  if [ -n "$PASSPHRASE" ]; then
    echo "Downloading encrypted backup from S3 and restoring (using pipe)..."
    aws $aws_args s3 cp "${s3_uri_base}/${key_suffix}" - \
      | gpg --decrypt --batch --passphrase "$PASSPHRASE" \
      | pg_restore $conn_opts --clean --if-exists
  else
    echo "Downloading backup from S3 and restoring (using pipe)..."
    aws $aws_args s3 cp "${s3_uri_base}/${key_suffix}" - \
      | pg_restore $conn_opts --clean --if-exists
  fi

  echo "Restore complete."
}

# Execute restore and handle post-commands
if run_restore "$@"; then
  # Restore succeeded
  if [ -n "${RESTORE_POST_SUCCESS_COMMAND:-}" ]; then
    echo "Running post-success command..."
    eval "$RESTORE_POST_SUCCESS_COMMAND" || echo "Warning: Post-success command failed with exit code $?"
  fi
else
  # Restore failed
  restore_exit_code=$?
  echo "Restore failed with exit code $restore_exit_code"
  if [ -n "${RESTORE_POST_FAILURE_COMMAND:-}" ]; then
    echo "Running post-failure command..."
    eval "$RESTORE_POST_FAILURE_COMMAND" || true
  fi
  exit $restore_exit_code
fi
