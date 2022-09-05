"""Utilities for testing Cairo contracts."""
import os
from collections import namedtuple
from decimal import Decimal
from random import seed, uniform
from typing import Callable, Iterable, List, Tuple, Union

from starkware.starknet.business_logic.execution.objects import Event
from starkware.starknet.business_logic.state.state_api_objects import BlockInfo
from starkware.starknet.compiler.compile import compile_starknet_files
from starkware.starknet.public.abi import get_selector_from_name
from starkware.starknet.services.api.contract_class import ContractClass
from starkware.starknet.services.api.feeder_gateway.response_objects import FunctionInvocation
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.objects import StarknetCallInfo
from starkware.starknet.testing.starknet import Starknet

from tests.roles import GateRoles

RANGE_CHECK_BOUND = 2**128
MAX_UINT256 = (2**128 - 1, 2**128 - 1)

STARKNET_ADDR = r"-?\d+"  # addresses are sometimes printed as negative numbers, hence the -?
ZERO_ADDRESS = 0

TRUE = 1
FALSE = 0

WAD_PERCENT = 10**16
RAY_PERCENT = 10**25
WAD_SCALE = 10**18
RAY_SCALE = 10**27
WAD_RAY_DIFF = RAY_SCALE // WAD_SCALE

CAIRO_PRIME = 2**251 + 17 * 2**192 + 1

# Gas estimation constants
NAMES = ["ecdsa_builtin", "range_check_builtin", "bitwise_builtin", "pedersen_builtin"]
WEIGHTS = {
    "storage": 512,
    "step": 0.05,
    "ecdsa_builtin": 25.6,
    "range_check_builtin": 0.4,
    "bitwise_builtin": 12.8,
    "pedersen_builtin": 0.4,
}

Uint256 = namedtuple("Uint256", "low high")
YangConfig = namedtuple("YangConfig", "contract_address ceiling threshold price_wad gate_address")

Uint256like = Union[Uint256, tuple[int, int]]
Addressable = Union[int, StarknetContract]
Calldata = list[int]  # payload arguments sent with a function call
Call = tuple[Addressable, str, Calldata]  # receiver address, selector (still as string) and payload

# Default error margin for fixed point calculations
ERROR_MARGIN = Decimal("0.000000001")

seed(420)


def str_to_felt(text: str) -> int:
    b_text = bytes(text, "ascii")
    return int.from_bytes(b_text, "big")


# Common addresses
ABBOT_OWNER = str_to_felt("abbot owner")
GATE_OWNER = str_to_felt("gate owner")
PURGER_OWNER = str_to_felt("purger owner")
SHRINE_OWNER = str_to_felt("shrine owner")


ADMIN = str_to_felt("admin")
ABBOT = str_to_felt("abbot")
BAD_GUY = str_to_felt("bad guy")

STETH_OWNER = str_to_felt("steth owner")
DOGE_OWNER = str_to_felt("doge owner")

AURA_USER = str_to_felt("aura user")

# Roles
ABBOT_ROLE = GateRoles.DEPOSIT + GateRoles.WITHDRAW

# Troves
TROVE_1 = 1
TROVE_2 = 2

TROVE1_OWNER = str_to_felt("trove 1 owner")
TROVE2_OWNER = str_to_felt("trove 2 owner")
TROVE3_OWNER = str_to_felt("trove 3 owner")
TROVE4_OWNER = str_to_felt("trove 4 owner")

# Shrine constants
LIMIT_RATIO = 95 * RAY_PERCENT
# Time Interval
TIME_INTERVAL = 30 * 60  # Number of seconds in time interval (30 mins)
# 1 / Number of intervals in a year (1 / (2 * 24 * 365) = 0.00005707762557077625)
TIME_INTERVAL_DIV_YEAR = Decimal("0.00005707762557077625")

# Yin constants
INFINITE_YIN_ALLOWANCE = CAIRO_PRIME - 1


def as_address(value: Addressable) -> int:
    if isinstance(value, StarknetContract):
        return value.contract_address
    return value


def signed_int_to_felt(a: int) -> int:
    """Takes in integer value, returns input if positive, otherwise return CAIRO_PRIME + input"""
    if a >= 0:
        return a
    return CAIRO_PRIME + a


