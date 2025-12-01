#!/usr/bin/env bash
#
# Test a range of Zcash blocks for header validation.
#
# Usage:
#   ./test_block_range.sh --start 0 --end 100
#   ./test_block_range.sh --start 0 --end 100 --step 10
#   ./test_block_range.sh --start 900000 --end 910000 --random 20
#   ./test_block_range.sh --upgrades  # Test blocks around all network upgrades
#
# Options:
#   --start N       Starting block height (default: 0)
#   --end N         Ending block height (default: 100)
#   --step N        Step between blocks (default: 1, ignored if --random is set)
#   --random N      Test N random blocks from the range instead of sequential
#   --upgrades      Test blocks around all Zcash network upgrade boundaries
#   --keep          Keep generated JSON files after testing (default: delete on success)
#   --nocapture     Show full output from scarb
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_DIR="$SCRIPT_DIR/../../packages/client"
SCARB="scarb"

GREEN='\033[0;32m'
RED='\033[1;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Zcash network upgrade heights
OVERWINTER_HEIGHT=347500
SAPLING_HEIGHT=419200
BLOSSOM_HEIGHT=653600
HEARTWOOD_HEIGHT=903000
CANOPY_HEIGHT=1046400
NU5_HEIGHT=1687104

# Default values
start_height=1
end_height=100
step=1
random_count=0
test_upgrades=0
keep_files=0
nocapture=0

# Minimum block height - block 0 is genesis (no previous state to validate against)
# Block 1+ can be validated
MIN_BLOCK_HEIGHT=1

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --start)
            start_height="$2"
            shift 2
            ;;
        --end)
            end_height="$2"
            shift 2
            ;;
        --step)
            step="$2"
            shift 2
            ;;
        --random)
            random_count="$2"
            shift 2
            ;;
        --upgrades)
            test_upgrades=1
            shift
            ;;
        --keep)
            keep_files=1
            shift
            ;;
        --nocapture)
            nocapture=1
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Build list of block heights to test
heights=()

if [[ $test_upgrades -eq 1 ]]; then
    echo -e "${CYAN}Testing blocks around network upgrade boundaries...${RESET}"
    # Early blocks
    heights+=(1 2 10 100 1000 10000)
    # Overwinter
    heights+=($((OVERWINTER_HEIGHT - 1)) $OVERWINTER_HEIGHT $((OVERWINTER_HEIGHT + 1)))
    # Sapling
    heights+=($((SAPLING_HEIGHT - 1)) $SAPLING_HEIGHT $((SAPLING_HEIGHT + 1)))
    # Blossom
    heights+=($((BLOSSOM_HEIGHT - 1)) $BLOSSOM_HEIGHT $((BLOSSOM_HEIGHT + 1)))
    # Heartwood
    heights+=($((HEARTWOOD_HEIGHT - 1)) $HEARTWOOD_HEIGHT $((HEARTWOOD_HEIGHT + 1)))
    # Canopy
    heights+=($((CANOPY_HEIGHT - 1)) $CANOPY_HEIGHT $((CANOPY_HEIGHT + 1)))
    # NU5
    heights+=($((NU5_HEIGHT - 1)) $NU5_HEIGHT $((NU5_HEIGHT + 1)))
elif [[ $random_count -gt 0 ]]; then
    echo -e "${CYAN}Selecting $random_count random blocks from range [$start_height, $end_height]...${RESET}"
    # Ensure start_height is at least MIN_BLOCK_HEIGHT
    if [[ $start_height -lt $MIN_BLOCK_HEIGHT ]]; then
        start_height=$MIN_BLOCK_HEIGHT
    fi
    range=$((end_height - start_height + 1))
    for ((i = 0; i < random_count; i++)); do
        h=$((start_height + RANDOM % range))
        heights+=($h)
    done
    # Sort and dedupe
    IFS=$'\n' heights=($(sort -n -u <<< "${heights[*]}")); unset IFS
