%lang starknet

from contracts.shared.convert import pack_felt

@view
func test_pack_felt{range_check_ptr}(a, b) -> (packed):
    return pack_felt(a, b)
end
