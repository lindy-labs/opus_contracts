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
OPUS_ADMIN_PK="0x13517e734bea500f1ad4e95c4bea50e3e3676376e3833b00fd445b7bcb4bee"

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
print "Declaring Shrine"
SHRINE_CLASS_HASH=$(starkli declare --private-key $OPUS_ADMIN_PK --casm-file $BUILD_DIR/opus_shrine.compiled_contract_class.json $BUILD_DIR/opus_shrine.contract_class.json)
print $SHRINE_CLASS_HASH

print "Deploying Shrine"
# Shrine's constructor args are admin, token name and token symbol
SHRINE_ADDR=$(starkli deploy --private-key $OPUS_ADMIN_PK $SHRINE_CLASS_HASH $OPUS_ADMIN_ADDR str:Cash str:CASH)
print $SHRINE_ADDR

print "\n\n"

#
# Flash mint
#
print "Declaring Flashmint"
FLASHMINT_CLASS_HASH=$(starkli declare --private-key $OPUS_ADMIN_PK --casm-file $BUILD_DIR/opus_flash_mint.compiled_contract_class.json $BUILD_DIR/opus_flash_mint.contract_class.json)
print $FLASHMINT_CLASS_HASH

print "Deploying Flashmint"
# Flashmint's constructor is just Shrine addr
FLASHMINT_ADDR=$(starkli deploy --private-key $OPUS_ADMIN_PK $FLASHMINT_CLASS_HASH $SHRINE_ADDR)
print $FLASHMINT_ADDR

print "\n\n"

#
# Sentinel
#
print "Declaring Sentinel"
SENTINEL_CLASS_HASH=$(starkli declare --private-key $OPUS_ADMIN_PK --casm-file $BUILD_DIR/opus_sentinel.compiled_contract_class.json $BUILD_DIR/opus_sentinel.contract_class.json)
print $SENTINEL_CLASS_HASH

print "Deploying Sentinel"
# Sentinel's constructor args are admin and Shrine addr
SENTINEL_ADDR=$(starkli deploy --private-key $OPUS_ADMIN_PK $SENTINEL_CLASS_HASH $OPUS_ADMIN_ADDR $SHRINE_ADDR)
print $SENTINEL_ADDR

print "\n\n"

#
# Abbot
#
print "Declaring Abbot"
ABBOT_CLASS_HASH=$(starkli declare --private-key $OPUS_ADMIN_PK --casm-file $BUILD_DIR/opus_abbot.compiled_contract_class.json $BUILD_DIR/opus_abbot.contract_class.json)
print $ABBOT_CLASS_HASH

print "Deploying Abbot"
# Abbot's constructor args are Shrine addr and Sentinel addr
ABBOT_ADDR=$(starkli deploy --private-key $OPUS_ADMIN_PK $ABBOT_CLASS_HASH $SHRINE_ADDR $SENTINEL_ADDR)
print $ABBOT_ADDR

print "\n\n"

#
# Absorber
#
print "Declaring Absorber"
ABSORBER_CLASS_HASH=$(starkli declare --private-key $OPUS_ADMIN_PK --casm-file $BUILD_DIR/opus_absorber.compiled_contract_class.json $BUILD_DIR/opus_absorber.contract_class.json)
print $ABSORBER_CLASS_HASH

print "Deploying Absorber"
# Absorber's constructor args are admin, Shrine addr, Sentinel addr
ABSORBER_ADDR=$(starkli deploy --private-key $OPUS_ADMIN_PK $ABSORBER_CLASS_HASH $OPUS_ADMIN_ADDR $SHRINE_ADDR $SENTINEL_ADDR)
print $ABSORBER_ADDR

print "\n\n"

#
# Mock Oracle
#
print "Declaring mock Oracle"
MOCK_ORACLE_CLASS_HASH=$(starkli declare --private-key $OPUS_ADMIN_PK --casm-file $BUILD_DIR/opus_mock_oracle.compiled_contract_class.json $BUILD_DIR/opus_mock_oracle.contract_class.json)
print $MOCK_ORACLE_CLASS_HASH

print "Deploying mock Oracle"
# Mock Oracle's constructor arg is just Shrine addr
MOCK_ORACLE_ADDR=$(starkli deploy --private-key $OPUS_ADMIN_PK $MOCK_ORACLE_CLASS_HASH $SHRINE_ADDR)
print $MOCK_ORACLE_ADDR

print "\n\n"

#
# Purger
#
print "Declaring Purger"
PURGER_CLASS_HASH=$(starkli declare --private-key $OPUS_ADMIN_PK --casm-file $BUILD_DIR/opus_purger.compiled_contract_class.json $BUILD_DIR/opus_purger.contract_class.json)
print $PURGER_CLASS_HASH

print "Deploying Purger"
# Purger's constructor args are admin, Shrine addr, Sentinel addr, Absorber addr and Oracle addr
# TODO: Oracle addr
PURGER_ADDR=$(starkli deploy --private-key $OPUS_ADMIN_PK $PURGER_CLASS_HASH $OPUS_ADMIN_ADDR $SHRINE_ADDR $SENTINEL_ADDR $ABSORBER_ADDR 0)
print $PURGER_ADDR

print "\n\n"

#
# Allocator
#
print "Declaring Allocator"
ALLOCATOR_CLASS_HASH=$(starkli declare --private-key $OPUS_ADMIN_PK --casm-file $BUILD_DIR/opus_allocator.compiled_contract_class.json $BUILD_DIR/opus_allocator.contract_class.json)
print $ALLOCATOR_CLASS_HASH

