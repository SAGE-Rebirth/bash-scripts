# Create the WebSocket API
aws apigatewayv2 create-api \
    --name test-websocket-gw \
    --protocol-type WEBSOCKET \
    --route-selection-expression '$request.body.action'

# Note the API ID from the response, then use it in the following commands
# Replace {API_ID} with the actual API ID returned

# Create $connect route
aws apigatewayv2 create-route \
    --api-id {API_ID} \
    --route-key '$connect'

# Create $disconnect route
aws apigatewayv2 create-route \
    --api-id {API_ID} \
    --route-key '$disconnect'

# Create $default route
aws apigatewayv2 create-route \
    --api-id {API_ID} \
    --route-key '$default'

# Create integrations (using the same VPC Link and endpoints)
# $connect integration
aws apigatewayv2 create-integration \
    --api-id {API_ID} \
    --integration-type HTTP_PROXY \
    --integration-uri http://websocket-public-nlb-with-sg-4506c47d12c97c5d.elb.ap-south-1.amazonaws.com:3000/connect \
    --connection-type VPC_LINK \
    --connection-id e8pe92 \
    --integration-method ANY \
    --timeout-in-millis 29000

# $disconnect integration
aws apigatewayv2 create-integration \
    --api-id {API_ID} \
    --integration-type HTTP_PROXY \
    --integration-uri http://websocket-public-nlb-with-sg-4506c47d12c97c5d.elb.ap-south-1.amazonaws.com:3000/disconnect \
    --connection-type VPC_LINK \
    --connection-id e8pe92 \
    --integration-method POST \
    --timeout-in-millis 29000

# $default integration
aws apigatewayv2 create-integration \
    --api-id {API_ID} \
    --integration-type HTTP_PROXY \
    --integration-uri http://websocket-public-nlb-with-sg-4506c47d12c97c5d.elb.ap-south-1.amazonaws.com:3000/message \
    --connection-type VPC_LINK \
    --connection-id e8pe92 \
    --integration-method POST \
    --timeout-in-millis 29000

# Update routes with integrations (replace {INTEGRATION_ID} with actual IDs)
aws apigatewayv2 update-route \
    --api-id {API_ID} \
    --route-id {CONNECT_ROUTE_ID} \
    --target integrations/{CONNECT_INTEGRATION_ID}

aws apigatewayv2 update-route \
    --api-id {API_ID} \
    --route-id {DISCONNECT_ROUTE_ID} \
    --target integrations/{DISCONNECT_INTEGRATION_ID}

aws apigatewayv2 update-route \
    --api-id {API_ID} \
    --route-id {DEFAULT_ROUTE_ID} \
    --target integrations/{DEFAULT_INTEGRATION_ID}






#!/bin/bash

# Function to create WebSocket API
create_websocket_api() {
    local api_name=$1
    
    # Create API
    api_response=$(aws apigatewayv2 create-api \
        --name "$api_name" \
        --protocol-type WEBSOCKET \
        --route-selection-expression '$request.body.action')
    
    api_id=$(echo $api_response | jq -r '.ApiId')
    echo "Created API: $api_name with ID: $api_id"
    
    # Create routes
    connect_route=$(aws apigatewayv2 create-route --api-id $api_id --route-key '$connect')
    disconnect_route=$(aws apigatewayv2 create-route --api-id $api_id --route-key '$disconnect')
    default_route=$(aws apigatewayv2 create-route --api-id $api_id --route-key '$default')
    
    # Extract route IDs
    connect_route_id=$(echo $connect_route | jq -r '.RouteId')
    disconnect_route_id=$(echo $disconnect_route | jq -r '.RouteId')
    default_route_id=$(echo $default_route | jq -r '.RouteId')
    
    # Create integrations
    connect_integration=$(aws apigatewayv2 create-integration \
        --api-id $api_id \
        --integration-type HTTP_PROXY \
        --integration-uri http://websocket-public-nlb-with-sg-4506c47d12c97c5d.elb.ap-south-1.amazonaws.com:3000/connect \
        --connection-type VPC_LINK \
        --connection-id e8pe92 \
        --integration-method ANY \
        --timeout-in-millis 29000)
    
    disconnect_integration=$(aws apigatewayv2 create-integration \
        --api-id $api_id \
        --integration-type HTTP_PROXY \
        --integration-uri http://websocket-public-nlb-with-sg-4506c47d12c97c5d.elb.ap-south-1.amazonaws.com:3000/disconnect \
        --connection-type VPC_LINK \
        --connection-id e8pe92 \
        --integration-method POST \
        --timeout-in-millis 29000)
    
    default_integration=$(aws apigatewayv2 create-integration \
        --api-id $api_id \
        --integration-type HTTP_PROXY \
        --integration-uri http://websocket-public-nlb-with-sg-4506c47d12c97c5d.elb.ap-south-1.amazonaws.com:3000/message \
        --connection-type VPC_LINK \
        --connection-id e8pe92 \
        --integration-method POST \
        --timeout-in-millis 29000)
    
    # Extract integration IDs
    connect_integration_id=$(echo $connect_integration | jq -r '.IntegrationId')
    disconnect_integration_id=$(echo $disconnect_integration | jq -r '.IntegrationId')
    default_integration_id=$(echo $default_integration | jq -r '.IntegrationId')
    
    # Update routes with integrations
    aws apigatewayv2 update-route --api-id $api_id --route-id $connect_route_id --target integrations/$connect_integration_id
    aws apigatewayv2 update-route --api-id $api_id --route-id $disconnect_route_id --target integrations/$disconnect_integration_id
    aws apigatewayv2 update-route --api-id $api_id --route-id $default_route_id --target integrations/$default_integration_id
    
    echo "Completed setup for $api_name"
    echo "WebSocket URL: wss://$api_id.execute-api.ap-south-1.amazonaws.com"
}

# Create both APIs
create_websocket_api "test-websocket-gw"
create_websocket_api "call-chat-websocket-gw"
