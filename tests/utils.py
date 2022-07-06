"""Utilities for testing Cairo contracts."""
import os
from collections import namedtuple
from decimal import Decimal
from functools import cache
from random import seed, uniform
from typing import Union

from starkware.starknet.business_logic.execution.objects import Event
from starkware.starknet.business_logic.state.state import BlockInfo
from starkware.starknet.compiler.compile import compile_starknet_files
from starkware.starknet.public.abi import get_selector_from_name
from starkware.starknet.services.api.contract_class import ContractClass
from starkware.starknet.services.api.feeder_gateway.response_objects import FunctionInvocation
from starkware.starknet.testing.objects import StarknetTransactionExecutionInfo
from starkware.starknet.testing.starknet import StarknetContract

MAX_UINT256 = (2**128 - 1, 2**128 - 1)
ZERO_ADDRESS = 0
TRUE = 1
FALSE = 0

WAD_SCALE = 10**18
RAY_SCALE = 10**27

# Gas estimation constants
NAMES = [
    "ecdsa_builtin",
    "range_check_builtin",
    "bitwise_builtin",
    "pedersen_builtin",
]
WEIGHTS = {
    "storage": 512,
    "step": 0.05,
    "ecdsa_builtin": 25.6,
    "range_check_builtin": 0.4,
    "bitwise_builtin": 12.8,
    "pedersen_builtin": 0.4,
}

Uint256 = namedtuple("Uint256", "low high")
Uint256like = Union[Uint256, tuple[int, int]]
Addressable = Union[int, StarknetContract]
Calldata = list[int]  # payload arguments sent with a function call
Call = tuple[Addressable, str, Calldata]  # receiver address, selector (still as string) and payload

# Acceptable error margin for fixed point calculations
ERROR_MARGIN = Decimal("0.000000001")

seed(420)


def as_address(value: Addressable) -> int:
    if isinstance(value, StarknetContract):
        return value.contract_address
    return value


def str_to_felt(text: str) -> int:
    b_text = bytes(text, "ascii")
    return int.from_bytes(b_text, "big")


def felt_to_str(felt: int) -> str:
    b_felt = felt.to_bytes(31, "big")
    return b_felt.decode()


def to_uint(a: int) -> Uint256:
    """Takes in value, returns Uint256 tuple."""
    return Uint256(low=(a & ((1 << 128) - 1)), high=(a >> 128))


def from_uint(uint: Uint256like) -> int:
    """Takes in uint256-ish tuple, returns value."""
    return uint[0] + (uint[1] << 128)


def assert_event_emitted(tx_exec_info, from_address, name, data=None):
    if data is not None:
        assert (
            Event(
                from_address=from_address,
                keys=[get_selector_from_name(name)],
                data=data,
            )
            in tx_exec_info.raw_events
        )
    else:
        key = get_selector_from_name(name)
        assert any([e for e in tx_exec_info.raw_events if e.from_address == from_address and key in e.keys])


def here() -> str:
    return os.path.abspath(os.path.dirname(__file__))


def contract_path(rel_contract_path: str) -> str:
    return os.path.join(here(), "..", rel_contract_path)


@cache
def compile_contract(rel_contract_path: str) -> ContractClass:
    contract_src = contract_path(rel_contract_path)
    tld = os.path.join(here(), "..")
    return compile_starknet_files(
        [contract_src],
        debug_info=True,
        disable_hint_validation=True,
        cairo_path=[tld, os.path.join(tld, "contracts", "lib")],
    )


#
# General helper functions
#


def to_wad(n: Union[float, Decimal]) -> int:
    return int(n * WAD_SCALE)


def from_wad(n: int) -> Decimal:
    return Decimal(n) / WAD_SCALE


def from_ray(n: int) -> Decimal:
    return Decimal(n) / RAY_SCALE


def assert_equalish(a: Decimal, b: Decimal):
    assert abs(a - b) <= ERROR_MARGIN


#
# Shrine helper functions
#

# Returns a price feed
def create_feed(start_price: Decimal, length: int, max_change: Decimal) -> list[int]:
    feed = []

    feed.append(start_price)
    for i in range(1, length):
        change = Decimal(
            uniform(-float(max_change), -float(max_change))
        )  # Returns the % change in price (in decimal form, meaning 1% = 0.01)
        feed.append(feed[i - 1] * (1 + change))

    # Scaling the feed before returning so it's ready to use in contracts
    return list(map(to_wad, feed))


# Returns the lower and upper bounds of a yang's price as a tuple of wads
def price_bounds(start_price: Decimal, length: int, max_change: float) -> tuple[int, int]:
    lo = ((Decimal("1") - Decimal(max_change)) ** length) * start_price
    hi = ((Decimal("1") + Decimal(max_change)) ** length) * start_price
    return lo, hi


def set_block_timestamp(sn, block_timestamp):
    sn.state.block_info = BlockInfo(
        sn.state.block_info.block_number,
        block_timestamp,
        sn.state.block_info.gas_price,
        sequencer_address=None,
    )


#
# Gas estimation
#


def estimate_gas(
    tx_info: StarknetTransactionExecutionInfo,
    num_storage_keys: int = 0,
    num_contracts: int = 0,
):
    gas_no_storage = estimate_gas_inner(tx_info.call_info)
    return gas_no_storage + (2 * num_storage_keys + 2 * num_contracts) * WEIGHTS["storage"]


def estimate_gas_inner(call_info: FunctionInvocation):
    steps = call_info.execution_resources.n_steps
    builtins = call_info.execution_resources.builtin_instance_counter

    # Sum of all gas consumed across both the call and its internal calls
    sum_gas = sum(WEIGHTS[name] * builtins[name] for name in NAMES) + steps * WEIGHTS["step"]
    for call in call_info.internal_calls:
        sum_gas += estimate_gas_inner(call)

    return sum_gas
