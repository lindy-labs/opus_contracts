from utils import compile_contract, as_address, str_to_felt, Addressable, Calldata, Call
from starkware.cairo.common.hash_state import compute_hash_on_elements
from starkware.crypto.signature.signature import private_to_stark_key, sign
from starkware.starknet.public.abi import get_selector_from_name
from starkware.starknet.services.api.contract_class import ContractClass
from starkware.starknet.testing.starknet import Starknet

# IDEA:
# create a context manager out of the account
# with acc.using(token_addr) as sender:
#     tx = await sender.mint(1000)


class Account:
    """
    Combines a signer and a deployed account contract into a single object
    to simplify sending TXs in tests.
    """

    compiled_acconut_contract: ContractClass = compile_contract("contracts/lib/openzeppelin/account/Account.cairo")

    def __init__(self, name):
        self.private_key = abs(hash(name))
        self.public_key = private_to_stark_key(self.private_key)
        self.nonce = 0
        self.contract = None

    @property
    def address(self) -> str:
        assert self.contract is not None, "Account contract was not deployed"
        return self.contract.contract_address

    async def deploy(self, starknet: Starknet):
        self.contract = await starknet.deploy(
            contract_class=Account.compiled_acconut_contract,
            constructor_calldata=[self.public_key],
        )

    async def send_tx(self, to: Addressable, selector: str, calldata: Calldata, max_fee=0):
        call_payload: Call = (to, selector, calldata)
        return await self.send_txs([call_payload], max_fee)

    async def send_txs(self, calls: list[Call], max_fee=0):
        calls_with_selector = [(as_address(call[0]), get_selector_from_name(call[1]), call[2]) for call in calls]
        call_array, calldata = from_call_to_call_array(calls)

        nonce = self.nonce
        self.nonce += 1

        message_hash = hash_multicall(self.address, calls_with_selector, nonce, max_fee)
        sig_r, sig_s = sign(message_hash, self.private_key)

        try:
            return await self.contract.__execute__(call_array, calldata, nonce).invoke(signature=[sig_r, sig_s])
        except:  # noqa: E722
            # when a TX throws, it's not accepted hence the
            # nonce doesn't get incremented in the account
            # contract so we have to decrease it here as well
            self.nonce -= 1
            raise


def from_call_to_call_array(calls):
    call_array = []
    calldata = []
    for call in calls:
        assert len(call) == 3, "Invalid call parameters"
        entry = (
            as_address(call[0]),
            get_selector_from_name(call[1]),
            len(calldata),
            len(call[2]),
        )
        call_array.append(entry)
        calldata.extend(call[2])
    return (call_array, calldata)


def hash_multicall(sender, calls, nonce, max_fee):
    hash_array = []
    for call in calls:
        call_elements = [call[0], call[1], compute_hash_on_elements(call[2])]
        hash_array.append(compute_hash_on_elements(call_elements))

    message = [
        str_to_felt("StarkNet Transaction"),
        sender,
        compute_hash_on_elements(hash_array),
        nonce,
        max_fee,
        0,  # transaction version
    ]
    return compute_hash_on_elements(message)
