import pytest

from tests.utils import str_to_felt, to_uint


@pytest.mark.asyncio
async def test_initialization(usda):
    assert (await usda.name().execute()).result.name == str_to_felt("USDa")
    assert (await usda.symbol().execute()).result.symbol == str_to_felt("USDa")
    assert (await usda.decimals().execute()).result.decimals == 18
    assert (await usda.totalSupply().execute()).result.totalSupply == to_uint(0)
