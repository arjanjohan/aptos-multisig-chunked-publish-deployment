#!/bin/bash
# Creates multiple copies of hello_world.move with incremented numbers

# Exit immediately if a command exits with a non-zero status
set -e

# Function to handle errors
handle_error() {
  echo "❌ Error occurred at line $1"
  exit 1
}

trap 'handle_error $LINENO' ERR

# Configuration
SOURCE_FILE="./sources/hello_world.move"
NUM_COPIES=8  # Number of copies to create

echo "🔄 Creating $NUM_COPIES copies of $SOURCE_FILE..."

# Check if source file exists
if [ ! -f "$SOURCE_FILE" ]; then
  echo "❌ Source file not found: $SOURCE_FILE"
  exit 1
fi

# Create copies with modified module names
for ((i=1; i<=$NUM_COPIES; i++)); do
  # Format the number with leading zero if needed
  PADDED_NUM=$(printf "%02d" $i)

  # Define the target filename
  TARGET_FILE="./sources/hello_world_${PADDED_NUM}.move"

  # Copy the file
  cp "$SOURCE_FILE" "$TARGET_FILE"

  # Replace the module name in the first line
  # This assumes the first line is the module declaration
  sed -i "1s/module multisig_code::hello_world {/module multisig_code::hello_world_${PADDED_NUM} {/" "$TARGET_FILE"

  echo "✅ Created $TARGET_FILE with module name hello_world_${PADDED_NUM}"
done

echo "🎉 Successfully created $NUM_COPIES copies of hello_world.move!"
echo ""
echo "ℹ️ You can adjust the number of copies by changing the NUM_COPIES variable in this script."
echo "ℹ️ Remember to update your Move.toml file to include these new modules."