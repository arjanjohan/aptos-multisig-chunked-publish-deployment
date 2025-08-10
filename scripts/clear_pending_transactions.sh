#!/bin/bash
# Helper script to clear pending transactions from a multisig account
# Detects pending transactions and calculates their sequence numbers for clearing

# Source the balance check helper
source ./scripts/balance_check_helper.sh

# Function to clear pending transactions
# Usage: clear_pending_transactions <multisig_address> <owner_profile> [owner_name]
# Note: This function will reject from the specified owner, but may need both owners to reject
# before execute-reject can succeed. If execute-reject fails, the other owner may need to reject as well.
clear_pending_transactions() {
    local multisig_address="$1"
    local owner_profile="$2"
    local owner_name="${3:-$owner_profile}"

    echo "🔍 Checking for pending transactions in multisig: $multisig_address"
    echo "👤 Using owner profile: $owner_name"

    # Check balance before proceeding
    check_balance "$owner_profile" "$owner_name"

    # Get the next sequence number (this will be the sequence number of the next transaction)
    echo "📊 Getting next sequence number..."
    local next_seq_response
    next_seq_response=$(aptos move view \
        --function-id 0x1::multisig_account::next_sequence_number \
        --args address:"$multisig_address" 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "❌ Failed to get next sequence number for multisig: $multisig_address"
        echo "   Make sure the multisig address is correct and the account exists"
        exit 1
    fi

    local next_seq
    next_seq=$(echo "$next_seq_response" | jq -r '.Result[0] // 0')

    if [ "$next_seq" = "null" ] || [ -z "$next_seq" ]; then
        echo "❌ Could not extract next sequence number from response"
        echo "   Response: $next_seq_response"
        exit 1
    fi

    echo "   Next sequence number: $next_seq"

    # Get pending transactions
    echo "🔍 Getting pending transactions..."
    local pending_response
    pending_response=$(aptos move view \
        --function-id 0x1::multisig_account::get_pending_transactions \
        --args address:"$multisig_address" 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "❌ Failed to get pending transactions for multisig: $multisig_address"
        exit 1
    fi

    local pending_count
    pending_count=$(echo "$pending_response" | jq -r '.Result[0] | length // 0')

    if [ "$pending_count" = "null" ] || [ -z "$pending_count" ]; then
        echo "❌ Could not extract pending transactions count from response"
        echo "   Response: $pending_response"
        exit 1
    fi

    echo "   Pending transactions found: $pending_count"

    if [ "$pending_count" -eq 0 ]; then
        echo "✅ No pending transactions to clear"
        return 0
    fi

    # Get owner's private key
    local owner_pk
    if [ "$owner_profile" = "default" ]; then
        owner_pk=$(cat ./keys/owner_1)
    elif [ "$owner_profile" = "owner_2" ]; then
        owner_pk=$(cat ./keys/owner_2)
    else
        echo "❌ Unknown owner profile: $owner_profile"
        echo "   Supported profiles: default, owner_2"
        exit 1
    fi

    echo "🔑 Using private key for profile: $owner_profile"

    # Calculate sequence numbers of pending transactions
    # Since transactions are sequential, pending transactions have sequence numbers:
    # next_seq - pending_count, next_seq - pending_count + 1, ..., next_seq - 1
    local start_seq=$((next_seq - pending_count))
    local end_seq=$((next_seq - 1))

    echo "📊 Pending transaction sequence numbers: $start_seq to $end_seq"

    # Clear each pending transaction
    local cleared_count=0
    local remaining_pending=$pending_count

    # Since execute-reject always removes the first pending transaction (lowest sequence number),
    # we need to process them one by one, starting from the lowest
    while [ $remaining_pending -gt 0 ]; do
        echo "🔄 Processing pending transaction (${remaining_pending} remaining)..."

        # Get current sequence number (it may have changed after previous operations)
        local current_next_seq_response
        current_next_seq_response=$(aptos move view \
            --function-id 0x1::multisig_account::next_sequence_number \
            --args address:"$multisig_address" 2>/dev/null)

        if [ $? -ne 0 ]; then
            echo "❌ Failed to get current sequence number"
            break
        fi

        local current_next_seq
        current_next_seq=$(echo "$current_next_seq_response" | jq -r '.Result[0] // 0')

        # Calculate the sequence number of the first pending transaction
        local current_pending_seq=$((current_next_seq - remaining_pending))

        echo "   📊 Current first pending transaction sequence number: $current_pending_seq"

        # First, reject the transaction from this owner
        echo "   📝 Rejecting transaction from owner..."
        local reject_response
        reject_response=$(aptos multisig reject \
            --multisig-address "$multisig_address" \
            --sequence-number "$current_pending_seq" \
            --private-key "$owner_pk" \
            --assume-yes 2>&1)

        if [ $? -ne 0 ]; then
            echo "❌ Failed to reject transaction with sequence number: $current_pending_seq"
            echo "   Response: $reject_response"
            break
        fi

        echo "   ✅ Successfully rejected transaction from owner"

        # Now we need to get the other owner to reject it as well, then execute-reject
        # For now, we'll try to execute-reject directly (this might work if we have enough rejections)
        echo "   🗑️ Attempting to execute-reject transaction..."
        local execute_reject_response
        execute_reject_response=$(aptos multisig execute-reject \
            --multisig-address "$multisig_address" \
            --assume-yes 2>&1)

        if [ $? -eq 0 ]; then
            echo "✅ Successfully executed reject for transaction with sequence number: $current_pending_seq"
            cleared_count=$((cleared_count + 1))
            remaining_pending=$((remaining_pending - 1))
        else
            echo "⚠️ execute-reject failed, transaction may need more rejections"
            echo "   Response: $execute_reject_response"

            # Try to reject from the other owner as well if we have access to their key
            echo "   🔄 Trying to reject from other owner to get enough rejections..."
            local other_owner_profile
            local other_owner_pk

            if [ "$owner_profile" = "default" ]; then
                other_owner_profile="owner_2"
                other_owner_pk=$(cat ./keys/owner_2 2>/dev/null || echo "")
            elif [ "$owner_profile" = "owner_2" ]; then
                other_owner_profile="default"
                other_owner_pk=$(cat ./keys/owner_2 2>/dev/null || echo "")
            fi

            if [ -n "$other_owner_pk" ]; then
                echo "   📝 Rejecting from other owner ($other_owner_profile)..."
                local other_reject_response
                other_reject_response=$(aptos multisig reject \
                    --multisig-address "$multisig_address" \
                    --sequence-number "$seq" \
                    --private-key "$other_owner_pk" \
                    --assume-yes 2>&1)

                if [ $? -eq 0 ]; then
                    echo "   ✅ Successfully rejected from other owner"

                    # Now try execute-reject again
                    echo "   🗑️ Trying execute-reject again with both rejections..."
                    local retry_execute_reject_response
                    retry_execute_reject_response=$(aptos multisig execute-reject \
                        --multisig-address "$multisig_address" \
                        --assume-yes 2>&1)

                    if [ $? -eq 0 ]; then
                        echo "✅ Successfully executed reject for transaction with sequence number: $seq (with both rejections)"
                        cleared_count=$((cleared_count + 1))
                    else
                        echo "❌ Still failed to execute-reject even with both rejections"
                        echo "   Response: $retry_execute_reject_response"
                    fi
                else
                    echo "   ❌ Failed to reject from other owner: $other_reject_response"
                fi
            else
                echo "   ⚠️ Could not access other owner's private key, trying alternative method..."

                # Try alternative method with execute-with-payload
                local execute_response
                execute_response=$(aptos multisig execute-with-payload \
                    --multisig-address "$multisig_address" \
                    --json-file <(echo '{"function_id": "0x1::multisig_account::reject_transaction", "args": []}') \
                    --assume-yes 2>&1)

                if [ $? -eq 0 ]; then
                    echo "✅ Successfully cleared transaction with sequence number: $seq (alternative method)"
                    cleared_count=$((cleared_count + 1))
                else
                    echo "❌ Failed to clear transaction with sequence number: $seq"
                    echo "   Alternative method response: $execute_response"
                fi
            fi
        fi

        # Small delay between operations
        sleep 1
    done

    echo "🎉 Clearing process completed!"
    echo "📊 Summary:"
    echo "   - Pending transactions found: $pending_count"
    echo "   - Successfully cleared: $cleared_count"
    echo "   - Failed to clear: $((pending_count - cleared_count))"

    if [ $cleared_count -eq $pending_count ]; then
        echo "✅ All pending transactions cleared successfully!"
        return 0
    else
        echo "⚠️ Some transactions could not be cleared"
        return 1
    fi
}

# Function to check if there are pending transactions
# Usage: check_pending_transactions <multisig_address>
check_pending_transactions() {
    local multisig_address="$1"

    echo "🔍 Checking for pending transactions in multisig: $multisig_address"

    # Get pending transactions
    local pending_response
    pending_response=$(aptos move view \
        --function-id 0x1::multisig_account::get_pending_transactions \
        --args address:"$multisig_address" 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "❌ Failed to get pending transactions for multisig: $multisig_address"
        return 1
    fi

    local pending_count
    pending_count=$(echo "$pending_response" | jq -r '.Result[0] | length // 0')

    if [ "$pending_count" = "null" ] || [ -z "$pending_count" ]; then
        echo "❌ Could not extract pending transactions count from response"
        return 1
    fi

    if [ "$pending_count" -gt 0 ]; then
        echo "⚠️ Found $pending_count pending transaction(s)"
        return 0  # Return 0 (success) if pending transactions exist
    else
        echo "✅ No pending transactions found"
        return 1  # Return 1 (failure) if no pending transactions
    fi
}

# If script is run directly, show usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Clear Pending Transactions Helper for Aptos Multisig"
    echo ""
    echo "Usage:"
    echo "  source ./scripts/clear_pending_transactions.sh"
    echo "  clear_pending_transactions <multisig_address> <owner_profile> [owner_name]"
    echo "  check_pending_transactions <multisig_address>"
    echo ""
    echo "Examples:"
    echo "  clear_pending_transactions 0x123... default 'Owner 1'"
    echo "  clear_pending_transactions 0x123... owner_2"
    echo "  check_pending_transactions 0x123..."
    echo ""
    echo "Note: This script should be sourced, not executed directly"
    exit 1
fi
