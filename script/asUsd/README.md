# Astera USD deployment

## Deploy Astera USD

### Default value

Find LayerZero EIDs and Endpoints: https://docs.layerzero.network/v2/developers/evm/technical-reference/deployed-contracts#amoy-testnet

Find chain id and rpc: https://chainlist.org/

```java
address asUsdUniversalAddress = address(0xC0d37000...);
string name = "Astera USD";
string symbol = "asUSD";
address delegate = TBD;
address treasury = TBD;
address guardian = TBD;
address _lzEndpoint = Chain_Dependent;
uint32 eid = Chain_Dependent;
uint256 fee = 0; // unit: BPS (default value)
uint256 hourlyLimit = 30_000e18; // unit: asUSD (default value)
uint256 limit = -100_000e18; // unit: asUSD (default value)
address[] facilitators = [asUsdAToken, amo];
```

### Deployment flow on a chain

- Deploy `asUSD` contract. (`AsUsdDeploy.s.sol`)
- Set hourly limit. (`AsUsdSetLimits.s.sol`)
- Set fee. (`AsUsdFee.s.sol`)
- Set peer for each already deployed chain. (`AsUsdSetPeer.s.sol`)
- Set limit for each chain. (`AsUsdSetLimits.s.sol`)
- Set facilitators. (`AsUsdAddFacilitator.s.sol`)


```bash
forge script script/asUsd/AsUsdDeploy.s.sol --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --etherscan-api-key $ETHEREUM_SCAN_APY_KEY --verify contracts/tokens/AsUSD.sol:AsUSD --broadcast
```


Base deployment:

```bash
forge script script/asUsd/AsUsdDeploy.s.sol --rpc-url $BASE_RPC_URL --private-key $PRIVATE_KEY --etherscan-api-key $BASE_SCAN_APY_KEY --verify contracts/tokens/AsUSD.sol:AsUSD --broadcast
```

```bash
forge script script/TimelockDeploy.s.sol --rpc-url $BASE_RPC_URL --private-key $PRIVATE_KEY --etherscan-api-key $BASE_SCAN_APY_KEY --verify node_modules/@openzeppelin/contracts/governance/TimelockController.sol:TimelockController --broadcast
```