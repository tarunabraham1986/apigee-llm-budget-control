/**
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

var provider = context.getVariable("llm_provider") || "google";
var inputTokens = 0;
var outputTokens = 0;

if (provider === "google") {
    inputTokens = parseInt(context.getVariable("google_prompt_tokens") || 0, 10);
    var candidatesTokens = parseInt(context.getVariable("google_output_tokens") || 0, 10);
    var thoughtsTokens = parseInt(context.getVariable("google_thoughts_tokens") || 0, 10);
    outputTokens = candidatesTokens + thoughtsTokens;
} else if (provider === "openai") {
    inputTokens = parseInt(context.getVariable("openai_prompt_tokens") || 0, 10);
    outputTokens = parseInt(context.getVariable("openai_output_tokens") || 0, 10);
} else if (provider === "anthropic") {
    inputTokens = parseInt(context.getVariable("anthropic_prompt_tokens") || 0, 10);
    outputTokens = parseInt(context.getVariable("anthropic_output_tokens") || 0, 10);
} else {
    // Fallback: try to read generic or any populated variables
    inputTokens = parseInt(context.getVariable("openai_prompt_tokens") || context.getVariable("google_prompt_tokens") || context.getVariable("anthropic_prompt_tokens") || 0, 10);
    outputTokens = parseInt(context.getVariable("openai_output_tokens") || context.getVariable("google_output_tokens") || context.getVariable("anthropic_output_tokens") || 0, 10);
}

// Retrieve KVM config
var costConfigStr = context.getVariable("model_cost_config");
var costConfig = {};
if (costConfigStr) {
    try {
        costConfig = JSON.parse(costConfigStr);
    } catch(e) {
        // Handle JSON parse error, will use fallbacks
    }
}

// Fallback rates (Gemini 2.5 Flash rates as default: $0.30 / 1M input, $2.50 / 1M output)
var inputRate = (costConfig.input_cost_per_million !== undefined) ? costConfig.input_cost_per_million : 0.30;
var outputRate = (costConfig.output_cost_per_million !== undefined) ? costConfig.output_cost_per_million : 2.50;

var inputCost = (inputTokens / 1000000) * inputRate;
var outputCost = (outputTokens / 1000000) * outputRate;
var totalCost = inputCost + outputCost;

// Convert to micro-dollars (1/1,000,000 of a dollar) and round
var totalCostMicro = Math.round(totalCost * 1000000);
var totalCostRounded = totalCostMicro / 1000000;

context.setVariable("llm_input_tokens", java.lang.Long.valueOf(inputTokens));
context.setVariable("llm_output_tokens", java.lang.Long.valueOf(outputTokens));
context.setVariable("llm_transaction_cost", totalCostRounded);
context.setVariable("llm_transaction_cost_micro", java.lang.Long.valueOf(totalCostMicro));
context.setVariable("quota_weight", java.lang.Long.valueOf(totalCostMicro));

// Calculate remaining budget (limit - used_before - current_cost)
var budgetLimit = parseInt(context.getVariable("verifyapikey.VA-VerifyAPIKey.apiproduct.budget_limit_micro_dollars") || 0, 10);
var budgetUsedBefore = parseInt(context.getVariable("ratelimit.Q-EnforceBudget-Request.used.count") || 0, 10);
var budgetRemaining = budgetLimit - (budgetUsedBefore + totalCostMicro);
context.setVariable("llm_budget_remaining", java.lang.Long.valueOf(budgetRemaining));

var budgetRemainingUsd = budgetRemaining / 1000000;
context.setVariable("llm_budget_remaining_usd", budgetRemainingUsd.toFixed(6));

