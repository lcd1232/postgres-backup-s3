# Pipe-Based Backup/Restore Implementation

## Overview

This document describes the implementation of pipe-based backup and restore functionality for postgres-backup-s3. The new implementation streams data directly between PostgreSQL, encryption (if enabled), and S3 without writing to disk first.

## Key Changes

### backup.sh

**Before**: 
1. `pg_dump` → write to disk (`backup/db.dump`)
2. (Optional) encrypt file on disk → `backup/db.dump.gpg`
3. Upload file to S3
4. Delete local file

**After**:
1. Calculate database size using `pg_database_size()` 
2. Stream: `pg_dump` → (optional GPG encryption) → AWS S3 upload
3. Use `--expected-size` parameter for databases > 50GB

**Benefits**:
- No disk space needed for backup files
- Faster backup process (no intermediate I/O)
- Handles large databases (>50GB) correctly with `--expected-size`

### restore.sh

**Before**:
1. Download backup from S3 to disk
2. (Optional) decrypt file on disk
3. `pg_restore` from disk file
4. Delete local file

**After**:
1. Stream: AWS S3 download → (optional GPG decryption) → `pg_restore`

**Benefits**:
- No disk space needed for restore files
- Faster restore process (no intermediate I/O)

## Implementation Details

### Expected Size Calculation

For backups larger than 50GB, AWS CLI requires the `--expected-size` parameter to avoid failures due to too many parts in multipart upload (default limit is 10,000 parts).

The implementation:
1. Queries the database size before backup: `SELECT pg_database_size(current_database())`
2. Compares to threshold: 53687091200 bytes (50GB)
3. Adds `--expected-size "$db_size"` to AWS CLI command if needed

### Pipe Implementation

**Non-encrypted backup (< 50GB)**:
```bash
pg_dump --format=custom ... | aws s3 cp - "s3://..."
```

**Non-encrypted backup (> 50GB)**:
```bash
pg_dump --format=custom ... | aws s3 cp --expected-size "$db_size" - "s3://..."
```

**Encrypted backup (< 50GB)**:
```bash
pg_dump --format=custom ... | gpg --symmetric ... | aws s3 cp - "s3://..."
```

**Encrypted backup (> 50GB)**:
```bash
pg_dump --format=custom ... | gpg --symmetric ... | aws s3 cp --expected-size "$db_size" - "s3://..."
```

**Non-encrypted restore**:
```bash
aws s3 cp "s3://..." - | pg_restore ... --clean --if-exists
```

**Encrypted restore**:
```bash
aws s3 cp "s3://..." - | gpg --decrypt ... | pg_restore ... --clean --if-exists
```

## Testing

The existing test suite in `tests/test.py` validates both scenarios:

1. **Test 1**: Backup and restore without passphrase (using pipe)
2. **Test 2**: Backup and restore with passphrase (using pipe)

Both tests verify:
- Data integrity through backup/restore cycle
- Correct handling of encryption/decryption in the pipe
- No intermediate files left on disk

Run tests with:
```bash
cd tests
python3 test.py
```

## Manual Verification

To manually verify the pipe mechanism:

1. Start the services:
```bash
docker-compose up -d
```

2. Create test data in PostgreSQL:
```bash
docker-compose exec postgres psql -U user -d dbname -c "CREATE TABLE test (id int, data text); INSERT INTO test VALUES (1, 'test data');"
```

3. Run backup (observe "using pipe" message):
```bash
docker-compose exec backup sh backup.sh
```

4. Verify no files in /backup directory:
```bash
docker-compose exec backup ls -la /backup
```

5. Drop the test table:
```bash
docker-compose exec postgres psql -U user -d dbname -c "DROP TABLE test;"
```

6. Run restore (observe "using pipe" message):
```bash
docker-compose exec backup sh restore.sh
```

7. Verify data is restored:
```bash
docker-compose exec postgres psql -U user -d dbname -c "SELECT * FROM test;"
```

## Backward Compatibility

The changes are fully backward compatible:
- All existing environment variables work as before
- The `/backup` directory is still used by go-cron and for temporary operations
- S3 naming conventions remain unchanged
- Encryption behavior is identical, just streamed instead of file-based

## Performance Considerations

**Advantages**:
- Reduced disk I/O: No intermediate file writes/reads
- Lower disk space requirements: No need for space equal to backup size
- Faster for large databases: Single streaming operation vs write-then-upload

**Trade-offs**:
- Cannot retry individual steps: If pipe fails, entire operation must restart
- No local backup copy: Backup goes directly to S3 (intentional design)
- Memory usage: Pipe buffers may use memory, but typically minimal with streaming

## AWS CLI Expected Size Parameter

From AWS CLI documentation:
> This argument specifies the expected size of a stream in terms of bytes. Note that this argument is needed only when a stream is being uploaded to s3 and the size is larger than 50GB. Failure to include this argument under these conditions may result in a failed upload due to too many parts in upload.

The implementation calculates the database size before backup and includes `--expected-size` when needed, preventing failures for large databases.