def felt_to_str(felt: int) -> str:
    b_felt = felt.to_bytes(31, "big")
    return b_felt.decode()


def to_uint(a: int) -> Uint256:
    """Takes in value, returns Uint256 tuple."""
    return Uint256(low=(a & ((1 << 128) - 1)), high=(a >> 128))


def from_uint(uint: Uint256like) -> int:
    """Takes in uint256-ish tuple, returns value."""
    return uint[0] + (uint[1] << 128)


def assert_event_emitted(
    tx_exec_info,
    from_address,
    name,
    data: Union[None, Callable[[List[int]], bool], Iterable] = None,
):
    key = get_selector_from_name(name)

    if isinstance(data, Callable):
        assert any([data(e.data) for e in tx_exec_info.raw_events if e.from_address == from_address and key in e.keys])
    elif data is not None:
        assert Event(from_address=from_address, keys=[key], data=data) in tx_exec_info.raw_events
    else:  # data=None
        assert any([e for e in tx_exec_info.raw_events if e.from_address == from_address and key in e.keys])


def here() -> str:
    return os.path.abspath(os.path.dirname(__file__))


def contract_path(rel_contract_path: str) -> str:
    return os.path.join(here(), "..", rel_contract_path)


def compile_contract(rel_contract_path: str, request) -> ContractClass:
    contract_src = contract_path(rel_contract_path)
    contract_cache_key = rel_contract_path + "/compiled"
    ctime_key = rel_contract_path + "/ctime"

    contract_ctime = int(os.path.getctime(contract_src))
    last_contract_ctime = request.config.cache.get(ctime_key, None)

    if contract_ctime == last_contract_ctime:
        # if last access time equals current and there's a cache-hit
        # return the compiled contract from cache
        serialized_contract = request.config.cache.get(contract_cache_key, None)
        if serialized_contract is not None:
            return ContractClass.loads(serialized_contract)

    tld = os.path.join(here(), "..")
    compiled_contract = compile_starknet_files(
        [contract_src],
        debug_info=True,
        disable_hint_validation=True,
        cairo_path=[tld, os.path.join(tld, "contracts", "lib")],
    )

    # write compiled contract to cache
    serialized_contract = ContractClass.dumps(compiled_contract)
    request.config.cache.set(contract_cache_key, serialized_contract)
    request.config.cache.set(ctime_key, contract_ctime)

    return compiled_contract


#
# General helper functions
#


def to_wad(n: Union[int, float, Decimal]) -> int:
    return int(n * WAD_SCALE)


def to_ray(n: Union[int, float, Decimal]) -> int:
    return int(n * RAY_SCALE)


def from_wad(n: int) -> Decimal:
    return Decimal(n) / WAD_SCALE


