#!/usr/bin/env python3

import argparse
import json
import os
import time
import logging
from decimal import Decimal, getcontext
from pathlib import Path
from collections import deque

import requests

logger = logging.getLogger(__name__)

getcontext().prec = 16

ZCASH_RPC = os.getenv("ZCASH_RPC") or os.getenv("BITCOIN_RPC")
ZCASH_RPC_API_KEY = os.getenv("ZCASH_RPC_API_KEY") or os.getenv("BITCOIN_RPC_API_KEY")
USERPWD = os.getenv("USERPWD")
DEFAULT_URL = os.getenv(
    "DEFAULT_ZCASH_RPC", "https://rpc.mainnet.ztarknet.cash"
)

# =============================================================================
# Zcash consensus parameters
# =============================================================================

POW_AVERAGING_WINDOW = 17
MEDIAN_TIME_WINDOW = 11
MAX_TIMESTAMP_HISTORY = POW_AVERAGING_WINDOW + MEDIAN_TIME_WINDOW
POW_LIMIT_BITS = "1d00ffff"

# Network upgrade activation heights (Zcash mainnet)
# Must match packages/consensus/src/params.cairo
OVERWINTER_ACTIVATION_HEIGHT = 347500   # ZIP 200, 201, 202, 203, 143
SAPLING_ACTIVATION_HEIGHT = 419200      # ZIP 205, 212, 213, 243
BLOSSOM_ACTIVATION_HEIGHT = 653600      # ZIP 208 - 75s block spacing
HEARTWOOD_ACTIVATION_HEIGHT = 903000    # ZIP 213, 221 - hashBlockCommitments
CANOPY_ACTIVATION_HEIGHT = 1046400      # ZIP 211, 212, 214, 215, 216
NU5_ACTIVATION_HEIGHT = 1687104         # ZIP 224, 225, 226, 227, 244 - Orchard

# Block timing parameters
PRE_BLOSSOM_POW_TARGET_SPACING = 150    # seconds
POST_BLOSSOM_POW_TARGET_SPACING = 75    # seconds

# =============================================================================
# Network upgrade helper functions
# =============================================================================

def is_overwinter_active(height: int) -> bool:
    """Returns True if Overwinter is active at the given height."""
    return height >= OVERWINTER_ACTIVATION_HEIGHT

def is_sapling_active(height: int) -> bool:
    """Returns True if Sapling is active at the given height."""
    return height >= SAPLING_ACTIVATION_HEIGHT

def is_blossom_active(height: int) -> bool:
    """Returns True if Blossom is active at the given height."""
    return height >= BLOSSOM_ACTIVATION_HEIGHT

def is_heartwood_active(height: int) -> bool:
    """Returns True if Heartwood is active at the given height."""
    return height >= HEARTWOOD_ACTIVATION_HEIGHT

def is_canopy_active(height: int) -> bool:
    """Returns True if Canopy is active at the given height."""
    return height >= CANOPY_ACTIVATION_HEIGHT

def is_nu5_active(height: int) -> bool:
    """Returns True if NU5 (Orchard) is active at the given height."""
    return height >= NU5_ACTIVATION_HEIGHT

def pow_target_spacing(height: int) -> int:
    """Returns the expected PoW target spacing for a given block height."""
    if is_blossom_active(height):
        return POST_BLOSSOM_POW_TARGET_SPACING
    else:
        return PRE_BLOSSOM_POW_TARGET_SPACING

# =============================================================================
# RPC configuration
# =============================================================================

FAST = False
RETRIES = 3
DELAY = 2
RPC_REQUEST_LIMIT = int(os.getenv("ZCASH_RPC_LIMIT", "3"))
RPC_REQUEST_WINDOW = int(os.getenv("ZCASH_RPC_WINDOW", "60"))
REQUEST_LOG = deque()


