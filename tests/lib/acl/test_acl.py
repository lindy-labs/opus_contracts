from itertools import combinations
from typing import Tuple

import pytest
from starkware.starknet.testing.starknet import StarknetContract
from starkware.starkware_utils.error_handling import StarkException

from tests.utils import BAD_GUY, FALSE, TRUE, assert_event_emitted, compile_contract, str_to_felt

ACL_OWNER = str_to_felt("acl owner")
NEW_ACL_OWNER = str_to_felt("new acl owner")
ACL_USER = str_to_felt("acl user")

ROLES = {
    "EXECUTE": 1,
    "WRITE": 2,
    "READ": 4,
}
SUDO_USER = sum(ROLES.values())

ROLES_COMBINATIONS = []

for i in range(1, len(ROLES) + 1):
    for j in combinations(ROLES, i):
        ROLES_COMBINATIONS.append(j)


def get_role_value(roles: Tuple[str]) -> int:
    """Takes in a list of string values representing the role name and returns the flag value"""
    return sum([ROLES[i] for i in roles])


@pytest.fixture
async def acl(starknet_session):
    contract = compile_contract("tests/lib/acl/acl_contract.cairo")
    return await starknet_session.deploy(contract_class=contract, constructor_calldata=[ACL_OWNER])


@pytest.fixture
async def sudo_user(acl):
    # Grant user all permissions
    await acl.grant_role(SUDO_USER, ACL_USER).invoke(caller_address=ACL_OWNER)


@pytest.fixture
async def acl_change_admin(acl):
    tx = await acl.change_admin(NEW_ACL_OWNER).invoke(caller_address=ACL_OWNER)
    return tx


@pytest.fixture
async def acl_new_admin(acl, acl_change_admin):
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
    assert_event_emitted(acl_change_admin, acl.contract_address, "AdminChanged", [ACL_OWNER, NEW_ACL_OWNER])

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
    given_role_value = get_role_value(given_roles)

    tx = await acl.grant_role(given_role_value, ACL_USER).invoke(caller_address=admin)

    # Check event
    assert_event_emitted(tx, acl.contract_address, "RoleGranted", [given_role_value, ACL_USER])

    # Check role
    role = (await acl.get_role(ACL_USER).invoke()).result.ufelt
    assert role == given_role_value

    # Check roles granted
    for r in ROLES:
        role_value = ROLES[r]
        has_role = (await acl.has_role(role_value, ACL_USER).invoke()).result.bool
        if r in given_roles:
            assert has_role == TRUE
        else:
            assert has_role == FALSE

    # Compute value of revoked role
    revoked_role_value = get_role_value(revoked_roles)

    tx = await acl.revoke_role(revoked_role_value, ACL_USER).invoke(caller_address=admin)

    # Check event
    assert_event_emitted(tx, acl.contract_address, "RoleRevoked", [revoked_role_value, ACL_USER])

    # Check role
    updated_role = (await acl.get_role(ACL_USER).invoke()).result.ufelt
    expected_role = given_role_value & (~revoked_role_value)
    assert updated_role == expected_role

    # Check roles remaining
    updated_role_list = [i for i in given_roles if i not in revoked_roles]
    for r in ROLES:
        role_value = ROLES[r]
        has_role = (await acl.has_role(role_value, ACL_USER).invoke()).result.bool
        if r in updated_role_list:
            assert has_role == TRUE
            await acl.assert_has_role(role_value).invoke(caller_address=ACL_USER)
        else:
            assert has_role == FALSE
            with pytest.raises(StarkException, match=f"AccessControl: caller is missing role {role_value}"):
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
    renounced_role_value = get_role_value(renounced_roles)
    tx = await acl.renounce_role(renounced_role_value, ACL_USER).invoke(caller_address=ACL_USER)

    assert_event_emitted(tx, acl.contract_address, "RoleRevoked", [renounced_role_value, ACL_USER])

    # Check role
    updated_role = (await acl.get_role(ACL_USER).invoke()).result.ufelt
    expected_role = SUDO_USER & (~renounced_role_value)
    assert updated_role == expected_role

    # Check roles remaining
    given_roles = list(ROLES.keys())
    updated_role_list = [i for i in given_roles if i not in renounced_roles]
    for r in ROLES:
        role_value = ROLES[r]
        has_role = (await acl.has_role(role_value, ACL_USER).invoke()).result.bool
        if r in updated_role_list:
            assert has_role == TRUE
            await acl.assert_has_role(role_value).invoke(caller_address=ACL_USER)
        else:
            assert has_role == FALSE
            with pytest.raises(StarkException, match=f"AccessControl: caller is missing role {role_value}"):
                await acl.assert_has_role(role_value).invoke(caller_address=ACL_USER)
