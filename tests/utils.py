"""Utilities for testing Cairo contracts."""
import os
from collections import namedtuple
from datetime import datetime
from decimal import ROUND_DOWN, Decimal
from functools import cache
from random import seed, uniform
from typing import Callable, Iterable, Union

from starkware.cairo.lang.compiler.cairo_compile import get_codes
from starkware.starknet.business_logic.execution.objects import Event
from starkware.starknet.business_logic.state.state_api_objects import BlockInfo
from starkware.starknet.compiler.compile import compile_starknet_codes, compile_starknet_files
from starkware.starknet.public.abi import get_selector_from_name
from starkware.starknet.services.api.contract_class.contract_class import ContractClass
from starkware.starknet.services.api.feeder_gateway.response_objects import FunctionInvocation
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.objects import StarknetCallInfo
from starkware.starknet.testing.starknet import Starknet
from starkware.starkware_utils.error_handling import StarkException

from tests.roles import GateRoles, SentinelRoles, ShrineRoles

RANGE_CHECK_BOUND = 2**128
MAX_UINT256 = (2**128 - 1, 2**128 - 1)

STARKNET_ADDR = r"-?\d+"  # addresses are sometimes printed as negative numbers, hence the -?
ZERO_ADDRESS = 0

TRUE = 1
FALSE = 0

WAD_DECIMALS = 18
RAY_DECIMALS = 27
WAD_PERCENT = 10 ** (WAD_DECIMALS - 2)
RAY_PERCENT = 10 ** (RAY_DECIMALS - 2)
WAD_SCALE = 10**WAD_DECIMALS
RAY_SCALE = 10**RAY_DECIMALS
WAD_RAY_DIFF = RAY_SCALE // WAD_SCALE
WAD_RAY_BOUND = 2**125

CAIRO_PRIME = 2**251 + 17 * 2**192 + 1

# Decimal precision
WBTC_DECIMALS = 8
EMPIRIC_DECIMALS = 8

# Gas estimation constants
NAMES = ["ecdsa_builtin", "range_check_builtin", "bitwise_builtin", "pedersen_builtin", "ec_op_builtin"]
WEIGHTS = {
    "storage": 512,
    "step": 0.05,
    "ecdsa_builtin": 102.4,
    "range_check_builtin": 0.8,
    "bitwise_builtin": 3.2,
    "pedersen_builtin": 1.6,
    "ec_op_builtin": 51.2,
}

Uint256 = namedtuple("Uint256", "low high")
YangConfig = namedtuple(
    "YangConfig", "contract_address decimals ceiling threshold price_wad rate gate_address empiric_id"
)

Uint256like = Union[Uint256, tuple[int, int]]
Addressable = Union[int, StarknetContract]
Calldata = list[int]  # payload arguments sent with a function call
Call = tuple[Addressable, str, Calldata]  # receiver address, selector (still as string) and payload


def custom_error_margin(negative_exp: int) -> Decimal:
    return Decimal(f"1E-{negative_exp}")


# Default error margin for fixed point calculations
ERROR_MARGIN = custom_error_margin(10)
WAD_ERROR_MARGIN = custom_error_margin(WAD_DECIMALS)
WBTC_ERROR_MARGIN = custom_error_margin(WBTC_DECIMALS)

seed(420)


def str_to_felt(text: str) -> int:
    b_text = bytes(text, "ascii")
    return int.from_bytes(b_text, "big")


# Common addresses
ABBOT_OWNER = str_to_felt("abbot owner")
SENTINEL_OWNER = str_to_felt("sentinel owner")
GATE_OWNER = str_to_felt("gate owner")
SHRINE_OWNER = str_to_felt("shrine owner")
EMPIRIC_OWNER = str_to_felt("empiric owner")
ABSORBER_OWNER = str_to_felt("absorber owner")

BAD_GUY = str_to_felt("bad guy")

# Roles
GATE_ROLE_FOR_SENTINEL = GateRoles.ENTER + GateRoles.EXIT
SENTINEL_ROLE_FOR_ABBOT = SentinelRoles.ENTER + SentinelRoles.EXIT
SHRINE_ROLE_FOR_PURGER = ShrineRoles.MELT + ShrineRoles.SEIZE + ShrineRoles.REDISTRIBUTE
SHRINE_ROLE_FOR_FLASHMINT = ShrineRoles.INJECT + ShrineRoles.EJECT

# Troves
TROVE_1 = 1
TROVE_2 = 2
TROVE_3 = 3

TROVE1_OWNER = str_to_felt("trove 1 owner")
TROVE2_OWNER = str_to_felt("trove 2 owner")
TROVE3_OWNER = str_to_felt("trove 3 owner")

