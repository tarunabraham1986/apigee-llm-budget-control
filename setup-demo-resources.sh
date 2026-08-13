#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "${SCRIPT_DIR}/env.sh"

export PATH=$PATH:$HOME/.apigeecli/bin

if [ -z "$PROJECT" ]; then
  echo "No PROJECT variable set in env.sh"
  exit 1
fi

TOKEN=$(gcloud auth print-access-token)

SUFFIX=$(date +%s)
echo "Unique suffix for this run: $SUFFIX"

echo "Creating Demo Developers..."
apigeecli developers create --user marketing-lead --email marketing-lead@acme.com --first Marketing --last Lead --org "$PROJECT" --token "$TOKEN" || true
apigeecli developers create --user engineering-lead --email engineering-lead@acme.com --first Engineering --last Lead --org "$PROJECT" --token "$TOKEN" || true

# Get Developer IDs (required to delete their apps)
DEV_A_ID=$(apigeecli developers get --email marketing-lead@acme.com --org "$PROJECT" --token "$TOKEN" --disable-check 2>/dev/null | jq .developerId -r || echo "")
DEV_B_ID=$(apigeecli developers get --email engineering-lead@acme.com --org "$PROJECT" --token "$TOKEN" --disable-check 2>/dev/null | jq .developerId -r || echo "")

echo "Deleting old Demo Apps..."
if [ -n "$DEV_A_ID" ] && [ "$DEV_A_ID" != "null" ]; then
  # List and delete all apps for marketing-lead
  for app in $(apigeecli developers getapps --name marketing-lead@acme.com --org "$PROJECT" --token "$TOKEN" --disable-check 2>/dev/null | jq -r '.app[].appId' 2>/dev/null || echo ""); do
    apigeecli apps delete --name "$app" --id "$DEV_A_ID" --org "$PROJECT" --token "$TOKEN" --disable-check || true
  done
fi
if [ -n "$DEV_B_ID" ] && [ "$DEV_B_ID" != "null" ]; then
  # List and delete all apps for engineering-lead
  for app in $(apigeecli developers getapps --name engineering-lead@acme.com --org "$PROJECT" --token "$TOKEN" --disable-check 2>/dev/null | jq -r '.app[].appId' 2>/dev/null || echo ""); do
    apigeecli apps delete --name "$app" --id "$DEV_B_ID" --org "$PROJECT" --token "$TOKEN" --disable-check || true
  done
fi

echo "Waiting 10 seconds for app deletions to propagate..."
sleep 10

echo "Recreating Demo API Products in the new Operations format..."
apigeecli products delete --name llm-budget-marketing-product --org "$PROJECT" --token "$TOKEN" || true
apigeecli products delete --name llm-budget-engineering-product --org "$PROJECT" --token "$TOKEN" || true

# Marketing Product: $0.02 budget (20,000 micro-dollars)
apigeecli products create --name llm-budget-marketing-product \
  --display-name "LLM Budget Marketing Product" \
  --envs "$APIGEE_ENV" \
  --opgrp "${SCRIPT_DIR}/config/operations.json" \
  --approval auto \
  --attrs "budget_limit_micro_dollars=20000,budget_interval=1,budget_timeunit=month" \
  --org "$PROJECT" \
  --token "$TOKEN" || true

# Engineering Product: $1.00 budget (1,000,000 micro-dollars)
apigeecli products create --name llm-budget-engineering-product \
  --display-name "LLM Budget Engineering Product" \
  --envs "$APIGEE_ENV" \
  --opgrp "${SCRIPT_DIR}/config/operations.json" \
  --approval auto \
  --attrs "budget_limit_micro_dollars=1000000,budget_interval=1,budget_timeunit=month" \
  --org "$PROJECT" \
  --token "$TOKEN" || true

echo "Creating Demo Developer Apps with unique names..."
APP_A_NAME="marketing-app-${SUFFIX}"
APP_B_NAME="engineering-app-${SUFFIX}"

apigeecli apps create --name "$APP_A_NAME" --email marketing-lead@acme.com --prods llm-budget-marketing-product --org "$PROJECT" --token "$TOKEN" --disable-check
apigeecli apps create --name "$APP_B_NAME" --email engineering-lead@acme.com --prods llm-budget-engineering-product --org "$PROJECT" --token "$TOKEN" --disable-check

echo "Retrieving API Keys..."
MARKETING_KEY=$(apigeecli apps get --name "$APP_A_NAME" --org "$PROJECT" --token "$TOKEN" --disable-check | jq .'[0].credentials[0].consumerKey' -r)
ENGINEERING_KEY=$(apigeecli apps get --name "$APP_B_NAME" --org "$PROJECT" --token "$TOKEN" --disable-check | jq .'[0].credentials[0].consumerKey' -r)

# Save keys to a temp env file for the traffic script
echo "export MARKETING_KEY=\"$MARKETING_KEY\"" > "${SCRIPT_DIR}/demo-keys.env"
echo "export ENGINEERING_KEY=\"$ENGINEERING_KEY\"" >> "${SCRIPT_DIR}/demo-keys.env"

echo "================================================================="
echo "Demo Resources Created Successfully!"
echo "Marketing App Name: $APP_A_NAME"
echo "Marketing App Key: $MARKETING_KEY (Budget: \$0.02/month)"
echo "Engineering App Name: $APP_B_NAME"
echo "Engineering App Key: $ENGINEERING_KEY (Budget: \$1.00/month)"
echo "Keys saved to llm-budget-control/demo-keys.env"
echo "================================================================="
