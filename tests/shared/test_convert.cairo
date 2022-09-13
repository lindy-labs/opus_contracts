%lang starknet

from contracts.shared.convert import pack_felt
from contracts.shared.aliases import packed

@view
func test_pack_felt{range_check_ptr}(a, b) -> (packed_felt: packed) {
    return (pack_felt(a, b),);
}
