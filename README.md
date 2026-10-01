# Decentralized Security
DeSec is an attempt to incentivize protocols and users to collaborate in combatting real time exploits.
## Overview
The DeSec protocol allows anyone to register any smart contract and provide:
- An invariant that should never be broken
- A bounty for reporting that invariant as broken
- A check-in fee that drips to watchers that verify the integrity of the invariant
- An interval for the check-in fee
- A protocol owner, acting as an admin for their registered protocol
- An emergency action, triggered when the invariant is confirmed broken

The check-in fee and the emergency action are optional. The protocol can be registered and bounty only.

You can read the full specification at: [Protocol specification](/docs/protocol.md)

It is MIT licensed.

### Getting Started

This project is built with [Foundry](https://book.getfoundry.sh/).

```bash
# Install Foundry (once per machine)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone with the dependencies (forge-std, openzeppelin-contracts)
git clone --recurse-submodules <repo-url>
cd deSec

# If you already cloned without submodules:
git submodule update --init --recursive

# Build and run the full test suite (unit, fuzz, and invariant tests)
forge build
forge test
```

### Deployment

The entire network deploys from a single transaction: the `GuardianAdapterFactory` constructor deploys the `DeSecRegistry` and the `GuardianExecutor` and wires them together. The deployer of the factory becomes the initial network fee recipient.

1. Create a `.env` file in the project root:

```bash
RPC_URL=<your rpc endpoint>
ETHERSCAN_URL=<your block explorer verifier url>
PRIVATE_KEY=<deployer private key, 0x-prefixed>
```

2. Deploy and verify:

```bash
forge script script/DeSec.s.sol --rpc-url $RPC_URL --broadcast --verify --verifier-url $ETHERSCAN_URL -vvvv
```

The script logs the factory, registry, executor, and fee recipient addresses. Before broadcasting to a live network, you can dry-run the deployment locally with `forge script script/DeSec.s.sol`.

