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

from random import uniform

#
# Consts
#

TRUE = 1
FALSE = 0

SCALE = 10**18

SECONDS_PER_MINUTE = 60

# Utility functions

def to_wad(n : float):
    return int(n*SCALE)

# Returns a price feed 
def create_feed(starting_price : float, length : int, max_change : float) -> list[int]:
    feed = []

    feed.append(starting_price)
    for i in range(1, length):
        change = uniform(-max_change, max_change) # Returns the % change in price (in decimal form, meaning 1% = 0.01)
        feed.append(feed[i-1]*(1 + change))
    
    return list(map(lambda x: int(SCALE*x),  feed)) #Scaling the feed before returning so it's ready to use in contracts


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

# Same as above but also comes with ready-to-use gages and price feeds
@pytest.fixture 
async def trove_setup(users, trove) -> StarknetContract:

    trove_owner = await users("trove owner")

    # Creating the gages
    await trove_owner.send_tx(trove.contract_address, "add_gage", [10_000 * SCALE]) 
    await trove_owner.send_tx(trove.contract_address, "add_gage", [50_000 * SCALE]) 
    await trove_owner.send_tx(trove.contract_address, "add_gage", [10_000_000 * SCALE]) 

    feed_len = 20
    # Creating the price feeds
    feed0 = create_feed(2000, feed_len, 0.025)
    feed1 = create_feed(500, feed_len, 0.025)
    feed2 = create_feed(1.25, feed_len, 0.025)

    # Putting the price feeds in the `series` storage variable
    for i in range(feed_len):
        trove_owner.send_tx(trove.contract_address, "advance", [0, feed0[i], i*30*SECONDS_PER_MINUTE])
        trove_owner.send_tx(trove.contract_address, "advance", [1, feed1[i], i*30*SECONDS_PER_MINUTE])
        trove_owner.send_tx(trove.contract_address, "advance", [2, feed2[i], i*30*SECONDS_PER_MINUTE])
    
    return trove

#
# Tests
# 

@pytest.mark.asyncio
async def test_auth(trove, users):

    trove_owner = await users("trove owner")


    #
    # Auth
    #

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

@pytest.mark.asyncio 
async def test_trove(trove_setup, users):
    trove = trove_setup

    