# Time Interval
TIME_INTERVAL = 30 * 60  # Number of seconds in time interval (30 mins)
# 1 / Number of intervals in a year (1 / (2 * 24 * 365) = 0.00005707762557077625)
TIME_INTERVAL_DIV_YEAR = Decimal("0.00005707762557077625")

# Yin constants
INFINITE_YIN_ALLOWANCE = 2**256 - 1

# Initial deposit amount to Gate to prevent first depositor front-running
INITIAL_ASSET_DEPOSIT_AMT = 10**3


def as_address(value: Addressable) -> int:
    if isinstance(value, StarknetContract):
        return value.contract_address
    return value


def signed_int_to_felt(a: int) -> int:
    """Takes in integer value, returns input if positive, otherwise return CAIRO_PRIME + input"""
    if a >= 0:
        return a
    return CAIRO_PRIME + a


# Out of bound values for WadRay
WAD_RAY_OOB_VALUES = [signed_int_to_felt(-1), WAD_RAY_BOUND + 1]


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
    data: Union[None, Callable[[list[int]], bool], Iterable] = None,
):
    key = get_selector_from_name(name)

    if isinstance(data, Callable):
        assert any([data(e.data) for e in tx_exec_info.raw_events if e.from_address == from_address and key in e.keys])
    elif data is not None:
        assert Event(from_address=from_address, keys=[key], data=data) in tx_exec_info.raw_events
    else:  # data=None
        assert any([e for e in tx_exec_info.raw_events if e.from_address == from_address and key in e.keys])


def assert_event_not_emitted(
    tx_exec_info,
    from_address,
    name,
):
    key = get_selector_from_name(name)
    assert not any([e for e in tx_exec_info.raw_events if e.from_address == from_address and key in e.keys])


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


def get_contract_code_with_replacement(rel_contract_path: str, replacements: dict[str, str]) -> tuple[str, str]:
    """
    Modify the source code of a contract by passing in a dictionary with the string to be replaced as the key
    and the new string as the value.

    Returns a tuple of the source code and the filename.
    """
    code = get_codes([rel_contract_path])

    contract = code[0][0]
    filename = code[0][1]

    for k, v in replacements.items():
        contract = contract.replace(k, v)

    code = (contract, filename)
    return code


def get_contract_code_with_addition(code: tuple[str, str], addition: str) -> tuple[str, str]:
    """
    Adds code to the source code of a contract, after `get_contract_code_with_replacement`.
    """
    contract = code[0]
    filename = code[1]

    contract += addition

    return (contract, filename)


@cache
def compile_code(code: tuple[str, str]) -> StarknetContract:
    """
    Compile the source code of a contract.

    Takes in a tuple of the source code and the contract filename.
    """
    tld = os.path.join(here(), "..")

    return compile_starknet_codes(
        [code],
        debug_info=True,
        disable_hint_validation=True,
        cairo_path=[tld, os.path.join(tld, "contracts", "lib")],
    )


#
# General helper functions
#


def to_fixed_point(n: Union[int, float, Decimal], decimals: int) -> int:
    """
    Helper function to scale a number to its fixed point equivalent
    according to the given decimal precision.

    Arguments
    ---------
    n: int
        Amount in real terms.
    decimals: int
        Number of decimals to scale by.

    Returns
    -------
    Scaled amount.
    """
    return int(n * 10**decimals)


def from_fixed_point(n: int, decimals: int) -> Decimal:
    """
    Helper function to scale a fixed point number to real value
    according to the given decimal precision.

    Arguments
    ---------
    n: int
        Amount in fixed point.
    decimals: int
        Number of decimals to scale by.

    Returns
    -------
    Real value in Decimal.
    """
    return Decimal(n) / 10**decimals


def to_wad(n: Union[int, float, Decimal]) -> int:
    return to_fixed_point(n, WAD_DECIMALS)


def to_ray(n: Union[int, float, Decimal]) -> int:
    return to_fixed_point(n, RAY_DECIMALS)


def from_wad(n: int) -> Decimal:
    return from_fixed_point(n, WAD_DECIMALS)


def wad_to_ray(n: int) -> int:
    return to_fixed_point(n, RAY_DECIMALS - WAD_DECIMALS)


def ray_to_wad(n: int) -> int:
    return n // 10 ** (RAY_DECIMALS - WAD_DECIMALS)


def from_ray(n: int) -> Decimal:
    return from_fixed_point(n, RAY_DECIMALS)


def to_empiric(value: Union[int, float, Decimal]) -> int:
    """
    Empiric reports the pairs used in this test suite with 8 decimals.
    This function converts a "regular" numeric value to an Empiric native
    one, i.e. as if it was returned from Empiric.
    """
    return int(value * (10**8))


