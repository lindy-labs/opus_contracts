import asyncio
from collections import namedtuple
import os

from utils import Signer

import pytest
from starkware.starknet.services.api.contract_definition import ContractDefinition
from starkware.starknet.compiler.compile import compile_starknet_files
from starkware.starknet.testing.starknet import Starknet, StarknetContract


MRACParameters = namedtuple(
    "MRACParameters", ["u", "r", "y", "theta", "theta_underline", "theta_bar", "gamma", "T"]
)

SCALE = 10 ** 18

DEFAULT_MRAC_PARAMETERS = MRACParameters(*[int(i * SCALE) for i in (0, 1.5, 0, 0, 0, 2, 0.1, 1)])


def here() -> str:
    return os.path.abspath(os.path.dirname(__file__))


def contract_path(rel_contract_path: str) -> str:
    return os.path.join(here(), "..", "contracts", rel_contract_path)


def compile_contract(rel_contract_path: str) -> ContractDefinition:
    contract_src = contract_path(rel_contract_path)
    return compile_starknet_files(
        [contract_src],
        debug_info=True,
        disable_hint_validation=True,
        cairo_path=[os.path.join(here(), "..", "contracts", "lib")],
    )


@pytest.fixture(scope="session")
def event_loop():
    return asyncio.new_event_loop()


@pytest.fixture(scope="session")
async def starknet() -> Starknet:
    starknet = await Starknet.empty()
    return starknet


@pytest.fixture(scope="session")
def users(starknet):
    """
    A factory fixture that creates users.

    The returned factory function takes a single string as an argument,
    which it uses as an identifier of the user and also to generates their
    private key. The fixture is session-scoped and has an internal cache,
    so the same argument (user name) will return the same result.

    The return value is a tuple of (signer: Signer, contract: StarknetContract)
    useful for sending signed transactions, assigning ownership, etc.
    """
    account_contract = compile_contract("lib/openzeppelin/account/Account.cairo")
    cache = {}

    async def get_or_create_user(name):
        hit = cache.get(name)
        if hit:
            return hit

        signer = Signer(abs(hash(name)))
        account = await starknet.deploy(
            contract_def=account_contract, constructor_calldata=[signer.public_key]
        )

        user = (signer, account)
        cache[name] = user
        return user

    return get_or_create_user


@pytest.fixture
async def usda(starknet, users) -> StarknetContract:
    contract = compile_contract("USDa/USDa.cairo")
    _, owner = await users("owner")
    return await starknet.deploy(
        contract_def=contract, constructor_calldata=[owner.contract_address]
    )


@pytest.fixture
async def mrac_controller(starknet) -> StarknetContract:
    contract = compile_contract("MRAC/controller.cairo")
    return await starknet.deploy(
        contract_def=contract, constructor_calldata=[*DEFAULT_MRAC_PARAMETERS]
    )
