#!/bin/bash
# Deploy Kofi contract to Aptos testnet

# Exit if any command fails
set -e

# Source the balance check helper
source ./scripts/balance_check_helper.sh

# Check balance before publishing
echo "🔍 Checking account balance before publishing..."
check_balance default

echo "🚀 Publishing contract to Aptos testnet..."

# Compile the contract
echo "📝 Compiling Move modules..."
aptos move compile --named-addresses multisig_code=default || {
    echo "❌ Compilation failed"
    exit 1
}

# use `--included-artifacts none to hide code on explorer

# Create deployment directory if it doesn't exist
mkdir -p ./deployment

# Publish to testnet
echo "📦 Publishing to testnet..."
aptos move deploy-object \
    --address-name multisig_code \
    --profile default \
    --chunked-publish \
    --assume-yes | tee /dev/tty | grep -o "0x[a-fA-F0-9]\+" > ./deployment/deployment_transactions.txt || {
    echo "❌ Publishing failed"
    exit 1
}



echo "✅ Contract successfully published on Aptos testnet!"

# Get the object address (the last line should be the object address)
OBJECT_ADDRESS=$(tail -n 1 ./deployment/deployment_transactions.txt)

# Store the object address in a separate file for easy access
echo "$OBJECT_ADDRESS" > ./deployment/hello_world_object_address.txt

# Print helpful information
echo "🔍 View your contract on Explorer:"
echo "https://explorer.aptoslabs.com/object/$OBJECT_ADDRESS?network=testnet"