def assert_equalish(a: Decimal, b: Decimal, error=ERROR_MARGIN):
    # Truncate inputs to the accepted error margin
    # For example, comparing 0.0001 and 0.00020123 should pass with an error margin of 1E-4.
    # Without rounding, it would not pass because 0.00010123 > 0.0001
    a = a.quantize(error, rounding=ROUND_DOWN)
    b = b.quantize(error, rounding=ROUND_DOWN)
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


# Note that timestamp (and timestamp) cannot start at 0 because:
# 1. Initial price and multiplier are assigned to current interval - 1
# 2. Cooldown period in absorber will be automatically triggered
DEPLOYMENT_TIMESTAMP = int(datetime.utcnow().timestamp())
DEPLOYMENT_INTERVAL = get_interval(DEPLOYMENT_TIMESTAMP)


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


def calculate_trove_threshold_and_value(
    prices: list[Decimal], amounts: list[Decimal], thresholds: list[Decimal]
) -> tuple[Decimal, Decimal]:
    """
    Helper function to calculate a trove's threshold and value

    Arguments
    ---------
    prices : list[Decimal]
        Ordered list of the prices of each Yang in Decimal
    amounts: list[Decimal]
        Ordered list of the amount of each Yang deposited in the Trove in Decimal
    thresholds: list[Decimal]
        Ordered list of the threshold for each Yang in Decimal

    Returns
    -------
    A tuple of the cumulative weighted threshold and total trove value, both in Decimal
    """

    cumulative_weighted_threshold = Decimal("0")
    total_value = Decimal("0")

    # Sanity check on inputs
    assert len(prices) == len(amounts) == len(thresholds)

    for p, a, t in zip(prices, amounts, thresholds):
        total_value += p * a
        cumulative_weighted_threshold += p * a * t

    threshold = 0
    if total_value > 0:
        threshold = cumulative_weighted_threshold / total_value

    return threshold, total_value


def calculate_max_forge(prices: list[Decimal], amounts: list[Decimal], thresholds: list[Decimal]) -> Decimal:
    """
    Helper function to calculate the maximum amount of debt a trove can forge

    Arguments
    ---------
    prices : list[Decimal]
        Ordered list of the prices of each Yang in Decimal
    amounts: list[Decimal]
        Ordered list of the amount of each Yang deposited in the Trove in Decimal
    thresholds: list[Decimal]
        Ordered list of the threshold for each Yang in Decimal

    Returns
    -------
    Value of the maximum forge value for a Trove in decimal.
    """
    threshold, value = calculate_trove_threshold_and_value(prices, amounts, thresholds)
    return threshold * value


#
# Token helpers
#


async def max_approve(token: StarknetContract, owner_addr: int, spender_addr: int):
    await token.approve(spender_addr, MAX_UINT256).execute(caller_address=owner_addr)


async def get_token_balances(
    tokens: tuple[StarknetContract],
    addresses: list[int],
) -> list[list[Decimal]]:
    """
    Helper function to fetch the token balances for a list of addreses.

    Arguments
    ---------
    tokens: tuple[StarknetContract]
        Ordered tuple of token contract instances for the tokens
    addresses: list[int]
        List of addresses to fetch the balances of.

    Returns
    -------
    An ordered 2D list of token balances in Decimal for each address.
    """
    ret = []
    for address in addresses:
        address_bals = []
        for token in tokens:
            decimals = (await token.decimals().execute()).result.decimals
            bal = from_fixed_point(
                from_uint((await token.balanceOf(address).execute()).result.balance),
                decimals,
            )
            address_bals.append(bal)

        ret.append(address_bals)

    return ret


async def get_yangs_total(
    shrine: StarknetContract,
    tokens_info: tuple[YangConfig],
) -> list[list[int]]:
    """
    Helper function to fetch the yang balances.

    Arguments
    ---------
    shrine: StarknetContract
        Deployed instance of Shrine.
    tokens_info: tuple[YangConfig]
        Ordered tuple of YangConfig

    Returns
    -------
    An ordered list of total yang in wad for each asset.
    """
    ret = []
    for token_info in tokens_info:
        total = (await shrine.get_yang_total(token_info.contract_address).execute()).result.total
        ret.append(total)

    return ret


#
# Gas estimation
#


def estimate_gas(
    tx_info: StarknetCallInfo,
    num_storage_keys: int = 0,
    num_contracts: int = 0,
):
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

    # Sum of all gas consumed across both the call and its internal calls
    sum_gas = sum(WEIGHTS[name] * builtins[name] for name in NAMES if builtins.get(name)) + steps * WEIGHTS["step"]
    for call in call_info.internal_calls:
        sum_gas += estimate_gas_inner(call)

    return sum_gas


def is_starknet_error(err, *args):
    """
    Filter function to be passed to `flaky` to determine if a failed test should be retried.
    Returns True if the failure is due to a `StarkException`.
    """
    return issubclass(err[0], StarkException)
