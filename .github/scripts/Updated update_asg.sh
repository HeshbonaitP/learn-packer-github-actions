#!/bin/bash
# Set execute permissions for the script
chmod +x "$0"
set -e

AMI_ID=$1
FRONTEND_ASG_NAME=$2
LAUNCH_TEMPLATE_NAME=$3
RDS_INSTANCE_IDENTIFIER="heshbonaitpdev"

# Define variables for the Java application
APP_DIR="/tmp"    # Updated to the correct directory
JAR_FILE=$(find $APP_DIR -name "*.jar" | head -n 1) # Assumes the JAR file is in the app directory
JAVA_VERSION="17"
JAVA_OPTS="-Xmx512m -Dspring.profiles.active=production -Dspring.jpa.hibernate.ddl-auto=none -Dspring.jpa.properties.hibernate.temp.use_jdbc_metadata_defaults=false"

echo "Starting ASG update process with AMI ID: $AMI_ID"

echo "Checking contents of $APP_DIR:"
if [ -d "$APP_DIR" ]; then
    ls -l $APP_DIR
else
    echo "$APP_DIR does not exist"
fi

echo "Checking for JAR files:"
find $APP_DIR -name "*.jar" || echo "No JAR files found in $APP_DIR"

echo "Checking permissions:"
ls -ld $APP_DIR  

# Check if Launch Template exists
if ! aws ec2 describe-launch-templates --launch-template-names "$LAUNCH_TEMPLATE_NAME" > /dev/null 2>&1; then
    echo "Error: Launch Template $LAUNCH_TEMPLATE_NAME does not exist."
    echo "Please create the Launch Template manually with the required settings before running this script."
    exit 1
else
    echo "Launch Template $LAUNCH_TEMPLATE_NAME exists. Proceeding with update."
fi

echo "Temporarily increasing Max Capacity to 2"
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name $FRONTEND_ASG_NAME \
  --max-size 2

echo "Creating new Launch Template version"
LATEST_LAUNCH_TEMPLATE=$(aws ec2 describe-launch-template-versions \
  --launch-template-name "$LAUNCH_TEMPLATE_NAME" \
  --versions '$Latest' \
  --query 'LaunchTemplateVersions[0].LaunchTemplateData' \
  --output json)

# Update only the AMI ID in the new version
NEW_LAUNCH_TEMPLATE_DATA=$(echo $LATEST_LAUNCH_TEMPLATE | jq --arg AMI_ID "$AMI_ID" '.ImageId = $AMI_ID')

NEW_LAUNCH_TEMPLATE_VERSION=$(aws ec2 create-launch-template-version \
  --launch-template-name "$LAUNCH_TEMPLATE_NAME" \
  --launch-template-data "$NEW_LAUNCH_TEMPLATE_DATA" \
  --query 'LaunchTemplateVersion.VersionNumber' \
  --output text)

echo "Updating ASG with new Launch Template version"
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name $FRONTEND_ASG_NAME \
  --launch-template LaunchTemplateName=$LAUNCH_TEMPLATE_NAME,Version=$NEW_LAUNCH_TEMPLATE_VERSION

echo "Starting instance refresh"
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name $FRONTEND_ASG_NAME \
  --preferences '{"MinHealthyPercentage": 100}'

echo "Waiting for instance refresh to complete..."
while true; do
  REFRESH_STATUS=$(aws autoscaling describe-instance-refreshes \
    --auto-scaling-group-name $FRONTEND_ASG_NAME \
    --query 'InstanceRefreshes[0].Status' \
    --output text)
  
  if [ "$REFRESH_STATUS" = "Successful" ]; then
    echo "Instance refresh completed successfully!"
    break
  elif [ "$REFRESH_STATUS" = "Failed" ] || [ "$REFRESH_STATUS" = "Cancelled" ]; then
    echo "Instance refresh failed or was cancelled. Status: $REFRESH_STATUS"
    exit 1
  elif [ "$REFRESH_STATUS" = "InProgress" ]; then
    echo "Instance refresh still in progress. Current status: $REFRESH_STATUS"
    sleep 30
  else
    echo "Unexpected status: $REFRESH_STATUS. Checking again..."
    sleep 30
  fi
done

# Get the ID of the new instance
NEW_INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names $FRONTEND_ASG_NAME \
  --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
  --output text | awk '{print $NF}')

echo "New instance ID: $NEW_INSTANCE_ID"

echo "Waiting for instance to be fully initialized..."
sleep 300  # Wait for 5 minutes

echo "Checking instance state..."
INSTANCE_STATE=$(aws ec2 describe-instances --instance-ids $NEW_INSTANCE_ID --query 'Reservations[0].Instances[0].State.Name' --output text)
echo "Instance state: $INSTANCE_STATE"

if [ "$INSTANCE_STATE" != "running" ]; then
  echo "Error: Instance is not in 'running' state"
  exit 1
fi

echo "Checking IAM instance profile..."
INSTANCE_PROFILE=$(aws ec2 describe-instances --instance-ids $NEW_INSTANCE_ID --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text)
echo "Instance profile: $INSTANCE_PROFILE"

echo "Waiting for ALB to report the target as healthy..."
TARGET_GROUP_ARN=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names $FRONTEND_ASG_NAME \
  --query 'AutoScalingGroups[0].TargetGroupARNs[0]' \
  --output text)

while true; do
  TARGET_HEALTH=$(aws elbv2 describe-target-health \
    --target-group-arn $TARGET_GROUP_ARN \
    --targets Id=$NEW_INSTANCE_ID \
    --query 'TargetHealthDescriptions[0].TargetHealth.State' \
    --output text)
  
  if [ "$TARGET_HEALTH" = "healthy" ]; then
    echo "New instance is healthy in ALB!"
    break
  elif [ "$TARGET_HEALTH" = "unhealthy" ]; then
    echo "New instance is unhealthy in ALB. Please check the application manually."
    exit 1
  else
    echo "Target health is $TARGET_HEALTH. Waiting..."
    sleep 30
  fi
done

echo "Setting up automatic connection between EC2 and RDS..."

# Set up the connection between EC2 and RDS
CONNECTION_RESULT=$(aws rds modify-db-instance \
  --db-instance-identifier $RDS_INSTANCE_IDENTIFIER \
  --aws-cli-connect-resources $NEW_INSTANCE_ID \
  --apply-immediately)

CONNECTION_STATUS=$(echo $CONNECTION_RESULT | jq -r '.DBInstance.DBInstanceStatus')

if [ "$CONNECTION_STATUS" = "available" ] || [ "$CONNECTION_STATUS" = "modifying" ]; then
  echo "Connection setup initiated successfully. RDS status: $CONNECTION_STATUS"
else
  echo "Error setting up connection. RDS status: $CONNECTION_STATUS"
  exit 1
fi

echo "Waiting for RDS modification to complete..."
aws rds wait db-instance-available --db-instance-identifier $RDS_INSTANCE_IDENTIFIER

echo "RDS-EC2 connection setup completed successfully!"

echo "ASG update process completed successfully!"


echo "ASG update process completed successfully!"
