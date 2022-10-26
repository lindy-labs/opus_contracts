# https://docs.empiric.network/using-empiric/consuming-data

from starknet_py.net.client_models import Call
from starknet_py.net.gateway_client import GatewayClient
from starknet_py.net.networks import TESTNET
from starkware.starknet.public.abi import get_selector_from_name

EMPIRIC_GOERLI_ADDR = 0x446812BAC98C08190DEE8967180F4E3CDCD1DB9373CA269904ACB17F67F7093


def str_to_felt(text: str) -> int:
    b_text = bytes(text, "ascii")
    return int.from_bytes(b_text, "big")


def main():
    client = GatewayClient(TESTNET)
    cx = Call(EMPIRIC_GOERLI_ADDR, get_selector_from_name("get_spot_median"), [str_to_felt("ETH/USD")])
    price, decimals, last_updated, num_sources = client.call_contract_sync(cx)
    print("Price:          ", price)
    print("Decimals:       ", decimals)
    print("Last updated at:", last_updated)
    print("Num sources:    ", num_sources)


if __name__ == "__main__":
    main()
