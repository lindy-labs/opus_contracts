import pytest
from starkware.starkware_utils.error_handling import StarkException

from tests.utils import FALSE, TRUE, assert_event_emitted, compile_contract


@pytest.fixture(scope="session")
async def auth_contract(request, starknet_session):
    contract = compile_contract("tests/lib/auth_contract.cairo", request)
    return await starknet_session.deploy(contract_class=contract)


@pytest.mark.asyncio
async def test_authorize_and_revoke(auth_contract):
    addr = 123
    assert (await auth_contract.is_authorized(addr).invoke()).result.bool == FALSE
    tx = await auth_contract.authorize(addr).invoke()
    assert_event_emitted(tx, auth_contract.contract_address, "Authorized", [addr])
    assert (await auth_contract.is_authorized(addr).invoke()).result.bool == TRUE
    tx = await auth_contract.revoke(addr).invoke()
    assert_event_emitted(tx, auth_contract.contract_address, "Revoked", [addr])
    assert (await auth_contract.is_authorized(addr).invoke()).result.bool == FALSE


@pytest.mark.asyncio
async def test_assert_caller_authed(auth_contract):
    caller = 999

    with pytest.raises(StarkException):
        await auth_contract.assert_caller_authed().invoke()

    await auth_contract.authorize(caller).invoke()
    assert (await auth_contract.is_authorized(caller).invoke()).result.bool == TRUE
    assert (await auth_contract.assert_caller_authed().invoke(caller_address=caller)).result.bool == TRUE


@pytest.mark.asyncio
async def test_assert_address_authed(auth_contract):
    addr = 321

    with pytest.raises(StarkException):
        await auth_contract.assert_address_authed(addr).invoke()

    await auth_contract.authorize(addr).invoke()
    assert (await auth_contract.assert_address_authed(addr).invoke()).result.bool == TRUE
