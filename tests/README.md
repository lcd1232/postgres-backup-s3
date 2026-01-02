# Tests

This directory contains automated tests for the PostgreSQL backup and restore functionality.

## Test Cases

The test suite validates the following scenarios:

1. **Backup and Restore without Passphrase**: Tests that backups can be created and restored without encryption
2. **Backup and Restore with Passphrase**: Tests that encrypted backups can be created and restored correctly

## Running Tests Locally

To run the tests locally:

```bash
cd tests
./test.sh
```

The test script will:
- Start a test environment with PostgreSQL, MinIO (S3-compatible storage), and the backup service
- Create sample data in the database
- Perform a backup
- Drop the data
- Restore from the backup
- Verify the data was restored correctly
- Run both with and without encryption

## Requirements

- Docker
- Docker Compose
- Bash

## How It Works

The tests use:
- **PostgreSQL 16**: As the test database
- **MinIO**: As an S3-compatible storage backend for testing
- **Docker Compose**: To orchestrate the test environment

The test script (`test.sh`) automatically:
1. Builds the backup container image
2. Starts all required services
3. Creates test data
4. Runs backup operations
5. Verifies restore operations
6. Cleans up after itself

## CI/CD

Tests run automatically on every commit via GitHub Actions (see `.github/workflows/test.yml`).
