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
# Consts
#

TRUE = 1
FALSE = 0


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
    b = await users("2nd owner")
    c = await users("3rd owner")

    # Authorizing an address and testing that it can use authorized functions
    await trove_owner.send_tx(trove.contract_address, "authorize", [b.address])
    b_authorized = (await trove.get_auth(b.address).invoke()).result.is_auth
    assert b_authorized == TRUE

    await b.send_tx(trove.contract_address, "authorize", [c.address])
    c_authorized = (await trove.get_auth(c.address).invoke()).result.is_auth
    assert c_authorized == TRUE

    #Revoking an address
    await b.send_tx(trove.contract_address, "revoke", [c.address])
    c_authorized = (await trove.get_auth(c.address).invoke()).result.is_auth
    assert c_authorized == FALSE

    # Calling an authorized function with an unauthorized address - should fail
    with pytest.raises(StarkException):
        await c.send_tx(trove.contract_address, "revoke", [b.address])


    


