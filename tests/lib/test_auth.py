import pytest
from starkware.starkware_utils.error_handling import StarkException

from tests.utils import FALSE, TRUE, assert_event_emitted, compile_contract


@pytest.fixture(scope="session")
async def auth_contract(starknet):
    contract = compile_contract("tests/lib/auth_contract.cairo")
    return await starknet.deploy(contract_class=contract)


@pytest.mark.asyncio
async def test_authorize_and_revoke(auth_contract):
    addr = 123
    assert (await auth_contract.get_authorization(addr).invoke()).result.bool == FALSE
    tx = await auth_contract.authorize(addr).invoke()
    assert_event_emitted(tx, auth_contract.contract_address, "Authorized", [addr])
    assert (await auth_contract.get_authorization(addr).invoke()).result.bool == TRUE
    tx = await auth_contract.revoke(addr).invoke()
    assert_event_emitted(tx, auth_contract.contract_address, "Revoked", [addr])
    assert (await auth_contract.get_authorization(addr).invoke()).result.bool == FALSE


@pytest.mark.asyncio
async def test_assert_caller(auth_contract):
    caller = 999

    with pytest.raises(StarkException):
        await auth_contract.assert_caller().invoke()

    await auth_contract.authorize(caller).invoke()
    assert (await auth_contract.get_authorization(caller).invoke()).result.bool == TRUE
    assert (await auth_contract.assert_caller().invoke(caller_address=caller)).result.bool == TRUE


@pytest.mark.asyncio
async def test_assert_address(auth_contract):
    addr = 321

    with pytest.raises(StarkException):
        await auth_contract.assert_address(addr).invoke()

    await auth_contract.authorize(addr).invoke()
    assert (await auth_contract.assert_address(addr).invoke()).result.bool == TRUE
