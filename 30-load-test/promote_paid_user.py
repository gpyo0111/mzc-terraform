import boto3
import json
import requests
import time
import sys

def main():
    # Configuration
    region = "ap-northeast-2"
    bucket = "securevoice-terraform-state-455535733131-ap-northeast-2"
    
    print("[1/4] Fetching Terraform state from S3...")
    s3 = boto3.client('s3', region_name=region)
    
    try:
        # Get runtime outputs (ALB DNS)
        resp = s3.get_object(Bucket=bucket, Key="securevoice/dev/20-runtime/terraform.tfstate")
        runtime_state = json.loads(resp['Body'].read())
        alb_dns = runtime_state['outputs']['alb_dns_name']['value']
        
        # Get persistent outputs (Bastion EC2, RDS Endpoint, DB Credentials)
        resp = s3.get_object(Bucket=bucket, Key="securevoice/dev/10-persistent/terraform.tfstate")
        persistent_state = json.loads(resp['Body'].read())
        db_admin_id = persistent_state['outputs']['db_admin_instance_id']['value']
        rds_endpoint = persistent_state['outputs']['rds_endpoint']['value']
        db_name = persistent_state['outputs']['db_name']['value']
        db_user = persistent_state['outputs']['db_app_username']['value']
        db_password_arn = persistent_state['outputs']['db_app_credentials_secret_arn']['value']
    except Exception as e:
        print(f"Error fetching state: {e}")
        sys.exit(1)
        
    print(f"  ALB DNS: {alb_dns}")
    print(f"  Bastion ID: {db_admin_id}")
    print(f"  RDS Endpoint: {rds_endpoint}")
    print(f"  DB Name: {db_name}")
    print(f"  DB User: {db_user}")
    print("\n[1.5/4] Cleaning up existing user and seeding tenant via SSM...")
    ssm = boto3.client('ssm', region_name=region)
    cleanup_command = f"""
set -e
SECRET_VAL=$(aws secretsmanager get-secret-value --region {region} --secret-id {db_password_arn} --query SecretString --output text)
DB_PASS=$(python3 -c "import json; print(json.loads('''$SECRET_VAL''')['password'])")
mysql -h {rds_endpoint} -u {db_user} -p"$DB_PASS" {db_name} -e "DELETE FROM users WHERE email='paid@bank-b.com'; INSERT IGNORE INTO tenants (tenant_id, tenant_name, tenant_type) VALUES ('bank-b', 'Bank B 고객센터', 'enterprise');"
echo "Cleaned up test user and seeded tenant."
"""
    try:
        response = ssm.send_command(
            InstanceIds=[db_admin_id],
            DocumentName='AWS-RunShellScript',
            Parameters={'commands': [cleanup_command]}
        )
        command_id = response['Command']['CommandId']
        print(f"  Cleanup command sent. ID: {command_id}")
        
        # Wait for cleanup
        for _ in range(12):
            time.sleep(5)
            result = ssm.get_command_invocation(CommandId=command_id, InstanceId=db_admin_id)
            if result['Status'] in ('Success', 'Failed', 'Cancelled', 'TimedOut'):
                if result['Status'] == 'Success':
                    print("  Cleanup completed successfully.")
                else:
                    print(f"  Cleanup warning: {result['StandardErrorContent']}")
                break
    except Exception as e:
        print(f"  Cleanup failed: {e}")

    print("\n[2/4] Registering test user 'paid@bank-b.com' via API...")
    signup_url = f"http://{alb_dns}/api/signup"
    payload = {
        "email": "paid@bank-b.com",
        "password": "LoadTest1234!",
        "display_name": "유료 고객"
    }
    
    try:
        res = requests.post(signup_url, json=payload, timeout=10)
        if res.status_code in (200, 201):
            print("  User registered successfully.")
        elif res.status_code == 409:
            print("  User already exists (HTTP 409). Continuing to promotion.")
        else:
            print(f"  Signup returned status {res.status_code}: {res.text}")
    except Exception as e:
        print(f"  API signup connection failed: {e}")
        print("  Proceeding to SQL update in case the user was already created.")

    print("\n[3/4] Sending SSM Run Command to bastion host to promote user to 'paid'...")
    
    # We query the secret directly in the bastion host shell to avoid printing or hardcoding password
    shell_command = f"""
set -e
SECRET_VAL=$(aws secretsmanager get-secret-value --region {region} --secret-id {db_password_arn} --query SecretString --output text)
DB_PASS=$(python3 -c "import json; print(json.loads('''$SECRET_VAL''')['password'])")
mysql -h {rds_endpoint} -u {db_user} -p"$DB_PASS" {db_name} -e "UPDATE users SET role='paid', tenant_id='bank-b' WHERE email='paid@bank-b.com';"
echo "Successfully updated user paid@bank-b.com to role='paid'."
"""

    try:
        response = ssm.send_command(
            InstanceIds=[db_admin_id],
            DocumentName='AWS-RunShellScript',
            Parameters={'commands': [shell_command]}
        )
        command_id = response['Command']['CommandId']
        print(f"  Command sent. ID: {command_id}")
        
        print("\n[4/4] Waiting for SSM command execution to complete...")
        for _ in range(12):
            time.sleep(5)
            result = ssm.get_command_invocation(
                CommandId=command_id,
                InstanceId=db_admin_id
            )
            status = result['Status']
            print(f"  Status: {status}")
            if status in ('Success', 'Failed', 'Cancelled', 'TimedOut'):
                if status == 'Success':
                    print("\n🎉 Promotion Completed successfully!")
                    print(result['StandardOutputContent'])
                else:
                    print(f"\n❌ SSM Command failed with status: {status}")
                    print(result['StandardErrorContent'])
                break
    except Exception as e:
        print(f"  SSM Command failed: {e}")

if __name__ == "__main__":
    main()
