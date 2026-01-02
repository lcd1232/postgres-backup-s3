#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Change to the tests directory
cd "$(dirname "$0")"

echo -e "${YELLOW}===== Starting PostgreSQL Backup/Restore Tests =====${NC}"

# Cleanup function
cleanup() {
    echo -e "${YELLOW}Cleaning up...${NC}"
    docker compose -f docker-compose.test.yml down -v 2>/dev/null || true
}

# Trap to ensure cleanup happens
trap cleanup EXIT

# Function to wait for service to be ready
wait_for_service() {
    local service=$1
    local max_attempts=30
    local attempt=0
    
    echo "Waiting for $service to be ready..."
    while [ $attempt -lt $max_attempts ]; do
        if docker compose -f docker-compose.test.yml exec -T $service echo "ready" &>/dev/null; then
            echo "$service is ready!"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    
    echo -e "${RED}$service failed to become ready${NC}"
    return 1
}

# Function to create test data
create_test_data() {
    echo "Creating test data in PostgreSQL..."
    docker compose -f docker-compose.test.yml exec -T postgres psql -U testuser -d testdb <<EOF
CREATE TABLE IF NOT EXISTS test_table (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    value INTEGER
);

INSERT INTO test_table (name, value) VALUES 
    ('test1', 100),
    ('test2', 200),
    ('test3', 300);
EOF
    echo "Test data created successfully"
}

# Function to verify test data
verify_test_data() {
    echo "Verifying test data..."
    local result=$(docker compose -f docker-compose.test.yml exec -T postgres psql -U testuser -d testdb -t -c "SELECT COUNT(*) FROM test_table;")
    local count=$(echo $result | tr -d ' ')
    
    if [ "$count" = "3" ]; then
        echo -e "${GREEN}✓ Data verification successful: Found 3 rows${NC}"
        return 0
    else
        echo -e "${RED}✗ Data verification failed: Expected 3 rows, found $count${NC}"
        return 1
    fi
}

# Function to drop test data
drop_test_data() {
    echo "Dropping test data..."
    docker compose -f docker-compose.test.yml exec -T postgres psql -U testuser -d testdb -c "DROP TABLE IF EXISTS test_table CASCADE;" || true
}

# Function to create S3 bucket
create_s3_bucket() {
    echo "Creating S3 bucket in MinIO..."
    # The backup container already has AWS credentials from env.sh
    # Just need to ensure we source env.sh and create the bucket
    docker compose -f docker-compose.test.yml exec -T backup sh -c '
        source ./env.sh
        aws $aws_args s3 mb s3://test-bucket 2>&1 || echo "Bucket may already exist"
        aws $aws_args s3 ls s3://test-bucket 2>&1 && echo "✓ Bucket verified" || echo "✗ Bucket verification failed"
    '
    echo "S3 bucket setup complete"
}

# Function to run backup
run_backup() {
    echo "Running backup..."
    docker compose -f docker-compose.test.yml exec -T backup sh backup.sh
    echo "Backup completed"
}

# Function to run restore
run_restore() {
    echo "Running restore..."
    docker compose -f docker-compose.test.yml exec -T backup sh restore.sh
    echo "Restore completed"
}

# Test 1: Backup and restore WITHOUT passphrase
test_without_passphrase() {
    echo -e "\n${YELLOW}===== Test 1: Backup and Restore WITHOUT Passphrase =====${NC}"
    
    # Start services without passphrase
    echo "Starting services (no passphrase)..."
    PASSPHRASE="" docker compose -f docker-compose.test.yml up -d
    
    # Wait for services
    sleep 10
    wait_for_service postgres
    wait_for_service minio
    wait_for_service backup
    
    # Create S3 bucket
    create_s3_bucket
    
    # Create test data
    create_test_data
    
    # Verify data exists
    verify_test_data
    
    # Run backup
    run_backup
    
    # Drop the test data
    drop_test_data
    
    # Verify data is gone
    echo "Verifying data was dropped..."
    local result=$(docker compose -f docker-compose.test.yml exec -T postgres psql -U testuser -d testdb -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='test_table';" 2>/dev/null || echo "0")
    local count=$(echo $result | tr -d ' ')
    if [ "$count" = "0" ]; then
        echo -e "${GREEN}✓ Data successfully dropped${NC}"
    fi
    
    # Run restore
    run_restore
    
    # Verify data is back
    if verify_test_data; then
        echo -e "${GREEN}✓✓✓ Test 1 PASSED: Backup and restore without passphrase works!${NC}"
        return 0
    else
        echo -e "${RED}✗✗✗ Test 1 FAILED: Data not restored correctly${NC}"
        return 1
    fi
}

# Test 2: Backup and restore WITH passphrase
test_with_passphrase() {
    echo -e "\n${YELLOW}===== Test 2: Backup and Restore WITH Passphrase =====${NC}"
    
    # Stop previous test
    docker compose -f docker-compose.test.yml down -v
    
    # Start services with passphrase
    echo "Starting services (with passphrase)..."
    PASSPHRASE="test_passphrase_123" docker compose -f docker-compose.test.yml up -d
    
    # Wait for services
    sleep 10
    wait_for_service postgres
    wait_for_service minio
    wait_for_service backup
    
    # Create S3 bucket
    create_s3_bucket
    
    # Create test data
    create_test_data
    
    # Verify data exists
    verify_test_data
    
    # Run backup
    run_backup
    
    # Drop the test data
    drop_test_data
    
    # Verify data is gone
    echo "Verifying data was dropped..."
    local result=$(docker compose -f docker-compose.test.yml exec -T postgres psql -U testuser -d testdb -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='test_table';" 2>/dev/null || echo "0")
    local count=$(echo $result | tr -d ' ')
    if [ "$count" = "0" ]; then
        echo -e "${GREEN}✓ Data successfully dropped${NC}"
    fi
    
    # Run restore
    run_restore
    
    # Verify data is back
    if verify_test_data; then
        echo -e "${GREEN}✓✓✓ Test 2 PASSED: Backup and restore with passphrase works!${NC}"
        return 0
    else
        echo -e "${RED}✗✗✗ Test 2 FAILED: Data not restored correctly${NC}"
        return 1
    fi
}

# Run tests
test1_result=0
test2_result=0

test_without_passphrase || test1_result=$?
test_with_passphrase || test2_result=$?

# Cleanup
cleanup

# Summary
echo -e "\n${YELLOW}===== Test Summary =====${NC}"
if [ $test1_result -eq 0 ]; then
    echo -e "${GREEN}✓ Test 1 (without passphrase): PASSED${NC}"
else
    echo -e "${RED}✗ Test 1 (without passphrase): FAILED${NC}"
fi

if [ $test2_result -eq 0 ]; then
    echo -e "${GREEN}✓ Test 2 (with passphrase): PASSED${NC}"
else
    echo -e "${RED}✗ Test 2 (with passphrase): FAILED${NC}"
fi

# Exit with error if any test failed
if [ $test1_result -ne 0 ] || [ $test2_result -ne 0 ]; then
    echo -e "\n${RED}Some tests failed!${NC}"
    exit 1
else
    echo -e "\n${GREEN}All tests passed!${NC}"
    exit 0
fi
