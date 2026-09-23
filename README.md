# ChainlinkCrosschainLending

A minimal money market that combines three Chainlink services to do things a single-chain, single-oracle
lending protocol can't:

- **[Data Feeds](https://docs.chain.link/data-feeds)** price both the collateral and debt asset, so
  borrow limits and liquidations are driven by real market prices instead of a static exchange rate.
- **[Automation](https://docs.chain.link/chainlink-automation)** watches every open position and
  liquidates the first one that falls below its health-factor threshold — no off-chain bot or keeper
  infrastructure required.
- **[CCIP](https://docs.chain.link/ccip)** lets collateral that lives on one chain be deposited into this
  market on another chain, via a single "programmable token transfer" message that carries both the
  tokens and the depositor's address.

This is a portfolio project, not an audited protocol — see [Scope & limitations](#scope--limitations)
for what's intentionally left out and why.

## Architecture

```
                         ┌─────────────────────┐
                         │   PriceFeedOracle    │
                         │  (Data Feeds wrapper)│
                         └──────────┬───────────┘
                                    │ getPrice() / usdValue()
                                    ▼
┌──────────────────┐      ┌─────────────────────┐      ┌───────────────────────────┐
│ LiquidationAutom- │◄────►│     LendingPool      │◄────►│ CrossChainCollateralRouter │
│ ation (Automation)│      │  (deposit / borrow /  │      │          (CCIP)           │
│                   │      │   repay / liquidate)  │      │                            │
└──────────────────┘      └─────────────────────┘      └──────────────┬─────────────┘
                                                                        │ CCIP message
                                                                        │ (tokens + sender)
                                                            ┌───────────▼─────────────┐
                                                            │ CrossChainCollateralRouter│
                                                            │      (other chain)        │
                                                            └────────────┬─────────────┘
                                                                         ▼
                                                              LendingPool (other chain)
```

| Contract | Role |
|---|---|
| [`src/PriceFeedOracle.sol`](src/PriceFeedOracle.sol) | Wraps `AggregatorV3Interface` per asset, normalizes every feed to 1e18, and rejects a stale, incomplete, or non-positive round rather than passing bad data through. |
| [`src/LendingPool.sol`](src/LendingPool.sol) | Single-collateral, single-debt-asset market: supply liquidity, deposit collateral, borrow up to 75% LTV, repay, and liquidate positions whose health factor drops below 1.0 (80% liquidation threshold, 10% liquidation bonus). |
| [`src/LiquidationAutomation.sol`](src/LiquidationAutomation.sol) | A Chainlink Automation-compatible upkeep. `checkUpkeep` is simulated off-chain by Automation nodes, so it can afford to scan every open borrower; it hands the first unsafe one to `performUpkeep`, which liquidates it on-chain using a reserve of debt tokens the owner funds. |
| [`src/CrossChainCollateralRouter.sol`](src/CrossChainCollateralRouter.sol) | Deployed on every connected chain. Locks collateral and sends it, plus the depositor's address, in one CCIP message to the router on another chain, which deposits it into that chain's `LendingPool` on the user's behalf. Peers are explicitly allowlisted by (chain selector, sender address). |

## Why these design choices

- **Both priced assets, not just collateral.** Borrow limits and liquidations use `oracle.usdValue()` for
  *both* the collateral and debt token, not just collateral against an assumed $1 debt peg — this is what
  actually breaks if a feed goes stale or a price moves, so it's worth getting the pattern right even in
  a demo.
- **`checkUpkeep` is unbounded on purpose.** Automation nodes simulate `checkUpkeep` off-chain at no gas
  cost to the contract, so an O(n) scan over borrowers is a legitimate pattern at demo scale — the
  constraint that actually matters is keeping `performUpkeep` (the part that runs on-chain) doing
  constant, bounded work, which it does. A production upkeep serving thousands of borrowers would page
  through them via `checkData` instead of scanning the full set every time.
- **The Automation contract holds its own liquidation capital.** Rather than a flash-liquidation pattern,
  `LiquidationAutomation` is funded with a reserve of the debt token up front and repays borrowers'
  debt from it directly, keeping the seized collateral for the owner to withdraw. This mirrors real
  Chainlink Automation liquidation-bot examples and keeps `performUpkeep` simple and cheap.
- **CCIP uses a programmable token transfer, not a bare message.** The collateral token and the
  depositor's address travel together in one `ccipSend` call; `_ccipReceive` on the destination trusts
  only allowlisted (chain selector, sender) pairs before crediting anyone's collateral balance.

## Scope & limitations

This repo intentionally leaves out a few things a production money market would need, to keep the code's
surface area focused on the three Chainlink integrations above:

- **No interest accrual.** Borrowing is 0% APR. Adding compounding interest correctly (and testing the
  accrual math under liquidation) is a project of its own; out of scope here.
- **18-decimal assets only.** `PriceFeedOracle` and `LendingPool` assume both tokens use 18 decimals
  (WETH/DAI-style). A production version would read `IERC20Metadata.decimals()` per token and normalize.
- **Single collateral / single debt asset per pool.** No cross-asset baskets or isolated multi-market
  design.
- **Bad-debt handling is minimal.** If a borrower's collateral is worth less than a liquidator's
  bonus-adjusted entitlement, `liquidate()` caps the seizure at whatever collateral remains rather than
  socializing the shortfall across suppliers — see the comment on `LendingPool.liquidate`.

## Testing

Everything runs locally against real (non-mocked-away) Chainlink contracts — `MockV3Aggregator` for Data
Feeds and [`@chainlink/local`](https://github.com/smartcontractkit/chainlink-local)'s
`CCIPLocalSimulator` for CCIP, so the tests exercise actual `AggregatorV3Interface`, `IRouterClient`, and
`CCIPReceiver` code paths rather than hand-rolled fakes.

```bash
forge install   # if lib/forge-std isn't already present
npm install      # pulls @chainlink/contracts, @chainlink/contracts-ccip, @chainlink/local, OpenZeppelin
forge test -vv
forge coverage --report summary
```

32 tests across `PriceFeedOracle`, `LendingPool`, `LiquidationAutomation`, and
`CrossChainCollateralRouter` (including a full local CCIP round trip: lock → send → receive → credit
collateral, plus a rejected-sender and a rejected-destination case).

## Deploying to testnets

`script/Deploy.s.sol` deploys the full stack from environment variables — no addresses are hardcoded in
this repo, since Chainlink's router and feed addresses do change over time. Pull the current ones for
your target networks right before deploying:

- CCIP router addresses & chain selectors: <https://docs.chain.link/ccip/directory>
- Data Feed addresses: <https://docs.chain.link/data-feeds/price-feeds/addresses>
- LINK token addresses: <https://docs.chain.link/resources/link-token-contracts>

```bash
cp .env.example .env   # fill in PRIVATE_KEY and the addresses above for chain A
source .env
forge script script/Deploy.s.sol --rpc-url $RPC_URL_A --broadcast

# repeat for chain B with its own .env, then on each router call the wiring functions
# the script prints at the end (setDestinationChainAllowed / setSourceAllowed)
```

After deploying:

1. Register `LiquidationAutomation` as a [custom logic upkeep](https://automation.chain.link), funded
   with LINK.
2. Fund its liquidation reserve: `debtToken.approve(automation, amount)` then
   `automation.fundReserve(amount)`.
3. Wire the two `CrossChainCollateralRouter` deployments together (chain selectors from the CCIP
   directory above):
   ```solidity
   routerA.setDestinationChainAllowed(chainSelectorB, true);
   routerB.setSourceAllowed(chainSelectorA, address(routerA), true);
   ```

## Stack

[Foundry](https://book.getfoundry.sh/) · Solidity 0.8.24 · `@chainlink/contracts` 1.5.0 ·
`@chainlink/contracts-ccip` 2.0.0 · `@chainlink/local` 0.2.9 · OpenZeppelin Contracts 5.7.0
