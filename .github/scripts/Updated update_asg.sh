#!/bin/bash
# Set execute permissions for the script
chmod +x "$0"
set -e

AMI_ID=$1
FRONTEND_ASG_NAME=$2
LAUNCH_TEMPLATE_NAME=$3

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

echo "Waiting for instance to be fully initialized..."
sleep 300  # Wait for 5 minutes

# Prompt for manual steps
echo "AMIT Instance initialization complete. Please perform the following manual steps:"
echo "AMIT 1. Connect to the database manually"
echo "AMIT 2. Start the application"
echo "AMIT 3. Verify that the application is running correctly"
echo "AMIT 4. Perform any additional health checks as needed"

# Wait for user confirmation
read -p "AMIT Press Enter when you have completed these steps and the application is healthy..."

echo "AMIT Manual verification completed. Proceeding with the rest of the process."

# Remove any ALB health check related code here

echo "ASG update process completed successfully!"
