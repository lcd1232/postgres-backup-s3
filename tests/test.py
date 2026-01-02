#!/usr/bin/env python3
"""
PostgreSQL Backup/Restore Test Suite

This script tests the backup and restore functionality of the postgres-backup-s3 container
with and without encryption (passphrase).
"""

from __future__ import annotations
import subprocess
import sys
import time
import os
from typing import Optional


# ANSI color codes
class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    NC = '\033[0m'  # No Color


def print_color(message: str, color: str = Colors.NC) -> None:
    """Print a message with color."""
    print(f"{color}{message}{Colors.NC}")


def run_command(
    cmd: list[str],
    capture_output: bool = False,
    check: bool = True, 
    input_text: Optional[str] = None,
    env: Optional[dict] = None
) -> subprocess.CompletedProcess:
    """Run a shell command and return the result."""
    try:
        result = subprocess.run(
            cmd,
            capture_output=capture_output,
            text=True,
            check=check,
            input=input_text,
            env=env
        )
        return result
    except subprocess.CalledProcessError as e:
        if check:
            print_color(f"Command failed: {' '.join(cmd)}", Colors.RED)
            print_color(f"Error: {e}", Colors.RED)
            if e.stdout:
                print(f"Stdout: {e.stdout}")
            if e.stderr:
                print(f"Stderr: {e.stderr}")
        raise


def docker_compose(*args: str) -> list[str]:
    """Build docker-compose command with test config."""
    return ["docker", "compose", "-f", "docker-compose.test.yml"] + list(args)


def cleanup() -> None:
    """Clean up Docker containers and volumes."""
    print_color("Cleaning up...", Colors.YELLOW)
    run_command(docker_compose("down", "-v"), check=False)


def wait_for_service(service: str, max_attempts: int = 30) -> bool:
    """Wait for a Docker service to be ready."""
    print(f"Waiting for {service} to be ready...")
    
    for attempt in range(max_attempts):
        try:
            result = run_command(
                docker_compose("exec", "-T", service, "echo", "ready"),
                capture_output=True,
                check=False
            )
            if result.returncode == 0:
                print(f"{service} is ready!")
                return True
        except Exception:
            pass
        
        time.sleep(2)
    
    print_color(f"{service} failed to become ready", Colors.RED)
    return False


def create_test_data() -> None:
    """Create test data in PostgreSQL."""
    print("Creating test data in PostgreSQL...")
    
    sql = """
CREATE TABLE IF NOT EXISTS test_table (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    value INTEGER
);

INSERT INTO test_table (name, value) VALUES 
    ('test1', 100),
    ('test2', 200),
    ('test3', 300);
"""
    
    result = run_command(
        docker_compose("exec", "-T", "postgres", "psql", "-U", "testuser", "-d", "testdb"),
        input_text=sql,
        capture_output=True
    )
    print("Test data created successfully")


def verify_test_data() -> bool:
    """Verify test data in PostgreSQL."""
    print("Verifying test data...")
    
    result = run_command(
        docker_compose(
            "exec", "-T", "postgres", "psql", "-U", "testuser", "-d", "testdb",
            "-t", "-c", "SELECT name, value FROM test_table ORDER BY id;"
        ),
        capture_output=True
    )
    
    # Normalize output: remove spaces and empty lines
    output = result.stdout.strip()
    lines = [line.strip().replace(' ', '') for line in output.split('\n') if line.strip()]
    
    expected = ["test1|100", "test2|200", "test3|300"]
    
    if lines == expected:
        print_color("✓ Data verification successful: All records match", Colors.GREEN)
        return True
    else:
        print_color("✗ Data verification failed", Colors.RED)
        print("Expected:")
        for line in expected:
            print(f"  {line}")
        print("Got:")
        for line in lines:
            print(f"  {line}")
        return False


def drop_test_data() -> None:
    """Drop test table from PostgreSQL."""
    print("Dropping test data...")
    run_command(
        docker_compose(
            "exec", "-T", "postgres", "psql", "-U", "testuser", "-d", "testdb",
            "-c", "DROP TABLE test_table CASCADE;"
        ),
        capture_output=True
    )


def verify_table_exists() -> bool:
    """Check if test table exists in PostgreSQL."""
    result = run_command(
        docker_compose(
            "exec", "-T", "postgres", "psql", "-U", "testuser", "-d", "testdb",
            "-t", "-c", "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='test_table';"
        ),
        capture_output=True
    )
    
    count = int(result.stdout.strip())
    return count > 0


def create_s3_bucket() -> None:
    """Create S3 bucket in MinIO."""
    print("Creating S3 bucket in MinIO...")
    
    script = '''
aws --endpoint-url $S3_ENDPOINT s3 mb s3://$S3_BUCKET 2>&1 || echo "Bucket may already exist"
aws --endpoint-url $S3_ENDPOINT s3 ls s3://$S3_BUCKET 2>&1 && echo "✓ Bucket verified" || echo "✗ Bucket verification failed"
'''
    
    run_command(
        docker_compose("run", "-T", "backup", "sh", "-c", script),
        capture_output=False
    )
    print("S3 bucket setup complete")


