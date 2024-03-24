// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "forge-std/StdUtils.sol";
import "forge-std/StdCheats.sol";
import { IIonPool } from "./interfaces/IIonPool.sol";
import { IGemJoin } from "./interfaces/IGemJoin.sol";
import { ISpotOracle } from "./interfaces/ISpotOracle.sol";
import { IERC20 } from 'forge-std/interfaces/IERC20.sol';
import { IUFDMHandler } from "./interfaces/IUFDMHandler.sol";
import { WadRayMath } from "@ionprotocol/libraries/math/WadRayMath.sol";

using WadRayMath for uint256;

contract HourglassDeleverage is Script, StdCheats {
    // We need to prank the a user that has a borrow position in the ION weETH pool 
    // Find potential borrowers here: https://etherscan.io/address/0x0000000000eaEbd95dAfcA37A39fd09745739b78#events
    address public ionBorrower = 0xa0f75491720835b36edC92D06DDc468D201e9b73; 

    // tx: 0x45da0474cc67c5d067c79400789a7564c8643a46be3dbb92c12ed42a86353e79
    uint8 public ilkIndex = 0; // index for wstETH 
    // Pool address for weETH pool 
    address public ionPoolAddress = 0x0000000000eaEbd95dAfcA37A39fd09745739b78; 
    address public ionPoolGem = 0x3f6119B0328C27190bE39597213ea1729f061876; 
    // address public weethHandlerAddress = 0xAB3c6236327FF77159B37f18EF85e8AC58034479;
    address public wsteth = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    uint256 public newWstethBalance = 1000 ether; // enough to fully repay position 

    IIonPool public ionPool;
    IGemJoin public gemJoin;
    IUFDMHandler public weethHandler; 
    ISpotOracle public spotOracle;

    uint256 public ilkSpot;
    uint256 public ilkRate;

    function formatUnits(uint256 value, uint256 precision) public pure returns (string memory) {
        uint256 base = 10 ** precision;
        uint256 integerPart = value / base;
        uint256 fractionalPart = value % base;
        return string(abi.encodePacked(vm.toString(integerPart), ".", vm.toString(fractionalPart)));
    }

    function run() public {
        // proxy address for ION pool for weETH 
        ionPool = IIonPool(ionPoolAddress);
        gemJoin = IGemJoin(ionPoolGem);
        // weethHandler = IUFDMHandler(payable(weethHandlerAddress));

        vm.startPrank(ionBorrower);

        console2.log("address(this): ", address(this)); 
        console2.log("User: ", ionBorrower);
        console2.log("------------------------------------------------");

        spotOracle = ionPool.spot(ilkIndex);
        ilkSpot = spotOracle.getSpot(); // spot oracle for collateral with index `ilkIndex`.
        ilkRate = ionPool.rate(ilkIndex); // The rate (debt accumulator) for collateral with index `ilkIndex`.
        uint256 vaultNormalizedDebt0 = ionPool.normalizedDebt(ilkIndex, ionBorrower);
        uint256 vaultCollateral0 = ionPool.collateral(ilkIndex, ionBorrower);

        console2.log("ilk spot: ", formatUnits(ilkSpot, 27));
        console2.log("ilk rate: ", formatUnits(ilkRate, 27));

        console2.log("-------------- Pre Interaction State -----------------"); 

        console2.log("vault normalized debt: ", formatUnits(vaultNormalizedDebt0, 18));
        console2.log("vault collateral: ", formatUnits(vaultCollateral0, 18));
        /*
        In order for a position to be modified, the following invariant must be maintained:
        INVARIANT: ilkRate * vault.normalizedDebt <= _vault.collateral * ilkSpot

        We want to determine what the maximum amount of collateral that can be withdrawn from the vault is.
        SOLVING: 
            ilkRate * vault.normalizedDebt <= (vault.collateral - maxCollateralWithdrawn) * ilkSpot
            ilkRate * vault.normalizedDebt <= vault.collateral * ilkSpot - maxCollateralWithdrawn * ilkSpot
            maxCollateralWithdrawn * ilkSpot <= vault.collateral * ilkSpot - ilkRate * vault.normalizedDebt
            maxCollateralWithdrawn <= vault.collateral - (ilkRate * vault.normalizedDebt) / ilkSpot
        */
        uint256 maxCollateralWithdrawable0 = vaultCollateral0 - (ilkRate * vaultNormalizedDebt0) / ilkSpot - 1; // -1 because of inequality 
        // uint256 deptReductionForCollateralWithdrawal = maxCollateralWithdrawable * ilkSpot / ilkRate;
        // uint256 repayAmountNormalized = maxCollateralWithdrawn.rayDivDown(rate); // units are weETH with WAD precision 
        console2.log("max collateral withdrawable: ", formatUnits(maxCollateralWithdrawable0, 18));

        console2.log("-------------- User Repays 10% of debt -----------------"); 

        // The ION borrower is required to have wstETH in their wallet to repay the debt.
        deal(address(wsteth), ionBorrower, newWstethBalance);
        IERC20 wstethContract = IERC20(wsteth);
        uint256 balanceWsteth = wstethContract.balanceOf(ionBorrower);
        wstethContract.approve(address(ionPoolAddress), ~uint256(0));

        // user wants to delever by withdrawing 10% of collateral, denominated in weETH 
        uint256 userCollateralDeleverageAmount = vaultCollateral0.wadDivDown(10 ether); 
        // this value will be submitted to the market maker via an RFQ and they need to lower bound the amount of wstETH offerred. 
        // the quote provided by the market maker needs to be at least minDebtRepaymentToFacilitateDeleverage. 
        uint256 minDebtRepaymentToFacilitateDeleverage = userCollateralDeleverageAmount * ilkSpot / ilkRate;
        console2.log("user collateral deleverage amount (weETH): ", formatUnits(userCollateralDeleverageAmount, 18));
        console2.log("min debt payment to facilitate deleverage (wstETH): ", formatUnits(minDebtRepaymentToFacilitateDeleverage, 18));
        console2.log("user wstETH balance: ", formatUnits(balanceWsteth, 18));
        console2.log("Implied price for for min dept payment to deleverage: 1 weETH =", formatUnits(
            minDebtRepaymentToFacilitateDeleverage * 1e18 / userCollateralDeleverageAmount, 18
        ), "wstETH");

        ionPool.repay(ilkIndex, ionBorrower, ionBorrower, minDebtRepaymentToFacilitateDeleverage);
        uint256 vaultNormalizedDebt1 = ionPool.normalizedDebt(ilkIndex, ionBorrower);
        uint256 vaultCollateral1 = ionPool.collateral(ilkIndex, ionBorrower);
        uint256 debtDiffActual = vaultNormalizedDebt0 - vaultNormalizedDebt1;
        uint256 maxCollateralWithdrawable1 = vaultCollateral1 - (ilkRate * vaultNormalizedDebt1) / ilkSpot - 1; // -1 because of inequality 
        console2.log("new vault normalized debt: ", formatUnits(vaultNormalizedDebt1, 18));
        console2.log("new vault debt difference: ", formatUnits(debtDiffActual, 18));
        console2.log("new vault collateral: ", formatUnits(vaultCollateral1, 18));
        console2.log("new max collateral withdrawable: ", formatUnits(maxCollateralWithdrawable1, 18));
        console2.log("max collateral newly withdrawable: ", formatUnits(maxCollateralWithdrawable1 - maxCollateralWithdrawable0, 18));
        console2.log("precomputation of collateral newly withdrawable", formatUnits(minDebtRepaymentToFacilitateDeleverage * ilkRate / ilkSpot, 18));

        ionPool.withdrawCollateral(ilkIndex, ionBorrower, ionBorrower, maxCollateralWithdrawable1);
 
        vm.stopPrank(); 
    }
}