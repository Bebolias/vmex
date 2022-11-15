// SPDX-License-Identifier: agpl-3.0
pragma solidity >=0.8.0;

import {SafeMath} from "../../../dependencies/openzeppelin/contracts/SafeMath.sol";
import {IERC20} from "../../../dependencies/openzeppelin/contracts/IERC20.sol";
import {WadRayMath} from "../math/WadRayMath.sol";
import {PercentageMath} from "../math/PercentageMath.sol";
import {SafeERC20} from "../../../dependencies/openzeppelin/contracts/SafeERC20.sol";
import {ReserveConfiguration} from "../configuration/ReserveConfiguration.sol";
import {UserConfiguration} from "../configuration/UserConfiguration.sol";
import {Errors} from "../helpers/Errors.sol";
import {IReserveInterestRateStrategy} from "../../../interfaces/IReserveInterestRateStrategy.sol";
import {DataTypes} from "../types/DataTypes.sol";
import {ReserveLogic} from "./ReserveLogic.sol";
import {ValidationLogic} from "./ValidationLogic.sol";
import {IAToken} from "../../../interfaces/IAToken.sol";
import {IPriceOracleGetter} from "../../../interfaces/IPriceOracleGetter.sol";
import {IStableDebtToken} from "../../../interfaces/IStableDebtToken.sol";
import {IVariableDebtToken} from "../../../interfaces/IVariableDebtToken.sol";
import {IFlashLoanReceiver} from "../../../flashloan/interfaces/IFlashLoanReceiver.sol";
import {ILendingPoolAddressesProvider} from "../../../interfaces/ILendingPoolAddressesProvider.sol";
import {GenericLogic} from "./GenericLogic.sol";
import {AssetMappings} from "../../lendingpool/AssetMappings.sol";
/**
 * @title DepositWithdrawLogic library
 * @author VMEX
 * @notice Implements functions to deposit and withdraw
 */
