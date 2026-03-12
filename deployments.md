## Kuru Internal Contracts

| Contract | Address |
|----------|---------|
| kuru flow | `0xb3e6778480b2E488385E8205eA05E20060B813cb` |
| kuru flow router | `0x465D06d4521ae9Ce724E0c182Daad5D8a2Ff7040` |
| kuru amm vault impl | `0xDC2A82E321866C30d62077945e067172C5f970F4` |
| kuru forwarder | `0x974E61BBa9C4704E8Bcc1923fdC3527B41323FAA` |
| kuru forwarder impl | `0xbf6Cc109c6eBcA4B28e3e51FD8798294599CFe2A` |
| kuru utils | `0xD8Ea5Ea6A4ebc202C77c795cb2a35835afd127f6` |
| margin account | `0x2A68ba1833cDf93fa9Da1EEbd7F46242aD8E90c5` |
| margin account impl | `0x57cF97FE1FAC7D78B07e7e0761410cb2e91F0ca7` |
| monad deployer | `0xe29309e308af3EE3B1a414E97c37A58509f27D1E` |
| order book impl | `0xea2Cc8769Fb04Ff1893Ed11cf517b7F040C823CD` |
| router impl | `0x0F2A2a5c0A78c406c26Adb2F1681D3e47322A9CD` |

example order book implementation MON/USDC for testing 0x122C0D8683Cab344163fB73E28E741754257e3Fa

### Pools Discovered
- **MON/USDC**: Fee 500 (0.05%), TickSpacing 10, USDC: `0x754704Bc059F8C67012fEd69BC8A327a5aafb603`
- **AUSD/USDC**: Fee 50 (0.005%), TickSpacing 1, AUSD: `0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a`, USDC: `0x754704Bc059F8C67012fEd69BC8A327a5aafb603`
- **MON/AUSD**: Fee 500 (0.05%), TickSpacing 1, AUSD: `0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a`
USDC/AUSD 0x8cF49e35D73B19433FF4d4421637AABB680dc9Cc <AUSD/USDC market>
WBTC address 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c
### Arbitrage Bots
- **Arbitrage (USDC)**: `0xbab899556aa7ea9c6d2d188417f7e6c53d15e6bb`
- **ArbitrageAUSD**: `0xdd4f2ee3d629f18095e8fef48ce2a9fe72192dcf`

### Kuru OrderBooks
- **MON/USDC**: `0x122C0D8683Cab344163fB73E28E741754257e3Fa`
- **MON/AUSD**: `0xf39c4fD5465Ea2dD7b0756CeBC48a258b34FeBf3`

### Latest Deployment (Liquidity Cap Fix)
- **Arbitrage (USDC)**: `0x863b546e53cB7821e963E0887668E1A69B3B7f84`
- **ArbitrageAUSD**: `0x0B1351bA380e0a9448Bfb6f7c43DC5c7a3660357`

### Production Deployment (Recipient Fixed)
- **ArbitrageAUSD**: `0x70f03e44cc8571fc1a32092c99256e996d070f3c`
- **ArbitrageUSDC**: `0xa38500b37011734ec3f45fe4b430ebd1e8867162`

### Bug Fix Deployment (Price Inversion Check)
- **ArbitrageAUSD**: `0xf0a4fbc224729088773599e0274b3a1ec3d75b5f`

### Bug Fix Deployment (Safety Buffer)
- **ArbitrageAUSD**: `0x63a769a43d9f3f0833654fc7276de2d11a1eecd0`

### Bug Fix Deployment (Zero Min Amount Out)
- **ArbitrageAUSD**: `0x54cb5f73e412a388417263d3c278076a98f8ce71`

### Bug Fix Deployment (Fee Validation & Limit Clamp)
- **ArbitrageAUSD**: `0xf8f0f6c2b87631e7a158455c05d61d65f9b5b046`

### Bug Fix Deployment (Stack Corruption / Console Logs Removed)
- **ArbitrageAUSD**: `0x5fb493210e3d92c9f57762e592934be42c31d284`

### Bug Fix Deployment (7bps Profit Logic Aligned)
- **ArbitrageAUSD**: `0x42282761b7855a9e7fc59b32b816ca04ebfe49e4`

