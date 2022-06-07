import pytest
from starkware.starkware_utils.error_handling import StarkException
from starkware.starknet.testing.starknet import StarknetContract

from utils import (
    MAX_UINT256,
    Uint256,
    compile_contract,
    to_uint,
    from_uint,
    assert_event_emitted,
    felt_to_str,
)

#
# Fixtures
#


# Returns the deployed trove module
@pytest.fixture
async def trove(starknet, users) -> StarknetContract:

    trove_owner = await users("trove owner")
    trove_contract = compile_contract("contracts/trove/trove.cairo")

    trove = await starknet.deploy(
        contract_def=trove_contract, 
        constructor_calldata=[
            trove_owner.address
        ]
    )

    return trove 

#
# Tests
# 

@pytest.mark.asyncio
async def test_trove(trove, users):

    trove_owner = await users("trove owner")
    second_owner = await users("2nd owner")

    await trove_owner.send_tx(trove.contract_address, "authorize", [second_owner.address])