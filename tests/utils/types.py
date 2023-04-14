from collections import namedtuple
from typing import Union

from starkware.starknet.testing.contract import StarknetContract

Uint256 = namedtuple("Uint256", "low high")
YangConfig = namedtuple(
    "YangConfig", "contract_address decimals ceiling threshold price_wad rate gate_address empiric_id"
)

Uint256like = Union[Uint256, tuple[int, int]]
Addressable = Union[int, StarknetContract]
Calldata = list[int]  # payload arguments sent with a function call
Call = tuple[Addressable, str, Calldata]  # receiver address, selector (still as string) and payload
STARKNET_ADDR = r"-?\d+"  # addresses are sometimes printed as negative numbers, hence the -?
