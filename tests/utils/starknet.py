from decimal import Decimal

from starkware.starknet.testing.contract import StarknetContract

from tests.constants import MAX_UINT256
from tests.utils.types import YangConfig
from tests.utils.wadray import from_fixed_point, from_uint


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
