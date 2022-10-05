%lang starknet

from contracts.lib.aliases import address
// these imported public functions are part of the contract's interface
from contracts.lib.accesscontrol.accesscontrol_external import (
    change_admin,
    get_admin,
    get_roles,
    grant_role,
    has_role,
    renounce_role,
    revoke_role,
)
from contracts.lib.accesscontrol.library import AccessControl
from contracts.lib.interfaces import IEmpiricOracle

@constructor
func constructor{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(admin: address) {
    AccessControl.initializer(admin);

    return ();
}

@external
func update_yang_prices{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    arguments
) {
    let (value, decimals, last_updated_ts, num_sources_agg) = IEmpiricOracle.get_value(
        'eth/usd', 'MEDIAN'
    );

    return ();
}

// YAGI?
