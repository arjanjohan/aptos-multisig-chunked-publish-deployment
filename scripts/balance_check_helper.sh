#!/bin/bash
# Balance check helper for Aptos multisig deployment scripts
# Checks if an account has sufficient balance (at least 0.1 APT) before executing transactions

# Function to check account balance
# Usage: check_balance <profile_name>
check_balance() {
    local profile="$1"

    # Minimum balance required: 0.1 APT = 1000000 octas
    local MIN_BALANCE=1000000

    # Get account balance
    local balance_response
    balance_response=$(aptos account balance --profile "$profile" 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "❌ Failed to get balance for profile: $profile"
        echo "   Make sure the profile exists and is properly configured"
        exit 1
    fi

    # Extract balance using jq
    local balance
    balance=$(echo "$balance_response" | jq -r '.Result[0].balance // 0')

    if [ "$balance" = "null" ] || [ -z "$balance" ]; then
        echo "❌ Could not extract balance from response"
        echo "   Response: $balance_response"
        exit 1
    fi

    # Check if balance is sufficient
    if [ "$balance" -lt "$MIN_BALANCE" ]; then
        echo "❌ Insufficient balance for $profile"
        echo "   Required: $MIN_BALANCE octas (0.1 APT)"
        echo "   Current: $balance octas ($(echo "scale=6; $balance / 100000000" | bc) APT)"
        echo "   Please fund the account with at least 0.1 APT before proceeding"
        exit 1
    fi

}

# Function to check multiple account balances
# Usage: check_multiple_balances <profile1> <profile2> ... [profileN]
check_multiple_balances() {
    local profiles=("$@")

    echo "🔍 Checking balances for ${#profiles[@]} account(s)..."
    echo ""

    for profile in "${profiles[@]}"; do
        check_balance "$profile" "$profile"
    done

}

# If script is run directly, show usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Balance Check Helper for Aptos Multisig Deployment"
    echo "Usage:"
    echo "  source ./scripts/balance_check_helper.sh"
    echo "  check_balance <profile_name>"
    echo "  check_multiple_balances <profile1> <profile2> ..."
    echo ""
    echo "Examples:"
    echo "  check_balance default"
    echo "  check_multiple_balances default owner_2"
    echo ""
    echo "Note: This script should be sourced, not executed directly"
    exit 1
fi
