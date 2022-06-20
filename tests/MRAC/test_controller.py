from typing import List, NamedTuple

import pytest

from conftest import DEFAULT_MRAC_PARAMETERS, SCALE, MRACParameters

Int125 = NamedTuple("Int125", [("value", int)])


def to_pyparams(cairo_params: List[Int125]) -> MRACParameters:
    """
    Converts mrac.cairo Parameters (a struct of Int125)
    to the namedtuple MRACParameters used in Python code.
    """
    return MRACParameters(*[p.value for p in cairo_params])


@pytest.mark.asyncio
async def test_constructor(mrac_controller):
    tx = mrac_controller.deploy_execution_info
    assert len(tx.raw_events) == 1
    event = tx.raw_events[0]
    assert event.data == list(DEFAULT_MRAC_PARAMETERS)

    tx = await mrac_controller.get_parameters().invoke()
    init_params = to_pyparams(tx.result.parameters)
    assert init_params == DEFAULT_MRAC_PARAMETERS


@pytest.mark.asyncio
async def test_adjust_parameters(mrac_controller):
    p = 42 * SCALE
    params = [p, p, p, p, p]
    tx = await mrac_controller.adjust_parameters(*params).invoke()

    assert len(tx.raw_events) == 1
    event = tx.raw_events[0]
    adjusted = MRACParameters(*event.data)
    assert adjusted.r == p
    assert adjusted.theta_underline == p
    assert adjusted.theta_bar == p
    assert adjusted.gamma == p
    assert adjusted.T == p

    tx = await mrac_controller.get_parameters().invoke()
    params = tx.result.parameters
    params = to_pyparams(params)

    assert params.r == p
    assert params.theta_underline == p
    assert params.theta_bar == p
    assert params.gamma == p
    assert params.T == p


# TODO: test calculate_new_parameters
