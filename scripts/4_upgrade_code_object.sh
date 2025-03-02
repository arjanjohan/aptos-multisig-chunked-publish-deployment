#!/bin/bash
# Upgrades the hello world contract on Aptos testnet using multisig account

# Get the object address
OBJECT_ADDRESS=$(tail -n 1 ./deployment/hello_world_object_address.txt)

# Get address of owner 1
OWNER_1=$(aptos account lookup-address --profile default | jq -r '.Result')

# Get address of owner 2
OWNER_2=$(aptos account lookup-address --profile owner_2 | jq -r '.Result')

# Get private key of owner 2
OWNER_2_PK=$(cat ./keys/owner_2)

# Get the multisig address
MULTISIG_ADDRESS=$(cat ./keys/multisig_address)

echo "🚀 Upgrading contract on Aptos testnet at address $OBJECT_ADDRESS..."

# Compile the contract, note that the named address is the object address
echo "📝 Compiling Move modules..."
aptos move compile --named-addresses multisig_code=$OBJECT_ADDRESS || {
    echo "❌ Compilation failed"
    exit 1
}

# Build upgrade payload
echo "📦 Building publish payload..."
aptos move build-publish-payload \
    --named-addresses multisig_code=$OBJECT_ADDRESS \
    --json-output-file publication.json \
    --chunked-publish \
    --assume-yes

# Modify the function ID in the publication.json
echo "🔧 Modifying function ID in payload..."
TMP_FILE=$(mktemp)
jq '.function_id = "0xe1ca3011bdd07246d4d16d909dbb2d6953a86c4735d5acf5865d962c630cce7::large_packages::stage_code_chunk_and_upgrade_object_code"' publication.json > "$TMP_FILE" && mv "$TMP_FILE" publication.json

# Add object address to args at the correct position (after the first array and before the second)
echo "🔧 Adding object address to payload args..."
TMP_FILE=$(mktemp)
jq --arg addr "$OBJECT_ADDRESS" '
  # Get the first argument
  .args[0] as $first_arg |
  # Get all arguments after the first one
  .args[1:] as $rest_args |
  # Replace args with: first arg, new address arg, then rest of args
  .args = [$first_arg, {type: "u8", value: [0,1,2,3,4]}] + $rest_args
' publication.json > "$TMP_FILE" && mv "$TMP_FILE" publication.json

# Add object address to args if not present
echo "🔧 Adding object address to payload args..."
TMP_FILE=$(mktemp)
jq --arg addr "$OBJECT_ADDRESS" '.args += [{type: "address", value: $addr}]' publication.json > "$TMP_FILE" && mv "$TMP_FILE" publication.json

# Get the sequence number from the transaction hash
SEQUENCE_NUMBER=$(aptos move view \
    --function-id 0x1::multisig_account::next_sequence_number \
    --args \
        address:"$MULTISIG_ADDRESS" | jq -r '.Result[0]')

# Create multisig transaction
echo "🔐 Creating multisig transaction..."
aptos multisig create-transaction \
    --multisig-address $MULTISIG_ADDRESS \
    --json-file publication.json \
    --store-hash-only \
    --assume-yes | tee /dev/tty | grep -o "0x[a-fA-F0-9]\+" > ./deployment/last_multisig_tx.txt

# Approve transaction from owner 2
echo "✍️  Approving transaction from owner 2..."
aptos multisig approve \
    --multisig-address $MULTISIG_ADDRESS \
    --sequence-number $SEQUENCE_NUMBER \
    --private-key $OWNER_2_PK \
    --assume-yes

# Execute transaction with payload
echo "🔄 Executing multisig transaction..."
aptos multisig execute-with-payload \
    --multisig-address $MULTISIG_ADDRESS \
    --json-file publication.json \
    --assume-yes

echo "✅ Contract successfully upgraded on Aptos testnet!"

# Print helpful information
echo "🔍 View your contract on Explorer:"
echo "https://explorer.aptoslabs.com/object/$OBJECT_ADDRESS?network=testnet"