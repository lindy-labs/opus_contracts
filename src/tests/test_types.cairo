use opus::types::{
    DistributionInfo, ExceptionalYangRedistribution, Health, Provision, Request, Trove, YangBalance, YangRedistribution
};
use wadray::{Wad, Ray};

#[test]
fn test_display_and_debug() {
    let h = Health { threshold: 1_u128.into(), ltv: 2_u128.into(), value: 3_u128.into(), debt: 4_u128.into() };
    assert_eq!(format!("{}", h), "Health(threshold: 1, ltv: 2, value: 3, debt: 4)", "Health display");
    assert_eq!(format!("{:?}", h), "Health(threshold: 1, ltv: 2, value: 3, debt: 4)", "Health debug");

    let y = YangBalance { yang_id: 123, amount: 456_u128.into() };
    assert_eq!(format!("{}", y), "YangBalance(yang_id: 123, amount: 456)", "YangBalance display");
    assert_eq!(format!("{:?}", y), "YangBalance(yang_id: 123, amount: 456)", "YangBalance debug");

    let t = Trove { charge_from: 123, last_rate_era: 456, debt: 789_u128.into() };
    assert_eq!(format!("{}", t), "Trove(charge_from: 123, last_rate_era: 456, debt: 789)", "Trove display");
    assert_eq!(format!("{:?}", t), "Trove(charge_from: 123, last_rate_era: 456, debt: 789)", "Trove debug");

    let y = YangRedistribution { unit_debt: 123_u128.into(), error: 456_u128.into(), exception: true };
    assert_eq!(
        format!("{}", y),
        "YangRedistribution(unit_debt: 123, error: 456, exception: true)",
        "YangRedistribution display"
    );
    assert_eq!(
        format!("{:?}", y),
        "YangRedistribution(unit_debt: 123, error: 456, exception: true)",
        "YangRedistribution debug"
    );

    let e = ExceptionalYangRedistribution { unit_debt: 123_u128.into(), unit_yang: 456_u128.into() };
    assert_eq!(
        format!("{}", e),
        "ExceptionalYangRedistribution(unit_debt: 123, unit_yang: 456)",
        "ExceptionalYangRedistribution display"
    );
    assert_eq!(
        format!("{:?}", e),
        "ExceptionalYangRedistribution(unit_debt: 123, unit_yang: 456)",
        "ExceptionalYangRedistribution debug"
    );

    let d = DistributionInfo { asset_amt_per_share: 123, error: 456 };
    assert_eq!(format!("{}", d), "DistributionInfo(asset_amt_per_share: 123, error: 456)", "DistributionInfo display");
    assert_eq!(format!("{:?}", d), "DistributionInfo(asset_amt_per_share: 123, error: 456)", "DistributionInfo debug");

    let p = Provision { epoch: 123, shares: 456_u128.into() };
    assert_eq!(format!("{}", p), "Provision(epoch: 123, shares: 456)", "Provision display");
    assert_eq!(format!("{:?}", p), "Provision(epoch: 123, shares: 456)", "Provision debug");

    let r = Request { timestamp: 123, timelock: 456, has_removed: true };
    assert_eq!(format!("{}", r), "Request(timestamp: 123, timelock: 456, has_removed: true)", "Provision display");
    assert_eq!(format!("{:?}", r), "Request(timestamp: 123, timelock: 456, has_removed: true)", "Provision debug");
}
