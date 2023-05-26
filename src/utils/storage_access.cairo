use option::OptionTrait;
use starknet::{StorageAccess, StorageBaseAddress, SyscallResult};
use starknet::storage_access::storage_address_from_base_and_offset;
use starknet::syscalls::{storage_read_syscall, storage_write_syscall};
use traits::{Into, TryInto};

use aura::utils::wadray::{Ray, Wad};

type U128Tuple = (u128, u128);

impl U128TupleStorageAccess of StorageAccess<U128Tuple> {
    #[inline(always)]
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<U128Tuple> {
        let first_val = storage_read_syscall(
            address_domain, storage_address_from_base_and_offset(base, 0_u8)
        )?
            .try_into()
            .unwrap();
        let second_val = storage_read_syscall(
            address_domain, storage_address_from_base_and_offset(base, 1_u8)
        )?
            .try_into()
            .unwrap();

        Result::Ok((first_val, second_val))
    }

    #[inline(always)]
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

    #[inline(always)]
    fn read_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8
    ) -> SyscallResult<U128Tuple> {
        Result::Ok(
            (
                StorageAccess::read_at_offset_internal(address_domain, base, offset)?,
                StorageAccess::read_at_offset_internal(address_domain, base, offset + 1)?
            )
        )
    }

    #[inline(always)]
    fn write_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8, value: U128Tuple
    ) -> SyscallResult<()> {
        let (v0, v1) = value;
        StorageAccess::write_at_offset_internal(address_domain, base, offset, v0)?;
        StorageAccess::write_at_offset_internal(
            address_domain, base, offset + StorageAccess::<u128>::size_internal(v0), v1
        )
    }

    #[inline(always)]
    fn size_internal(value: U128Tuple) -> u8 {
        let (v0, v1) = value;
        StorageAccess::size_internal(v0) + StorageAccess::size_internal(v1)
    }
}

type WadTuple = (Wad, Wad);

impl WadTupleStorageAccess of StorageAccess<WadTuple> {
    #[inline(always)]
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<WadTuple> {
        let (first_val, second_val) = U128TupleStorageAccess::read(address_domain, base)?;
        Result::Ok((Wad { val: first_val }, Wad { val: second_val }))
    }

    #[inline(always)]
    fn write(
        address_domain: u32, base: StorageBaseAddress, value: WadTuple
    ) -> SyscallResult::<()> {
        let (first_wad, second_wad) = value;
        U128TupleStorageAccess::write(address_domain, base, (first_wad.val, second_wad.val))
    }

    #[inline(always)]
    fn read_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8
    ) -> SyscallResult<WadTuple> {
        let (v0, v1) = U128TupleStorageAccess::read_at_offset_internal(
            address_domain, base, offset
        )?;
        Result::Ok((Wad { val: v0 }, Wad { val: v1 }))
    }

    #[inline(always)]
    fn write_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8, value: WadTuple
    ) -> SyscallResult<()> {
        let (w0, w1) = value;
        U128TupleStorageAccess::write_at_offset_internal(
            address_domain, base, offset, (w0.val, w1.val)
        )
    }

    #[inline(always)]
    fn size_internal(value: WadTuple) -> u8 {
        let (w0, w1) = value;
        U128TupleStorageAccess::size_internal((w0.val, w1.val))
    }
}

type RayTuple = (Ray, Ray);

impl RayTupleStorageAccess of StorageAccess<RayTuple> {
    #[inline(always)]
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<RayTuple> {
        let (first_val, second_val) = U128TupleStorageAccess::read(address_domain, base)?;
        Result::Ok((Ray { val: first_val }, Ray { val: second_val }))
    }

    #[inline(always)]
    fn write(
        address_domain: u32, base: StorageBaseAddress, value: RayTuple
    ) -> SyscallResult::<()> {
        let (first_ray, second_ray) = value;
        U128TupleStorageAccess::write(address_domain, base, (first_ray.val, second_ray.val))
    }

    #[inline(always)]
    fn read_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8
    ) -> SyscallResult<RayTuple> {
        let (v0, v1) = U128TupleStorageAccess::read_at_offset_internal(
            address_domain, base, offset
        )?;
        Result::Ok((Ray { val: v0 }, Ray { val: v1 }))
    }

    #[inline(always)]
    fn write_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8, value: RayTuple
    ) -> SyscallResult<()> {
        let (r0, r1) = value;
        U128TupleStorageAccess::write_at_offset_internal(
            address_domain, base, offset, (r0.val, r1.val)
        )
    }

    #[inline(always)]
    fn size_internal(value: RayTuple) -> u8 {
        let (r0, r1) = value;
        U128TupleStorageAccess::size_internal((r0.val, r1.val))
    }
}
