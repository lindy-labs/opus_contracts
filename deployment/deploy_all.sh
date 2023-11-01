#!/bin/zsh

set -e
set -u
set -o pipefail

# Deploy script for Opus
# Assuming katana with --seed 0x6f707573

#
# vars
#

WORK_DIR="$(dirname `realpath $0`)"
PROJ_DIR="$(realpath $WORK_DIR/..)"
BUILD_DIR="$PROJ_DIR/target/dev"
export STARKLI_NO_PLAIN_KEY_WARNING=1

# user 1 in Katana
OPUS_ADMIN_ADDR="0x5e405cb48f615268de62931988de94f6d1a084d09ed28ef01d7252e295d3a4f"
# all starkli commands will use this PK unless otherwise specified
export STARKNET_PRIVATE_KEY="0x13517e734bea500f1ad4e95c4bea50e3e3676376e3833b00fd445b7bcb4bee"

export STARKNET_ACCOUNT="$WORK_DIR/admin_user.json"
export STARKNET_RPC="http://127.0.0.1:5050"

KATANA_USER_2_ADDR="0x296ef185476e31a65b83ffa6962a8a0f8ccf5b59d5839d744f5890ac72470e4"

#
# Clean compile
#

print "Building Opus"
scarb clean && scarb build

#
# Shrine
#
print "Shrine"
SHRINE_CLASS_HASH=$(starkli declare --casm-file $BUILD_DIR/opus_shrine.compiled_contract_class.json $BUILD_DIR/opus_shrine.contract_class.json)
# Shrine's constructor args are admin, token name and token symbol
SHRINE_ADDR=$(starkli deploy $SHRINE_CLASS_HASH $OPUS_ADMIN_ADDR str:Cash str:CASH)

print "\n"

#
# Flash mint
#
print "Flashmint"
FLASHMINT_CLASS_HASH=$(starkli declare --casm-file $BUILD_DIR/opus_flash_mint.compiled_contract_class.json $BUILD_DIR/opus_flash_mint.contract_class.json)
# Flashmint's constructor is just Shrine addr
FLASHMINT_ADDR=$(starkli deploy $FLASHMINT_CLASS_HASH $SHRINE_ADDR)

print "\n"

#
# Sentinel
#
print "Sentinel"
SENTINEL_CLASS_HASH=$(starkli declare --casm-file $BUILD_DIR/opus_sentinel.compiled_contract_class.json $BUILD_DIR/opus_sentinel.contract_class.json)
# Sentinel's constructor args are admin and Shrine addr
SENTINEL_ADDR=$(starkli deploy $SENTINEL_CLASS_HASH $OPUS_ADMIN_ADDR $SHRINE_ADDR)

print "\n"

#
# Abbot
#
print "Abbot"
ABBOT_CLASS_HASH=$(starkli declare --casm-file $BUILD_DIR/opus_abbot.compiled_contract_class.json $BUILD_DIR/opus_abbot.contract_class.json)
# Abbot's constructor args are Shrine addr and Sentinel addr
ABBOT_ADDR=$(starkli deploy $ABBOT_CLASS_HASH $SHRINE_ADDR $SENTINEL_ADDR)

print "\n"

#
# Absorber
#
print "Absorber"
ABSORBER_CLASS_HASH=$(starkli declare --casm-file $BUILD_DIR/opus_absorber.compiled_contract_class.json $BUILD_DIR/opus_absorber.contract_class.json)
# Absorber's constructor args are admin, Shrine addr, Sentinel addr
ABSORBER_ADDR=$(starkli deploy $ABSORBER_CLASS_HASH $OPUS_ADMIN_ADDR $SHRINE_ADDR $SENTINEL_ADDR)

print "\n"

#
# Mock Oracle
#
print "Mock Oracle"
MOCK_ORACLE_CLASS_HASH=$(starkli declare --casm-file $BUILD_DIR/opus_mock_oracle.compiled_contract_class.json $BUILD_DIR/opus_mock_oracle.contract_class.json)
# Mock Oracle's constructor arg is just Shrine addr
MOCK_ORACLE_ADDR=$(starkli deploy $MOCK_ORACLE_CLASS_HASH $SHRINE_ADDR)

