use opus::types::{DistributionInfo, Health, HealthTrait, Provision, Request, Trove, YangBalance};
use starknet::storage_access::StorePacking;
use wadray::Wad;

#[test]
fn test_display_and_debug() {
    let h = Health { threshold: 1_u128.into(), ltv: 2_u128.into(), value: 3_u128.into(), debt: 4_u128.into() };
    let expected = "Health { threshold: 1, ltv: 2, value: 3, debt: 4 }";
    assert_eq!(format!("{}", h), expected.clone(), "Health display");
    assert_eq!(format!("{:?}", h), expected.clone(), "Health debug");

    let y = YangBalance { yang_id: 123, amount: 456_u128.into() };
    let expected = "YangBalance { yang_id: 123, amount: 456 }";
    assert_eq!(format!("{}", y), expected.clone(), "YangBalance display");
    assert_eq!(format!("{:?}", y), expected.clone(), "YangBalance debug");

    let t = Trove { charge_from: 123, last_rate_era: 456, debt: 789_u128.into() };
    let expected = "Trove { charge_from: 123, last_rate_era: 456, debt: 789 }";
    assert_eq!(format!("{}", t), expected.clone(), "Trove display");
    assert_eq!(format!("{:?}", t), expected.clone(), "Trove debug");

    let d = DistributionInfo { asset_amt_per_share: 123, error: 456 };
    let expected = "DistributionInfo { asset_amt_per_share: 123, error: 456 }";
    assert_eq!(format!("{}", d), expected.clone(), "DistributionInfo display");
    assert_eq!(format!("{:?}", d), expected.clone(), "DistributionInfo debug");

    let p = Provision { epoch: 123, shares: 456_u128.into() };
    let expected = "Provision { epoch: 123, shares: 456 }";
    assert_eq!(format!("{}", p), expected.clone(), "Provision display");
    assert_eq!(format!("{:?}", p), expected.clone(), "Provision debug");

    let r = Request { timestamp: 123, timelock: 456, is_valid: true };
    let expected = "Request { timestamp: 123, timelock: 456, is_valid: true }";
    assert_eq!(format!("{}", r), expected.clone(), "Provision display");
    assert_eq!(format!("{:?}", r), expected.clone(), "Provision debug");
}

#[test]
fn test_is_healthy() {
    let h = Health { threshold: 1_u128.into(), ltv: 0_u128.into(), value: 1_u128.into(), debt: 0_u128.into() };
    assert(h.is_healthy(), 'is_healthy #1');

    let h = Health { threshold: 1_u128.into(), ltv: 1_u128.into(), value: 1_u128.into(), debt: 1_u128.into() };
    assert(h.is_healthy(), 'is_healthy #2');

    let h = Health { threshold: 1_u128.into(), ltv: 2_u128.into(), value: 1_u128.into(), debt: 2_u128.into() };
    assert(!h.is_healthy(), 'is_healthy #3');
}

#[test]
fn test_trove_packing() {
    let charge_from: u64 = 0x8000040000000000;
    let last_rate_era: u64 = 0xea8888888888888;
    let debt: Wad = 0xffffffffffffffffffffffff_u128.into();
    let trove = Trove { charge_from, last_rate_era, debt };
    let unpacked: Trove = StorePacking::unpack(StorePacking::pack(trove));
    assert_eq!(trove, unpacked, "trove packing failed");
}

#[test]
fn test_distribution_info_packing() {
    // using only 127 bits
    let asset_amt_per_share: u128 = 0x7ffffffffffffffffffffffffffffffd;
    // using only 123 bits
    let error: u128 = 0x7fffffffffffffffffffffffffffff0;
    let distribution_info = DistributionInfo { asset_amt_per_share, error };
    let unpacked: DistributionInfo = StorePacking::unpack(StorePacking::pack(distribution_info));
    assert_eq!(distribution_info, unpacked, "distribution_info 1 packing failed");

    // error should be capped to 2**123-1
    let max_error: u128 = 0x7ffffffffffffffffffffffffffffff;
    let too_big_error: u128 = max_error + 1;

    let distribution_info = DistributionInfo { asset_amt_per_share, error: too_big_error };
    let unpacked: DistributionInfo = StorePacking::unpack(StorePacking::pack(distribution_info));
    assert_eq!(
        distribution_info.asset_amt_per_share,
        unpacked.asset_amt_per_share,
        "distribution_info 2 asset_amt_per_share packing failed",
    );
    assert_eq!(unpacked.error, max_error, "distribution_info 2 error packing failed");
}

#[test]
fn test_provision_packing() {
    let epoch: u32 = 0x80004000;
    let shares: Wad = 0xffffffffffffffffffffffff_u128.into();
    let provision = Provision { epoch, shares };
    let unpacked: Provision = StorePacking::unpack(StorePacking::pack(provision));
    assert_eq!(provision, unpacked, "provision epoch packing failed");
}

#[test]
fn test_request_packing() {
    let timestamp: u64 = 0x8000040000000000;
    let timelock: u64 = 0xea8888888888888;
    let is_valid = true;
    let request = Request { timestamp, timelock, is_valid };
    let unpacked: Request = StorePacking::unpack(StorePacking::pack(request));
    assert_eq!(request, unpacked, "request packing failed");
}
