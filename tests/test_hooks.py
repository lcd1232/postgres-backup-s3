#!/usr/bin/env python3
"""
Test suite for backup/restore hook commands
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
    env: Optional[dict[str, str]] = None
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


def create_s3_bucket() -> None:
    """Create S3 bucket in MinIO."""
    print("Creating S3 bucket in MinIO...")
    
    script = '''
source ./env.sh
aws --endpoint-url $S3_ENDPOINT s3 mb s3://$S3_BUCKET 2>&1 || echo "Bucket may already exist"
aws --endpoint-url $S3_ENDPOINT s3 ls s3://$S3_BUCKET 2>&1 && echo "✓ Bucket verified" || echo "✗ Bucket verification failed"
'''
    
    run_command(
        docker_compose("run", "-T", "backup", "sh", "-c", script),
        capture_output=False
    )
    print("S3 bucket setup complete")


def test_backup_hooks() -> bool:
    """Test backup with hooks."""
    print_color("\n===== Test: Backup with Hooks =====", Colors.YELLOW)
    
    try:
        # Create marker files in the backup container
        setup_script = '''
# Pre-command creates a file
echo "echo 'PRE_BACKUP' > /tmp/pre_marker" > /tmp/pre_cmd.sh
# Success command creates a file
echo "echo 'BACKUP_SUCCESS' > /tmp/success_marker" > /tmp/success_cmd.sh
# Make them executable
chmod +x /tmp/pre_cmd.sh /tmp/success_cmd.sh
'''
        
        run_command(
            docker_compose("exec", "-T", "backup", "sh", "-c", setup_script),
            capture_output=False
        )
        
        # Set environment variables for hooks
        env = os.environ.copy()
        env["BACKUP_PRE_COMMAND"] = "/tmp/pre_cmd.sh"
        env["BACKUP_POST_SUCCESS_COMMAND"] = "/tmp/success_cmd.sh"
        env["BACKUP_POST_FAILURE_COMMAND"] = "echo 'BACKUP_FAILED' > /tmp/failure_marker"
        
        # Run backup with hooks
        print("Running backup with hooks...")
        result = run_command(
            docker_compose("run", "-T", "backup", "sh", "backup.sh"),
            capture_output=True,
            env=env
        )
        
        print("Backup output:")
        print(result.stdout)
        
        # Verify hooks were executed
        print("Verifying hooks were executed...")
        
        # Check pre-command marker
        pre_result = run_command(
            docker_compose("exec", "-T", "backup", "cat", "/tmp/pre_marker"),
            capture_output=True,
            check=False
        )
        
        # Check success-command marker  
        success_result = run_command(
            docker_compose("exec", "-T", "backup", "cat", "/tmp/success_marker"),
            capture_output=True,
            check=False
        )
        
        # Check failure-command marker (should not exist)
        failure_result = run_command(
            docker_compose("exec", "-T", "backup", "cat", "/tmp/failure_marker"),
            capture_output=True,
            check=False
        )
        
        pre_executed = pre_result.returncode == 0 and "PRE_BACKUP" in pre_result.stdout
        success_executed = success_result.returncode == 0 and "BACKUP_SUCCESS" in success_result.stdout
        failure_not_executed = failure_result.returncode != 0
        
        if pre_executed and success_executed and failure_not_executed:
            print_color("✓✓✓ Test PASSED: Backup hooks executed correctly", Colors.GREEN)
            return True
        else:
            print_color("✗✗✗ Test FAILED: Hooks did not execute as expected", Colors.RED)
            print(f"  Pre-command executed: {pre_executed}")
            print(f"  Success command executed: {success_executed}")
            print(f"  Failure command not executed: {failure_not_executed}")
            return False
            
    except Exception as e:
        print_color(f"✗✗✗ Test FAILED with exception: {e}", Colors.RED)
        import traceback
        traceback.print_exc()
        return False


def test_restore_hooks() -> bool:
    """Test restore with hooks."""
    print_color("\n===== Test: Restore with Hooks =====", Colors.YELLOW)
    
    try:
        # Set environment variables for hooks
        env = os.environ.copy()
        env["RESTORE_PRE_COMMAND"] = "echo 'PRE_RESTORE' > /tmp/restore_pre_marker"
        env["RESTORE_POST_SUCCESS_COMMAND"] = "echo 'RESTORE_SUCCESS' > /tmp/restore_success_marker"
        env["RESTORE_POST_FAILURE_COMMAND"] = "echo 'RESTORE_FAILED' > /tmp/restore_failure_marker"
        
        # Run restore with hooks
        print("Running restore with hooks...")
        result = run_command(
            docker_compose("run", "-T", "backup", "sh", "restore.sh"),
            capture_output=True,
            env=env
        )
        
        print("Restore output:")
        print(result.stdout)
        
        # Verify hooks were executed
        print("Verifying hooks were executed...")
        
        # Check pre-command marker
        pre_result = run_command(
            docker_compose("exec", "-T", "backup", "cat", "/tmp/restore_pre_marker"),
            capture_output=True,
            check=False
        )
        
        # Check success-command marker
        success_result = run_command(
            docker_compose("exec", "-T", "backup", "cat", "/tmp/restore_success_marker"),
            capture_output=True,
            check=False
        )
        
        # Check failure-command marker (should not exist)
        failure_result = run_command(
            docker_compose("exec", "-T", "backup", "cat", "/tmp/restore_failure_marker"),
            capture_output=True,
            check=False
        )
        
        pre_executed = pre_result.returncode == 0 and "PRE_RESTORE" in pre_result.stdout
        success_executed = success_result.returncode == 0 and "RESTORE_SUCCESS" in success_result.stdout
        failure_not_executed = failure_result.returncode != 0
        
        if pre_executed and success_executed and failure_not_executed:
            print_color("✓✓✓ Test PASSED: Restore hooks executed correctly", Colors.GREEN)
            return True
        else:
            print_color("✗✗✗ Test FAILED: Hooks did not execute as expected", Colors.RED)
            print(f"  Pre-command executed: {pre_executed}")
            print(f"  Success command executed: {success_executed}")
            print(f"  Failure command not executed: {failure_not_executed}")
            return False
            
    except Exception as e:
        print_color(f"✗✗✗ Test FAILED with exception: {e}", Colors.RED)
        import traceback
        traceback.print_exc()
        return False


def main() -> int:
    """Main test runner."""
    # Change to tests directory
    script_dir = os.path.dirname(os.path.abspath(__file__))
    os.chdir(script_dir)
    
    print_color("===== Starting Hook Tests =====", Colors.YELLOW)
    
    test_backup_passed = False
    test_restore_passed = False
    
    try:
        print("Starting services...")
        env = os.environ.copy()
        env["PASSPHRASE"] = ""
        
        run_command(
            docker_compose("up", "-d"),
            env=env
        )
        
        # Wait for services
        if not wait_for_service("postgres"):
            return 1
        if not wait_for_service("minio"):
            return 1
        if not wait_for_service("backup"):
            return 1
        
        # Setup test environment
        create_s3_bucket()
        create_test_data()
        
        if not verify_test_data():
            return 1
        
        # Run hook tests
        test_backup_passed = test_backup_hooks()
        
        # Drop and restore data for restore hooks test
        drop_test_data()
        test_restore_passed = test_restore_hooks()
        
        # Verify data after restore
        if not verify_test_data():
            print_color("Data verification failed after restore", Colors.RED)
            return 1
        
        # Print summary
        print_color("\n===== Test Summary =====", Colors.YELLOW)
        
        if test_backup_passed:
            print_color("✓ Backup hooks test: PASSED", Colors.GREEN)
        else:
            print_color("✗ Backup hooks test: FAILED", Colors.RED)
        
        if test_restore_passed:
            print_color("✓ Restore hooks test: PASSED", Colors.GREEN)
        else:
            print_color("✗ Restore hooks test: FAILED", Colors.RED)
        
        # Exit with appropriate code
        if test_backup_passed and test_restore_passed:
            print_color("\nAll tests passed!", Colors.GREEN)
            return 0
        else:
            print_color("\nSome tests failed!", Colors.RED)
            return 1
            
    except KeyboardInterrupt:
        print_color("\nTests interrupted by user", Colors.YELLOW)
        return 130
    except Exception as e:
        print_color(f"\nUnexpected error: {e}", Colors.RED)
        import traceback
        traceback.print_exc()
        return 1
    finally:
        # Always cleanup
        cleanup()


if __name__ == "__main__":
    sys.exit(main())
