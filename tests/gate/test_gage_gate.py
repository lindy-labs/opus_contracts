import pytest

from tests.gate.constants import TAX
from tests.utils import TRUE, from_uint


@pytest.mark.asyncio
async def test_gate_setup(gate_gage_rebasing, users):
    gate = gate_gage_rebasing

    # Check system is live
    live = (await gate.get_live().invoke()).result.bool
    assert live == TRUE

    # Check Abbot address is authorized
    abbot = await users("abbot")
    authorized = (await gate.get_auth(abbot.address).invoke()).result.bool
    assert authorized == TRUE

    # Check tax
    tax = (await gate.get_tax().invoke()).result.ray
    assert tax == TAX

    # Check taxman
    taxman = await users("taxman")
    taxman_address = (await gate.get_taxman_address().invoke()).result.address
    assert taxman_address == taxman.address

    # Check initial values
    assert from_uint((await gate.totalSupply().invoke()).result.totalSupply) == 0
