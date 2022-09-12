import pytest
from starkware.starkware_utils.error_handling import StarkException

from tests.utils import FALSE, TRUE, assert_event_emitted, compile_contract


@pytest.fixture(scope="session")
async def auth_contract(starknet_session):
    contract = compile_contract("tests/lib/auth_contract.cairo")
    return await starknet_session.deploy(contract_class=contract)


@pytest.mark.asyncio
async def test_authorize_and_revoke(auth_contract):
    addr = 123
    assert (await auth_contract.is_authorized(addr).execute()).result.bool == FALSE
    tx = await auth_contract.authorize(addr).execute()
    assert_event_emitted(tx, auth_contract.contract_address, "Authorized", [addr])
    assert (await auth_contract.is_authorized(addr).execute()).result.bool == TRUE
    tx = await auth_contract.revoke(addr).execute()
    assert_event_emitted(tx, auth_contract.contract_address, "Revoked", [addr])
    assert (await auth_contract.is_authorized(addr).execute()).result.bool == FALSE


@pytest.mark.asyncio
async def test_assert_caller_authed(auth_contract):
    caller = 999

    with pytest.raises(StarkException):
        await auth_contract.assert_caller_authed().execute()

    await auth_contract.authorize(caller).execute()
    assert (await auth_contract.is_authorized(caller).execute()).result.bool == TRUE
    assert (await auth_contract.assert_caller_authed().execute(caller_address=caller)).result.bool == TRUE


@pytest.mark.asyncio
async def test_assert_address_authed(auth_contract):
    addr = 321

    with pytest.raises(StarkException):
        await auth_contract.assert_address_authed(addr).execute()

    await auth_contract.authorize(addr).execute()
    assert (await auth_contract.assert_address_authed(addr).execute()).result.bool == TRUE
