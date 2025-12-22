# Deployed Contracts

## Current Active Contracts

### Kuru ↔ Uniswap V4
| Contract | Address | Pair | TickSpacing |
|----------|---------|------|-------------|
| ArbitrageAUSD | `0xd094376118983aecbf8496d84caa96df6a3976d1` | MON/AUSD | 1 |
| ArbitrageUSDC | `0xbfe7c25725833b8e7e956a982a1db75a930092dc` | MON/USDC | 10 |

### Kuru ↔ PancakeSwap V3  
| Contract | Address | PCS Pool |
|----------|---------|----------|
| ArbitragePancakeAUSD | `0x386fa87ff4ca03f84663b5a109a33518c3ca3ad2` | AUSD/WMON |
| ArbitragePancakeUSDC | `0x69c2afa06f9df12281bc27e7b960279ab6e27119` | WMON/USDC |

### PancakeSwap V3 ↔ Uniswap V4
| Contract | Address | PCS Pool | Uni TickSpacing |
|----------|---------|----------|-----------------|
| ArbitragePcsUniAUSD | `0x9f4a9a9ede458db4ddc227a9aae2b8eb603f1d1d` | AUSD/WMON | 1 |
| ArbitragePcsUniUSDC | `0x2913e4d3c13063f579065970b059f017e5ad892c` | WMON/USDC | 10 |

---

## Core Addresses

### Uniswap V4
- **PoolManager:** `0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e`

### PancakeSwap V3 Pools
- **AUSD/WMON:** `0xD5b70d70CBE6C42bCD1aaa662A21673A83f4615b`
- **WMON/USDC:** `0x63e48B725540A3Db24ACF6682a29f877808C53F2`

### Kuru Orderbooks
- **MON/AUSD:** `0xf39c4fD5465Ea2dD7b0756CeBC48a258b34FeBf3`
- **MON/USDC:** `0x122C0D8683Cab344163fB73E28E741754257e3Fa`

### Tokens
- **MON:** Native (address 0)
- **WMON:** `0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A`
- **AUSD:** `0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a`
- **USDC:** `0x754704Bc059F8C67012fEd69BC8A327a5aafb603`
- **WBTC:** `0x0555E30da8f98308EdB960aa94C0Db47230d2B9c`

### Profit Wallet
- `0x0000000383dCfDc98cFda69dD8A9EEec239e35E1`

---

## Uni V4 Pool TickSpacing
- **MON/AUSD:** tickSpacing = 1
- **MON/USDC:** tickSpacing = 10

---

## Keeper Config
```toml
[[bots]]
address = "0xbfe7c25725833b8e7e956a982a1db75a930092dc"
name = "USDC Uni"

[[bots]]
address = "0xd094376118983aecbf8496d84caa96df6a3976d1"
name = "AUSD Uni"

[[bots]]
address = "0x386fa87ff4ca03f84663b5a109a33518c3ca3ad2"
name = "AUSD Pancake"

[[bots]]
address = "0x69c2afa06f9df12281bc27e7b960279ab6e27119"
name = "USDC Pancake"

[[bots]]
address = "0x9f4a9a9ede458db4ddc227a9aae2b8eb603f1d1d"
name = "AUSD PcsUni"

[[bots]]
address = "0x2913e4d3c13063f579065970b059f017e5ad892c"
name = "USDC PcsUni"
```
