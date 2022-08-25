from enum import IntEnum
from itertools import combinations
from typing import Callable, List, Tuple

import pytest
from starkware.starknet.testing.objects import StarknetTransactionExecutionInfo
from starkware.starknet.testing.starknet import StarknetContract
from starkware.starkware_utils.error_handling import StarkException

from tests.utils import BAD_GUY, FALSE, TRUE, assert_event_emitted, compile_contract, str_to_felt

ACL_OWNER = str_to_felt("acl owner")
NEW_ACL_OWNER = str_to_felt("new acl owner")
ACL_USER = str_to_felt("acl user")


class Roles(IntEnum):
    EXECUTE = 1
    WRITE = 2
    READ = 4


SUDO_USER: int = sum([r.value for r in Roles])

ROLES_COMBINATIONS: List[Tuple[Roles, ...]] = []

for i in range(1, len(Roles) + 1):
    for j in combinations(Roles, i):
        ROLES_COMBINATIONS.append(j)


@pytest.fixture
async def acl(starknet_session) -> StarknetContract:
    contract = compile_contract("tests/lib/acl/acl_contract.cairo")
    return await starknet_session.deploy(contract_class=contract, constructor_calldata=[ACL_OWNER])


@pytest.fixture
async def sudo_user(acl):
    # Grant user all permissions
    await acl.grant_role(SUDO_USER, ACL_USER).invoke(caller_address=ACL_OWNER)


@pytest.fixture
async def acl_change_admin(acl) -> StarknetTransactionExecutionInfo:
    tx = await acl.change_admin(NEW_ACL_OWNER).invoke(caller_address=ACL_OWNER)
    return tx


@pytest.fixture
async def acl_new_admin(acl, acl_change_admin) -> StarknetContract:
    return acl


@pytest.fixture
def acl_both(request) -> StarknetContract:
    """
    Wrapper fixture to pass two different instances of ACL to `pytest.parametrize`,
    before and after change of admin.

    Returns a tuple of the ACL contract and the caller
    """
    caller = ACL_OWNER if request.param == "acl" else NEW_ACL_OWNER
    return (request.getfixturevalue(request.param), caller)


@pytest.mark.asyncio
async def test_acl_setup(acl):
    admin = (await acl.get_admin().invoke()).result.address
    assert admin == ACL_OWNER

    await acl.assert_admin().invoke(caller_address=ACL_OWNER)

    with pytest.raises(StarkException, match="AccessControl: caller is not admin"):
        await acl.assert_admin().invoke(caller_address=NEW_ACL_OWNER)


@pytest.mark.asyncio
async def test_change_admin(acl, acl_change_admin):
    # Check event
    assert_event_emitted(
        acl_change_admin,
        acl.contract_address,
        "AdminChanged",
        [ACL_OWNER, NEW_ACL_OWNER],
    )

    # Check admin
    admin = (await acl.get_admin().invoke()).result.address
    assert admin == NEW_ACL_OWNER

    await acl.assert_admin().invoke(caller_address=NEW_ACL_OWNER)

    with pytest.raises(StarkException, match="AccessControl: caller is not admin"):
        await acl.assert_admin().invoke(caller_address=ACL_OWNER)


@pytest.mark.asyncio
async def test_change_admin_unauthorized(acl):
    with pytest.raises(StarkException, match="AccessControl: caller is not admin"):
        await acl.change_admin(BAD_GUY).invoke(caller_address=BAD_GUY)