### Bug Fix Deployment (Correct Profit Wallet)
- **ArbitrageAUSD**: `0xc2a449e9ffc17c5af00f780f7b85df2ca941c8e1`

### Deployment (Min Size & 0.7% Buffer) - ACTIVE
- **ArbitrageAUSD**: `0x058b62eb0ff589176a26034e69f6f8ccf619c0ef`
- **ArbitrageUSDC**: `0xcfde93b0e118a23d080d7e65b4ec162aa48aa73e`

### ArbitrageTriangle V2 (2024-12-14) - DEPRECATED
- **ArbitrageTriangle**: `0x98bd1fdbf086717bd648bec9fb7912ebd94a2fb9`
- Triangular arb: Uni MON/USDC → Kuru MON/AUSD → Uni AUSD/USDC
- Fixes: sqrtPriceLimit, AUSD price conversion for Kuru queries

### ArbitrageTriangle V3 (2024-12-14) - ACTIVE
- **ArbitrageTriangle**: `0x5c4e9658907a8d8fb7e5a59a3bf589739fdd872c`
- Fix: Uni-first REVERSE flow (sqrtPriceLimit controls fill before Kuru commitment)
- Removed trade size cap (no longer needed with correct flow)

### Pre-Optimization v3 (2024-12-14) - SUPERSEDED
- **ArbitrageAUSD-v3**: `0x49ea296c003f23ef6b86B36F0c47cA067f25e5b5`
- **ArbitrageUSDC-v3**: `0x1370C351A81B73d0930fd5bEb1E3Ea279E75DF51`
- Used `calculateProfit()` with 50-tick depth
- Blocking `join_all` broadcasts
- Typical Δ Blocks: 2, occasional 3-4 on slow RPC responses
- See `transactions_monad_before_optimization.md` for benchmark data

### keeperProfit() Optimization (2024-12-15) - SUPERSEDED
- **ArbitrageAUSD**: `0x1ac3741941f8a4dfe99274d78826998b4b02e671`
- **ArbitrageUSDC**: `0xc2e5ec965af80916eacfc28cae63e3bd85d195e1`
- Feature: `keeperProfit()` view function (10-tick depth vs 50)
- Feature: Async broadcasts (tokio::spawn for fire-and-forget)

### Precision Buffer Fix v6 (2024-12-15) - SUPERSEDED
- **ArbitrageAUSD**: `0xa75D4879cE4E3C06eDcbfe81C39fb8D531e7ffdA`
- **ArbitrageUSDC**: `0xf621E89D09D7c65b041B1557534B25BC5B8d9cd8`
- Fix: Price limit margin 0.07% → 0.1%
- Fix: Quantity buffer 0.3% → 0.4%
- Still reverted on partial fills due to sqrtPriceLimit

### Price Limit Fix v7 (2024-12-15) - SUPERSEDED
- **ArbitrageAUSD**: `0x602410f69c9ec48cfcb3c5030d46a93f0180bc6b`
- **ArbitrageUSDC**: `0xcba9708114edbc3eba7e85c941cdaec75ace63e2`
- Fix: Price limit margin 0.1% → 0.2% (9980/10000)
- Addresses partial fill precision reverts

### Price Limit Fix v7 (2024-12-15) - ACTIVE
- **ArbitrageAUSD**: `0x1E45ba2e6d56282a1F0d6A9E2147E5199eF0B913`
- **ArbitrageUSDC**: `0xFF9aB730d101e5634eE133C0436E247f3520FefF`
- Fix: Price limit margin 0.1% → 0.2% (9980/10000)
- Addresses partial fill precision reverts

WMON Address: 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A
Pankcake Swap WMON/USDC: 0x63e48B725540A3Db24ACF6682a29f877808C53F2
              AUSD/WMON: 0xD5b70d70CBE6C42bCD1aaa662A21673A83f4615b
              WBTC/WMON: 0x0944526D2727B532653E6Ca6c4D980461E170a09
              AUSD/USDC: 0xD5b70d70CBE6C42bCD1aaa662A21673A83f4615b