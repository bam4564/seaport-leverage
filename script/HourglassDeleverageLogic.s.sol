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
        /* This function ends up calling down to the ion pool spot oracle's getSpot() function.

        // The price of the collateral (weETH) in borrow asset (wstETH) terms -> wstETH / weETH 
        // This is overriden in the spot oracle sub-contract specific to this pool. 
        // 0.888336
        uint256 price = getPrice();

        // Returns the exchange rate between wstETH and weETH. -> wstETH / weETH
        // 0.888211
        uint256 exchangeRate = RESERVE_ORACLE.currentExchangeRate();

        // Take the min of price computed internally and from reserve oracle. 
        uint256 min = Math.min(price, exchangeRate); // [wad]

        // Scale this min price down by the LTV. 
        // LTV for this pool is 0.8
        spot = LTV.wadMulDown(min); // [ray] * [wad] / [wad] = [ray]

        // Current value is roughly. 
        spot = 0.71066898 wstETH / weETH
        */
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
            minDebtRepaymentToFacilitateDeleverage.wadDivDown(userCollateralDeleverageAmount), 18
        ), "wstETH");

        // uint256 ayyy = ilkRate * (minDebtRepaymentToFacilitateDeleverage) / ilkSpot;
        // console2.log("ayyy: ", formatUnits(ayyy, 18));

        // This will free up `userCollateralDeleverageAmount` weETH from the vault.
        // uint256 hh = 59630000000000000000;
        // minDebtRepaymentToFacilitateDeleverage = hh.rayDivDown(ilkRate); 

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

        /* Output: 

        address(this):  0x5b73C5498c1E3b4dbA84de0F1833c4a029d90519
        User:  0xa0f75491720835b36edC92D06DDc468D201e9b73
        ------------------------------------------------
        ilk spot:  0.710728781608730499200000000
        ilk rate:  1.7752371006559967386768185
        -------------- Pre Interaction State -----------------
        vault normalized debt:  345.50750180497734252
        vault collateral:  677.714750753129381296
        max collateral withdrawable:  188.462421862052748619
        -------------- User Repays 10% of debt -----------------
        user collateral deleverage amount (weETH):  67.771475075312938129
        min debt payment to facilitate deleverage (wstETH):  47.796600924881443341
        user wstETH balance:  1000.0
        Implied price for for min dept payment to deleverage: 1 weETH = 0.705261334090281200 wstETH
        new vault normalized debt:  297.254149255616290911
        new vault debt difference:  47.796600924881443341
        new vault collateral:  677.714750753129381296
        new max collateral withdrawable:  256.233896937365686748
        max collateral newly withdrawable:  67.771475075312938129
        precomputation of collateral newly withdrawable 67.771475075312938128

        Thinking about what this means in the case of the seaport deleveraging flow we are trying to simulate:
        - Let's say user wants to pay back 10% of their collateral (weETH). This is 67.771475075312938129 weETH.
        - The minimum amount of wstETH that needs to be paid back to facilitate this collateral 
          withdrwal is 47.796600924881443341 wstETH.
        - The user sends off an RFQ for 67.771475075312938129 weETH to be quoted in wstETH.
        - The current market exchange rate for these assets is 1 weETH = 0.88 wstETH.
        - Let's say that the market maker quotes this price to the end user 
            - rfq maker selling: 67.771475075312938129 weETH
            - rfq taker selling: .88 * 67.771475075312938129 = 59.63889806627538 wstETH 
            - summary: swapping 67.77 weETH for 59.63 wstETH
        - The RFQ maker receives the order and signature. They call down to the seaport deleverage passing these data inputs. 
        - The seaport deleverage contract does the following 
            - validates the order struct 
            - market makers 59.63 wstETH is transferred to the RFQ maker. 
            - The synthetic token hook is triggered. The user pays back 59.63 wstETH of debt. 
            - this action frees up: 
                = debtRepaid / ilkSpot 
                = 59.63 / 0.71 = 83.89 weETH
            - The user can now withdraw 83.89 weETH from the vault.
            - However, the user withdraws the collateral amount encoded in the order 
                - 67.77 weETH
            - This means that the user deleveraged by 83.89 - 67.77 = 16.12 weETH more than they intended.
        */
 
        vm.stopPrank(); 
    }
}