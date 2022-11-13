import BigNumber from "bignumber.js";

export interface UserReserveData {
  scaledATokenBalance: BigNumber;
  currentATokenBalance: BigNumber;
  currentStableDebt: BigNumber;
  currentVariableDebt: BigNumber;
  principalStableDebt: BigNumber;
  scaledVariableDebt: BigNumber;
  liquidityRate: BigNumber;
  stableBorrowRate: BigNumber;
  stableRateLastUpdated: BigNumber;
  usageAsCollateralEnabled: Boolean;
  walletBalance: BigNumber;
  [key: string]: BigNumber | string | Boolean;
}

export interface UserAccountData {
  totalCollateralETH: BigNumber;
  totalDebtETH: BigNumber;
  availableBorrowsETH: BigNumber;
  currentLiquidityThreshold: BigNumber;
  ltv: BigNumber;
  healthFactor: BigNumber;
}

export enum RateMode {
  None = "0",
  Stable = "1",
  Variable = "2",
}

export interface UserSuppliedData {
  asset: string;
  tranche: string;
  currentATokenBalance: BigNumber;
  usageAsCollateralEnabled: Boolean;
}

export interface UserBorrowedData {
  asset: string;
  tranche: string;
  currentVariableDebt: BigNumber;
}

export interface ReserveData {
  availableLiquidity: BigNumber;
  totalSupplied: BigNumber;
  totalStableDebt: BigNumber;
  totalVariableDebt: BigNumber;
  liquidityRate: BigNumber;
  variableBorrowRate: BigNumber;
  stableBorrowRate: BigNumber;
  averageStableBorrowRate: BigNumber;
  liquidityIndex: BigNumber;
  variableBorrowIndex: BigNumber;
  lastUpdateTimestamp: BigNumber;
}

export interface ReserveDataBase {
  configuration: BigNumber;
  liquidityIndex: BigNumber;
  variableBorrowIndex: BigNumber;
  currentLiquidityRate: BigNumber;
  currentVariableBorrowRate: BigNumber;
  currentStableBorrowRate: BigNumber;
  lastUpdateTimestamp: BigNumber;
  aTokenAddress: BigNumber;
  stableDebtTokenAddress: BigNumber;
  variableDebtTokenAddress: BigNumber;
  interestRateStrategyAddress: BigNumber;
  id: BigNumber;
  trancheId: BigNumber;
}
