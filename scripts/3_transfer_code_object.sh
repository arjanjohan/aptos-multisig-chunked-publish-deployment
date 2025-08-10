#!/bin/bash
# Transfer Kofi contract object to multisig account

# Exit if any command fails
set -e

# Source the balance check helper
source ./scripts/balance_check_helper.sh

# Check balance before transferring
check_balance default

# Get address of owner 1
OWNER_1=$(aptos account lookup-address --profile default | jq -r '.Result')

# Get address of owner 2
OWNER_2=$(aptos account lookup-address --profile owner_2 | jq -r '.Result')

# Get the object address
OBJECT_ADDRESS=$(tail -n 1 ./deployment/hello_world_object_address.txt)

# Get the multisig address
MULTISIG_ADDRESS=$(cat ./keys/multisig_address)

# Step 3: Transfer object ownership to multisig
echo "🔄 Transferring code object $OBJECT_ADDRESS to multisig account $MULTISIG_ADDRESS..."
aptos move run \
    --function-id "0x1::object::transfer" \
    --type-args "0x1::object::ObjectCore" \
    --args address:$OBJECT_ADDRESS address:$MULTISIG_ADDRESS \
    --assume-yes \
    --profile default

echo "✅ Code object $OBJECT_ADDRESS transferred to multisig account $MULTISIG_ADDRESS!"
echo "📝 Summary:"
echo "   - Code Object Address: $OBJECT_ADDRESS"
echo "   - Multisig Owner: $MULTISIG_ADDRESS"
echo "   - Multisig Owners: $OWNER_1, $OWNER_2"
echo "🔍 View on Explorer:"
echo "   - Code Object: https://explorer.aptoslabs.com/object/$OBJECT_ADDRESS"
echo "   - Multisig Account: https://explorer.aptoslabs.com/account/$MULTISIG_ADDRESS"
