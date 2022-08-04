%lang starknet

from starkware.cairo.common.bool import TRUE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_le, assert_not_zero
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
func TaxUpdated(prev_tax_ray, new_tax_ray):
end

@event
func TaxCollectorUpdated(prev_tax_collector, new_tax_collector):
end

@event
func TaxLevied(tax_ray):
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
        tax_ray, tax_collector_address
    ):
        set_tax(tax_ray)
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

    func set_tax{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(tax_ray):
        # Check that tax is lower than MAX_TAX
        with_attr error_message("Gate: Maximum tax exceeded"):
            assert_le(tax_ray, MAX_TAX)
        end

        let (prev_tax_ray) = gate_tax_storage.read()
        gate_tax_storage.write(tax_ray)

        TaxUpdated.emit(prev_tax_ray, tax_ray)
        return ()
    end

    # Update the tax collector address
    func set_tax_collector{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        address
    ):
        with_attr error_message("Gate: Invalid tax collector address"):
            assert_not_zero(address)
        end

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
        asset_address, taxable_wad
    ):
        alloc_locals

        # Get tax
        let (tax_ray) = gate_tax_storage.read()

        # Early return if tax is 0
        if tax_ray == 0:
            return ()
        end

        # Calculate taxable amount
        # `rmul` on a wad and a ray returns a wad
        let (chargeable_wad) = WadRay.rmul(taxable_wad, tax_ray)

        # Transfer fees
        let (tax_collector) = gate_tax_collector_storage.read()
        let (chargeable_uint256 : Uint256) = WadRay.to_uint(chargeable_wad)
        let (success) = IERC20.transfer(
            contract_address=asset_address, recipient=tax_collector, amount=chargeable_uint256
        )

        # Events
        if success == TRUE:
            TaxLevied.emit(chargeable_wad)

            tempvar syscall_ptr = syscall_ptr
            tempvar range_check_ptr = range_check_ptr
        else:
            tempvar syscall_ptr = syscall_ptr
            tempvar range_check_ptr = range_check_ptr
        end

        return ()
    end
end
