"""Utilities for testing Cairo contracts."""
import os

from collections import namedtuple
from functools import cache
from typing import Union

from starkware.starknet.business_logic.execution.objects import Event
from starkware.starknet.compiler.compile import compile_starknet_files
from starkware.starknet.public.abi import get_selector_from_name
from starkware.starknet.services.api.contract_class import ContractClass
from starkware.starknet.testing.starknet import StarknetContract

MAX_UINT256 = (2**128 - 1, 2**128 - 1)
ZERO_ADDRESS = 0
TRUE = 1
FALSE = 0


Uint256 = namedtuple("Uint256", "low high")
Uint256like = Union[Uint256, tuple[int, int]]
Addressable = Union[int, StarknetContract]
Calldata = list[int]  # payload arguments sent with a function call
Call = tuple[Addressable, str, Calldata]  # receiver address, selector (still as string) and payload


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
