# Aptos Multisig Contract Chunked Publish Tutorial

This repository demonstrates how to deploy and upgrade a Move smart contract with chunked publish as a **code object** using a **multisig wallet** on the Aptos blockchain. The example includes multiple duplicate "Hello World" contracts that can be upgraded through multisig governance.

Note: if you don't need to use `chunked-publish`, please see [aptos-multisig-deployment](https://github.com/wagmitt/aptos-multisig-deployment) for a simpler implementation of the same scripts.

## Prerequisites

- [Aptos CLI](https://aptos.dev/cli-tools/aptos-cli-tool/install-aptos-cli)
- Bash shell environment
- Git

## Project Structure

```
.
├── sources/             # Move smart contract source files
├── scripts/             # Deployment and setup scripts
├── keys/               # Generated keys and addresses (will be created)
├── deployment/         # Deployment artifacts (will be created)
├── Move.toml           # Move package manifest
└── publication.json    # Package publication info
```

## Setup and Deployment Steps

### 0. Setup Signers

```bash
bash ./scripts/0_setup_signers.sh
```

This script will:

- Create necessary directories
- Generate two owner keys for the multisig
- Initialize Aptos CLI with the generated keys

### 1. Setup Multisig

```bash
bash ./scripts/1_setup_multisig.sh
```

Creates a 2-of-2 multisig account that will own and control the smart contract.

### 2.1. Create Hello World Copies

```bash
bash ./scripts/2_1_create_hello_world_copies.sh
```

This helper script creates copies of the `hello_world.move` module to increase the deployment size for testing chunked-publish. Change the `NUM_COPIES` value to increase or decrease the amount of copies to make.

### 2.2. Deploy Code Object

```bash
bash ./scripts/2_2_deploy_code_object.sh
```

Deploys the initial version of the Hello World contracts.

### 2.3. Query Published Chunks

```bash
bash ./scripts/2_3_query_published_chunks.sh
```

Retrieves the payload of the chunked deployment transaction and stores the deployment chunk sizes in `config/chunk_sizes.json`. These values will be used in step 4 when creating a chunked upgrade transaction.

### 3. Transfer Code Object

```bash
bash ./scripts/3_transfer_code_object.sh
```

Transfers ownership of the deployed contract to the multisig account.

### 4. Upgrade Code Object

```bash
bash ./scripts/4_upgrade_code_object.sh
```

Demonstrates how to upgrade the contract through the multisig. The chunk sizes are determined by the values in `config/chunk_sizes.json`. Either run `./scripts/2_3_query_published_chunks.sh` to retrieve the values of the initial chunked publish, or modify this file to your needs.

## Smart Contract Details

The example contracts are identical copies, to simulate deploying large modules.

## Security Considerations

- Keep your private keys secure and never share them
- The multisig setup requires both owners to approve any contract upgrades
- All generated keys will be stored in the `keys/` directory

## Network

This tutorial is configured to work with Aptos testnet by default. To use a different network, modify the network parameter in the setup scripts.

## Troubleshooting

If you encounter any issues:

1. Ensure Aptos CLI is properly installed and in your PATH
2. Check that all scripts have execute permissions (`chmod +x scripts/*.sh`)
3. Verify you have sufficient test tokens for deployment
4. Clear the `keys/` and `deployment/` directories and start fresh if needed

## Acknowledgements

This project is based on [aptos-multisig-deployment](https://github.com/wagmitt/aptos-multisig-deployment) by [wagmitt](https://github.com/wagmitt).

If you want to use these scripts without `chunked--publish`, it is recommended to use the scripts in that repo instead.

## License

This project is open-source and available under the MIT License.
