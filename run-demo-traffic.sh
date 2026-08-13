#!/bin/bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "${SCRIPT_DIR}/env.sh"
if [ ! -f "${SCRIPT_DIR}/demo-keys.env" ]; then
  echo "Demo keys file not found. Please run setup-demo-resources.sh first."
  exit 1
fi
source "${SCRIPT_DIR}/demo-keys.env"

echo "================================================================="
echo "Starting Demo Traffic Simulation"
echo "================================================================="

# Function to send request
send_request() {
  local app_name=$1
  local key=$2
  local model=$3
  local text=$4
  
  echo "Sending request for $app_name using $model..."
  RESPONSE=$(curl -s -w "\nHTTP_STATUS: %{http_code}\n" -X POST \
    "https://${APIGEE_HOST}/v2/samples/llm-budget-control/v1/projects/${PROJECT}/locations/${REGION:-us-west1}/publishers/google/models/${model}:generateContent" \
    --header "x-apikey: $key" \
    --header "x-llm-provider: google" \
    --header "Content-Type: application/json" \
    --data "{ \"contents\": [{ \"role\": \"user\", \"parts\": [{ \"text\": \"$text\" }] }] }")
    
  # Extract response text and status
  local status=$(echo "$RESPONSE" | grep "HTTP_STATUS" | cut -d' ' -f2)
  
  if [ "$status" -eq 200 ]; then
    local content=$(echo "$RESPONSE" | grep -v "HTTP_STATUS" | jq -r '.candidates[0].content.parts[0].text' 2>/dev/null || echo "Success (could not parse JSON)")
    echo "Status: $status"
    echo "Response: $content"
  else
    echo "Status: $status"
    echo "Error Response: $(echo "$RESPONSE" | grep -v "HTTP_STATUS")"
  fi
  echo "-----------------------------------------------------------------"
}

# 1. Team B (Engineering) sends a request (Budget: $1.00)
# This should succeed.
send_request "Engineering App" "$ENGINEERING_KEY" "gemini-2.5-pro" "Explain quantum computing in one sentence."

# 2. Team A (Marketing) sends first request (Budget: $0.01 = 10,000 micro-dollars)
# This request will cost around 5,000 - 8,000 micro-dollars (due to thinking tokens).
# It should succeed, but nearly exhaust the budget.
send_request "Marketing App" "$MARKETING_KEY" "gemini-2.5-pro" "Write a catchy slogan for a new solar watch."

# Sleep to allow quota sync (distributed quota might take a second)
echo "Waiting 3 seconds for quota synchronization..."
sleep 3

# 3. Team A (Marketing) sends second request.
# This might exceed the budget and fail (429), or get very close.
send_request "Marketing App" "$MARKETING_KEY" "gemini-2.5-pro" "Write a short email newsletter template for the watch."

# Sleep to allow quota sync
echo "Waiting 3 seconds for quota synchronization..."
sleep 3

# 4. Team A (Marketing) sends third request.
# This will definitely be blocked (429) if the previous one didn't block.
send_request "Marketing App" "$MARKETING_KEY" "gemini-2.5-pro" "Write a paragraph about solar energy."

# 5. Team B (Engineering) sends another request.
# This should still succeed because they have plenty of budget left.
send_request "Engineering App" "$ENGINEERING_KEY" "gemini-2.5-flash" "Explain the difference between a list and a tuple in Python."

echo "Demo Traffic Simulation Complete!"
