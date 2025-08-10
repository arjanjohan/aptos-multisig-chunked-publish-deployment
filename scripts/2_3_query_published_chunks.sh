#!/bin/bash
# Query transaction details from Aptos API for all transactions in deployment_transactions.txt

# Exit immediately if a command exits with a non-zero status
set -e

# Function to handle errors
handle_error() {
  echo "❌ Error occurred at line $1"
  exit 1
}

trap 'handle_error $LINENO' ERR

# Define constants
API_BASE_URL="https://api.testnet.aptoslabs.com/v1"
TRANSACTION_FILE="./deployment/deployment_transactions.txt"
OUTPUT_DIR="./deployment/transaction_data"
CHUNK_SIZES_FILE="./config/chunk_sizes.json"

echo "🔍 Analyzing transactions from $TRANSACTION_FILE..."

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"
mkdir -p "$(dirname "$CHUNK_SIZES_FILE")"

# Check if transaction file exists
if [ ! -f "$TRANSACTION_FILE" ]; then
  echo "❌ Transaction file not found: $TRANSACTION_FILE"
  exit 1
fi

# Read transaction hashes, skip the last line (object address), and remove duplicates
TX_HASHES=($(grep -o "0x[a-fA-F0-9]\+" "$TRANSACTION_FILE" | head -n -1 | sort -u))

# Check if we have any transactions
if [ ${#TX_HASHES[@]} -eq 0 ]; then
  echo "⚠️ No transaction hashes found in $TRANSACTION_FILE"
  exit 0
fi

echo "📊 Found ${#TX_HASHES[@]} unique transaction hashes to analyze"

# Array to store chunk sizes
CHUNK_SIZES=()

# Function to query transaction details from API
query_transaction() {
  local tx_hash=$1
  local output_file="$OUTPUT_DIR/transaction_${tx_hash}.json"

  echo "🔄 Querying transaction: $tx_hash"

  # Make API request
  local response=$(curl --silent --request GET \
    --url "$API_BASE_URL/transactions/by_hash/$tx_hash" \
    --header 'Accept: application/json, application/x-bcs')

  # Check if response is empty or contains an error
  if [ -z "$response" ] || [[ "$response" == *"error"* ]]; then
    echo "⚠️ Failed to get data for transaction $tx_hash"
    echo "$response" > "$output_file"
    return 1
  fi

  # Save response to file
  echo "$response" > "$output_file"
  echo "✅ Saved transaction data to $output_file"

  # Extract the length of the second argument (index 1) from the payload
  # The payload structure is: .payload.arguments[1] which contains an array
  local arg2_length=$(echo "$response" | jq '.payload.arguments[1] | length' 2>/dev/null)

  # Extract the length of the third argument (index 2) from the payload
  # The payload structure is: .payload.arguments[2] which contains an array
  local arg3_length=$(echo "$response" | jq '.payload.arguments[2] | length' 2>/dev/null)

  # Check if both lengths are valid numbers and equal
  if [[ "$arg2_length" =~ ^[0-9]+$ ]] && [[ "$arg3_length" =~ ^[0-9]+$ ]]; then
    if [ "$arg2_length" -eq "$arg3_length" ]; then
      echo "📊 Extracted chunk size: $arg2_length (both arguments have same length)"
      CHUNK_SIZES+=($arg2_length)
    else
      echo "⚠️ Arguments have different lengths: arg2=$arg2_length, arg3=$arg3_length"
      # Use the second argument's length as per your requirement
      echo "📊 Using second argument's length: $arg2_length"
      CHUNK_SIZES+=($arg2_length)
    fi
  else
    echo "⚠️ Could not extract valid lengths from arguments"
  fi

  return 0
}

# Process each transaction hash
SUCCESSFUL_QUERIES=0
FAILED_QUERIES=0

for tx_hash in "${TX_HASHES[@]}"; do
  echo "-------------------------------------------"
  if query_transaction "$tx_hash"; then
    SUCCESSFUL_QUERIES=$((SUCCESSFUL_QUERIES + 1))
  else
    FAILED_QUERIES=$((FAILED_QUERIES + 1))
  fi

  # Add a small delay to avoid rate limiting
  sleep 0.5
done

# Update chunk sizes file if we found any
if [ ${#CHUNK_SIZES[@]} -gt 0 ]; then
  # Create JSON array string
  JSON_ARRAY="["
  for ((i=0; i<${#CHUNK_SIZES[@]}; i++)); do
    JSON_ARRAY+="${CHUNK_SIZES[$i]}"
    if [ $i -lt $((${#CHUNK_SIZES[@]} - 1)) ]; then
      JSON_ARRAY+=", "
    fi
  done
  JSON_ARRAY+="]"

  # Write to file
  echo "$JSON_ARRAY" > "$CHUNK_SIZES_FILE"
  echo "✅ Updated chunk sizes file with sizes: ${CHUNK_SIZES[*]}"
else
  echo "⚠️ No chunk sizes were extracted from the transactions"
fi

echo "-------------------------------------------"
echo "📊 Summary:"
echo "- Total transactions processed: ${#TX_HASHES[@]}"
echo "- Successful queries: $SUCCESSFUL_QUERIES"
echo "- Failed queries: $FAILED_QUERIES"
echo "- Chunk sizes extracted: ${CHUNK_SIZES[*]}"
echo "- Transaction data saved to: $OUTPUT_DIR"
echo "- Chunk sizes saved to: $CHUNK_SIZES_FILE"