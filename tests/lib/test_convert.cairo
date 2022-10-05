%lang starknet

from contracts.lib.aliases import packed
from contracts.lib.convert import pack_felt

@view
func test_pack_felt{range_check_ptr}(a, b) -> (packed_felt: packed) {
    return (pack_felt(a, b),);
}
