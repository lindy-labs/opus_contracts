import pytest
from starkware.starknet.testing.starknet import Starknet, StarknetContract

from tests.utils import compile_contract


@pytest.fixture(scope="session")  # TODO: descope when PR#54 is merged and rebased
async def starknet() -> Starknet:
    starknet = await Starknet.empty()
    return starknet


@pytest.fixture
async def shrine(starknet, users) -> StarknetContract:
    shrine_owner = await users("shrine owner")
    shrine_contract = compile_contract("contracts/shrine/shrine.cairo")
    shrine = await starknet.deploy(contract_class=shrine_contract, constructor_calldata=[shrine_owner.address])
    return shrine


@pytest.fixture
async def abbot(starknet, shrine, users) -> StarknetContract:
    shrine_owner = await users("shrine owner")
    abbot_contract = compile_contract("contracts/abbot/abbot.cairo")
    abbot = await starknet.deploy(contract_class=abbot_contract, constructor_calldata=[shrine.contract_address])
    # authorize abbot in shrine
    await shrine_owner.send_tx(shrine.contract_address, "authorize", [abbot.contract_address])
    return abbot
