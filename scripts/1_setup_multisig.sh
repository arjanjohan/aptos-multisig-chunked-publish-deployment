#!/bin/bash
# Setup multisig account

# Source the balance check helper
source ./scripts/balance_check_helper.sh

# Check balances before proceeding
echo "🔍 Checking account balances before creating multisig..."
check_multiple_balances default owner_2

# Get address of owner 1
OWNER_1=$(aptos account lookup-address --profile default | jq -r '.Result')

# Get address of owner 2
OWNER_2=$(aptos account lookup-address --profile owner_2 | jq -r '.Result')

# Create multisig account
echo "🔑 Creating multisig account..."
echo "📝 Using owners:"
echo "   - Owner 1: $OWNER_1"
echo "   - Owner 2: $OWNER_2"

# Get private key of owner 1
OWNER_1_PK=$(cat ./keys/owner_1)

# Create multisig account using owner1's private key
RESPONSE=$(aptos multisig create \
    --private-key $OWNER_1_PK \
    --additional-owners $OWNER_2 \
    --num-signatures-required 2 \
    --assume-yes \
    )

echo "Raw response:"
echo "$RESPONSE"

# Extract address using jq if available
if command -v jq >/dev/null 2>&1; then
    MULTISIG_ADDRESS="0x$(echo "$RESPONSE" | jq -r '.Result.multisig_address')"
else
    # Fallback to grep methods if jq is not available
    MULTISIG_ADDRESS=$(echo "$RESPONSE" | grep -o '"multisig_address": "[^"]*"' | cut -d'"' -f4)
    MULTISIG_ADDRESS="0x$MULTISIG_ADDRESS"
fi

if [ -z "$MULTISIG_ADDRESS" ] || [ "$MULTISIG_ADDRESS" = "0x" ]; then
    echo "❌ Failed to extract multisig address from response"
    exit 1
fi

# Write multisig address to file
echo "$MULTISIG_ADDRESS" > ./keys/multisig_address

echo "✅ Multisig account created successfully!"
echo "📝 Multisig Address: $MULTISIG_ADDRESS"
echo "🔑 Number of owners: 2"
echo "✍️  Required signatures: 2"