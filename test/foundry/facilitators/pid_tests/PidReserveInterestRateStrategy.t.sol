// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "test/helpers/TestAsUSDAndLendAndStaking.sol";

contract PidReserveInterestRateStrategyAsUsdTest is TestAsUSDAndLendAndStaking {
    address[] users;

    string path = "./test/foundry/facilitators/pid_tests/datas/output.csv";
    uint256 nbUsers = 4;
    uint256 initialAmt = 1e12 ether;
    uint256 DEFAULT_TIME_BEFORE_OP = 6 hours;
    int256 counterAssetPrice = int256(1 * 10 ** PRICE_FEED_DECIMALS);

    function setUp() public override {
        super.setUp();

        /// users
        for (uint256 i = 0; i < nbUsers; i++) {
            users.push(vm.addr(i + 1));
            for (uint256 j = 0; j < erc20Tokens.length; j++) {
                if (address(erc20Tokens[j]) != address(asUsd)) {
                    deal(address(erc20Tokens[j]), users[i], initialAmt);
                }
            }
        }

        /// Mint counter asset and approve Balancer vault
        for (uint256 i = 0; i < nbUsers; i++) {
            ERC20Mock(address(counterAsset)).mint(users[i], initialAmt);
            vm.startPrank(users[i]);
            ERC20Mock(address(counterAsset)).approve(address(tRouter), type(uint256).max);
            ERC20Mock(address(asUsd)).approve(address(tRouter), type(uint256).max);
            ERC20(address(poolAdd)).approve(address(tRouter), type(uint256).max);
            vm.stopPrank();
        }

        ERC20Mock(address(counterAsset)).approve(address(tRouter), type(uint256).max);
        ERC20Mock(address(asUsd)).approve(address(tRouter), type(uint256).max);
        ERC20(address(poolAdd)).approve(address(tRouter), type(uint256).max);

        /// file setup
        if (vm.exists(path)) vm.removeFile(path);
        vm.writeLine(
            path, "timestamp,user,action,asset,stablePoolBalance,currentVariableBorrowRate"
        );
    }

    function testTF() public view {
        console2.logUint(asUsdInterestRateStrategy.transferFunction(-400e24) / (1e27 / 10000)); // bps
    }

    // 4 users  (users[0], users[1], users[2], users[3])
    // 4 tokens (wbtc, eth, dai, asUsd)
    // Initial Balancer Pool asUSD/CounterAsseter balance is 10M/10M.
    function testPid() public {
        ERC20 wbtc = erc20Tokens[0]; // wbtcPrice =  670000,0000000$
        ERC20 eth = erc20Tokens[1]; // ethPrice =  3700,00000000$
        ERC20 dai = erc20Tokens[2]; // daiPrice =  1,00000000$
        ERC20 asusd = erc20Tokens[3]; // asUsdPrice =  1,00000000$

        deposit(users[0], wbtc, 2e8);
        deposit(users[1], wbtc, 20_000e8);
        deposit(users[1], dai, 100_000e18);

        borrow(users[1], asusd, 12_000_000e18);

        plateau(20);
        swapBalancer(users[1], asusd, 5_000_000e18);
        plateau(20);
        swapBalancer(users[1], asusd, 5_000_000e18);
        plateau(20);
        swapBalancer(users[1], counterAsset, 5_000_000e18);
        plateau(20);
        swapBalancer(users[1], counterAsset, 5_000_000e18);
        plateau(20);
        swapBalancer(users[1], counterAsset, 5_000_000e18);
        plateau(20);
        swapBalancer(users[1], counterAsset, 5_000_000e18);
        plateau(100);
        swapBalancer(users[1], asusd, 5_000_000e18);
        plateau(20);
        swapBalancer(users[1], asusd, 5_000_000e18);
        plateau(20);
        swapBalancer(users[1], asusd, 5_000_000e18);
        plateau(200);
        repay(users[1], asusd, 100_000e18);

        // counterAssetPrice = int256(2 * 10 ** PRICE_FEED_DECIMALS); //! counter asset deppeg
    }
    // ------------------------------
    // ---------- Helpers -----------
    // ------------------------------

    function deposit(address user, ERC20 asset, uint256 amount) internal {
        vm.startPrank(user);
        asset.approve(address(deployedContracts.lendingPool), amount);
        deployedContracts.lendingPool.deposit(
            address(asset), address(asset) == address(asUsd) ? false : true, amount, user
        );
        vm.stopPrank();
        logg(user, 0, address(asset));
        logCash();
        counterAssetPriceFeed.updateAnswer(counterAssetPrice); // needed to update the lastTimestamp.
        skip(DEFAULT_TIME_BEFORE_OP);
    }

    function borrow(address user, ERC20 asset, uint256 amount) internal {
        vm.startPrank(user);
        deployedContracts.lendingPool.borrow(
            address(asset), address(asset) == address(asUsd) ? false : true, amount, user
        );
        vm.stopPrank();
        logg(user, 1, address(asset));
        logCash();
        counterAssetPriceFeed.updateAnswer(counterAssetPrice); // needed to update the lastTimestamp.
        skip(DEFAULT_TIME_BEFORE_OP);
    }

    function borrowWithoutSkip(address user, ERC20 asset, uint256 amount) internal {
        vm.startPrank(user);
        deployedContracts.lendingPool.borrow(
            address(asset), address(asset) == address(asUsd) ? false : true, amount, user
        );
        vm.stopPrank();
        logCash();
        counterAssetPriceFeed.updateAnswer(counterAssetPrice); // needed to update the lastTimestamp.
        logg(user, 1, address(asset));
    }

    function withdraw(address user, ERC20 asset, uint256 amount) internal {
        vm.startPrank(user);
        deployedContracts.lendingPool.withdraw(
            address(asset), address(asset) == address(asUsd) ? false : true, amount, user
        );
        vm.stopPrank();
        logg(user, 2, address(asset));
        logCash();
        counterAssetPriceFeed.updateAnswer(counterAssetPrice); // needed to update the lastTimestamp.
        skip(DEFAULT_TIME_BEFORE_OP);
    }

    function repay(address user, ERC20 asset, uint256 amount) internal {
        vm.startPrank(user);
        asset.approve(address(deployedContracts.lendingPool), amount);
        deployedContracts.lendingPool.repay(
            address(asset), address(asset) == address(asUsd) ? false : true, amount, user
        );
        vm.stopPrank();
        logg(user, 3, address(asset));
        logCash();
        counterAssetPriceFeed.updateAnswer(counterAssetPrice); // needed to update the lastTimestamp.
        skip(DEFAULT_TIME_BEFORE_OP);
    }

    function plateau(uint256 period) public {
        for (uint256 i = 0; i < period; i++) {
            vm.startPrank(users[0]);
            deployedContracts.lendingPool.borrow(
                address(erc20Tokens[3]),
                address(erc20Tokens[3]) == address(asUsd) ? false : true,
                1,
                users[0]
            );
            vm.stopPrank();
            logg(users[0], 1, address(erc20Tokens[3]));
            counterAssetPriceFeed.updateAnswer(counterAssetPrice); // needed to update the lastTimestamp.
            skip(DEFAULT_TIME_BEFORE_OP);

            vm.startPrank(users[0]);
            erc20Tokens[3].approve(address(deployedContracts.lendingPool), 1);
            deployedContracts.lendingPool.repay(
                address(erc20Tokens[3]),
                address(erc20Tokens[3]) == address(asUsd) ? false : true,
                1,
                users[0]
            );
            vm.stopPrank();
            logg(users[0], 3, address(erc20Tokens[3]));
            counterAssetPriceFeed.updateAnswer(counterAssetPrice); // needed to update the lastTimestamp.
            skip(DEFAULT_TIME_BEFORE_OP);
        }
    }

    function swapBalancer(address user, ERC20 assetIn, uint256 amt) public {
        vm.startPrank(user);
        tRouter.swapSingleTokenExactIn(
            poolAdd,
            IERC20(address(assetIn)),
            address(assetIn) == address(asUsd)
                ? IERC20(address(counterAsset))
                : IERC20(address(asUsd)),
            amt,
            0
        );
        vm.stopPrank();
    }

    function setManualInterestRate(uint256 manualInterestRate) public {
        asUsdInterestRateStrategy.setManualInterestRate(manualInterestRate);
    }

    function setErrI(int256 newErrI) public {
        asUsdInterestRateStrategy.setErrI(newErrI);
    }

    function logg(address user, uint256 action, address asset) public {
        (, uint256 currentVariableBorrowRate,) =
            asUsdInterestRateStrategy.getCurrentInterestRates();

        (IERC20[] memory tokens_,,, uint256[] memory lastBalancesLiveScaled18_) =
            IVault(vaultV3).getPoolTokenInfo(poolAdd);

        uint256 cashAsusd = lastBalancesLiveScaled18_[indexAsUsd];

        uint256 stablePoolBalance = cashAsusd * 1e27 / INITIAL_ASUSD_AMT;

        string memory data = string(
            abi.encodePacked(
                Strings.toString(block.timestamp),
                ",",
                Strings.toHexString(user),
                ",",
                Strings.toString(action),
                ",",
                Strings.toHexString(asset),
                ",",
                Strings.toString(stablePoolBalance), //!
                ",",
                Strings.toString(currentVariableBorrowRate)
            )
        );

        vm.writeLine(path, data);
    }

    function logCash() public view {
        (IERC20[] memory tokens_,,, uint256[] memory lastBalancesLiveScaled18_) =
            IVault(vaultV3).getPoolTokenInfo(poolAdd);

        uint256 cashAsusd = lastBalancesLiveScaled18_[indexAsUsd];
        uint256 cashCa = lastBalancesLiveScaled18_[indexCounterAsset];

        // console2.log("cash asUSD : ", cashAsusd);
        // console2.log("cash counter: ", cashCa);
        // console2.log("---");
    }
}
