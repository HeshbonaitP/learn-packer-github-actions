#!/bin/bash
set -e

AMI_ID=$1
FRONTEND_ASG_NAME=$2
LAUNCH_TEMPLATE_NAME=$3
RDS_INSTANCE_IDENTIFIER="heshbonaitpdev"

echo "Starting ASG update process with AMI ID: $AMI_ID"

# Function to check if instance is running and has passed status checks
check_instance_health() {
    local instance_id=$1
    local max_attempts=20
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        status=$(aws ec2 describe-instance-status --instance-ids $instance_id --query 'InstanceStatuses[0].InstanceStatus.Status' --output text)
        if [ "$status" = "ok" ]; then
            echo "Instance $instance_id is healthy."
            return 0
        fi
        echo "Attempt $attempt: Instance not yet healthy. Waiting..."
        sleep 30
        ((attempt++))
    done
    echo "Instance did not become healthy within the expected time."
    return 1
}

# Update Launch Template
echo "Creating new Launch Template version"
LATEST_LAUNCH_TEMPLATE=$(aws ec2 describe-launch-template-versions \
  --launch-template-name "$LAUNCH_TEMPLATE_NAME" \
  --versions '$Latest' \
  --query 'LaunchTemplateVersions[0].LaunchTemplateData' \
  --output json)

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
REFRESH_ID=$(aws autoscaling start-instance-refresh \
  --auto-scaling-group-name $FRONTEND_ASG_NAME \
  --preferences '{"MinHealthyPercentage": 100}' \
  --query 'InstanceRefreshId' \
  --output text)

echo "Waiting for instance refresh to complete..."
while true; do
  REFRESH_STATUS=$(aws autoscaling describe-instance-refreshes \
    --auto-scaling-group-name $FRONTEND_ASG_NAME \
    --instance-refresh-ids $REFRESH_ID \
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

# Check if the new instance is healthy
if ! check_instance_health $NEW_INSTANCE_ID; then
    echo "New instance did not pass health checks. Exiting."
    exit 1
fi

echo "Setting up automatic connection between EC2 and RDS..."
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

# Wait for the application to start
echo "Waiting for application to start and connect to the database..."
sleep 120

echo "Checking ALB target health..."
TARGET_GROUP_ARN=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names $FRONTEND_ASG_NAME \
  --query 'AutoScalingGroups[0].TargetGroupARNs[0]' \
  --output text)

max_attempts=20
attempt=1
while [ $attempt -le $max_attempts ]; do
  TARGET_HEALTH=$(aws elbv2 describe-target-health \
    --target-group-arn $TARGET_GROUP_ARN \
    --targets Id=$NEW_INSTANCE_ID \
    --query 'TargetHealthDescriptions[0].TargetHealth.State' \
    --output text)
  
  if [ "$TARGET_HEALTH" = "healthy" ]; then
    echo "New instance is healthy in ALB!"
    break
  elif [ "$TARGET_HEALTH" = "unhealthy" ]; then
    echo "New instance is unhealthy in ALB. Attempt $attempt of $max_attempts"
    if [ $attempt -eq $max_attempts ]; then
      echo "Max attempts reached. Please check the application manually."
      exit 1
    fi
  else
    echo "Target health is $TARGET_HEALTH. Waiting... Attempt $attempt of $max_attempts"
  fi
  sleep 30
  ((attempt++))
done

echo "ASG update process completed successfully!"