print "Deploying Allocator"
# Allocator's constructor args are admin, recipients (span of addrs) and precentages (span or Rays)
ALLOCATOR_ADDR=$(starkli deploy --private-key $OPUS_ADMIN_PK $ALLOCATOR_CLASS_HASH $OPUS_ADMIN_ADDR 1 $KATANA_USER_2_ADDR 1 1000000000000000000000000000)
print $ALLOCATOR_ADDR

print "\n\n"

#
# Equalizer
#
print "Declaring Equalizer"
EQUALIZER_CLASS_HASH=$(starkli declare --private-key $OPUS_ADMIN_PK --casm-file $BUILD_DIR/opus_equalizer.compiled_contract_class.json $BUILD_DIR/opus_equalizer.contract_class.json)
print $EQUALIZER_CLASS_HASH

print "Deploying Equalizer"
# Equalizer's constructor args are admin, shrine, allocator
EQUALIZER_ADDR=$(starkli deploy --private-key $OPUS_ADMIN_PK $EQUALIZER_CLASS_HASH $OPUS_ADMIN_ADDR $SHRINE_ADDR $ALLOCATOR_ADDR)
print $EQUALIZER_ADDR

print "\n\n"

#
# Caretaker
#
print "Declaring Caretaker"
CARETAKER_CLASS_HASH=$(starkli declare --private-key $OPUS_ADMIN_PK --casm-file $BUILD_DIR/opus_caretaker.compiled_contract_class.json $BUILD_DIR/opus_caretaker.contract_class.json)
print $CARETAKER_CLASS_HASH

print "Deploying Caretaker"
# Caretaker's constructor args are admin, shrine, abbot, sentinel, equalizer
CARETAKER_ADDR=$(starkli deploy --private-key $OPUS_ADMIN_PK $CARETAKER_CLASS_HASH $OPUS_ADMIN_ADDR $SHRINE_ADDR $ABBOT_ADDR $SENTINEL_ADDR $EQUALIZER_ADDR)
print $CARETAKER_ADDR

print "\n\n"

#
# Tokens
#
print "Declaring ERC20 token"
ERC20_CLASS_HASH=$(starkli declare --private-key $OPUS_ADMIN_PK --casm-file $BUILD_DIR/opus_erc20.compiled_contract_class.json $BUILD_DIR/opus_erc20.contract_class.json)
print $ERC20_CLASS_HASH

print "Deploying ETH"
# token constructor args are owner, name, symbol, decimals, initial supply, recipient
ETH_ADDR=$(starkli deploy --private-key $OPUS_ADMIN_PK $ERC20_CLASS_HASH str:Ether str:ETH 18 u256:10000000000000000000000000 $OPUS_ADMIN_ADDR)
print $ETH_ADDR

print "Deploying BTC"
# token constructor args are owner, name, symbol, decimals, initial supply, recipient
BTC_ADDR=$(starkli deploy --private-key $OPUS_ADMIN_PK $ERC20_CLASS_HASH str:Bitcoin str:BTC 8 u256:210000000000000 $OPUS_ADMIN_ADDR)
print $BTC_ADDR

#
# Gates
#
print "Declaring Gate"
GATE_CLASS_HASH=$(starkli declare --private-key $OPUS_ADMIN_PK --casm-file $BUILD_DIR/opus_gate.compiled_contract_class.json $BUILD_DIR/opus_gate.contract_class.json)
print $GATE_CLASS_HASH

print "Deploying ETH Gate"
# A Gate's constructor args are shrine, asset addr and sentinel
ETH_GATE_ADDR=$(starkli deploy --private-key $OPUS_ADMIN_PK $GATE_CLASS_HASH $SHRINE_ADDR $ETH_ADDR $SENTINEL_ADDR)
print $ETH_GATE_ADDR

print "Deploying BTC Gate"
# A Gate's constructor args are shrine, asset addr and sentinel
BTC_GATE_ADDR=$(starkli deploy --private-key $OPUS_ADMIN_PK $GATE_CLASS_HASH $SHRINE_ADDR $BTC_ADDR $SENTINEL_ADDR)
print $BTC_GATE_ADDR


print "\n\n"
printf "-----------------------------------------------------------------------------------\n"
# pretty print a table of the modules and their addrs
addrs=("Abbot $ABBOT_ADDR" "Absorber $ABSORBER_ADDR" "Allocator $ALLOCATOR_ADDR"
    "Caretaker $CARETAKER_ADDR" "Equalizer $EQUALIZER_ADDR" "Gate[BTC] $BTC_GATE_ADDR" "Gate[ETH] $ETH_GATE_ADDR"
    "Flashmint $FLASHMINT_ADDR" "Purger $PURGER_ADDR" "Sentinel $SENTINEL_ADDR" "Shrine $SHRINE_ADDR"
    "Token[BTC] $BTC_ADDR"  "Token[ETH] $ETH_ADDR"
    "Oracle $MOCK_ORACLE_ADDR"
)
for tuple in "${addrs[@]}"; do
    key="${tuple%% *}"
    val="${tuple#* }"

    printf "%-16s %s\n" $key $val
done
printf "-----------------------------------------------------------------------------------\n"

# TODO:
#   Oracle
#   add tokens as yangs
#   less verbose output