print "\n"

#
# Purger
#
print "Purger"
PURGER_CLASS_HASH=$(starkli declare --casm-file $BUILD_DIR/opus_purger.compiled_contract_class.json $BUILD_DIR/opus_purger.contract_class.json)
# Purger's constructor args are admin, Shrine addr, Sentinel addr, Absorber addr and Oracle addr
PURGER_ADDR=$(starkli deploy  $PURGER_CLASS_HASH $OPUS_ADMIN_ADDR $SHRINE_ADDR $SENTINEL_ADDR $ABSORBER_ADDR $MOCK_ORACLE_ADDR)

print "\n"

#
# Allocator
#
print "Allocator"
ALLOCATOR_CLASS_HASH=$(starkli declare --casm-file $BUILD_DIR/opus_allocator.compiled_contract_class.json $BUILD_DIR/opus_allocator.contract_class.json)
# Allocator's constructor args are admin, recipients (span of addrs) and percentages (span of Rays)
ALLOCATOR_ADDR=$(starkli deploy  $ALLOCATOR_CLASS_HASH $OPUS_ADMIN_ADDR 1 $KATANA_USER_2_ADDR 1 1000000000000000000000000000)

print "\n"

#
# Equalizer
#
print "Equalizer"
EQUALIZER_CLASS_HASH=$(starkli declare --casm-file $BUILD_DIR/opus_equalizer.compiled_contract_class.json $BUILD_DIR/opus_equalizer.contract_class.json)
# Equalizer's constructor args are admin, shrine, allocator
EQUALIZER_ADDR=$(starkli deploy $EQUALIZER_CLASS_HASH $OPUS_ADMIN_ADDR $SHRINE_ADDR $ALLOCATOR_ADDR)

print "\n"

#
# Caretaker
#
print "Caretaker"
CARETAKER_CLASS_HASH=$(starkli declare --casm-file $BUILD_DIR/opus_caretaker.compiled_contract_class.json $BUILD_DIR/opus_caretaker.contract_class.json)
# Caretaker's constructor args are admin, shrine, abbot, sentinel, equalizer
CARETAKER_ADDR=$(starkli deploy $CARETAKER_CLASS_HASH $OPUS_ADMIN_ADDR $SHRINE_ADDR $ABBOT_ADDR $SENTINEL_ADDR $EQUALIZER_ADDR)

print "\n"

#
# Controller
#
print "Controller"
CONTROLLER_CLASS_HASH=$(starkli declare --casm-file $BUILD_DIR/opus_controller.compiled_contract_class.json $BUILD_DIR/opus_controller.contract_class.json)
# Controller's constructor args are admin, shrine, p gain, i gain, alpha p, beta p, alpha i, beta i
CONTROLLER_ADDR=$(starkli deploy $CONTROLLER_CLASS_HASH $OPUS_ADMIN_ADDR $SHRINE_ADDR 100000000000000000000000000000 0 3 8 1 2)

print "\n"

#
# Tokens
#
print "ERC20 tokens (ETH & BTC)"
ERC20_CLASS_HASH=$(starkli declare  --casm-file $BUILD_DIR/opus_erc20.compiled_contract_class.json $BUILD_DIR/opus_erc20.contract_class.json)
# token constructor args are owner, name, symbol, decimals, initial supply, recipient
ETH_ADDR=$(starkli deploy  $ERC20_CLASS_HASH str:Ether str:ETH 18 u256:10000000000000000000000000 $OPUS_ADMIN_ADDR)
BTC_ADDR=$(starkli deploy  $ERC20_CLASS_HASH str:Bitcoin str:BTC 8 u256:210000000000000 $OPUS_ADMIN_ADDR)

#
# Gates
#
print "Gates"
GATE_CLASS_HASH=$(starkli declare  --casm-file $BUILD_DIR/opus_gate.compiled_contract_class.json $BUILD_DIR/opus_gate.contract_class.json)
# A Gate's constructor args are shrine, asset addr and sentinel
ETH_GATE_ADDR=$(starkli deploy  $GATE_CLASS_HASH $SHRINE_ADDR $ETH_ADDR $SENTINEL_ADDR)
BTC_GATE_ADDR=$(starkli deploy  $GATE_CLASS_HASH $SHRINE_ADDR $BTC_ADDR $SENTINEL_ADDR)
print $BTC_GATE_ADDR