library DepositWithdrawLogic {
    using SafeMath for uint256;
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using SafeERC20 for IERC20;
    using ReserveLogic for *;
    using UserConfiguration for *;
    using ReserveConfiguration for *;

    /**
     * @dev Emitted on setUserUseReserveAsCollateral()
     * @param reserve The address of the underlying asset of the reserve
     * @param user The address of the user enabling the usage as collateral
     **/
    event ReserveUsedAsCollateralEnabled(
        address indexed reserve,
        address indexed user
    );

    /**
     * @dev Emitted on deposit()
     * @param reserve The address of the underlying asset of the reserve
     * @param user The address initiating the deposit
     * @param onBehalfOf The beneficiary of the deposit, receiving the aTokens
     * @param amount The amount deposited
     * @param referral The referral code used
     **/
    event Deposit(
        address indexed reserve,
        uint64 trancheId,
        address user,
        address indexed onBehalfOf,
        uint256 amount,
        uint16 indexed referral
    );

    function _deposit(
        DataTypes.ReserveData storage self,
        DataTypes.DepositVars memory vars,
        DataTypes.UserConfigurationMap storage user
    ) external {
        ValidationLogic.validateDeposit(self, vars.amount);

        address aToken = self.aTokenAddress;

        // if (assetData.isLendable) {
        //these will simply not be used for collateral vault, and even if it is, it won't change anything, so this will just save gas
        self.updateInterestRates(vars.asset, aToken, vars.amount, 0);
        self.updateState();
        {
            address oracle = ILendingPoolAddressesProvider(vars._addressesProvider).getPriceOracle(
                        AssetMappings(ILendingPoolAddressesProvider(vars._addressesProvider).getAssetMappings()).getAssetType(vars.asset)
                    );
            IPriceOracleGetter(oracle).updateTWAP(vars.asset);
        }

        // }

        IERC20(vars.asset).safeTransferFrom(msg.sender, aToken, vars.amount); //msg.sender should still be the user, not the contract

        bool isFirstDeposit = IAToken(aToken).mint(
            vars.onBehalfOf,
            vars.amount,
            self.liquidityIndex
        ); //this also considers if it is a first deposit into a trancheId, not just a specific asset

        if (isFirstDeposit) {
            user.setUsingAsCollateral(self.id, true); //default collateral is true
        }

        emit Deposit(
            vars.asset,
            vars.trancheId,
            msg.sender,
            vars.onBehalfOf,
            vars.amount,
            vars.referralCode
        );
    }

    /**
     * @dev Emitted on setUserUseReserveAsCollateral()
     * @param reserve The address of the underlying asset of the reserve
     * @param user The address of the user enabling the usage as collateral
     **/
    event ReserveUsedAsCollateralDisabled(
        address indexed reserve,
        address indexed user
    );

    /**
     * @dev Emitted on withdraw()
     * @param reserve The address of the underlyng asset being withdrawn
     * @param user The address initiating the withdrawal, owner of aTokens
     * @param to Address that will receive the underlying
     * @param amount The amount to be withdrawn
     **/
    event Withdraw(
        address indexed reserve,
        address indexed user,
        address indexed to,
        uint256 amount
    );

    function _withdraw(
        mapping(address => mapping(uint64 => DataTypes.ReserveData))
            storage _reserves,
        DataTypes.UserConfigurationMap storage user,
        mapping(uint256 => address) storage _reservesList,
        DataTypes.WithdrawParams memory vars,
        ILendingPoolAddressesProvider _addressesProvider
    ) public returns (uint256) {
        DataTypes.ReserveData storage reserve = _reserves[vars.asset][
            vars.trancheId
        ];
        address aToken = reserve.aTokenAddress;

        uint256 userBalance = IAToken(aToken).balanceOf(msg.sender);
        //balanceOf actually multiplies the atokens that the user has by the liquidity index.
        //User A deposits 1000 DAI at the liquidity index of 1.1. He is actually minted 1000/1.1 = 909 scaled aTokens. But when he checks his balance, he finds 909 *1.1 = 1000
        //User B deposits another amount into the same pool. The liquidity index is now 1.2. User A now checks 909*1.2 = 1090.9, so he gets "interest" despite his scaled aTokens remaining the same
        //liquidityIndex is not 1 to 1 with pool amount. So there are additional funds left in pool in above case.

        if (vars.amount == type(uint256).max) {
            vars.amount = userBalance; //amount to withdraw
        }

        ValidationLogic.validateWithdraw(
            vars.asset,
            vars.trancheId,
            vars.amount,
            userBalance,
            _reserves,
            user,
            _reservesList,
            vars._reservesCount,
            _addressesProvider
        );

        reserve.updateInterestRates(vars.asset, aToken, 0, vars.amount);
        reserve.updateState();

        {
            address oracle = ILendingPoolAddressesProvider(_addressesProvider).getPriceOracle(
                        AssetMappings(_addressesProvider.getAssetMappings()).getAssetType(vars.asset)
                    );
            IPriceOracleGetter(oracle).updateTWAP(vars.asset);
        }

        if (vars.amount == userBalance) {
            user.setUsingAsCollateral(reserve.id, false);
            emit ReserveUsedAsCollateralDisabled(vars.asset, msg.sender);
        }

        IAToken(aToken).burn(
            msg.sender,
            vars.to,
            vars.amount,
            reserve.liquidityIndex
        );

        emit Withdraw(vars.asset, msg.sender, vars.to, vars.amount);

        return vars.amount;
    }

    /**
     * @dev Emitted on borrow() and flashLoan() when debt needs to be opened
     * @param reserve The address of the underlying asset being borrowed
     * @param user The address of the user initiating the borrow(), receiving the funds on borrow() or just
     * initiator of the transaction on flashLoan()
     * @param onBehalfOf The address that will be getting the debt
     * @param amount The amount borrowed out
     * @param borrowRateMode The rate mode: 1 for Stable, 2 for Variable
     * @param borrowRate The numeric rate at which the user has borrowed
     * @param referral The referral code used
     **/
    event Borrow(
        address indexed reserve,
        address user,
        address indexed onBehalfOf,
        uint256 amount,
        uint256 borrowRateMode,
        uint256 borrowRate,
        uint16 indexed referral
    );

    function _borrowHelper(
        mapping(address => mapping(uint64 => DataTypes.ReserveData))
            storage _reserves,
        mapping(uint256 => address) storage _reservesList,
        DataTypes.UserConfigurationMap storage userConfig,
        ILendingPoolAddressesProvider _addressesProvider,
        DataTypes.ExecuteBorrowParams memory vars
    ) public {
        {
            address oracle = ILendingPoolAddressesProvider(_addressesProvider).getPriceOracle(
                        AssetMappings(_addressesProvider.getAssetMappings()).getAssetType(vars.asset)
                    );
            IPriceOracleGetter(oracle).updateTWAP(vars.asset);
        }
        
        DataTypes.ReserveData storage reserve = _reserves[vars.asset][
            vars.trancheId
        ];

        //The mocks are in ETH, but when deploying to mainnet we probably want to convert to USD
        //This is really amount in WEI. getAssetPrice gets the asset price in wei
        //The units are consistent. The reserve decimals will be the lp token decimals (usually 18). Then it's basically like multiplying some small 1.02 or some factor to the geometric mean wei price. By dividing by 10**decimals we are getting back wei.

        uint256 amountInETH = IPriceOracleGetter( //if we change the address of the oracle to give the price in usd, it should still work
            _addressesProvider.getPriceOracle(
                AssetMappings(_addressesProvider.getAssetMappings()).getAssetType(vars.asset)
            )
        ).getAssetPrice(vars.asset).mul(vars.amount).div(
                10**reserve.configuration.getDecimals()
            ); //lp token decimals are 18, like ETH

        ValidationLogic.validateBorrow(
            vars,
            reserve,
            amountInETH,
            vars._maxStableRateBorrowSizePercent,
            _reserves,
            userConfig,
            _reservesList,
            vars._reservesCount,
            _addressesProvider
        );

        reserve.updateState();

        uint256 currentStableRate = 0;

        bool isFirstBorrowing = false;
        if (
            DataTypes.InterestRateMode(vars.interestRateMode) ==
            DataTypes.InterestRateMode.STABLE
        ) {
            currentStableRate = reserve.currentStableBorrowRate;

            isFirstBorrowing = IStableDebtToken(reserve.stableDebtTokenAddress)
                .mint(
                    vars.user,
                    vars.onBehalfOf,
                    vars.amount,
                    currentStableRate
                );
        } else {
            isFirstBorrowing = IVariableDebtToken(
                reserve.variableDebtTokenAddress
            ).mint(
                    vars.user,
                    vars.onBehalfOf,
                    vars.amount,
                    reserve.variableBorrowIndex
                );
        }

        if (isFirstBorrowing) {
            userConfig.setBorrowing(reserve.id, true);
        }

        reserve.updateInterestRates(
            vars.asset,
            vars.aTokenAddress,
            0,
            vars.releaseUnderlying ? vars.amount : 0
        );

        if (vars.releaseUnderlying) {
            IAToken(vars.aTokenAddress).transferUnderlyingTo(
                vars.user,
                vars.amount
            );
        }

        emit Borrow(
            vars.asset,
            vars.user,
            vars.onBehalfOf,
            vars.amount,
            vars.interestRateMode,
            DataTypes.InterestRateMode(vars.interestRateMode) ==
                DataTypes.InterestRateMode.STABLE
                ? currentStableRate
                : reserve.currentVariableBorrowRate,
            vars.referralCode
        );
    }

    struct FlashLoanLocalVars {
        IFlashLoanReceiver receiver;
        ILendingPoolAddressesProvider oracle;
        uint256 i;
        address currentAsset;
        uint64 currentTranche;
        address currentATokenAddress;
        uint256 currentAmount;
        uint256 currentPremium;
        uint256 currentAmountPlusPremium;
        address debtToken;
    }

    /**
     * @dev Emitted on flashLoan()
     * @param target The address of the flash loan receiver contract
     * @param initiator The address initiating the flash loan
     * @param asset The address of the asset being flash borrowed
     * @param amount The amount flash borrowed
     * @param premium The fee flash borrowed
     * @param referralCode The referral code used
     **/
    // event FlashLoan(
    //     address indexed target,
    //     address indexed initiator,
    //     address indexed asset,
    //     uint64 trancheId,
    //     uint256 amount,
    //     uint256 premium,
    //     uint16 referralCode
    // );

    // function _flashLoan(
    //     DataTypes.flashLoanVars memory callvars,
    //     mapping(address => DataTypes.ReserveAssetType) storage assetDatas,
    //     mapping(address => mapping(uint64 => DataTypes.ReserveData))
    //         storage _reserves,
    //     mapping(uint64 => mapping(uint256 => address)) storage _reservesList,
    //     mapping(uint64 => uint256) storage _reservesCount,
    //     DataTypes.UserConfigurationMap storage userConfig
    // ) external {
    //     FlashLoanLocalVars memory vars;

    //     ValidationLogic.validateFlashloan(callvars.assets, callvars.amounts);

    //     address[] memory aTokenAddresses = new address[](
    //         callvars.assets.length
    //     );
    //     uint256[] memory premiums = new uint256[](callvars.assets.length);

    //     vars.receiver = IFlashLoanReceiver(callvars.receiverAddress);

    //     for (vars.i = 0; vars.i < callvars.assets.length; vars.i++) {
    //         aTokenAddresses[vars.i] = _reserves[callvars.assets[vars.i]][
    //             callvars.trancheId
    //         ].aTokenAddress;

    //         premiums[vars.i] = callvars
    //             .amounts[vars.i]
    //             .mul(callvars._flashLoanPremiumTotal)
    //             .div(10000);

    //         IAToken(aTokenAddresses[vars.i]).transferUnderlyingTo(
    //             callvars.receiverAddress,
    //             callvars.amounts[vars.i]
    //         );
    //     }

    //     require(
    //         vars.receiver.executeOperation(
    //             callvars.assets,
    //             callvars.amounts,
    //             premiums,
    //             msg.sender,
    //             callvars.params
    //         ),
    //         Errors.LP_INVALID_FLASH_LOAN_EXECUTOR_RETURN
    //     );

    //     for (vars.i = 0; vars.i < callvars.assets.length; vars.i++) {
    //         vars.currentAsset = callvars.assets[vars.i];
    //         vars.currentTranche = callvars.trancheId;
    //         vars.currentAmount = callvars.amounts[vars.i];
    //         vars.oracle = ILendingPoolAddressesProvider(
    //             callvars._addressesprovider
    //         );
    //         vars.currentPremium = premiums[vars.i];
    //         vars.currentATokenAddress = aTokenAddresses[vars.i];
    //         vars.currentAmountPlusPremium = vars.currentAmount.add(
    //             vars.currentPremium
    //         );

    //         if (
    //             DataTypes.InterestRateMode(callvars.modes[vars.i]) ==
    //             DataTypes.InterestRateMode.NONE
    //         ) {
    //             _reserves[vars.currentAsset][vars.currentTranche].updateState();
    //             _reserves[vars.currentAsset][vars.currentTranche]
    //                 .cumulateToLiquidityIndex(
    //                     IERC20(vars.currentATokenAddress).totalSupply(),
    //                     vars.currentPremium
    //                 );
    //             _reserves[vars.currentAsset][vars.currentTranche]
    //                 .updateInterestRates(
    //                     vars.currentAsset,
    //                     vars.currentATokenAddress,
    //                     vars.currentAmountPlusPremium,
    //                     0
    //                 );

    //             IERC20(vars.currentAsset).safeTransferFrom(
    //                 callvars.receiverAddress,
    //                 vars.currentATokenAddress,
    //                 vars.currentAmountPlusPremium
    //             );
    //         } else {
    //             // If the user chose to not return the funds, the system checks if there is enough collateral and
    //             // eventually opens a debt position
    //             DataTypes.ExecuteBorrowParams memory borrowvars;
    //             DataTypes.ReserveData storage reserve;
    //             {
    //                 reserve = _reserves[vars.currentAsset][vars.currentTranche];
    //             }
    //             {
    //                 borrowvars = DataTypes.ExecuteBorrowParams(
    //                     vars.currentAsset,
    //                     vars.currentTranche,
    //                     msg.sender,
    //                     callvars.onBehalfOf,
    //                     vars.currentAmount,
    //                     callvars.modes[vars.i],
    //                     reserve.aTokenAddress,
    //                     callvars.referralCode,
    //                     true,
    //                     callvars._maxStableRateBorrowSizePercent,
    //                     _reservesCount[vars.currentTranche]
    //                 );
    //             }
    //             {
    //                 _borrowHelper(
    //                     _reserves,
    //                     _reservesList[vars.currentTranche],
    //                     userConfig,
    //                     assetDatas,
    //                     vars.oracle,
    //                     borrowvars
    //                 );
    //             }
    //         }
    //         emit FlashLoan(
    //             callvars.receiverAddress,
    //             msg.sender,
    //             vars.currentAsset,
    //             callvars.trancheId,
    //             vars.currentAmount,
    //             vars.currentPremium,
    //             callvars.referralCode
    //         );
    //     }
    // }
}