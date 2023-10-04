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

# user 1 in Katana
OPUS_ADMIN_ADDR="0x5e405cb48f615268de62931988de94f6d1a084d09ed28ef01d7252e295d3a4f"
OPUS_ADMIN_PK="0x13517e734bea500f1ad4e95c4bea50e3e3676376e3833b00fd445b7bcb4bee"

export STARKNET_ACCOUNT="$WORK_DIR/admin_user.json"
export STARKNET_RPC="http://127.0.0.1:5050"

#
# Clean compile
#

print "Building Opus"
scarb clean && scarb build

#
# Shrine
#
print "Declaring Shrine"
SHRINE_CLASS_HASH=$(starkli declare --private-key $OPUS_ADMIN_PK $PROJ_DIR/target/dev/opus_Shrine.sierra.json)
print $SHRINE_CLASS_HASH

print "\n\n"

print "Deploying Shrine"
# Shrine's constructor args are admin, token name and token symbol
SHRINE_ADDR=$(starkli deploy --private-key $OPUS_ADMIN_PK $SHRINE_CLASS_HASH $OPUS_ADMIN_ADDR str:Cash str:CASH)
print $SHRINE_ADDR

print "\n\n"

#
# Flash mint
#
print "Declaring Flashmint"
FLASHMINT_CLASS_HASH=$(starkli declare --private-key $OPUS_ADMIN_PK $PROJ_DIR/target/dev/opus_FlashMint.sierra.json)
print $FLASHMINT_CLASS_HASH

print "\n\n"

print "Deploying Flashmint"
# Flashmint's constructor is just Shrine addr
FLASHMINT_ADDR=$(starkli deploy --private-key $OPUS_ADMIN_PK $FLASHMINT_CLASS_HASH $SHRINE_ADDR)
print $FLASHMINT_ADDR

#
# Sentinel
#
print "Declaring Sentinel"
SENTINEL_CLASS_HASH=$(starkli declare --private-key $OPUS_ADMIN_PK $PROJ_DIR/target/dev/opus_Sentinel.sierra.json)
print $SENTINEL_CLASS_HASH

print "\n\n"

print "Deploying Sentinel"
# Sentinel's constructor args are admin and Shrine addr
SENTINEL_ADDR=$(starkli deploy --private-key $OPUS_ADMIN_PK $SENTINEL_CLASS_HASH $OPUS_ADMIN_ADDR $SHRINE_ADDR)
print $SENTINEL_ADDR

#
# Abbot
#
print "Declaring Abbot"
ABBOT_CLASS_HASH=$(starkli declare --private-key $OPUS_ADMIN_PK $PROJ_DIR/target/dev/opus_Abbot.sierra.json)
print $ABBOT_CLASS_HASH

print "\n\n"

print "Deploying Abbot"
# Abbot's constructor args are Shrine addr and Sentinel addr
ABBOT_ADDR=$(starkli deploy --private-key $OPUS_ADMIN_PK $ABBOT_CLASS_HASH $SHRINE_ADDR $SENTINEL_ADDR)
print $ABBOT_ADDR

#
# Absorber
#
print "Declaring Absorber"
ABSORBER_CLASS_HASH=$(starkli declare --private-key $OPUS_ADMIN_PK $PROJ_DIR/target/dev/opus_Absorber.sierra.json)
print $ABSORBER_CLASS_HASH

print "\n\n"

print "Deploying Absorber"
# Absorber's constructor args are admin, Shrine addr, Sentinel addr
ABSORBER_ADDR=$(starkli deploy --private-key $OPUS_ADMIN_PK $ABSORBER_CLASS_HASH $OPUS_ADMIN_ADDR $SHRINE_ADDR $SENTINEL_ADDR)
print $ABSORBER_ADDR

#
# Purger
#
print "Declaring Purger"
PURGER_CLASS_HASH=$(starkli declare --private-key $OPUS_ADMIN_PK $PROJ_DIR/target/dev/opus_Purger.sierra.json)
print $PURGER_CLASS_HASH

print "\n\n"

print "Deploying Purger"
# Purger's constructor args are admin, Shrine addr, Sentinel addr, Absorber addr and Oracle addr
# TODO: Oracle addr
PURGER_ADDR=$(starkli deploy --private-key $OPUS_ADMIN_PK $PURGER_CLASS_HASH $OPUS_ADMIN_ADDR $SHRINE_ADDR $SENTINEL_ADDR $ABSORBER_ADDR 0)
print $PURGER_ADDR

# TODO:
#   Allocator
#   Caretaker
#   Equalizer
#   Gates + tokens
#   Oracle
