import asyncio
import os

from utils import str_to_felt, to_uint

import pytest
from starkware.starknet.services.api.contract_definition import ContractDefinition
from starkware.starknet.compiler.compile import compile_starknet_files
from starkware.starknet.testing.starknet import Starknet, StarknetContract


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


@pytest.fixture
async def usda(starknet) -> StarknetContract:
    contract = compile_contract("USDa/USDa.cairo")
    return await starknet.deploy(contract_def=contract, constructor_calldata=[1])
