import pytest
from starkware.starknet.testing.contract import StarknetContract

from tests.harmonizer.constants import *  # noqa: F403
from tests.utils import compile_contract


@pytest.fixture
async def beneficiary_registrar(starknet) -> StarknetContract:
    registrar_contract = compile_contract("contracts/harmonizer/beneficiary_registrar.cairo")
    registrar = await starknet.deploy(
        contract_class=registrar_contract,
        constructor_calldata=[
            BENEFICIARY_REGISTRAR_OWNER,
            len(INITIAL_BENEFICIARIES),
            *INITIAL_BENEFICIARIES,
            len(INITIAL_PERCENTAGES_RAY),
            *INITIAL_PERCENTAGES_RAY,
        ],
    )

    return registrar