def run_backup() -> None:
    """Run backup operation."""
    print("Running backup...")
    run_command(docker_compose("run", "-T", "backup", "sh", "backup.sh"))
    print("Backup completed")


def run_restore() -> None:
    """Run restore operation."""
    print("Running restore...")
    run_command(docker_compose("run", "-T", "backup", "sh", "restore.sh"))
    print("Restore completed")


def test_without_passphrase() -> bool:
    """Test backup and restore without passphrase."""
    print_color("\n===== Test 1: Backup and Restore WITHOUT Passphrase =====", Colors.YELLOW)
    
    try:
        print("Starting services (no passphrase)...")
        env = os.environ.copy()
        env["PASSPHRASE"] = ""
        
        run_command(
            docker_compose("up", "-d"),
            env=env
        )
        
        # Wait for services
        if not wait_for_service("postgres"):
            return False
        if not wait_for_service("minio"):
            return False
        if not wait_for_service("backup"):
            return False
        
        # Run test sequence
        create_s3_bucket()
        create_test_data()
        
        if not verify_test_data():
            return False
        
        run_backup()
        drop_test_data()
        
        print("Verifying data was dropped...")
        if not verify_table_exists():
            print_color("✓ Data successfully dropped", Colors.GREEN)
        else:
            print_color("✗ Table still exists after drop", Colors.RED)
            return False
        
        run_restore()
        
        # Verify data is restored
        if verify_test_data():
            print_color("✓✓✓ Test 1 PASSED: Backup and restore without passphrase works!", Colors.GREEN)
            return True
        else:
            print_color("✗✗✗ Test 1 FAILED: Data not restored correctly", Colors.RED)
            return False
            
    except Exception as e:
        print_color(f"✗✗✗ Test 1 FAILED with exception: {e}", Colors.RED)
        return False


def test_with_passphrase() -> bool:
    """Test backup and restore with passphrase."""
    print_color("\n===== Test 2: Backup and Restore WITH Passphrase =====", Colors.YELLOW)
    
    try:
        # Stop previous test
        run_command(docker_compose("down", "-v"))
        
        print("Starting services (with passphrase)...")
        env = os.environ.copy()
        env["PASSPHRASE"] = "test_passphrase_123"
        
        run_command(
            docker_compose("up", "-d"),
            env=env
        )
        
        # Wait for services
        if not wait_for_service("postgres"):
            return False
        if not wait_for_service("minio"):
            return False
        if not wait_for_service("backup"):
            return False
        
        # Run test sequence
        create_s3_bucket()
        create_test_data()
        
        if not verify_test_data():
            return False
        
        run_backup()
        drop_test_data()
        
        print("Verifying data was dropped...")
        if not verify_table_exists():
            print_color("✓ Data successfully dropped", Colors.GREEN)
        else:
            print_color("✗ Table still exists after drop", Colors.RED)
            return False
        
        run_restore()
        
        # Verify data is restored
        if verify_test_data():
            print_color("✓✓✓ Test 2 PASSED: Backup and restore with passphrase works!", Colors.GREEN)
            return True
        else:
            print_color("✗✗✗ Test 2 FAILED: Data not restored correctly", Colors.RED)
            return False
            
    except Exception as e:
        print_color(f"✗✗✗ Test 2 FAILED with exception: {e}", Colors.RED)
        return False


def main() -> int:
    """Main test runner."""
    # Change to tests directory
    script_dir = os.path.dirname(os.path.abspath(__file__))
    os.chdir(script_dir)
    
    print_color("===== Starting PostgreSQL Backup/Restore Tests =====", Colors.YELLOW)
    
    try:
        # Run tests
        test1_passed = test_without_passphrase()
        test2_passed = test_with_passphrase()
        
        # Cleanup
        cleanup()
        
        # Print summary
        print_color("\n===== Test Summary =====", Colors.YELLOW)
        
        if test1_passed:
            print_color("✓ Test 1 (without passphrase): PASSED", Colors.GREEN)
        else:
            print_color("✗ Test 1 (without passphrase): FAILED", Colors.RED)
        
        if test2_passed:
            print_color("✓ Test 2 (with passphrase): PASSED", Colors.GREEN)
        else:
            print_color("✗ Test 2 (with passphrase): FAILED", Colors.RED)
        
        # Exit with appropriate code
        if test1_passed and test2_passed:
            print_color("\nAll tests passed!", Colors.GREEN)
            return 0
        else:
            print_color("\nSome tests failed!", Colors.RED)
            return 1
            
    except KeyboardInterrupt:
        print_color("\nTests interrupted by user", Colors.YELLOW)
        cleanup()
        return 130
    except Exception as e:
        print_color(f"\nUnexpected error: {e}", Colors.RED)
        cleanup()
        return 1


if __name__ == "__main__":
    sys.exit(main())
