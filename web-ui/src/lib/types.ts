export interface GasEstimation {
  gasLimit: string; // hex
  maxFeePerGas: string; // hex
  maxPriorityFeePerGas: string; // hex
  estimatedGasCost: string; // hex (wei)
  estimatedGasCostEth: string; // decimal string
  totalCost: string; // hex (wei) - gas + value
  totalCostEth: string; // decimal string
  type: "legacy" | "eip1559" | "eip7702";
}
