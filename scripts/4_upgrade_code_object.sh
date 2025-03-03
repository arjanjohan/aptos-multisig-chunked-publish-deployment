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
DEFAULT_CHUNK_SIZE=6
SLEEP_BETWEEN_TXS=2
DELETE_AFTER_PROCESSING=true
CHUNK_SIZES_FILE="./config/chunk_sizes.json"

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

# Function to get chunk sizes from file
get_chunk_sizes() {
  # Read chunk sizes from file
  if [ -f "$CHUNK_SIZES_FILE" ]; then
    # Read the file content and log it
    local sizes_json=$(cat "$CHUNK_SIZES_FILE")
    echo "📊 Using chunk sizes: $sizes_json" >&2

    # Extract the array values and return them
    jq -r '.[]' "$CHUNK_SIZES_FILE"
  else
    echo "⚠️ No chunk sizes file found, using default: $DEFAULT_CHUNK_SIZE" >&2
    echo "$DEFAULT_CHUNK_SIZE"
  fi
}

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

# Split the publication.json into multiple files with chunk sizes from previous transactions
echo "📄 Splitting publication.json into chunked files..."

# Get the total number of items in the arrays
TOTAL_ITEMS=$(jq '.args[1].value | length' publication.json)
echo "Total items in arrays: $TOTAL_ITEMS"

# Get chunk sizes from file - store in an array
readarray -t CHUNK_SIZES < <(get_chunk_sizes)

# Calculate chunks based on the determined chunk sizes
calculate_chunks() {
  local total=$1
  local sizes=("${!2}")
  local chunks=0
  local remaining=$total
  local i=0

  # If no sizes were provided, use the default
  if [ ${#sizes[@]} -eq 0 ]; then
    sizes=($DEFAULT_CHUNK_SIZE)
  fi

  while [ $remaining -gt 0 ]; do
    local size=${sizes[$i % ${#sizes[@]}]}
    if [ $remaining -lt $size ]; then
      size=$remaining
    fi
    remaining=$((remaining - size))
    chunks=$((chunks + 1))
    i=$((i + 1))
  done

  echo $chunks
}

# Calculate the number of chunks needed based on the chunk sizes
CHUNKS=$(calculate_chunks $TOTAL_ITEMS CHUNK_SIZES[@])
echo "Creating $CHUNKS chunked files based on determined chunk sizes"

# Create each chunked file
CURRENT_IDX=0
for ((i=0; i<$CHUNKS; i++)); do
  # Add progress reporting
  echo "🔄 Processing chunk $((i+1)) of $CHUNKS ($(( (i+1) * 100 / CHUNKS ))%)"

  # Determine chunk size for this chunk
  # If no sizes were provided, use the default
  if [ ${#CHUNK_SIZES[@]} -eq 0 ]; then
    CHUNK_SIZE=$DEFAULT_CHUNK_SIZE
  else
    CHUNK_SIZE=${CHUNK_SIZES[$i % ${#CHUNK_SIZES[@]}]}
  fi

  # If this would exceed total items, adjust the chunk size
  if [ $((CURRENT_IDX + CHUNK_SIZE)) -gt $TOTAL_ITEMS ]; then
    CHUNK_SIZE=$((TOTAL_ITEMS - CURRENT_IDX))
  fi

  echo "📊 Using chunk size: $CHUNK_SIZE for items $CURRENT_IDX to $((CURRENT_IDX + CHUNK_SIZE - 1))"

  START_IDX=$CURRENT_IDX
  END_IDX=$((CURRENT_IDX + CHUNK_SIZE))

  # Determine if this is the last chunk
  IS_LAST_CHUNK=false
  if [ $END_IDX -ge $TOTAL_ITEMS ]; then
    IS_LAST_CHUNK=true
    END_IDX=$TOTAL_ITEMS
  fi

  # Calculate the length for this chunk
  CHUNK_LENGTH=$((END_IDX - START_IDX))

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

  if [ "$IS_LAST_CHUNK" = true ]; then
    echo "✅ Created chunked-publication-$CHUNK_NUM.json with items $START_IDX to $((END_IDX-1)) (with object address)"
  else
    echo "✅ Created chunked-publication-$CHUNK_NUM.json with items $START_IDX to $((END_IDX-1))"
  fi

  # Update current index for next chunk
  CURRENT_IDX=$END_IDX
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
echo "- Chunk sizes used: ${CHUNK_SIZES[*]}"
echo "- Object address: $OBJECT_ADDRESS"
echo "- Multisig address: $MULTISIG_ADDRESS"
echo "- Last transaction hash: $LAST_TX_HASH"

# Print helpful information
echo "🔍 View your contract on Explorer:"
echo "https://explorer.aptoslabs.com/object/$OBJECT_ADDRESS?network=testnet"