%lang starknet

from starkware.cairo.common.bool import TRUE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_le
from starkware.cairo.common.math_cmp import is_le
from starkware.cairo.common.uint256 import Uint256

from contracts.shared.interfaces import IERC20
from contracts.shared.wad_ray import WadRay

#
# Constants
#

# Maximum tax that can be set by an authorized address (ray)
const MAX_TAX = 5 * 10 ** 25

#
# Events
#

@event
func TaxUpdated(prev_tax, new_tax):
end

@event
func TaxCollectorUpdated(prev_tax_collector, new_tax_collector):
end

@event
func TaxLevied(tax):
end

#
# Storage
#

# Admin fee charged on yield from underlying - ray
@storage_var
func gate_tax_storage() -> (ray):
end

# Address to send admin fees to
@storage_var
func gate_tax_collector_storage() -> (address):
end

namespace GateTax:
    func initializer{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        tax, tax_collector_address
    ):
        set_tax(tax)
        set_tax_collector(tax_collector_address)
        return ()
    end

    #
    # Getters
    #

    func get_tax{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (ray):
        return gate_tax_storage.read()
    end

    func get_tax_collector{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}() -> (
        address
    ):
        return gate_tax_collector_storage.read()
    end

    #
    # Setters
    #

    func set_tax{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(tax):
        # Check that tax is lower than MAX_TAX
        with_attr error_message("Gate: Maximum tax exceeded"):
            assert_le(tax, MAX_TAX)
        end

        let (prev_tax) = gate_tax_storage.read()
        gate_tax_storage.write(tax)

        TaxUpdated.emit(prev_tax, tax)
        return ()
    end

    # Update the tax collector address
    func set_tax_collector{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        address
    ):
        let (prev_tax_collector) = gate_tax_collector_storage.read()
        gate_tax_collector_storage.write(address)

        TaxCollectorUpdated.emit(prev_tax_collector, address)
        return ()
    end

    #
    # Core
    #

    # Charge the tax and transfer to the tax collector
    func levy{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        asset_address, gate_address, last_updated_balance_wad
    ):
        alloc_locals

        # Get tax
        let (tax_rate) = gate_tax_storage.read()

        # Early return if tax is 0
        if tax_rate == 0:
            return ()
        end

        let (latest_uint : Uint256) = IERC20.balanceOf(
            contract_address=asset_address, account=gate_address
        )
        let (latest_wad) = WadRay.from_uint(latest_uint)

        # Assumption: Balance cannot decrease without any user action
        let (unincremented) = is_le(latest_wad, last_updated_balance_wad)
        if unincremented == TRUE:
            return ()
        end

        # `rmul` on a wad and a ray returns a wad
        let (chargeable_wad) = WadRay.rmul(latest_wad - last_updated_balance_wad, tax_rate)
        let (chargeable_uint256 : Uint256) = WadRay.to_uint(chargeable_wad)

        # Transfer fees
        let (tax_collector) = gate_tax_collector_storage.read()
        IERC20.transfer(
            contract_address=asset_address, recipient=tax_collector, amount=chargeable_uint256
        )

        # Events
        TaxLevied.emit(chargeable_wad)

        return ()
    end
end
