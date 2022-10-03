%lang starknet

from starkware.cairo.common.bool import TRUE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.math import assert_le, assert_not_zero
from starkware.cairo.common.uint256 import Uint256

from contracts.shared.aliases import address, bool, ray, wad
from contracts.shared.interfaces import IERC20
from contracts.shared.wad_ray import WadRay

//
// Constants
//

// Maximum tax that can be set by an authorized address (ray)
const MAX_TAX = 5 * WadRay.RAY_PERCENT;  // 5%

//
// Events
//

@event
func TaxUpdated(prev_tax: ray, new_tax: ray) {
}

@event
func TaxCollectorUpdated(prev_tax_collector: address, new_tax_collector: address) {
}

@event
func TaxLevied(tax: wad) {
}

//
// Storage
//

// Admin fee charged on yield from underlying - ray
@storage_var
func gate_tax_storage() -> (tax: ray) {
}

// Address to send admin fees to
@storage_var
func gate_tax_collector_storage() -> (tax_collector: address) {
}

namespace GateTax {
    func initializer{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        tax: ray, tax_collector: address
    ) {
        set_tax(tax);
        set_tax_collector(tax_collector);
        return ();
    }

    //
    // Getters
    //

    func get_tax{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> ray {
        let (tax: ray) = gate_tax_storage.read();
        return tax;
    }

    func get_tax_collector{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        ) -> address {
        let (collector: address) = gate_tax_collector_storage.read();
        return collector;
    }

    //
    // Setters
    //

    func set_tax{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(tax: ray) {
        // Check that tax is lower than MAX_TAX
        with_attr error_message("Gate: Maximum tax exceeded") {
            assert_le(tax, MAX_TAX);
        }

        let (prev_tax: ray) = gate_tax_storage.read();
        gate_tax_storage.write(tax);

        TaxUpdated.emit(prev_tax, tax);
        return ();
    }

    // Update the tax collector address
    func set_tax_collector{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        new_collector: address
    ) {
        with_attr error_message("Gate: Invalid tax collector address") {
            assert_not_zero(new_collector);
        }

        let (prev_collector: address) = gate_tax_collector_storage.read();
        gate_tax_collector_storage.write(new_collector);

        TaxCollectorUpdated.emit(prev_collector, new_collector);
        return ();
    }

    //
    // Core
    //

    // Charge the tax and transfer to the tax collector
    func levy{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        asset: address, taxable: wad
    ) {
        alloc_locals;

        // Get tax
        let (tax: ray) = gate_tax_storage.read();

        // Early return if tax is 0
        if (tax == 0) {
            return ();
        }

        // Calculate taxable amount
        // `rmul` on a wad and a ray returns a wad
        let chargeable: wad = WadRay.rmul(taxable, tax);

        // Transfer fees
        let (tax_collector: address) = gate_tax_collector_storage.read();
        let (chargeable_uint256: Uint256) = WadRay.to_uint(chargeable);
        let (success: bool) = IERC20.transfer(
            contract_address=asset, recipient=tax_collector, amount=chargeable_uint256
        );

        // Events
        if (success == TRUE) {
            TaxLevied.emit(chargeable);

            tempvar syscall_ptr = syscall_ptr;
            tempvar range_check_ptr = range_check_ptr;
        } else {
            tempvar syscall_ptr = syscall_ptr;
            tempvar range_check_ptr = range_check_ptr;
        }

        return ();
    }
}
