#!/bin/bash
# Upgrades the hello world contract on Aptos testnet using multisig account

# Exit immediately if a command exits with a non-zero status
set -e

# Function to handle errors
handle_error() {
  echo "❌ Error occurred at line $1"
  exit 1
}

trap 'handle_error $LINENO' ERR

# Define constants for easier configuration
PACKAGE_ADDRESS="0xe1ca3011bdd07246d4d16d909dbb2d6953a86c4735d5acf5865d962c630cce7"
CHUNK_SIZE=6
SLEEP_BETWEEN_TXS=2
DELETE_AFTER_PROCESSING=true

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
    --override-size-check \
    --assume-yes

# Add object address to args at the correct position (after the first array and before the second)
echo "🔧 Adding object address to payload args..."
TMP_FILE=$(mktemp)
jq '
  # Get the first argument
  .args[0] as $first_arg |
  # Get all arguments after the first one
  .args[1:] as $rest_args |
  # Get length of next array argument
  (.args[1].value | length) as $next_array_length |
  # Create array of indices matching length
  [range(0; $next_array_length)] as $indices |
  # Replace args with: first arg, new address arg with matching length, then rest of args
  .args = [$first_arg, {type: "u16", value: $indices}] + $rest_args
' publication.json > "$TMP_FILE" && mv "$TMP_FILE" publication.json

# Split the publication.json into multiple files with a maximum of $CHUNK_SIZE items per array
echo "📄 Splitting publication.json into chunked files..."

# Get the total number of items in the arrays
TOTAL_ITEMS=$(jq '.args[1].value | length' publication.json)
echo "Total items in arrays: $TOTAL_ITEMS"

# Calculate the number of chunks needed (ceiling division)
CHUNKS=$(( ($TOTAL_ITEMS + $CHUNK_SIZE - 1) / $CHUNK_SIZE ))
echo "Creating $CHUNKS chunked files with maximum $CHUNK_SIZE items per array"

# Create each chunked file
for ((i=0; i<$CHUNKS; i++)); do
  # Add progress reporting
  echo "🔄 Processing chunk $((i+1)) of $CHUNKS ($(( (i+1) * 100 / CHUNKS ))%)"

  START_IDX=$((i * $CHUNK_SIZE))
  END_IDX=$(((i + 1) * $CHUNK_SIZE))

  # If END_IDX is greater than TOTAL_ITEMS, adjust it
  if [ $END_IDX -gt $TOTAL_ITEMS ]; then
    END_IDX=$TOTAL_ITEMS
  fi

  # Calculate the length for this chunk
  CHUNK_LENGTH=$((END_IDX - START_IDX))

  # Determine if this is the last chunk
  IS_LAST_CHUNK=false
  if [ $i -eq $(($CHUNKS - 1)) ]; then
    IS_LAST_CHUNK=true
  fi

  # Set the appropriate function ID based on whether this is the last chunk
  if [ "$IS_LAST_CHUNK" = true ]; then
    FUNCTION_ID="${PACKAGE_ADDRESS}::large_packages::stage_code_chunk_and_upgrade_object_code"
    echo "🔄 Using upgrade function for final chunk: stage_code_chunk_and_upgrade_object_code"
  else
    FUNCTION_ID="${PACKAGE_ADDRESS}::large_packages::stage_code_chunk"
    echo "🔄 Using staging function for chunk: stage_code_chunk"
  fi

  # Create the chunked file using jq
  TMP_FILE=$(mktemp)

  # Build the jq filter with common operations
  JQ_FILTER='
    # Extract the subset of arrays for this chunk
    .args[1].value = (.args[1].value | .[$start:$start+$length]) |
    .args[2].value = (.args[2].value | .[$start:$start+$length]) |

    # Set the function ID
    .function_id = $function_id'

  # Handle first argument differently for first chunk vs subsequent chunks
  if [ $i -eq 0 ]; then
    # First chunk - keep the first argument unchanged
    FIRST_ARG_FILTER=""
  else
    # Subsequent chunks - replace first argument with "0x"
    FIRST_ARG_FILTER=' | .args[0].value = "0x"'
  fi

  # Add object address for last chunk
  if [ "$IS_LAST_CHUNK" = true ]; then
    ADDR_FILTER=' | .args += [{type: "address", value: $addr}]'
    jq --argjson start "$START_IDX" --argjson length "$CHUNK_LENGTH" \
       --arg function_id "$FUNCTION_ID" --arg addr "$OBJECT_ADDRESS" \
       "$JQ_FILTER$FIRST_ARG_FILTER$ADDR_FILTER" publication.json > "$TMP_FILE"
  else
    ADDR_FILTER=""
    jq --argjson start "$START_IDX" --argjson length "$CHUNK_LENGTH" \
       --arg function_id "$FUNCTION_ID" \
       "$JQ_FILTER$FIRST_ARG_FILTER$ADDR_FILTER" publication.json > "$TMP_FILE"
  fi

  # Format the chunk number with leading zero
  CHUNK_NUM=$(printf "%02d" $i)

  # Move the temporary file to the final destination
  mv "$TMP_FILE" "chunked-publication-$CHUNK_NUM.json"
  echo "✅ Created chunked-publication-$CHUNK_NUM.json with items $START_IDX to $((END_IDX-1))"