def request_rpc(method: str, params: list):
    """Makes a JSON-RPC call to a Bitcoin API endpoint.
    Retries the request a specified number of times before failing.

    :param retries: Number of retry attempts before raising an exception.
    :param delay: Delay between retries in seconds.
    :return: parsed JSON result as Python object
    """
    url = ZCASH_RPC or DEFAULT_URL
    auth = tuple(USERPWD.split(":")) if USERPWD else None
    headers = {
        "content-type": "application/json",
        "accept-encoding": "identity",
    }
    if ZCASH_RPC_API_KEY:
        headers["x-api-key"] = ZCASH_RPC_API_KEY
    payload = {"jsonrpc": "2.0", "method": method, "params": params, "id": 0}

    def throttle():
        if RPC_REQUEST_LIMIT <= 0:
            return
        now = time.time()
        while REQUEST_LOG and now - REQUEST_LOG[0] > RPC_REQUEST_WINDOW:
            REQUEST_LOG.popleft()
        if len(REQUEST_LOG) >= RPC_REQUEST_LIMIT:
            sleep_for = 1
            time.sleep(max(sleep_for, 0))
        REQUEST_LOG.append(time.time())

    res = None
    for attempt in range(RETRIES):
        try:
            throttle()
            res = requests.post(url, auth=auth, headers=headers, json=payload)
            if res.status_code == 429:
                raise ConnectionError(res.text)
            data = res.json()
            if "error" in data and data["error"]:
                raise ConnectionError(data["error"])
            if "result" not in data:
                raise ConnectionError(f"Malformed RPC response: {data}")
            return data["result"]
        except Exception as e:
            if attempt < RETRIES - 1:
                logger.debug(f"Connection error: {e}, will retry in {DELAY}s")
                time.sleep(DELAY)  # Wait before retrying
            else:
                body = res.text if res is not None else "<no response>"
                raise ConnectionError(
                    f"Unexpected RPC response after {RETRIES} attempts:\n{body}"
                )


def fetch_chain_state(block_height: int):
    """Fetches chain state at the end of a specific block with given height.
    Chain state is a just a block header extended with extra fields:
        - prev_timestamps
        - epoch_start_time
    
    Only queries as many previous blocks as actually exist (up to MAX_TIMESTAMP_HISTORY).
    """
    # Chain state at height H is the state after applying block H
    block_hash = request_rpc("getblockhash", [block_height])
    head = request_rpc("getblockheader", [block_hash])

    # Calculate how many previous blocks we actually need to query
    # We need up to MAX_TIMESTAMP_HISTORY timestamps and POW_AVERAGING_WINDOW pow targets
    # But we can't query more blocks than exist
    max_prev_blocks = min(block_height, max(MAX_TIMESTAMP_HISTORY - 1, POW_AVERAGING_WINDOW - 1))
    
    prev_timestamps = [int(head["time"])]
    pow_history = [bits_to_target(head["bits"])]
    current_header = head
    
    # Only query the blocks that actually exist
    for _ in range(max_prev_blocks):
        prev_hash = current_header.get("previousblockhash")
        if not prev_hash:
            break
        current_header = request_rpc("getblockheader", [prev_hash])
        if len(prev_timestamps) < MAX_TIMESTAMP_HISTORY:
            prev_timestamps.insert(0, int(current_header["time"]))
        if len(pow_history) < POW_AVERAGING_WINDOW:
            pow_history.insert(0, bits_to_target(current_header["bits"]))

    # DON'T pad timestamps or pow_history - the Cairo code uses the lengths to determine
    # whether to run difficulty adjustment. For early blocks, we want to skip adjustment
    # and use the target from the block's nBits instead.

    head["prev_timestamps"] = prev_timestamps

    # In order to init epoch start we need to query block header at epoch start
    if block_height < 2016:
        head["epoch_start_time"] = 1477953400  # Zcash genesis time
    else:
        head["epoch_start_time"] = get_epoch_start_time(block_height)

    head["pow_target_history"] = pow_history
    
    # Compute total work (sum of work for all blocks up to this height)
    # For simplicity, we approximate by computing work for this block times (height + 1)
    # This is a rough approximation since difficulty varies, but it's good enough for testing
    block_work = target_to_work(bits_to_target(head["bits"]))
    head["total_work"] = block_work * (block_height + 1)
    
    return head


