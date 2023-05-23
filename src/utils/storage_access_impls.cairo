use option::OptionTrait;
use starknet::{
    ContractAddress, Felt252TryIntoContractAddress, StorageAccess, StorageBaseAddress, SyscallResult
};
use starknet::storage_access::{
    storage_address_from_base_and_offset, storage_base_address_from_felt252
};
use starknet::syscalls::{storage_read_syscall, storage_write_syscall};
use traits::{Into, TryInto};

use aura::utils::types::{Trove, YangRedistribution};
use aura::utils::types::Pragma::{PriceValidityThresholds, YangSettings};
use aura::utils::wadray::{Ray, Wad};

// Storage Access
impl WadStorageAccess of StorageAccess<Wad> {
    fn write(address_domain: u32, base: StorageBaseAddress, value: Wad) -> SyscallResult::<()> {
        StorageAccess::write(address_domain, base, value.val)
    }

    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<Wad> {
        Result::Ok(
            Wad {
                val: storage_read_syscall(
                    address_domain, storage_address_from_base_and_offset(base, 0_u8)
                )?.try_into().unwrap(),
            }
        )
    }
}

impl RayStorageAccess of StorageAccess<Ray> {
    fn write(address_domain: u32, base: StorageBaseAddress, value: Ray) -> SyscallResult::<()> {
        StorageAccess::write(address_domain, base, value.val)
    }

    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<Ray> {
        Result::Ok(
            Ray {
                val: storage_read_syscall(
                    address_domain, storage_address_from_base_and_offset(base, 0_u8)
                )?.try_into().unwrap(),
            }
        )
    }
}

impl TroveStorageAccess of StorageAccess<Trove> {
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<Trove> {
        Result::Ok(
            Trove {
                charge_from: storage_read_syscall(
                    address_domain, storage_address_from_base_and_offset(base, 0_u8)
                )?.try_into().unwrap(),
                debt: Wad {
                    val: storage_read_syscall(
                        address_domain, storage_address_from_base_and_offset(base, 1_u8)
                    )?.try_into().unwrap()
                },
                last_rate_era: storage_read_syscall(
                    address_domain, storage_address_from_base_and_offset(base, 2_u8)
                )?.try_into().unwrap(),
            }
        )
    }

    fn write(address_domain: u32, base: StorageBaseAddress, value: Trove) -> SyscallResult::<()> {
        storage_write_syscall(
            address_domain,
            storage_address_from_base_and_offset(base, 0_u8),
            value.charge_from.into()
        )?;
        storage_write_syscall(
            address_domain, storage_address_from_base_and_offset(base, 1_u8), value.debt.val.into()
        )?;
        storage_write_syscall(
            address_domain,
            storage_address_from_base_and_offset(base, 2_u8),
            value.last_rate_era.into()
        )
    }
}

type U128Tuple = (u128, u128);

impl U128TupleStorageAccess of StorageAccess<U128Tuple> {
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<U128Tuple> {
        let first_val = storage_read_syscall(
            address_domain, storage_address_from_base_and_offset(base, 0_u8)
        )?.try_into().unwrap();
        let second_val = storage_read_syscall(
            address_domain, storage_address_from_base_and_offset(base, 1_u8)
        )?.try_into().unwrap();

        Result::Ok((first_val, second_val))
    }

    fn write(
        address_domain: u32, base: StorageBaseAddress, value: U128Tuple
    ) -> SyscallResult::<()> {
        let (first_val, second_val) = value;

        storage_write_syscall(
            address_domain, storage_address_from_base_and_offset(base, 0_u8), first_val.into()
        )?;
        storage_write_syscall(
            address_domain, storage_address_from_base_and_offset(base, 1_u8), second_val.into()
        )
    }
}

type WadTuple = (Wad, Wad);

impl WadTupleStorageAccess of StorageAccess<WadTuple> {
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<WadTuple> {
        let (first_val, second_val) = U128TupleStorageAccess::read(address_domain, base)?;
        Result::Ok((Wad { val: first_val }, Wad { val: second_val }))
    }

    fn write(
        address_domain: u32, base: StorageBaseAddress, value: WadTuple
    ) -> SyscallResult::<()> {
        let (first_wad, second_wad) = value;
        U128TupleStorageAccess::write(address_domain, base, (first_wad.val, second_wad.val))
    }
}

type RayTuple = (Ray, Ray);

impl RayTupleStorageAccess of StorageAccess<RayTuple> {
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<RayTuple> {
        let (first_val, second_val) = U128TupleStorageAccess::read(address_domain, base)?;
        Result::Ok((Ray { val: first_val }, Ray { val: second_val }))
    }

    fn write(
        address_domain: u32, base: StorageBaseAddress, value: RayTuple
    ) -> SyscallResult::<()> {
        let (first_ray, second_ray) = value;
        U128TupleStorageAccess::write(address_domain, base, (first_ray.val, second_ray.val))
    }
}

impl YangRedistributionStorageAccess of StorageAccess<YangRedistribution> {
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<YangRedistribution> {
        let (unit_debt, error) = WadTupleStorageAccess::read(address_domain, base)?;
        Result::Ok(YangRedistribution { unit_debt, error })
    }

    fn write(
        address_domain: u32, base: StorageBaseAddress, value: YangRedistribution
    ) -> SyscallResult::<()> {
        WadTupleStorageAccess::write(address_domain, base, (value.unit_debt, value.error))
    }
}

impl PriceValidityThresholdsStorageAccess of StorageAccess<PriceValidityThresholds> {
    fn read(
        address_domain: u32, base: StorageBaseAddress
    ) -> SyscallResult<PriceValidityThresholds> {
        Result::Ok(
            PriceValidityThresholds {
                freshness: storage_read_syscall(
                    address_domain, storage_address_from_base_and_offset(base, 0)
                )?.try_into().unwrap(),
                sources: storage_read_syscall(
                    address_domain, storage_address_from_base_and_offset(base, 1)
                )?.try_into().unwrap()
            }
        )
    }

    fn write(
        address_domain: u32, base: StorageBaseAddress, value: PriceValidityThresholds
    ) -> SyscallResult<()> {
        storage_write_syscall(
            address_domain, storage_address_from_base_and_offset(base, 0_u8), value.freshness.into()
        )?;
        storage_write_syscall(
            address_domain, storage_address_from_base_and_offset(base, 1_u8), value.sources.into()
        )
    }
}

impl YangSettingsStorageAccess of StorageAccess<YangSettings> {
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult<YangSettings> {
        let pair_id: u256 = StorageAccess::<u256>::read(address_domain, base)?;
        let next: felt252 = storage_address_from_base_and_offset(base, 2).into();
        let yang: ContractAddress = StorageAccess::<ContractAddress>::read(
            address_domain, storage_base_address_from_felt252(next)
        )?;
        Result::Ok(YangSettings { pair_id, yang })
    }

    fn write(
        address_domain: u32, base: StorageBaseAddress, value: YangSettings
    ) -> SyscallResult<()> {
        StorageAccess::<u256>::write(address_domain, base, value.pair_id);
        let next: felt252 = storage_address_from_base_and_offset(base, 2).into();
        StorageAccess::<ContractAddress>::write(
            address_domain, storage_base_address_from_felt252(next), value.yang
        )
    }
}
