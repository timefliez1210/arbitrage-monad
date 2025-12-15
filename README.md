## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
    let bots: Vec<ArbBot> = vec![
        // MON/AUSD Arbitrage Bot
        ArbBot {
            name: "Arbitrage MON/AUSD".to_string(),
            address: Address::from_str("0xc2a449e9ffc17c5af00f780f7b85df2ca941c8e1").unwrap(),
        },
        // USDC Arbitrage Bot
        ArbBot {
            address: Address::from_str("0xa38500b37011734ec3f45fe4b430ebd1e8867162")?, // USDC Arb
            name: "USDC".to_string(),
        },



        ArbBot {
            address: Address::from_str("0x73B5220f73Ad7B3C3C03C73f43571Ad563FF67B0")?, // USDC Arb (0.15 threshold)
            name: "USDC".to_string(),
        },
        ArbBot {
            address: Address::from_str("0xde6824EB845A1327cbE0e889435769B961051B26")?, // AUSD Arb (0.15 threshold)
            name: "AUSD".to_string(),
        },


        Kuru Flow Router Swap
                // ArbBot {
        //     address: Address::from_str("0x98C85aBe9A5bC51D382723BaBB558E5DC993D093")?, // AUSD KuruFlow
        //     name: "AUSD-KuruFlow".to_string(),
        // },