@pytest.mark.parametrize("given_roles", ROLES_COMBINATIONS)
@pytest.mark.parametrize("revoked_roles", ROLES_COMBINATIONS)
@pytest.mark.parametrize("acl_both", ["acl", "acl_new_admin"], indirect=["acl_both"])
@pytest.mark.asyncio
async def test_grant_and_revoke_role(acl_both, given_roles, revoked_roles):
    acl, admin = acl_both

    # Compute value of given role
    given_role_value = sum([r.value for r in given_roles])

    tx = await acl.grant_role(given_role_value, ACL_USER).invoke(caller_address=admin)

    # Check event
    assert_event_emitted(tx, acl.contract_address, "RoleGranted", [given_role_value, ACL_USER])

    # Check role
    role = (await acl.get_role(ACL_USER).invoke()).result.ufelt
    assert role == given_role_value

    # Check roles granted
    for r in Roles:
        role_value = r.value

        # Check `has_role`
        has_role = (await acl.has_role(role_value, ACL_USER).invoke()).result.bool

        # Check getter
        role_name = r.name.lower()
        getter: Callable = acl.get_contract_function(f"can_{role_name}")
        can_perform_role = (await getter(ACL_USER).invoke()).result.bool

        expected = TRUE if r in given_roles else FALSE
        assert has_role == can_perform_role == expected

    # Compute value of revoked role
    revoked_role_value = sum([r.value for r in revoked_roles])

    tx = await acl.revoke_role(revoked_role_value, ACL_USER).invoke(caller_address=admin)

    # Check event
    assert_event_emitted(tx, acl.contract_address, "RoleRevoked", [revoked_role_value, ACL_USER])

    # Check role
    updated_role = (await acl.get_role(ACL_USER).invoke()).result.ufelt
    expected_role = given_role_value & (~revoked_role_value)
    assert updated_role == expected_role

    # Check roles remaining
    updated_role_list = [i for i in given_roles if i not in revoked_roles]
    for r in Roles:
        role_value = r.value

        # Check `has_role`
        has_role = (await acl.has_role(role_value, ACL_USER).invoke()).result.bool

        # Check getter
        role_name = r.name.lower()
        getter: Callable = acl.get_contract_function(f"can_{role_name}")
        can_perform_role = (await getter(ACL_USER).invoke()).result.bool

        if r in updated_role_list:
            assert has_role == can_perform_role == TRUE
            await acl.assert_has_role(role_value).invoke(caller_address=ACL_USER)
        else:
            assert has_role == can_perform_role == FALSE
            with pytest.raises(
                StarkException,
                match=f"AccessControl: caller is missing role {role_value}",
            ):
                await acl.assert_has_role(role_value).invoke(caller_address=ACL_USER)


@pytest.mark.usefixtures("sudo_user")
@pytest.mark.asyncio
async def test_role_actions_unauthorized(acl):
    with pytest.raises(StarkException, match="AccessControl: caller is not admin"):
        await acl.grant_role(SUDO_USER, BAD_GUY).invoke(caller_address=BAD_GUY)

    with pytest.raises(StarkException, match="AccessControl: caller is not admin"):
        await acl.revoke_role(SUDO_USER, ACL_USER).invoke(caller_address=BAD_GUY)

    with pytest.raises(StarkException, match="AccessControl: can only renounce roles for self"):
        await acl.renounce_role(SUDO_USER, ACL_USER).invoke(caller_address=BAD_GUY)


@pytest.mark.parametrize("renounced_roles", ROLES_COMBINATIONS)
@pytest.mark.usefixtures("sudo_user")
@pytest.mark.asyncio
async def test_renounce_role(acl, renounced_roles):
    renounced_role_value = sum([r.value for r in renounced_roles])
    tx = await acl.renounce_role(renounced_role_value, ACL_USER).invoke(caller_address=ACL_USER)

    assert_event_emitted(tx, acl.contract_address, "RoleRevoked", [renounced_role_value, ACL_USER])

    # Check role
    updated_role = (await acl.get_role(ACL_USER).invoke()).result.ufelt
    expected_role = SUDO_USER & (~renounced_role_value)
    assert updated_role == expected_role

    # Check roles remaining
    updated_role_list = [i for i in Roles if i not in renounced_roles]
    for r in Roles:
        role_value = r.value

        # Check `has_role`
        has_role = (await acl.has_role(role_value, ACL_USER).invoke()).result.bool

        # Check getter
        role_name = r.name.lower()
        getter: Callable = acl.get_contract_function(f"can_{role_name}")
        can_perform_role = (await getter(ACL_USER).invoke()).result.bool

        if r in updated_role_list:
            assert has_role == can_perform_role == TRUE
            await acl.assert_has_role(role_value).invoke(caller_address=ACL_USER)
        else:
            assert has_role == can_perform_role == FALSE
            with pytest.raises(
                StarkException,
                match=f"AccessControl: caller is missing role {role_value}",
            ):
                await acl.assert_has_role(role_value).invoke(caller_address=ACL_USER)
