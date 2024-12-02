# TeaREX

This repository contains the smart contracts for the TeaREX, a spot leverage trading platform.

## Introduction

TeaREX is spot margin trading platform, allowing users to deposit collateral and utilize funds from the lending pool to enhance capital efficiency when trading target assets. TeaREX's is composed of two main components: the trading core and the lending pools.

### Lending Pools

In the lending pool, liquidity providers can deposit their idle funds and earn interest income when margin traders utilize these funds for trading.

- There will be multiple lending pools based on trading needs. For example, longing ETH/USDC requires a USDC pool, while shorting requires an ETH pool.
- Lending pools support different interest rate models. Currently, a variable interest rate model has been implemented, which automatically adjusts the interest rate based on the pool's fund utilization rate.
- Through the lending router, interactions with the lending pool are made based on the asset and interest rate model.

#### Trader

- Pay interest to the lending pool based on the amount of capital used.
- Pay protocol fee calculated in a fixed annual rate to the treasury based on the amount of capital used.

#### Liquidity Provider

- Earned interest is calculated based on the interest rate model and will distribute to liquidity providers pro rata.
- When a loan position used for trading is liquidated and the assets are insufficient to cover the debt, any unpaid protocol fees will first absorb the loss. If there is still remaining bad debt, the entire lending pool will bear the remaining loss.

### Trading Core

Trading core is the entry for trading-related operations. Traders can use their collateral to make leverage trades on various targets and also manage/check the conditions for passive position closures, including take-profit, stop-loss, and liquidation.

- Using a unified pricing interface, it supports various types of quotations, including ordinary oracles and even the TWAP (Time-Weighted Average Price) from liquidity pools.
- Using a specially designed swap relayer, it supports universal swaps, allowing traders to perform swaps through various swap routers to minimize price impact.

#### Operations

Here's several operations of trading actions. We defined some notations to elaborate each operation.

1. Asset $A$: asset held by a position, e.g. borrow ETH and sell it to USDC to short ETH/USDC, $A$ is USDC.
2. Debt $D$: debt owed by a position, e.g. borrow ETH and sell it to USDC to short ETH/USDC, $D$ is ETH.
3. Margin $M$: margin deposited by the trader for the position, e.g. provide USDC as margin, borrow ETH and sell it to USDC to short ETH/USDC, $M$ is USDC.
4. Price function $P$: function of token price in a anchor token.
5. Relative price function: $P_{a,b}$: token a price in token b, that is $P(a)/P(b)$.
6. Value function $v$: value of tokens held by the position.
7. Loss ratio $LR$: the difference between $A$ and $D$ as a proportion of $M$.

##### Open Position

1. $LR$ must lower than a pre-set threshold of the market.
2. Leverage must lower than a pre-set limit of the market.
3. Total position size must under a pre-set cap of the market.
4. Pay a portion of swap source token to the platform treasury as the trading fee. E.g. Swapping ETH to USDC when opening a short ETH/USDC position, a fixed percent of ETH will be charge from the position.
5. Mint an NFT as a proof of the position.

```solidity
function openPosition
```

##### Modify Take-profit and Stop-loss Price

1. Take-profit price must greater than $P_{A,D}$.
2. Stop-loss price must less than $P_{A,D}$.

```solidity
function modifyPassiveClosePrice
```

##### Add Margin

1. Add margin to lower the risk of liquidation.
2. Maintain a lower $LR$ such that $LR$ of a position less than a pre-set liquidation threshold of the market.

```solidity
function addMargin
```

##### Close Position

1. Actively close a position by the position owner, i.e. trader itself.
2. Should not close with potentional risk of being not able to repay the debt.
3. Pay a portion of swap source token to the platform treasury as the trading fee. E.g. Swapping USDC to ETH when closing a short ETH/USDC position, a fixed percent of USDC will be charge from the position.

```solidity
function closePosition
```

##### Take Profit

1. Passively close a position when the price condition is met.
2. Should not close with potentional risk of being not able to repay the debt.
3. Swap rate must not less than the pre-set take-profit price.
4. Pay a portion of swap source token to the platform treasury as the trading fee. E.g. Swapping USDC to ETH when closing a short ETH/USDC position, a fixed percent of USDC will be charge from the position.

```solidity
function takeProfit
```

##### Stop Loss

1. Passively close a position when the price condition is met.
2. Should not close with potentional risk of being not able to repay the debt.
3. Swap rate must not less than the oracle price.
4. Pay a portion of swap source token to the platform treasury as the trading fee. E.g. Swapping USDC to ETH when closing a short ETH/USDC position, a fixed percent of USDC will be charge from the position.

```solidity
function stopLoss
```

##### Liquidate

1. Passively close a position when the price condition is met.
2. Swap rate must not less than the oracle price with a pre-set liquidation discount.
3. Pay a portion of swap source token to the platform treasury as the trading fee and the additional liquidation fee. E.g. Swapping USDC to ETH when closing a short ETH/USDC position, a fixed percent plus an additional percent of USDC will be charge from the position.

```solidity
function liquidate
```

## Contract Code

### Installation

Use `npm install` to install required packages.

### Configuration

Copy `.env.example` to `.env` and change relevant settings.

### Deployment

1. Deploy lending-related contracts
    - Deploy interest rate model
    - Deploy pool beacon
    - Deploy router
        - Set trading core address after it's deployed.
        - Set fee config
        - Set interest rate model
        - Set whitelisted operators (optional)
        - Create lending pool
2. Deploy trading-related contracts
    - Deploy fee plugin (optional)
    - Deploy calldata processor (optional)
    - Deploy swap relayer
        - Disable/enable whitelist mechanism (optional)
        - Set whitelisted swap routers (optional)
    - Deploy oracle
        - Enable supported asset (optional)
    - Deploy market beacon
    - Deploy trading core
        - Set whitelisted operators (optional)
        - Set fee config
        - Set fee plugin
        - Set up liquidity pool for swap elsewhere (optional)
        - Create market

### Test

- Use `npx hardhat test` to run unit tests under `test` folder.
- Use `npx hardhat run scripts/helperLibTest.js` to run tests under `script` folder.

## Licensing

All primary contracts including interfaces, libraries and contract implementations for TeaREX are the Business Source License 1.1 (BUSL-1.1), which are declared in their SPDX header.