def get_epoch_start_time(block_height: int) -> int:
    """Computes the corresponding epoch start time given the current block height."""
    epoch_start_block_height = (block_height // 2016) * 2016
    epoch_start_block_hash = request_rpc("getblockhash", [epoch_start_block_height])
    epoch_start_header = request_rpc("getblockheader", [epoch_start_block_hash])
    return epoch_start_header["time"]


def format_chain_state(head: dict):
    """Formats chain state according to the respective Cairo type."""
    # Zcash RPC doesn't return chainwork, so we use a stored value or compute it
    if "chainwork" in head:
        total_work = int.from_bytes(bytes.fromhex(head["chainwork"]), "big")
    elif "total_work" in head:
        total_work = head["total_work"]
    else:
        # For genesis or early blocks, start with work from target
        total_work = target_to_work(bits_to_target(head["bits"]))
    
    return {
        "block_height": head["height"],
        "total_work": str(total_work),
        "best_block_hash": head["hash"],
        "current_target": str(bits_to_target(head["bits"])),
        "prev_timestamps": head["prev_timestamps"],
        "epoch_start_time": head["epoch_start_time"],
        "pow_target_history": [
            str(value) for value in head.get("pow_target_history", [])
        ],
    }


def target_to_work(target: int) -> int:
    """Convert target to work (approximate).
    Work = 2^256 / (target + 1)
    """
    if target == 0:
        return 0
    return (2**256) // (target + 1)


def bits_to_target(bits: str) -> int:
    """Convert difficulty bits (compact target representation) to target.

    :param bits: bits as a hex string (without 0x prefix)
    :return: target as integer
    """
    exponent = int.from_bytes(bytes.fromhex(bits[:2]), "big")
    mantissa = int.from_bytes(bytes.fromhex(bits[2:]), "big")
    if exponent == 0:
        return mantissa
    elif exponent <= 3:
        return mantissa >> (8 * (3 - exponent))
    else:
        return mantissa << (8 * (exponent - 3))


def bits_int_to_target(bits_int: int) -> int:
    return bits_to_target(bits_int.to_bytes(4, "big").hex())


POW_LIMIT_TARGET = bits_to_target(POW_LIMIT_BITS)


def fetch_block(block_hash: str):
    """Downloads block with transactions (and referred UTXOs) from RPC given the block hash."""
    block = request_rpc("getblock", [block_hash, 2])
    block["data"] = {
        tx["txid"]: resolve_transaction(tx, None) for tx in block["tx"]
    }
    return block


def resolve_transaction(transaction: dict, previous_outputs: dict):
    """Resolves transaction inputs and formats the content according to the Cairo type."""
    return {
        "version": transaction["version"],
        "is_segwit": transaction["hex"][8:12] == "0001",
        "inputs": [
            resolve_input(input, previous_outputs) for input in transaction["vin"]
        ],
        "outputs": [format_output(output) for output in transaction["vout"]],
        "lock_time": transaction["locktime"],
    }


def resolve_input(input: dict, previous_outputs: dict):
    """Resolves referenced UTXO and formats the transaction inputs according to the Cairo type."""
    if input.get("coinbase"):
        return format_coinbase_input(input)
    else:
        if previous_outputs:
            previous_output = format_outpoint(
                previous_outputs[(input["txid"], input["vout"])]
            )
        else:
            previous_output = resolve_outpoint(input)
        return {
            "script": f'0x{input["scriptSig"]["hex"]}',
            "sequence": input["sequence"],
            "previous_output": previous_output,
            "witness": [f"0x{item}" for item in input.get("txinwitness", [])],
        }


def format_outpoint(previous_output):
    """Formats output according to the Cairo type."""
    return {
        "txid": previous_output["txid"],
        "vout": int(previous_output["vout"]),
        "data": {
            "value": int(previous_output["value"]),
            "pk_script": f'0x{previous_output["pk_script"]}',
            "cached": False,
        },
        "block_height": int(previous_output["block_height"]),
        # Note that BigQuery dataset uses "median_timestamp" instead of "median_time_past"
        "median_time_past": int(previous_output["median_timestamp"]),
        "is_coinbase": previous_output["is_coinbase"],
    }


def resolve_outpoint(input: dict):
    """Fetches transaction and block header for the referenced output,
    formats resulting outpoint according to the Cairo type.
    """
    tx = request_rpc("getrawtransaction", [input["txid"], True])
    block = request_rpc("getblockheader", [tx["blockhash"]])
    # Time-based relative lock-times are measured from the
    # smallest allowed timestamp of the block containing the
    # txout being spent, which is the median time past of the
    # block prior.
    prev_block = request_rpc("getblockheader", [block["previousblockhash"]])
    return {
        "txid": input["txid"],
        "vout": input["vout"],
        "data": format_output(tx["vout"][input["vout"]]),
        "block_height": block["height"],
        "median_time_past": prev_block["mediantime"],
        "is_coinbase": tx["vin"][0].get("coinbase") is not None,
    }


def format_coinbase_input(input: dict):
    """Formats coinbase input according to the Cairo type."""
    return {
        "script": f'0x{input["coinbase"]}',
        "sequence": input["sequence"],
        "previous_output": {
            "txid": "0" * 64,
            "vout": 0xFFFFFFFF,
            "data": {"value": 0, "pk_script": "0x", "cached": False},
            "block_height": 0,
            "median_time_past": 0,
            "is_coinbase": False,
        },
        "witness": [
            "0x0000000000000000000000000000000000000000000000000000000000000000"
        ],
    }


def format_output(output: dict):
    """Formats transaction output according to the Cairo type."""
    value = (Decimal(str(output["value"])) * Decimal("100000000")).to_integral_value()
    return {
        "value": int(value),
        "pk_script": f'0x{output["scriptPubKey"]["hex"]}',
        "cached": False,
    }


def format_block_with_transactions(block: dict):
    """Formats block with transactions according to the respective Cairo type."""
    return {
        "header": format_header(block),
        "data": {"variant_id": 1, "transactions": list(block["data"].values())},
    }


def fetch_block_header(block_hash: str):
    """Downloads block header (without transaction) from RPC given the block hash."""
    return request_rpc("getblockheader", [block_hash])


def format_block(header: dict):
    """Formats block (without transactions) according to the respective Cairo type.
    Note that transaction data uses a verbose format to include information
    about the particular enum variant.

    :param header: block header obtained from RPC
    """
    return {
        "header": format_header(header),
        "data": {"variant_id": 0, "merkle_root": header["merkleroot"]},
    }


def parse_bits(bits_value: str) -> int:
    bits_value = bits_value.lower()
    if bits_value.startswith("0x"):
        bits_value = bits_value[2:]
    return int(bits_value, 16)


def format_header(header: dict):
    """Formats header according to the respective Cairo type.

    :param header: block header obtained from RPC
    
    The header commitment field changes based on network upgrades:
    - Pre-Sapling (< 419200): Reserved field (all zeros)
    - Sapling to Heartwood (419200 - 902999): hashFinalSaplingRoot
    - Heartwood to NU5 (903000 - 1687103): hashLightClientRoot (blockcommitments)
    - NU5+ (>= 1687104): hashBlockCommitments (includes Orchard)
    """
    height = header.get("height", 0)
    
    # Determine the correct commitment field based on network upgrade
    if is_heartwood_active(height):
        # After Heartwood: use blockcommitments (hashLightClientRoot/hashBlockCommitments)
        hash_commitment = header.get("blockcommitments", "0" * 64)
    elif is_sapling_active(height):
        # Sapling to Heartwood: use finalsaplingroot
        hash_commitment = header.get("finalsaplingroot", "0" * 64)
    else:
        # Pre-Sapling: reserved field (should be all zeros)
        hash_commitment = header.get("finalsaplingroot", "0" * 64)
    
    return {
        "version": header["version"],
        "final_sapling_root": hash_commitment,
        "time": header["time"],
        "bits": parse_bits(header["bits"]),
        "nonce": normalize_hash_string(header.get("nonce", "0" * 64)),
        "indices": format_solution(header.get("solution", "")),
    }


def normalize_hash_string(value: str) -> str:
    value = value.lower()
    if value.startswith("0x"):
        return value[2:]
    return value


def format_solution(solution_hex: str) -> list[int]:
    """Convert hex-encoded solution bytes to unpacked 21-bit indices.

    For Zcash mainnet (n=200, k=9), this extracts 512 indices of 21 bits each
    from the 1344-byte minimal-encoded solution.
    """
    solution_hex = solution_hex.lower()
    if solution_hex.startswith("0x"):
        solution_hex = solution_hex[2:]
    if not solution_hex:
        return []

    data = bytes.fromhex(solution_hex)

    # Equihash parameters for Zcash mainnet
    n = 200
    k = 9
    collision_bit_length = n // (k + 1)  # 20
    bits_per_index = collision_bit_length + 1  # 21
    num_indices = 2 ** k  # 512
    expected_bytes = (num_indices * bits_per_index + 7) // 8  # 1344

    if len(data) != expected_bytes:
        raise ValueError(f"Equihash solution must be {expected_bytes} bytes, got {len(data)}")

    # Unpack 21-bit indices from minimal-encoded bytes (big-endian bitstream)
    indices: list[int] = []
    for idx in range(num_indices):
        value = 0
        for b in range(bits_per_index):
            global_bit = idx * bits_per_index + b
            byte_index = global_bit // 8
            bit_in_byte = global_bit % 8
            # Big-endian: bit 0 is MSB of byte
            bit_val = (data[byte_index] >> (7 - bit_in_byte)) & 1
            value = (value << 1) | bit_val
        indices.append(value)

    return indices


def next_chain_state(current_state: dict, new_block: dict) -> dict:
    """Computes the next chain state given the current state and a new block."""
    next_state = new_block.copy()

    # We need to recalculate the prev_timestamps field given the previous chain state
    # and all the blocks we applied to it
    prev_timestamps = current_state["prev_timestamps"] + [new_block["time"]]
    next_state["prev_timestamps"] = prev_timestamps[-MAX_TIMESTAMP_HISTORY:]

    # Update epoch start time
    if new_block["height"] % 2016 == 0:
        next_state["epoch_start_time"] = new_block["time"]
    else:
        next_state["epoch_start_time"] = current_state["epoch_start_time"]

    pow_history = list(current_state.get("pow_target_history", []))
    if not pow_history:
        pow_history = [POW_LIMIT_TARGET] * POW_AVERAGING_WINDOW
    pow_history.append(bits_to_target(new_block["bits"]))
    next_state["pow_target_history"] = pow_history[-POW_AVERAGING_WINDOW:]

    # Compute cumulative total work
    current_total_work = current_state.get("total_work", 0)
    if isinstance(current_total_work, str):
        current_total_work = int(current_total_work)
    block_work = target_to_work(bits_to_target(new_block["bits"]))
    next_state["total_work"] = current_total_work + block_work

    return next_state


def generate_data(
    initial_height: int,
    num_blocks: int,
    fast: bool,
):
    """Generates arguments for Zoro program in a human readable form and the expected result.

    :param initial_height: The block height of the initial chain state (0 means the state after genesis)
    :param num_blocks: The number of blocks to apply on top of it (has to be at least 1)
    :param fast: Placeholder, kept for backwards compatibility (ignored)
    :return: tuple (arguments, expected output)
    """

    if fast:
        logger.warning(
            "Fast mode is not supported for the Zcash data pipeline; falling back to RPC-backed flow."
        )

    logger.debug(
        f"Fetching initial chain state, blocks: [{initial_height}, {initial_height + num_blocks - 1}]..."
    )

    chain_state = fetch_chain_state(initial_height)
    initial_chain_state = chain_state

    next_block_hash = chain_state["nextblockhash"]
    blocks = []

    for i in range(num_blocks):
        if next_block_hash is None:
            raise Exception(f"No next block hash for block {initial_height + i + 1}")

        logger.debug(f"Fetching block {initial_height + i + 1} {i + 1}/{num_blocks}...")

        block = fetch_block_header(next_block_hash)
        blocks.append(block)

        chain_state = next_chain_state(chain_state, block)

        logger.info(f"block: {block}")

        next_block_hash = block.get("nextblockhash")

        logger.info(f"Fetched block {initial_height + i + 1} {i + 1}/{num_blocks}")

    formatted_blocks = list(map(format_block, blocks))
    result = {
        "chain_state": format_chain_state(initial_chain_state),
        "blocks": formatted_blocks,
        "expected": format_chain_state(chain_state),
    }

    if formatted_blocks:
        first_bits = formatted_blocks[0]["header"]["bits"]
        last_bits = formatted_blocks[-1]["header"]["bits"]
        result["chain_state"]["current_target"] = str(bits_int_to_target(first_bits))
        result["expected"]["current_target"] = str(bits_int_to_target(last_bits))

    return result


def str2bool(value):
    if isinstance(value, bool):
        return value
    if value.lower() in ("yes", "true", "t", "y", "1"):
        return True
    elif value.lower() in ("no", "false", "f", "n", "0"):
        return False
    else:
        raise argparse.ArgumentTypeError("Boolean value expected.")


# Example: generate_data.py --height 0 --num_blocks 10 --output_file light_0_10.json
if __name__ == "__main__":
    console_handler = logging.StreamHandler()
    console_handler.setLevel(logging.DEBUG)
    console_handler.setFormatter(
        logging.Formatter("%(asctime)s - %(levelname)4.4s - %(message)s")
    )
    root_logger = logging.getLogger()
    root_logger.addHandler(console_handler)
    root_logger.setLevel(logging.DEBUG)

    logging.getLogger("urllib3").setLevel(logging.WARNING)

    parser = argparse.ArgumentParser(description="Process UTXO files.")

    parser.add_argument(
        "--height",
        dest="height",
        required=True,
        type=int,
        help="The block height of the initial chain state",
    )

    parser.add_argument(
        "--num_blocks",
        dest="num_blocks",
        required=True,
        type=int,
        help="The number of blocks",
    )

    parser.add_argument(
        "--output_file", dest="output_file", required=True, type=str, help="Output file"
    )

    parser.add_argument("--fast", dest="fast", action="store_true", help="Fast mode")

    args = parser.parse_args()

    data = generate_data(
        initial_height=args.height,
        num_blocks=args.num_blocks,
        fast=args.fast,
    )

    Path(args.output_file).write_text(json.dumps(data, indent=2))