else
    echo -e "${CYAN}Testing blocks from $start_height to $end_height (step: $step)...${RESET}"
    # Ensure start_height is at least MIN_BLOCK_HEIGHT
    if [[ $start_height -lt $MIN_BLOCK_HEIGHT ]]; then
        echo -e "${YELLOW}Note: Skipping block 0 (genesis has no previous state)${RESET}"
        start_height=$MIN_BLOCK_HEIGHT
    fi
    for ((h = start_height; h <= end_height; h += step)); do
        heights+=($h)
    done
fi

echo -e "${CYAN}Will test ${#heights[@]} blocks: ${heights[*]:0:10}${RESET}"
if [[ ${#heights[@]} -gt 10 ]]; then
    echo -e "${CYAN}  ... and $((${#heights[@]} - 10)) more${RESET}"
fi
echo ""

# Counters
num_ok=0
num_fail=0
failures=()
temp_files=()

# Change to client directory
cd "$CLIENT_DIR"

# Test each block
for height in "${heights[@]}"; do
    echo -n "test block $height ..."
    
    # Generate test data
    json_file="tests/data/.temp_block_${height}.json"
    args_file="tests/data/.arguments-temp_block_${height}.json"
    temp_files+=("$json_file" "$args_file")
    
    # Generate the light block data
    gen_error=$(python3 "$SCRIPT_DIR/generate_data.py" \
        --height "$height" \
        --num_blocks 1 \
        --output_file "$json_file" 2>&1)
    if [ $? -ne 0 ]; then
        echo -e "${RED} fail ${RESET}(data generation failed)"
        if [ "$NOCAPTURE" = "1" ]; then
            echo "Error: $gen_error"
        fi
        num_fail=$((num_fail + 1))
        failures+=("block $height — Failed to generate test data")
        continue
    fi
    
    # Format arguments for Cairo
    if ! python3 "$SCRIPT_DIR/format_args.py" --input_file "$json_file" > "$args_file" 2>/dev/null; then
        echo -e "${RED} fail ${RESET}(argument formatting failed)"
        num_fail=$((num_fail + 1))
        failures+=("block $height — Failed to format arguments")
        continue
    fi
    
    # Run the test
    output=$($SCARB --profile release execute --print-resource-usage --arguments-file "$args_file" 2>&1) || true
    rm -rf ../../target/execute 2>/dev/null || true
    
    steps=$(echo "$output" | grep -o 'steps: [0-9,]*' | sed 's/steps: //' || echo "?")
    
    if [[ "$nocapture" -eq 1 ]]; then
        echo -e "\n$output"
    fi
    
    if [[ "$output" == *"FAIL"* ]]; then
        echo -e "${RED} fail ${RESET}(steps: $steps)"
        num_fail=$((num_fail + 1))
        error=$(echo "$output" | grep -o "error='[^']*'" | sed "s/error=//" || echo "unknown error")
        failures+=("block $height — Panicked with $error")
    elif [[ "$output" == *"OK"* ]]; then
        echo -e "${GREEN} ok ${RESET}(steps: $steps)"
        num_ok=$((num_ok + 1))
        # Clean up temp files on success if not keeping
        if [[ $keep_files -eq 0 ]]; then
            rm -f "$json_file" "$args_file"
        fi
    else
        echo -e "${RED} fail ${RESET}"
        num_fail=$((num_fail + 1))
        error=$(echo "$output" | head -5 | tr '\n' ' ')
        failures+=("block $height — $error")
    fi
done

# Summary
echo ""
if [[ $num_fail -eq 0 ]]; then
    echo -e "test result: ${GREEN}ok${RESET}. ${num_ok} passed; 0 failed"
    # Clean up all temp files
    if [[ $keep_files -eq 0 ]]; then
        for f in "${temp_files[@]}"; do
            rm -f "$f" 2>/dev/null || true
        done
    fi
else
    echo -e "failures:"
    for failure in "${failures[@]}"; do
        echo -e "\t$failure"
    done
    echo -e "test result: ${RED}FAILED${RESET}. ${num_ok} passed; ${num_fail} failed"
    exit 1
fi

