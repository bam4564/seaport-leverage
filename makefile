# Basic makefile for Pitch Contracts

# Pull in everything from the .env file
ifneq (,$(wildcard ./.env))
  include .env
  export
endif

all: build

# Build contracts	
build: 
	forge build

setup:
	forge install

format:
	npm run prettier

lint:
	npm run solhint

# Testing
tests:
	forge test --fork-url ${TESTING_RPC_URL} -vvv 

# Gas and Coverage Reports
get_gas:
	cast gas-price

get_latest_basefee:
	cast basefee

# Anvil local node
node:
	anvil --fork-url ${MAINNET_RPC_URL}

# Node management commands 
anvil_reset:
	curl -X POST -H 'Content-Type: application/json' \
	-d '{"jsonrpc": "2.0", "method": "anvil_reset", "params": [{"forking": {"jsonRpcUrl": "${MAINNET_RPC_URL}", "blockNumber": "latest"}}], "id": 1}' ${LOCAL_RPC_URL}

full_reset: anvil_reset
	forge script script/DeployTestableFraxFarm.s.sol --rpc-url ${LOCAL_RPC_URL} --private-key ${LOCAL_TESTING_PRIVATE_KEY} -vvvv --broadcast --ffi
	forge script script/DeployOrderFillerSuite.s.sol --rpc-url ${LOCAL_RPC_URL} --private-key ${LOCAL_TESTING_PRIVATE_KEY} -vvvv --broadcast --ffi

# -------------------------------------------------------------------------------------------------------------------------
# -------------------------------------------- Local Testing of ION Deleverage --------------------------------------------
# -------------------------------------------------------------------------------------------------------------------------

deal_eth_ion_deployer: 
	cast rpc anvil_setBalance ${LOCAL_ION_DEPLOYER_ADDRESS} 10000000000000000000 --rpc-url ${LOCAL_RPC_URL}

deploy_ion_seaport_deleverage: deal_eth_ion_deployer
# 	Deploy the ION Seaport Deleverage contract for weETH  
#   first arg is ION pool proxy address for weETH 
#   second arg is gem join address for pool 
	forge create --rpc-url ${LOCAL_RPC_URL} src/SeaportDeleverage.sol:SeaportDeleverage \
		--private-key ${LOCAL_ION_DEPLOYER_PKEY} \
		--gas-limit 10000000 \
		--constructor-args '0x0000000000eaEbd95dAfcA37A39fd09745739b78' '0x3f6119B0328C27190bE39597213ea1729f061876' 0
# Yields the following outputs when run successfully
# Deployer: 0x4Fb386F5E85b355cEc4eB1A491Ab76ecA19Bd5C9
# Deployed to: 0x045dB163d222BdD8295ca039CD0650D46AC477f3
# Transaction hash: 0x4ccbd8db9b129aa18a7332b888a3ea64531f882957ec8107d9266cd9014f39f0

run_seaport_deleverage_logic: 
	forge script script/HourglassDeleverageLogic.s.sol --rpc-url ${LOCAL_RPC_URL} --private-key ${LOCAL_ION_DEPLOYER_PKEY} -vvvv --broadcast --ffi

run_seaport_deleverage_debt: 
	forge script script/HourglassDeleverageLogicDebt.s.sol --rpc-url ${LOCAL_RPC_URL} --private-key ${LOCAL_ION_DEPLOYER_PKEY} -vvvv --broadcast --ffi



run_seaport_deleverage_e2e: 
	forge script script/HourglassDeleverageE2E.s.sol --rpc-url ${LOCAL_RPC_URL} --private-key ${LOCAL_ION_DEPLOYER_PKEY} -vvvv --broadcast --ffi