print "\n"

#
# all necessary contracts are deployed
# setup their roles
#
print "Setting up roles"

# Absorber
# update to Purger
starkli invoke $ABSORBER_ADDR grant_role 4 $PURGER_ADDR

# Sentinel
# enter + exit to Abbot
starkli invoke $SENTINEL_ADDR grant_role $((2 + 4)) $ABBOT_ADDR
# exit to Purger
starkli invoke $SENTINEL_ADDR grant_role 4 $PURGER_ADDR
# exit to Caretaker
starkli invoke $SENTINEL_ADDR grant_role 4 $CARETAKER_ADDR

# Shrine
# deposit + forge + melt + withdraw to Abbot
starkli invoke $SHRINE_ADDR grant_role $((4 + 16 + 128 + 65536)) $ABBOT_ADDR
# eject + kill + seize to Caretaker
starkli invoke $SHRINE_ADDR grant_role $((8 + 64 + 512)) $CARETAKER_ADDR
# set multiplier to Controller
starkli invoke $SHRINE_ADDR grant_role 2048 $CONTROLLER_ADDR
# inject to Equalizer
starkli invoke $SHRINE_ADDR grant_role 32 $EQUALIZER_ADDR
# eject + inject to Flash mint
starkli invoke $SHRINE_ADDR grant_role $((8 + 32)) $FLASHMINT_ADDR
# advance to Oracle
starkli invoke $SHRINE_ADDR grant_role 2 $MOCK_ORACLE_ADDR
# melt + redistribute + seize to Purger
starkli invoke $SHRINE_ADDR grant_role $((128 + 256 + 512)) $PURGER_ADDR /
# add yang + update yang suspension to Sentinel
starkli invoke $SHRINE_ADDR grant_role $((1 + 16384)) $SENTINEL_ADDR

print "\n"

#
# adding ETH and BTC yangs
#
print "Adding ETH and BTC yangs"
# when adding yang, Sentinel takes initial amount, approve sentinel to spend admin's tokens
starkli invoke $ETH_ADDR approve $SENTINEL_ADDR u256:10000000000000000000000
starkli invoke $BTC_ADDR approve $SENTINEL_ADDR u256:10000000000000000000000
# ETH: threshold is 80%, start price 2000, base rate 2%
starkli invoke $SENTINEL_ADDR add_yang $ETH_ADDR 10000000000000000000000 800000000000000000000000000 2000000000000000000000 20000000000000000000000000 $ETH_GATE_ADDR
# BTC: threshold is 90%, start price 35000, base rate 2.5%
starkli invoke $SENTINEL_ADDR add_yang $BTC_ADDR 10000000000000000000000 900000000000000000000000000 35000000000000000000000 25000000000000000000000000 $BTC_GATE_ADDR

print "\n"

printf "-----------------------------------------------------------------------------------\n"
# pretty print a table of the modules and their addrs
addrs=("Abbot $ABBOT_ADDR" "Absorber $ABSORBER_ADDR" "Allocator $ALLOCATOR_ADDR"
    "Caretaker $CARETAKER_ADDR" "Controller $CONTROLLER_ADDR" "Equalizer $EQUALIZER_ADDR"
    "Gate[BTC] $BTC_GATE_ADDR" "Gate[ETH] $ETH_GATE_ADDR" "Flashmint $FLASHMINT_ADDR"
    "Oracle $MOCK_ORACLE_ADDR" "Purger $PURGER_ADDR" "Sentinel $SENTINEL_ADDR"
    "Shrine $SHRINE_ADDR" "Token[BTC] $BTC_ADDR"  "Token[ETH] $ETH_ADDR"
)
for tuple in "${addrs[@]}"; do
    key="${tuple%% *}"
    val="${tuple#* }"

    printf "%-16s %s\n" $key $val
done
printf "-----------------------------------------------------------------------------------\n"
