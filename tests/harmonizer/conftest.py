import pytest
from starkware.starknet.services.api.contract_class import ContractClass
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.starknet import Starknet

from tests.harmonizer.constants import *  # noqa: F403
from tests.utils import compile_contract


@pytest.fixture
def allocator_contract() -> ContractClass:
    allocator_contract = compile_contract("contracts/harmonizer/allocator.cairo")
    return allocator_contract


@pytest.fixture
async def allocator(starknet: Starknet, allocator_contract) -> StarknetContract:
    allocator = await starknet.deploy(
        contract_class=allocator_contract,
        constructor_calldata=[
            len(INITIAL_RECIPIENTS),
            *INITIAL_RECIPIENTS,
            len(INITIAL_PERCENTAGES_RAY),
            *INITIAL_PERCENTAGES_RAY,
        ],
    )
    return allocator
