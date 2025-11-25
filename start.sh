#!/bin/bash
# Start multiple ECS services

CLUSTER_NAME="be-test-ecs"
SERVICES=("test-be-auth-service" "test-be-channel-product-service" "test-be-channel-service" "test-be-chat-service" "test-be-inventory-service" "test-be-job-service" "test-be-map-service" "test-be-notification-service" "test-be-post-service" "test-be-user-service" "test-be-userfeed-service" "test-be-video-service" "test-be-videofeed-service")

for SERVICE in "${SERVICES[@]}"; do
  aws ecs update-service \
    --cluster "$CLUSTER_NAME" \
    --service "$SERVICE" \
    --desired-count 1
  
  echo "$(date) ✅ Started ECS service: $SERVICE"
done

#ec2 instance start
aws ec2 start-instances --instance-ids i-07a36961d17902df5 i-011104f2165932623 i-0f9af0bc09cd68be8

# Start all services at 10:00AM (Mon–Fri)
#0 10 * * 1-5 /home/ubuntu/start.sh >> /var/log/start.log 2>&1
