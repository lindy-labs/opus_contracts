import pytest

from utils import str_to_felt, to_uint


@pytest.mark.asyncio
async def test_initialization(usda):
    assert (await usda.name().invoke()).result.name == str_to_felt("USDa")
    assert (await usda.symbol().invoke()).result.symbol == str_to_felt("USDa")
    assert (await usda.decimals().invoke()).result.decimals == 18
    assert (await usda.totalSupply().invoke()).result.totalSupply == to_uint(0)