done

# We can now delete the original publication.json as we'll use the chunked files
echo "🗑️ Removing original publication.json file..."
rm publication.json
# Process each chunked file
echo "🔄 Processing each chunked file..."
PROCESSED_CHUNKS=0
SUCCESSFUL_CHUNKS=0
FAILED_CHUNKS=0
LAST_TX_HASH=""
for CHUNKED_FILE in chunked-publication-*.json; do
  PROCESSED_CHUNKS=$((PROCESSED_CHUNKS + 1))
  echo "📄 Processing $CHUNKED_FILE ($PROCESSED_CHUNKS of $CHUNKS)..."

  # Get the sequence number from the transaction hash
  SEQUENCE_NUMBER=$(aptos move view \
    --function-id 0x1::multisig_account::next_sequence_number \
    --args \
        address:"$MULTISIG_ADDRESS" | jq -r '.Result[0]')

  echo "📊 Current sequence number: $SEQUENCE_NUMBER"

  # Create multisig transaction
  echo "🔐 Creating multisig transaction for $CHUNKED_FILE..."
  TX_HASH=$(aptos multisig create-transaction \
    --multisig-address $MULTISIG_ADDRESS \
    --json-file "$CHUNKED_FILE" \
    --store-hash-only \
    --assume-yes | tee /dev/tty | grep -o "0x[a-fA-F0-9]\+")

  # Validate transaction hash
  if [ -z "$TX_HASH" ]; then
    echo "❌ Failed to get transaction hash for $CHUNKED_FILE"
    FAILED_CHUNKS=$((FAILED_CHUNKS + 1))
    continue
  fi

  echo "📝 Transaction hash: $TX_HASH"
  echo "$TX_HASH" > "./deployment/last_multisig_tx_$(basename "$CHUNKED_FILE" .json).txt"
  LAST_TX_HASH="$TX_HASH"

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
    --json-file "$CHUNKED_FILE" \
    --assume-yes


  echo "✅ Successfully processed $CHUNKED_FILE"
  echo "-------------------------------------------"

  # Only delete if flag is set
  if [ "$DELETE_AFTER_PROCESSING" = true ]; then
    rm "$CHUNKED_FILE"
    echo "🗑️ Removed $CHUNKED_FILE"
  else
    echo "💾 Keeping $CHUNKED_FILE for reference"
  fi

  # Small delay to ensure transactions are processed in order
  echo "⏱️ Waiting $SLEEP_BETWEEN_TXS seconds before processing next chunk..."
  sleep $SLEEP_BETWEEN_TXS
done

echo "✅ Contract successfully upgraded on Aptos testnet!"

# Add a summary report at the end
echo "📊 Summary:"
echo "- Total chunks processed: $PROCESSED_CHUNKS of $CHUNKS"
echo "- Successful transactions: $SUCCESSFUL_CHUNKS"
echo "- Failed transactions: $FAILED_CHUNKS"
echo "- Object address: $OBJECT_ADDRESS"
echo "- Multisig address: $MULTISIG_ADDRESS"
echo "- Last transaction hash: $LAST_TX_HASH"

# Print helpful information
echo "🔍 View your contract on Explorer:"
echo "https://explorer.aptoslabs.com/object/$OBJECT_ADDRESS?network=testnet"