def wad_to_ray(n: int) -> int:
    return int(n * (RAY_SCALE // WAD_SCALE))


def from_ray(n: int) -> Decimal:
    return Decimal(n) / RAY_SCALE


def assert_equalish(a: Decimal, b: Decimal, error=ERROR_MARGIN):
    assert abs(a - b) <= error


#
# Starknet helper functions
#


def get_block_timestamp(sn: Starknet) -> int:
    return sn.state.state.block_info.block_timestamp


def set_block_timestamp(sn: Starknet, block_timestamp: int):
    sn.state.state.block_info = BlockInfo.create_for_testing(sn.state.state.block_info.block_number, block_timestamp)


def get_interval(block_timestamp: int) -> int:
    """
    Helper function to calculate the interval by dividing the provided timestamp
    by the TIME_INTERVAL constant.

    Arguments
    ---------
    block_timestamp: int
        Timestamp value

    Returns
    -------
    Interval ID based on the given timestamp.
    """
    return block_timestamp // TIME_INTERVAL


#
# Shrine helper functions
#

# Returns a price feed
def create_feed(start_price: Decimal, length: int, max_change: float) -> list[int]:
    feed = []

    feed.append(start_price)
    for i in range(1, length):
        change = Decimal(
            uniform(-max_change, max_change)
        )  # Returns the % change in price (in decimal form, meaning 1% = 0.01)
        feed.append(feed[i - 1] * (1 + change))

    # Scaling the feed before returning so it's ready to use in contracts
    return list(map(to_wad, feed))


# Returns the lower and upper bounds of a yang's price as a tuple of wads
def price_bounds(start_price: Decimal, length: int, max_change: float) -> tuple[int, int]:
    lo = ((Decimal("1") - Decimal(max_change)) ** length) * start_price
    hi = ((Decimal("1") + Decimal(max_change)) ** length) * start_price
    return lo, hi


def calculate_threshold_and_value(
    prices: List[int], amounts: List[int], thresholds: List[int]
) -> Tuple[Decimal, Decimal]:
    """
    Helper function to calculate a trove's cumulative weighted threshold and value

    Arguments
    ---------
    prices : List[int]
        Ordered list of the prices of each Yang in wad
    amounts: List[int]
        Ordered list of the amount of each Yang deposited in the Trove in wad
    thresholds: List[Decimal]
        Ordered list of the threshold for each Yang in ray

    Returns
    -------
    A tuple of the cumulative weighted threshold and total trove value, both in Decimal
    """

    cumulative_weighted_threshold = Decimal("0")
    total_value = Decimal("0")

    # Sanity check on inputs
    assert len(prices) == len(amounts) == len(thresholds)

    for p, a, t in zip(prices, amounts, thresholds):
        p = from_wad(p)
        a = from_wad(a)
        t = from_ray(t)

        total_value += p * a
        cumulative_weighted_threshold += p * a * t

    return cumulative_weighted_threshold, total_value


def calculate_trove_threshold(prices: List[int], amounts: List[int], thresholds: List[int]) -> Decimal:
    """
    Helper function to calculate a trove's threshold

    Arguments
    ---------
    prices : List[int]
        Ordered list of the prices of each Yang in wad
    amounts: List[int]
        Ordered list of the amount of each Yang deposited in the Trove in wad
    thresholds: List[Decimal]
        Ordered list of the threshold for each Yang in ray

    Returns
    -------
    Value of the variable threshold in decimal.
    """
    cumulative_weighted_threshold, total_value = calculate_threshold_and_value(prices, amounts, thresholds)
    return cumulative_weighted_threshold / total_value


def calculate_max_forge(prices: List[int], amounts: List[int], thresholds: List[int]) -> Decimal:
    """
    Helper function to calculate the maximum amount of debt a trove can forge

    Arguments
    ---------
    prices : List[int]
        Ordered list of the prices of each Yang in wad
    amounts: List[int]
        Ordered list of the amount of each Yang deposited in the Trove in wad
    thresholds: List[Decimal]
        Ordered list of the threshold for each Yang in ray

    Returns
    -------
    Value of the maximum forge value for a Trove in decimal.
    """
    cumulative_weighted_threshold, _ = calculate_threshold_and_value(prices, amounts, thresholds)
    return cumulative_weighted_threshold * from_ray(LIMIT_RATIO)


#
# Token helpers
#


async def max_approve(token: StarknetContract, owner_addr: int, spender_addr: int):
    await token.approve(spender_addr, MAX_UINT256).execute(caller_address=owner_addr)


#
# Gas estimation
#


def estimate_gas(tx_info: StarknetCallInfo, num_storage_keys: int = 0, num_contracts: int = 0):
    """
    Helper function to estimate gas for a transaction.

    Arguments
    ---------
    tx_info : StarknetCallInfo.
        Transaction receipt
    num_storage_keys : int
        Number of unique keys updated in the transaction.
    num_contracts : int
        Number of unique contracts updated in the transaction.
    """
    gas_no_storage = estimate_gas_inner(tx_info.call_info)
    return gas_no_storage + (2 * num_storage_keys + 2 * num_contracts) * WEIGHTS["storage"]


def estimate_gas_inner(call_info: FunctionInvocation):
    steps = call_info.execution_resources.n_steps
    builtins = call_info.execution_resources.builtin_instance_counter
    print(builtins)
    # Sum of all gas consumed across both the call and its internal calls

    sum_gas = sum(WEIGHTS[name] * builtins[name] for name in NAMES if builtins.get(name)) + steps * WEIGHTS["step"]
    for call in call_info.internal_calls:
        sum_gas += estimate_gas_inner(call)

    return sum_gas
